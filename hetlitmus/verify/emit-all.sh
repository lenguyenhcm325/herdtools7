#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus over every REGISTERED
# (CPU ISA x GPU dialect) pair into OUTDIR -- 411 het harness dirs per het lane
# and 137 gpu-only kernels per gpu-only lane.
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
# THE LANES ARE PAIRS, not vendors.  A compound harness is a CPU ISA and a GPU
# dialect, and litmus/hetOracle.ml's table says which of those pairs carry an
# oracle, which are registered without one, and which are refused outright.  The
# emission surface is therefore one lane per REGISTERED pair, listed in
# HET_LANES / GPU_LANES below and nowhere else:
#
#   het-cuda      aarch64 corpus x cuda   POPULATED    expected-nvidia.csv
#   het-x86-hip   x86     corpus x hip    POPULATED    expected-amd.csv
#   het-x86-cuda  x86     corpus x cuda   NO-ORACLE    dev-tier machinery
#   gpu-cuda / gpu-hip                    the GPU-only (scoped LISA) arm, which
#                                         has no CPU column and so no pair
#
# The x86 lanes are what keeps the HIP RENDER under byte-level snapshot cover:
# (aarch64, hip) is ABSENT from the table and now refuses at emission, so the
# hip render of a het harness exists only on the x86 side.  They also put the
# LANDMINE SURFACE in every snapshot -- het-x86-cuda is the pair whose harnesses
# must carry no trace of the AMD oracle -- which is asserted per lane below.
#
# The x86 corpus is NOT committed (tests/het/generate-x86.sh says why); it is
# generated into a scratch dir OUTSIDE OUTDIR, so `diff -r' of two snapshots
# still compares emitted bytes only.  The het corpora are emitted from INSIDE
# their own directory so emission finds the pair's control map + the co-run
# sibling .litmus (B6b: a Disallowed test's harness embeds its mu(T) mutant and
# the canary, resolved relative to the source dir).  gpu-only reuses emit-gpu.sh.
#
# REFUSAL LANES.  An ABSENT pair is part of the emission surface too -- the
# refusal is the behaviour -- so REFUSE_LANES asserts it here rather than
# leaving it to a gate that could quietly stop running.  Nothing is written, so
# a refusal lane contributes no bytes to the snapshot.  No committed script,
# this one included, may pass `-allow-no-oracle'
# (hetlitmus/verify/allow-no-oracle-gate.sh enforces that over the whole tree).
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
# wired.  Three INDEPENDENT detectors now stand between a refusal and a green run:
#   (a) CORRUPTION -- litmus7 exits 3 and prints "HetLitmus REFUSED" (see
#       HetArch.refused); this script checks the status AND greps the marker,
#       so neither one alone is load-bearing;
#   (b) OMISSION   -- the harness directory the test must produce is checked
#       for existence and for its <t>_cpu.c and its OWN render, which fires even
#       if litmus7 were to exit 0 with nothing written.  The lane's render is
#       also required to be the ONLY one: a dir carrying the other vendor's
#       file too would mean -gpu-target stopped filtering.
#   (c) MIS-TAGGING -- every harness of a lane must carry that PAIR's oracle
#       stamp and no other pair's oracle NAME anywhere in the directory.  A
#       harness tagged from the wrong pair compiles, runs and reports; only the
#       stamp says which model it was claiming to test.
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

# THE EMISSION LANES, "<corpus>:<gpu-target>:<render extension>:<OUTDIR subdir>".
HET_LANES="aarch64:cuda:cu:het-cuda x86:hip:hip:het-x86-hip x86:cuda:cu:het-x86-cuda"
# THE RETIRED VERDICT VOCABULARY, banned in EVERY lane.  The tool characterizes:
# it reports observations and carries no prediction, so an emitted harness that
# named a class, a verdict or a verdicts CSV would be claiming something nothing
# in it derived.  Checked over the whole harness dir, header and payloads
# included.
RETIRED_TOKENS='ORACLE_[A-Z]+|_rec\.het_oracle|oracle_source|expected-(nvidia|amd)\.csv'
# The MACHINE words a lane must NOT contain anywhere in its harness dirs -- the
# landmine: an x86 host with an NVIDIA GPU is neither part, so it may name
# neither, and "Infinity Fabric" is what the (X86_64, hip) lane stamps one line
# away from here.  (`MI300A' alone is not a landmine: the CPU stress payload's
# comments compare the two hosts by name -- see cram oracle-pairs.t (f).)
forbidden_of_lane() {           # <corpus>:<target> -> egrep pattern, or ""
  case "$1" in
    x86:cuda) echo 'expected-amd|AMD-CDNA3-x86|Infinity Fabric' ;;
    *)        echo '' ;;
  esac
}
# ABSENT pairs: emission must REFUSE, exit 3, and write nothing.
REFUSE_LANES="aarch64:hip"
GPU_LANES="cuda:cu:gpu-cuda hip:hip:gpu-hip"
EXPECT_HET=411          # harness dirs per het lane
EXPECT_GPU=137          # kernels per gpu-only lane

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
# OUTSIDE OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
# dotfiles too, so no scratch file may land in it.
LOG="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -f "$LOG"; rm -rf "$SCRATCH"' EXIT

# The x86 corpus, generated on demand (it is deliberately not committed).
X86_CORPUS="$SCRATCH/x86"
gen_x86_once() {
  [ -d "$X86_CORPUS" ] && return 0
  echo "        generating the x86 corpus (not committed; tests/het/generate-x86.sh)"
  PATH="$BIN:$PATH" bash "$HETL/tests/het/generate-x86.sh" "$X86_CORPUS" >"$LOG" 2>&1 || {
    echo "FAIL: generate-x86.sh failed; its output:" >&2 ; cat "$LOG" >&2 ; exit 1 ; }
}
corpus_dir() {                  # <corpus> -> the directory to emit from
  case "$1" in
    aarch64) echo "$HETL/tests/het" ;;
    x86)     gen_x86_once >&2 ; echo "$X86_CORPUS" ;;
    *) echo "emit-all.sh: unknown corpus $1" >&2 ; return 1 ;;
  esac
}

i=0
nlanes=$(( $(echo $HET_LANES | wc -w) + $(echo $REFUSE_LANES | wc -w) \
           + $(echo $GPU_LANES | wc -w) ))

for lane in $HET_LANES; do
  corpus="${lane%%:*}"; rest="${lane#*:}"
  target="${rest%%:*}"; rest="${rest#*:}"
  ext="${rest%%:*}"; sub="${rest#*:}"
  forbidden="$(forbidden_of_lane "$corpus:$target")"
  i=$((i+1))
  echo "[$i/$nlanes] $corpus corpus, -gpu-target $target -> $OUTDIR/$sub"
  cdir="$(corpus_dir "$corpus")"
  mkdir -p "$OUTDIR/$sub"
  ( cd "$cdir"
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
          echo "FAIL: $t emitted no $f in the $corpus/$target lane (harness missing or empty); litmus7 said:" >&2
          cat "$LOG" >&2
          exit 1
        fi
      done
      for other in $HET_LANES; do
        oext="${other#*:}"; oext="${oext#*:}"; oext="${oext%%:*}"
        if [ "$oext" != "$ext" ] && [ -e "$OUTDIR/$sub/$n/$n.$oext" ]; then
          echo "FAIL: the $corpus/$target lane emitted $n/$n.$oext as well -- -gpu-target is not filtering" >&2
          exit 1
        fi
      done
      # (c) THE RECORD STAMP, and the ABSENCE of the retired verdict vocabulary.
      # het_verdict() reads no field of a record without HET_REC_MAGIC, so a
      # render that lost the stamp discards every run it will ever make.
      if [ "$(grep -c '_rec.rec_magic = HET_REC_MAGIC;' "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp _rec.rec_magic exactly once" >&2
        exit 1
      fi
      if grep -rqE "$RETIRED_TOKENS" "$OUTDIR/$sub/$n"; then
        echo "FAIL: $t in the $corpus/$target lane carries the retired verdict vocabulary:" >&2
        grep -rlE "$RETIRED_TOKENS" "$OUTDIR/$sub/$n" >&2
        exit 1
      fi
      if [ -n "$forbidden" ] \
         && grep -rqE "$forbidden" "$OUTDIR/$sub/$n"; then
        echo "FAIL: $t in the $corpus/$target lane names another pair's oracle ($forbidden):" >&2
        grep -rlE "$forbidden" "$OUTDIR/$sub/$n" >&2
        exit 1
      fi
    done )
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $EXPECT_HET), each stamping its record once, none naming a verdict"
  if [ "$nhet" -ne "$EXPECT_HET" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_HET)" >&2
    exit 1
  fi
done

for lane in $REFUSE_LANES; do
  corpus="${lane%%:*}"; target="${lane#*:}"
  i=$((i+1))
  echo "[$i/$nlanes] $corpus corpus, -gpu-target $target -> MUST REFUSE (absent pair)"
  cdir="$(corpus_dir "$corpus")"
  probe="$SCRATCH/refuse-$corpus-$target"
  mkdir -p "$probe"
  # No `ls | head': under `pipefail' the SIGPIPE that head's early exit sends to
  # ls makes the pipeline status 141, and set -e then kills this script with no
  # message at all.  Measured here, on a 411-file corpus.
  t="$(cd "$cdir" && for f in *.litmus; do echo "$f"; break; done)"
  st=0
  ( cd "$cdir" && "$LITMUS7" -gpu-target "$target" -o "$probe" "$t" ) >"$LOG" 2>&1 || st=$?
  if [ "$st" -ne 3 ]; then
    echo "FAIL: an ABSENT pair emitted instead of refusing: exit $st on $t; its output:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if ! grep -q 'HetLitmus REFUSED' "$LOG" \
     || ! grep -q 'no oracle is registered for the CPU-ISA x GPU-dialect pair' "$LOG"; then
    echo "FAIL: the refusal on $t does not name the pair; it said:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  left="$(find "$probe" -mindepth 1 | wc -l)"
  if [ "$left" -ne 0 ]; then
    echo "FAIL: the refused $corpus/$target emission left $left path(s) behind" >&2
    exit 1
  fi
  echo "        exit 3, pair named, nothing written"
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

echo "emitted: $(echo $HET_LANES | wc -w) x $EXPECT_HET het harness dirs, \
$(echo $GPU_LANES | wc -w) x $EXPECT_GPU gpu-only kernels, \
$(echo $REFUSE_LANES | wc -w) absent pair(s) refused"
