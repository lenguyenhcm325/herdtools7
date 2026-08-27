"""The pinned corpus censuses, in one home (census.sh mirrors them for shell).

GPU_ONLY and HET are the .litmus counts of hetlitmus/tests/gpu-only and
hetlitmus/tests/het (either CPU rendering of the het grid); SYNTHETIC the
carriers hipsrccheck.py writes for the annotations no corpus test holds; COVER
the tests verify/faithful-cover.txt lists.  corpus-gate.sh proves GPU_ONLY and
HET against the tree and the two homes against each other.
"""

GPU_ONLY = 173
HET = 471
SYNTHETIC = 1
COVER = 48
