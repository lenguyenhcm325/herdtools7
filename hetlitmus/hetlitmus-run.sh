#!/usr/bin/env bash
# =========================================================================
# HetLitmus device session: ONE entry point, one chain, on a real machine.
# preflight -> probe -> emit -> compile -> campaign -> collect.  Every step
# fails CLOSED with a named reason, and every value the session turned on --
# the resolved device arch, the (CPU ISA x GPU dialect) pair, the control map
# or the absence of one -- is written into the results dir as a fact, because
# a run whose arch or oracle was decided invisibly cannot be read afterwards.
#
# Composition only: probe.sh / probe-hip.sh probe, litmus7 emits, the emitted
# comp.sh + Makefile build, campaign.py schedules, run-one.sh invokes.  What is
# new here is the ORDER, the refusals and the record.
#
# There is no smoke-ladder step between compile and campaign: spotcheck/
# ladder.sh is that, driven separately, and this wrapper does not wrap it.
#
# Usage: --help.  Exit: 0 = session complete; 2 = refused (configuration or
# machine); 1 = the campaign errored a row or corroborated a sighting.
# =========================================================================
# Needs bash (arrays, mapfile); `sh hetlitmus-run.sh' would run it under dash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

# Bite seams, the same idiom as emit-all.sh's HET_LITMUS7: a gate points these at
# stand-ins to drive the chain on a box with no device.  Each is RECORDED in the
# results dir when it is not the default, so a bundle can never pass a stub probe
# or a stub compiler off as the real one.
LITMUS7="${HET_LITMUS7:-$LITMUS7}"
# Seconds per harness invocation.  campaign.py has no timeout of its own, and a
# harness that stalls at the rendezvous (the shared-memory banner names the
# allocators that can) would otherwise hold the session open indefinitely.
HET_RUN_TIMEOUT="${HET_RUN_TIMEOUT:-300}"

usage() {
  cat <<'EOF'
usage: hetlitmus-run.sh --gpu-target cuda|hip --corpus DIR [options]

  --gpu-target cuda|hip      the GPU dialect litmus7 renders (MANDATORY)
  --corpus DIR               directory of .litmus tests (MANDATORY)
  --arch auto|sm_XX|gfxXXX   device arch to build for (default: auto)
  --budget-runs N            max runs per bound row (default 100)
  --p-goal P                 stop a bound row once its pooled bound <= P
  --out DIR                  results dir (default hetlitmus/run-out/<stamp>)
  --reuse-emitted            reuse <out>/emit instead of emitting again
  --dry-run                  print the plan and do nothing else
EOF
}

die() { echo "hetlitmus-run: REFUSING -- $*" >&2; exit 2; }

GPU_TARGET="" ; CORPUS="" ; ARCH="auto" ; BUDGET_RUNS=100 ; P_GOAL=""
OUT="" ; REUSE=0 ; DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu-target)    GPU_TARGET="${2:-}" ; shift 2 ;;
    --corpus)        CORPUS="${2:-}" ; shift 2 ;;
    --arch)          ARCH="${2:-}" ; shift 2 ;;
    --budget-runs)   BUDGET_RUNS="${2:-}" ; shift 2 ;;
    --p-goal)        P_GOAL="${2:-}" ; shift 2 ;;
    --out)           OUT="${2:-}" ; shift 2 ;;
    --reuse-emitted) REUSE=1 ; shift ;;
    --dry-run)       DRYRUN=1 ; shift ;;
    -h|--help)       usage ; exit 0 ;;
    *) usage >&2 ; die "unknown argument \"$1\"" ;;
  esac
done

# --gpu-target is mandatory and is never inferred from what happens to be
# installed: it names the GPU half of the oracle pair, so a default would pick
# which model the session claims to test.
[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory (cuda|hip).  It names the \
GPU dialect AND half of the oracle pair, so there is no defaulting it."
case "$GPU_TARGET" in
  cuda|hip) ;;
  *) die "--gpu-target \"$GPU_TARGET\" is not a GPU dialect (accepted: cuda, hip)" ;;
esac
[ -n "$CORPUS" ] || die "--corpus is mandatory: the corpus carries the CPU column, \
which is the other half of the oracle pair"
[ -d "$CORPUS" ] || die "--corpus $CORPUS is not a directory"
CORPUS="$(cd "$CORPUS" && pwd)"
# The budgets are checked HERE and not by campaign.py's argparse: that runs after
# a whole corpus has been emitted and built, which on a real session is an hour.
echo "$BUDGET_RUNS" | grep -qE '^[1-9][0-9]*$' \
  || die "--budget-runs \"$BUDGET_RUNS\" is not a positive integer"
[ -z "$P_GOAL" ] || echo "$P_GOAL" | grep -qE '^0?\.[0-9]+([eE]-?[0-9]+)?$|^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$' \
  || die "--p-goal \"$P_GOAL\" is not a probability"

if [ "$GPU_TARGET" = cuda ]; then
  COMPILER="${NVCC:-nvcc}"  ; ARCH_VAR=CUDA_ARCH ; RENDER_EXT=cu  ; OTHER_EXT=hip
  ARCH_RE='^sm_[0-9]+[a-z]?$' ; ARCH_SHAPE='sm_XX'
  PROBE_DEFAULT="$HETL/spotcheck/probe.sh"
  ARCH_TOOLS='nvidia-smi --query-gpu=compute_cap, then nvptx-arch'
else
  COMPILER="${HIPCC:-hipcc}" ; ARCH_VAR=HIP_ARCH  ; RENDER_EXT=hip ; OTHER_EXT=cu
  ARCH_RE='^gfx[0-9a-f]+$'   ; ARCH_SHAPE='gfxXXX'
  PROBE_DEFAULT="$HETL/spotcheck/probe-hip.sh"
  ARCH_TOOLS='amdgpu-arch, then rocminfo'
fi
PROBE_SH="${HET_PROBE_SH:-$PROBE_DEFAULT}"

# =========================================================================
# STEP 1 -- PREFLIGHT.  Nothing is written and nothing is built until the box,
# the toolchain and the corpus agree with each other.
# =========================================================================

# The CPU lane of a corpus, read off a test the way litmus7 reads it: the first
# device tag of the program header that names a CPU ISA (HetArch.scan_cpu_isa,
# whose tag vocabulary this mirrors).  A test with no CPU column is refused here
# though the emitter would default it to AArch64 -- defaulting the host ISA of a
# device session is how a run gets built for the wrong machine.  The mirror is
# checked against the emitter's own answer after step 3.
corpus_cpu_isa() {              # <file.litmus> -> aarch64 | x86_64 | (empty)
  awk '
    /^[ \t]*P[0-9]+[ \t]*:/ && /\|/ {
      n = split($0, cells, "|")
      for (i = 1; i <= n; i++) {
        c = cells[i]; sub(/^[ \t]+/, "", c); sub(/[ \t;]+$/, "", c)
        p = index(c, ":"); if (p == 0) continue
        tag = tolower(substr(c, p + 1)); gsub(/[ \t]/, "", tag)
        if (tag == "cpu" || tag == "aarch64" || tag == "arm") { print "aarch64"; exit }
        if (tag == "x86_64" || tag == "x86-64" || tag == "amd64" || tag == "x64") \
          { print "x86_64"; exit }
      }
      exit
    }' "$1"
}

# THE PAIR TABLE IS litmus/hetOracle.ml AND THIS READS THAT FILE.  A second copy
# of the table here could drift from the one the emitter obeys, and the drift
# would show up as a campaign scheduled against another pair's classes.  What the
# emitter decided is checked against this in step 3, off the oracle stamp it
# writes into every render.
oracle_pair() {                 # <ISA key> <target> -> "POPULATED <oracle> <map>" | NO-ORACLE | ABSENT
  awk -v want="(\"$1\", \"$2\")," '
    function qval(s) {
      if (match(s, /= "[^"]*"/)) return substr(s, RSTART + 3, RLENGTH - 4)
      return ""
    }
    /^[ \t]*\("[A-Za-z0-9_]+", "[a-z]+"\),[ \t]*$/ {
      k = $0; gsub(/^[ \t]+|[ \t]+$/, "", k)
      inb = (k == want); if (inb) found = 1; next
    }
    inb {
      if ($0 ~ /Registered_none/)    state  = "NO-ORACLE"
      if ($0 ~ /Populated/)          state  = "POPULATED"
      if ($0 ~ /op_oracle_csv/)      oracle = qval($0)
      if ($0 ~ /op_control_map_csv/) map    = qval($0)
    }
    END {
      if (!found)               { print "ABSENT" ; exit }
      if (state == "NO-ORACLE") { print "NO-ORACLE" ; exit }
      if (state == "POPULATED" && oracle != "" && map != "") {
        print "POPULATED " oracle " " map ; exit
      }
      print "UNPARSED"
    }' "$REPO/litmus/hetOracle.ml"
}

[ -x "$LITMUS7" ] || die "litmus7 is not built at $LITMUS7 (run 'make all')"
shopt -s nullglob
CORPUS_TESTS=()
for f in "$CORPUS"/*.litmus; do CORPUS_TESTS+=("$(basename "$f" .litmus)"); done
shopt -u nullglob
[ "${#CORPUS_TESTS[@]}" -gt 0 ] || die "--corpus $CORPUS holds no .litmus test"

for tool in "$COMPILER" make gcc python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is not on PATH.  The $GPU_TARGET lane builds with $COMPILER and \
gcc through the emitted comp.sh, and the campaign runs each harness under timeout."
done

CPU_ISA="$(corpus_cpu_isa "$CORPUS/${CORPUS_TESTS[0]}.litmus")"
[ -n "$CPU_ISA" ] || die "no CPU column in $CORPUS/${CORPUS_TESTS[0]}.litmus -- the \
corpus CPU lane cannot be read, and it is half of the oracle pair"

# The pair, keyed as litmus/hetOracle.ml keys it (HetCpuFront's isa_name
# spelling).  Resolved BEFORE the host-ISA check because it is a property of the
# corpus and the flag alone: an unregistered pair is worth naming on any box,
# including the ones that could not have run it anyway.
case "$CPU_ISA" in
  aarch64) ISA_KEY=AArch64 ;;
  x86_64)  ISA_KEY=X86_64 ;;
  *) die "no oracle-table key for CPU ISA $CPU_ISA" ;;
esac
PAIR="($ISA_KEY, $GPU_TARGET)"
read -r PAIR_STATE PAIR_ORACLE PAIR_MAP <<<"$(oracle_pair "$ISA_KEY" "$GPU_TARGET")"
case "$PAIR_STATE" in
  POPULATED)
    [ -r "$CORPUS/$PAIR_MAP" ] || die "the pair $PAIR is populated and its control \
map is $PAIR_MAP, which is not readable beside the corpus ($CORPUS).  Emission reads \
it from there, so the session has no classes to schedule without it." ;;
  NO-ORACLE)
    PAIR_ORACLE="" ; PAIR_MAP="" ;;
  ABSENT)
    die "the pair $PAIR is not in litmus/hetOracle.ml, so emission refuses it and \
this session has nothing to run.  Register the pair there first." ;;
  *)
    die "litmus/hetOracle.ml did not yield a state for $PAIR (got \"$PAIR_STATE\") -- \
the table's shape changed and this wrapper reads it; fix the reader rather than \
hardcoding the pair here." ;;
esac

HOST_ISA="$(uname -m)"
[ "$CPU_ISA" = "$HOST_ISA" ] || die "this corpus carries a $CPU_ISA CPU column and \
uname -m is $HOST_ISA.  On a foreign host the CPU object is the portable shim, so \
the binary would test nothing (the emitted link targets refuse for the same reason)."

# =========================================================================
# ARCH RESOLUTION.  Never -arch=native: the value a session was built for has to
# be a recorded fact, so it is resolved here, printed, written down, and passed
# to every compiler invocation explicitly.
# =========================================================================
detect_archs() {                # -> one arch per line (unfiltered, unsorted)
  if [ "$GPU_TARGET" = cuda ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
        | tr -d ' \r' | awk 'NF { gsub(/\./, "") ; print "sm_" $0 }' || true
    fi
    if command -v nvptx-arch >/dev/null 2>&1; then
      nvptx-arch 2>/dev/null | tr -d ' \r' || true
    fi
  else
    if command -v amdgpu-arch >/dev/null 2>&1; then
      amdgpu-arch 2>/dev/null | tr -d ' \r' || true
    fi
    if command -v rocminfo >/dev/null 2>&1; then
      rocminfo 2>/dev/null | sed -n 's/.*Name: *\(gfx[0-9a-f]*\).*/\1/p' || true
    fi
  fi
}

if [ "$ARCH" = auto ]; then
  mapfile -t FOUND < <(detect_archs | grep -E "$ARCH_RE" | sort -u || true)
  if [ "${#FOUND[@]}" -eq 0 ]; then
    die "--arch auto found no $GPU_TARGET device on this box (detection is \
$ARCH_TOOLS, and neither named one).  A session cannot be built for a device that \
is not there; pass --arch $ARCH_SHAPE to build for a machine other than this one."
  elif [ "${#FOUND[@]}" -gt 1 ]; then
    die "--arch auto is AMBIGUOUS: this box shows ${#FOUND[@]} distinct \
architectures (${FOUND[*]}).  One binary is built per harness, so name the device \
under test with --arch $ARCH_SHAPE."
  fi
  ARCH="${FOUND[0]}" ; ARCH_SOURCE="auto (probed on this box)"
else
  [ "$ARCH" != native ] || die "--arch native is not accepted: the arch a session \
was built for must be a recorded value, and 'native' records nothing"
  echo "$ARCH" | grep -qE "$ARCH_RE" \
    || die "--arch \"$ARCH\" is not a $GPU_TARGET architecture (want $ARCH_SHAPE)"
  ARCH_SOURCE="explicit (--arch)"
fi

# =========================================================================
# THE PLAN.  Printed on every run, and it is the whole of a --dry-run.
# =========================================================================
STAMP="$(date +%Y%m%d-%H%M%S)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )"
[ -n "$OUT" ] || OUT="$HETL/run-out/hetlitmus-run-$STAMP"
if [ "$PAIR_STATE" = POPULATED ]; then
  MODE="oracle"
  MODE_LONG="oracle ($PAIR_ORACLE; classes from $PAIR_MAP)"
else
  MODE="characterization"
  MODE_LONG="characterization (the pair carries no oracle: nothing here adjudicates)"
fi
RUNONE="$HETL/spotcheck/run-one.sh"
RUNNER="timeout $HET_RUN_TIMEOUT sh $RUNONE {dir} {test}"

echo "=========================================================================="
echo "HetLitmus device session"
echo "  host          $(uname -srm)   $( (hostname 2>/dev/null || echo '?') )"
echo "  corpus        $CORPUS   (${#CORPUS_TESTS[@]} test(s), $CPU_ISA CPU lane)"
echo "  gpu-target    $GPU_TARGET   (compiler $COMPILER)"
echo "  pair          $PAIR  ->  $MODE_LONG"
echo "  arch          $ARCH   [$ARCH_SOURCE]   passed to the build as $ARCH_VAR"
echo "  budget        --budget-runs $BUDGET_RUNS   --p-goal ${P_GOAL:-<unset: bound rows run to budget>}"
echo "  results       $OUT"
echo "  probe         $PROBE_SH"
echo "  runner        $RUNNER"
echo "=========================================================================="
echo "  step 1  preflight   DONE: toolchain, corpus, host ISA, pair"
echo "  step 2  probe       $PROBE_SH -> $OUT/probe.txt"
if [ "$REUSE" -eq 1 ]; then
  echo "  step 3  emit        SKIPPED (--reuse-emitted); $OUT/emit is verified instead"
else
  echo "  step 3  emit        litmus7 -gpu-target $GPU_TARGET over ${#CORPUS_TESTS[@]} test(s) -> $OUT/emit"
fi
echo "  step 4  compile     comp.sh $GPU_TARGET + make $GPU_TARGET-bin, $ARCH_VAR=$ARCH"
echo "  step 5  smoke rungs NOT IN THIS CHAIN (spotcheck/ladder.sh is driven separately)"
if [ "$MODE" = oracle ]; then
  echo "  step 6  campaign    campaign.py --control-map $CORPUS/$PAIR_MAP"
else
  echo "  step 6  campaign    campaign.py --characterization ($PAIR has no oracle)"
fi
echo "  step 7  collect     probe, build logs, harness transcripts, campaign state, summary -> $OUT"
if [ "$DRYRUN" -eq 1 ]; then
  echo
  echo "hetlitmus-run: --dry-run -- nothing was emitted, built, run or written."
  exit 0
fi

mkdir -p "$OUT" "$OUT/build"
OUT="$(cd "$OUT" && pwd)"
EMIT="$OUT/emit"
{
  echo "session_date=$(date -Is 2>/dev/null || date)"
  echo "session_host=$( (hostname 2>/dev/null || echo unknown) )"
  echo "host_uname=$(uname -srm)"
  echo "host_isa=$HOST_ISA"
  echo "corpus=$CORPUS"
  echo "corpus_cpu_isa=$CPU_ISA"
  echo "corpus_tests=${#CORPUS_TESTS[@]}"
  echo "gpu_target=$GPU_TARGET"
  echo "pair=$PAIR"
  echo "pair_state=$PAIR_STATE"
  echo "oracle_csv=${PAIR_ORACLE:-NONE}"
  echo "control_map=${PAIR_MAP:-NONE}"
  echo "mode=$MODE"
  echo "arch=$ARCH"
  echo "arch_var=$ARCH_VAR"
  echo "arch_source=$ARCH_SOURCE"
  echo "compiler=$COMPILER"
  echo "budget_runs=$BUDGET_RUNS"
  echo "p_goal=${P_GOAL:-UNSET}"
  echo "run_timeout_s=$HET_RUN_TIMEOUT"
  echo "runner=$RUNNER"
  echo "probe_cmd=$PROBE_SH"
  echo "reuse_emitted=$REUSE"
  echo "het_alloc=${HET_ALLOC:-<unset: the harness resolves it>}"
  echo "litmus7=$LITMUS7"
  echo "git_rev=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo nogit)"
  echo "git_dirty=$( [ -z "$(cd "$REPO" && git status --porcelain -- litmus hetlitmus 2>/dev/null)" ] && echo no || echo YES )"
  # LOUD WHEN A SEAM IS IN USE: a stub probe or a stand-in litmus7 makes this
  # results dir a machinery artefact and not a reading of the machine.
  if [ -n "${HET_PROBE_SH:-}" ]; then echo "seam_probe=STUB($HET_PROBE_SH)"; fi
  if [ -n "${HET_LITMUS7:-}" ]; then echo "seam_litmus7=STUB($HET_LITMUS7)"; fi
  if [ "$COMPILER" != nvcc ] && [ "$COMPILER" != hipcc ]; then
    echo "seam_compiler=OVERRIDDEN($COMPILER)"
  fi
} > "$OUT/run-record.txt"

# =========================================================================
# STEP 2 -- PROBE.  What this machine offers, recorded before anything is
# built for it.
# =========================================================================
echo
echo "== step 2/7: probe =="
probe_rc=0
RESULTS="$OUT" sh "$PROBE_SH" > "$OUT/probe.log" 2>&1 || probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "hetlitmus-run: the probe exited $probe_rc; its log:" >&2
  tail -20 "$OUT/probe.log" >&2
  die "the probe did not complete.  It is what records the machine this session \
measures, so a session without it produces numbers nobody can attribute."
fi
head -20 "$OUT/probe.log" | sed 's/^/    /'

# =========================================================================
# STEP 3 -- EMIT.  One test at a time and each one checked, because litmus7's
# batch driver reports a refusal on the discarded stream and still exits 0
# (verify/emit-all.sh carries that measurement).
# =========================================================================
echo
echo "== step 3/7: emit =="
TESTLOG="$(mktemp)"
trap 'rm -f "$TESTLOG"' EXIT
emit_one() {                    # <test> -- emits into $EMIT, fails closed
  local t="$1" st=0
  ( cd "$CORPUS" && "$LITMUS7" -gpu-target "$GPU_TARGET" -set-libdir "$LIBDIR" \
      -o "$EMIT" "$t.litmus" ) > "$TESTLOG" 2>&1 || st=$?
  { echo "### $t (exit $st)" ; cat "$TESTLOG" ; } >> "$OUT/emit.log"
  if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$TESTLOG"; then
    echo "hetlitmus-run: litmus7 -gpu-target $GPU_TARGET failed on $t (exit $st):" >&2
    cat "$TESTLOG" >&2
    die "emission failed on $t"
  fi
}
# The oracle stamp every render carries names the pair's oracle, or discloses that
# the pair has none.  It is the EMITTER's answer to the question the pair table
# was read for above, so the two are compared here: a disagreement means the
# wrapper and litmus7 resolved different pairs, and the campaign would be
# scheduled against classes the harnesses do not carry.
check_stamp() {                 # <test>
  local t="$1" f="$EMIT/$t/$t.$RENDER_EXT" want
  [ -s "$f" ] || die "no .$RENDER_EXT render for $t under $EMIT"
  [ -s "$EMIT/$t/${t}_cpu.c" ] || die "no CPU thread emitted for $t under $EMIT"
  [ ! -e "$EMIT/$t/$t.$OTHER_EXT" ] \
    || die "$t carries a .$OTHER_EXT render too -- -gpu-target is not filtering"
  if [ "$PAIR_STATE" = POPULATED ]; then
    want="\"$PAIR_ORACLE:"
  else
    want="\"(NO-ORACLE: $PAIR is registered without one"
  fi
  grep -qF "_rec.oracle_source = $want" "$f" || {
    echo "hetlitmus-run: $t stamps" >&2
    grep -F '_rec.oracle_source' "$f" >&2 || echo "  (no oracle_source at all)" >&2
    die "the emitted stamp of $t disagrees with the pair this wrapper resolved \
($PAIR, $PAIR_STATE) -- one of the two read litmus/hetOracle.ml wrongly"
  }
}
if [ "$REUSE" -eq 1 ]; then
  [ -d "$EMIT" ] || die "--reuse-emitted, but there is no $EMIT to reuse (point \
--out at the results dir of the run that emitted it)"
  for t in "${CORPUS_TESTS[@]}"; do check_stamp "$t"; done
  echo "    reused ${#CORPUS_TESTS[@]} harness dir(s) in $EMIT, each carrying the \
$GPU_TARGET render and this pair's stamp"
else
  mkdir -p "$EMIT"
  : > "$OUT/emit.log"
  for t in "${CORPUS_TESTS[@]}"; do emit_one "$t" ; check_stamp "$t" ; done
  echo "    emitted ${#CORPUS_TESTS[@]} harness dir(s) into $EMIT"
fi
# The mirror check: the emitted build files carry the EMITTER's reading of the
# CPU lane, and the host-ISA refusal above rests on this wrapper's.
EMITTED_ISA="$(sed -n 's/^HET_HOST_ISA *?*= *//p' "$EMIT/${CORPUS_TESTS[0]}/Makefile" | head -1)"
[ "$EMITTED_ISA" = "$CPU_ISA" ] || die "the emitted harness carries CPU ISA \
'$EMITTED_ISA' but this wrapper read '$CPU_ISA' off the corpus -- the host-ISA \
check was made against the wrong lane"

# =========================================================================
# STEP 4 -- COMPILE.  Objects then binary, with the resolved arch passed
# explicitly.  Every failure goes in the table; one failure stops the session.
# =========================================================================
echo
echo "== step 4/7: compile ($ARCH_VAR=$ARCH) =="
FAILTAB="$OUT/build-failures.txt"
: > "$FAILTAB"
nfail=0
for t in "${CORPUS_TESTS[@]}"; do
  rc=0
  ( cd "$EMIT/$t" && export "$ARCH_VAR=$ARCH" \
      && sh comp.sh "$GPU_TARGET" && make "$GPU_TARGET-bin" ) \
    > "$OUT/build/$t.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -x "$EMIT/$t/$t" ]; then
    printf '%-40s rc=%-4s %s\n' "$t" "$rc" \
      "$(grep -m1 -iE 'error|refuses' "$OUT/build/$t.log" | cut -c1-100)" >> "$FAILTAB"
    nfail=$((nfail + 1))
  fi
done
if [ "$nfail" -ne 0 ]; then
  echo "hetlitmus-run: $nfail of ${#CORPUS_TESTS[@]} harness(es) did not build:" >&2
  cat "$FAILTAB" >&2
  echo "  per-test logs are in $OUT/build/" >&2
  die "$nfail harness(es) failed to build; the table is $FAILTAB"
fi
echo "    built ${#CORPUS_TESTS[@]} harness binaries (the failure table $FAILTAB is empty)"

# =========================================================================
# STEP 6 -- CAMPAIGN.  Step 5, a smoke ladder between build and campaign, is not
# part of this chain (see the header).
# =========================================================================
echo
echo "== step 6/7: campaign ($MODE) =="
# campaign.py parses the HetStats line and keeps none of it; run-one.sh copies
# each transcript here so the session keeps the lines its rows were scored from.
export HET_RUN_LOG_DIR="$OUT/hetstats"
TESTS_CSV="$(IFS=, ; echo "${CORPUS_TESTS[*]}")"
CAMPAIGN_ARGS=(--corpus "$EMIT" --runner "$RUNNER" --tests "$TESTS_CSV"
               --budget-runs "$BUDGET_RUNS" --state "$OUT/campaign-state.csv")
if [ -n "$P_GOAL" ]; then CAMPAIGN_ARGS+=(--p-goal "$P_GOAL"); fi
# The mode is READ OFF THE EMISSION, never guessed: a pair with no oracle stamps
# every render as such (checked above), and characterizing is the only thing its
# harnesses can do.  The alternative -- a control map whose cells are blank --
# would put a class in the campaign that nobody derived.
if [ "$MODE" = oracle ]; then
  CAMPAIGN_ARGS+=(--control-map "$CORPUS/$PAIR_MAP")
else
  CAMPAIGN_ARGS+=(--characterization)
fi
camp_rc=0
python3 "$HETL/campaign.py" "${CAMPAIGN_ARGS[@]}" > "$OUT/campaign.log" 2>&1 || camp_rc=$?
tail -40 "$OUT/campaign.log" | sed 's/^/    /'

# =========================================================================
# STEP 7 -- COLLECT.  One screen, and the results dir holds the rest.
# =========================================================================
count_stop() {                  # <STOP> -> rows of the campaign state carrying it
  if [ ! -r "$OUT/campaign-state.csv" ]; then echo 0 ; return ; fi
  awk -F, -v s="$1" 'NR > 1 && $3 == s' "$OUT/campaign-state.csv" | wc -l
}
SUMMARY="$OUT/summary.txt"
{
  echo "=========================================================================="
  echo "HetLitmus session summary"
  echo "  results     $OUT"
  echo "  host        $(uname -srm)   $( (hostname 2>/dev/null || echo '?') )"
  echo "  pair        $PAIR"
  echo "  mode        $MODE_LONG"
  echo "  arch        $ARCH   [$ARCH_SOURCE]"
  echo "  corpus      $CORPUS   (${#CORPUS_TESTS[@]} test(s), $CPU_ISA CPU lane)"
  echo "  probe       $OUT/probe.txt   ($(grep -m1 '^probe_status=' "$OUT/probe.txt" 2>/dev/null | sed 's/^probe_status=//'))"
  echo "  build       ${#CORPUS_TESTS[@]} built, $nfail failed   (logs in $OUT/build/)"
  echo "  campaign    exit $camp_rc   (log $OUT/campaign.log, state $OUT/campaign-state.csv)"
  echo "  transcripts $OUT/hetstats/   ($(find "$OUT/hetstats" -name '*.log' 2>/dev/null | wc -l) harness log(s))"
  for s in OBSERVED CONFIRMED BOUND-MET BUDGET ERROR; do
    n="$(count_stop "$s")"
    if [ "$n" -gt 0 ]; then printf '              %-10s %d row(s)\n' "$s" "$n" ; fi
  done
  if [ "$MODE" = characterization ]; then
    echo "  reading     CHARACTERIZATION: $PAIR carries no compound-model prediction,"
    echo "              so no row here agrees or disagrees with one.  These rows say"
    echo "              what the machine does, and nothing about the model."
  fi
  case "$camp_rc" in
    0) echo "  verdict     session complete" ;;
    1) echo "  verdict     *** the campaign reported an errored row or a corroborated"
       echo "              sighting -- read $OUT/campaign.log before anything is claimed ***" ;;
    *) echo "  verdict     *** the campaign refused (exit $camp_rc): see $OUT/campaign.log ***" ;;
  esac
  echo "=========================================================================="
} > "$SUMMARY"
echo
cat "$SUMMARY"
exit "$camp_rc"
