#!/usr/bin/env python3
"""
noraclerun.py -- what a harness with NO CONTROL MAP actually PRINTS, on a device.

The (x86_64, cuda) pair is registered without a control map and is the pair the
dev box is: every runtime bite in this tree executes one of its harnesses.  Such
a harness reads no positive-control map, so nothing in it co-runs and nothing
marks any row a canary -- and that is a state the whole verdict/statistics stack
has to describe correctly without ever having a control to lean on.  Every other gate on
that stack drives it from SYNTHETIC records or from emitted text; this one builds
a harness, runs it on the GPU, and reads the printout, which is the only artefact
a result is ever read off.

What it asserts, all on the printout of a real run:

  A the record is stamped and the printout names the PAIR it was built for
  B no self-canary sentence anywhere -- nothing here is the Layer-B canary, and
    the map that would have said so was never read
  C the no-control-map sentence IS there, and calls the missing bound an
    omission rather than a construction
  D the run reaches OBSERVED and reports itself against the PAIR NAME
  E MATCH / MISMATCH / any retired verdict word is unreachable: this harness
    carries no prediction to agree or disagree with
  F no Grace / Hopper / NVLink / C2C / GH200 anywhere in stdout or stderr
  G the observation class is not ALWAYS on a run that fired in k < R runs (where
    nothing co-runs, "usable" is defined by firing, so R is the denominator)

MEASURED DEFECT this closes: on this exact pair the statistics layer printed "it
IS the Layer-B canary (control-map.csv says `self')" and "NO BOUND -- by
construction, not by omission", and the report line named a string that was not a
target name at all.  Every clause was false, and the verdict layer on the SAME
run printed UNINTERPRETABLE.

The outcome is stochastic (C, D and G need one sighting), so the run is repeated
with fresh seeds until one fires, up to SEED_TRIES.  A pair that cannot fire the
most observable het shape in that many runs is itself the finding, and the gate
says so rather than passing vacuously.

`--bite' rewrites the emitted het_verdict.h -- the harness's own copy, never the
source -- rebuilds and re-runs, and requires each injection to redden.
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
X86_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het-x86")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

TEST = "MP-cg-sys-relaxed-x86_64"
PAIR = "(X86_64, cuda)"
SEED_TRIES = 12
RUN_TIMEOUT = 90     # a healthy run is ~3 s; past this it is stalled

# The harness is emitted from the x86 fixture because that is where an x86-64 CPU
# column lives in the committed tree.
VENDOR_RE = re.compile(r"nvlink|grace|hopper|c2c|gh200", re.I)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def cuda_arch():
    """sm_XY of the device this will actually run on -- never a hardcoded GH200
    sm_90, which does not load here."""
    if os.environ.get("CUDA_ARCH"):
        return os.environ["CUDA_ARCH"]
    r = sh(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"])
    caps = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or not caps:
        return None
    return "sm_" + caps[0].replace(".", "")


def emit(tmp):
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    r = sh(["litmus7", "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", out,
            os.path.join(X86_DIR, TEST + ".litmus")], cwd=ROOT, env=_env())
    d = os.path.join(out, TEST)
    if r.returncode != 0 or not os.path.exists(os.path.join(d, TEST + ".cu")):
        raise SystemExit("noraclerun: litmus7 emitted no harness:\n" + r.stderr)
    return d


def build(d, arch):
    env = dict(os.environ)
    env["CUDA_ARCH"] = arch
    r = sh(["sh", "comp.sh", "cuda-link"], cwd=d, env=env)
    if r.returncode != 0:
        raise SystemExit("noraclerun: comp.sh cuda-link failed:\n"
                         + (r.stdout + r.stderr)[-2000:])


def run_until_sighting(d, quiet=False):
    """Run with fresh seeds until the outcome fires once.  Returns (text, k, R,
    obs, tries) -- text is stdout+stderr, which is the whole printout a reader
    sees."""
    env = dict(os.environ)
    env["HET_ALLOC"] = env.get("HET_ALLOC", "pinned")
    last = None
    hangs = 0
    for i in range(1, SEED_TRIES + 1):
        env["HET_SEED"] = str(1000 + i)
        try:
            r = subprocess.run([os.path.join(d, TEST)], cwd=d, env=env,
                               capture_output=True, text=True, timeout=RUN_TIMEOUT)
        except subprocess.TimeoutExpired:
            # HET_ALLOC=pinned on a device without host-native atomics can lose
            # barrier increments and stall -- the harness's own banner says so.
            # A stalled run is a property of THIS box, not of the printout, so it
            # is retried; only an all-stall is reported, and never as a pass.
            hangs += 1
            if not quiet:
                print("      seed %d: STALLED at the rendezvous after %ds, retrying"
                      % (1000 + i, RUN_TIMEOUT))
            if hangs >= SEED_TRIES:
                raise SystemExit(
                    "noraclerun: every one of %d runs stalled at the rendezvous.  "
                    "HET_ALLOC=%s cannot make a system-scope atomic barrier on this "
                    "device; re-run with an allocator that can."
                    % (hangs, env["HET_ALLOC"]))
            continue
        text = r.stdout + "\n" + r.stderr
        m = re.search(r"^HetStats \S+ cpu_only=\d+ obs=(\S+) R=(\d+) usable=\d+ "
                      r"k=(\d+) ", r.stdout, re.M)
        if not m:
            raise SystemExit("noraclerun: the run printed no HetStats line "
                             "(rc=%d)\n%s" % (r.returncode, text[-2000:]))
        obs, R, k = m.group(1), int(m.group(2)), int(m.group(3))
        last = (text, k, R, obs, i)
        if k > 0:
            return last
        if not quiet:
            print("      seed %d: k=0, retrying (C/D/G need one sighting)"
                  % (1000 + i))
    return last


def check(text, k, R, obs, quiet=False):
    """Every assertion is on the PRINTOUT.  Returns a list of failures."""
    bad = []
    say = (lambda *_: None) if quiet else print

    def must(tag, frag):
        if frag not in text:
            bad.append("[%s] the printout never says %r" % (tag, frag))
        else:
            say("      [%s] %s" % (tag, frag[:96]))

    def never(tag, frag, why):
        if frag in text:
            bad.append("[%s] the printout says %r -- %s" % (tag, frag, why))

    must("A", "HetVerdict %s [" % TEST)
    must("A", 'Report it as what %s exhibited' % PAIR)

    never("B", "IS the Layer-B canary",
          "no control map was read for this pair, so nothing here marks any row "
          "the canary")
    never("B", "control map names it as its own canary",
          "the same claim, one clause over")

    must("C", "NO POSITIVE-CONTROL MAP WAS READ for %s" % PAIR)
    must("C", "It gets NO BOUND, and that is an OMISSION, not a construction")
    never("C", "NO BOUND -- by construction, not by omission",
          "the bound is missing because the bootstrap map does not exist yet, "
          "which is an omission")

    must("D", ": OBSERVED")
    never("D", "the target this harness was tagged for",
          "that sentence once substituted a disclosure blob for the pair name")

    for w in ("MISMATCH", "MATCH", "ORACLE_", "Disallowed", "REFUT"):
        if w in text:
            bad.append("[E] the printout contains %r -- this harness carries no "
                       "prediction to agree or disagree with" % w)
    say("      [E] no MATCH / MISMATCH / retired verdict word anywhere")

    hits = sorted(set(m.group(0) for m in VENDOR_RE.finditer(text)))
    if hits:
        bad.append("[F] the printout names %s -- this run was on neither part"
                   % ", ".join(hits))
    else:
        say("      [F] no Grace / Hopper / NVLink / C2C / GH200 in stdout or stderr")

    if 0 < k < R and obs == "Always":
        bad.append("[G] obs=Always on k=%d of R=%d: the denominator collapsed onto "
                   "the runs that fired, which is every usable cell here" % (k, R))
    elif 0 < k < R:
        say("      [G] obs=%s on k=%d of R=%d (denominator is R, not the usable "
            "count)" % (obs, k, R))
    else:
        bad.append("[G] k=%d of R=%d -- no sighting, so the class carries no "
                   "information about the denominator" % (k, R))
    return bad


def run_once(d, quiet=False):
    got = run_until_sighting(d, quiet=quiet)
    if got is None:
        return 1, ["the harness produced no run at all"]
    text, k, R, obs, tries = got
    if k == 0:
        return 1, ["the outcome never fired in %d x %d runs -- C, D and G cannot "
                   "be read, and a NO-ORACLE pair that cannot fire the most "
                   "observable het shape is itself the finding" % (tries, R)]
    bad = check(text, k, R, obs, quiet=quiet)
    return (1 if bad else 0), bad


# --- the injections.  Each rewrites ONE file of the emitted harness (never the
# source tree), and names the file, because the two halves of the printout come
# from two places: the verdict/statistics prose from het_verdict.h and the
# driver's own WARNINGS -- where the Grace/Hopper defect was first measured --
# from the render itself. ---
INJECTIONS = [
    ("B/C", "het_verdict.h", "the no-control-map note reverted to the self-canary sentence",
     lambda s: s.replace(
         "  NOTE: this row CO-RUNS NO CONTROL because NO POSITIVE-CONTROL MAP WAS ",
         "  NOTE: this row CO-RUNS NO CONTROL -- it IS the Layer-B canary.  WAS ", 1)),
    ("C", "het_verdict.h", "the bound called structural again",
     lambda s: s.replace("It gets NO BOUND, and that is an OMISSION, not a "
                         "construction",
                         "It gets NO BOUND -- by construction, not by omission", 1)),
    ("A/D", "het_verdict.h", "the report sentence names a constant instead of the pair",
     lambda s: s.replace(
         "      HET_PAIR_NAME, HET_LINK_NAME);",
         '      "the target this harness was tagged for", HET_LINK_NAME);', 1)),
    ("F", TEST + ".cu", "the driver's noise warning names the GH200 halves again",
     lambda s: s.replace("the host half of the host-device interconnect noise",
                         "the Grace half of the NVLink-C2C noise")),
]


def bite(tmp, arch):
    print("===== BITE: does this gate read the PRINTOUT? =====")
    bad = 0
    for tag, fname, what, mutate in INJECTIONS:
        d = emit(tmp)
        hdr = os.path.join(d, fname)
        src = open(hdr).read()
        new = mutate(src)
        if new == src:
            print("  *** [%s] %s: the injection changed NOTHING -- this bite "
                  "proves nothing" % (tag, what))
            bad += 1
            shutil.rmtree(os.path.dirname(d), ignore_errors=True)
            continue
        open(hdr, "w").write(new)
        build(d, arch)
        rc, why = run_once(d, quiet=True)
        if rc == 0:
            print("  *** [%s] %s: the gate stayed GREEN" % (tag, what))
            bad += 1
        else:
            print("      [%s] RED on %s" % (tag, what))
            print("          %s" % why[0][:150])
        shutil.rmtree(os.path.dirname(d), ignore_errors=True)
    # ... and the untouched harness must be green, or "red" meant nothing.
    d = emit(tmp)
    build(d, arch)
    rc, why = run_once(d, quiet=True)
    if rc != 0:
        print("  *** the UNTOUCHED harness is RED (%s) -- the injections above "
              "prove nothing" % (why[0][:150] if why else "?"))
        bad += 1
    else:
        print("      the untouched harness: GREEN")
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED; restored GREEN)" % len(INJECTIONS))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove the gate reddens on a corrupted sentence")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("noraclerun: litmus7 not built (run 'make all')")
    arch = cuda_arch()
    if arch is None:
        # NOT a skip.  This is the one gate in the tree that runs a harness on a
        # device; skipping it quietly is how a check stops checking.
        raise SystemExit(
            "noraclerun: no CUDA device is visible (nvidia-smi reported none).\n"
            "  This gate BUILDS AND RUNS a registered-NO-ORACLE harness and reads "
            "its printout;\n  there is nothing it can assert without a device, so "
            "it fails rather than passing vacuously.")
    print("noraclerun: %s harness, %s, HET_ALLOC=%s"
          % (PAIR, arch, os.environ.get("HET_ALLOC", "pinned")))

    tmp = tempfile.mkdtemp(prefix="noraclerun.")
    try:
        if a.bite:
            return bite(tmp, arch)
        print("===== the printout of a registered-NO-ORACLE run =====")
        d = emit(tmp)
        build(d, arch)
        rc, bad = run_once(d)
        if rc:
            print("\nNORACLERUN FAILED: %d problem(s)." % len(bad))
            for m in bad:
                print("  %s" % m)
            return 1
        print("\nNORACLERUN: PASS (a pair with no control map characterizes, "
              "names itself, claims no canary and no machine, and adjudicates "
              "nothing)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
