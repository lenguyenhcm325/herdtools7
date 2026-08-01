#!/usr/bin/env bash
# HetLitmus Task 8 (HIP analog): compile-check the emitted AMD HIP (.hip) litmus
# kernels with hipcc/amdclang, cross-compiling for the MI300A ISA (gfx942).
#
# This is the AMD counterpart of CUDA's Task 8 (nvcc compile).  It does NOT run
# the kernels: this box has no AMD GPU (no /dev/kfd), so execution stays
# MI300A-gated (Task 9).  A clean compile proves the __hip_atomic_* / scope
# lowering is valid for the target ISA; it does NOT validate memory-model
# behaviour.  amdclang++ (HIP-Clang) accepts the __hip_atomic_* builtins the
# emitter produces; nvcc does not, so the HIP-Clang stack is required here (not
# HIP-over-CUDA).  See litmus/HipLang.ml + hetlitmus/docs/hip-emitter.md.
#
# Usage:  ./compile-hip.sh [INDIR] [OUTDIR]
#   INDIR   dir of emitted .hip   (default ./hip-out)
#   OUTDIR  dir for binaries+logs (default $INDIR/bin)
#   ARCH=<gfxNNN>  offload-arch override (default gfx942 = MI300A / CDNA3)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
ARCH="${ARCH:-gfx942}"
INDIR="${1:-$HETL/hip-out}"
OUTDIR="${2:-$INDIR/bin}"

# Locate hipcc (PATH, else the default ROCm prefix).
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

echo "compile-check: $pass passed, $fail failed (arch=$ARCH; run = Task 9 / MI300A-gated)"
[ "$fail" -eq 0 ]
