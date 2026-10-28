#!/usr/bin/env bash
# tokens.sh -- run the static faithfulness and stress-liveness checkers.  Subcommands:
#   all        covercheck.py, then ptxcheck.py over verify/faithful-cover.txt
#   full       ptxcheck.py over both corpora entire
#   gpu-only | het        one corpus
#   hipsrc     hipsrccheck.py over the gpu-only and het-x86_64 trees
#   stress | cpustress    the two liveness checkers over their reps
set -u

. "$(dirname "$0")/../paths.sh"
. "$HETL/verify/census.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

CHECK="$REPO/hetlitmus/verify/ptxcheck.py"
HIPSRCCHECK="$REPO/hetlitmus/verify/hipsrccheck.py"
COVERCHECK="$REPO/hetlitmus/verify/covercheck.py"
COVER="$REPO/hetlitmus/verify/faithful-cover.txt"
GPU_DIR="$GPU_CORPUS"
HET_DIR="$HET_CORPUS"
X86_DIR="$X86_CORPUS"
EXPECT_COVER="$CENSUS_COVER"
_jobs_default() {
  local n
  n="$(nproc 2>/dev/null || echo 4)"
  if [ "$n" -gt 12 ]; then n=12; fi
  echo "$n"
}
JOBS="${JOBS:-$(_jobs_default)}"
RESDIR="$(mktemp -d)"
trap 'rm -rf "$RESDIR"' EXIT

run_one() {
  local t="$1" name out rc
  name="$(basename "$t" .litmus)"
  out="$(python3 "$CHECK" "$t" 2>&1)"; rc=$?
  case "$rc" in
    0) echo "PASS $name" ;;
    1) echo "FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    2) echo "GUARD-FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    *) echo "ERROR $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
  esac
}
export -f run_one
export CHECK RESDIR

run_paths() {
  local label="$1" expect="$2"
  printf '\n===== static token check: %s =====\n' "$label"
  printf '%-34s | %s\n' "test" "verdict"
  printf -- '-----------------------------------+---------\n'
  local res="$RESDIR/res.$label"
  xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} | sort -k2 > "$res"
  awk '{printf "%-34s | %s\n",$2,$1}' "$res"
  printf -- '-----------------------------------+---------\n'
  local total pass fail guard err
  total=$(wc -l < "$res")
  pass=$(grep -c '^PASS '       "$res" || true)
  fail=$(grep -c '^FAIL '       "$res" || true)
  guard=$(grep -c '^GUARD-FAIL ' "$res" || true)
  err=$(grep -c '^ERROR '       "$res" || true)
  printf 'TALLY %s: %d/%d PASS  (FAIL=%d  GUARD-FAIL=%d  ERROR=%d)\n' \
         "$label" "$pass" "$total" "$fail" "$guard" "$err"
  if [ "$pass" -ne "$total" ]; then
    printf '\n--- diffs for non-PASS %s tests ---\n' "$label"
    grep -vE '^PASS ' "$res" | while read -r v n; do
      printf '>>> %s %s\n' "$v" "$n"; cat "$RESDIR/diff.$n" 2>/dev/null
    done
  fi
  if [ "$total" -ne "$expect" ]; then
    printf 'CENSUS FAIL %s: %d .litmus swept, expected %d (empty/misnamed input?)\n' \
           "$label" "$total" "$expect" >&2
    return 1
  fi
  [ "$pass" -eq "$total" ]
}

run_dir() { ls "$1"/*.litmus 2>/dev/null | run_paths "$2" "$3"; }

run_cover() {
  python3 "$COVERCHECK" || return 1
  grep -vE '^[[:space:]]*(#|$)' "$COVER" | sed "s|^|$CORPUS/|" \
    | run_paths cover "$EXPECT_COVER"
}

_liveness_report() {
  local banner="$1" tag="$2" what="$3" checker="$4" flags="$5"
  shift 5
  local reps="$*" fails=0 ran=0 rc t out
  printf '\n===== %s =====\n' "$banner"
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    out="$(python3 "$REPO/hetlitmus/verify/$checker" $flags "$HET_DIR/$t.litmus" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    ran=$((ran+1))
    [ "$rc" -ne 0 ] && fails=$((fails+1))
  done
  printf '\n'
  if [ "$ran" -eq 0 ]; then
    echo "$tag FAILED: no rep ran"
    return 1
  fi
  if [ "$fails" -eq 0 ]; then
    echo "$tag OK (${reps// /, })"
    return 0
  fi
  echo "$tag FAILED: $fails rep(s) $what"
  return 1
}

stress_report() {
  _liveness_report "STRESS PTX SURVIVAL: is the GPU scratchpad layer in the PTX?" \
    STRESS "carry a stress layer nvcc folded away" stresscheck.py "" \
    MP-cg-sys-ra.acq
}

cpustress_report() {
  _liveness_report "CPU + INTERCONNECT STRESS LIVENESS: does that layer run?" \
    CPUSTRESS "carry a dead CPU/interconnect stress layer" cpustresscheck.py "" \
    MP-cg-sys-ra.acq
}

cmd="${1:-all}"
case "$cmd" in
  gpu-only)  run_dir "$GPU_DIR" gpu-only "$CENSUS_GPU_ONLY" ;;
  het)       run_dir "$HET_DIR" het "$CENSUS_HET" ;;
  hipsrc)
    CHECK="$HIPSRCCHECK"
    rc=0
    run_dir "$GPU_DIR" hipsrc-gpu-only "$CENSUS_GPU_ONLY" || rc=1
    run_dir "$X86_DIR" hipsrc-het-x86_64 "$CENSUS_HET_X86" || rc=1
    exit $rc ;;
  stress)    stress_report; exit $? ;;
  cpustress) cpustress_report; exit $? ;;
  all)       run_cover; exit $? ;;
  full)
    rc=0
    run_dir "$GPU_DIR" gpu-only "$CENSUS_GPU_ONLY" || rc=1
    run_dir "$HET_DIR" het "$CENSUS_HET" || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|full|gpu-only|het|hipsrc|stress|cpustress]"; exit 64 ;;
esac
