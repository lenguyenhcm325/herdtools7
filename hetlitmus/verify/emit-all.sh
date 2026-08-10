#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus over every (CPU ISA x GPU
# dialect) pair into OUTDIR -- 411 het harness dirs per het lane and 137
# gpu-only kernels per gpu-only lane.
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
# dialect, and litmus/hetMachine.ml's table says which of those pairs may NAME a
# machine.  Every pair emits; the table decides what the render is entitled to
# claim, so the emission surface is one lane per (corpus x dialect) combination,
# listed in HET_LANES / GPU_LANES below and nowhere else:
#
#   het-cuda      aarch64 corpus x cuda   GH200 machine words stamped
#   het-x86-hip   x86     corpus x hip    MI300A machine words stamped
#   het-x86-cuda  x86     corpus x cuda   registered, no machine row: no stamps
#   het-hip       aarch64 corpus x hip    unregistered: no stamps, warned
#   gpu-cuda / gpu-hip                    the GPU-only (scoped LISA) arm, which
#                                         has no CPU column and so no pair
#
# The two lanes that stamp NOTHING are the LANDMINE SURFACE, asserted per lane
# below: a render that names a machine its pair has no row for is the one defect
# no reader of a results tree could catch afterwards.
#
# The x86 corpus is NOT committed (tests/het/generate-x86.sh says why); it is
# generated into a scratch dir OUTSIDE OUTDIR, so `diff -r' of two snapshots
# still compares emitted bytes only.  The het corpora are emitted from INSIDE
# their own directory so emission finds the pair's control map + the co-run
# sibling .litmus (B6b: a Disallowed test's harness embeds its mu(T) mutant and
# the canary, resolved relative to the source dir).  gpu-only reuses emit-gpu.sh.
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
#   (c) MIS-TAGGING -- every harness of a lane must carry that PAIR's name, that
#       pair's machine defines and NO other pair's machine words anywhere in the
#       directory.  A harness built for the wrong pair compiles, runs and
#       reports; only the stamps say which machine it was measuring.
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
HET_LANES="aarch64:cuda:cu:het-cuda x86:hip:hip:het-x86-hip x86:cuda:cu:het-x86-cuda \
aarch64:hip:hip:het-hip"
# THE RETIRED VERDICT VOCABULARY, banned in EVERY lane.  The tool characterizes:
# it reports observations and carries no prediction, so an emitted harness that
# named a class, a verdict or a verdicts CSV would be claiming something nothing
# in it derived.  Checked over the whole harness dir, header and payloads
# included.
RETIRED_TOKENS='ORACLE_[A-Z]+|_rec\.het_oracle|oracle_source|expected-(nvidia|amd)\.csv'
# The OTHER VENDOR'S words a lane must NOT contain anywhere in its harness dirs
# -- the landmine: an x86 host with an NVIDIA GPU is neither published part, and
# "Infinity Fabric" is what the (X86_64, hip) lane stamps one line away from
# here.  (`MI300A' alone is not a landmine: the CPU stress payload's comments
# compare the two hosts by name -- see cram machine-pairs.t (e).)
forbidden_of_lane() {           # <corpus>:<target> -> egrep pattern, or ""
  case "$1" in
    x86:cuda) echo 'expected-amd|AMD-CDNA3-x86|Infinity Fabric' ;;
    *)        echo '' ;;
  esac
}
# The MACHINE PHRASES, and the one place a lane entitled to no machine may not
# put them: a line the driver PRINTS.  Both rows' words appear in the dialect
# payloads' comparative comments -- the .inc files pasted into the render explain
# the CUDA lane by naming the part they were derived for -- so a blanket ban on
# the word would ban the comment.  What may not happen is a harness TELLING its
# reader which Grace half was disabled on a box that has no Grace: that sentence
# is built from HET_HOST_HALF / HET_DEV_HALF / HET_LINK_NAME, and a lane that
# stamps none of them gets the mechanism-naming defaults instead.
MACHINE_PHRASES='Infinity Fabric|NVLink-C2C|the Grace half|the Hopper half|the x86 half|the MI300A device half'
# THE PAIR NAME each lane's renders must stamp, and the MACHINE DEFINE BLOCK each
# is entitled to -- verbatim, in emission order, empty where the pair has no
# machine row (litmus/hetMachine.ml).  Checked as a whole block rather than by
# count: a lane that stamped another row's words in the right number would pass a
# count.
pair_of_lane() {                # <corpus>:<target> -> the HET_PAIR_NAME value
  case "$1" in
    aarch64:*) echo "(AArch64, ${1#*:})" ;;
    x86:*)     echo "(X86_64, ${1#*:})" ;;
    *) echo "emit-all.sh: unknown lane $1" >&2 ; return 1 ;;
  esac
}
machine_of_lane() {             # <corpus>:<target> -> the #define block, or ""
  case "$1" in
    aarch64:cuda)
      printf '%s\n' '#define HET_LINK_NAME "NVLink-C2C"' \
                    '#define HET_HOST_HALF "the Grace half"' \
                    '#define HET_DEV_HALF "the Hopper half"' \
                    '#define HET_LLC_MB 114' \
                    '#define HET_ALGLAVE_ZERO_MEASURED 1' ;;
    x86:hip)
      printf '%s\n' '#define HET_LINK_NAME "Infinity Fabric"' \
                    '#define HET_HOST_HALF "the x86 half"' \
                    '#define HET_DEV_HALF "the MI300A device half"' \
                    '#define HET_LLC_MB 256' ;;
    *) : ;;
  esac
}
# ...and, where no machine is stamped, WHICH of the two reasons the render gives
# for it: a REGISTERED pair is deliberately nameless, an unregistered one was
# never considered.  Only litmus/hetMachine.ml's registered bit tells them apart,
# and this line is the only place that bit reaches a reader.
nomachine_note_of_lane() {      # <corpus>:<target> -> the sentence, or ""
  case "$1" in
    aarch64:cuda|x86:hip) : ;;
    aarch64:hip) echo 'is in no' ;;
    *)           echo 'no machine row backs this' ;;
  esac
}
MACHINE_DEFINE_RE='^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)'
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
nlanes=$(( $(echo $HET_LANES | wc -w) + $(echo $GPU_LANES | wc -w) ))

for lane in $HET_LANES; do
  corpus="${lane%%:*}"; rest="${lane#*:}"
  target="${rest%%:*}"; rest="${rest#*:}"
  ext="${rest%%:*}"; sub="${rest#*:}"
  forbidden="$(forbidden_of_lane "$corpus:$target")"
  want_pair="$(pair_of_lane "$corpus:$target")"
  want_machine="$(machine_of_lane "$corpus:$target")"
  want_note="$(nomachine_note_of_lane "$corpus:$target")"
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
      # THE PAIR, and the machine words that pair is entitled to.
      if [ "$(grep -cF "#define HET_PAIR_NAME \"$want_pair\"" "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp HET_PAIR_NAME \"$want_pair\" exactly once; it stamps:" >&2
        grep -F '#define HET_PAIR_NAME' "$OUTDIR/$sub/$n/$n.$ext" >&2 \
          || echo "  (no HET_PAIR_NAME at all)" >&2
        exit 1
      fi
      got_machine="$(grep -E "$MACHINE_DEFINE_RE" "$OUTDIR/$sub/$n/$n.$ext" || true)"
      if [ "$got_machine" != "$want_machine" ]; then
        echo "FAIL: $t in the $corpus/$target lane stamps the wrong machine.  It stamps:" >&2
        printf '%s\n' "${got_machine:-  (nothing)}" | sed 's/^/  /' >&2
        echo "  and this pair is entitled to:" >&2
        printf '%s\n' "${want_machine:-  (nothing)}" | sed 's/^/  /' >&2
        exit 1
      fi
      if [ -n "$want_note" ]; then
        if ! grep -qF "$want_note" "$OUTDIR/$sub/$n/$n.$ext"; then
          echo "FAIL: $t in the $corpus/$target lane names no machine and does not say WHY (\"$want_note\") -- a registered pair with no machine row and a pair in no row at all read alike" >&2
          exit 1
        fi
        if grep -E 'fprintf\(' "$OUTDIR/$sub/$n/$n.$ext" | grep -qE "$MACHINE_PHRASES"; then
          echo "FAIL: $t in the $corpus/$target lane PRINTS a machine phrase, and its pair is entitled to none:" >&2
          grep -E 'fprintf\(' "$OUTDIR/$sub/$n/$n.$ext" | grep -E "$MACHINE_PHRASES" >&2
          exit 1
        fi
      fi
      if [ -n "$forbidden" ] \
         && grep -rqE "$forbidden" "$OUTDIR/$sub/$n"; then
        echo "FAIL: $t in the $corpus/$target lane names a machine its pair has no row for ($forbidden):" >&2
        grep -rlE "$forbidden" "$OUTDIR/$sub/$n" >&2
        exit 1
      fi
    done )
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $EXPECT_HET), each stamping its record and $want_pair once, none naming a verdict or another pair's machine"
  if [ "$nhet" -ne "$EXPECT_HET" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_HET)" >&2
    exit 1
  fi
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
$(echo $GPU_LANES | wc -w) x $EXPECT_GPU gpu-only kernels"
