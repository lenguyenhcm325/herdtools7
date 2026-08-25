#!/usr/bin/env bash
# Emit the GPU-only litmus kernels from the scoped LISA corpus
# (hetlitmus/tests/gpu-only).  litmus7 parses the scoped Bell IR and renders the
# ONE dialect `-gpu-target' names, .cu (CudaLang) or .hip (HipLang), so covering
# both vendors takes two passes -- what the TARGET OUTDIR pairs are for.  litmus7
# has no default target, and neither has this script.  It also drops its
# C-runtime boilerplate beside the kernels; each output dir's .gitignore keeps
# only its own dialect.  hetlitmus/docs/{cuda,hip}-emitter.md.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

TESTS="$HETL/tests/gpu-only"

if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
  echo "usage: emit-gpu.sh TARGET OUTDIR [TARGET OUTDIR]...  (e.g. cuda ./cuda-out)" >&2
  exit 2
fi

if [ ! -x "$LITMUS7" ]; then
  echo "error: litmus7 not built at $LITMUS7 (run 'make all' in $REPO)" >&2
  exit 1
fi

while [ "$#" -gt 0 ]; do
  TARGET="$1" ; OUTDIR="$2" ; shift 2
  mkdir -p "$OUTDIR"
  OUTDIR="$(cd "$OUTDIR" && pwd)"
  echo "Emitting $TARGET from $TESTS -> $OUTDIR"
  for t in "$TESTS"/*.litmus; do
    "$LITMUS7" -gpu-target "$TARGET" -set-libdir "$LIBDIR" -o "$OUTDIR" "$t" >/dev/null
  done
  echo "Emitted:"
  # the vendor->extension map lives in the emitter, so the absent one is no error
  ls -1 "$OUTDIR"/*.cu "$OUTDIR"/*.hip 2>/dev/null || true
done
