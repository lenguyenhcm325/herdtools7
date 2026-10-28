# HetLitmus paths, for sourcing.
HETL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HETL/.." && pwd)"
BIN="$REPO/_build/install/default/bin"
LITMUS7="$BIN/litmus7"
LIBDIR="$REPO/litmus/libdir"      # litmus7's libdir
HERDLIB="$REPO/herd/libdir"       # herd7's (and diy's) libdir
CORPUS="$REPO/_build/default/hetlitmus/tests"   # the built corpus trees
HET_CORPUS="$CORPUS/het"
X86_CORPUS="$CORPUS/het-x86_64"
GPU_CORPUS="$CORPUS/gpu-only"
