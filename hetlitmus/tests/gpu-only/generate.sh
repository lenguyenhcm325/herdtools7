#!/bin/bash
# Generate the GPU-only HetLitmus litmus corpus as scoped LISA tests.
#
#   usage:  ./generate.sh             # this directory + the @all manifest
#           ./generate.sh OUTDIR      # the same corpus, into OUTDIR instead
#
# OUTDIR (default: this directory) exists for verify/corpus-gate.sh, which says
# there why it regenerates out of tree.
#
# Two parts:
#  (A) The tests anchored on the [Goens23] artifact (MP/LB/SB/IRIW, the relaxed
#      + "-F" release/acquire variants, plus MP-cta-F).  These keep their
#      original names because that is how the artifact names them.  Generated
#      verbatim.
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
# Reference verdicts: only the part-(A) tests carry an external one, from the
# [Goens23] artifact's own expected.csv (AMD GCN3 + x86).  The part-(B) grid
# reaches past that artifact -- which has no fence and no `sc' operation
# anywhere -- so an offline oracle-compare.sh pass of a grid row against a CSV
# built from it reports UNINTERPRETED rather than a verdict.  Provenance and
# vendor scope: hetlitmus/docs/{gpu-only-corpus,corpus-grid}.md.

set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path works -- the same rule generate-x86.sh states at this spot.
OUT="${1:-}"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; fi

cd "$(dirname "$0")"
: "${OUT:=$(pwd)}"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell -arch LISA"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

# diyone7 writes each test into the cwd, so the corpus lands wherever OUTDIR
# points.
cd "$OUT"

# ---------------------------------------------------------------------------
# (A) Artifact-anchored tests (oracle set) -- generated verbatim, names fixed.
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
