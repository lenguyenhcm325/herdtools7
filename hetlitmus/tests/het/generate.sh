#!/usr/bin/env bash
# Generate the heterogeneous (compound CPU-GPU) HetLitmus corpus with hetgen7
# (gen/hetGen.ml), which runs the monomorphic diy cycle engine once per device
# and merges each proc's column from the run owning that proc's device.  How
# and why: hetlitmus/docs/het-generation.md; the grid rule: docs/corpus-grid.md.
#
#   usage:  ./generate.sh             # the committed corpus + the @all manifest
#           ./generate.sh OUTDIR      # the same corpus, into OUTDIR instead
#           CPU_ARCHS="aarch64 x86_64" ./generate.sh
#
# OUTDIR (default: this directory) exists for verify/corpus-gate.sh, which says
# there why it regenerates out of tree.
#
# CPU_ARCHS (default "aarch64", matching GH200) selects which CPU ISAs the
# cpu-tagged procs are generated for; the x86_64 variants (suffix -x86_64) are
# generated on demand only and are not committed.
#
# The corpus, in the order the sections below emit it:
#  (A) MP-het, SB-het -- the hand-checked reference tests.  MP-het is
#      regenerated and diffed, never overwritten here (an OUTDIR gets the
#      regeneration, so its rendering is complete); SB-het is (re)generated.
#  (B) The one-sided grid <shape>-<cuttag>-<scope>-<order>.litmus: every shape x
#      canonical device cut x scope{cta,gpu,sys} x order{relaxed,acquire,
#      release,fence}.  GPU procs carry the annotation, CPU procs are plain
#      AArch64.  A column byte-identical to its relaxed sibling is dropped.
#  (D) The two-sided family <shape>-<cuttag>-sys-{acqrel,fence}-2s: BOTH devices
#      annotated, so a complete morally-strong cross-device pair can form.
#  (E) The two-sided order-pair grid <shape>-<cuttag>-sys-<cpu>.<gpu>-2s: the
#      off-diagonal of (D), one file per pair-grid cut class x non-diagonal
#      cell of the (cpu order, gpu order) grid (../_grid_lib.sh).
#
# No expected outcome is attached to any of these tests: this branch predicts
# none, and comparing a run against a verdict CSV is an optional offline step
# over a file the reader supplies (docs/oracle-harness.md).

set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path works -- the same rule generate-x86.sh and generate-cpuonly.sh
# state at this spot.
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

regen="${TMPDIR:-/tmp}/MP-het.regen.$$.litmus"
"$BIN/hetgen7" $COMMON -devices cpu,gpu -name MP-het \
  -com "Heterogeneous message-passing: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)" \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys" \
  > "$regen"
if diff -w -q "$regen" "$HETDIR/MP-het.litmus" >/dev/null; then
  echo "MP-het: generator reproduces hand-written MP-het.litmus (modulo whitespace)"
else
  echo "MP-het: WARNING generated output differs from MP-het.litmus" >&2
  diff -w "$regen" "$HETDIR/MP-het.litmus" || true
fi
# In the committed tree the hand-written file is authoritative, so it is left
# alone; an OUTDIR rendering has to carry the test all the same.
[ "$OUT" = "$HETDIR" ] || cp "$regen" "$OUT/MP-het.litmus"
rm -f "$regen"

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
# Both halves annotated: the CPU cycle with ARM atoms (render_cpu_cycle) and the
# GPU cycle with the matching sys annotation, so the corpus carries the
# cross-device pair annotated on BOTH sides -- (B) annotates the GPU half alone.
# Restricted to sys scope (cta and gpu name GPU threads only, so a CPU proc sits
# outside them however it is annotated) and to the complete pairings {acqrel,
# fence} -- acquire or release alone annotates one role only.
# Generated for aarch64 only: the committed corpus is the AArch64 rendering, and
# the x86 CPU column is emitted on demand by generate-x86.sh (its header says
# why it is not committed).
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
# (D) gives both devices the same order name, i.e. the diagonal only.  The
# ordering a primitive supplies depends on which program-order pair its proc
# has, so sweep  cpu in {ra, sy, st, ld} x gpu in {ra, sc, rel, acq}, named
# <shape>-<cuttag>-sys-<cpu>.<gpu>-2s.  ../_grid_lib.sh has the token table and
# why only 2-proc shapes (minus 2+2W) and one cut for SB/LB.
pair_count=0 diag_count=0
for shape in $TWO_SIDED_PAIR_SHAPES; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_2S_PAIR_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for c in $TWO_SIDED_CPU_ORDERS; do
      for g in $TWO_SIDED_GPU_ORDERS; do
        cpu_toks=$(render_2s_cpu "$c" $cyc)
        gpu_toks=$(render_2s_gpu "$g" $cyc)
        # The two diagonal cells already exist under their (D) names: prove it
        # by regenerating under the (D) name and byte-diffing the committed
        # file, then skip (emitting them would be an exact duplicate, which
        # verify/dupcheck.py rejects anyway).
        diag=""
        [ "$c.$g" = "ra.ra" ] && diag="$shape-$tag-sys-acqrel-2s"
        [ "$c.$g" = "sy.sc" ] && diag="$shape-$tag-sys-fence-2s"
        if [ -n "$diag" ]; then
          "$BIN/hetgen7" $COMMON -cpu-arch aarch64 -devices "$cut" -name "$diag" \
            -cpu "$cpu_toks" -gpu "$gpu_toks" > "/tmp/hetgen-diag.$$.litmus"
          if ! diff -q "/tmp/hetgen-diag.$$.litmus" "$diag.litmus" >/dev/null; then
            echo "generate.sh: FATAL $c.$g does NOT reproduce $diag" >&2
            diff "/tmp/hetgen-diag.$$.litmus" "$diag.litmus" >&2 || true
            rm -f "/tmp/hetgen-diag.$$.litmus"; exit 1
          fi
          rm -f "/tmp/hetgen-diag.$$.litmus"
          diag_count=$((diag_count+1)); continue
        fi
        name="$shape-$tag-sys-$c.$g-2s"
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
