#!/usr/bin/env bash
# HetLitmus Tier-1: emit the GPU-only litmus kernels from the scoped LISA corpus.
#
# Drives the litmus7 binary over every tests/gpu-only/*.litmus test.  litmus7's
# `LISA arch branch parses the scoped Bell IR ONCE per test and renders both
# dialects from that one parse: CudaLang writes the .cu (cuda::atomic_ref scoped
# atomics, CTA layout from the scope tree) and HipLang the .hip (__hip_atomic_*
# scoped atomics, workgroup layout).  One pass therefore fills both trees.
# See litmus/{CudaLang,HipLang,hetGpuOnly}.ml.
#
# litmus7 also drops its C-runtime boilerplate next to the kernels; each output
# directory's .gitignore keeps only its own dialect.  Compile-checking the .hip
# is ./compile-hip.sh; nvcc compilation and hardware execution are Tasks 8/9.
#
# Usage:  ./emit-gpu.sh [CUDA_OUT] [HIP_OUT]
#           defaults ./cuda-out and ./hip-out.  Naming the same directory twice
#           leaves both dialects together, which is what emit-cuda.sh and
#           emit-hip.sh do.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

TESTS="$HETL/tests/gpu-only"
CUDA_OUT="${1:-$HETL/cuda-out}"
HIP_OUT="${2:-$HETL/hip-out}"

if [ ! -x "$LITMUS7" ]; then
  echo "error: litmus7 not built at $LITMUS7 (run 'make all' in $REPO)" >&2
  exit 1
fi

mkdir -p "$CUDA_OUT" "$HIP_OUT"
CUDA_OUT="$(cd "$CUDA_OUT" && pwd)"
HIP_OUT="$(cd "$HIP_OUT" && pwd)"

echo "Emitting CUDA+HIP from $TESTS -> $CUDA_OUT (.cu) + $HIP_OUT (.hip)"
for t in "$TESTS"/*.litmus; do
  "$LITMUS7" -set-libdir "$LIBDIR" -o "$CUDA_OUT" "$t" >/dev/null
done
if [ "$CUDA_OUT" != "$HIP_OUT" ]; then
  cp "$CUDA_OUT"/*.hip "$HIP_OUT/"
fi

echo "Emitted:"
ls -1 "$CUDA_OUT"/*.cu
ls -1 "$HIP_OUT"/*.hip
