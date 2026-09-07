#!/usr/bin/env bash
# emit-all.sh -- emit the built corpus trees (paths.sh) over every (CPU ISA x
# GPU dialect) lane into OUTDIR, at the censuses verify/census.sh pins.  A
# behaviour-preserving
# emitter refactor proves itself byte-identical against two snapshots:
#   ./emit-all.sh SNAP_BEFORE; ...refactor...; ./emit-all.sh SNAP_AFTER
#   diff -r SNAP_BEFORE SNAP_AFTER && echo BYTE-IDENTICAL
# litmus7's batch driver catches an emission exception and still exits 0, so
# each lane is fail-closed three ways: litmus7's status AND the "HetLitmus
# REFUSED" marker; the harness dir with its _cpu.c, its render and no other
# vendor's; and the pair name every render must stamp exactly once.
# Usage: hetlitmus/verify/emit-all.sh OUTDIR.  Exit 0 = every lane complete.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
. "$HETL/verify/census.sh"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

# The emission lanes, "<corpus>:<gpu-target>:<render extension>:<OUTDIR subdir>".
HET_LANES="aarch64:cuda:cu:het-cuda x86:hip:hip:het-x86_64-hip x86:cuda:cu:het-x86_64-cuda \
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
EXPECT_GPU="$CENSUS_GPU_ONLY"     # kernels per gpu-only lane
expect_of_corpus() {            # <corpus> -> harness dirs per het lane
  case "$1" in
    aarch64) echo "$CENSUS_HET" ;;
    x86)     echo "$CENSUS_HET_X86" ;;
    *) echo "emit-all.sh: unknown corpus $1" >&2 ; return 1 ;;
  esac
}

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# Outside OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
# dotfiles too, so no scratch file may land in it.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

corpus_dir() {                  # <corpus> -> the built tree to emit from
  case "$1" in
    aarch64) echo "$HET_CORPUS" ;;
    x86)     echo "$X86_CORPUS" ;;
    *) echo "emit-all.sh: unknown corpus $1" >&2 ; return 1 ;;
  esac
}
for d in "$HET_CORPUS" "$X86_CORPUS" "$GPU_CORPUS"; do
  [ -d "$d" ] || { echo "error: $d not built (run 'make hetlitmus-corpus-gen')" >&2; exit 2; }
done

i=0
nlanes=0
ngpulanes=0
nhet_total=0
for lane in $HET_LANES $GPU_LANES; do nlanes=$((nlanes+1)); done

for lane in $HET_LANES; do
  corpus="${lane%%:*}"; rest="${lane#*:}"
  target="${rest%%:*}"; rest="${rest#*:}"
  ext="${rest%%:*}"; sub="${rest#*:}"
  want_pair="$(pair_of_lane "$corpus:$target")"
  expect_het="$(expect_of_corpus "$corpus")"
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
      # The pair this harness was built for.
      if [ "$(grep -cF "#define HET_PAIR_NAME \"$want_pair\"" "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp HET_PAIR_NAME \"$want_pair\" exactly once; it stamps:" >&2
        grep -F '#define HET_PAIR_NAME' "$OUTDIR/$sub/$n/$n.$ext" >&2 \
          || echo "  (no HET_PAIR_NAME at all)" >&2
        exit 1
      fi
    done )
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $expect_het), each stamping $want_pair once"
  if [ "$nhet" -ne "$expect_het" ]; then
    echo "FAIL: census mismatch in $sub (want $expect_het)" >&2
    exit 1
  fi
  nhet_total=$((nhet_total+nhet))
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

echo "emitted: $nhet_total het harness dirs over $((nlanes-ngpulanes)) lanes, \
$ngpulanes x $EXPECT_GPU gpu-only kernels"
