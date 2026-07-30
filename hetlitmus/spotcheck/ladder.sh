#!/usr/bin/env bash
# =========================================================================
# HetLitmus dev-tier LADDER -- seven rungs, run on the rented instance.
# =========================================================================
# WHAT THIS IS.  A MACHINERY spot check: does the emitted harness build, link,
# launch, rendezvous across the two devices, drive its knobs, keep its controls
# hot, print the right reporting frame for its oracle class, and pool across
# invocations?  Every one of those is a property of the CODE, and every one of
# them can be checked on a GPU that is not a GH200.
#
# WHAT THIS IS NOT.  It is not an evaluation and its numbers are not results.
# A non-GH200 box has no ATS and no NVLink-C2C, so the shared vars do not sit on
# one cache line under a live hardware-coherence protocol; they migrate, or they
# cross PCIe.  The compound-model oracle in expected-nvidia.csv was DERIVED for
# GH200 (ARMv9 Grace + Hopper PTX).  So:
#
#   * a NULL here says nothing about the CMCM.  Different machine, different
#     window, different coherence mechanism.
#   * a SIGHTING on a Disallowed row here is NOT a refutation of the compound
#     model either -- but it IS a five-alarm machinery event (or a genuinely
#     interesting hardware fact) and the ladder stops and says so.
#
# Results land in results-devtier-<date>-<host>/ and MUST NOT be merged with
# GH200 evaluation data.  See README.md.
#
# ---- RUNTIME KNOBS -------------------------------------------------------
# The harness has exactly FIVE runtime (getenv) knobs.  Everything else --
# HET_PLACE, the stress percentages, HET_NWIN, SIZE_OF_TEST, NUMBER_OF_RUN -- is
# compile-time and is set through the compiler, e.g.
#   make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"
# (het_verdict.h is explicit about why: a -D the device code can see is exactly
# how B4's stress layer came to be silently folded away.)
#
#   HET_ALLOC      auto|malloc|managed|pinned   shared-memory mode      (PORT1)
#   HET_RUNS_MAX   runs this invocation, clamped to the compiled NUMBER_OF_RUN
#   HET_ADAPTIVE   1 => consult het_campaign_should_stop() after every run
#   HET_P_GOAL     stop a bound-needing row once p_bound <= this
#   HET_SEED       overrides the compiled seed base; MUST vary per invocation
#
# Ladder defaults, deliberately tiny -- this is a smoke ladder, not a campaign:
LADDER_RUNS_TINY="${LADDER_RUNS_TINY:-2}"     # rungs 2-3
LADDER_RUNS_MAIN="${LADDER_RUNS_MAIN:-4}"     # rungs 4-5
LADDER_BUDGET="${LADDER_BUDGET:-16}"          # rung 6; > NUMBER_OF_RUN (10) so
                                              # a bound row MUST take >= 2
                                              # invocations and pooling engages
LADDER_SEED0="${LADDER_SEED0:-20260731}"
LADDER_TIMEOUT="${LADDER_TIMEOUT:-300}"       # seconds per harness invocation.
                                              # Not optional: HET_ALLOC=pinned
                                              # on a device without native host
                                              # atomics can hang at the barrier
                                              # (the harness warns about it).
# =========================================================================
# This script needs bash (arrays, mapfile, pipefail).  `sh ladder.sh' would run
# it under dash on Debian/Ubuntu and die on line 1 of the real work, so re-exec
# rather than rely on the operator getting the invocation right.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail        # NOT -e: a failed rung is DATA, to be tabled, not fatal

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE/tests"
TESTS_FILE="$HERE/TESTS.txt"

# ---- refusals -----------------------------------------------------------
die() { echo "ladder: REFUSING -- $*" >&2; exit 2; }

[ -d "$TESTS_DIR" ] || die "no tests/ next to this script (is this the unpacked bundle?)"
[ -r "$TESTS_FILE" ] || die "no TESTS.txt next to this script"

mapfile -t TESTS < <(grep -vE '^[[:space:]]*(#|$)' "$TESTS_FILE" | awk '{print $1}')
[ "${#TESTS[@]}" -gt 0 ] || die "TESTS.txt names no tests"

# The CPU ISA is a property of the EMITTED harness, so read it from the harness
# rather than hardcoding it: the emitted Makefile carries HET_HOST_ISA and the
# link guard compares against exactly that.
WANT_ISA="$(sed -n 's/^HET_HOST_ISA *?*= *//p' "$TESTS_DIR/${TESTS[0]}/Makefile" | head -1)"
WANT_ISA="${WANT_ISA:-aarch64}"
HAVE_ISA="$(uname -m)"
[ "$HAVE_ISA" = "$WANT_ISA" ] || die "uname -m is '$HAVE_ISA' but these harnesses carry $WANT_ISA CPU asm; on any other host the CPU object is the portable shim and every number below would be a fiction"
command -v nvcc >/dev/null 2>&1 || die "nvcc not on PATH"
command -v make >/dev/null 2>&1 || die "make not on PATH"

RESULTS="${RESULTS:-$HERE/results-devtier-$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"
mkdir -p "$RESULTS"

# CUDA_ARCH: prefer what the probe measured.  Never -arch=native (CUDA 11.5
# update 1 and later only), never a guess.
if [ -z "${CUDA_ARCH:-}" ] && [ -r "$RESULTS/probe.txt" ]; then
  CUDA_ARCH="$(sed -n 's/^suggested_cuda_arch=//p' "$RESULTS/probe.txt" | head -1)"
fi
[ -n "${CUDA_ARCH:-}" ] || die "CUDA_ARCH unset and $RESULTS/probe.txt has no suggested_cuda_arch -- run 'sh probe.sh' first (it is rung -1 for a reason)"
export CUDA_ARCH

# Probe facts the conditional bites need.  Absent probe.txt => those bites are
# reported as NOT RUN, never as passed.
pv() { [ -r "$RESULTS/probe.txt" ] && sed -n "s/^$1=//p" "$RESULTS/probe.txt" | head -1; }
P_PAGEABLE="$(pv pageableMemoryAccess)"
P_CMA="$(pv concurrentManagedAccess)"
P_COOP="$(pv cooperativeLaunch)"

echo "=========================================================================="
echo "HetLitmus dev-tier ladder"
echo "  host        $(uname -srm)   $( (hostname 2>/dev/null || echo '?') )"
echo "  CPU ISA     want $WANT_ISA / have $HAVE_ISA"
echo "  CUDA_ARCH   $CUDA_ARCH"
echo "  tests       ${#TESTS[@]}: ${TESTS[*]}"
echo "  results     $RESULTS"
echo "  probe       pageable=${P_PAGEABLE:-?} cma=${P_CMA:-?} coop=${P_COOP:-?}"
echo "=========================================================================="
if [ "${P_COOP:-1}" = "0" ]; then
  echo "ladder: probe says cooperativeLaunch=0 -- the harness returns 2 before it"
  echo "        does anything.  Continuing so the table records it, but expect"
  echo "        every run rung to fail with rc=2."
fi

declare -a ROWS=()
row() { ROWS+=("$(printf '%-9s %-34s %-10s %s' "$1" "$2" "$3" "$4")"); }

# ---- one harness invocation --------------------------------------------
# usage: invoke <test> <invtag> [ENV=VAL ...]
# Returns the harness rc; the whole transcript goes to <test>-<invtag>.log.
invoke() {
  local t="$1" tag="$2"; shift 2
  local log="$RESULTS/$t-$tag.log" rc=0
  {
    echo "### $t / $tag"
    echo "### env: $*"
    echo "### inherited HET_ALLOC=${HET_ALLOC:-<unset>}"
    echo "### date: $(date -Is 2>/dev/null || date)"
  } > "$log"
  ( cd "$TESTS_DIR/$t" && env "$@" timeout "$LADDER_TIMEOUT" "./$t" ) >> "$log" 2>&1
  rc=$?
  echo "### rc=$rc" >> "$log"
  [ "$rc" -eq 124 ] && echo "### TIMEOUT after ${LADDER_TIMEOUT}s" >> "$log"
  return "$rc"
}

# Machinery assertions on a transcript.  These check the harness SAID the right
# kind of thing, never what the hardware did.
check_machinery() { # log test expected-oracle-class
  local log="$1" t="$2" oclass="$3" bad=0
  grep -q '^HetLitmus: shared-mem mode=' "$log" || { echo "    MISSING: shared-mem banner"; bad=1; }
  grep -q "^HetVerdict $t \[" "$log"            || { echo "    MISSING: HetVerdict frame line"; bad=1; }
  grep -q "^HetStats $t oracle=" "$log"         || { echo "    MISSING: HetStats machine line"; bad=1; }
  grep -q "^HetStats $t oracle=$oclass " "$log" || { echo "    MISSING: machine line does not carry oracle=$oclass"; bad=1; }
  grep -q "^HetVerdict $t \[.*\] oracle=$oclass " "$log" || { echo "    MISSING: verdict frame does not carry oracle=$oclass"; bad=1; }
  return $bad
}

oclass_of() { awk -F, -v t="$1" '$1==t{print $2; exit}' "$HERE/expected-nvidia.csv"; }

# =========================================================================
# RUNG 0 -- build the subset, objects then executable.
# =========================================================================
echo; echo "== rung 0: build =="
r0=0
for t in "${TESTS[@]}"; do
  log="$RESULTS/$t-build.log"
  ( cd "$TESTS_DIR/$t" && sh comp.sh cuda && make cuda-bin ) > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -x "$TESTS_DIR/$t/$t" ]; then
    echo "  ok    $t"
  else
    echo "  FAIL  $t (rc=$rc, see $log)"; r0=1
  fi
done
row 0 "build subset (comp.sh + cuda-bin)" "$([ $r0 -eq 0 ] && echo PASS || echo FAIL)" "${#TESTS[@]} harness dirs"
[ $r0 -eq 0 ] || { echo; echo "ladder: nothing to run without binaries -- stopping at rung 0."; printf '%s\n' "${ROWS[@]}"; exit 1; }

# =========================================================================
# RUNG 1 -- the negative-knob bites.  These are the PORT1 guards whose FATAL
# paths need a GPU and so could not be bitten on the dev box.
# =========================================================================
echo; echo "== rung 1: negative-knob bites =="
BT="${TESTS[0]}"
r1=0; r1note=""

# (a) an unknown HET_ALLOC must FAIL CLOSED -- nonzero exit, named reason, and
#     no silent fallback to auto.  Always applicable.
if invoke "$BT" bite-alloc-garbage HET_ALLOC=garbage HET_RUNS_MAX=1; then
  echo "  FAIL  HET_ALLOC=garbage EXITED 0 -- the knob is not fail-closed"; r1=1
else
  rc=$?
  if grep -q 'is not a shared-memory mode' "$RESULTS/$BT-bite-alloc-garbage.log"; then
    echo "  ok    HET_ALLOC=garbage -> rc=$rc + FATAL names the knob"
  else
    echo "  FAIL  HET_ALLOC=garbage -> rc=$rc but WITHOUT the FATAL line (wrong reason)"; r1=1
  fi
fi

# (b) liveness the OTHER way: a legal forced mode must be ACCEPTED and must
#     appear in the banner.  A knob that only ever refuses is not a live knob.
if [ "${P_CMA:-0}" = "1" ]; then
  invoke "$BT" bite-alloc-managed-ok HET_ALLOC=managed HET_RUNS_MAX=1; rc=$?
  if grep -q '^HetLitmus: shared-mem mode=managed (HET_ALLOC=managed' "$RESULTS/$BT-bite-alloc-managed-ok.log"; then
    echo "  ok    HET_ALLOC=managed accepted (rc=$rc), banner reports mode=managed"
  else
    echo "  FAIL  HET_ALLOC=managed did not report mode=managed in the banner"; r1=1
  fi
else
  echo "  n/a   forced-managed-accepted: probe says concurrentManagedAccess=${P_CMA:-?}"
  r1note="$r1note managed-accept:n/a"
fi

# (c) forced managed where the probe says CMA=0 must be FATAL.  Only meaningful
#     on such a box; anywhere else it is NOT RUN, and says so.
if [ "${P_CMA:-1}" = "0" ]; then
  if invoke "$BT" bite-alloc-managed-fatal HET_ALLOC=managed HET_RUNS_MAX=1; then
    echo "  FAIL  HET_ALLOC=managed EXITED 0 on a concurrentManagedAccess=0 device"; r1=1
  else
    grep -q 'cudaDevAttrConcurrentManagedAccess=0' "$RESULTS/$BT-bite-alloc-managed-fatal.log" \
      && echo "  ok    HET_ALLOC=managed -> FATAL naming concurrentManagedAccess" \
      || { echo "  FAIL  refused, but not for the named reason"; r1=1; }
  fi
else
  echo "  n/a   forced-managed-FATAL: needs concurrentManagedAccess=0, this box has ${P_CMA:-?}"
  r1note="$r1note managed-fatal:n/a"
fi

# (d) same for forced malloc on a device without pageable access.
if [ "${P_PAGEABLE:-1}" = "0" ]; then
  if invoke "$BT" bite-alloc-malloc-fatal HET_ALLOC=malloc HET_RUNS_MAX=1; then
    echo "  FAIL  HET_ALLOC=malloc EXITED 0 on a pageableMemoryAccess=0 device"; r1=1
  else
    grep -q 'cudaDevAttrPageableMemoryAccess=0' "$RESULTS/$BT-bite-alloc-malloc-fatal.log" \
      && echo "  ok    HET_ALLOC=malloc -> FATAL naming pageableMemoryAccess" \
      || { echo "  FAIL  refused, but not for the named reason"; r1=1; }
  fi
else
  echo "  n/a   forced-malloc-FATAL: needs pageableMemoryAccess=0, this box has ${P_PAGEABLE:-?}"
  r1note="$r1note malloc-fatal:n/a"
fi
row 1 "HET_ALLOC bites" "$([ $r1 -eq 0 ] && echo PASS || echo FAIL)" "fail-closed + liveness;${r1note:- all applicable}"

# =========================================================================
# RUNG 2 -- an Allowed harness that co-runs ONLY the canary (2 instances), at
# tiny N.  Checks the frames and the caveat machinery, not the physics.
# =========================================================================
echo; echo "== rung 2: canary pair, tiny N =="
T2="MP-cg-cta-acquire"; r2=0
if [ -d "$TESTS_DIR/$T2" ]; then
  invoke "$T2" rung2 HET_RUNS_MAX="$LADDER_RUNS_TINY" HET_SEED="$LADDER_SEED0"; rc=$?
  log="$RESULTS/$T2-rung2.log"
  [ "$rc" -eq 0 ] || { echo "  FAIL  rc=$rc"; r2=1; }
  check_machinery "$log" "$T2" "$(oclass_of "$T2")" || r2=1
  grep -q 'HET_CANARY_COMPILED_IN' "$TESTS_DIR/$T2/$T2.cu" || { echo "    MISSING: no canary compiled in"; r2=1; }
  echo "    frame:  $(grep -m1 "^HetVerdict $T2 " "$log" | cut -c1-140)"
  echo "    caveats:$(grep -c '  CAVEAT:' "$log") line(s)"
  grep -m3 '  CAVEAT:' "$log" | sed 's/^/      /'
else
  echo "  FAIL  $T2 not in the bundle"; r2=1
fi
row 2 "canary pair, tiny N ($T2)" "$([ $r2 -eq 0 ] && echo PASS || echo FAIL)" "frames + caveats printed"

# =========================================================================
# RUNG 3 -- the Disallowed harness: T + mu(T) + canary in one launch.
# Expect 0 weak.  A SIGHTING is not a ladder failure -- it is an alarm.
# =========================================================================
echo; echo "== rung 3: Disallowed triple =="
T3="MP-cg-sys-fence-2s"; r3=0; r3note="0 weak"
if [ -d "$TESTS_DIR/$T3" ]; then
  invoke "$T3" rung3 HET_RUNS_MAX="$LADDER_RUNS_TINY" HET_SEED="$((LADDER_SEED0+1))"; rc=$?
  log="$RESULTS/$T3-rung3.log"
  [ "$rc" -eq 0 ] || { echo "  FAIL  rc=$rc"; r3=1; }
  check_machinery "$log" "$T3" Disallowed || r3=1
  grep -q '#define HET_CONTROL_COMPILED_IN 1' "$TESTS_DIR/$T3/$T3.cu" || { echo "    MISSING: no mu(T) compiled in"; r3=1; }
  k="$(grep -m1 "^HetStats $T3 oracle=" "$log" | tr ' ' '\n' | sed -n 's/^k=//p')"
  echo "    frame:  $(grep -m1 "^HetVerdict $T3 " "$log" | cut -c1-140)"
  echo "    k=${k:-?}"
  if [ -n "${k:-}" ] && [ "$k" != "0" ]; then
    r3note="*** k=$k WEAK SIGHTINGS ON A DISALLOWED ROW ***"
    echo "  !!    $r3note"
    echo "        On a non-GH200 box this is NOT a refutation of the compound model"
    echo "        (wrong machine, wrong oracle).  Stop the ladder and hand it to a"
    echo "        human: it is either a machinery fault or a real hardware fact."
  fi
else
  echo "  FAIL  $T3 not in the bundle"; r3=1
fi
row 3 "Disallowed triple ($T3)" "$([ $r3 -eq 0 ] && echo PASS || echo FAIL)" "$r3note"

# =========================================================================
# RUNG 4 -- the remaining Allowed rows and the NO-ORACLE row.  The point is
# that each prints the frame for ITS OWN oracle class: a NO-ORACLE row must
# never print a validation or a refutation sentence (B6c).
# =========================================================================
echo; echo "== rung 4: Allowed + NO-ORACLE =="
r4=0
for t in R-cg-sys-relaxed 2+2W-cg-sys-relaxed IRIW-gcgc-sys-fence; do
  [ -d "$TESTS_DIR/$t" ] || { echo "  FAIL  $t not in the bundle"; r4=1; continue; }
  oc="$(oclass_of "$t")"
  invoke "$t" rung4 HET_RUNS_MAX="$LADDER_RUNS_MAIN" HET_SEED="$((LADDER_SEED0+2))"; rc=$?
  log="$RESULTS/$t-rung4.log"
  [ "$rc" -eq 0 ] || { echo "  FAIL  $t rc=$rc"; r4=1; }
  check_machinery "$log" "$t" "$oc" || r4=1
  echo "  $t [$oc]"
  echo "    $(grep -m1 "^HetVerdict $t " "$log" | cut -c1-140)"
  if [ "$oc" = "NO-ORACLE" ]; then
    if grep -qE 'REFUT|This is the CMCM validation claim' "$log"; then
      echo "    FAIL: a NO-ORACLE row printed a validation/refutation sentence"; r4=1
    else
      echo "    ok: no validation/refutation sentence (B6c third frame)"
    fi
  fi
done
row 4 "Allowed + NO-ORACLE frames" "$([ $r4 -eq 0 ] && echo PASS || echo FAIL)" "3 rows, per-class frames"

# =========================================================================
# RUNG 5 -- the stress knobs, off then on.  Off is a REBUILD, because the
# stress knobs are compile-time by design; the harness must then say its
# mechanisms are dead rather than quietly reporting a stressed run.
# On a PCIe box the C2C noise pair cannot be homed remotely and must
# self-report degraded whatever the knobs claim.
# =========================================================================
echo; echo "== rung 5: stress off -> on =="
T5="$T3"; r5=0
NOSTRESS_D="-DHET_PRE_STRESS_PCT=0 -DHET_MEM_STRESS_PCT=0 -DHET_CPU_ENEMIES=0 -DHET_CPU_PRELOAD_PCT=0 -DHET_NOISE_CPU=0 -DHET_NOISE_GPU_BLOCKS=0"
if [ -d "$TESTS_DIR/$T5" ]; then
  ( cd "$TESTS_DIR/$T5" && make clean >/dev/null && make cuda-bin NVCC="nvcc $NOSTRESS_D" ) \
      > "$RESULTS/$T5-build-nostress.log" 2>&1 \
    && invoke "$T5" rung5-stress-off HET_RUNS_MAX="$LADDER_RUNS_MAIN" HET_SEED="$((LADDER_SEED0+3))"
  off_rc=$?
  ( cd "$TESTS_DIR/$T5" && make clean >/dev/null && make cuda-bin ) \
      > "$RESULTS/$T5-build-stress.log" 2>&1 \
    && invoke "$T5" rung5-stress-on HET_RUNS_MAX="$LADDER_RUNS_MAIN" HET_SEED="$((LADDER_SEED0+4))"
  on_rc=$?
  offlog="$RESULTS/$T5-rung5-stress-off.log"; onlog="$RESULTS/$T5-rung5-stress-on.log"
  [ "$off_rc" -eq 0 ] && [ "$on_rc" -eq 0 ] || { echo "  FAIL  off rc=$off_rc on rc=$on_rc"; r5=1; }
  # The knobs are LIVE if the two transcripts differ where stress is reported.
  offline="$(grep -m1 '^HetLitmus cpu-stress:' "$offlog")"
  online="$(grep -m1 '^HetLitmus cpu-stress:' "$onlog")"
  echo "    off: ${offline:-<missing>}"
  echo "    on : ${online:-<missing>}"
  if [ -z "$offline" ] || [ -z "$online" ]; then
    echo "  FAIL  no cpu-stress line -- cannot tell the two builds apart"; r5=1
  elif [ "$offline" = "$online" ]; then
    echo "  FAIL  the stress-off and stress-on builds report IDENTICAL stress config"
    echo "        -- the -D knobs did not reach the build (an inert knob)"; r5=1
  else
    echo "  ok    the two builds differ in their reported stress config"
  fi
  # LIVENESS BOTH WAYS, off the HetObs record rather than off a prose caveat.
  # A tally that cannot go to zero is not evidence, and neither is one that
  # cannot go non-zero -- so assert BOTH directions on the mechanisms whose
  # counters the record actually carries.  (The caveat strings were the wrong
  # instrument: with the knobs at 0 the mechanisms are not REQUESTED, so the
  # `dead' disqualifiers correctly do not fire and nothing says "unstressed".)
  obsfield() { grep -m1 '^HetObs ' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
  for pair in "do_stress_rounds GPU scratchpad" "enemy_rounds CPU enemies" "preload M3 preload"; do
    f="${pair%% *}"; what="${pair#* }"
    voff="$(obsfield "$offlog" "$f")"; von="$(obsfield "$onlog" "$f")"
    if [ "${voff:-x}" = "0" ] && [ -n "${von:-}" ] && [ "${von:-0}" != "0" ]; then
      echo "  ok    $what: $f 0 (off) -> $von (on)"
    else
      echo "  FAIL  $what: $f off='${voff:-<missing>}' on='${von:-<missing>}' -- a"
      echo "        counter that cannot go to zero when the knob says off, or"
      echo "        cannot go non-zero when it says on, is not a live mechanism"; r5=1
    fi
  done
  reqoff="$(obsfield "$offlog" req)"; reqon="$(obsfield "$onlog" req)"
  if [ -n "$reqoff" ] && [ "$reqoff" != "$reqon" ]; then
    echo "  ok    requested-mechanism mask differs: $reqoff (off) vs $reqon (on)"
  else
    echo "  FAIL  requested-mechanism mask identical ($reqoff) -- the -D knobs did"
    echo "        not reach the compiled record"; r5=1
  fi
  # The C2C noise pair off ATS/C2C: it must SAY it is not interconnect stress,
  # by either route -- could not be homed remotely, or could not be allocated.
  if grep -qE 'noise buffer could not be homed|could not allocate the .* noise buffer|no interconnect-stress lever' "$onlog"; then
    echo "  ok    the C2C noise pair self-reports DEGRADED/DISABLED (expected off C2C)"
  else
    echo "  note  no noise-degradation warning in $onlog -- if this box has no ATS,"
    echo "        read it by hand: an interconnect stressor that claims to be live"
    echo "        off C2C is exactly the bug class this project keeps finding."
  fi
else
  echo "  FAIL  $T5 not in the bundle"; r5=1
fi
row 5 "stress off -> on ($T5)" "$([ $r5 -eq 0 ] && echo PASS || echo FAIL)" "knobs live + degradation declared"

# =========================================================================
# RUNG 6 -- campaign.py: >= 2 invocations per row, fresh seed each time, so
# the cross-invocation pooling and the B7/B7b statistics actually engage.
# The budget is deliberately above the compiled NUMBER_OF_RUN (10) so a bound
# row CANNOT finish in one invocation.
# =========================================================================
echo; echo "== rung 6: campaign pooling =="
# --control-map IS FED expected-nvidia.csv, NOT control-map.csv, and that is not
# a slip.  campaign.py's read_control_map skips the header row by testing
# f[0] == "Litmus" -- which is expected-nvidia.csv's first column name.
# control-map.csv's header is `Test,Expected,...', so its header row is ingested
# as a test called "Test" with oracle class "Expected" and campaign.py dies with
# `control map carries unknown oracle class(es) ['Expected']'.  campaign.py only
# ever reads (test, class) from columns 1-2, which both files carry identically
# (hetlitmus-controlmap gates that they agree), so pointing it at the file it can
# actually parse is correct today; the header-skip is a campaign.py bug and is
# reported upstream of this ladder, not patched here.
r6=0
STATE="$RESULTS/campaign-state.csv"
python3 "$HERE/campaign.py" \
  --corpus "$TESTS_DIR" \
  --control-map "$HERE/expected-nvidia.csv" \
  --runner "sh $HERE/run-one.sh {dir} {test}" \
  --tests "$(IFS=,; echo "${TESTS[*]}")" \
  --budget-runs "$LADDER_BUDGET" --allowed-budget-runs "$LADDER_BUDGET" \
  --seed0 "$LADDER_SEED0" --state "$STATE" \
  > "$RESULTS/campaign.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  FAIL  campaign.py rc=$rc (see $RESULTS/campaign.log)"; r6=1; }
if [ -r "$STATE" ]; then
  minv="$(awk -F, 'NR>1 && $4!="" {if (m=="" || $4<m) m=$4} END{print m+0}' "$STATE")"
  echo "    state: $STATE"
  column -s, -t < "$STATE" 2>/dev/null | cut -c1-160 | head -8 || head -8 "$STATE"
  if [ "${minv:-0}" -lt 2 ]; then
    echo "  note  a row took only ${minv:-0} invocation(s): pooling engaged for the"
    echo "        others, but check WHY (an Allowed row that fired stops at OBSERVED,"
    echo "        which is a legitimate early stop, not a fault)."
  else
    echo "  ok    every row took >= 2 invocations -- pooling and B7 stats engaged"
  fi
else
  echo "  FAIL  no campaign state written"; r6=1
fi
row 6 "campaign pooling (>=2 invocations)" "$([ $r6 -eq 0 ] && echo PASS || echo FAIL)" "budget=$LADDER_BUDGET"

# =========================================================================
echo
echo "=========================================================================="
echo "LADDER SUMMARY   $RESULTS"
echo "=========================================================================="
printf '%-9s %-34s %-10s %s\n' RUNG WHAT VERDICT NOTE
printf '%s\n' "${ROWS[@]}"
echo "--------------------------------------------------------------------------"
fails=0
for r in "${ROWS[@]}"; do case "$r" in *FAIL*) fails=$((fails+1));; esac; done
echo "rungs failed: $fails / ${#ROWS[@]}"
echo
echo "REMINDER: this is dev-tier MACHINERY evidence.  Nothing here validates or"
echo "refutes the compound memory model, and none of it may be merged with GH200"
echo "evaluation data.  Keep $RESULTS as-is and ship it whole."
exit "$fails"
