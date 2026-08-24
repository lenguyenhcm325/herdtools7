#!/usr/bin/env bash
# Emission snapshot: emit the whole corpus over every (CPU ISA x GPU dialect)
# pair into OUTDIR, one lane per pair, at the censuses EXPECT_HET / EXPECT_GPU
# below.
#
# It is the refactor golden.  The Layer-2 gate (corpus-gate.sh) byte-pins only
# the committed gpu-only samples; every other emitted artifact is covered by
# property gates (cram greps, ptxcheck, verdictcheck/statscheck corpus phases),
# which by design pass a range of outputs.  A behaviour-preserving refactor of
# the emitter proves byte-identical output instead: emit before, emit after,
# `diff -r'.  Emission is deterministic (corpus-gate.sh already relies on that
# for its samples).
#
#   ./emit-all.sh SNAP_BEFORE     # at the pre-refactor commit
#   ...refactor...
#   ./emit-all.sh SNAP_AFTER
#   diff -r SNAP_BEFORE SNAP_AFTER && echo BYTE-IDENTICAL
#
# The lanes are pairs, not vendors.  A compound harness is a CPU ISA and a GPU
# dialect, so the emission surface is one lane per (corpus x dialect)
# combination, listed in HET_LANES / GPU_LANES below and nowhere else:
#
#   het-cuda      aarch64 corpus x cuda
#   het-x86-hip   x86     corpus x hip
#   het-x86-cuda  x86     corpus x cuda
#   het-hip       aarch64 corpus x hip
#   gpu-cuda / gpu-hip                    the GPU-only (scoped LISA) arm, which
#                                         has no CPU column and so no pair
#
# The x86 corpus is not committed (tests/het/generate-x86.sh says why); it is
# generated into a scratch dir outside OUTDIR, so `diff -r' of two snapshots
# still compares emitted bytes only.  The het corpora are emitted from inside
# their own directory, so litmus7 is handed bare <test>.litmus names and the
# harness dir it writes carries the test's own name.  gpu-only reuses
# emit-gpu.sh.
#
# Fail-closed, because litmus7's batch driver catches an emission exception,
# prints it on the stream this script discards and still exits 0
# (dumpRun.ml -> litmus.ml).  Three independent detectors stand between a
# refusal and a green run:
#   (a) corruption -- litmus7 exits 3 and prints "HetLitmus REFUSED" (see
#       HetArch.refused); this script checks the status AND greps the marker,
#       so neither one alone is load-bearing;
#   (b) omission   -- the harness directory the test must produce is checked
#       for existence and for its <t>_cpu.c and its own render, which fires even
#       if litmus7 were to exit 0 with nothing written.  The lane's render is
#       also required to be the only one: a dir carrying the other vendor's
#       file too would mean -gpu-target stopped filtering.
#   (c) mis-tagging -- every harness of a lane must stamp that lane's pair name
#       exactly once.  A harness built for the wrong pair compiles, runs and
#       reports; the stamp is what says which pair it was measuring.
# Each names the test it failed on and pastes litmus7's own output.
#
# Usage:  hetlitmus/verify/emit-all.sh OUTDIR
# Exit:   0 = every lane complete; non-zero otherwise (fail-fast).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

# The emission lanes, "<corpus>:<gpu-target>:<render extension>:<OUTDIR subdir>".
HET_LANES="aarch64:cuda:cu:het-cuda x86:hip:hip:het-x86-hip x86:cuda:cu:het-x86-cuda \
aarch64:hip:hip:het-hip"
# The pair name each lane's renders must stamp.
pair_of_lane() {                # <corpus>:<target> -> the HET_PAIR_NAME value
  case "$1" in
    aarch64:*) echo "(AArch64, ${1#*:})" ;;
    x86:*)     echo "(X86_64, ${1#*:})" ;;
    *) echo "emit-all.sh: unknown lane $1" >&2 ; return 1 ;;
  esac
}
GPU_LANES="cuda:cu:gpu-cuda hip:hip:gpu-hip"
EXPECT_HET=471          # harness dirs per het lane
EXPECT_GPU=173          # kernels per gpu-only lane

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# Outside OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
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
nlanes=0
nhetlanes=0
ngpulanes=0
for lane in $HET_LANES $GPU_LANES; do nlanes=$((nlanes+1)); done

for lane in $HET_LANES; do
  corpus="${lane%%:*}"; rest="${lane#*:}"
  target="${rest%%:*}"; rest="${rest#*:}"
  ext="${rest%%:*}"; sub="${rest#*:}"
  nhetlanes=$((nhetlanes+1))
  want_pair="$(pair_of_lane "$corpus:$target")"
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
      # (c) The record stamp.  het_verdict() reads no field of a record without
      # HET_REC_MAGIC, so a render that lost the stamp discards every run it
      # will ever make.
      if [ "$(grep -c '_rec.rec_magic = HET_REC_MAGIC;' "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp _rec.rec_magic exactly once" >&2
        exit 1
      fi
      # The pair this harness was built for.
      if [ "$(grep -cF "#define HET_PAIR_NAME \"$want_pair\"" "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp HET_PAIR_NAME \"$want_pair\" exactly once; it stamps:" >&2
        grep -F '#define HET_PAIR_NAME' "$OUTDIR/$sub/$n/$n.$ext" >&2 \
          || echo "  (no HET_PAIR_NAME at all)" >&2
        exit 1
      fi
    done )
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $EXPECT_HET), each stamping its record and $want_pair once"
  if [ "$nhet" -ne "$EXPECT_HET" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_HET)" >&2
    exit 1
  fi
done

for lane in $GPU_LANES; do
  target="${lane%%:*}"; rest="${lane#*:}"; ext="${rest%%:*}"; sub="${rest#*:}"
  ngpulanes=$((ngpulanes+1))
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

echo "emitted: $nhetlanes x $EXPECT_HET het harness dirs, \
$ngpulanes x $EXPECT_GPU gpu-only kernels"
