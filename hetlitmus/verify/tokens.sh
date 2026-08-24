#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tokens.sh -- drive ptxcheck.py over the HetLitmus corpus.
#
# The static, hardware-free faithfulness check: for every emitted GPU (and
# het CPU) harness, the kind+order+scope of every memory op must match its
# .litmus annotation exactly (hetlitmus/docs/faithfulness.md).  This script loops
# the corpus and prints a per-test PASS/FAIL table + tally, and drives the two
# stress-liveness checkers over their reps.
#
# Usage:
#   bash hetlitmus/verify/tokens.sh            # gpu-only + het table + tally
#   bash hetlitmus/verify/tokens.sh gpu-only   # just the gpu-only corpus
#   bash hetlitmus/verify/tokens.sh het        # just the het corpus
#   bash hetlitmus/verify/tokens.sh stress     # GPU scratchpad liveness
#   bash hetlitmus/verify/tokens.sh cpustress  # CPU + interconnect liveness
#   JOBS=8 bash hetlitmus/verify/tokens.sh     # workers (default: nproc, max 12)
# ---------------------------------------------------------------------------
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

CHECK="$REPO/hetlitmus/verify/ptxcheck.py"
GPU_DIR="$REPO/hetlitmus/tests/gpu-only"
HET_DIR="$REPO/hetlitmus/tests/het"
# Per-test workers for the corpus loops below.  `nproc' honours this process's
# affinity mask but NOT a cgroup CPU quota, so an uncapped default can
# oversubscribe a container several times over; the cap bounds that without
# reading cgroup files whose layout differs between v1 and v2.
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
  out="$(python3 "$CHECK" "$t" -q 2>&1)"; rc=$?
  case "$rc" in
    0) echo "PASS $name" ;;
    1) echo "FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    2) echo "GUARD-FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    *) echo "ERROR $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
  esac
}
export -f run_one
export CHECK RESDIR

# ---- loop a directory, print table + tally --------------------------------
run_dir() {
  local dir="$1" label="$2" expect="${3:-0}"
  printf '\n===== static token check: %s =====\n' "$label"
  printf '%-34s | %s\n' "test" "verdict"
  printf -- '-----------------------------------+---------\n'
  local res="$RESDIR/res.$label"
  ls "$dir"/*.litmus 2>/dev/null | \
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
  # `pass -eq total' is VACUOUSLY true on an empty or misnamed corpus (0 -eq 0):
  # it would report OK for zero tests.  So assert the known census, passed in by
  # the call site below -- the same exact-count discipline corpus-gate and
  # verdictcheck use; a census change then has to be a deliberate edit there.
  if [ "$expect" -gt 0 ] && [ "$total" -ne "$expect" ]; then
    printf 'CENSUS FAIL %s: %d .litmus emitted, expected %d (empty/misnamed corpus?)\n' \
           "$label" "$total" "$expect" >&2
    return 1
  fi
  [ "$pass" -eq "$total" ]
}

# ---- one liveness sweep: run a checker over its reps and tally --------------
# Shared by the two reports below, which are the same loop: run CHECKER once per
# rep, count nonzero exits, and print an OK line naming the reps that ran (so a
# shrunken rep list is visible) or a failure line counting them.  Only the reps,
# the checker and the two label strings differ -- and the rep-selection rationale
# stays at each call site, where it is the thing worth reading.
#   $1 banner (printed between `===== '), $2 tag, $3 what-failed, $4 checker,
#   $5 extra args for every rep AFTER the first ("" = run them all identically),
#   $6.. the reps.
_liveness_report() {
  local banner="$1" tag="$2" what="$3" checker="$4" rest="$5"
  shift 5
  local reps="$*"
  local fails=0 rc t out first=1 dfile="$RESDIR/hdr.$tag" nrep nd
  : > "$dfile"
  printf '\n===== %s =====\n' "$banner"
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    if [ "$first" -eq 1 ]; then
      out="$(python3 "$REPO/hetlitmus/verify/$checker" "$HET_DIR/$t.litmus" 2>&1)"
      rc=$?
      first=0
    else
      out="$(python3 "$REPO/hetlitmus/verify/$checker" "$HET_DIR/$t.litmus" $rest 2>&1)"
      rc=$?
    fi
    printf '%s\n' "$out"
    [ "$rc" -ne 0 ] && fails=$((fails+1))
    printf '%s\n' "$out" \
      | sed -n 's/.*het_stress\.h=\([0-9a-z]*\).*/\1/p' >> "$dfile"
  done
  printf '\n'
  # A reduced check set on the later reps is only covered by the first rep if
  # every rep compiled against the SAME het_stress.h -- that header is the whole
  # of what the device probe reads.  The checker prints its digest; require one
  # per rep and one distinct value.
  if [ -n "$rest" ]; then
    nrep=$(printf '%s\n' $reps | wc -l)
    nd=$(sort -u "$dfile" | wc -l)
    if [ "$(wc -l < "$dfile")" -ne "$nrep" ] || [ "$nd" -ne 1 ]; then
      echo "$tag FAILED: the $nrep reps reported $(wc -l < "$dfile") het_stress.h"\
           "digest(s), $nd distinct -- the reps that ran \`$rest' are NOT covered"\
           "by the first rep's full run"
      cat "$dfile"
      return 1
    fi
    echo "$tag: every rep compiled against het_stress.h $(head -1 "$dfile"), so the"\
         "first rep's device probe covers them all"
  fi
  if [ "$fails" -eq 0 ]; then
    echo "$tag OK (${reps// /, })"
    return 0
  fi
  echo "$tag FAILED: $fails rep(s) $what"
  return 1
}

# ---- stress liveness (the other static gate; see stresscheck.py) ------------
# ptxcheck proves the harness carries exactly the tested ops and is blind to the
# stress layer; stresscheck.py proves the scaffolding is there at all.  Three
# reps, one per GPU-lane shape, because the pre-stress lives in the test lanes
# and the mem-stress in the pure-stress blocks:
#   MP-cg-sys-acqrel-2s   1 GPU test lane, register outcome columns only
#   S-cg-sys-fence        1 GPU test lane, and a location outcome column
#   IRIW-gcgc-sys-fence   2 GPU test lanes
# The device probe -- the RUNTIME tally -- takes its only input from the harness
# in het_stress.h, and litmus7 writes that file verbatim for every test
# (hetEmit.ml, `write "het_stress.h"'), so the three reps would drive the same
# device probe three times.  The first rep runs it; the others run the structural
# checks, and _liveness_report compares the digest each rep prints so a header
# that stopped being verbatim cannot make that shortcut silent.
stress_report() {
  _liveness_report "STRESS LIVENESS: is the GPU scratchpad layer in the PTX?" \
    STRESS "carry a dead stress layer" stresscheck.py "--checks structural" \
    MP-cg-sys-acqrel-2s S-cg-sys-fence IRIW-gcgc-sys-fence
}

# ---- CPU + interconnect stress liveness (see cpustresscheck.py) -------------
# stresscheck.py above covers the GPU scratchpad layer.  The CPU side adds three
# mechanisms no structural gate can see: the cache preload (host hints -- no
# order, no scope, not a model op), the CPU enemies (host threads that never
# enter the PTX at all) and the interconnect noise pair.  cpustresscheck.py asks
# the two questions the structural gates cannot -- did they survive the OPTIMISER
# (read off the compiled -O2 asm, on both host ISAs), and do they do anything at run
# time (a host-side probe, checked live-when-on and zero-when-off, since a tally
# that cannot go to zero is not evidence of liveness).
#
# Two reps are enough: the CPU stress layer is per-proc, not per-GPU-lane shape.
#   MP-cg-sys-acqrel-2s   the -2s shape -- the CPU issues the tested STLRs, so this
#                         is where injecting stress could corrupt the hypothesis
#   S-cg-sys-fence        a shape whose outcome carries a location column
cpustress_report() {
  _liveness_report "CPU + INTERCONNECT STRESS LIVENESS: does that layer run?" \
    CPUSTRESS "carry a dead CPU/interconnect stress layer" cpustresscheck.py "" \
    MP-cg-sys-acqrel-2s S-cg-sys-fence
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only)  run_dir "$GPU_DIR" gpu-only 173 ;;
  het)       run_dir "$HET_DIR" het 471 ;;
  stress)    stress_report; exit $? ;;
  cpustress) cpustress_report; exit $? ;;
  all)
    rc=0
    run_dir "$GPU_DIR" gpu-only 173 || rc=1
    run_dir "$HET_DIR" het 471 || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|gpu-only|het|stress|cpustress]"; exit 64 ;;
esac
