#!/usr/bin/env bash
# Emit HIP kernels from the GPU-only corpus, through ./emit-gpu.sh.
# Usage:  ./emit-hip.sh [OUTDIR]      (default OUTDIR=./hip-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/hip-out}"
exec "$HETL/emit-gpu.sh" hip "$OUTDIR"
