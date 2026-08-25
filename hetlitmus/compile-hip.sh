#!/usr/bin/env bash
# Compile-check the emitted .hip litmus kernels with hipcc/amdclang for gfx942
# (MI300A).  Nothing is launched; what a clean compile does and does NOT
# establish, and why the HIP-Clang stack rather than HIP-over-CUDA:
# hetlitmus/docs/hip-emitter.md "Compile status".
#
# Usage:  ./compile-hip.sh [INDIR] [OUTDIR]   (default ./hip-out, $INDIR/bin)
#         ARCH=<gfxNNN>  offload-arch override (default gfx942)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
ARCH="${ARCH:-gfx942}"
INDIR="${1:-$HETL/hip-out}"
OUTDIR="${2:-$INDIR/bin}"

HIPCC="$(command -v hipcc || true)"
if [ -z "$HIPCC" ] && [ -x /opt/rocm/bin/hipcc ]; then HIPCC=/opt/rocm/bin/hipcc; fi
if [ -z "$HIPCC" ]; then
  echo "error: hipcc not found -- install ROCm/HIP (see hetlitmus/docs/hip-emitter.md)" >&2
  exit 1
fi

if ! ls "$INDIR"/*.hip >/dev/null 2>&1; then
  echo "error: no .hip files in $INDIR (run emit-hip.sh first)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
echo "Compile-checking .hip from $INDIR for --offload-arch=$ARCH"
echo "  ($("$HIPCC" --version | head -1))"
pass=0 fail=0
for t in "$INDIR"/*.hip; do
  base="$(basename "${t%.hip}")"
  if "$HIPCC" --offload-arch="$ARCH" -std=c++17 "$t" -o "$OUTDIR/$base" \
       > "$OUTDIR/$base.log" 2>&1; then
    echo "  PASS  $base"
    pass=$((pass + 1))
  else
    echo "  FAIL  $base   (see $OUTDIR/$base.log)"
    fail=$((fail + 1))
  fi
done

echo "compile-check: $pass passed, $fail failed (arch=$ARCH; nothing is launched -- running a kernel needs an AMD device)"
[ "$fail" -eq 0 ]
