"""The pinned corpus censuses and the built corpus trees, in one home
(census.sh mirrors the pins for shell, paths.sh the trees).

GPU_ONLY, HET and HET_X86 are the .litmus counts of the built gpu-only, het
and het-x86_64 trees (GPU_DIR, HET_DIR, X86_DIR under CORPUS: grid.py's
directory targets, hetlitmus/tests/dune); COVER the tests
verify/faithful-cover.txt lists.  corpus-gate.sh proves the counts against
the trees and the two homes against each other.
"""

import os

CORPUS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "..", "_build", "default",
                                       "hetlitmus", "tests"))
HET_DIR = os.path.join(CORPUS, "het")
X86_DIR = os.path.join(CORPUS, "het-x86_64")
GPU_DIR = os.path.join(CORPUS, "gpu-only")

GPU_ONLY = 372
HET = 2743
HET_X86 = 1616
COVER = 76
