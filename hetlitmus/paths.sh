# HetLitmus repo layout, for sourcing.  It self-locates from its own path, so a
# caller at any depth gets the same answers whatever its cwd is:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/paths.sh"      # a script in hetlitmus/
#   . "$(dirname "$0")/../paths.sh"                  # in hetlitmus/verify/ or cats/
#   . ../../paths.sh                                 # after cd'ing into a test dir
#
# PATH is deliberately NOT touched here: the nvcc-lane scripts need
# /usr/local/cuda/bin ahead of $BIN and the .cat runners need neither, so each
# caller exports the search path it wants.
HETL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HETL/.." && pwd)"
BIN="$REPO/_build/install/default/bin"
LITMUS7="$BIN/litmus7"
LIBDIR="$REPO/litmus/libdir"      # litmus7's libdir
HERDLIB="$REPO/herd/libdir"       # herd7's (and diy's) libdir
