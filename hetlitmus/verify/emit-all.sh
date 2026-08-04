#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus, for EVERY vendor, into
# OUTDIR -- 411 het harness dirs and 137 gpu-only kernels per GPU target.
#
# Purpose: the refactor golden.  The Layer-2 gate (corpus-gate.sh) byte-pins
# only the committed gpu-only samples; every other emitted artifact is covered
# by PROPERTY gates (cram greps, ptxcheck, verdictcheck/statscheck corpus
# phases), which by design pass a range of outputs.  A behaviour-preserving
# refactor of the emitter should instead prove BYTE-IDENTICAL output: emit
# before, emit after, `diff -r`.  Emission is deterministic (corpus-gate.sh
# already relies on this for its samples).
#
#   ./emit-all.sh SNAP_BEFORE     # at the pre-refactor commit
#   ...refactor...
#   ./emit-all.sh SNAP_AFTER
#   diff -r SNAP_BEFORE SNAP_AFTER && echo BYTE-IDENTICAL
#
# ONE VENDOR PER EMISSION (litmus7 -gpu-target, litmus/hetTarget.ml): a harness
# directory carries one render and one vendor's build arms, so covering the
# emission surface takes one lane per (corpus, target) pair.  The lanes are
# listed in HET_LANES / GPU_LANES below and nowhere else, so a pair that stops
# emitting -- or a vendor that is added -- is a line here, not a rewrite.
#
# The het corpus is emitted from INSIDE hetlitmus/tests/het so emission finds
# control-map.csv + the co-run sibling .litmus (B6b: a Disallowed test's
# harness embeds its mu(T) mutant and the canary, resolved relative to the
# source dir).  gpu-only reuses emit-gpu.sh.
#
# FAIL-CLOSED (P2b).  This loop used to be
#     "$LITMUS7" -o "$OUTDIR/het" "$t" >/dev/null
# and litmus7 itself EXITED 0 on a refusal: its batch driver caught the emission
# exception, printed it on the discarded stream and returned success
# (dumpRun.ml:266-281 -> litmus.ml:383-385).  Measured, by replaying the
# pre-P2b script against stand-in litmus7 binaries:
#   * a wholly MISSING harness directory WAS caught, but only by the aggregate
#     census at the bottom -- `emitted: 410 ...' / `FAIL: census mismatch',
#     exit 1, naming no test and no reason (and the count is not even
#     proportionate: one broken test also breaks every harness that co-runs it
#     as mu(T)/canary);
#   * an INCOMPLETE harness -- directory present, <t>_cpu.c gone -- was NOT
#     caught: `emitted: 411 het harness dirs', exit 0.  A snapshot with a whole
#     CPU thread missing reported success.
# Inert while every committed test emitted; live the moment the x86 CPU lane was
# wired.  Two INDEPENDENT detectors now stand between a refusal and a green run:
#   (a) CORRUPTION -- litmus7 exits 3 and prints "HetLitmus REFUSED" (see
#       HetArch.refused); this script checks the status AND greps the marker,
#       so neither one alone is load-bearing;
#   (b) OMISSION   -- the harness directory the test must produce is checked
#       for existence and for its <t>_cpu.c and its OWN render, which fires even
#       if litmus7 were to exit 0 with nothing written.  The lane's render is
#       also required to be the ONLY one: a dir carrying the other vendor's
#       file too would mean -gpu-target stopped filtering.
# Each names the test it failed on and pastes litmus7's own output.
#
# Usage:  hetlitmus/verify/emit-all.sh OUTDIR
# Exit:   0 = every lane complete; non-zero otherwise (fail-fast).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
# Bite seam, same idiom as the Makefile's HET_ORACLE / HET_AMD_ORACLE: point
# this at a stand-in litmus7 to prove the detectors below actually fire.  A
# detector that has never been seen to fail is not evidence.
LITMUS7="${HET_LITMUS7:-$LITMUS7}"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

# THE EMISSION LANES, "<gpu-target>:<render extension>:<OUTDIR subdir>".
HET_LANES="cuda:cu:het-cuda hip:hip:het-hip"
GPU_LANES="cuda:cu:gpu-cuda hip:hip:gpu-hip"
EXPECT_HET=411          # harness dirs per het lane
EXPECT_GPU=137          # kernels per gpu-only lane

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
# OUTSIDE OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
# dotfiles too, so no scratch file may land in it.
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT

i=0
nlanes=$(( $(echo $HET_LANES | wc -w) + $(echo $GPU_LANES | wc -w) ))

for lane in $HET_LANES; do
  target="${lane%%:*}"; rest="${lane#*:}"; ext="${rest%%:*}"; sub="${rest#*:}"
  i=$((i+1))
  echo "[$i/$nlanes] het corpus, -gpu-target $target -> $OUTDIR/$sub"
  mkdir -p "$OUTDIR/$sub"
  ( cd "$HETL/tests/het"
    for t in *.litmus; do
      n="${t%.litmus}"
      st=0
      "$LITMUS7" -gpu-target "$target" -o "$OUTDIR/$sub" "$t" >"$LOG" 2>&1 || st=$?
      if [ "$st" -ne 0 ]; then
        echo "FAIL: litmus7 -gpu-target $target exited $st on $t (no harness emitted); its output:" >&2
        cat "$LOG" >&2
        exit 1
      fi
      if grep -q 'HetLitmus REFUSED' "$LOG"; then
        echo "FAIL: litmus7 -gpu-target $target REFUSED $t; its output:" >&2
        cat "$LOG" >&2
        exit 1
      fi
      for f in "$n/${n}_cpu.c" "$n/$n.$ext"; do
        if [ ! -s "$OUTDIR/$sub/$f" ]; then
          echo "FAIL: $t emitted no $f in the $target lane (harness missing or empty); litmus7 said:" >&2
          cat "$LOG" >&2
          exit 1
        fi
      done
      for other in $HET_LANES; do
        oext="${other#*:}"; oext="${oext%%:*}"
        if [ "$oext" != "$ext" ] && [ -e "$OUTDIR/$sub/$n/$n.$oext" ]; then
          echo "FAIL: the $target lane emitted $n/$n.$oext as well -- -gpu-target is not filtering" >&2
          exit 1
        fi
      done
    done )
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $EXPECT_HET)"
  if [ "$nhet" -ne "$EXPECT_HET" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_HET)" >&2
    exit 1
  fi
done

for lane in $GPU_LANES; do
  target="${lane%%:*}"; rest="${lane#*:}"; ext="${rest%%:*}"; sub="${rest#*:}"
  i=$((i+1))
  echo "[$i/$nlanes] gpu-only corpus, -gpu-target $target -> $OUTDIR/$sub"
  st=0
  "$HETL/emit-gpu.sh" "$target" "$OUTDIR/$sub" >"$LOG" 2>&1 || st=$?
  if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$LOG"; then
    echo "FAIL: emit-gpu.sh $target exited $st / refused; its output:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  n="$(ls "$OUTDIR/$sub"/*."$ext" 2>/dev/null | wc -l)"
  echo "        $n gpu-only .$ext (expect $EXPECT_GPU)"
  if [ "$n" -ne "$EXPECT_GPU" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_GPU .$ext)" >&2
    exit 1
  fi
  for other in $GPU_LANES; do
    oext="${other#*:}"; oext="${oext%%:*}"
    if [ "$oext" != "$ext" ] && ls "$OUTDIR/$sub"/*."$oext" >/dev/null 2>&1; then
      echo "FAIL: the gpu-only $target lane emitted .$oext files -- -gpu-target is not filtering" >&2
      exit 1
    fi
  done
done

# The per-outdir run.sh embeds the ABSOLUTE OUTDIR path + the git revision
# (upstream litmus7 boilerplate, overwritten by every emission so it names only
# the last test).  It is the ONLY emitted file that does (verified: grep for
# the revision/outdir over a full snapshot hits nothing else), so drop it here
# and a plain `diff -r` of two snapshots is byte-exact across dirs AND commits.
for lane in $HET_LANES $GPU_LANES; do
  rm -f "$OUTDIR/${lane##*:}/run.sh"
done

echo "emitted: $(echo $HET_LANES | wc -w) x $EXPECT_HET het harness dirs, $(echo $GPU_LANES | wc -w) x $EXPECT_GPU gpu-only kernels"
