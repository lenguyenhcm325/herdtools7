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
#
# ORACLE STATUS: every het test here is NO-ORACLE -- the PLDI'23 expected.csv is
# AMD-GCN3 + x86 only and contains no AArch64+PTX (GH200) heterogeneous verdict.
# These tests are validated by routing through litmus7 (Tier-2 emission), not by
# a herd7 verdict.  The `fence' column is additionally advisory (see the GPU-only
# generate.sh header).

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
# @all manifest (only the committed, default-arch tests if CPU_ARCHS=aarch64).
# ---------------------------------------------------------------------------
ls *.litmus | LC_ALL=C sort > @all
echo "Done. $(wc -l < @all) tests in $(pwd) (grid: $grid_count generated, $skip_count degenerate skipped); manifest @all written."
