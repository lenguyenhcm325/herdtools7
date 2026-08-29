#!/usr/bin/env bash
# Compile-check the emitted .hip litmus kernels with hipcc/amdclang for gfx942
# (MI300A).  Nothing is launched; what a clean compile does and does NOT
# establish, and why the HIP-Clang stack rather than HIP-over-CUDA:
# hetlitmus/docs/hip-emitter.md "Compile status".
#
# Usage:  ./compile-hip.sh [INDIR] [OUTDIR]   (default ./hip-out,
#           $RESULTS/hip-compile; RESULTS default run-out/<date>-<host>)
#         HIPCC=<path>   compiler (default: hipcc on PATH, else /opt/rocm/bin)
#         HIP_ARCH=<gfxNNN>   offload-arch override (default gfx942)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
HIP_ARCH="${HIP_ARCH:-gfx942}"
INDIR="${1:-$HETL/hip-out}"
# The results-dir default is spelled as build.sh and probe-hip.sh spell it, so
# the steps of one run share a dir (hetlitmus/docs/het-emission.md).
RESULTS="${RESULTS:-$HETL/run-out/$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"
OUTDIR="${2:-$RESULTS/hip-compile}"

HIPCC="${HIPCC:-}"
if [ -n "$HIPCC" ]; then
  # command -v alone resolves a builtin or function, which compiles nothing.
  [ -x "$(command -v "$HIPCC" 2>/dev/null || true)" ] || {
    echo "error: HIPCC=$HIPCC is not an executable" >&2
    exit 1
  }
else
  HIPCC="$(command -v hipcc 2>/dev/null || true)"
  [ -x "$HIPCC" ] || HIPCC=""
  if [ -z "$HIPCC" ] && [ -x /opt/rocm/bin/hipcc ]; then HIPCC=/opt/rocm/bin/hipcc; fi
  if [ -z "$HIPCC" ]; then
    echo "error: hipcc not found -- install ROCm/HIP (see hetlitmus/docs/hip-emitter.md)" >&2
    exit 1
  fi
fi

if ! ls "$INDIR"/*.hip >/dev/null 2>&1; then
  echo "error: no .hip files in $INDIR (run emit-hip.sh first)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
echo "Compile-checking .hip from $INDIR into $OUTDIR for --offload-arch=$HIP_ARCH"
echo "  ($("$HIPCC" --version | head -1))"
pass=0 fail=0
for t in "$INDIR"/*.hip; do
  base="$(basename "${t%.hip}")"
  if "$HIPCC" --offload-arch="$HIP_ARCH" -std=c++17 "$t" -o "$OUTDIR/$base" \
       > "$OUTDIR/$base.log" 2>&1; then
    echo "  PASS  $base"
    pass=$((pass + 1))
  else
    echo "  FAIL  $base   (see $OUTDIR/$base.log)"
    fail=$((fail + 1))
  fi
done

echo "compile-check: $pass passed, $fail failed (arch=$HIP_ARCH; nothing is launched -- running a kernel needs an AMD device)"
[ "$fail" -eq 0 ]
