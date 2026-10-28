#!/usr/bin/env bash
# Emit CUDA kernels from the GPU-only corpus, through ./emit-gpu.sh.
# Usage:  ./emit-cuda.sh [OUTDIR]      (default OUTDIR=./cuda-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/cuda-out}"
exec "$HETL/emit-gpu.sh" cuda "$OUTDIR"
