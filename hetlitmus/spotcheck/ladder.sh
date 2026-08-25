#!/usr/bin/env bash
# The dev-tier ladder, run from an unpacked bundle on the instance: build, the
# HET_ALLOC bites, the subset's rows, stress off -> on, campaign pooling.  A
# rung FAILS when the machinery it drives did not do its job on this box; every
# count it prints describes this box and is compared against nothing.  Results
# land in results-devtier-<date>-<host>/ and must NOT be merged with GH200
# evaluation data.  Runtime knobs, the subset and the known quirks: README.md
# beside this script.

# Ladder defaults, deliberately tiny -- this is a smoke ladder, not a campaign.
LADDER_RUNS_TINY="${LADDER_RUNS_TINY:-2}"     # rung 2
LADDER_RUNS_MAIN="${LADDER_RUNS_MAIN:-4}"     # rung 3
LADDER_BUDGET="${LADDER_BUDGET:-16}"          # rung 4; > NUMBER_OF_RUN so pooling engages
LADDER_SEED0="${LADDER_SEED0:-20260731}"
LADDER_TIMEOUT="${LADDER_TIMEOUT:-900}"       # seconds per harness invocation
# This script needs bash (arrays, mapfile, pipefail), so re-exec rather than
# rely on the operator not typing `sh ladder.sh'.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail        # NOT -e: a failed rung is data, tabled, not fatal

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE/tests"
TESTS_FILE="$HERE/TESTS.txt"

# ---- refusals -----------------------------------------------------------
die() { echo "ladder: REFUSING -- $*" >&2; exit 2; }

[ -d "$TESTS_DIR" ] || die "no tests/ next to this script (is this the unpacked bundle?)"
[ -r "$TESTS_FILE" ] || die "no TESTS.txt next to this script"

mapfile -t TESTS < <(grep -vE '^[[:space:]]*(#|$)' "$TESTS_FILE" | awk '{print $1}')
[ "${#TESTS[@]}" -gt 0 ] || die "TESTS.txt names no tests"

# The CPU ISA is a property of the EMITTED harness, so read it from the emitted
# Makefile: the link guard compares against exactly that.
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
[ -n "${CUDA_ARCH:-}" ] || die "CUDA_ARCH unset and $RESULTS/probe.txt has no suggested_cuda_arch -- run 'sh probe-cuda.sh' first"
export CUDA_ARCH

# Probe facts the conditional arms need.  Absent probe.txt => they are reported
# as NOT run, never as passed.
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
  echo "        does anything; expect every run rung to fail with rc=2."
fi

declare -a ROWS=()
row() { ROWS+=("$(printf '%-9s %-34s %-10s %s' "$1" "$2" "$3" "$4")"); }

# usage: invoke <test> <invtag> [ENV=VAL ...]; returns the harness rc, writes
# the whole transcript to <test>-<invtag>.log.
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

# The line shapes a rung reads its result off: that the harness SAID the right
# kind of thing, never what the hardware did.
check_machinery() { # log test
  local log="$1" t="$2" bad=0
  grep -q '^HetLitmus: shared-mem mode=' "$log" || { echo "    MISSING: shared-mem banner"; bad=1; }
  # The test name is data, not a pattern: `2+2W-cg-sys-relaxed' in an ERE is a
  # quantifier, so the name is compared as a string.
  awk -v t="$t" '$1 == "HetVerdict" && $2 == t &&
                 $0 ~ /^HetVerdict [^ ]+( CPU-ONLY)? run=[0-9]+: [A-Z-]+$/ \
                 { found = 1 } END { exit !found }' "$log" \
    || { echo "    MISSING: HetVerdict frame line"; bad=1; }
  grep -q "^HetStats $t cpu_only=" "$log" || { echo "    MISSING: HetStats machine line"; bad=1; }
  grep -q "^HetStats $t: " "$log"         || { echo "    MISSING: HetStats human block"; bad=1; }
  return $bad
}

# One field of the HetStats machine line, by name.  Same string-not-pattern rule
# as above: the test name is compared with grep -F.
statfield() { # log test field
  grep -m1 -F "HetStats $2 cpu_only=" "$1" | tr ' ' '\n' | sed -n "s/^$3=//p"
}

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
# RUNG 1 -- the HET_ALLOC knob, refused and accepted.
# =========================================================================
echo; echo "== rung 1: HET_ALLOC bites =="
BT="${TESTS[0]}"
r1=0; r1note=""

# (a) an unknown mode must FAIL CLOSED: non-zero exit, named reason, no silent
#     fallback to auto.
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

# (b) liveness the other way: a legal forced mode must be accepted and must
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
row 1 "HET_ALLOC bites" "$([ $r1 -eq 0 ] && echo PASS || echo FAIL)" "fail-closed + liveness;${r1note:- all applicable}"

# =========================================================================
# RUNG 2 -- every row of the subset at tiny N; what it reads is each launch's
# frames, not the physics.
# =========================================================================
echo; echo "== rung 2: the subset's rows, tiny N =="
r2=0; i=0
for t in "${TESTS[@]}"; do
  i=$((i+1))
  invoke "$t" rung2 HET_RUNS_MAX="$LADDER_RUNS_TINY" HET_SEED="$((LADDER_SEED0+i))"; rc=$?
  log="$RESULTS/$t-rung2.log"
  echo "  $t"
  [ "$rc" -eq 0 ] || { echo "  FAIL  $t rc=$rc"; r2=1; }
  check_machinery "$log" "$t" || r2=1
  echo "    frame:  $(grep -m1 "^HetVerdict $t " "$log" | cut -c1-140)"
  # What the rendezvous cost this launch decides whether the frame above is a
  # reading at all: an iteration only one side started was discarded.
  echo "    rdv:    scored=$(statfield "$log" "$t" scored) discarded=$(statfield "$log" "$t" discarded) k=$(statfield "$log" "$t" k)"
  echo "    caveats:$(grep -c '  CAVEAT:' "$log") line(s)"
  grep -m3 '  CAVEAT:' "$log" | sed 's/^/      /'
done
row 2 "the subset's rows, tiny N" "$([ $r2 -eq 0 ] && echo PASS || echo FAIL)" "${#TESTS[@]} rows, frames printed"

# =========================================================================
# RUNG 3 -- the stress knobs, off then on.  Off is a rebuild: the knobs are
# compile-time, and the harness must then report its mechanisms dead.
# =========================================================================
echo; echo "== rung 3: stress off -> on =="
T3="MP-cg-sys-fence-2s"; r3=0
NOSTRESS_D="-DHET_PRE_STRESS_PCT=0 -DHET_MEM_STRESS_PCT=0 -DHET_CPU_ENEMIES=0 -DHET_CPU_PRELOAD_PCT=0 -DHET_NOISE_CPU=0 -DHET_NOISE_GPU_BLOCKS=0"
if [ -d "$TESTS_DIR/$T3" ]; then
  ( cd "$TESTS_DIR/$T3" && make clean >/dev/null && make cuda-bin NVCC="nvcc $NOSTRESS_D" ) \
      > "$RESULTS/$T3-build-nostress.log" 2>&1 \
    && invoke "$T3" rung3-stress-off HET_RUNS_MAX="$LADDER_RUNS_MAIN" HET_SEED="$((LADDER_SEED0+30))"
  off_rc=$?
  ( cd "$TESTS_DIR/$T3" && make clean >/dev/null && make cuda-bin ) \
      > "$RESULTS/$T3-build-stress.log" 2>&1 \
    && invoke "$T3" rung3-stress-on HET_RUNS_MAX="$LADDER_RUNS_MAIN" HET_SEED="$((LADDER_SEED0+31))"
  on_rc=$?
  offlog="$RESULTS/$T3-rung3-stress-off.log"; onlog="$RESULTS/$T3-rung3-stress-on.log"
  [ "$off_rc" -eq 0 ] && [ "$on_rc" -eq 0 ] || { echo "  FAIL  off rc=$off_rc on rc=$on_rc"; r3=1; }
  # A rebuild is where a reporting frame goes missing, so both builds are read
  # for the line shapes before their knobs are compared.
  for l in "$offlog" "$onlog"; do
    check_machinery "$l" "$T3" || r3=1
  done
  # The knobs are LIVE if the two transcripts differ where stress is reported.
  offline="$(grep -m1 '^HetLitmus cpu-stress:' "$offlog")"
  online="$(grep -m1 '^HetLitmus cpu-stress:' "$onlog")"
  echo "    off: ${offline:-<missing>}"
  echo "    on : ${online:-<missing>}"
  if [ -z "$offline" ] || [ -z "$online" ]; then
    echo "  FAIL  no cpu-stress line -- cannot tell the two builds apart"; r3=1
  elif [ "$offline" = "$online" ]; then
    echo "  FAIL  identical stress config off and on -- the -D knobs did not reach the build"; r3=1
  else
    echo "  ok    the two builds differ in their reported stress config"
  fi
  # Liveness BOTH ways, read off the HetObs record: a tally that cannot go to
  # zero is not evidence, and neither is one that cannot go non-zero.
  obsfield() { grep -m1 '^HetObs ' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
  for pair in "do_stress_rounds GPU scratchpad" "enemy_rounds CPU enemies" "preload CPU cache preload"; do
    f="${pair%% *}"; what="${pair#* }"
    voff="$(obsfield "$offlog" "$f")"; von="$(obsfield "$onlog" "$f")"
    if [ "${voff:-x}" = "0" ] && [ -n "${von:-}" ] && [ "${von:-0}" != "0" ]; then
      echo "  ok    $what: $f 0 (off) -> $von (on)"
    else
      echo "  FAIL  $what: $f off='${voff:-<missing>}' on='${von:-<missing>}' -- not a live mechanism"; r3=1
    fi
  done
  reqoff="$(obsfield "$offlog" req)"; reqon="$(obsfield "$onlog" req)"
  if [ -n "$reqoff" ] && [ "$reqoff" != "$reqon" ]; then
    echo "  ok    requested-mechanism mask differs: $reqoff (off) vs $reqon (on)"
  else
    echo "  FAIL  requested-mechanism mask identical ($reqoff) -- the -D knobs did not reach the record"; r3=1
  fi
  # The C2C noise pair off ATS/C2C must SAY it is not interconnect stress, by
  # either route -- not homed remotely, or not allocated.
  if grep -qE 'noise buffer could not be homed|could not allocate the .* noise buffer|no interconnect-stress lever' "$onlog"; then
    echo "  ok    the C2C noise pair self-reports DEGRADED/DISABLED (expected off C2C)"
  else
    echo "  note  no noise-degradation warning in $onlog -- on a box with no ATS,"
    echo "        read it by hand: a stressor claiming to be live off C2C is a bug."
  fi
else
  echo "  FAIL  $T3 not in the bundle"; r3=1
fi
row 3 "stress off -> on ($T3)" "$([ $r3 -eq 0 ] && echo PASS || echo FAIL)" "knobs live + degradation declared"

# =========================================================================
# RUNG 4 -- campaign.py: >= 2 invocations per row, fresh seed each time, and a
# budget above NUMBER_OF_RUN so a null row CANNOT finish in one invocation.
# =========================================================================
echo; echo "== rung 4: campaign pooling =="
r4=0
STATE="$RESULTS/campaign-state.csv"
# A campaign is never resumed, so campaign.py refuses an existing --state: this
# rung starts from a fresh file rather than yesterday's.
rm -f "$STATE"
python3 "$HERE/campaign.py" \
  --corpus "$TESTS_DIR" \
  --runner "sh $HERE/run-one.sh {dir} {test}" \
  --tests "$(IFS=,; echo "${TESTS[*]}")" \
  --budget-runs "$LADDER_BUDGET" \
  --seed0 "$LADDER_SEED0" --state "$STATE" \
  > "$RESULTS/campaign.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "  FAIL  campaign.py rc=$rc (see $RESULTS/campaign.log)"; r4=1; }
if [ -r "$STATE" ]; then
  minv="$(awk -F, 'NR>1 && $3!="" {if (m=="" || $3<m) m=$3} END{print m+0}' "$STATE")"
  echo "    state: $STATE"
  column -s, -t < "$STATE" 2>/dev/null | cut -c1-160 | head -8 || head -8 "$STATE"
  if [ "${minv:-0}" -lt 2 ]; then
    echo "  note  a row took only ${minv:-0} invocation(s) -- check WHY (a row whose"
    echo "        sighting corroborated stops there, a legitimate early stop)."
  else
    echo "  ok    every row took >= 2 invocations -- runs, sightings and clean runs"
    echo "        were pooled across them"
  fi
else
  echo "  FAIL  no campaign state written"; r4=1
fi
row 4 "campaign pooling (>=2 invocations)" "$([ $r4 -eq 0 ] && echo PASS || echo FAIL)" "budget=$LADDER_BUDGET"

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
echo "REMINDER: dev-tier MACHINERY evidence.  Every count in $RESULTS describes"
echo "this box, was compared against no model, and must never be merged with"
echo "GH200 evaluation data.  Keep the dir as-is and ship it whole."
exit "$fails"
