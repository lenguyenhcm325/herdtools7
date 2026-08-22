#!/usr/bin/env bash
# =========================================================================
# HetLitmus device session: ONE entry point, one chain, on a real machine.
# preflight -> probe -> emit -> compile -> campaign -> collect.  Every step
# fails CLOSED with a named reason, and every value the session turned on --
# the resolved device arch, the (CPU ISA x GPU dialect) pair -- is written into
# the results dir as a fact, because a run whose arch or target was decided
# invisibly cannot be read afterwards.
#
# Composition only: probe-cuda.sh / probe-hip.sh probe, litmus7 emits, the
# emitted comp.sh + Makefile build, campaign.py schedules, run-one.sh invokes.
# What is new here is the ORDER, the refusals and the record.
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
  --budget-runs N            max runs per row (default 100)
  --out DIR                  results dir (default hetlitmus/run-out/<stamp>)
  --reuse-emitted            reuse <out>/emit instead of emitting again
  --resume                   continue the campaign state already in <out>
  --dry-run                  print the plan and do nothing else
EOF
}

# The session status, written into the results dir and kept true at every exit:
# RUNNING while the chain is in flight, COMPLETE at step 7, REFUSED@step<N> when a
# step fails closed, ABORTED@step<N> if the shell died some other way.  Without it
# a refused session and a finished one leave results dirs that read alike.
STEP=1 ; RECORD="" ; SUMMARY=""
mark_status() {                 # <status>
  [ -n "$RECORD" ] && [ -f "$RECORD" ] || return 0
  sed "s/^session_status=.*/session_status=$1/" "$RECORD" > "$RECORD.tmp" \
    && mv -f "$RECORD.tmp" "$RECORD"
}
finish() {                      # the EXIT trap, armed once the record exists
  [ -z "${TESTLOG:-}" ] || rm -f "$TESTLOG"
  if [ -n "$RECORD" ] && [ -f "$RECORD" ] \
     && grep -q '^session_status=RUNNING$' "$RECORD"; then
    mark_status "ABORTED@step$STEP"
  fi
}

die() {
  mark_status "REFUSED@step$STEP"
  echo "hetlitmus-run: REFUSING -- $*" >&2
  exit 2
}

# A valued flag given no value would `shift 2' off the end of the argument list,
# which under set -e exits 1 -- the code that means the campaign errored a row --
# with nothing printed at all.
need_val() {                    # <flag> <remaining argc>
  [ "$2" -ge 2 ] || { usage >&2 ; die "$1 needs a value"; }
}

GPU_TARGET="" ; CORPUS="" ; ARCH="auto" ; BUDGET_RUNS=100
OUT="" ; REUSE=0 ; DRYRUN=0 ; RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu-target)    need_val "$1" $# ; GPU_TARGET="$2" ; shift 2 ;;
    --corpus)        need_val "$1" $# ; CORPUS="$2" ; shift 2 ;;
    --arch)          need_val "$1" $# ; ARCH="$2" ; shift 2 ;;
    --budget-runs)   need_val "$1" $# ; BUDGET_RUNS="$2" ; shift 2 ;;
    --out)           need_val "$1" $# ; OUT="$2" ; shift 2 ;;
    --reuse-emitted) REUSE=1 ; shift ;;
    --resume)        RESUME=1 ; shift ;;
    --dry-run)       DRYRUN=1 ; shift ;;
    -h|--help)       usage ; exit 0 ;;
    *) usage >&2 ; die "unknown argument \"$1\"" ;;
  esac
done

# --gpu-target is mandatory and is never inferred from what happens to be
# installed: it names the GPU half of the pair, so a default would pick which
# pair the renders are built for.
[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory (cuda|hip).  It names the \
GPU dialect AND half of the (CPU ISA x GPU dialect) pair, so there is no defaulting it."
case "$GPU_TARGET" in
  cuda|hip) ;;
  *) die "--gpu-target \"$GPU_TARGET\" is not a GPU dialect (accepted: cuda, hip)" ;;
esac
[ -n "$CORPUS" ] || die "--corpus is mandatory: the corpus carries the CPU column, \
which is the other half of the pair"
[ -d "$CORPUS" ] || die "--corpus $CORPUS is not a directory"
CORPUS="$(cd "$CORPUS" && pwd)"
# The budget is checked HERE and not by campaign.py's argparse: that runs after a
# whole corpus has been emitted and built, which on a real session is an hour.
echo "$BUDGET_RUNS" | grep -qE '^[1-9][0-9]*$' \
  || die "--budget-runs \"$BUDGET_RUNS\" is not a positive integer"

if [ "$GPU_TARGET" = cuda ]; then
  COMPILER="${NVCC:-nvcc}"  ; ARCH_VAR=CUDA_ARCH ; RENDER_EXT=cu  ; OTHER_EXT=hip
  ARCH_RE='^sm_[0-9]+[a-z]?$' ; ARCH_SHAPE='sm_XX'
  PROBE_DEFAULT="$HETL/spotcheck/probe-cuda.sh"
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

# The CPU lane of a corpus, read off EVERY test the way litmus7 reads it: the
# first device tag of the program header that names a CPU ISA (HetArch.scan_cpu_isa,
# whose tag vocabulary this mirrors).  A test with no CPU column is refused here
# though the emitter would default it to AArch64 -- defaulting the host ISA of a
# device session is how a run gets built for the wrong pair.  Sampling one test
# would let a mixed-ISA corpus pass this step and die at emission instead.  The
# mirror is checked against the emitter's answer after step 3.
corpus_cpu_lanes() {            # <file.litmus>... -> "<file> aarch64|x86_64|NONE"
  awk '
    function flush() { if (cur != "") print cur, (isa == "" ? "NONE" : isa) }
    FNR == 1 { flush(); cur = FILENAME; isa = ""; seen = 0 }
    seen { next }
    /^[ \t]*P[0-9]+[ \t]*:/ && /\|/ {
      seen = 1
      n = split($0, cells, "|")
      for (i = 1; i <= n; i++) {
        c = cells[i]; sub(/^[ \t]+/, "", c); sub(/[ \t;]+$/, "", c)
        p = index(c, ":"); if (p == 0) continue
        tag = tolower(substr(c, p + 1)); gsub(/[ \t]/, "", tag)
        if (tag == "cpu" || tag == "aarch64" || tag == "arm") { isa = "aarch64"; break }
        if (tag == "x86_64" || tag == "x86-64" || tag == "amd64" || tag == "x64") \
          { isa = "x86_64"; break }
      }
    }
    END { flush() }' "$@"
}

[ -x "$LITMUS7" ] || die "litmus7 is not built at $LITMUS7 (run 'make all')"
shopt -s nullglob
CORPUS_TESTS=() ; CORPUS_PATHS=()
for f in "$CORPUS"/*.litmus; do
  CORPUS_TESTS+=("$(basename "$f" .litmus)") ; CORPUS_PATHS+=("$f")
done
shopt -u nullglob
[ "${#CORPUS_TESTS[@]}" -gt 0 ] || die "--corpus $CORPUS holds no .litmus test"

for tool in "$COMPILER" make gcc python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is not on PATH.  The $GPU_TARGET lane builds with $COMPILER and \
gcc through the emitted comp.sh, and the campaign runs each harness under timeout."
done

CPU_ISA="" ; CPU_ISA_FILE=""
while read -r lane_file lane_isa; do
  [ "$lane_isa" != NONE ] || die "no CPU column in $lane_file -- the corpus CPU \
lane cannot be read, and it is half of the pair"
  if [ -z "$CPU_ISA" ]; then
    CPU_ISA="$lane_isa" ; CPU_ISA_FILE="$lane_file"
  elif [ "$lane_isa" != "$CPU_ISA" ]; then
    die "this corpus mixes CPU lanes: $lane_file is $lane_isa and $CPU_ISA_FILE is \
$CPU_ISA.  One session builds one pair, so a corpus with two CPU halves names no \
pair at all; split it and run one session per lane."
  fi
done < <(corpus_cpu_lanes "${CORPUS_PATHS[@]}")

# The pair, spelled exactly as the emitter stamps it into HET_PAIR_NAME
# (HetCpuFront's isa_name spelling); check_stamp below compares the two.
# Resolved BEFORE the host-ISA check because it is a property of the corpus and
# the flag alone.
case "$CPU_ISA" in
  aarch64) ISA_KEY=AArch64 ;;
  x86_64)  ISA_KEY=X86_64 ;;
  *) die "no pair key for CPU ISA $CPU_ISA" ;;
esac
PAIR="($ISA_KEY, $GPU_TARGET)"

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
RUNONE="$HETL/spotcheck/run-one.sh"
RUNNER="timeout $HET_RUN_TIMEOUT sh $RUNONE {dir} {test}"

# What a second session into this dir would inherit: campaign.py resumes every
# terminal row it finds in --state rather than re-running it, so without an
# explicit --resume a repeat session invokes no harness at all and still reports a
# complete one.  The short list is the subset that would also silently swallow a
# raised --budget-runs: rows stopped BY budget, which a resume can only leave at
# the budget they were measured with.  Column 2 is the stop, column 4 the runs.
STATE="$OUT/campaign-state.csv"
RESUMABLE=0 ; RESUMABLE_SHORT=""
if [ -r "$STATE" ]; then
  RESUMABLE="$(awk -F, 'NR > 1 && ($2 == "CORROBORATED" ||
      $2 == "UNCONFIRMED-SIGHTING" || $2 == "BUDGET" ||
      $2 == "ERROR")' "$STATE" | wc -l)"
  RESUMABLE_SHORT="$(awk -F, -v b="$BUDGET_RUNS" \
    'NR > 1 && $2 == "BUDGET" && $4 + 0 < b + 0 \
     { printf "%s(%s runs) ", $1, $4 }' "$STATE")"
fi

echo "=========================================================================="
echo "HetLitmus device session"
echo "  host          $(uname -srm)   $( (hostname 2>/dev/null || echo '?') )"
echo "  corpus        $CORPUS   (${#CORPUS_TESTS[@]} test(s), $CPU_ISA CPU lane)"
echo "  gpu-target    $GPU_TARGET   (compiler $COMPILER)"
echo "  pair          $PAIR"
echo "  arch          $ARCH   [$ARCH_SOURCE]   passed to the build as $ARCH_VAR"
echo "  budget        --budget-runs $BUDGET_RUNS   (every row runs to it or to a stop)"
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
echo "  step 6  campaign    campaign.py (characterization: one stop rule per row)"
echo "  step 7  collect     probe, build logs, harness transcripts, campaign state, summary -> $OUT"
if [ "$RESUMABLE" -gt 0 ]; then
  echo "  resume      $RESUMABLE terminal row(s) already in $STATE"
fi
if [ "$RESUMABLE" -gt 0 ] && [ "$RESUME" -eq 0 ]; then
  die "$STATE already carries $RESUMABLE terminal row(s), and campaign.py resumes \
each of them instead of re-running it: this session would invoke no harness and \
still report a complete one.  Pass --resume to continue that campaign (the inherited \
rows are then disclosed as not measured here), or move $STATE aside to measure \
again into this dir."
fi
if [ "$RESUME" -eq 1 ] && [ -n "$RESUMABLE_SHORT" ]; then
  die "--resume, but --budget-runs $BUDGET_RUNS is above what these row(s) spent, \
and a resumed row is never re-run: $RESUMABLE_SHORT.  Each stopped at the budget it \
was given, so inheriting them under this one would credit the session with runs \
nobody spent; re-run at their budget, or move $STATE aside."
fi
if [ "$DRYRUN" -eq 1 ]; then
  echo
  echo "hetlitmus-run: --dry-run -- nothing was emitted, built, run or written."
  exit 0
fi

mkdir -p "$OUT" "$OUT/build"
OUT="$(cd "$OUT" && pwd)"
EMIT="$OUT/emit" ; STATE="$OUT/campaign-state.csv"
RECORD="$OUT/run-record.txt" ; SUMMARY="$OUT/summary.txt"
# A summary from an earlier session into this dir would otherwise sit beside this
# session's record and describe a different run.
[ ! -e "$SUMMARY" ] || mv -f "$SUMMARY" "$OUT/summary-superseded-$STAMP.txt"
{
  echo "session_status=RUNNING"
  echo "session_date=$(date -Is 2>/dev/null || date)"
  echo "session_host=$( (hostname 2>/dev/null || echo unknown) )"
  echo "host_uname=$(uname -srm)"
  echo "host_isa=$HOST_ISA"
  echo "corpus=$CORPUS"
  echo "corpus_cpu_isa=$CPU_ISA"
  echo "corpus_tests=${#CORPUS_TESTS[@]}"
  echo "gpu_target=$GPU_TARGET"
  echo "pair=$PAIR"
  echo "arch=$ARCH"
  echo "arch_var=$ARCH_VAR"
  echo "arch_source=$ARCH_SOURCE"
  echo "compiler=$COMPILER"
  echo "budget_runs=$BUDGET_RUNS"
  echo "run_timeout_s=$HET_RUN_TIMEOUT"
  echo "runner=$RUNNER"
  echo "probe_cmd=$PROBE_SH"
  echo "reuse_emitted=$REUSE"
  echo "resume=$RESUME"
  echo "resumed_rows=$RESUMABLE"
  if [ "$RESUME" -eq 1 ] && [ "$RESUMABLE" -gt 0 ]; then
    echo "resumed_note=resumed $RESUMABLE row(s) (not measured in this session)"
  fi
  echo "het_alloc=${HET_ALLOC:-<unset: the harness resolves it>}"
  echo "litmus7=$LITMUS7"
  echo "git_rev=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo nogit)"
  echo "git_dirty=$( [ -z "$(cd "$REPO" && git status --porcelain -- litmus hetlitmus 2>/dev/null)" ] && echo no || echo YES )"
  # Loud when a seam is in use: a stub probe or a stand-in litmus7 makes this
  # results dir a machinery artefact and not a reading of the machine.
  if [ -n "${HET_PROBE_SH:-}" ]; then echo "seam_probe=STUB($HET_PROBE_SH)"; fi
  if [ -n "${HET_LITMUS7:-}" ]; then echo "seam_litmus7=STUB($HET_LITMUS7)"; fi
  if [ "$COMPILER" != nvcc ] && [ "$COMPILER" != hipcc ]; then
    echo "seam_compiler=OVERRIDDEN($COMPILER)"
  fi
} > "$RECORD"
trap finish EXIT

# =========================================================================
# STEP 2 -- PROBE.  What this machine offers, recorded before anything is
# built for it.
# =========================================================================
echo
echo "== step 2/7: probe =="
STEP=2
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
STEP=3
TESTLOG="$(mktemp)"
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
# HET_PAIR_NAME is the EMITTER's spelling of the pair resolved above, so the two
# are compared here: a disagreement means the wrapper and litmus7 read different
# pairs off the same corpus, and the campaign would run harnesses built for the
# other one.
check_stamp() {                 # <test>
  local t="$1" f="$EMIT/$t/$t.$RENDER_EXT"
  [ -s "$f" ] || die "no .$RENDER_EXT render for $t under $EMIT"
  [ -s "$EMIT/$t/${t}_cpu.c" ] || die "no CPU thread emitted for $t under $EMIT"
  [ ! -e "$EMIT/$t/$t.$OTHER_EXT" ] \
    || die "$t carries a .$OTHER_EXT render too -- -gpu-target is not filtering"
  grep -qF "#define HET_PAIR_NAME \"$PAIR\"" "$f" || {
    echo "hetlitmus-run: $t stamps" >&2
    grep -F '#define HET_PAIR_NAME' "$f" >&2 || echo "  (no HET_PAIR_NAME at all)" >&2
    die "the emitted pair name of $t disagrees with the pair this wrapper resolved \
($PAIR) -- one of the two read the corpus CPU lane wrongly"
  }
}
if [ "$REUSE" -eq 1 ]; then
  [ -d "$EMIT" ] || die "--reuse-emitted, but there is no $EMIT to reuse (point \
--out at the results dir of the run that emitted it)"
  for t in "${CORPUS_TESTS[@]}"; do check_stamp "$t"; done
  echo "    reused ${#CORPUS_TESTS[@]} harness dir(s) in $EMIT, each carrying the \
$GPU_TARGET render and this pair's name"
else
  mkdir -p "$EMIT"
  : > "$OUT/emit.log"
  for t in "${CORPUS_TESTS[@]}"; do emit_one "$t" ; check_stamp "$t" ; done
  echo "    emitted ${#CORPUS_TESTS[@]} harness dir(s) into $EMIT"
fi
# The mirror check: the emitted build files carry the EMITTER's reading of the
# CPU lane, and the host-ISA refusal above rests on this wrapper's.  Every test,
# for the reason the preflight reads every test.
for t in "${CORPUS_TESTS[@]}"; do
  EMITTED_ISA="$(sed -n 's/^HET_HOST_ISA *?*= *//p' "$EMIT/$t/Makefile" | head -1)"
  [ "$EMITTED_ISA" = "$CPU_ISA" ] || die "the emitted harness of $t carries CPU ISA \
'$EMITTED_ISA' but this wrapper read '$CPU_ISA' off the corpus -- the host-ISA \
check was made against the wrong lane"
done

# =========================================================================
# STEP 4 -- COMPILE.  Objects then binary, with the resolved arch passed
# explicitly.  Every failure goes in the table; one failure stops the session.
# =========================================================================
echo
echo "== step 4/7: compile ($ARCH_VAR=$ARCH) =="
STEP=4
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
echo "== step 6/7: campaign (characterization) =="
STEP=6
# campaign.py parses the HetStats line and keeps none of it; run-one.sh copies
# each transcript here so the session keeps the lines its rows were scored from.
export HET_RUN_LOG_DIR="$OUT/hetstats"
TESTS_CSV="$(IFS=, ; echo "${CORPUS_TESTS[*]}")"
CAMPAIGN_ARGS=(--corpus "$EMIT" --runner "$RUNNER" --tests "$TESTS_CSV"
               --budget-runs "$BUDGET_RUNS" --state "$STATE")
camp_rc=0
python3 "$HETL/campaign.py" "${CAMPAIGN_ARGS[@]}" > "$OUT/campaign.log" 2>&1 || camp_rc=$?
tail -40 "$OUT/campaign.log" | sed 's/^/    /'

# =========================================================================
# STEP 7 -- COLLECT.  One screen, and the results dir holds the rest.
# =========================================================================
STEP=7
count_stop() {                  # <STOP> -> rows of the campaign state carrying it
  if [ ! -r "$STATE" ]; then echo 0 ; return ; fi
  awk -F, -v s="$1" 'NR > 1 && $2 == s' "$STATE" | wc -l
}
{
  echo "=========================================================================="
  echo "HetLitmus session summary"
  echo "  results     $OUT"
  echo "  host        $(uname -srm)   $( (hostname 2>/dev/null || echo '?') )"
  echo "  pair        $PAIR"
  echo "  arch        $ARCH   [$ARCH_SOURCE]"
  echo "  corpus      $CORPUS   (${#CORPUS_TESTS[@]} test(s), $CPU_ISA CPU lane)"
  echo "  probe       $OUT/probe.txt   ($(grep -m1 '^probe_status=' "$OUT/probe.txt" 2>/dev/null | sed 's/^probe_status=//'))"
  echo "  build       ${#CORPUS_TESTS[@]} built, $nfail failed   (logs in $OUT/build/)"
  echo "  campaign    exit $camp_rc   (log $OUT/campaign.log, state $STATE)"
  if [ "$RESUME" -eq 1 ] && [ "$RESUMABLE" -gt 0 ]; then
    echo "  resumed     $RESUMABLE row(s) (not measured in this session)"
  fi
  echo "  transcripts $OUT/hetstats/   ($(find "$OUT/hetstats" -name '*.log' 2>/dev/null | wc -l) harness log(s))"
  for s in CORROBORATED UNCONFIRMED-SIGHTING BUDGET ERROR; do
    n="$(count_stop "$s")"
    if [ "$n" -gt 0 ]; then printf '              %-21s %d row(s)\n' "$s" "$n" ; fi
  done
  echo "  reading     CHARACTERIZATION: no harness here carries a prediction, so no"
  echo "              row agrees or disagrees with one.  These rows say what the"
  echo "              machine does, and nothing about any model."
  case "$camp_rc" in
    0) echo "  verdict     session complete" ;;
    1) echo "  verdict     *** the campaign reported an errored row or a lone sighting"
       echo "              the confirmation window closed on -- read $OUT/campaign.log"
       echo "              before anything is claimed ***" ;;
    *) echo "  verdict     *** the campaign refused (exit $camp_rc): see $OUT/campaign.log ***" ;;
  esac
  echo "=========================================================================="
} > "$SUMMARY"
mark_status COMPLETE
echo
cat "$SUMMARY"
exit "$camp_rc"
