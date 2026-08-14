#!/usr/bin/env python3
"""
x86fixturecheck.py -- is `hetlitmus/tests/het-x86' still what its generators emit?

That directory is five hand-cut committed files -- four `.litmus' renderings plus
a one-row-per-test extract of `control-map-amd.csv' -- and the ONLY committed
route to the (x86_64, hip) pair: the real x86 corpus is generated on demand and
never committed, and a cram sandbox has no `hetgen7' on $PATH.  Nothing else
compares the fixture against its generators, and what moves it --
`generate-x86.sh', `tests/het/control-map-amd.csv' -- moves often.  A stale
fixture breaks no gate; it makes every gate that reads it test a configuration
nothing ships.

  litmus-bytes  run generate-x86.sh into a temp dir and `cmp' each committed
                .litmus against its generated twin, byte for byte
  map-rows      each committed map row must equal the row the generated
                (re-keyed) map carries -- fields, order and text

One generator run serves both phases, since only the fixture side is ever
perturbed, and neither phase needs a GPU: the gate lives in the CUDA-free
`hetlitmus-test' umbrella.  `--bite' perturbs one committed .litmus body and one
committed map row in a COPY of the fixture and requires the matching phase to
redden naming the file.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")
FIXTURE = os.path.join(ROOT, "hetlitmus", "tests", "het-x86")
GEN_X86 = os.path.join(HET_DIR, "generate-x86.sh")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# The tests the fixture carries.  Named here rather than globbed so that a file
# deleted from the fixture is a failure and NOT an empty loop.
# S-cg-sys-relaxed is here because the S row names it as mu(T) and the emitter
# refuses a control it cannot resolve: a fixture that names one has to ship it.
TESTS = ["MP-cg-sys-relaxed-x86_64",
         "MP-cg-sys-acqrel-2s-x86_64",
         "S-cg-sys-fence-x86_64",
         "S-cg-sys-relaxed-x86_64"]
MAPS = ["control-map-amd.csv"]

fails = []


def fail(phase, msg):
    fails.append((phase, msg))


def _env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def generate(tmp):
    """The real generator, into a scratch dir.  Its output is the ground truth."""
    out = os.path.join(tmp, "corpus")
    r = subprocess.run(["bash", GEN_X86, out], cwd=ROOT, env=_env(),
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("x86fixturecheck: generate-x86.sh failed:\n" + r.stderr)
    return out


def rows_of(path):
    """test name -> the map line, verbatim.  Comments and the header are skipped:
    the fixture rewrites those on purpose (they say it is an extract)."""
    out = {}
    with open(path) as fh:
        for line in fh:
            s = line.rstrip("\n")
            if not s or s.lstrip().startswith("#"):
                continue
            key = s.split(",", 1)[0]
            if key in ("Test", "Litmus"):
                continue
            out[key] = s
    return out


def phase1(corpus, fixture, quiet=False):
    say = (lambda *_: None) if quiet else print
    say("===== litmus-bytes: the committed .litmus files, byte for byte =====")
    n = 0
    for t in TESTS:
        have = os.path.join(fixture, t + ".litmus")
        want = os.path.join(corpus, t + ".litmus")
        if not os.path.exists(have):
            fail("litmus-bytes", "%s.litmus is missing from the fixture" % t)
            continue
        if not os.path.exists(want):
            fail("litmus-bytes", "generate-x86.sh no longer emits %s.litmus -- the fixture "
                       "names a test its generator does not produce" % t)
            continue
        n += 1
        if open(have, "rb").read() != open(want, "rb").read():
            fail("litmus-bytes", "%s.litmus DIFFERS from generate-x86.sh's rendering" % t)
        else:
            say("      %-32s identical" % (t + ".litmus"))
    if n != len(TESTS):
        fail("litmus-bytes", "compared %d of %d fixtures -- a comparison that did not happen "
                   "is not a pass" % (n, len(TESTS)))
    return n


def phase2(corpus, fixture, quiet=False):
    say = (lambda *_: None) if quiet else print
    say("\n===== map-rows: the committed rows, against the re-keyed originals =====")
    n = 0
    for m in MAPS:
        have_p, want_p = os.path.join(fixture, m), os.path.join(corpus, m)
        if not os.path.exists(have_p):
            fail("map-rows", "%s is missing from the fixture" % m)
            continue
        have, want = rows_of(have_p), rows_of(want_p)
        extra = sorted(set(have) - set(TESTS))
        if extra:
            fail("map-rows", "%s carries row(s) for %s, which the fixture does not ship "
                       "a .litmus for" % (m, ", ".join(extra)))
        for t in TESTS:
            if t not in have:
                fail("map-rows", "%s has no row for %s" % (m, t))
                continue
            if t not in want:
                fail("map-rows", "%s: the generated map has no row for %s -- the fixture "
                           "row is keyed on a name the map no longer carries"
                           % (m, t))
                continue
            n += 1
            if have[t] != want[t]:
                fail("map-rows", "%s row for %s DIFFERS from the generated map's:\n"
                           "        committed: %s\n        generated: %s"
                     % (m, t, have[t], want[t]))
            else:
                say("      %-24s %-28s row identical" % (m, t))
    need = len(MAPS) * len(TESTS)
    if n != need:
        fail("map-rows", "compared %d of %d map rows -- a comparison that did not happen "
                   "is not a pass" % (n, need))
    return n


def run_once(fixture, corpus, quiet=False):
    del fails[:]
    n1 = phase1(corpus, fixture, quiet)
    n2 = phase2(corpus, fixture, quiet)
    if fails:
        if not quiet:
            print("\nX86FIXTURECHECK FAILED: %d problem(s)." % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            print("\ntests/het-x86 is an EXTRACT of its generators, never an "
                  "independent judgement.  Re-cut it from a fresh "
                  "generate-x86.sh run; do not edit it to match.")
        return 1
    if not quiet:
        print("\nX86FIXTURECHECK: PASS (%d .litmus byte-identical, %d map rows "
              "verbatim)" % (n1, n2))
    return 0


def bite(corpus):
    """Each injection is into a COPY of the fixture, so the committed one is NEVER
    touched, and each must redden its own phase naming the file it broke."""
    print("===== BITE: does this gate see a stale fixture? =====")
    bad = 0
    injections = [
        ("litmus-bytes", "a .litmus body edited (one register renamed)",
         TESTS[0] + ".litmus",
         lambda s: s.replace("r0", "r9", 1),
         TESTS[0] + ".litmus DIFFERS"),
        ("map-rows", "a control-map row's canary re-pointed",
         "control-map-amd.csv",
         lambda s: s.replace(",self", ",MP-cg-sys-acqrel-2s-x86_64", 1),
         "control-map-amd.csv row for " + TESTS[0] + " DIFFERS"),
        ("map-rows", "a control-map row's mu(T) re-pointed off the floor",
         "control-map-amd.csv",
         lambda s: s.replace(TESTS[2] + ",S-cg-sys-relaxed-x86_64",
                             TESTS[2] + ",S-cg-sys-acqrel-2s-x86_64", 1),
         "control-map-amd.csv row for " + TESTS[2] + " DIFFERS"),
    ]
    for phase, what, fname, mutate, want in injections:
        tmp = tempfile.mkdtemp(prefix="x86fixturebite.")
        try:
            copy = os.path.join(tmp, "het-x86")
            shutil.copytree(FIXTURE, copy)
            p = os.path.join(copy, fname)
            src = open(p).read()
            new = mutate(src)
            if new == src:
                print("  *** [%s] %s: the injection changed NOTHING -- this bite "
                      "cannot prove anything" % (phase, what))
                bad += 1
                continue
            open(p, "w").write(new)
            rc = run_once(copy, corpus, quiet=True)
            hit = any(ph == phase and want in m for ph, m in fails)
            if rc == 0 or not hit:
                print("  *** [%s] %s: gate rc=%d, %s -- it did not catch this"
                      % (phase, what, rc,
                         "no matching failure" if not hit else "no failure"))
                bad += 1
            else:
                print("      [%s] RED on %s" % (phase, what))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    # ... and green again on the untouched fixture, so "red" was the injection.
    rc = run_once(FIXTURE, corpus, quiet=True)
    if rc != 0:
        print("  *** the committed fixture itself is RED -- the bites above prove "
              "nothing about the injections")
        bad += 1
    else:
        print("      the committed fixture: GREEN")
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED in its own phase; restored GREEN)"
          % len(injections))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove the gate reddens on a stale fixture")
    a = ap.parse_args()
    if not os.access(os.path.join(BIN, "hetgen7"), os.X_OK):
        raise SystemExit("x86fixturecheck: hetgen7 not built (run 'make all')")
    tmp = tempfile.mkdtemp(prefix="x86fixturecheck.")
    try:
        corpus = generate(tmp)
        return bite(corpus) if a.bite else run_once(FIXTURE, corpus)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
