#!/usr/bin/env bash
# Emit CUDA (.cu) litmus kernels from the GPU-only LISA corpus: the vendor name
# for ./emit-gpu.sh, which does the work.  Everything lands in OUTDIR, whose
# .gitignore keeps only the .cu.  Every emitted .cu banner names this path
# (litmus/CudaLang.ml).  hetlitmus/docs/cuda-emitter.md.
#
# Usage:  ./emit-cuda.sh [OUTDIR]      (default OUTDIR=./cuda-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/cuda-out}"
exec "$HETL/emit-gpu.sh" cuda "$OUTDIR"
