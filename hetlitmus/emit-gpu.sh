#!/usr/bin/env bash
# HetLitmus Tier-1: emit the GPU-only litmus kernels from the scoped LISA corpus.
#
# Drives the litmus7 binary over every tests/gpu-only/*.litmus test.  litmus7's
# `LISA arch branch parses the scoped Bell IR once per test and renders the ONE
# dialect `-gpu-target' names: CudaLang writes the .cu (cuda::atomic_ref scoped
# atomics, CTA layout from the scope tree), HipLang the .hip (__hip_atomic_*
# scoped atomics, workgroup layout).  One vendor per pass, so covering both
# means two passes -- which is what the TARGET OUTDIR pairs are for.
# See litmus/{CudaLang,HipLang,hetGpuOnly,hetDialect}.ml.
#
# litmus7 also drops its C-runtime boilerplate next to the kernels; each output
# directory's .gitignore keeps only its own dialect.  Compile-checking the .hip
# is ./compile-hip.sh; nvcc compilation and hardware execution are Tasks 8/9.
#
# Usage:  ./emit-gpu.sh TARGET OUTDIR [TARGET OUTDIR]...
#           e.g. ./emit-gpu.sh cuda ./cuda-out hip ./hip-out
#         The vendor is always spelled out: litmus7 has no default target, and
#         neither has this script.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

TESTS="$HETL/tests/gpu-only"

if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
  echo "usage: emit-gpu.sh TARGET OUTDIR [TARGET OUTDIR]...  (e.g. cuda ./cuda-out)" >&2
  exit 2
fi

if [ ! -x "$LITMUS7" ]; then
  echo "error: litmus7 not built at $LITMUS7 (run 'make all' in $REPO)" >&2
  exit 1
fi

while [ "$#" -gt 0 ]; do
  TARGET="$1" ; OUTDIR="$2" ; shift 2
  mkdir -p "$OUTDIR"
  OUTDIR="$(cd "$OUTDIR" && pwd)"
  echo "Emitting $TARGET from $TESTS -> $OUTDIR"
  for t in "$TESTS"/*.litmus; do
    "$LITMUS7" -gpu-target "$TARGET" -set-libdir "$LIBDIR" -o "$OUTDIR" "$t" >/dev/null
  done
  echo "Emitted:"
  # whichever extension this vendor renders; the map lives in the emitter, not
  # here, so both are listed and the absent one is not an error
  ls -1 "$OUTDIR"/*.cu "$OUTDIR"/*.hip 2>/dev/null || true
done
