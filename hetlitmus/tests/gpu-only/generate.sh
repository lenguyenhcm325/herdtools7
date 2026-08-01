#!/bin/bash
# Generate the GPU-only HetLitmus litmus corpus as scoped LISA tests.
#
# Two parts:
#  (A) The 8 PLDI'23-anchored tests (MP/LB/SB/IRIW, the relaxed + "-F"
#      release/acquire variants, plus MP-cta-F).  These keep their original
#      names because they are the oracle-anchored set verified 8/8 against
#      expected-amd-gcn3.csv by ../../cats/run-gpu-only.sh.  Generated verbatim.
#  (B) The systematic grid: every standard shape
#         MP SB LB 2+2W R S WRC RWC ISA2 IRIW WRC3
#      swept over  scope in {cta,gpu,sys}  x  order in {relaxed,acquire,release,
#      fence}, named <shape>-<scope>-<order>.litmus.
#
# Each test is a closed critical cycle of annotated edges; diy7 attaches one
# memory-order tag and one scope tag per access (vocabulary in
# hetlitmus/bells/ptx.bell).  Edge token = <base-edge><atom(src)><atom(dst)>,
# atom rendered <Order><Scope> (gen/common/edge.ml pp_edge_compat).  The grid
# annotation rule + the fence column are defined in ../_grid_lib.sh.
#
# ORACLE STATUS: only the 8 part-(A) tests have a reference verdict
# (expected-amd-gcn3.csv, AMD GCN3 + x86).  Every part-(B) grid test is
# NO-ORACLE in the oracle-compare sense.  In particular the `fence' column is
# ADVISORY: amd-gcn3.cat deliberately does not model fences (its header explains
# the HRF fence model computes AMD SB/IRIW wrong), so herd7 leaves the fence
# event unconstrained and the accesses read like relaxed -- herd still prints an
# Observation, but it must not be read as a fence verdict.
# See hetlitmus/docs/{gpu-only-corpus,corpus-grid}.md.

set -e
cd "$(dirname "$0")"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell -arch LISA"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

# ---------------------------------------------------------------------------
# (A) PLDI'23-anchored tests (oracle set) -- generated verbatim, names fixed.
# ---------------------------------------------------------------------------
TREE2="(sys (gpu (cta P0) (cta P1)))"
TREE4="(sys (gpu (cta P0) (cta P1) (cta P2) (cta P3)))"

gen () { # name  scopes-tree  edges...
  local name="$1" tree="$2"; shift 2
  "$BIN/diyone7" $COMMON -name "$name" -scopes "$tree" "$@"
  echo "  generated $name.litmus  [scopes: $tree]"
}

# MP: P0:{Wx,Wy} | P1:{Ry,Rx}  cycle PodWW Rfe PodRR Fre
gen MP-sys "$TREE2" \
  PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
gen MP-sys-F "$TREE2" \
  PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys
gen MP-cta-F "$TREE2" \
  PodWWRelaxedCtaReleaseCta RfeReleaseCtaAcquireCta PodRRAcquireCtaRelaxedCta FreRelaxedCtaRelaxedCta
# LB: P0:{Rx,Wy} | P1:{Ry,Wx}  cycle PodRW Rfe PodRW Rfe
gen LB-sys "$TREE2" \
  PodRWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys
# SB: P0:{Wx,Ry} | P1:{Wy,Rx}  cycle PodWR Fre PodWR Fre
gen SB-sys "$TREE2" \
  PodWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys PodWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
gen SB-sys-F "$TREE2" \
  PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys
# IRIW: 2 writers + 2 readers  cycle Rfe PodRR Fre Rfe PodRR Fre
gen IRIW-sys "$TREE4" \
  RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys \
  RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
gen IRIW-sys-F "$TREE4" \
  RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys \
  RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys

# ---------------------------------------------------------------------------
# (B) Systematic shape x scope x order grid.
# ---------------------------------------------------------------------------
grid_count=0 skip_count=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  n="${SHAPE_NPROCS[$shape]}"
  tree=$(scope_tree "$n")
  for scope in $GRID_SCOPES; do
    relaxed_ref=$(render_cycle "$scope" relaxed $cyc)
    for order in $GRID_ORDERS; do
      toks=$(render_cycle "$scope" "$order" $cyc)
      # Skip a column that is byte-identical to relaxed (e.g. `acquire' on an
      # all-write shape has no read to upgrade): redundant, not a new test.
      if [ "$order" != relaxed ] && [ "$toks" = "$relaxed_ref" ]; then
        echo "  skip $shape-$scope-$order (degenerate: == $shape-$scope-relaxed)"
        skip_count=$((skip_count+1)); continue
      fi
      "$BIN/diyone7" $COMMON -name "$shape-$scope-$order" -scopes "$tree" $toks
      grid_count=$((grid_count+1))
    done
  done
done

# ---------------------------------------------------------------------------
# @all manifest (herd7/litmus7 list-file: one .litmus per line, relative to
# this dir; lib/misc.ml is_list).  Drives the end-state herd7 sweep.
# ---------------------------------------------------------------------------
ls *.litmus | LC_ALL=C sort > @all
echo "Done. $(wc -l < @all) tests in $(pwd) (grid: $grid_count generated, $skip_count degenerate skipped); manifest @all written."
