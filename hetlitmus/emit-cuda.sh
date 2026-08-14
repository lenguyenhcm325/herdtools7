#!/usr/bin/env bash
# Emit CUDA (.cu) litmus kernels from the GPU-only LISA corpus.
#
# The CUDA-side entry point named in every emitted .cu banner (litmus/CudaLang.ml).
# The work lives in ./emit-gpu.sh; this names the vendor, so everything lands in
# OUTDIR, whose .gitignore keeps only the .cu.
#
# Usage:  ./emit-cuda.sh [OUTDIR]      (default OUTDIR=./cuda-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/cuda-out}"
exec "$HETL/emit-gpu.sh" cuda "$OUTDIR"
