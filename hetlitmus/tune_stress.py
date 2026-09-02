#!/usr/bin/env python3
"""The stress-environment tuner: a seeded random search over the harness's own
stress knobs, one target machine at a time.

`search' draws a configuration, rebuilds every harness dir of --emit-dir with the
knobs as `-D' flags through build.sh's NVCC/HIPCC channel, runs each row once, and
appends the result to an append-only JSONL log.  That log is the whole state:
`rank' reads it offline and writes the winner params files.  The
score is weak iterations per wall-clock second, per row; the draw, the three
validity layers and the objective are hetlitmus/docs/00-environment-design.md
sec 3.8.  Exit: 0 = the pass ran; 2 = configuration/environment error.
"""

import argparse
import json
import os
import re
import secrets
import select
import subprocess
import sys
import time

HETL = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HETL)
BUILD_SH = os.path.join(HETL, "build.sh")
CPU_STRESS_H = os.path.join(REPO, "litmus", "het-runtime", "het_cpu_stress.h")
VERDICT_H = os.path.join(REPO, "litmus", "het-runtime", "het_verdict.h")

LOG_NAME = "tune.jsonl"


def die(msg):
    sys.stderr.write("tune_stress: FATAL: %s\n" % msg)
    sys.exit(2)


def header_define(path, name):
    """The value `path' compiles for `name'.  A header out of reach is fatal, not
    defaulted: the tuner would otherwise search against a bound nothing holds."""
    try:
        with open(path) as fh:
            text = fh.read()
    except (IOError, OSError) as e:
        die("%s cannot be read (%s) -- %s is the bound this search applies"
            % (path, e, name))
    m = re.search(r"^#define[ \t]+%s[ \t]+\(?(-?\d+)\)?" % name, text, re.M)
    if m is None:
        die("%s no longer defines %s" % (path, name))
    return int(m.group(1))


# ---------------------------------------------------------------------------
# The draw.  Knob j of configuration i is a pure function of (base seed, i, j),
# so an index regenerates its whole vector anywhere.
# ---------------------------------------------------------------------------

_M64 = (1 << 64) - 1


def het_draw(seed, who, k):
    """het_cpu_stress.h's splitmix64 draw, value for value."""
    z = ((((seed & 0xffffffff) << 32) | (who & 0xffffffff))
         + k * 0x9E3779B97F4A7C15) & _M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _M64
    return (z ^ (z >> 31)) & 0xffffffff


# Sub-index layout of one configuration: K_STRIDE per redraw attempt, then the
# per-row seed stream, which no redraw may reach.
K_STRIDE = 64
K_RUN_SEED = 1000000
MAX_ATTEMPTS = 16

STRESS_BLOCK_SET = (0, 1, 2, 4, 8, 16, 32, 64)
CPU_STRIDE_SET = (8, 16, 32, 64, 128)
NOISE_BLOCK_SET = (0, 1, 2, 4, 8, 16)
NOISE_STRIDE_SET = (1, 8, 32)
ENEMIES_MAX = 12

# Every knob the search turns, in one joint draw.  Order is the stream: a knob
# inserted above another redraws it into a different value.
KNOBS = ("HET_MEM_STRESS_PCT", "HET_MEM_STRESS_ITER", "HET_MEM_STRESS_PATTERN",
         "HET_PRE_STRESS_PCT", "HET_PRE_STRESS_ITER", "HET_PRE_STRESS_PATTERN",
         "HET_STRESS_LINE_SIZE", "HET_STRESS_TARGETS", "HET_STRESS_ASSIGN",
         "HET_BLOCK_DIM", "HET_STRESS_BLOCKS",
         "HET_CPU_ENEMIES", "HET_CPU_SCRATCH_WORDS", "HET_CPU_SPREAD",
         "HET_CPU_STRIDE", "HET_CPU_ENEMY_SEQ", "HET_CPU_PRELOAD_PCT",
         "HET_NOISE_GPU_BLOCKS", "HET_NOISE_CPU", "HET_NOISE_MB",
         "HET_NOISE_STRIDE",
         "HET_SCRATCH_SIZE")           # derived, never drawn


def draw_knobs(seed, i, env, attempt):
    """One joint draw at attempt `attempt'; two sub-indices per knob."""
    base = attempt * K_STRIDE

    def d(j):
        return het_draw(seed, i, base + j)

    line = 1 << (2 + d(12) % 6)
    targets = 1 + d(14) % 16
    # Even, from the width this test's scope tree needs to the upstream ceiling.
    lo = env.block_dim_lo
    bdim = lo + 2 * (d(18) % ((256 - lo) // 2 + 1))
    blocks = -1 if d(20) % 2 == 0 else STRESS_BLOCK_SET[d(21) % len(STRESS_BLOCK_SET)]
    # -1 = auto and 0 = none are distinct requests, so both sit in the one set.
    e_hi = min(ENEMIES_MAX, max(0, env.spare_cores))
    e_pick = d(22) % (e_hi + 2)
    enemies = -1 if e_pick == 0 else e_pick - 1
    k = {
        "HET_MEM_STRESS_PCT": d(0) % 101,
        "HET_MEM_STRESS_ITER": d(2) % 1025,
        "HET_MEM_STRESS_PATTERN": d(4) % 4,
        "HET_PRE_STRESS_PCT": d(6) % 101,
        "HET_PRE_STRESS_ITER": d(8) % 129,
        "HET_PRE_STRESS_PATTERN": d(10) % 4,
        "HET_STRESS_LINE_SIZE": line,
        "HET_STRESS_TARGETS": targets,
        "HET_STRESS_ASSIGN": d(16) % 2,
        "HET_BLOCK_DIM": bdim,
        "HET_STRESS_BLOCKS": blocks,
        "HET_CPU_ENEMIES": enemies,
        "HET_CPU_SCRATCH_WORDS": 1 << (15 + d(24) % 7),
        "HET_CPU_SPREAD": 1 + d(26) % 16,
        "HET_CPU_STRIDE": CPU_STRIDE_SET[d(28) % len(CPU_STRIDE_SET)],
        "HET_CPU_ENEMY_SEQ": d(30) % 4,
        "HET_CPU_PRELOAD_PCT": d(32) % 101,
        "HET_NOISE_GPU_BLOCKS": NOISE_BLOCK_SET[d(34) % len(NOISE_BLOCK_SET)],
        "HET_NOISE_CPU": d(36) % 2,
        "HET_NOISE_MB": env.noise_mb_set[d(38) % len(env.noise_mb_set)],
        "HET_NOISE_STRIDE": NOISE_STRIDE_SET[d(40) % len(NOISE_STRIDE_SET)],
        # [CudaLitmus] derivation
        "HET_SCRATCH_SIZE": 32 * line * targets,
    }
    return k


def violated(k, env):
    """The draw-time layer: what a configuration cannot ask for, before a
    compiler or a device is spent on it."""
    if k["HET_CPU_SPREAD"] * k["HET_CPU_STRIDE"] > k["HET_CPU_SCRATCH_WORDS"]:
        return "spread x stride exceeds the enemy scratchpad"
    n = k["HET_CPU_ENEMIES"]
    if n < 0:
        n = max(0, env.ncores - env.cpu_test - k["HET_NOISE_CPU"] - env.reserve)
    if n + k["HET_NOISE_CPU"] + env.cpu_test + env.reserve > env.ncores:
        return "enemies + noise + test threads + reserve exceed %d core(s)" % env.ncores
    if k["HET_NOISE_MB"] < 2 * env.llc_mb:
        return "noise working set is below 2 x the last-level cache"
    return None


def draw_config(seed, i, env):
    """Configuration i.  A violated draw redraws at fresh sub-indices and
    consumes NO configuration index."""
    for attempt in range(MAX_ATTEMPTS):
        k = draw_knobs(seed, i, env, attempt)
        why = violated(k, env)
        if why is None:
            return k
    die("configuration %d: %d draws all violated the draw-time constraints "
        "(last: %s) -- the ranges and this machine do not intersect"
        % (i, MAX_ATTEMPTS, why))


def dflags(k):
    """The knob vector as the compiler sees it.  No parentheses: make expands
    this into a shell command line, where `(' opens a subshell."""
    return ["-D%s=%d" % (n, k[n]) for n in KNOBS]


def run_seed(seed, i, row_ix):
    """This row's HET_SEED, off the tuner's own stream: 31 bits, the width the
    harness reads a seed base at."""
    return het_draw(seed, i, K_RUN_SEED + row_ix) & 0x7fffffff


# ---------------------------------------------------------------------------
# The target: what the emitted corpus and this machine allow.
# ---------------------------------------------------------------------------

class Env(object):
    pass


def named_tests(path):
    """--tests: one name per line, `#' and blanks ignored, first field wins."""
    if not os.path.isfile(path):
        die("--tests %s is not a file" % path)
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line.split()[0])
    uniq = list(dict.fromkeys(out))
    if not uniq:
        die("--tests %s names no test" % path)
    return uniq


def mem_available_mb():
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (IOError, OSError, ValueError, IndexError):
        pass
    return 0


def probe(a, tests):
    """The emitted corpus and the machine, read once: the per-test floors the
    draw needs, and the vendor build.sh will pick."""
    env = Env()
    env.emit = os.path.abspath(a.emit_dir)
    if not os.path.isdir(env.emit):
        die("--emit-dir %s is not a directory" % env.emit)
    env.tests = tests
    env.reserve = header_define(CPU_STRESS_H, "HET_CPU_RESERVE_CORES")
    env.max_discard_pct = header_define(VERDICT_H, "HET_RDV_MAX_DISCARD_PCT")

    vendors, lanes, cpu_test = set(), 1, 0
    for t in tests:
        d = os.path.join(env.emit, t)
        got = [(os.path.join(d, "%s.%s" % (t, ext)), v)
               for ext, v in (("cu", "cuda"), ("hip", "hip"))
               if os.path.isfile(os.path.join(d, "%s.%s" % (t, ext)))]
        if len(got) != 1:
            die("%s carries %s render -- one dir names one vendor"
                % (d, "no .cu or .hip" if not got else "both a .cu and a .hip"))
        src, vendor = got[0]
        vendors.add(vendor)
        with open(src) as fh:
            text = fh.read()
        m = re.search(r"^#define SIZE_OF_TEST (\d+)", text, re.M)
        if m is None:
            die("%s defines no SIZE_OF_TEST" % src)
        if int(m.group(1)) != a.iters:
            die("%s was emitted at SIZE_OF_TEST=%s, not --iters %d -- the "
                "tuning length is fixed at emission (litmus7 -s)"
                % (src, m.group(1), a.iters))
        m = re.search(r"^#if HET_BLOCK_DIM < (\d+)", text, re.M)
        if m is None:
            die("%s carries no HET_BLOCK_DIM floor" % src)
        lanes = max(lanes, int(m.group(1)))
        m = re.search(r"^\s*int _nCpuTest = (\d+);", text, re.M)
        if m is None:
            die("%s declares no _nCpuTest" % src)
        cpu_test = max(cpu_test, int(m.group(1)))
    if len(vendors) != 1:
        die("%s mixes GPU dialects %s: one build carries one arch"
            % (env.emit, ", ".join(sorted(vendors))))
    env.vendor = vendors.pop()
    env.compiler_var = "NVCC" if env.vendor == "cuda" else "HIPCC"
    env.compiler = "nvcc" if env.vendor == "cuda" else "hipcc"
    env.cpu_test = cpu_test
    # Even, and at least the lanes one block must hold.
    env.block_dim_lo = max(2, lanes + (lanes & 1))
    if env.block_dim_lo > 256:
        die("the tuning set needs %d lanes per block, past the 256 the draw "
            "spans" % lanes)

    env.ncores = os.cpu_count() or 1
    env.spare_cores = env.ncores - env.reserve - 1 - env.cpu_test
    env.llc_mb = a.llc_mb if a.llc_mb else header_define(CPU_STRESS_H, "HET_LLC_MB")
    # Two noise buffers are requested per run and either may be served from host
    # memory, so half of what is available is the ceiling one may ask for.
    cap = max(1, mem_available_mb() // 2)
    wanted = sorted(set([2 * env.llc_mb, 4 * env.llc_mb, 8 * env.llc_mb,
                         8192, 16384]))
    env.noise_mb_set = tuple(v for v in wanted if v <= cap)
    if not env.noise_mb_set:
        die("no noise working set above 2 x %d MB fits the %d MB this machine "
            "reports available: the interconnect noise cannot be drawn here"
            % (env.llc_mb, mem_available_mb()))
    return env


# ---------------------------------------------------------------------------
# One configuration: build, then run every row serially.
# ---------------------------------------------------------------------------

def build(a, env, k, timeout):
    """`make clean && make <vendor>-bin' per dir, through build.sh: the knobs
    ride the compiler variable, which make expands into the command line."""
    e = dict(os.environ)
    e["RESULTS"] = a.out
    flags = dflags(k)
    if a.llc_mb:
        flags = flags + ["-DHET_LLC_MB=%d" % a.llc_mb]
    e[env.compiler_var] = "%s %s" % (e.get(env.compiler_var) or env.compiler,
                                     " ".join(flags))
    cmd = [BUILD_SH, env.emit, "--tests", os.path.abspath(a.tests),
           "-j", str(a.jobs)]
    if a.arch:
        cmd += ["--arch", a.arch]
    try:
        r = subprocess.run(cmd, env=e, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return "build timed out after %d s" % timeout
    if r.returncode != 0:
        return "build.sh rc=%d: %s" % (r.returncode, r.stderr.strip()[-300:])
    return None


GEOM_RE = re.compile(r"^HetLitmus: blockDim=(\d+) grid=(\d+) \(test=(\d+) "
                     r"stress=(\d+), co-resident cap=(\d+)\)")
CPUCFG_RE = re.compile(r"^HetLitmus cpu-stress: cores=(\d+) test=(\d+) "
                       r"enemies=(-?\d+) .*\| noise: gpu_blocks=(\d+) cpu=(\d+)")
EMPTY_RE = re.compile(r"^HetLitmus WARNING: the mem-stress population is EMPTY")
OVERCAP_RE = re.compile(r"^grid (\d+) exceeds co-resident cap (\d+)")


def launch_refusal(line):
    """The launch-time layer: the two lines that say the realised geometry is
    not the drawn one, both printed before the first iteration."""
    if EMPTY_RE.match(line):
        return "the mem-stress population is empty"
    m = OVERCAP_RE.match(line)
    if m:
        return "grid %s exceeds the co-resident cap %s" % (m.group(1), m.group(2))
    return None


def realized(lines):
    """What the driver says it actually got, beside what was drawn."""
    out = {}
    for line in lines:
        m = GEOM_RE.match(line)
        if m:
            out.update(block_dim=int(m.group(1)), grid=int(m.group(2)),
                       test_blocks=int(m.group(3)),
                       stress_blocks=int(m.group(4)),
                       max_grid=int(m.group(5)))
        m = CPUCFG_RE.match(line)
        if m:
            out.update(cores=int(m.group(1)), cpu_test=int(m.group(2)),
                       enemies=int(m.group(3)),
                       noise_gpu_blocks=int(m.group(4)),
                       noise_cpu=int(m.group(5)))
    return out


def kv_line(line, tag):
    """A `TAG <name> key=value ...' machine line's fields, or None: the human
    block sharing the prefix ends its second field in `:'."""
    if not line.startswith(tag + " "):
        return None
    f = line.split()
    if len(f) < 3 or f[1].endswith(":"):
        return None
    kv = {}
    for tok in f[2:]:
        p = tok.find("=")
        if p > 0:
            kv[tok[:p]] = tok[p + 1:]
    return kv


def inum(kv, key):
    try:
        return int(kv.get(key, "0"), 0)
    except ValueError:
        return 0


def run_row(exe, cwd, e, timeout):
    """One invocation, read as it arrives so a launch-time refusal is caught in
    seconds rather than in a full run."""
    t0 = time.time()
    p = subprocess.Popen([exe], cwd=cwd, env=e, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=0)
    lines, buf, refusal = [], b"", None
    deadline = t0 + timeout
    while True:
        left = deadline - time.time()
        if left <= 0:
            p.kill()
            p.wait()
            return "TIMEOUT", time.time() - t0, lines, "timeout after %d s" % timeout
        if not select.select([p.stdout], [], [], min(left, 1.0))[0]:
            continue
        chunk = os.read(p.stdout.fileno(), 65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode("utf-8", "replace")
            lines.append(line)
            if refusal is None:
                refusal = launch_refusal(line)
        if refusal is not None:
            p.kill()
            p.wait()
            return "KILLED", time.time() - t0, lines, refusal
    if buf:
        lines.append(buf.decode("utf-8", "replace"))
    p.stdout.close()
    return p.wait(), time.time() - t0, lines, None


def score(lines, max_discard_pct):
    """The score-time layer: weak iterations, the effort behind them, and
    whether this run is a reading at all."""
    hs = None
    weak, live = 0, {}
    for line in lines:
        kv = kv_line(line, "HetStats")
        if kv is not None:
            hs = kv
        kv = kv_line(line, "HetObs")
        if kv is not None:
            weak += inum(kv, "target")
            live = {n: kv.get(n, "") for n in
                    ("req", "do_stress_rounds", "stress_trunc", "enemies",
                     "enemy_rounds", "preload", "noise_cpu", "noise_gpu",
                     "noise_inert")}
    if hs is None:
        return None, {"status": "error", "weak": 0,
                      "why": "no HetStats machine line"}
    R, usable = inum(hs, "R"), inum(hs, "usable")
    n, disc = inum(hs, "N"), inum(hs, "discarded")
    rec = {"weak": weak, "R": R, "usable": usable, "k": inum(hs, "k"),
           "k_eff": inum(hs, "k_eff"), "N": n,
           "iters_scored": inum(hs, "scored"), "discarded": disc,
           "flags": hs.get("flags", ""), "live": live}
    if R < 1:
        rec.update(status="error", why="the harness scored no run")
    elif usable == 0:
        # het_verdict()'s COLD-INVALID: a mechanism the build asked for was dead,
        # and a search scoring such a run optimises the dead mechanism.
        rec.update(status="excluded",
                   why="not one of %d run(s) was usable (every run "
                       "COLD-INVALID)" % R)
    elif n > 0 and disc * 100 > n * R * max_discard_pct:
        rec.update(status="excluded",
                   why="%d of %d iteration(s) discarded at the rendezvous"
                       % (disc, n * R))
    else:
        rec.update(status="scored",
                   why="" if usable == R
                   else "%d of %d run(s) COLD-INVALID" % (R - usable, R))
    return hs, rec


def run_config(a, env, log, i, k):
    """Every row of one configuration, serially: a stress configuration owns the
    machine while it is measured."""
    t0 = time.time()
    why = build(a, env, k, a.timeout)
    if why is not None:
        log.emit({"type": "config", "i": i, "seed": a.seed, "drawn": k,
                  "status": "build_error", "why": why})
        print("config %d: %s" % (i, why))
        return False
    print("config %d: built in %.1f s" % (i, time.time() - t0))

    for row_ix, t in enumerate(env.tests):
        d = os.path.join(env.emit, t)
        exe = os.path.join(d, t)
        if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
            log.emit({"type": "run", "i": i, "row": t, "status": "error",
                      "why": "no executable harness at %s" % exe})
            continue
        e = dict(os.environ)
        seed = run_seed(a.seed, i, row_ix)
        e["HET_SEED"] = str(seed)
        e["HET_RATE"] = "1"
        e["HET_ADAPTIVE"] = "0"
        e["HET_RUNS_MAX"] = "1"
        if a.cap_cpu:
            e["HET_CAP_CPU"] = str(a.cap_cpu)
        if a.cap_gpu:
            e["HET_CAP_GPU"] = str(a.cap_gpu)
        rc, secs, lines, refusal = run_row(exe, d, e, a.timeout)
        real = realized(lines)
        if rc == "KILLED":
            log.emit({"type": "config", "i": i, "seed": a.seed, "drawn": k,
                      "status": "invalid_geometry", "why": refusal,
                      "realized": real})
            print("config %d: invalid geometry -- %s" % (i, refusal))
            return False
        rec = {"type": "run", "i": i, "row": t, "het_seed": seed,
               "secs": round(secs, 3), "realized": real}
        if rc != 0:
            rec.update(status="error", weak=0, rate_s=0.0,
                       why=refusal or "harness rc=%s" % rc)
        else:
            _, sc = score(lines, env.max_discard_pct)
            rec.update(sc)
            rec["rate_s"] = round(rec.get("weak", 0) / secs, 6) if secs > 0 else 0.0
        log.emit(rec)
        print("  %-28s %-9s weak=%-6s %.3f/s in %.1f s%s"
              % (t, rec["status"], rec.get("weak", 0), rec.get("rate_s", 0.0),
                 secs, ("  ** " + rec["why"] + " **") if rec.get("why") else ""))
    log.emit({"type": "config", "i": i, "seed": a.seed, "drawn": k,
              "status": "scored"})
    return True


# ---------------------------------------------------------------------------
# The log: append-only, and the only state the search keeps.
# ---------------------------------------------------------------------------

class Log(object):
    def __init__(self, path):
        self.fh = open(path, "a")

    def emit(self, obj):
        self.fh.write(json.dumps(obj, sort_keys=True) + "\n")
        self.fh.flush()


def read_log(path):
    if not os.path.isfile(path):
        die("%s holds no log" % path)
    out, bad = [], 0
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                bad += 1
    if bad:
        print("tune_stress: %d unparseable log line(s) skipped" % bad)
    return out


def log_meta(rows):
    for r in rows:
        if r.get("type") == "meta":
            return r
    die("the log carries no meta line, so it names no target or seed")


# ---------------------------------------------------------------------------
# Passes.
# ---------------------------------------------------------------------------

def search(a):
    tests = named_tests(a.tests)
    env = probe(a, tests)
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, LOG_NAME)
    i, scored = 0, 0
    fresh = not os.path.isfile(path)
    a.target = a.target or os.uname().nodename
    if not fresh:
        if not a.resume:
            die("%s already holds a log: pass --resume to continue that search, "
                "or point --out at a fresh directory" % path)
        rows = read_log(path)
        meta = log_meta(rows)
        if a.seed is None:
            a.seed = meta["seed"]
        if meta["seed"] != a.seed or meta["iters"] != a.iters:
            die("%s was written at seed=%s iters=%s, not seed=%s iters=%s -- "
                "that is another stream, not a continuation"
                % (path, meta["seed"], meta["iters"], a.seed, a.iters))
        for r in rows:
            if r.get("type") == "config":
                i = max(i, r["i"] + 1)
                if r["status"] == "scored":
                    scored += 1
        print("tune_stress: resuming at index %d, %d config(s) scored" % (i, scored))
    if a.seed is None:
        a.seed = secrets.randbits(31)
    log = Log(path)
    if fresh:
        log.emit({"type": "meta", "seed": a.seed, "iters": a.iters,
                  "target": a.target, "vendor": env.vendor, "arch": a.arch or "",
                  "emit_dir": env.emit, "tests": tests,
                  "llc_mb": env.llc_mb, "cores": env.ncores,
                  "noise_mb_set": list(env.noise_mb_set),
                  "block_dim_lo": env.block_dim_lo})
    print("tune_stress: seed=%d target=%s %s %d row(s), %d core(s), "
          "noise set %s MB"
          % (a.seed, a.target, env.vendor, len(tests), env.ncores,
             ",".join(str(v) for v in env.noise_mb_set)))
    try:
        while a.configs == 0 or scored < a.configs:
            k = draw_config(a.seed, i, env)
            if run_config(a, env, log, i, k):
                scored += 1
            i += 1
    except KeyboardInterrupt:
        print("\ntune_stress: interrupted at index %d, %d config(s) scored -- "
              "resume with --resume --out %s" % (i, scored, a.out))
    return 0


def rank(a):
    rows = read_log(os.path.join(a.out, LOG_NAME))
    meta = log_meta(rows)
    target = a.target or meta.get("target") or ""
    runs = [r for r in rows if r.get("type") == "run" and r["status"] == "scored"]
    if not runs:
        print("tune_stress: no scored run in %s" % a.out)
        return 0

    best, revealed = {}, {}
    for r in runs:
        b = best.get(r["row"])
        if b is None or r["rate_s"] > b["rate_s"]:
            best[r["row"]] = r
        if r["weak"] > 0:
            revealed.setdefault(r["i"], set()).add(r["row"])

    print("per-row argmax on weak iterations per second:")
    wins, dark = {}, []
    for row in sorted(best):
        r = best[row]
        if r["weak"] == 0:
            dark.append(row)
            continue
        wins[r["i"]] = wins.get(r["i"], 0) + 1
        print("  %-28s config %-5d %.4f/s  weak=%d in %.1f s"
              % (row, r["i"], r["rate_s"], r["weak"], r["secs"]))
    if dark:
        print("  no configuration revealed: %s" % ", ".join(dark))
    never = sorted(set(r["row"] for r in rows if r.get("type") == "run")
                   - set(best))
    if never:
        print("  never scored (every line excluded or errored): %s"
              % ", ".join(never))
    if not wins:
        return 0

    print("rows each configuration revealed at all:")
    for i in sorted(revealed, key=lambda i: (-len(revealed[i]), i)):
        print("  config %-5d %s" % (i, ", ".join(sorted(revealed[i]))))

    # The greedy cover from the argmax leader: what a campaign taking one
    # configuration would never see, and the cheapest configurations that add it.
    lead = min(wins, key=lambda i: (-wins[i], i))
    covered = set(revealed.get(lead, ()))
    allrows = set()
    for rows_i in revealed.values():
        allrows |= rows_i
    print("coverage: config %d wins %d row(s) and reveals %d of the %d row(s) "
          "any configuration revealed."
          % (lead, wins[lead], len(covered), len(allrows)))
    while covered != allrows:
        nxt = min(revealed, key=lambda i: (-len(revealed[i] - covered), i))
        extra = revealed[nxt] - covered
        if not extra:
            break
        print("  config %-5d adds %s" % (nxt, ", ".join(sorted(extra))))
        covered |= extra

    drawn = {r["i"]: r["drawn"] for r in rows
             if r.get("type") == "config" and "drawn" in r}
    for i in sorted(wins):
        out = os.path.join(a.out, "winner-%d.params" % i)
        with open(out, "w") as fh:
            fh.write("# target=%s\n# seed=%d\n# config=%d\n" % (target, meta["seed"], i))
            for f in dflags(drawn[i]):
                fh.write(f + "\n")
        print("winner config %d -> %s" % (i, out))
    return 0


def add_build_args(p):
    p.add_argument("--emit-dir", required=True,
                   help="the tuning-length emission: one harness dir per test")
    p.add_argument("--tests", required=True,
                   help="file naming the tuning set, one test per line")
    p.add_argument("--out", required=True,
                   help="log, build logs and winner params files")
    p.add_argument("--iters", type=int, default=100000,
                   help="the SIZE_OF_TEST --emit-dir must carry")
    p.add_argument("--arch", default="",
                   help="device arch, as build.sh takes it; the default is the "
                        "probe record build.sh reads from --out")
    p.add_argument("--llc-mb", type=int, default=0,
                   help="last-level cache on the path, in MB; the noise draw is "
                        "built from it, and it is compiled in when given")
    p.add_argument("--cap-cpu", type=int, default=0, help="HET_CAP_CPU per run")
    p.add_argument("--cap-gpu", type=int, default=0, help="HET_CAP_GPU per run")
    p.add_argument("--timeout", type=int, default=900,
                   help="seconds one build or one invocation may take")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4,
                   help="build.sh parallelism across harness dirs")


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="pass_", required=True)

    s = sub.add_parser("search", help="draw, build, run, log")
    add_build_args(s)
    s.add_argument("--configs", type=int, default=0,
                   help="scored configurations to reach; 0 runs until "
                        "interrupted")
    s.add_argument("--seed", type=int, default=None,
                   help="base seed of the draw stream; the default is drawn and "
                        "logged")
    s.add_argument("--target", default="",
                   help="the machine this search is valid on; it stamps the "
                        "winner params files")
    s.add_argument("--resume", action="store_true",
                   help="continue the search --out already holds")

    r = sub.add_parser("rank", help="rank the log and write winner params files")
    r.add_argument("--out", required=True, help="the directory holding the log")
    r.add_argument("--target", default="",
                   help="override the target the log recorded")

    a = ap.parse_args()
    a.out = os.path.abspath(a.out)
    if a.pass_ != "rank":
        if a.iters < 1:
            die("--iters %d is not a test length" % a.iters)
        if a.jobs < 1:
            die("-j %d is not a positive integer" % a.jobs)
        if not os.access(BUILD_SH, os.X_OK):
            die("%s is not executable, and every rebuild goes through it"
                % BUILD_SH)
    return a


def main():
    a = parse_args()
    if a.pass_ == "search":
        return search(a)
    return rank(a)


if __name__ == "__main__":
    sys.exit(main())
