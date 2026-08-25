#!/usr/bin/env bash
# Generate the heterogeneous (compound CPU-GPU) HetLitmus corpus with hetgen7
# (gen/hetGen.ml).  How the merge works: hetlitmus/docs/het-generation.md.  The
# grid rule, the families (A) (B) (D) (E) and the CPU_ARCHS knob:
# hetlitmus/docs/corpus-grid.md.
#
#   usage:  ./generate.sh             # the committed corpus + the @all manifest
#           ./generate.sh OUTDIR      # the same corpus, into OUTDIR instead
#           CPU_ARCHS="aarch64 x86_64" ./generate.sh
#
# OUTDIR (default: this directory) exists for verify/corpus-gate.sh.

set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path works.
OUT="${1:-}"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; fi

cd "$(dirname "$0")"
HETDIR="$(pwd)"
: "${OUT:=$HETDIR}"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell -oneloc"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

# Everything below writes and reads siblings relative to the cwd, so the corpus
# lands wherever OUTDIR points; $HETDIR stays the address of the committed tree.
cd "$OUT"

CPU_ARCHS="${CPU_ARCHS:-aarch64}"

# ---------------------------------------------------------------------------
# (A) Reference tests.
# ---------------------------------------------------------------------------
"$BIN/hetgen7" $COMMON -devices cpu,gpu -name SB-het \
  -com "Heterogeneous store-buffering: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)" \
  -cpu "PodWR Fre PodWR Fre" \
  -gpu "PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys" \
  > SB-het.litmus
echo "generated SB-het.litmus"

"$BIN/hetgen7" $COMMON -devices cpu,gpu -name MP-het \
  -com "Heterogeneous message-passing: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)" \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys" \
  > MP-het.litmus
echo "generated MP-het.litmus"

# ---------------------------------------------------------------------------
# (B) The grid.
# ---------------------------------------------------------------------------
grid_count=0 skip_count=0
for cpu_arch in $CPU_ARCHS; do
  asfx=""; [ "$cpu_arch" != aarch64 ] && asfx="-$cpu_arch"
  for shape in $SHAPE_ORDER; do
    cyc="${SHAPE_CYCLE[$shape]}"
    for cut in ${SHAPE_HET_CUTS[$shape]}; do
      tag=$(cut_tag "$cut")
      for scope in $GRID_SCOPES; do
        relaxed_file="$shape-$tag-$scope-relaxed$asfx.litmus"
        for order in $GRID_ORDERS; do
          name="$shape-$tag-$scope-$order$asfx"
          gpu_toks=$(render_cycle "$scope" "$order" $cyc)
          "$BIN/hetgen7" $COMMON -cpu-arch "$cpu_arch" -devices "$cut" -name "$name" \
            -cpu "$cyc" -gpu "$gpu_toks" > "$name.litmus"
          # Content dedup: drop a non-relaxed variant byte-identical to its
          # relaxed sibling (the cut put the changed annotation on a CPU proc,
          # or on a GPU proc with no matching access).  Compare from line 3,
          # skipping `Het <name>' + the comment line.
          if [ "$order" != relaxed ] && [ -f "$relaxed_file" ] \
             && diff -q <(tail -n +3 "$relaxed_file") <(tail -n +3 "$name.litmus") >/dev/null; then
            rm -f "$name.litmus"
            echo "  skip $name (degenerate: == $shape-$tag-$scope-relaxed$asfx)"
            skip_count=$((skip_count+1)); continue
          fi
          grid_count=$((grid_count+1))
        done
      done
    done
  done
done

# ---------------------------------------------------------------------------
# (D) The two-sided family: complete the morally-strong cross-device pair.
# ---------------------------------------------------------------------------
# Both halves annotated, so the cross-device pair closes -- (B) annotates the GPU
# half alone.  Which orders and why sys scope: ../_grid_lib.sh, TWO_SIDED_ORDERS.
# aarch64 only; generate-x86.sh renders the x86 CPU column on demand.
twosided_count=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_HET_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for order in $TWO_SIDED_ORDERS; do
      name="$shape-$tag-sys-$order-2s"
      cpu_toks=$(render_cpu_cycle "$order" $cyc)
      gpu_toks=$(render_cycle sys "$order" $cyc)
      "$BIN/hetgen7" $COMMON -cpu-arch aarch64 -devices "$cut" -name "$name" \
        -cpu "$cpu_toks" -gpu "$gpu_toks" > "$name.litmus"
      # Drop a two-sided test that does not actually differ from its one-sided
      # sibling: when every CPU proc of the cut is single-access the annotation
      # has nothing to attach to (IRIW-gcgc fence -- both CPU procs are single
      # writers).  Only `fence' can bite here; the grid emits no
      # <shape>-<tag>-sys-acqrel sibling to compare against.
      onesided="$shape-$tag-sys-$order.litmus"
      if [ -f "$onesided" ] \
         && diff -q <(tail -n +3 "$onesided") <(tail -n +3 "$name.litmus") >/dev/null; then
        rm -f "$name.litmus"
        echo "  skip $name (not two-sided: == $shape-$tag-sys-$order)"
        skip_count=$((skip_count+1)); continue
      fi
      twosided_count=$((twosided_count+1))
    done
  done
done

# ---------------------------------------------------------------------------
# (E) The two-sided order-pair grid: the off-diagonal of (D).
# ---------------------------------------------------------------------------
# (D) gives both devices the same order name, i.e. the diagonal only, so sweep
# cpu in {ra, sy, st, ld} x gpu in {ra, sc, rel, acq}, named
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
        name="$shape-$tag-sys-$c.$g-2s"
        cpu_toks=$(render_2s_cpu "$c" $cyc)
        gpu_toks=$(render_2s_gpu "$g" $cyc)
        "$BIN/hetgen7" $COMMON -cpu-arch aarch64 -devices "$cut" -name "$name" \
          -cpu "$cpu_toks" -gpu "$gpu_toks" > "$name.litmus"
        pair_count=$((pair_count+1))
      done
    done
  done
done

# ---------------------------------------------------------------------------
# @all manifest (only the committed, default-arch tests if CPU_ARCHS=aarch64).
# ---------------------------------------------------------------------------
ls *.litmus | LC_ALL=C sort > @all
echo "Done. $(wc -l < @all) tests in $(pwd); manifest @all written."
echo "  grid $grid_count (+$skip_count degenerate skipped), two-sided $twosided_count, order-pair $pair_count (+$diag_count diagonal cells == their (D) sibling)"
