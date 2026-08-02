#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus (411 het harness dirs +
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
# source dir).  gpu-only reuses emit-gpu.sh, which renders both dialects from
# one parse.
#
# FAIL-CLOSED (P2b).  This loop used to be
#     "$LITMUS7" -o "$OUTDIR/het" "$t" >/dev/null
# which reported SUCCESS for a test litmus7 REFUSED to emit: litmus7's batch
# driver caught the emission exception, printed it on the discarded stream and
# exited 0 (dumpRun.ml:266-281 -> litmus.ml:383-385).  Inert while every
# committed test emitted; live the moment the x86 CPU lane was wired.  Two
# INDEPENDENT detectors now stand between a refusal and a green run:
#   (a) CORRUPTION -- litmus7 exits 3 and prints "HetLitmus REFUSED" (see
#       HetArch.refused); this script checks the status AND greps the marker,
#       so neither one alone is load-bearing;
#   (b) OMISSION   -- the harness directory the test must produce is checked
#       for existence and for its <t>_cpu.c / <t>.cu / <t>.hip content, which
#       fires even if litmus7 were to exit 0 with nothing written.
# Each names the test it failed on and pastes litmus7's own output.
#
# Usage:  hetlitmus/verify/emit-all.sh OUTDIR
# Exit:   0 = all 685 emitted; non-zero otherwise (fail-fast).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
# Bite seam, same idiom as the Makefile's HET_ORACLE / HET_AMD_ORACLE: point
# this at a stand-in litmus7 to prove the detectors below actually fire.  A
# detector that has never been seen to fail is not evidence.
LITMUS7="${HET_LITMUS7:-$LITMUS7}"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
# OUTSIDE OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
# dotfiles too, so no scratch file may land in it.
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT

echo "[1/2] het corpus -> $OUTDIR/het"
mkdir -p "$OUTDIR/het"
( cd "$HETL/tests/het"
  for t in *.litmus; do
    n="${t%.litmus}"
    st=0
    "$LITMUS7" -o "$OUTDIR/het" "$t" >"$LOG" 2>&1 || st=$?
    if [ "$st" -ne 0 ]; then
      echo "FAIL: litmus7 exited $st on $t (no harness emitted); its output:" >&2
      cat "$LOG" >&2
      exit 1
    fi
    if grep -q 'HetLitmus REFUSED' "$LOG"; then
      echo "FAIL: litmus7 REFUSED $t; its output:" >&2
      cat "$LOG" >&2
      exit 1
    fi
    for f in "$n/${n}_cpu.c" "$n/$n.cu" "$n/$n.hip"; do
      if [ ! -s "$OUTDIR/het/$f" ]; then
        echo "FAIL: $t emitted no $f (harness missing or empty); litmus7 said:" >&2
        cat "$LOG" >&2
        exit 1
      fi
    done
  done )

echo "[2/2] gpu-only CUDA+HIP -> $OUTDIR/gpu-cuda + $OUTDIR/gpu-hip"
st=0
"$HETL/emit-gpu.sh" "$OUTDIR/gpu-cuda" "$OUTDIR/gpu-hip" >"$LOG" 2>&1 || st=$?
if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$LOG"; then
  echo "FAIL: emit-gpu.sh exited $st / refused; its output:" >&2
  cat "$LOG" >&2
  exit 1
fi

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
if [ "$nhet" -ne 411 ] || [ "$ncu" -ne 137 ] || [ "$nhip" -ne 137 ]; then
  echo "FAIL: census mismatch (want 411/137/137)" >&2
  exit 1
fi
