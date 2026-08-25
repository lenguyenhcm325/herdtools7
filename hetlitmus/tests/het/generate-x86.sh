#!/usr/bin/env bash
# Render the het corpus with an x86-64 CPU column, into OUTDIR.  These renderings
# are NOT committed and are generated on demand, which is what makes the x86 lane
# reproducible (hetlitmus/docs/het-emission.md, "Scope / limits").
#
#   usage:  ./generate-x86.sh OUTDIR
#
# Sections mirror generate.sh -- (A) reference tests, (B) the one-sided grid,
# (D) matched two-sided, (E) the order-pair grid -- with every loop here, since
# generate.sh's (D) and (E) are aarch64-only.

set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path -- what a Makefile caller passes -- is correct.
OUT="${1:?usage: generate-x86.sh OUTDIR}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cd "$(dirname "$0")"
# Captured AFTER the cd, so it is absolute: `dirname "$0"' is relative to the
# original cwd and is already stale by this line.
HETDIR="$(pwd)"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell -oneloc"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

[ "$OUT" != "$HETDIR" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }

# render_x86_cpu <cpu-tok> <base-edge>...  -> x86-64 diy edge token list; the
# x86-TSO collapse of the four tokens: corpus-grid.md, "Census rationale".
render_x86_cpu() {
  local t="$1"; shift
  case "$t" in
    ra|st|ld) echo "$*";;
    sy) local out="" e
        for e in "$@"; do
          edge_src_dst "$e"
          if [ "$IS_PO" = 1 ]; then out="$out MFence${PO_LOC}${PO_XY}"; else out="$out $e"; fi
        done
        echo "${out# }";;
    *) echo "render_x86_cpu: bad token $t" >&2; return 1;;
  esac
}

# --- (A) reference tests ------------------------------------------------------
"$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices cpu,gpu -name SB-het-x86_64 \
  -cpu "PodWR Fre PodWR Fre" \
  -gpu "PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys" \
  > "$OUT/SB-het-x86_64.litmus"
"$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices cpu,gpu -name MP-het-x86_64 \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys" \
  > "$OUT/MP-het-x86_64.litmus"
a=2

# --- (B) the one-sided grid ---------------------------------------------------
# Same loop as generate.sh section (B), including its degenerate-variant drop.
b=0 bskip=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_HET_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for scope in $GRID_SCOPES; do
      relaxed_file="$OUT/$shape-$tag-$scope-relaxed-x86_64.litmus"
      for order in $GRID_ORDERS; do
        name="$shape-$tag-$scope-$order-x86_64"
        gpu_toks=$(render_cycle "$scope" "$order" $cyc)
        "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$cut" -name "$name" \
          -cpu "$cyc" -gpu "$gpu_toks" > "$OUT/$name.litmus"
        if [ "$order" != relaxed ] && [ -f "$relaxed_file" ] \
           && diff -q <(tail -n +3 "$relaxed_file") <(tail -n +3 "$OUT/$name.litmus") >/dev/null; then
          rm -f "$OUT/$name.litmus"
          bskip=$((bskip+1)); continue
        fi
        b=$((b+1))
      done
    done
  done
done

# --- (D) matched two-sided ----------------------------------------------------
# Same loop as generate.sh section (D), including its degenerate two-sided drop:
# a cut whose CPU procs are all single writers has nothing for the annotation to
# attach to.  BOTH lanes drop the same names, which is what keeps the x86
# renderings 1:1 with the committed corpus.
d=0 dskip=0
for shape in $SHAPE_ORDER; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_HET_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for order in $TWO_SIDED_ORDERS; do
      name="$shape-$tag-sys-$order-2s-x86_64"
      case "$order" in acqrel) ctok=ra;; fence) ctok=sy;; esac
      cpu_toks=$(render_x86_cpu "$ctok" $cyc)
      gpu_toks=$(render_cycle sys "$order" $cyc)
      "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$cut" -name "$name" \
        -cpu "$cpu_toks" -gpu "$gpu_toks" > "$OUT/$name.litmus"
      onesided="$OUT/$shape-$tag-sys-$order-x86_64.litmus"
      if [ -f "$onesided" ] \
         && diff -q <(tail -n +3 "$onesided") <(tail -n +3 "$OUT/$name.litmus") >/dev/null; then
        rm -f "$OUT/$name.litmus"
        echo "  skip $name (not two-sided: == $shape-$tag-sys-$order-x86_64)"
        dskip=$((dskip+1)); continue
      fi
      d=$((d+1))
    done
  done
done

# --- (E) order-pair grid ------------------------------------------------------
e=0
for shape in $TWO_SIDED_PAIR_SHAPES; do
  cyc="${SHAPE_CYCLE[$shape]}"
  for cut in ${SHAPE_2S_PAIR_CUTS[$shape]}; do
    tag=$(cut_tag "$cut")
    for c in $TWO_SIDED_CPU_ORDERS; do
      for g in $TWO_SIDED_GPU_ORDERS; do
        [ "$c.$g" = "ra.ra" ] && continue    # == -sys-acqrel-2s
        [ "$c.$g" = "sy.sc" ] && continue    # == -sys-fence-2s
        name="$shape-$tag-sys-$c.$g-2s-x86_64"
        cpu_toks=$(render_x86_cpu "$c" $cyc)
        gpu_toks=$(render_2s_gpu "$g" $cyc)
        "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$cut" -name "$name" \
          -cpu "$cpu_toks" -gpu "$gpu_toks" > "$OUT/$name.litmus"
        e=$((e+1))
      done
    done
  done
done

n="$(ls "$OUT"/*.litmus | wc -l)"
echo "generate-x86: (A) $a + (B) $b (skipped $bskip degenerate) + (D) $d (skipped $dskip degenerate) + (E) $e = $n files in $OUT"
[ "$n" -eq $((a+b+d+e)) ] || { echo "FAIL: $n files on disk but $((a+b+d+e)) counted" >&2; exit 1; }
