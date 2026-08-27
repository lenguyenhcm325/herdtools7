#!/usr/bin/env python3
"""runcheck.py -- the two device-facing checks with no other home: the AMD probe
under stand-in vendor tools, and what a het harness PRINTS on this box's GPU.

  probe-hip.sh       its four exit paths, each with the probe_status it stamps.
  --characterize-hw  one harness emitted, built through hetlitmus/build.sh and
                     run on the GPU; a sighting, a null and a discarded run are
                     each an arm of its printout.
A miss means an arch, a refusal or a printed arm was decided with nothing
recording it.
"""
import argparse
import atexit
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HETL = os.path.join(ROOT, "hetlitmus")
PROBE_HIP = os.path.join(HETL, "probe-hip.sh")
BUILD_SH = os.path.join(HETL, "build.sh")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# The committed (x86_64, *) fixture: a generate-x86.sh run, cut verbatim and
# kept that way by corpus-gate.sh's het-x86 label.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
X86_TESTS = ["CoRR-cg-sys-fence-2s-x86_64", "MP-cg-sys-acqrel-2s-x86_64",
             "MP-cg-sys-relaxed-x86_64", "S-cg-sys-fence-x86_64"]
# The (AArch64, *) lane is the committed het corpus, and the cut below is copied
# out of it at run time: it is the corpus minus rows, not a second fixture.
AARCH64_DIR = os.path.join(HETL, "tests", "het")
AARCH64_TESTS = ["MP-cg-sys-acqrel-2s", "MP-cg-sys-acquire", "MP-cg-sys-relaxed",
                 "S-cg-sys-fence", "S-cg-sys-relaxed"]


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def write_exec(path, text):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, 0o755)
    return path


# ---------------------------------------------------------------------------
# The fixture this host can drive: the emitted link target refuses a foreign
# host, so a corpus whose CPU column is not this box's drives nothing here.
# ---------------------------------------------------------------------------
_CUT = None


def aarch64_corpus():
    """The AArch64 cut, copied verbatim out of the committed corpus on demand."""
    global _CUT
    if _CUT is None:
        d = tempfile.mkdtemp(prefix="runcheck-aarch64.")
        atexit.register(shutil.rmtree, d, True)
        for t in AARCH64_TESTS:
            shutil.copy(os.path.join(AARCH64_DIR, t + ".litmus"), d)
        _CUT = d
    return _CUT


def fixture():
    """{isa, key, dir, tests} for this host, or None."""
    m = platform.machine()
    if m == "x86_64":
        fx = {"isa": "x86_64", "key": "X86_64", "dir": X86_DIR,
              "tests": X86_TESTS}
    elif m in ("aarch64", "arm64"):
        fx = {"isa": "aarch64", "key": "AArch64", "dir": aarch64_corpus(),
              "tests": AARCH64_TESTS}
    else:
        return None
    return fx


def host_fixture():
    """The fixture, or a fail-closed exit: a host with no corpus of its own CPU
    lane drives nothing here, and a pass over nothing is the failure mode."""
    fx = fixture()
    if fx is None:
        raise SystemExit("runcheck: no committed corpus carries a %s CPU column,"
                         " so there is no chain to drive on this host."
                         % platform.machine())
    return fx


# ---------------------------------------------------------------------------
# probe-hip.sh, under stand-in vendor tools.  No AMD device is reachable from
# this tree, so its device answers are checked here or nowhere.
# ---------------------------------------------------------------------------
def _hip_tools(tmp, gfx):
    d = os.path.join(tmp, "hipbin-" + ("-".join(gfx) or "none"))
    os.makedirs(d, exist_ok=True)
    write_exec(os.path.join(d, "hipcc"), "#!/bin/sh\necho 'HIP version: 6.0.0'\n")
    write_exec(os.path.join(d, "amdgpu-arch"),
               "#!/bin/sh\n" + "".join("echo %s\n" % g for g in gfx))
    write_exec(os.path.join(d, "rocminfo"),
               "#!/bin/sh\n" + "".join("echo '  Name:  %s'\n" % g for g in gfx))
    return d


def phase6_probe_hip(probe, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck6.")
    try:
        cases = [("no hipcc", None, "NO_TOOLCHAIN", 2),
                 ("no gfx agent", [], "NO_DEVICE", 2),
                 ("one gfx agent", ["gfx942"], "HOST_ONLY", 0),
                 ("two gfx agents", ["gfx942", "gfx90a"], "AMBIGUOUS_DEVICE", 2)]
        for name, gfx, want, rc in cases:
            res = os.path.join(tmp, "res-" + name.replace(" ", "_"))
            env = dict(os.environ)
            env["RESULTS"] = res
            if gfx is None:
                env["HIPCC"] = os.path.join(tmp, "no-such-hipcc")
            else:
                bindir = _hip_tools(tmp, gfx)
                env["PATH"] = bindir + os.pathsep + os.environ["PATH"]
                env["HIPCC"] = os.path.join(bindir, "hipcc")
            r = sh(["sh", probe], env=env)
            txt = os.path.join(res, "probe.txt")
            got = ""
            if os.path.exists(txt):
                got = "".join(l for l in open(txt) if l.startswith("probe_status="))
            if r.returncode != rc:
                bad.append("[%s] probe-hip exited %d, want %d: %s"
                           % (name, r.returncode, rc, r.stderr.strip()[-200:]))
            elif want not in got:
                bad.append("[%s] probe.txt says %r, want probe_status=%s"
                           % (name, got.strip(), want))
            elif not quiet:
                print("      %-14s rc=%d  probe_status=%s" % (name, rc, want))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# --characterize-hw -- a harness built, run on the GPU and read off its
# printout: a sighting, a null and a discarded run are each an arm.
# ---------------------------------------------------------------------------

# The relaxed MP row of this host's fixture: a harness whose CPU column is
# foreign does not link here.
CH_STEM = "MP-cg-sys-relaxed"
CH_SEED_TRIES = 12
# The printout's shape does not depend on how many runs stand behind it, so the
# runs are curtailed and the timeout is what a curtailed run may take.
CH_RUNS = "2"
CH_RUN_TIMEOUT = 600
# The host rendezvous cap this run takes, shortened to keep a run inside its
# timeout.  The device cap is left alone: shortening it makes a clean run rare.
CH_CAP_CPU = "4096"


def _ch_env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def ch_pick():
    """(test, corpus dir, pair) for this host: the emitted link target refuses a
    foreign CPU lane, so the corpus has to be this box's own."""
    fx = host_fixture()
    for t in fx["tests"]:
        if t == CH_STEM or t.startswith(CH_STEM + "-"):
            return t, fx["dir"], "(%s, cuda)" % fx["key"]
    raise SystemExit("runcheck --characterize-hw: the %s fixture carries no %s "
                     "row to build" % (fx["isa"], CH_STEM))


def ch_arch():
    """sm_XY of the device this will actually run on, NEVER a hardcoded sm_90: a
    cubin built for another architecture does not load."""
    if os.environ.get("CUDA_ARCH"):
        return os.environ["CUDA_ARCH"]
    r = sh(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"])
    caps = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or not caps:
        return None
    return "sm_" + caps[0].replace(".", "")


def ch_emit(tmp, test, cdir):
    """Emit `test' out of `cdir' and return its harness dir."""
    out = tempfile.mkdtemp(dir=tmp)
    r = sh(["litmus7", "-gpu-target", "cuda", "-set-libdir",
            os.path.join(ROOT, "litmus", "libdir"), "-o", out,
            os.path.join(cdir, test + ".litmus")], cwd=ROOT, env=_ch_env())
    d = os.path.join(out, test)
    if r.returncode != 0 or not os.path.exists(os.path.join(d, test + ".cu")):
        raise SystemExit("runcheck --characterize-hw: litmus7 emitted no "
                         "harness:\n%s" % r.stderr)
    return d


def ch_build(d, arch):
    """The real build step over the dir `d' was emitted into, so what this mode
    runs is the binary hetlitmus/build.sh produces and no other."""
    emit = os.path.dirname(d)
    env = _ch_env()
    env["RESULTS"] = os.path.join(os.path.dirname(emit), "build-results")
    r = sh(["bash", BUILD_SH, emit, "--arch", arch], env=env)
    if r.returncode != 0 or not os.access(os.path.join(d, os.path.basename(d)),
                                          os.X_OK):
        raise SystemExit("runcheck --characterize-hw: build.sh --arch %s failed "
                         "(rc=%d):\n%s"
                         % (arch, r.returncode, (r.stdout + r.stderr)[-2000:]))


def ch_env(**kw):
    env = dict(os.environ)
    env["HET_ALLOC"] = env.get("HET_ALLOC", "pinned")
    env["HET_RUNS_MAX"] = env.get("HET_RUNS_MAX", CH_RUNS)
    env["HET_CAP_CPU"] = env.get("HET_CAP_CPU", CH_CAP_CPU)
    env.update(kw)
    return env


def ch_run_until_sighting(d, test, quiet=False):
    """Run with fresh seeds until the outcome fires once, or the seeds run out --
    the last run either way; returns (text, k, R, obs, tries)."""
    env = ch_env()
    last = None
    for i in range(1, CH_SEED_TRIES + 1):
        env["HET_SEED"] = str(1000 + i)
        try:
            r = subprocess.run([os.path.join(d, test)], cwd=d, env=env,
                               capture_output=True, text=True,
                               timeout=CH_RUN_TIMEOUT)
        except subprocess.TimeoutExpired:
            # Every rendezvous wait is capped in polls, so a run that does not
            # finish is a launch or driver fault, not a slow box.
            raise SystemExit("runcheck --characterize-hw: the run did not "
                             "finish in %ds under HET_ALLOC=%s."
                             % (CH_RUN_TIMEOUT, env["HET_ALLOC"]))
        text = r.stdout + "\n" + r.stderr
        m = re.search(r"^HetStats \S+ cpu_only=\d+ obs=(\S+) R=(\d+) usable=(\d+) "
                      r"k=(\d+) ", r.stdout, re.M)
        if not m:
            raise SystemExit("runcheck --characterize-hw: the run printed no "
                             "HetStats line (rc=%d)\n%s" % (r.returncode,
                                                            text[-2000:]))
        obs, R, k = m.group(1), int(m.group(2)), int(m.group(4))
        last = (text, k, R, obs, i)
        if k > 0:
            return last
        if "COLD-INVALID" in text:
            if not quiet:
                print("      seed %d: the run was DISCARDED, which no fresh seed "
                      "undoes -- read as the arm this box printed" % (1000 + i))
            return last
        if not quiet:
            print("      seed %d: k=0, retrying (a sighting carries more "
                  "sentences to read)" % (1000 + i))
    return last


# What a run that saw the outcome must print, and what a run that did not must
# print instead.  The arms are exclusive and one of them always applies.
def ch_observed(pair):
    return [": OBSERVED", "Report it as what %s exhibited" % pair]


CH_NULL = ["NOT OBSERVED under this effort",
           "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
           "CHARACTERIZATION, NEVER VALIDATION",
           "effort:",
           # The effort a null reports is the iterations it read back, so the
           # number is on the line beside the sentence.
           "scored="]
# What a run every cell of which was DISCARDED must print instead: it is read as
# the arm it is, and what it may NOT do is read as reach.
CH_COLD = ["DISCARD this null -- the harness was not demonstrably hot",
           "the weak outcome was NOT observed",
           "VOID -- not one of",
           "scored="]
# The second run: caps of one poll, where the rendezvous cannot complete.
CH_CAP1 = ["COLD-INVALID",
           "DISCARD this null -- the harness was not demonstrably hot",
           "A timed-out rendezvous is a DEAD PARTNER"]
CH_CLASSES = ("Never", "Sometimes", "Always", "VOID")


def ch_check(text, k, obs, test, pair, quiet=False):
    """Every assertion is on the PRINTOUT.  Returns a list of failures."""
    bad = []
    say = (lambda *_: None) if quiet else print

    def must(tag, frag):
        if frag not in text:
            bad.append("[%s] the printout never says %r" % (tag, frag))
        else:
            say("      [%s] %s" % (tag, frag[:88]))

    must("A", "HetVerdict %s run=" % test)

    # Which arm this box printed.  A sighting outranks everything; otherwise a
    # printout whose every run was discarded is the COLD arm.
    classes = set(re.findall(r"^HetVerdict \S+(?: CPU-ONLY)? run=\d+: (\S+)$",
                             text, re.M))
    if k > 0:
        arm, frags = "OBSERVED", ch_observed(pair)
    elif classes == {"COLD-INVALID"}:
        arm, frags = "COLD-INVALID", CH_COLD
    else:
        arm, frags = "NOT-OBSERVED", CH_NULL
    say("      [D] the %s arm (%s)" % (arm, ", ".join(sorted(classes)) or "none"))
    for frag in frags:
        must("D", frag)

    if obs not in CH_CLASSES:
        bad.append("[F] obs=%s is not one of %s" % (obs, list(CH_CLASSES)))
    else:
        say("      [F] obs=%s on k=%d" % (obs, k))
    return bad


def ch_run_once(d, test, pair, quiet=False):
    got = ch_run_until_sighting(d, test, quiet=quiet)
    if got is None:
        return 1, ["the harness produced no run at all"]
    text, k, R, obs, tries = got
    if k == 0 and not quiet:
        print("      the outcome never fired in %d x %d runs, so a non-sighting "
              "arm is what this device printed" % (tries, R))
    bad = ch_check(text, k, obs, test, pair, quiet=quiet)
    return (1 if bad else 0), bad


def ch_cap_run(d, test, quiet=False):
    """The rendezvous disqualifier, driven by a run-time knob: under caps of ONE
    poll nearly every iteration is discarded and the run must be thrown away."""
    say = (lambda *_: None) if quiet else print
    env = ch_env(HET_CAP_CPU="1", HET_CAP_GPU="1", HET_RUNS_MAX="1",
                 HET_SEED="1")
    try:
        r = subprocess.run([os.path.join(d, test)], cwd=d, env=env,
                           capture_output=True, text=True, timeout=CH_RUN_TIMEOUT)
    except subprocess.TimeoutExpired:
        return ["[R] the caps=1 run STALLED after %ds -- a one-poll cap is the "
                "one wait that cannot stall" % CH_RUN_TIMEOUT]
    text = r.stdout + "\n" + r.stderr
    bad = []
    for frag in CH_CAP1:
        if frag not in text:
            bad.append("[R] under HET_CAP_CPU=1 HET_CAP_GPU=1 the printout never "
                       "says %r -- a rendezvous that cannot complete must be "
                       "discarded naming the dead mechanism" % frag)
        else:
            say("      [R] %s" % frag[:88])
    if "NOT OBSERVED under this effort" in text:
        bad.append("[R] under HET_CAP_CPU=1 HET_CAP_GPU=1 the printout reports "
                   "reach: a run whose two sides never met is not a "
                   "non-observation")
    return bad


def ch_probe(tmp, test, cdir, pair, arch, quiet=False):
    d = ch_emit(tmp, test, cdir)
    ch_build(d, arch)
    rc, bad = ch_run_once(d, test, pair, quiet=quiet)
    if not quiet:
        print("===== the same binary under caps of one poll =====")
    bad = bad + ch_cap_run(d, test, quiet=quiet)
    return (1 if bad else 0), bad


def characterize_hw():
    test, cdir, pair = ch_pick()
    arch = ch_arch()
    if arch is None:
        # NOT a skip: this mode builds and runs a harness on the device, and
        # skipping it quietly is how a check stops checking.
        raise SystemExit(
            "runcheck --characterize-hw: no CUDA device is visible (nvidia-smi "
            "reported none), so there is nothing it can assert.")
    print("runcheck --characterize-hw: %s, %s, %s, HET_ALLOC=%s"
          % (test, pair, arch, os.environ.get("HET_ALLOC", "pinned")))
    tmp = tempfile.mkdtemp(prefix="runcheck-chhw.")
    try:
        print("===== the printout of a run =====")
        bad = ch_probe(tmp, test, cdir, pair, arch)[1]
        if bad:
            print("\nCHARACTERIZE-HW FAILED: %d problem(s)." % len(bad))
            for m in bad:
                print("  %s" % m)
            return 1
        print("\nCHARACTERIZE-HW: PASS (the printout names the test, reads as "
              "the arm the run took and names no voucher; a rendezvous that "
              "cannot complete is DISCARDED naming itself)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


PHASES = [
    ("probe-hip.sh's exit paths", lambda q: phase6_probe_hip(PROBE_HIP, q)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--characterize-hw", action="store_true",
                    help="build a harness and read what it PRINTS "
                         "(toolchain lane)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    host_fixture()
    if a.characterize_hw:
        return characterize_hw()

    rc = 0
    for name, phase in PHASES:
        print("\n===== %s =====" % name)
        failures = phase(a.quiet)
        for m in failures:
            print("  *** %s" % m)
        rc |= 1 if failures else 0
    if rc:
        print("\nRUNCHECK FAILED.")
        return 1
    print("\nRUNCHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
