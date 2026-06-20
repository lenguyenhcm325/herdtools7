#!/usr/bin/env bash
# HetLitmus Tier-1: emit CUDA (.cu) litmus kernels from the GPU-only LISA corpus.
#
# Drives the litmus7 binary (built on branch hetlitmus-tier1) over every
# tests/gpu-only/*.litmus test; litmus7's `LISA arch branch parses the scoped
# Bell IR and CudaLang emits one .cu per test (cuda::atomic_ref scoped atomics,
# CTA layout from the scope tree).  See litmus/CudaLang.ml + litmus/top_litmus.ml.
#
# Out of scope here (Tasks 8/9): nvcc compilation and hardware execution.
#
# Usage:  ./emit-cuda.sh [OUTDIR]      (default OUTDIR=./cuda-out)
set -euo pipefail

# Resolve repo root from this script's location (hetlitmus/ lives at repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

LITMUS7="$REPO/_build/install/default/bin/litmus7"
LIBDIR="$REPO/litmus/libdir"
TESTS="$HERE/tests/gpu-only"
OUTDIR="${1:-$HERE/cuda-out}"

if [ ! -x "$LITMUS7" ]; then
  echo "error: litmus7 not built at $LITMUS7 (run 'make all' in $REPO)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
echo "Emitting CUDA from $TESTS -> $OUTDIR"
for t in "$TESTS"/*.litmus; do
  "$LITMUS7" -set-libdir "$LIBDIR" -o "$OUTDIR" "$t" >/dev/null
done

echo "Emitted:"
ls -1 "$OUTDIR"/*.cu
