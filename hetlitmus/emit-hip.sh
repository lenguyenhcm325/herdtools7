#!/usr/bin/env bash
# Emit AMD HIP (.hip) litmus kernels from the GPU-only LISA corpus.
#
# The HIP-side entry point named in every emitted .hip banner (litmus/HipLang.ml).
# The work lives in ./emit-gpu.sh; this names the vendor, so everything lands in
# OUTDIR, whose .gitignore keeps only the .hip.  `make hetlitmus-amd-faithful'
# compiles every render's device half and reads the gfx942 lowering back;
# ./compile-hip.sh builds them into host binaries by hand; running a kernel
# needs an AMD device.
#
# Usage:  ./emit-hip.sh [OUTDIR]      (default OUTDIR=./hip-out)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
OUTDIR="${1:-$HETL/hip-out}"
exec "$HETL/emit-gpu.sh" hip "$OUTDIR"
