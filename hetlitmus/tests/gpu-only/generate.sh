#!/bin/bash
# Generate the GPU-only HetLitmus corpus as scoped LISA tests: (A) the tests
# anchored on the [Goens23] artifact, which keep the artifact's own names, and
# (B) the systematic shape x scope x order grid.  Provenance, the grid rule and
# the vendor scope: hetlitmus/docs/{gpu-only-corpus,corpus-grid}.md.
#
#   usage:  ./generate.sh             # this directory + the @all manifest
#           ./generate.sh OUTDIR      # the same corpus, into OUTDIR instead
#
# Edge token = <base-edge><atom(src)><atom(dst)>, the atom rendered <Order><Scope>
# (gen/common/edge.ml pp_edge_compat); the vocabulary is hetlitmus/bells/gpu.bell.

set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path works.
OUT="${1:-}"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; fi

cd "$(dirname "$0")"
: "${OUT:=$(pwd)}"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/gpu.bell -arch LISA -oneloc"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

# diyone7 writes each test into the cwd, so the corpus lands wherever OUTDIR
# points.
cd "$OUT"

# ---------------------------------------------------------------------------
# (A) Artifact-anchored tests -- generated verbatim, names fixed.
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
# this dir; lib/misc.ml is_list).
# ---------------------------------------------------------------------------
ls *.litmus | LC_ALL=C sort > @all
echo "Done. $(wc -l < @all) tests in $(pwd) (grid: $grid_count generated, $skip_count degenerate skipped); manifest @all written."
