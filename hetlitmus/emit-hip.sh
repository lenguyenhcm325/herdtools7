#!/usr/bin/env bash
# Emit AMD HIP (.hip) litmus kernels from the GPU-only LISA corpus: the vendor
# name for ./emit-gpu.sh, which does the work.  Everything lands in OUTDIR,
# whose .gitignore keeps only the .hip.  Every emitted .hip banner names this
# path (litmus/HipLang.ml).  ./compile-hip.sh compile-checks the renders;
# running a kernel needs an AMD device.  hetlitmus/docs/hip-emitter.md.
#
# Usage:  ./emit-hip.sh [OUTDIR]      (default OUTDIR=./hip-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/hip-out}"
exec "$HETL/emit-gpu.sh" hip "$OUTDIR"
