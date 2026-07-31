#!/usr/bin/env bash
# Generate the heterogeneous (compound CPU-GPU) HetLitmus corpus with hetgen7
# (gen/hetGen.ml).
#
# The diy cycle engine is monomorphic in one architecture, so hetgen7 runs it
# ONCE PER DEVICE on a device-appropriate cycle of the SAME logical shape, then
# keeps each proc's column from the run owning that proc's device and merges the
# columns + init + condition into one Tier-0 `Het' test.  The CPU procs are
# plain AArch64 (relaxed); the scope x order grid lives on the GPU procs (the
# only place scopes exist).  See ../_grid_lib.sh and hetlitmus/docs/{het-
# generation,corpus-grid}.md.
#
# Corpus = three parts:
#  (A) MP-het, SB-het: the hand-checked Tier-0/Tier-2 reference tests.  MP-het is
#      regenerated and diffed (not overwritten); SB-het is (re)generated.
#  (B) The grid: every standard shape x canonical device cut (settled decision
#      #1: role-based, symmetry-reduced -- 2-proc shapes both directions; 3-proc
#      each proc in turn on the GPU; IRIW the four reader/writer symmetry cuts;
#      WRC3 each chain stage in turn) x scope{cta,gpu,sys} x order{relaxed,
#      acquire,release,fence}, named <shape>-<cuttag>-<scope>-<order>.litmus.
#      A column byte-identical to its relaxed sibling (e.g. `acquire' when the
#      GPU proc only writes) is dropped as degenerate.
#  (C) CPU-ISA knob: CPU_ARCHS (default "aarch64", matching GH200) selects which
#      CPU ISAs the cpu-tagged procs are generated for.  Run
#         CPU_ARCHS="aarch64 x86_64" ./generate.sh
#      to also emit x86_64 het variants (suffix -x86_64) with no code edit; the
#      x86_64 files are NOT committed by default.
#  (E) The two-sided ORDER-PAIR grid: <shape>-<cuttag>-sys-<cpu>.<gpu>-2s, the
#      OFF-DIAGONAL of (D).  (D) applies the same order name to both devices, so
#      only the diagonal was ever generated; (E) sweeps cpu in {ra,sy,st,ld} x
#      gpu in {ra,sc,rel,acq} on the 2-proc shapes (minus 2+2W) -- 8 cut classes
#      x (16 - 2 diagonal) = 112 files.  See ../_grid_lib.sh.
#  (D) The TWO-SIDED family: <shape>-<cuttag>-sys-{acqrel,fence}-2s.  Unlike (A)-
#      (C) (GPU annotated, CPU plain), these annotate BOTH devices so a complete
#      morally-strong cross-device pair forms (CPU: STLR/LDAPR/DMB.SY via
#      render_cpu_cycle; GPU: matching sys release/acquire/fence).  These are the
#      tests that can be Disallowed -- see expected-nvidia.csv and docs/het-
#      oracle.md.
#
# ORACLE: the NVIDIA GH200 oracle is tests/het/expected-nvidia.csv (Model
# NVIDIA-PTX-AArch64), regenerated reproducibly by build-nvidia-oracle.sh.  The
# one-sided tests (A)-(C) are Allowed/NO-ORACLE (the plain-CPU baseline); the
# two-sided tests (D) carry the grounded Disallowed verdicts.  The PLDI'23
# expected.csv is AMD-GCN3+x86 and is NOT reused here.  The `fence' column on the
# (B) grid is additionally advisory under herd (see the GPU-only generate.sh
# header); litmus7 (Tier-2 emission) routes every test regardless.

set -e
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)
BIN="$REPO/_build/install/default/bin"
COMMON="-set-libdir $REPO/herd/libdir -bell $REPO/hetlitmus/bells/ptx.bell"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

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
  > /tmp/MP-het.regen.$$.litmus
if diff -w -q /tmp/MP-het.regen.$$.litmus MP-het.litmus >/dev/null; then
  echo "MP-het: generator reproduces hand-written MP-het.litmus (modulo whitespace)"
else
  echo "MP-het: WARNING generated output differs from MP-het.litmus" >&2
  diff -w /tmp/MP-het.regen.$$.litmus MP-het.litmus || true
fi
rm -f /tmp/MP-het.regen.$$.litmus

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
          # Content-based dedup: drop a non-relaxed variant whose program is
          # byte-identical to its relaxed sibling (the device cut put the
          # changed annotation on a CPU proc, or on a GPU proc with no matching
          # access).  Compare from line 3 (skip `Het <name>' + comment).
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
# (D) The TWO-SIDED family: complete the morally-strong cross-device pair.
# ---------------------------------------------------------------------------
# The grid above (B) annotates ONLY the GPU procs; every CPU proc is a plain
# ARMv9 ld/st, so a GPU sys release/acquire/fence on one proc can never CLOSE the
# morally-strong pair the CMCM needs to cut a cycle -- the other ordering-critical
# proc contributes nothing.  Those one-sided tests are PRESERVED above (they stay
# Allowed: the plain-CPU baseline).  Here we ADD two-sided variants that annotate
# BOTH halves: the CPU cycle is rendered with ARM atoms (render_cpu_cycle -> STLR
# release / LDAPR RCpc acquire / DMB.SY fence; scope-free, ARM ops are implicitly
# system-scope -- Bagchi 3.2) and the GPU cycle with the matching sys annotation,
# so a complete pair can form and the targeted outcome can be Disallowed.
#
# Restricted to SYS scope and to the COMPLETE pairings {acqrel, fence}:
#   - cta/gpu GPU scope can never encompass the CPU thread regardless of how the
#     CPU is annotated (Bagchi r3-5,21-22; PTX 3.3), so a two-sided cta/gpu test
#     adds no new verdict -- skipped.
#   - acquire/release ALONE annotate only one role (reads xor writes), so they
#     never complete a pair; only `acqrel' (release on writes + acquire on reads)
#     and `fence' (DMB.SY + fence.sc.sys) are complete pairings.
# Naming: <shape>-<cuttag>-sys-<order>-2s.litmus  (`-2s' = two-sided).  The GH200
# target is AArch64+PTX, so two-sided is generated for aarch64 only (the x86 CPU
# is the AMD/x86 model, a different oracle); see expected-nvidia.csv for verdicts.
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
      # Drop a two-sided test that does NOT actually differ from its one-sided
      # sibling: when every CPU proc of the cut is a single-access proc the
      # annotation has nothing to attach to (e.g. IRIW-gcgc fence -- both CPU
      # procs are single writers), so the body equals the one-sided
      # <shape>-<tag>-sys-<order> and it is not genuinely two-sided.
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
# (E) The two-sided ORDER-PAIR grid: the OFF-DIAGONAL of (D).  [Q10 steps 1-3]
# ---------------------------------------------------------------------------
# (D) applies the SAME order name to both devices, so only the two diagonal
# cells were generated.  The per-side ordering a primitive supplies depends on
# which program-order pair its proc has -- so sweep
#   cpu in {ra, sy, st, ld} x gpu in {ra, sc, rel, acq}
# named <shape>-<cuttag>-sys-<cpu>.<gpu>-2s.  See ../_grid_lib.sh for the token
# table, how Q10b unblocked the DMB.ST/DMB.LD axis, and why only 2-proc shapes
# (minus 2+2W) and one cut for SB/LB.  Verdicts are COMPOSITIONAL and machine-checked:
# build-nvidia-oracle.sh + verify/ordercheck.py (make hetlitmus-order).
pair_count=0 diag_count=0
for shape in $TWO_SIDED_PAIR_SHAPES; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_2S_PAIR_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for c in $TWO_SIDED_CPU_ORDERS; do
      for g in $TWO_SIDED_GPU_ORDERS; do
        cpu_toks=$(render_2s_cpu "$c" $cyc)
        gpu_toks=$(render_2s_gpu "$g" $cyc)
        # The two DIAGONAL cells already exist under their (D) names.  PROVE
        # that -- regenerate under the (D) name and byte-diff the committed
        # file -- instead of assuming it, then skip (emitting them would be an
        # exact duplicate, which verify/dupcheck.py would reject anyway).
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
echo "Done. $(wc -l < @all) tests in $(pwd) (grid: $grid_count generated, $skip_count degenerate skipped; two-sided: $twosided_count; order-pair: $pair_count generated, $diag_count diagonal cells verified == their (D) sibling and skipped); manifest @all written."
