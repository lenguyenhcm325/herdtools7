#!/usr/bin/env bash
# HetLitmus Tier-1: emit AMD HIP (.hip) litmus kernels from the GPU-only LISA corpus.
#
# Drives the litmus7 binary (built on branch hetlitmus-work) over every
# tests/gpu-only/*.litmus test; litmus7's `LISA arch branch parses the scoped
# Bell IR and HipLang emits one .hip per test (__hip_atomic_* scoped atomics,
# workgroup layout from the scope tree).  See litmus/HipLang.ml + litmus/top_litmus.ml.
#
# NB: the same litmus7 run also drops a .cu (CudaLang); this script keeps only the
# .hip (see hip-out/.gitignore).  Compile-checking the emitted .hip (the HIP
# analog of CUDA's Task 8) is now wired: run ./compile-hip.sh afterwards to
# cross-compile each .hip for the MI300A ISA (gfx942) with hipcc.  Hardware
# execution stays Task 9 / MI300A-gated.
#
# Usage:  ./emit-hip.sh [OUTDIR]      (default OUTDIR=./hip-out)
set -euo pipefail

# Resolve repo root from this script's location (hetlitmus/ lives at repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

LITMUS7="$REPO/_build/install/default/bin/litmus7"
LIBDIR="$REPO/litmus/libdir"
TESTS="$HERE/tests/gpu-only"
OUTDIR="${1:-$HERE/hip-out}"

if [ ! -x "$LITMUS7" ]; then
  echo "error: litmus7 not built at $LITMUS7 (run 'make all' in $REPO)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
echo "Emitting HIP from $TESTS -> $OUTDIR"
for t in "$TESTS"/*.litmus; do
  "$LITMUS7" -set-libdir "$LIBDIR" -o "$OUTDIR" "$t" >/dev/null
done

echo "Emitted:"
ls -1 "$OUTDIR"/*.hip
