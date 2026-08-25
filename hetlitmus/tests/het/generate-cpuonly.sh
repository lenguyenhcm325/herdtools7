#!/usr/bin/env bash
# The CPU-only set: het tests whose every proc is tagged `cpu', generated into
# OUTDIR (never the repo), emitted with litmus7, and read back for the
# `_rec.cpu_only = 1' stamp against a negative control that stamps 0.  It does
# not run them: only the target box's run would count.  Why the set exists and
# what each row must show: hetlitmus/docs/het-emission.md, "The CPU-only set".
#
#   usage:  ./generate-cpuonly.sh OUTDIR [GPU-TARGET]
#
# Het rather than upstream X86_64 so the cells sit on the shared allocation
# (gd_alloc_shared), which is what the set asks about.

set -euo pipefail
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path -- what the Makefile caller passes -- is correct.
OUT="${1:?usage: generate-cpuonly.sh OUTDIR [GPU-TARGET]}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# litmus7 emits ONE vendor per harness dir: this corpus has an x86_64 CPU column,
# so `hip' selects the (x86_64, hip) pair.  `cuda' is legal and is a machinery smoke.
TARGET="${2:-hip}"

cd "$(dirname "$0")"
HETDIR="$(pwd)"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell"

# The rm below empties OUT, so inside the repo ONLY the scratch dir
# hetlitmus/tests/het/cpuonly-out may be named.
[ "$OUT" != "$HETDIR" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }
[ "$OUT" != "$REPO" ] || { echo "refusing to empty the repo root" >&2; exit 2; }
case "$OUT" in "$REPO"/*)
  [ "$(basename "$OUT")" = cpuonly-out ] ||
    { echo "refusing to empty $OUT inside the repo" >&2; exit 2; } ;;
esac
rm -rf "${OUT:?}"/*

# The negative control for the stamp: a corpus test with a GPU proc, which the
# emitter must stamp 0.
NEG=MP-cg-sys-relaxed

# shape | nprocs | cycle
CPUONLY_ROWS="
MP:2:PodWW Rfe PodRR Fre
LB:2:PodRW Rfe PodRW Rfe
SB:2:PodWR Fre PodWR Fre
2+2W:2:PodWW Coe PodWW Coe
R:2:PodWW Coe PodWR Fre
IRIW:4:Rfe PodRR Fre Rfe PodRR Fre
"

while IFS=: read -r shape nprocs cycle; do
  [ -n "$shape" ] || continue
  name="$shape-cpuonly-x86_64"
  devs="cpu"; i=1
  while [ "$i" -lt "$nprocs" ]; do devs="$devs,cpu"; i=$((i+1)); done
  # -gpu is a required option of hetgen7 and is unused here: no proc carries the
  # gpu tag, so it is fed the same cycle and the two cannot drift apart.
  "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$devs" -name "$name" \
    -cpu "$cycle" -gpu "$cycle" > "$OUT/$name.litmus"
  # Every proc really is a CPU proc -- what the whole CPU-only reading rests on.
  if grep -qE 'P[0-9]+:gpu' "$OUT/$name.litmus"; then
    echo "FAIL: $name has a gpu column -- it is not a CPU-only test" >&2; exit 1
  fi
done <<< "$CPUONLY_ROWS"

n_tests=$(find "$OUT" -maxdepth 1 -name '*.litmus' | wc -l)
# Pinned, NOT derived: a row silently dropped from CPUONLY_ROWS must redden here.
[ "$n_tests" -eq 6 ] || { echo "FAIL: expected 6 CPU-only tests, found $n_tests" >&2; exit 1; }
echo "generate-cpuonly: $n_tests CPU-only tests in $OUT"

# --- emit, then read every render for the stamp -----------------------------
cd "$OUT"
for t in *.litmus; do
  "$LITMUS7" -gpu-target "$TARGET" -set-libdir "$LIBDIR" -o . "$t" 2>&1 \
    | grep -E 'pair:|REFUSED'
done
n_dirs=$(find "$OUT" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$n_dirs" -eq "$n_tests" ] || {
  echo "FAIL: emitted $n_dirs harness dir(s) for $n_tests test(s)" >&2; exit 1; }

n=0
for d in "$OUT"/*/ ; do
  r=""
  for cand in "$d"*.hip "$d"*.cu; do
    if [ -f "$cand" ]; then r="$cand"; break; fi
  done
  [ -n "$r" ] || { echo "FAIL: $d carries no render" >&2; exit 1; }
  grep -q '_rec\.cpu_only = 1;' "$r" || {
    echo "FAIL: $r does not stamp _rec.cpu_only = 1 -- a CPU-only cycle whose" >&2
    echo "  harness does not say so is reported as a compound-model row" >&2
    exit 1; }
  n=$((n+1))
done
echo "generate-cpuonly: $n/$n_tests renders stamp _rec.cpu_only = 1"

# --- negative control: the flag is not a constant ---------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$LITMUS7" -gpu-target cuda -set-libdir "$LIBDIR" -o "$tmp" \
  "$HETDIR/$NEG.litmus" >"$tmp/emit.log" 2>&1 || { cat "$tmp/emit.log" >&2; exit 1; }
grep -q '_rec\.cpu_only = 0;' "$tmp/$NEG/$NEG.cu" || {
  echo "FAIL: the negative control $NEG does not stamp _rec.cpu_only = 0 --" >&2
  echo "  the flag is a constant, so the 1s above vouch for nothing" >&2
  exit 1; }
echo "generate-cpuonly: the negative control $NEG stamps _rec.cpu_only = 0"

echo
echo "CPU-only harnesses in $OUT, rendered for $TARGET.  On the target box:"
echo "    cd <test> && sh comp.sh $TARGET-link && ./<test>    # SB and R must FIRE"
echo "    python3 hetlitmus/campaign.py --corpus $OUT --runner 'sh hetlitmus/spotcheck/run-one.sh {dir} {test}'"
