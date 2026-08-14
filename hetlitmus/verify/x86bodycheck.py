#!/usr/bin/env python3
"""
x86bodycheck.py -- is the x86-64 CPU thread of a het harness REAL?

A stub body -- an x86 CPU proc emitted as `{ (void)_n; (void)x; (void)y; }' --
tests nothing and does not fail loudly: with no tagged store and no bound load
the condition can resolve neither a read buffer nor a mu, so litmus7 refuses most
of the corpus, and a refusal that exits 0 reports success.

Seven phases, each of which must be seen to fail:

  P1 emission coverage   every x86 rendering emits a complete harness
  P2 body fidelity       each emitted body is its OWN test's program, not a stub
  P3 tag liveness        every store carries K*(_n+1)+mu, every load reaches a
                         buffer -- emitting is not testing
  P4 machine code        the tested instructions survive gcc to the .o
  P5 AArch64 lane        it still emits str/ldr/dmb with no x86 leak, and its
                         classifier refuses what it cannot render faithfully
  P6 fail-closed         a refusal exits 3, prints HetLitmus REFUSED and leaves
                         no harness; `--bite' drives emit-all.sh's three
                         detectors from here as well
  P7 co-run bodies       a co-run harness carries T, mu(T) AND the canary at the
                         same proc index; each must be checked against its own
                         test, none silently dropped

Non-vacuity: P2/P3/P7 do not merely count what they saw.  Each pins its count
against a total derived from the corpus' own .litmus columns AND against a
measured constant, so a phase that made zero comparisons fails rather than
printing "0 comparisons made" and passing.

`--bite' injects into each phase, on CORRUPTION and on OMISSION, and requires the
phase that owns the injected object to redden naming it.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")
GEN_X86 = os.path.join(HET_DIR, "generate-x86.sh")
# The x86 lane has its OWN lattice: hetCpuFront.X86_64 names control-map-amd.csv,
# and generate-x86.sh re-keys it onto the -x86_64 names inside the generated
# corpus.  This gate therefore reads the map the emitter reads, rather than
# building an x86-keyed stand-in and checking a configuration nothing ships.
CONTROL_MAP = os.path.join(HET_DIR, "control-map-amd.csv")
EMIT_ALL = os.path.join(HERE, "emit-all.sh")
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

# ---------------------------------------------------------------------------
# Census pins.  Each is cross-checked at run time against a value derived live
# from the corpus, so a pin can go stale only by someone changing both.
# ---------------------------------------------------------------------------

# One x86 rendering per corpus test: generate-x86.sh mirrors generate.sh's
# degenerate two-sided drop, so the two name sets are equal in both directions
# and control-map-amd.csv can stay keyed on the unsuffixed names with NO orphan
# either way.  That script explains its sections and prints their census.
N_X86 = 411

# The x86 side of those renderings, counted from their .litmus columns.
N_X86_PROCS = 663
N_X86_STORES = 608
N_X86_LOADS = 579

# P7's probe set: the control-map rows that name a mu(T), hence the harnesses
# that co-run three instances (T, mu, canary), all three at the SAME proc index
# -- which is why keying bodies by proc alone loses two of every three.  That is
# every row off the lattice floor; the rest are the fully-relaxed rows no sibling
# can be weaker than.
# The body count is not N_CORUN_TESTS x 3: a co-run harness emits one body per
# (instance, x86 proc) pair, and how many x86 procs a shape has runs from one
# (LB, MP) to three (WRC3), so the ratio is shape-dependent and the two numbers
# are measured separately, never derived from each other.
N_CORUN_TESTS = 333
N_CORUN_BODIES = 1365

# Representative harness for the machine-code phase: its x86 CPU proc carries a
# store, a fence AND a load, so one objdump covers the whole vocabulary.  It is
# off the lattice floor, so it emits three instances and its bodies are prefixed
# (het_run_t_P0, not het_run_P0) -- the symbol has to be looked up rather than
# assumed; see MC_SYMS.
MC_TEST = "SB-cg-sys-fence-2s-x86_64"
MC_SYMS = ["het_run_t_P0", "het_run_P0"]

# AArch64 tests P5 re-emits (a store proc, a load proc, a two-sided proc).
AARCH64_TESTS = ["2+2W-cg-sys-relaxed", "MP-gc-sys-relaxed", "MP-cg-sys-fence-2s"]

# Which GPU dialect the x86 renderings are emitted for.  A harness is a
# (CPU ISA x GPU dialect) pair, and (x86_64, hip) is the one with an MI300A row
# (litmus/hetMachine.ml).  Either x86 dialect would do for what P7 reads -- both
# read control-map-amd.csv, which is keyed on the CPU frontend -- and hip is the
# render the rest of this gate builds.  The CPU body itself is
# dialect-independent (one <t>_cpu.c per harness), which is what makes this
# phase's subject the same either way.
X86_TARGET = "hip"
X86_EXT = "hip"

fails = []


def fail(phase, msg):
    fails.append((phase, msg))
    print("  FAIL [%s] %s" % (phase, msg))


def env():
    e = dict(os.environ)
    e["PATH"] = os.path.join(ROOT, "_build", "install", "default", "bin") + os.pathsep + e["PATH"]
    return e


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, env=env(), **kw)


# ---------------------------------------------------------------- test parsing

def parse_litmus(path):
    """Return (name, {proc: [cells]}, {proc: isa}) for one het .litmus."""
    lines = open(path).read().splitlines()
    body = [l for l in lines if "|" in l and l.rstrip().endswith(";")]
    if not body:
        raise SystemExit("x86bodycheck: %s has no program section" % path)
    hdr = [c.strip() for c in body[0].rstrip().rstrip(";").split("|")]
    isa = {}
    for i, c in enumerate(hdr):
        m = re.match(r"P(\d+):(\S+)", c)
        if m:
            isa[i] = m.group(2)
    cells = {i: [] for i in isa}
    for l in body[1:]:
        cs = [c.strip() for c in l.rstrip().rstrip(";").split("|")]
        for i in isa:
            if i < len(cs) and cs[i]:
                cells[i].append(cs[i])
    return os.path.basename(path)[:-len(".litmus")], cells, isa


_PARSE_CACHE = {}


def parse_cached(path):
    if path not in _PARSE_CACHE:
        _PARSE_CACHE[path] = parse_litmus(path)
    return _PARSE_CACHE[path]


# x86 het vocabulary, as _grid_lib.sh renders it
RE_ST_IMM = re.compile(r"^mov[bwlq]?\s+\$(\d+),\((\w+)\)$")
RE_ST_REG = re.compile(r"^mov[bwlq]?\s+%(\w+),\((\w+)\)$")
RE_LD = re.compile(r"^mov[bwlq]?\s+\((\w+)\),%(\w+)$")
RE_FENCE = re.compile(r"^([ms]fence|lfence)$")


def expected_nodes(cells):
    """The (kind, global) sequence one x86 column must produce."""
    out = []
    for c in cells:
        m = RE_ST_IMM.match(c) or RE_ST_REG.match(c)
        if m:
            out.append(("store", m.group(2)))
            continue
        m = RE_LD.match(c)
        if m:
            out.append(("load", m.group(1)))
            continue
        m = RE_FENCE.match(c)
        if m:
            out.append(("fence", m.group(1)))
            continue
        raise SystemExit("x86bodycheck: unmodelled x86 cell %r" % c)
    return out


def corpus_x86_census(corpus):
    """(procs, stores, loads) over every x86_64 column in [corpus].

    Derived from the .litmus SOURCES, never from an emitted harness, so it is a
    genuine expectation for P2/P3 rather than a restatement of what they saw.
    """
    procs = stores = loads = 0
    for f in sorted(os.listdir(corpus)):
        if not f.endswith(".litmus"):
            continue
        _, cells, isa = parse_cached(os.path.join(corpus, f))
        for p, tag in isa.items():
            if tag != "x86_64":
                continue
            procs += 1
            for k, _g in expected_nodes(cells[p]):
                if k == "store":
                    stores += 1
                elif k == "load":
                    loads += 1
    return procs, stores, loads


# ------------------------------------------------------------- body extraction

# Group 2 is the co-run prefix: "" for a single-instance harness, else "t_",
# "mu_" or "can_" (hetEmit's co-run naming).  Capturing it is what lets a body be
# checked against ITS OWN test rather than against the harness' T.
RE_FUNC = re.compile(r"^void (het_run_(\w*?)P(\d+))\(([^)]*)\) \{$")

# The CO-RUN banner hetEmit writes at the top of <t>_cpu.c, e.g.
#      T      LB-cg-sys-fence-2s-x86_64 K=3
#      mu(T)  LB-cg-sys-fence-x86_64 K=3
#      canary MP-cg-sys-relaxed-x86_64 K=3
RE_CORUN = re.compile(r"^\s+(T|mu\(T\)|canary)\s+(\S+)\s+K=(\d+)\s*$", re.M)
ROLE_PREFIX = {"T": "t_", "mu(T)": "mu_", "canary": "can_"}


def host_region(cpu_c):
    """The `#if defined(__x86_64__)' / `#if defined(__aarch64__)' arm only."""
    txt = open(cpu_c).read()
    m = re.search(r"^#if defined\(__\w+__\)\n(.*?)^#else$", txt, re.S | re.M)
    if not m:
        raise SystemExit("x86bodycheck: no host arm in %s" % cpu_c)
    return m.group(1)


def split_bodies(region):
    """{(proc, fname): (prefix, [lines])} for each het_run_*P<n> in the host arm.

    Keyed by (proc, fname), NOT by proc.  A co-run harness carries het_run_t_P0,
    het_run_mu_P0 and het_run_can_P0 -- three different programs at the same proc
    index -- so a proc-keyed dict keeps only the last of them (the canary) and
    P2/P3 stop checking T and mu(T) altogether.  On every `-relaxed' rendering T
    and the canary have the same (kind,global) sequence, so P2 goes on passing
    while checking the wrong program.
    """
    bodies, cur, key, prefix = {}, None, None, None
    for l in region.splitlines():
        m = RE_FUNC.match(l)
        if m:
            key, prefix, cur = (int(m.group(3)), m.group(1)), m.group(2), []
            continue
        if cur is not None:
            if l == "}":
                if key in bodies:
                    raise SystemExit(
                        "x86bodycheck: two bodies named %s at P%d" % (key[1], key[0]))
                bodies[key] = (prefix, cur)
                cur = None
            else:
                cur.append(l)
    return bodies


def split_bodies_proc_keyed(region):
    """The proc-keyed splitter, which loses every body but the last at a shared
    proc index.  Kept ONLY so --bite can restore that defect and watch P7 redden;
    no passing run uses it."""
    out = {}
    for (proc, fname), v in split_bodies(region).items():
        out[(proc, "het_run_P%d" % proc)] = v
    return out


def corun_map(cpu_c):
    """{prefix: (test, K)} from the CO-RUN banner; {} for a single-instance file."""
    txt = open(cpu_c).read()
    head = txt.split("#define _GNU_SOURCE")[0]
    return {ROLE_PREFIX[r]: (t, int(k)) for r, t, k in RE_CORUN.findall(head)}


def resolve_bodies(corpus, name, cpu_c, splitter=split_bodies):
    """[(proc, fname, prefix, lines, src_test_or_None)] for one harness.

    src_test is the test whose column that body must reproduce: the harness'
    own name for a single-instance body, else whatever the CO-RUN banner names
    for that prefix.  None means "unresolvable" and every caller FAILS on it --
    a body nobody can attribute is never silently skipped.
    """
    region = host_region(cpu_c)
    cm = corun_map(cpu_c)
    out = []
    for (proc, fname), (prefix, lines) in sorted(splitter(region).items()):
        if prefix == "":
            src = name if not cm else None
        else:
            src = cm.get(prefix, (None, None))[0]
        out.append((proc, fname, prefix, lines, src))
    return out, cm


RE_ASM_ST = re.compile(r'^\s*"movq %\[_v(\d+)\],\(%\[(\w+)\]\)\\n"$')
RE_ASM_LD = re.compile(r'^\s*"movq \(%\[(\w+)\]\),%\[_t(\d+)\]\\n"$')
RE_ASM_FEN = re.compile(r'^\s*"([ms]fence|lfence)\\n"$')
RE_TAG = re.compile(r"^\s*uint64_t _v(\d+) = \(uint64_t\)(\d+) \* \(_n \+ 1\) \+ (\d+);$")
RE_TMP = re.compile(r"^\s*uint64_t _t(\d+) = 0;$")
RE_BUF = re.compile(r"^\s*(\w+)\[_n\] = _t(\d+);$")


def body_nodes(lines):
    """The (kind, global) sequence the emitted asm block actually performs."""
    out = []
    for l in lines:
        m = RE_ASM_ST.match(l)
        if m:
            out.append(("store", m.group(2)))
            continue
        m = RE_ASM_LD.match(l)
        if m:
            out.append(("load", m.group(1)))
            continue
        m = RE_ASM_FEN.match(l)
        if m:
            out.append(("fence", m.group(1)))
            continue
    return out


# ------------------------------------------------------------------- P1 + P2/3

def emit_corpus(tmp, corpus, sub="emit"):
    """Emit every rendering in [corpus]; return {name: harness dir}, refusals."""
    out = os.path.join(tmp, sub)
    os.makedirs(out, exist_ok=True)
    good, bad = {}, []
    for f in sorted(os.listdir(corpus)):
        if not f.endswith(".litmus"):
            continue
        n = f[:-len(".litmus")]
        r = run([LITMUS7, "-gpu-target", X86_TARGET, "-set-libdir", LIBDIR, "-o", out, os.path.join(corpus, f)])
        blob = r.stdout + r.stderr
        d = os.path.join(out, n)
        # The files THIS emission owes: one vendor per harness dir (-gpu-target
        # above), so the other dialect's render is that lane's deliverable, not
        # a missing file.
        parts = [os.path.join(d, n + s) for s in ("_cpu.c", "." + X86_EXT)]
        if r.returncode != 0:
            bad.append((n, "litmus7 exited %d: %s" % (r.returncode, blob.strip().splitlines()[-1:])))
        elif "HetLitmus REFUSED" in blob:
            bad.append((n, "REFUSED marker on stderr"))
        elif not all(os.path.exists(p) and os.path.getsize(p) for p in parts):
            missing = [os.path.basename(p) for p in parts
                       if not (os.path.exists(p) and os.path.getsize(p))]
            bad.append((n, "harness incomplete: missing %s" % ", ".join(missing)))
        else:
            good[n] = d
    return good, bad


def phase1(corpus, good, bad):
    print("== P1  emission coverage (was 39/411 with the stub) ==")
    n = len([f for f in os.listdir(corpus) if f.endswith(".litmus")])
    if n != N_X86:
        fail("P1", "generate-x86.sh produced %d renderings, expected %d" % (n, N_X86))
    for name, why in bad:
        fail("P1", "%s did not emit a complete harness (%s)" % (name, why))
    # Second, INDEPENDENT detector: `bad' is what emit_corpus noticed; this pin
    # fires even if a rendering never reached it at all.
    if len(good) != n:
        fail("P1", "%d of the %d renderings emitted a complete harness"
             % (len(good), n))
    print("  emitted %d / %d x86 renderings" % (len(good), n))


def check_fidelity(phase, corpus, name, recs, cm):
    """Compare every body of one harness against ITS OWN test's column.

    Returns (bodies_compared, {proc of a body that IS this test's own}).
    """
    compared, own = 0, set()
    for (proc, fname, prefix, lines, src) in recs:
        if src is None:
            fail(phase, "%s: body %s carries co-run prefix %r, which the CO-RUN "
                        "banner does not name (%r) -- cannot attribute it to a test"
                 % (name, fname, prefix, sorted(cm)))
            continue
        sp = os.path.join(corpus, src + ".litmus")
        if not os.path.exists(sp):
            fail(phase, "%s: body %s claims to be %s, which is not in the corpus"
                 % (name, fname, src))
            continue
        _, scells, sisa = parse_cached(sp)
        if sisa.get(proc) != "x86_64":
            fail(phase, "%s: body %s sits at P%d, which is not an x86_64 proc of %s (%r)"
                 % (name, fname, proc, src, sisa.get(proc)))
            continue
        want = expected_nodes(scells[proc])
        got = body_nodes(lines)
        if got != want:
            fail(phase, "%s %s: emitted %r but %s P%d says %r"
                 % (name, fname, got, src, proc, want))
        compared += 1
        if prefix in ("", "t_"):
            own.add(proc)
    return compared, own


def phase2(corpus, good, splitter=split_bodies):
    print("== P2  body fidelity: every emitted body IS its own test's column ==")
    # Derived from the CORPUS, not from [good]: a run that emitted nothing must
    # fail the pin instead of passing on zero comparisons.
    want_procs, _, _ = corpus_x86_census(corpus)
    compared = covered = 0
    for name, d in sorted(good.items()):
        _, _cells, isa = parse_cached(os.path.join(corpus, name + ".litmus"))
        x86procs = {p for p, t in isa.items() if t == "x86_64"}
        cpu_c = os.path.join(d, name + "_cpu.c")
        region = host_region(cpu_c)
        if "(void)_n;" in region:
            fail("P2", "%s: the host arm still carries a STUB body ((void)_n)" % name)
            continue
        recs, cm = resolve_bodies(corpus, name, cpu_c, splitter)
        c, own = check_fidelity("P2", corpus, name, recs, cm)
        compared += c
        for p in sorted(x86procs - own):
            fail("P2", "%s: no body of its own for x86 proc P%d (found %r)"
                 % (name, p, [r[1] for r in recs]))
        covered += len(own & x86procs)
    if covered != want_procs:
        fail("P2", "covered %d of the %d x86 procs the corpus declares -- a phase "
                   "that checks nothing must not pass" % (covered, want_procs))
    if want_procs != N_X86_PROCS:
        fail("P2", "the corpus declares %d x86 procs, pinned at %d"
             % (want_procs, N_X86_PROCS))
    print("  %d bodies compared against their own test's column (%d of them the "
          "corpus' own %d x86 procs)" % (compared, covered, want_procs))


def check_liveness(phase, name, recs):
    """Tag liveness for every body of one harness.  Returns (stores, loads)."""
    nst = nld = 0
    for (_proc, fname, _prefix, lines, _src) in recs:
        tags = {int(m.group(1)): (int(m.group(2)), int(m.group(3)))
                for m in (RE_TAG.match(l) for l in lines) if m}
        tmps = {int(m.group(1)) for m in (RE_TMP.match(l) for l in lines) if m}
        bufs = {int(m.group(2)): m.group(1)
                for m in (RE_BUF.match(l) for l in lines) if m}
        st = [int(m.group(1)) for m in (RE_ASM_ST.match(l) for l in lines) if m]
        ld = [int(m.group(2)) for m in (RE_ASM_LD.match(l) for l in lines) if m]
        if '  asm __volatile__(' not in lines:
            fail(phase, "%s %s: the block is not asm __volatile__" % (name, fname))
        if '    : "memory","cc");' not in lines:
            fail(phase, "%s %s: the block does not clobber memory" % (name, fname))
        for i in st:
            if i not in tags:
                fail(phase, "%s %s: store operand _v%d has no K*(_n+1)+mu tag"
                     % (name, fname, i))
                continue
            k, mu = tags[i]
            if k < 1 or mu < 1:
                fail(phase, "%s %s: _v%d tag is K=%d mu=%d (a constant store)"
                     % (name, fname, i, k, mu))
            nst += 1
        mus = [tags[i][1] for i in st if i in tags]
        if len(set(mus)) != len(mus):
            fail(phase, "%s %s: two stores share a mu %r -- recovery cannot tell "
                        "them apart" % (name, fname, mus))
        for i in ld:
            if i not in tmps:
                fail(phase, "%s %s: load into _t%d that is never declared"
                     % (name, fname, i))
            if i not in bufs:
                fail(phase, "%s %s: load _t%d is never recorded into a buffer"
                     % (name, fname, i))
            nld += 1
    return nst, nld


def phase3(corpus, good, splitter=split_bodies):
    print("== P3  tag liveness: stores tag, loads reach a buffer ==")
    _, want_st, want_ld = corpus_x86_census(corpus)
    own_st = own_ld = co_st = co_ld = 0
    for name, d in sorted(good.items()):
        cpu_c = os.path.join(d, name + "_cpu.c")
        recs, _cm = resolve_bodies(corpus, name, cpu_c, splitter)
        own = [r for r in recs if r[2] in ("", "t_")]
        co = [r for r in recs if r[2] not in ("", "t_")]
        a, b = check_liveness("P3", name, own)
        own_st += a
        own_ld += b
        a, b = check_liveness("P3", name, co)
        co_st += a
        co_ld += b
    # The pins count the harnesses' OWN bodies only, so the co-run bodies the
    # control map beside the renderings adds do not disturb them.
    if (own_st, own_ld) != (want_st, want_ld):
        fail("P3", "checked %d stores / %d loads in the tests' own bodies, but the "
                   "corpus' x86 columns declare %d / %d"
             % (own_st, own_ld, want_st, want_ld))
    if (want_st, want_ld) != (N_X86_STORES, N_X86_LOADS):
        fail("P3", "the corpus declares %d stores / %d loads, pinned at %d / %d"
             % (want_st, want_ld, N_X86_STORES, N_X86_LOADS))
    print("  %d tagged stores, %d buffered loads (+ %d / %d in co-run bodies)"
          % (own_st, own_ld, co_st, co_ld))


def phase4(tmp, good):
    print("== P4  machine code: the tested instructions survive gcc ==")
    if MC_TEST not in good:
        fail("P4", "%s did not emit, so no object could be built" % MC_TEST)
        return
    cpu_c = os.path.join(good[MC_TEST], MC_TEST + "_cpu.c")
    ok, why = objdump_ok(tmp, cpu_c, "P4")
    if ok:
        print("  %s: the test's own body contains store + mfence + load in program "
              "order" % MC_TEST)
    else:
        fail("P4", "%s: %s" % (MC_TEST, why))


def objdump_ok(tmp, cpu_c, phase):
    obj = os.path.join(tmp, "mc.o")
    r = run(["gcc", "-O2", "-c", cpu_c, "-I", os.path.dirname(cpu_c), "-o", obj])
    if r.returncode != 0:
        return False, "gcc refused it: %s" % r.stderr.strip()[:400]
    r = run(["objdump", "-d", obj])
    if r.returncode != 0:
        return False, "objdump failed: %s" % r.stderr.strip()[:200]
    # Slice from the symbol header to the next one.  Not `(.*?)\n\n': at -O2
    # het_run_P0 can be the LAST function in .text, with no blank line after it.
    parts = re.split(r"^[0-9a-f]+ <[^>]+>:$", r.stdout, flags=re.M)
    names = re.findall(r"^[0-9a-f]+ <([^>]+)>:$", r.stdout, flags=re.M)
    sym = next((x for x in MC_SYMS if x in names), None)
    if sym is None:
        return False, ("none of %r in the object (symbols: %r)" % (MC_SYMS, names))
    txt = parts[names.index(sym) + 1]
    seq = []
    for l in txt.splitlines():
        ins = l.split("\t")[-1].strip()
        if re.match(r"^mov\s+%r\w+,\(%r\w+\)$", ins):
            seq.append("store")
        elif re.match(r"^mov\s+\(%r\w+\),%r\w+$", ins):
            seq.append("load")
        elif ins.startswith("mfence"):
            seq.append("mfence")
    # store ; mfence ; load, with the buffer write (another store) after
    if seq[:3] != ["store", "mfence", "load"]:
        return False, "het_run_P0 machine code is %r, expected store,mfence,load first" % seq[:4]
    return True, ""


def emit_aarch64(out):
    os.makedirs(out, exist_ok=True)
    for t in AARCH64_TESTS:
        run([LITMUS7, "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", out, t + ".litmus"], cwd=HET_DIR)
    return out


# ------------------------------------------------------------------ P5 probes

# Four CPU columns hetCpuBodyA64 must refuse, none of them reachable from the
# corpus: its AArch64 vocabulary is MOV r,#k / STR / LDR / STLR / LDAPR /
# DMB SY|ST|LD, all at a bare [Xn].  emit-all.sh emitting the whole corpus is
# therefore the control that these four are refused for their instruction and NOT
# for their shape.  What --bite substitutes for each is stated in [bite].
#
# PROBE_A64_DEAD_VALUE kills the immediate with a load into the same register:
# the store's value is then not statically known, and the emitter must refuse to
# bind `1:r0=5' to it rather than decode it to the wrong mu.  PROBE_A64_MOV_REG
# kills it with a register-to-register MOV, which the classifier refuses
# outright.  PROBE_A64_LIVE_VALUE writes the same 5 with the immediate intact and
# must emit, which is what makes the refusal about value provenance and not about
# the literal 5.
PROBE_A64_DEAD_VALUE = """Het PROVA64
"probe: the store value is killed by a load into the same register"
{
0:X1=x;
0:X2=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#5   | r[relaxed,sys] r0 y ;
 LDR W0,[X1] | r[relaxed,sys] r1 x ;
 STR W0,[X2] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=5)
"""

PROBE_A64_MOV_REG = """Het PROVMOVA64
"probe: the store value is killed by a register-to-register MOV"
{
0:X1=x;
0:X2=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#5   | r[relaxed,sys] r0 y ;
 MOV W0,W3   | r[relaxed,sys] r1 x ;
 STR W0,[X2] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=5)
"""

PROBE_A64_LIVE_VALUE = """Het PROVLIVEA64
"probe: same condition, but the store value reaches the store"
{
0:X1=x;
0:X2=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#5   | r[relaxed,sys] r0 y ;
 STR W0,[X2] | r[relaxed,sys] r1 x ;
 MOV W3,#1   |                     ;
 STR W3,[X1] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=5)
"""

# A non-zero addressing offset: the operand shapes render `[%[g]]' whatever the
# MemExt says, so accepting this would test an access to x+0 while the .litmus
# says x+8.  The --bite variant is the same file with `[X1]'.
PROBE_A64_OFFSET = """Het OFFSETA64
"probe: a non-zero load offset"
{
0:X1=x;
0:X2=y;
}
 P0:cpu         | P1:gpu              ;
 MOV W3,#1      | r[relaxed,sys] r0 y ;
 STR W3,[X2]    | r[relaxed,sys] r1 x ;
 LDR X0,[X1,#8] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=1)
"""

# DSB is outside the het fence vocabulary: rendering it as `dmb sy' would put a
# mnemonic in the asm that the .litmus never named.  The --bite variant is the
# same file with `DMB SY'.
PROBE_A64_DSB = """Het DSBA64
"probe: a DSB on the CPU side"
{
0:X1=x;
0:X3=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#1   | r[relaxed,sys] r0 y ;
 STR W0,[X1] | f[sc,sys]           ;
 DSB SY      | r[relaxed,sys] r1 x ;
 MOV W2,#1   |                     ;
 STR W2,[X3] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=1 /\\ 1:r1=0)
"""


def phase5(tmp, out=None, litmus7=LITMUS7, dead_text=None, mov_text=None,
           live_text=None, offset_text=None, dsb_text=None):
    """The AArch64 lane: it emits aarch64, and it refuses what it cannot render.

    NOT the byte-diff.  The instrument that protects the emitted aarch64 lane is
    `hetlitmus/verify/emit-all.sh SNAP_x' run before and after a change, followed
    by `diff -r' over the two snapshots; that is inherently a two-revision
    comparison and cannot be a single-shot make target.  What this phase owns is
    the aarch64 lane's own evidence: no x86 mnemonic in an aarch64 body, and the
    four classifier refusals no corpus test can reach, against a control that
    must emit.
    """
    print("== P5  the AArch64 lane: emits aarch64, refuses what it cannot render ==")
    if out is None:
        out = emit_aarch64(os.path.join(tmp, "aarch64"))
    for t in AARCH64_TESTS:
        cpu_c = os.path.join(out, t, t + "_cpu.c")
        if not os.path.exists(cpu_c):
            fail("P5", "%s did not emit an aarch64 CPU file" % t)
            continue
        txt = open(cpu_c).read()
        if "hetCpuBodyX86" in txt:
            fail("P5", "%s: the aarch64 harness names the x86 body emitter" % t)
        if "movq " in txt:
            fail("P5", "%s: x86 mnemonics leaked into the aarch64 harness" % t)
        region = host_region(cpu_c)
        if not re.search(r'"(str|stlr|ldr|ldar|ldapr) %x\[', region):
            fail("P5", "%s: the aarch64 body carries no str/ldr %%x operand" % t)
    print("  %d aarch64 harnesses checked for str/ldr %%x and for x86 leakage"
          % len(AARCH64_TESTS))

    def refuses(label, text, want, note):
        st, blob, dirs = litmus_on(tmp, label, text, litmus7)
        if st != 3 or want not in blob or dirs:
            fail("P5", "%s: exit=%d dirs=%r, litmus7 said %r"
                 % (note, st, dirs, blob.strip().splitlines()[-1:]))
            return False
        return True

    if refuses("A64DEAD", dead_text or PROBE_A64_DEAD_VALUE,
               "no store writes 5 to y",
               "a store whose value a load killed still bound `1:r0=5'"):
        print("  value provenance: the killed-immediate store refuses (exit 3)")
    if refuses("A64MOV", mov_text or PROBE_A64_MOV_REG,
               "unsupported CPU instruction MOV W0,W3",
               "a register-to-register MOV over a live immediate was accepted"):
        print("  redefinition: `MOV W0,W3' refuses at classification")
    if refuses("A64OFF", offset_text or PROBE_A64_OFFSET,
               "unsupported CPU instruction LDR X0,[X1,#8]",
               "a non-zero addressing offset was accepted and read at +0"):
        print("  addressing: `LDR X0,[X1,#8]' refuses at classification")
    if refuses("A64DSB", dsb_text or PROBE_A64_DSB,
               "unsupported CPU instruction DSB SY",
               "a DSB was accepted and rendered as some other fence"):
        print("  fences: `DSB SY' refuses at classification")
    st, blob, dirs = litmus_on(tmp, "A64LIVE", live_text or PROBE_A64_LIVE_VALUE,
                               litmus7)
    if st != 0 or len(dirs) != 1:
        fail("P5", "the immediate-store twin did NOT emit, so the refusals above "
                   "prove nothing about provenance: exit=%d dirs=%r said %r"
             % (st, dirs, blob.strip().splitlines()[-1:]))
    else:
        print("  value provenance: the immediate-store twin emits (exit 0) -- the "
              "refusal is about provenance, not about the value")


# ------------------------------------------------------------------ P6 probes

# These two probes are about value provenance: where a stored value came from
# inside the CPU column.
#
# A CPU column whose store value is NOT statically known: the `$5' is killed by
# the load into the same register, so `movl %eax,(y)' writes whatever x held.
# hetCpuBodyX86.nodes_of must therefore report the value as unknown and the
# emitter must refuse to bind `1:r0=5' to it -- an immediate memo that a later
# write to the register does not invalidate records the store as writing 5, and
# this probe then emits, with `case 1: return 5;' in its _decode_value.
PROBE_KILLED_VALUE = """Het PROV-x86_64
"probe: the store value is killed by a load into the same register"
{
}
 P0:x86_64      | P1:gpu              ;
 movl $5,%%eax   | r[relaxed,sys] r0 y ;
 movl (x),%%eax  | r[relaxed,sys] r1 x ;
 movl %%eax,(y)  |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=%s)
"""

# The same shape with the value written directly: the emitter MUST emit this,
# which is what proves the refusal above is about value PROVENANCE and not
# simply about the literal 5 or about `movl %reg,(g)' being unsupported.
PROBE_LIVE_VALUE = """Het PROVLIVE-x86_64
"probe: same condition, but the store value is an immediate"
{
}
 P0:x86_64      | P1:gpu              ;
 movl $5,(y)    | r[relaxed,sys] r0 y ;
 movl $1,(x)    | r[relaxed,sys] r1 x ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=%s)
"""


def litmus_on(tmp, label, text, litmus7=LITMUS7):
    """Run litmus7 on [text]; return (exit, output, harness dirs left behind)."""
    src = os.path.join(tmp, label + ".litmus")
    open(src, "w").write(text)
    out = os.path.join(tmp, "out-" + label)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    r = run([litmus7, "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", out, src])
    left = [d for d in os.listdir(out) if os.path.isdir(os.path.join(out, d))]
    return r.returncode, (r.stdout + r.stderr), left


def phase6(tmp, corpus, prov_text=None, live_text=None, litmus7=LITMUS7):
    print("== P6  fail-closed: a refusal exits 3 and emits nothing ==")
    src = os.path.join(corpus, "MP-gc-sys-relaxed-x86_64.litmus")
    txt = open(src).read()
    # name a register no proc loads into: the condition can bind no read buffer
    bent = txt.replace("1:rax=", "1:rcx=")
    if bent == txt:
        fail("P6", "could not build a refusable test from %s" % src)
        return
    st, blob, left = litmus_on(tmp, "REFUSEME", bent, litmus7)
    if st != 3:
        fail("P6", "litmus7 exited %d on a test it cannot emit, expected 3" % st)
    if "HetLitmus REFUSED" not in blob:
        fail("P6", "no `HetLitmus REFUSED' marker on stderr; got %r" % blob.strip()[-200:])
    if left:
        fail("P6", "a refused test left harness directories behind: %r" % left)
    print("  litmus7 exit=%d, marker printed, %d directories left behind"
          % (st, len(left)))

    # --- value provenance, BOTH ways -----------------------------------------
    st, blob, dirs = litmus_on(tmp, "PROV", prov_text or (PROBE_KILLED_VALUE % 5), litmus7)
    if st != 3 or "no store writes 5 to y" not in blob:
        fail("P6", "a store whose value a load killed still bound `1:r0=5': "
                   "exit=%d dirs=%r, litmus7 said %r"
             % (st, dirs, blob.strip().splitlines()[-1:]))
    else:
        print("  value provenance: the killed-immediate store refuses (exit 3)")
    st, blob, dirs = litmus_on(tmp, "PROVLIVE", live_text or (PROBE_LIVE_VALUE % 5), litmus7)
    if st != 0 or len(dirs) != 1:
        fail("P6", "the immediate-store twin did NOT emit, so the refusal above "
                   "proves nothing about provenance: exit=%d dirs=%r said %r"
             % (st, dirs, blob.strip().splitlines()[-1:]))
    else:
        print("  value provenance: the immediate-store twin emits (exit 0) -- the "
              "refusal is about provenance, not about the value")


# -------------------------------------------------------------------- P7 co-run

def n_x86_procs(path):
    """How many x86_64 CPU columns this .litmus declares (its proc header line)."""
    for l in open(path):
        if ":x86_64" in l or ":gpu" in l:
            return l.count(":x86_64")
    return 0


def corun_probe(tmp, corpus):
    """A scratch copy of the generated corpus, and the rows that co-run a mu(T).

    The corpus generate-x86.sh produces ALREADY carries the re-keyed
    control-map-amd.csv the emitter reads, so nothing is rewritten here -- the
    probe set is read out of that same file.  Reading the committed map and
    re-keying it a second way would be a gate checking its own arithmetic.
    `self' and `none' are sentinels, not names.
    """
    scratch = os.path.join(tmp, "corun-src")
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.copytree(corpus, scratch)
    m = os.path.join(scratch, "control-map-amd.csv")
    if not os.path.exists(m):
        fail("P7", "the generated corpus carries no control-map-amd.csv -- the "
                   "emitter would co-run no control at all")
        return scratch, []
    rows = []
    for l in open(m):
        if l.startswith("#") or not l.strip():
            continue
        f = l.rstrip("\n").split(",")
        if len(f) != 6 or f[0] == "Test":
            continue
        if f[1] != "none":
            rows.append(f[0])
    return scratch, rows


def phase7(tmp, corpus, splitter=split_bodies, probe=corun_probe):
    print("== P7  co-run: T, mu(T) and the canary are EACH checked, none dropped ==")
    scratch, rows = probe(tmp, corpus)
    if len(rows) != N_CORUN_TESTS:
        fail("P7", "control-map-amd.csv names %d mu(T) rows, pinned at %d"
             % (len(rows), N_CORUN_TESTS))
    out = os.path.join(tmp, "corun-out")
    os.makedirs(out, exist_ok=True)
    bodies = collapsed = compared = 0
    for t in sorted(rows):
        src = os.path.join(scratch, t + ".litmus")
        if not os.path.exists(src):
            fail("P7", "%s has no x86 rendering" % t)
            continue
        r = run([LITMUS7, "-gpu-target", X86_TARGET, "-set-libdir", LIBDIR, "-o", out, src], cwd=scratch)
        cpu_c = os.path.join(out, t, t + "_cpu.c")
        if r.returncode != 0 or not (os.path.exists(cpu_c) and os.path.getsize(cpu_c)):
            fail("P7", "%s emitted no co-run harness (exit %d): %s"
                 % (t, r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1:]))
            continue
        recs, cm = resolve_bodies(scratch, t, cpu_c, splitter)
        if set(cm) != {"t_", "mu_", "can_"}:
            fail("P7", "%s: CO-RUN banner names %r, expected T + mu(T) + canary"
                 % (t, sorted(cm)))
            continue
        # The three INSTANCES must all be present.  Not one body each: a test with
        # two x86 CPU procs contributes two bodies per instance, so pinning the
        # multiset to exactly ["can_","mu_","t_"] would redden every WRC / WRC3 /
        # IRIW row.  What has to hold is that no INSTANCE went missing.
        got_prefixes = sorted(set(r[2] for r in recs))
        if got_prefixes != ["can_", "mu_", "t_"]:
            fail("P7", "%s: the host arm carries bodies %r, but the banner names "
                       "three instances -- a body was dropped"
                 % (t, [r[1] for r in recs]))
        bodies += len(recs)
        collapsed += len(recs) - len({r[0] for r in recs})
        c, _own = check_fidelity("P7", scratch, t, recs, cm)
        compared += c
        check_liveness("P7", t, recs)
    # DERIVED as well as pinned: the number of co-run bodies is the sum, over the
    # probe set, of the x86 CPU procs of T, of mu(T) and of the canary.  A pin on
    # its own goes stale silently the next time the lattice moves; a derivation on
    # its own cannot catch a corpus and a map that moved together.
    want = 0
    for t in sorted(rows):
        f = os.path.join(scratch, t + ".litmus")
        if not os.path.exists(f):
            continue
        mu = can = None
        for l in open(os.path.join(scratch, "control-map-amd.csv")):
            g = l.rstrip("\n").split(",")
            if len(g) == 6 and g[0] == t:
                mu, can = g[1], g[5]
                break
        for nm in (t, mu, can):
            if nm and nm not in ("-", "none", "self"):
                q = os.path.join(scratch, nm + ".litmus")
                if os.path.exists(q):
                    want += n_x86_procs(q)
    if bodies != want:
        fail("P7", "found %d co-run bodies, the corpus' own columns say %d"
             % (bodies, want))
    if bodies != N_CORUN_BODIES:
        fail("P7", "found %d co-run bodies, pinned at %d" % (bodies, N_CORUN_BODIES))
    if compared != bodies:
        fail("P7", "compared %d of the %d co-run bodies" % (compared, bodies))
    # Non-vacuity: this phase is only evidence about the (proc,fname) keying if
    # some harness really does carry >1 body at one proc index.
    if collapsed < 1:
        fail("P7", "no harness carried two bodies at one proc index, so this "
                   "phase says nothing about the keying it exists to protect")
    print("  %d co-run bodies over %d harnesses, each compared with its own test "
          "(%d would be LOST by proc-only keying)" % (bodies, len(rows), collapsed))


# ------------------------------------------------------------------------ bite

STUB_OMIT = r"""#!/usr/bin/env bash
# BITE stand-in: real litmus7, then delete one test's _cpu.c.  Exits 0 and
# prints nothing unusual, so ONLY emit-all.sh's omission detector can see it.
REAL=%s
VICTIM=%s
"$REAL" "$@" ; st=$?
outdir=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && outdir="$a"; prev="$a"; done
[ -n "$outdir" ] && rm -f "$outdir/$VICTIM/${VICTIM}_cpu.c"
exit $st
"""

# Two stand-in litmus7 binaries for P6's OWN three assertions (exit 3 / marker /
# nothing left behind).  Neither is reachable by doctoring a file: what they
# stand for is HetArch.refused ceasing to refuse, and a refusal leaving a partial
# harness, so the bite has to substitute the tool.
STUB_SWALLOW = r"""#!/usr/bin/env bash
# The PRE-P2b behaviour, reproduced: emit what you can, swallow the failure,
# print nothing on stderr, exit 0.  P6's exit-code AND marker checks must fire.
REAL=%s
"$REAL" "$@" >/dev/null 2>&1
exit 0
"""

STUB_LITTER = r"""#!/usr/bin/env bash
# Refuses correctly (exit 3 + marker) but leaves a half-built harness behind.
# ONLY P6's "directories left behind" check can see this.
REAL=%s
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
"$REAL" "$@" ; st=$?
if [ "$st" -ne 0 ] && [ -n "$out" ]; then mkdir -p "$out/LEFTOVER"; fi
exit $st
"""

STUB_REFUSE = r"""#!/usr/bin/env bash
# BITE stand-in: real litmus7, then print the refusal marker while EXITING 0.
# ONLY emit-all.sh's marker grep can see this.
REAL=%s
"$REAL" "$@" ; st=$?
case "$*" in *%s*) echo "HetLitmus REFUSED (het) injected: bite" >&2 ;; esac
exit $st
"""

# The per-lane stamp and word detectors (emit-all.sh's (c)).  Those assertions
# are about a harness that is complete and correct except for what it says it was
# built for, so no defect in litmus7 reaches them: the stand-in emits for real and
# then edits one file of one lane's victim, which is the ONLY way to hold the
# emitter still and move the artefact.  LANE is the OUTDIR subdir the lane writes
# to, so a stub fires on one lane and the others stay clean; the loop runs the
# edit once per render the victim actually has (exactly one, `-gpu-target'
# filters), and `$d' is there for the edits that are not on the render.
STUB_LANE = r"""#!/usr/bin/env bash
# BITE stand-in: real litmus7, then %s in the %s lane's %s.
REAL=%s
LANE=%s
VICTIM=%s
"$REAL" "$@" ; st=$?
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && [ "$(basename "$out")" = "$LANE" ] || exit $st
d="$out/$VICTIM"
[ -d "$d" ] || exit $st
for r in "$d/$VICTIM.cu" "$d/$VICTIM.hip"; do
  [ -f "$r" ] || continue
  %s
done
exit $st
"""


def lane_stub(what, lane, where, victim, body):
    return STUB_LANE % (what, lane, where, LITMUS7, lane, victim, body)


def emit_all_bite(tmp, label, script, want, lane=None, tests=None):
    """Drive emit-all.sh under a stand-in litmus7, over [lane] and [tests] only.

    [lane] is the OUTDIR subdir the stub corrupts something in; [tests] are that
    lane's own corpus names -- the victim plus one neighbour, so the per-test
    loop the detector lives in is entered more than once.  Each injection is
    caught inside that loop or by the per-lane brandscan, both of which run
    before the census, so the census expectation moving to the selected count
    cannot mask one.  Neither given = the whole corpus.  The PARTIAL SNAPSHOT
    banner is required exactly one way round, so a selection silently ignored
    and a whole run labelling itself a subset are both refusals.
    """
    path = os.path.join(tmp, "litmus7-" + label)
    open(path, "w").write(script)
    os.chmod(path, 0o755)
    e = dict(os.environ)
    e["HET_LITMUS7"] = path
    e["HET_LANES_ONLY"] = lane or ""
    e["HET_TESTS_ONLY"] = " ".join(tests or ())
    out = os.path.join(tmp, "ea-" + label)
    shutil.rmtree(out, ignore_errors=True)
    r = subprocess.run(["bash", EMIT_ALL, out], capture_output=True, text=True, env=e)
    blob = r.stdout + r.stderr
    partial = "PARTIAL SNAPSHOT" in blob
    if (lane or tests) and not partial:
        print("  *** SEAM IGNORED [%s]: emit-all.sh announced no partial snapshot, "
              "so the selection above was not honoured" % label)
        return False
    if not (lane or tests) and partial:
        print("  *** PARTIAL WHEN WHOLE [%s]: emit-all.sh announced a partial "
              "snapshot for a run that selected nothing" % label)
        return False
    if r.returncode == 0:
        print("  *** DID NOT BITE [%s]: emit-all.sh reported success" % label)
        return False
    if want not in blob:
        print("  *** WRONG REASON [%s]: expected %r, got:\n%s" % (label, want, blob[-500:]))
        return False
    line = [l for l in blob.splitlines() if l.startswith("FAIL:")]
    print("  bite %-8s -> %s" % (label, line[0] if line else blob.strip()[-160:]))
    return True


def expect_red(label, thunk, must_mention=None):
    """Run [thunk]; require it to have added at least one failure."""
    fails.clear()
    try:
        thunk()
    except SystemExit as e:
        fails.append(("*", "SystemExit: %s" % e))
    if not fails:
        print("  *** DID NOT BITE [%s]" % label)
        fails.clear()
        return False
    if must_mention is not None and not any(must_mention in m for _p, m in fails):
        print("  *** WRONG REASON [%s]: expected %r, got %r"
              % (label, must_mention, [m for _p, m in fails][:3]))
        fails.clear()
        return False
    print("  bite %-14s -> %s" % (label, fails[0][1]))
    fails.clear()
    return True


def bite(tmp, corpus, good):
    print("===== X86BODYCHECK BITE =====")
    ok = True

    # --- P1: CORRUPTION of a rendering -> that test must stop emitting -------
    scratch = os.path.join(tmp, "bite-corpus")
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.copytree(corpus, scratch)
    victim = "MP-gc-sys-relaxed-x86_64"
    p = os.path.join(scratch, victim + ".litmus")
    t = open(p).read()
    open(p, "w").write(t.replace("1:rax=", "1:rcx="))
    _PARSE_CACHE.pop(p, None)
    g2, b2 = emit_corpus(os.path.join(tmp, "b1"), scratch)
    ok &= expect_red("P1/corrupt", lambda: phase1(scratch, g2, b2), victim)

    # --- P1: OMISSION of a rendering -> the census pin must fire -------------
    os.remove(os.path.join(scratch, victim + ".litmus"))
    g3, b3 = emit_corpus(os.path.join(tmp, "b1b"), scratch)
    ok &= expect_red("P1/omit", lambda: phase1(scratch, g3, b3),
                     "produced 410 renderings")

    # --- P1: a harness that never reached `bad' at all -----------------------
    short = dict(good)
    short.pop(victim, None)
    ok &= expect_red("P1/short", lambda: phase1(corpus, short, []),
                     "of the %d renderings emitted" % N_X86)

    # --- P2: the STUB body itself -- the shape this gate exists to catch -----
    d = good[victim]
    src = os.path.join(d, victim + "_cpu.c")
    stubbed = os.path.join(tmp, "stub")
    shutil.rmtree(stubbed, ignore_errors=True)
    shutil.copytree(d, os.path.join(stubbed, victim))
    txt = open(src).read()
    # replay emit_stub's output verbatim into the host arm
    stub = ("void het_run_P1(uint64_t *x, uint64_t *y, uint64_t *bufP1_0, "
            "uint64_t *bufP1_1, int _n) {\n"
            "  /* x86_64 het CPU body: compile-only stub */\n"
            "  (void)_n;\n  (void)x;\n  (void)y;\n"
            "  (void)bufP1_0;\n  (void)bufP1_1;\n}\n")
    host = host_region(src)
    open(os.path.join(stubbed, victim, victim + "_cpu.c"), "w").write(
        txt.replace(host, stub))
    ok &= expect_red("P2/stub",
                     lambda: phase2(corpus, {victim: os.path.join(stubbed, victim)}),
                     "STUB body")

    # --- P2: OMISSION of one instruction from the emitted body ---------------
    dropped = os.path.join(tmp, "drop")
    shutil.rmtree(dropped, ignore_errors=True)
    shutil.copytree(d, os.path.join(dropped, victim))
    f = os.path.join(dropped, victim, victim + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r'^\s*"movq \(%\[\w+\]\),%\[_t1\]\\n"\n', "", t, count=1, flags=re.M)
    if t2 == t:
        print("  *** VACUOUS BITE [P2/drop]: no load line to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        ok &= expect_red("P2/drop",
                         lambda: phase2(corpus, {victim: os.path.join(dropped, victim)}),
                         "but %s P1 says" % victim)

    # --- P2: VACUITY -- a run that compared nothing must FAIL, not pass ------
    ok &= expect_red("P2/vacuous", lambda: phase2(corpus, {}),
                     "covered 0 of the %d x86 procs" % N_X86_PROCS)

    # --- P3: CORRUPTION of the tag -> a constant store ------------------------
    const = os.path.join(tmp, "const")
    shutil.rmtree(const, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(const, MC_TEST))
    f = os.path.join(const, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r"uint64_t _v0 = \(uint64_t\)\d+ \* \(_n \+ 1\) \+ \d+;",
                "uint64_t _v0 = (uint64_t)0 * (_n + 1) + 0;", t, count=1)
    if t2 == t:
        print("  *** VACUOUS BITE [P3/const]: no tag to flatten")
        ok = False
    else:
        open(f, "w").write(t2)
        ok &= expect_red("P3/const",
                         lambda: phase3(corpus, {MC_TEST: os.path.join(const, MC_TEST)}),
                         "a constant store")

    # --- P3: OMISSION of the buffer write -------------------------------------
    nobuf = os.path.join(tmp, "nobuf")
    shutil.rmtree(nobuf, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(nobuf, MC_TEST))
    f = os.path.join(nobuf, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r"^\s*\w+\[_n\] = _t0;\n", "", t, count=1, flags=re.M)
    if t2 == t:
        print("  *** VACUOUS BITE [P3/nobuf]: no buffer write to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        ok &= expect_red("P3/nobuf",
                         lambda: phase3(corpus, {MC_TEST: os.path.join(nobuf, MC_TEST)}),
                         "never recorded into a buffer")

    # --- P3: VACUITY ----------------------------------------------------------
    ok &= expect_red("P3/vacuous", lambda: phase3(corpus, {}),
                     "checked 0 stores / 0 loads")

    # --- P4: OMISSION of the fence from the compiled body ---------------------
    nofence = os.path.join(tmp, "nofence")
    shutil.rmtree(nofence, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(nofence, MC_TEST))
    f = os.path.join(nofence, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = t.replace('    "mfence\\n"\n', "", 1)
    if t2 == t:
        print("  *** VACUOUS BITE [P4/nofence]: no mfence to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        good2, why = objdump_ok(tmp, f, "P4")
        if good2:
            print("  *** DID NOT BITE [P4/nofence]: a fenceless object passed P4")
            ok = False
        else:
            print("  bite P4/nofence    -> %s" % why)

    # --- P4: CORRUPTION -- the fence moved BEFORE the store -------------------
    # Nothing is missing; only the order is wrong.  A phase that merely counted
    # mnemonics would still pass, which is why P4 compares a SEQUENCE.
    reord = os.path.join(tmp, "reorder")
    shutil.rmtree(reord, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(reord, MC_TEST))
    f = os.path.join(reord, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    mst = re.search(r'^    "movq %\[_v0\],\(%\[\w+\]\)\\n"\n', t, flags=re.M)
    if mst is None or '    "mfence\\n"\n' not in t:
        print("  *** VACUOUS BITE [P4/reorder]: no store+mfence pair to swap")
        ok = False
    else:
        t2 = t.replace('    "mfence\\n"\n', "", 1)
        t2 = t2.replace(mst.group(0), '    "mfence\\n"\n' + mst.group(0), 1)
        open(f, "w").write(t2)
        good2, why = objdump_ok(tmp, f, "P4")
        if good2:
            print("  *** DID NOT BITE [P4/reorder]: a reordered object passed P4")
            ok = False
        else:
            print("  bite P4/reorder    -> %s" % why)

    # --- P5: CORRUPTION -- an x86 mnemonic inside an aarch64 harness ----------
    a64 = emit_aarch64(os.path.join(tmp, "a64bite"))
    t0 = AARCH64_TESTS[0]
    f = os.path.join(a64, t0, t0 + "_cpu.c")
    t = open(f).read()
    t2 = t.replace('"str %x[', '"movq %x[')
    if t2 == t:
        print("  *** VACUOUS BITE [P5/leak]: no str %x[ to replace")
        ok = False
    else:
        open(f, "w").write(t2)
        ok &= expect_red("P5/leak", lambda: phase5(tmp, out=a64), "leaked")

    # --- P5: OMISSION -- an aarch64 harness that never emitted ----------------
    a64b = emit_aarch64(os.path.join(tmp, "a64omit"))
    os.remove(os.path.join(a64b, t0, t0 + "_cpu.c"))
    ok &= expect_red("P5/omit", lambda: phase5(tmp, out=a64b),
                     "did not emit an aarch64 CPU file")

    # --- P5: the four AArch64 refusals, each fed a test that behaves the other
    # way.  The refusal probes get a variant that MUST emit and the emission
    # control gets one that refuses; for the offset and the DSB the substitute
    # differs in ONE token, so the bite doubles as the evidence that the
    # refusal is about that token and not about the probe's shape.  [out] is a
    # clean emission, or the smoke above would redden these on its own.
    a64c = emit_aarch64(os.path.join(tmp, "a64probe"))
    ok &= expect_red("P5/a1-dead",
                     lambda: phase5(tmp, out=a64c, dead_text=PROBE_A64_LIVE_VALUE),
                     "still bound `1:r0=5'")
    ok &= expect_red("P5/a1-mov",
                     lambda: phase5(tmp, out=a64c, mov_text=PROBE_A64_LIVE_VALUE),
                     "register-to-register MOV over a live immediate")
    ok &= expect_red("P5/a1-live",
                     lambda: phase5(tmp, out=a64c, live_text=PROBE_A64_DEAD_VALUE),
                     "did NOT emit")
    ok &= expect_red("P5/a2",
                     lambda: phase5(tmp, out=a64c,
                                    offset_text=PROBE_A64_OFFSET.replace(
                                        "[X1,#8]", "[X1]")),
                     "non-zero addressing offset")
    ok &= expect_red("P5/a3",
                     lambda: phase5(tmp, out=a64c,
                                    dsb_text=PROBE_A64_DSB.replace(
                                        "DSB SY", "DMB SY")),
                     "a DSB was accepted")

    # --- P6: its OWN three assertions, via a stand-in litmus7 ----------------
    def stub(label, script):
        p = os.path.join(tmp, "l7-" + label)
        open(p, "w").write(script)
        os.chmod(p, 0o755)
        return p

    ok &= expect_red("P6/swallow",
                     lambda: phase6(tmp, corpus,
                                    litmus7=stub("swallow", STUB_SWALLOW % LITMUS7)),
                     "expected 3")
    ok &= expect_red("P6/litter",
                     lambda: phase6(tmp, corpus,
                                    litmus7=stub("litter", STUB_LITTER % LITMUS7)),
                     "left harness directories behind")

    # --- P6: value provenance, both directions -------------------------------
    # Feed each probe the OTHER's expectation: the refusal check must redden on
    # a test that emits, and the emission check on a test that refuses.
    ok &= expect_red("P6/prov-live",
                     lambda: phase6(tmp, corpus, prov_text=PROBE_LIVE_VALUE % 5),
                     "still bound `1:r0=5'")
    ok &= expect_red("P6/prov-dead",
                     lambda: phase6(tmp, corpus, live_text=PROBE_KILLED_VALUE % 5),
                     "did NOT emit")

    # --- P7: the proc-keyed splitter, which drops two bodies of every three --
    ok &= expect_red("P7/proc-keyed",
                     lambda: phase7(tmp, corpus, splitter=split_bodies_proc_keyed),
                     "a body was dropped")

    # --- P7: OMISSION -- one co-run harness never probed at all --------------
    ok &= expect_red(
        "P7/omit",
        lambda: phase7(os.path.join(tmp, "p7short"), corpus,
                       probe=lambda t2, c2: (lambda s, r: (s, r[:-1]))(*corun_probe(t2, c2))),
        "pinned at %d" % N_CORUN_TESTS)

    # --- P7: the co-run FIDELITY arm, on the mu body specifically ------------
    # P7 passing is only evidence if a wrong mu/canary body would be caught, so
    # break one and require P7's comparator to name THAT body and THAT test.
    scr, rows = corun_probe(os.path.join(tmp, "p7fid"), corpus)
    tvic = sorted(rows)[0]
    o7 = os.path.join(tmp, "p7fid", "out")
    os.makedirs(o7, exist_ok=True)
    run([LITMUS7, "-gpu-target", X86_TARGET, "-set-libdir", LIBDIR, "-o", o7, os.path.join(scr, tvic + ".litmus")],
        cwd=scr)
    fv = os.path.join(o7, tvic, tvic + "_cpu.c")
    tx = open(fv).read()
    # drop the FIRST asm line of the mu body only
    mu_at = tx.index("void het_run_mu_")
    cut = re.search(r'^\s*"movq [^\n]*\\n"\n', tx[mu_at:], flags=re.M)
    if cut is None:
        print("  *** VACUOUS BITE [P7/mu-drop]: no asm line in the mu body")
        ok = False
    else:
        open(fv, "w").write(tx[:mu_at] + tx[mu_at:].replace(cut.group(0), "", 1))
        recs, cm = resolve_bodies(scr, tvic, fv)
        ok &= expect_red("P7/mu-drop",
                         lambda: check_fidelity("P7", scr, tvic, recs, cm),
                         "het_run_mu_")

    # --- P7: OMISSION of the CO-RUN banner -> bodies become unattributable ---
    tx = open(fv).read()
    open(fv, "w").write(re.sub(r"^\s+(T|mu\(T\)|canary)\s+\S+\s+K=\d+\s*$", "  /* */",
                               tx, flags=re.M))
    recs, cm = resolve_bodies(scr, tvic, fv)
    ok &= expect_red("P7/banner",
                     lambda: check_fidelity("P7", scr, tvic, recs, cm),
                     "cannot attribute it to a test")

    # --- P6: emit-all.sh's refusal and omission detectors, each alone ---------
    ok &= emit_all_bite(tmp, "omit", STUB_OMIT % (LITMUS7, "MP-gc-cta-fence"),
                        "emitted no MP-gc-cta-fence/MP-gc-cta-fence_cpu.c",
                        "het-cuda", ["MP-gc-cta-fence", "MP-cg-cta-fence"])
    # emit-all.sh names the LANE it was refused in (`-gpu-target cuda'), because
    # a refusal that reached only one vendor is the interesting half of the news.
    ok &= emit_all_bite(tmp, "refuse", STUB_REFUSE % (LITMUS7, "MP-cg-cta-acquire"),
                        "REFUSED MP-cg-cta-acquire.litmus",
                        "het-cuda", ["MP-cg-cta-acquire", "MP-cg-cta-fence"])
    # ...and its per-lane MIS-TAGGING assertions, one victim each.  This gate owns
    # the emit-all stand-in rig, which is why they live here and not beside the
    # table they protect (litmus/hetMachine.ml, cram machine-pairs.t).
    for label, stub, want, lane, tests in [
        # (1) the PAIR NAME, exactly once.  Twice is the interesting direction: a
        # count of "at least one" passes a render carrying two pairs' names.
        ("pair-twice",
         lane_stub("stamp HET_PAIR_NAME twice", "het-cuda", "render",
                   "MP-cg-cta-acquire", r"""sed -i '/^#define HET_PAIR_NAME/p' "$r" """),
         "does not stamp HET_PAIR_NAME \"(AArch64, cuda)\" exactly once",
         "het-cuda", ["MP-cg-cta-acquire", "MP-cg-cta-fence"]),
        # (2) the MACHINE DEFINE BLOCK, compared whole: one line short of the row
        # this lane is entitled to, which no per-line grep for "a machine define"
        # would notice.
        ("machine-short",
         lane_stub("drop HET_LLC_MB", "het-cuda", "render", "MP-cg-cta-fence",
                   r"""sed -i '/^#define HET_LLC_MB /d' "$r" """),
         "stamps the wrong machine",
         "het-cuda", ["MP-cg-cta-fence", "MP-cg-cta-acquire"]),
        # (3) the NO-MACHINE NOTE: without it a registered pair that is
        # deliberately nameless and a pair in no row at all read identically.
        ("no-note",
         lane_stub("delete the no-machine note", "het-x86-cuda", "render",
                   "MP-cg-cta-acquire-x86_64",
                   r"""sed -i '/No machine defines: no machine row backs/d' "$r" """),
         "names no machine and does not say WHY",
         "het-x86-cuda", ["MP-cg-cta-acquire-x86_64", "MP-cg-cta-fence-x86_64"]),
        # (4) a machine word in a nameless lane's README -- prose, which no check
        # over #defines or over the render can see.
        ("brand-readme",
         lane_stub("brand the README target line", "het-x86-cuda", "README.md",
                   "MP-cg-cta-fence-x86_64",
                   r"""sed -i 's/^Target: NVIDIA CUDA\.$/Target: NVIDIA GH200 (CUDA)./' \
       "$d/README.md" """),
         "names 'GH200' (the gh200 row's word; this lane is entitled to none)",
         "het-x86-cuda", ["MP-cg-cta-fence-x86_64", "MP-cg-cta-acquire-x86_64"]),
        # (5) ...and one SPLIT ACROSS TWO ADJACENT LITERALS on two lines, which is
        # the shape a grep of `fprintf(' lines cannot see.  This one runs
        # unseamed: it is caught in the last het lane's brandscan, so reaching it
        # walks every het lane's whole corpus through the per-test assertions and
        # the earlier brandscans, which nothing else in the suite does.
        ("brand-split",
         lane_stub("plant a two-line printed literal", "het-hip", "render",
                   "MP-cg-cta-acquire",
                   r"""grep -q _planted "$r" || printf 'static void _planted(void){ fprintf(stderr, "the MI300A "\n"APU is idle\\n"); }\n' >> "$r" """),
         "names 'MI300A' (the mi300a row's word; this lane is entitled to none)",
         None, None),
    ]:
        ok &= emit_all_bite(tmp, label, stub, want, lane, tests)

    fails.clear()
    print()
    if ok:
        print("X86BODYCHECK BITE OK (every injection reddened its own phase)")
        return 0
    print("X86BODYCHECK BITE FAILED")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove each phase FAILS on corruption and on omission")
    a = ap.parse_args()

    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("x86bodycheck: %s not built (run 'make all')" % LITMUS7)

    tmp = tempfile.mkdtemp(prefix="x86bodycheck.")
    try:
        corpus = os.path.join(tmp, "corpus")
        r = run(["bash", GEN_X86, corpus])
        if r.returncode != 0:
            raise SystemExit("x86bodycheck: generate-x86.sh failed:\n" + r.stderr)
        print(r.stdout.strip())
        good, bad = emit_corpus(tmp, corpus)

        if a.bite:
            return bite(tmp, corpus, good)

        print("===== X86BODYCHECK: is the x86-64 CPU thread of a het harness REAL? =====")
        phase1(corpus, good, bad)
        phase2(corpus, good)
        phase3(corpus, good)
        phase4(tmp, good)
        phase5(tmp)
        phase6(tmp, corpus)
        phase7(tmp, corpus)
        print("=" * 70)
        if fails:
            print("X86BODYCHECK FAILED: %d assertion(s)" % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            return 1
        print("X86BODYCHECK: PASS (%d/%d x86 renderings emit a real tagged body)"
              % (len(good), N_X86))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
