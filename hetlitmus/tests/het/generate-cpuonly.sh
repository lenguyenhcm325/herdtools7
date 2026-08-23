#!/usr/bin/env bash
# The CPU-only set: six shapes (MP, LB, SB, 2+2W, R, IRIW) rendered as het tests
# whose every proc is tagged `cpu', generated into OUTDIR (never the repo).
#
#   usage:  ./generate-cpuonly.sh OUTDIR
#
# Het rather than upstream X86_64 so the cells sit on the SHARED allocation
# (gd_alloc_shared), which is what the set asks about; the emitter stamps
# `_rec.cpu_only = 1' from the procs' device tags, so nothing here depends on
# the file name.  Why the set exists, what each row must show and why the 2+2W
# row is unresolved: hetlitmus/docs/het-emission.md, "The CPU-only set".
set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path -- what the Makefile caller passes -- is correct.  The same
# rule generate.sh and generate-x86.sh state at this spot.
OUT="${1:?usage: generate-cpuonly.sh OUTDIR}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cd "$(dirname "$0")"
HETDIR="$(pwd)"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell"

[ "$OUT" != "$HETDIR" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }

# shape | nprocs | cycle
#
# The harnesses carry no verdict, and this script supplies none: comparing an
# observation against an oracle is the offline step, and the caller brings both
# the comparator and the CSV.  Whatever a run shows, it is not a compound-model
# result: the CPU-only branch of het_verdict.h outranks the ordinary sentence,
# because on an all-CPU cycle the compound model is not under test.
CPUONLY_ROWS="
MP:2:PodWW Rfe PodRR Fre
LB:2:PodRW Rfe PodRW Rfe
SB:2:PodWR Fre PodWR Fre
2+2W:2:PodWW Coe PodWW Coe
R:2:PodWW Coe PodWR Fre
IRIW:4:Rfe PodRR Fre Rfe PodRR Fre
"

n=0
printf '%s\n' "$CPUONLY_ROWS" | while IFS=: read -r shape nprocs cycle; do
  [ -n "$shape" ] || continue
  name="$shape-cpuonly-x86_64"
  devs="cpu"; i=1
  while [ "$i" -lt "$nprocs" ]; do devs="$devs,cpu"; i=$((i+1)); done
  # -gpu is a required option of hetgen7 and is unused here: no proc carries the
  # gpu tag, so no LISA column is rendered.  It is fed the same cycle so the two
  # arguments cannot drift apart into a cycle mismatch.
  "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$devs" -name "$name" \
    -cpu "$cycle" -gpu "$cycle" > "$OUT/$name.litmus"
  # Sanity: every proc really is tagged x86_64 and none is a gpu column.  Cheap,
  # and it is the property the whole CPU-only reading rests on.
  if grep -qE 'P[0-9]+:gpu' "$OUT/$name.litmus"; then
    echo "FAIL: $name has a gpu column -- it is not a CPU-only test" >&2; exit 1
  fi
done

n="$(ls "$OUT"/*.litmus | wc -l)"
echo "generate-cpuonly: $n CPU-only tests in $OUT"
[ "$n" -eq 6 ] || { echo "FAIL: expected 6 CPU-only tests, found $n" >&2; exit 1; }
