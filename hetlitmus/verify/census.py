"""The pinned corpus censuses and the built corpus trees; census.sh mirrors the pins."""

import os

CORPUS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "..", "_build", "default",
                                       "hetlitmus", "tests"))
HET_DIR = os.path.join(CORPUS, "het")
X86_DIR = os.path.join(CORPUS, "het-x86_64")
GPU_DIR = os.path.join(CORPUS, "gpu-only")

GPU_ONLY = 771
HET = 6923
HET_X86 = 4056
COVER = 77


class GateError(Exception):
    """A sweep that cannot run at all."""


def corpus_files(d, label, expect):
    if not os.path.isdir(d):
        raise GateError("the %s corpus directory %s does not exist" % (label, d))
    files = sorted(f for f in os.listdir(d) if f.endswith(".litmus"))
    if len(files) != expect:
        raise GateError(
            "the %s corpus %s holds %d .litmus, expected %d -- a short corpus "
            "is refused, never swept as if it were the whole one"
            % (label, d, len(files), expect))
    return [os.path.join(d, f) for f in files]
