#!/usr/bin/env bash
# Render the het corpus with an x86-64 CPU column, into OUTDIR.  Never writes
# into the repo: the x86 renderings are NOT part of the committed corpus.
#
#   usage:  ./generate-x86.sh OUTDIR
#
# Why they are not committed (measured 2026-08-02, P2a): the oracle
# expected-amd.csv is keyed on the AArch64 test NAMES -- one row per shape x
# cut x scope x order, whatever ISA the CPU column is rendered in -- and
# corpus-gate.sh pins tests/het at exactly 411 files while dupcheck.py rejects
# byte-identical duplicates.  90 of the x86 renderings ARE byte-identical to a
# sibling (x86-TSO collapses the four CPU order tokens onto two images, see
# below), so committing them would break both gates for no oracle gain.  They
# are generated on demand instead -- by this script, which is what makes the
# x86 lane reproducible.
#
# The CPU rendering is memo PORT2-R2-amd-oracle.md section 3.1's TSO collapse
# table, verbatim:
#     ra -> plain MOV (no instruction added)   st -> plain MOV (fence dropped)
#     ld -> plain MOV (fence dropped)          sy -> MOV + MFENCE
# so the four two-sided CPU order tokens collapse onto TWO x86 images
# {plain, mfence}.  (E)'s off-diagonal sweep therefore emits many programs that
# differ only in their GPU column, which is exactly the point of the sweep.
#
# Sections mirror generate.sh: (A) the two reference tests, (B) the one-sided
# grid, (D) the matched two-sided family, (E) the two-sided order-pair grid.
# generate.sh emits (D) and (E) for aarch64 only, so this script carries its
# own (D)/(E) loops; (B) it drives through generate.sh's own CPU_ARCHS knob.
set -e
cd "$(dirname "$0")"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

OUT="${1:?usage: generate-x86.sh OUTDIR}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[ "$OUT" != "$(pwd)" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }

# render_x86_cpu <cpu-tok> <base-edge>...  -> x86-64 diy edge token list.
#   plain image  : the bare base cycle (an x86 MOV is already rel/acq under TSO)
#   mfence image : each intra-proc Pod<XY> becomes MFenced<XY>
render_x86_cpu() {
  local t="$1"; shift
  case "$t" in
    ra|st|ld) echo "$*";;
    sy) local out="" e
        for e in "$@"; do
          edge_src_dst "$e"
          if [ "$IS_PO" = 1 ]; then out="$out MFenced${e#Pod}"; else out="$out $e"; fi
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
d=0
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
echo "generate-x86: (A) $a + (B) $b (skipped $bskip degenerate) + (D) $d + (E) $e = $n files in $OUT"
[ "$n" -eq $((a+b+d+e)) ] || { echo "FAIL: $n files on disk but $((a+b+d+e)) counted" >&2; exit 1; }
