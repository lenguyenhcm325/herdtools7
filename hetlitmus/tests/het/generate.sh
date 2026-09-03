#!/usr/bin/env bash
# Generate the heterogeneous (compound CPU-GPU) HetLitmus corpus with hetgen7
# (gen/hetGen.ml) for ONE CPU ISA.  How the merge works:
# hetlitmus/docs/het-generation.md.  The grid rule, the families (A) (B) (D)
# (E) and the CPU ISA of a rendering: hetlitmus/docs/corpus-grid.md.
#
#   usage:  ./generate.sh                          # the committed corpus + @all
#           ./generate.sh OUTDIR                   # the same corpus, into OUTDIR
#           ./generate.sh --cpu-arch x86_64 OUTDIR # the x86_64 rendering
#
# A rendering in a non-default ISA is refused into this directory; OUTDIR
# (default: this directory) exists for verify/corpus-gate.sh.
# Exit: 0 = the rendering is complete; 1 = OUTDIR holds a .litmus this run did
# not write; 2 = bad argument or unknown ISA.

set -e
usage() { echo "usage: generate.sh [--cpu-arch aarch64|x86_64] [OUTDIR]" >&2; }
CPU_ARCH=aarch64 OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cpu-arch) [ $# -ge 2 ] || { usage; exit 2; }; CPU_ARCH="$2"; shift 2;;
    -h|--help)  usage; exit 0;;
    -*)         usage; exit 2;;
    *)  [ -z "$OUT" ] || { echo "generate.sh: one OUTDIR, not \"$OUT\" and \"$1\"" >&2; exit 2; }
        OUT="$1"; shift;;
  esac
done
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path works.
if [ -n "$OUT" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; fi

cd "$(dirname "$0")"
HETDIR="$(pwd)"
: "${OUT:=$HETDIR}"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/gpu.bell -oneloc -cpu-arch $CPU_ARCH"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

cpu_arch_check "$CPU_ARCH" || exit 2
SFX="${CPU_ARCH_SFX[$CPU_ARCH]}"
CPU_NAME="${CPU_ARCH_NAME[$CPU_ARCH]}"
if [ -n "$SFX" ] && [ "$OUT" = "$HETDIR" ]; then
  echo "generate.sh: refusing to write the $CPU_ARCH rendering into the committed corpus $HETDIR; name an OUTDIR" >&2
  exit 2
fi

# Everything below writes and reads siblings relative to the cwd, so the corpus
# lands wherever OUTDIR points; $HETDIR stays the address of the committed tree.
cd "$OUT"

# ---------------------------------------------------------------------------
# (A) Reference tests.
# ---------------------------------------------------------------------------
"$BIN/hetgen7" $COMMON -devices cpu,gpu -name "SB-het$SFX" \
  -com "Heterogeneous store-buffering: P0 on the CPU ($CPU_NAME), P1 on the GPU (LISA)" \
  -cpu "PodWR Fre PodWR Fre" \
  -gpu "PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys" \
  > "SB-het$SFX.litmus"
echo "generated SB-het$SFX.litmus"

"$BIN/hetgen7" $COMMON -devices cpu,gpu -name "MP-het$SFX" \
  -com "Heterogeneous message-passing: P0 on the CPU ($CPU_NAME), P1 on the GPU (LISA)" \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys" \
  > "MP-het$SFX.litmus"
echo "generated MP-het$SFX.litmus"
ref_count=2

# ---------------------------------------------------------------------------
# (B) The grid.
# ---------------------------------------------------------------------------
grid_count=0 grid_skip=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_HET_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for scope in $GRID_SCOPES; do
      relaxed_file="$shape-$tag-$scope-relaxed$SFX.litmus"
      for order in $GRID_ORDERS; do
        name="$shape-$tag-$scope-$order$SFX"
        gpu_toks=$(render_cycle "$scope" "$order" $cyc)
        "$BIN/hetgen7" $COMMON -devices "$cut" -name "$name" \
          -cpu "$cyc" -gpu "$gpu_toks" > "$name.litmus"
        # Content dedup: drop a non-relaxed variant byte-identical to its
        # relaxed sibling (the cut put the changed annotation on a CPU proc,
        # or on a GPU proc with no matching access).  Compare from line 3,
        # skipping `Het <name>' + the comment line.
        if [ "$order" != relaxed ] && [ -f "$relaxed_file" ] \
           && diff -q <(tail -n +3 "$relaxed_file") <(tail -n +3 "$name.litmus") >/dev/null; then
          rm -f "$name.litmus"
          echo "  skip $name (degenerate: == $shape-$tag-$scope-relaxed$SFX)"
          grid_skip=$((grid_skip+1)); continue
        fi
        grid_count=$((grid_count+1))
      done
    done
  done
done

# ---------------------------------------------------------------------------
# (D) The two-sided family: annotate both halves of the cross-device pair.
# ---------------------------------------------------------------------------
# Both halves annotated, so the cross-device pair closes -- (B) annotates the GPU
# half alone.  Which orders and why sys scope: ../_grid_lib.sh, TWO_SIDED_ORDERS.
twosided_count=0 twosided_skip=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_HET_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for order in $TWO_SIDED_ORDERS; do
      name="$shape-$tag-sys-$order-2s$SFX"
      ctok=$(two_sided_cpu_tok "$order") || exit 2
      cpu_toks=$(render_2s_cpu "$CPU_ARCH" "$ctok" $cyc)
      gpu_toks=$(render_cycle sys "$order" $cyc)
      "$BIN/hetgen7" $COMMON -devices "$cut" -name "$name" \
        -cpu "$cpu_toks" -gpu "$gpu_toks" > "$name.litmus"
      # Drop a two-sided test byte-identical below its header to its one-sided
      # sibling (hetlitmus/docs/corpus-grid.md, "(D) Matched two-sided").
      onesided="$shape-$tag-sys-$order$SFX.litmus"
      if [ -f "$onesided" ] \
         && diff -q <(tail -n +3 "$onesided") <(tail -n +3 "$name.litmus") >/dev/null; then
        rm -f "$name.litmus"
        echo "  skip $name (not two-sided: == $shape-$tag-sys-$order$SFX)"
        twosided_skip=$((twosided_skip+1)); continue
      fi
      twosided_count=$((twosided_count+1))
    done
  done
done

# ---------------------------------------------------------------------------
# (E) The two-sided order-pair grid: the off-diagonal of (D).
# ---------------------------------------------------------------------------
# (D) gives both devices the same order name, i.e. the diagonal only, so sweep
# cpu in {ra, sy, st, ld} x gpu in {ra, sc, rel, acq, acqrel}, named
# <shape>-<cuttag>-sys-<cpu>.<gpu>-2s.  ../_grid_lib.sh has the token table and
# why only 2-proc shapes (minus 2+2W) and one cut for SB/LB.
pair_count=0 diag_count=0
for shape in $TWO_SIDED_PAIR_SHAPES; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_2S_PAIR_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for c in $TWO_SIDED_CPU_ORDERS; do
      for g in $TWO_SIDED_GPU_ORDERS; do
        # The diagonal cells already exist under their (D) names; re-emitting
        # one would be an exact duplicate.
        [ "$c.$g" = "ra.ra" ] && { diag_count=$((diag_count+1)); continue; }
        [ "$c.$g" = "sy.sc" ] && { diag_count=$((diag_count+1)); continue; }
        name="$shape-$tag-sys-$c.$g-2s$SFX"
        cpu_toks=$(render_2s_cpu "$CPU_ARCH" "$c" $cyc)
        gpu_toks=$(render_2s_gpu "$g" $cyc)
        "$BIN/hetgen7" $COMMON -devices "$cut" -name "$name" \
          -cpu "$cpu_toks" -gpu "$gpu_toks" > "$name.litmus"
        pair_count=$((pair_count+1))
      done
    done
  done
done

# ---------------------------------------------------------------------------
# The count and the @all manifest.  A .litmus file this run did not write is
# not part of the rendering and must not reach the manifest.
# ---------------------------------------------------------------------------
n="$(ls *.litmus | wc -l)"
written=$((ref_count+grid_count+twosided_count+pair_count))
if [ "$n" -ne "$written" ]; then
  echo "generate.sh: $n .litmus files in $(pwd) but this run wrote $written; remove the file(s) it did not write" >&2
  exit 1
fi
ls *.litmus | LC_ALL=C sort > @all
echo "Done. $n tests in $(pwd), CPU ISA $CPU_ARCH; manifest @all written."
echo "  reference $ref_count, grid $grid_count (+$grid_skip degenerate skipped), two-sided $twosided_count (+$twosided_skip not two-sided), order-pair $pair_count (+$diag_count diagonal cells == their (D) sibling)"
