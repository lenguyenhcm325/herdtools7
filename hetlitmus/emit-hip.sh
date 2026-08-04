#!/usr/bin/env bash
# HetLitmus Tier-1: emit AMD HIP (.hip) litmus kernels from the GPU-only LISA corpus.
#
# The HIP-side entry point named in every emitted .hip banner (litmus/HipLang.ml).
# The work lives in ./emit-gpu.sh; this names the vendor, so everything lands in
# OUTDIR, whose .gitignore keeps only the .hip.  Compile-check the result with
# ./compile-hip.sh (hipcc, gfx942); hardware execution stays Task 9 / MI300A-gated.
#
# Usage:  ./emit-hip.sh [OUTDIR]      (default OUTDIR=./hip-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/hip-out}"
exec "$HETL/emit-gpu.sh" hip "$OUTDIR"
