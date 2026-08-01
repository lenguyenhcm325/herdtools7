#!/usr/bin/env bash
# HetLitmus Tier-1: emit CUDA (.cu) litmus kernels from the GPU-only LISA corpus.
#
# The CUDA-side entry point named in every emitted .cu banner (litmus/CudaLang.ml).
# One litmus7 run renders both dialects, so the work lives in ./emit-gpu.sh and
# this keeps the historical contract: everything lands in OUTDIR, whose
# .gitignore keeps only the .cu.
#
# Usage:  ./emit-cuda.sh [OUTDIR]      (default OUTDIR=./cuda-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/cuda-out}"
exec "$HETL/emit-gpu.sh" "$OUTDIR" "$OUTDIR"
