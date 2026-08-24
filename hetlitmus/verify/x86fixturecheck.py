#!/usr/bin/env python3
"""
x86fixturecheck.py -- is `hetlitmus/tests/het-x86' still what its generator emits?

That directory is hand-cut committed files -- the `.litmus' renderings named in
TESTS -- and the ONLY committed route to the (x86_64, hip) pair: the real x86
corpus is generated on demand and never committed, and a cram sandbox has no
`hetgen7' on $PATH.  Nothing else compares the fixture against its generator,
and what moves it -- `generate-x86.sh' -- moves often.  A stale fixture breaks
no gate; it makes every gate that reads it test a configuration nothing ships.

  litmus-bytes  run generate-x86.sh into a temp dir and `cmp' each committed
                .litmus against its generated twin, byte for byte

The check needs no GPU: the gate lives in the CUDA-free `hetlitmus-test'
umbrella.
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
# deleted from the fixture is a failure and NOT an empty loop.  Why each of them
# is committed: hetlitmus/tests/het-x86/README.md.
TESTS = ["MP-cg-sys-relaxed-x86_64",
         "MP-cg-sys-acqrel-2s-x86_64",
         "S-cg-sys-fence-x86_64",
         "CoRR-cg-sys-fence-2s-x86_64"]

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


def litmus_bytes(corpus, fixture):
    print("===== litmus-bytes: the committed .litmus files, byte for byte =====")
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
            print("      %-32s identical" % (t + ".litmus"))
    if n != len(TESTS):
        fail("litmus-bytes", "compared %d of %d fixtures -- a comparison that did not happen "
                   "is not a pass" % (n, len(TESTS)))
    return n


def run_once(fixture, corpus):
    n = litmus_bytes(corpus, fixture)
    if fails:
        print("\nX86FIXTURECHECK FAILED: %d problem(s)." % len(fails))
        for ph, m in fails:
            print("  [%s] %s" % (ph, m))
        print("\ntests/het-x86 is an EXTRACT of its generator, never an "
              "independent judgement.  Re-cut it from a fresh "
              "generate-x86.sh run; do not edit it to match.")
        return 1
    print("\nX86FIXTURECHECK: PASS (%d .litmus byte-identical)" % n)
    return 0


def main():
    argparse.ArgumentParser().parse_args()   # takes no options; reject stray args
    if not os.access(os.path.join(BIN, "hetgen7"), os.X_OK):
        raise SystemExit("x86fixturecheck: hetgen7 not built (run 'make all')")
    tmp = tempfile.mkdtemp(prefix="x86fixturecheck.")
    try:
        corpus = generate(tmp)
        return run_once(FIXTURE, corpus)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
