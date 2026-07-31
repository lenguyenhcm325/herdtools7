#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus (450 het harness dirs +
# 137 gpu-only .cu + 137 gpu-only .hip) into OUTDIR.
#
# Purpose: the refactor golden.  The Layer-2 gate (corpus-gate.sh) byte-pins
# only 10 committed gpu-only .cu samples; every other emitted artifact is
# covered by PROPERTY gates (cram greps, ptxcheck, verdictcheck/statscheck
# corpus phases), which by design pass a range of outputs.  A behaviour-
# preserving refactor of the emitter should instead prove BYTE-IDENTICAL
# output: emit before, emit after, `diff -r`.  Emission is deterministic
# (corpus-gate.sh already relies on this for its 10 samples).
#
#   ./emit-all.sh SNAP_BEFORE     # at the pre-refactor commit
#   ...refactor...
#   ./emit-all.sh SNAP_AFTER
#   diff -r SNAP_BEFORE SNAP_AFTER && echo BYTE-IDENTICAL
#
# The het corpus is emitted from INSIDE hetlitmus/tests/het so emission finds
# control-map.csv + the co-run sibling .litmus (B6b: a Disallowed test's
# harness embeds its mu(T) mutant and the canary, resolved relative to the
# source dir).  gpu-only reuses emit-cuda.sh / emit-hip.sh unchanged.
#
# Usage:  hetlitmus/verify/emit-all.sh OUTDIR
# Exit:   0 = all 724 emitted; non-zero otherwise (fail-fast).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HETL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HETL/.." && pwd)"

LITMUS7="$REPO/_build/install/default/bin/litmus7"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

echo "[1/3] het corpus -> $OUTDIR/het"
mkdir -p "$OUTDIR/het"
( cd "$HETL/tests/het"
  for t in *.litmus; do
    "$LITMUS7" -o "$OUTDIR/het" "$t" >/dev/null
  done )

echo "[2/3] gpu-only CUDA -> $OUTDIR/gpu-cuda"
"$HETL/emit-cuda.sh" "$OUTDIR/gpu-cuda" >/dev/null

echo "[3/3] gpu-only HIP -> $OUTDIR/gpu-hip"
"$HETL/emit-hip.sh" "$OUTDIR/gpu-hip" >/dev/null

# The per-outdir run.sh embeds the ABSOLUTE OUTDIR path + the git revision
# (upstream litmus7 boilerplate, overwritten by every emission so it names only
# the last test).  It is the ONLY emitted file that does (verified: grep for
# the revision/outdir over a full snapshot hits nothing else), so drop it here
# and a plain `diff -r` of two snapshots is byte-exact across dirs AND commits.
rm -f "$OUTDIR"/het/run.sh "$OUTDIR"/gpu-cuda/run.sh "$OUTDIR"/gpu-hip/run.sh

nhet="$(find "$OUTDIR/het" -mindepth 1 -maxdepth 1 -type d | wc -l)"
ncu="$(ls "$OUTDIR/gpu-cuda"/*.cu 2>/dev/null | wc -l)"
nhip="$(ls "$OUTDIR/gpu-hip"/*.hip 2>/dev/null | wc -l)"
echo "emitted: $nhet het harness dirs, $ncu gpu-only .cu, $nhip gpu-only .hip"
if [ "$nhet" -ne 450 ] || [ "$ncu" -ne 137 ] || [ "$nhip" -ne 137 ]; then
  echo "FAIL: census mismatch (want 450/137/137)" >&2
  exit 1
fi
