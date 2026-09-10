"""The pinned corpus censuses and the built corpus trees, in one home
(census.sh mirrors the pins for shell, paths.sh the trees).

GPU_ONLY, HET and HET_X86 are the .litmus counts of the built gpu-only, het
and het-x86_64 trees (GPU_DIR, HET_DIR, X86_DIR under CORPUS: grid.py's
directory targets, hetlitmus/tests/dune); COVER the tests
verify/faithful-cover.txt lists.  Every sweep asserts its own home's pins
against the same trees.
"""

import os

CORPUS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "..", "_build", "default",
                                       "hetlitmus", "tests"))
HET_DIR = os.path.join(CORPUS, "het")
X86_DIR = os.path.join(CORPUS, "het-x86_64")
GPU_DIR = os.path.join(CORPUS, "gpu-only")

GPU_ONLY = 744
HET = 6695
HET_X86 = 3900
COVER = 76


class GateError(Exception):
    """A sweep that cannot run at all."""


def corpus_files(d, label, expect):
    """The .litmus files of one tree, its census asserted BEFORE the sweep:
    `pass == total' is vacuously true over a tree that is not there."""
    if not os.path.isdir(d):
        raise GateError("the %s corpus directory %s does not exist" % (label, d))
    files = sorted(f for f in os.listdir(d) if f.endswith(".litmus"))
    if len(files) != expect:
        raise GateError(
            "the %s corpus %s holds %d .litmus, expected %d -- a short corpus "
            "is refused, never swept as if it were the whole one"
            % (label, d, len(files), expect))
    return [os.path.join(d, f) for f in files]
