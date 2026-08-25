#!/usr/bin/env bash
# tokens.sh -- drive the static faithfulness and stress-liveness checkers over
# the corpus (hetlitmus/docs/faithfulness.md).  Subcommands:
#   all        covercheck.py, then ptxcheck.py over verify/faithful-cover.txt
#   full       ptxcheck.py over both corpora entire
#   gpu-only | het        one corpus
#   stress | cpustress    the two liveness checkers over their reps
#   stress-static         the GPU stress checker without its device probe
# Every non-PASS test prints its diff; a cover miss, a census miss, a FAIL, a
# GUARD-FAIL or an ERROR exits non-zero.  JOBS sets the worker count.
set -u

. "$(dirname "$0")/../paths.sh"
. "$HETL/verify/census.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

CHECK="$REPO/hetlitmus/verify/ptxcheck.py"
COVERCHECK="$REPO/hetlitmus/verify/covercheck.py"
COVER="$REPO/hetlitmus/verify/faithful-cover.txt"
GPU_DIR="$REPO/hetlitmus/tests/gpu-only"
HET_DIR="$REPO/hetlitmus/tests/het"
EXPECT_COVER="$CENSUS_COVER"
# `nproc' honours this process's affinity mask but NOT a cgroup CPU quota, so
# the cap is what keeps an uncapped default from oversubscribing a container.
_jobs_default() {
  local n
  n="$(nproc 2>/dev/null || echo 4)"
  if [ "$n" -gt 12 ]; then n=12; fi
  echo "$n"
}
JOBS="${JOBS:-$(_jobs_default)}"
RESDIR="$(mktemp -d)"
trap 'rm -rf "$RESDIR"' EXIT

# ---- one test -> a single result line "VERDICT name" ----------------------
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

# ---- sweep the .litmus paths on stdin, print table + tally ----------------
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
  # echo any diffs for non-PASS tests so failures are never papered over
  if [ "$pass" -ne "$total" ]; then
    printf '\n--- diffs for non-PASS %s tests ---\n' "$label"
    grep -vE '^PASS ' "$res" | while read -r v n; do
      printf '>>> %s %s\n' "$v" "$n"; cat "$RESDIR/diff.$n" 2>/dev/null
    done
  fi
  # `pass -eq total' is VACUOUSLY true on an empty or misnamed input (0 -eq 0),
  # so the census is asserted against the count the call site pins.
  if [ "$total" -ne "$expect" ]; then
    printf 'CENSUS FAIL %s: %d .litmus swept, expected %d (empty/misnamed input?)\n' \
           "$label" "$total" "$expect" >&2
    return 1
  fi
  [ "$pass" -eq "$total" ]
}

run_dir() { ls "$1"/*.litmus 2>/dev/null | run_paths "$2" "$3"; }

# The committed cover: covercheck.py asserts it reaches every feature of the
# full corpus, so this sweep misses no shape `full' would compile.
run_cover() {
  python3 "$COVERCHECK" || return 1
  grep -vE '^[[:space:]]*(#|$)' "$COVER" | run_paths cover "$EXPECT_COVER"
}

# ---- $1 banner, $2 tag, $3 what-failed, $4 checker, $5 flags, $6.. reps ----
# The OK line names the reps that ran, so a shrunken rep list is visible.
_liveness_report() {
  local banner="$1" tag="$2" what="$3" checker="$4" flags="$5"
  shift 5
  local reps="$*" fails=0 rc t out
  printf '\n===== %s =====\n' "$banner"
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    out="$(python3 "$REPO/hetlitmus/verify/$checker" $flags "$HET_DIR/$t.litmus" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    [ "$rc" -ne 0 ] && fails=$((fails+1))
  done
  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "$tag OK (${reps// /, })"
    return 0
  fi
  echo "$tag FAILED: $fails rep(s) $what"
  return 1
}

# ---- GPU scratchpad stress liveness (stresscheck.py) ----------------------
# ptxcheck is blind to the stress layer; this asks whether it is there at all.
stress_report() {
  _liveness_report "STRESS LIVENESS: is the GPU scratchpad layer in the PTX?" \
    STRESS "carry a dead stress layer" stresscheck.py "" \
    MP-cg-sys-acqrel-2s
}

# The same checker minus its device probe, for a box with nvcc and no GPU.
stress_static_report() {
  _liveness_report "STRESS PTX SURVIVAL: does the layer survive nvcc?" \
    STRESS-STATIC "carry a stress layer nvcc folded away" stresscheck.py --no-device \
    MP-cg-sys-acqrel-2s
}

# ---- CPU + interconnect stress liveness (cpustresscheck.py) ---------------
# The preload, the CPU enemies and the noise pair never enter the PTX.
cpustress_report() {
  _liveness_report "CPU + INTERCONNECT STRESS LIVENESS: does that layer run?" \
    CPUSTRESS "carry a dead CPU/interconnect stress layer" cpustresscheck.py "" \
    MP-cg-sys-acqrel-2s
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only)  run_dir "$GPU_DIR" gpu-only "$CENSUS_GPU_ONLY" ;;
  het)       run_dir "$HET_DIR" het "$CENSUS_HET" ;;
  stress)    stress_report; exit $? ;;
  stress-static) stress_static_report; exit $? ;;
  cpustress) cpustress_report; exit $? ;;
  all)       run_cover; exit $? ;;
  full)
    rc=0
    run_dir "$GPU_DIR" gpu-only "$CENSUS_GPU_ONLY" || rc=1
    run_dir "$HET_DIR" het "$CENSUS_HET" || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|full|gpu-only|het|stress|stress-static|cpustress]"; exit 64 ;;
esac
