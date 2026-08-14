#!/usr/bin/env bash
# Render the het corpus with an x86-64 CPU column, into OUTDIR.  Never writes
# into the repo: the x86 renderings are NOT part of the committed corpus.
#
#   usage:  ./generate-x86.sh OUTDIR
#
# Why they are not committed: control-map-amd.csv is keyed on the AArch64 test
# NAMES -- one row per shape x cut x scope x order, whatever ISA the CPU column
# is rendered in -- and corpus-gate.sh pins the tests/het census while
# dupcheck.py rejects byte-identical duplicates.  Many x86 renderings are
# byte-identical to a sibling (x86-TSO collapses the four CPU order tokens onto
# two images, see below), so committing them would break both gates for nothing.
# They are generated on demand instead -- by this script, which is what makes
# the x86 lane reproducible (hetlitmus/docs/het-emission.md, "Scope / limits").
#
# The CPU rendering is the TSO collapse implemented by render_x86_cpu below:
#     ra -> plain MOV (no instruction added)   st -> plain MOV (fence dropped)
#     ld -> plain MOV (fence dropped)          sy -> MOV + MFENCE
# so the four two-sided CPU order tokens collapse onto two x86 images
# {plain, mfence}.  (E)'s off-diagonal sweep therefore emits many programs that
# differ only in their GPU column, which is exactly the point of the sweep.
#
# Sections mirror generate.sh: (A) the two reference tests, (B) the one-sided
# grid, (D) the matched two-sided family, (E) the two-sided order-pair grid.
# Every loop lives here rather than being driven through generate.sh, whose (D)
# and (E) are aarch64-only, and only this script re-keys the control map onto
# the suffixed names (below).
set -e
# OUTDIR is resolved against the caller's cwd BEFORE the `cd' below moves us, so
# a relative path -- what a Makefile caller passes -- is correct.  The same rule
# generate.sh and generate-d10.sh state at this spot.
OUT="${1:?usage: generate-x86.sh OUTDIR}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cd "$(dirname "$0")"
# Captured AFTER the cd, so it is absolute and independent of how we were
# invoked -- `dirname "$0"' is relative to the ORIGINAL cwd and is already stale
# by this line.
HETDIR="$(pwd)"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh

[ "$OUT" != "$HETDIR" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }

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
# Same loop as generate.sh section (D), including the degenerate two-sided drop
# that section makes: a cut whose CPU procs are all single writers (IRIW-gcgc)
# gives the two-sided annotation nothing to attach to, so its rendering comes
# out byte-identical below the 2-line header to the one-sided sibling and is
# dropped.  Both lanes drop the same names, which is what keeps the x86
# renderings 1:1 with the committed corpus and lets the control map stay keyed
# on the unsuffixed names.
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

# --- the AMD lane's control map, re-keyed onto the x86 file names -------------
# The emitter resolves the control map relative to the .litmus it is given
# (hetEmit.ml: HetControlMap.load ~dir:src_dir), so without a map beside them
# every x86 rendering names no mu(T) and no canary, co-runs nothing, and every
# null it produces is cold-invalid.
#
# Re-keyed rather than copied: the committed map is keyed on the AArch64 test
# names -- one row per shape x cut x scope x order, whatever ISA the CPU column
# is rendered in -- while these renderings are named `<test>-x86_64'.  The
# rewrite is mechanical and total, so mu(T) and the canary still resolve to a
# .litmus that exists in $OUT.
#
# The file name is kept (control-map-amd.csv) rather than flattened to
# control-map.csv: hetCpuFront.X86_64 asks for that name, so a directory
# carrying the NVIDIA map cannot be mistaken for an AMD lane, and the harness
# records which of the two it was tagged from.
#
# `-' (no alternative), `self' (the test is the canary) and `none' (the row is
# at the lattice floor) are sentinels, not names, and must NOT be suffixed:
# suffixed, `none' becomes the test name `none-x86_64' and litmus7 refuses the
# row.  litmus/hetControlMap.ml knows the same sentinels.
rekey_names() {                 # rekey_names FILE COL... -- suffix those columns
  local f="$1"; shift
  awk -F, -v cols="$*" -v sfx="-x86_64" 'BEGIN{ n=split(cols,C," ") }
    /^#/ || NF==0 { print; next }
    { if ($1 == "Test" || $1 == "Litmus") { print; next }
      for (i = 1; i <= n; i++) { c = C[i]
        if (c <= NF && $c != "-" && $c != "self" && $c != "none" && $c != "")
          $c = $c sfx }
      out = $1; for (i = 2; i <= NF; i++) out = out "," $i; print out }' "$f"
}
# control-map-amd.csv: Test,Mu,MuRule,MuAlt,MuRelaxed,Canary
#   name-valued columns are 1 (Test), 2 (Mu), 4 (MuAlt), 5 (MuRelaxed), 6 (Canary)
rekey_names "$HETDIR/control-map-amd.csv" 1 2 4 5 6 > "$OUT/control-map-amd.csv"

# The map must cover the corpus EXACTLY, in both directions.  A map row with no
# test is a stale name; a test with no map row is refused by the emitter, so the
# whole lane would stop rather than emit a harness co-running nothing.
m=control-map-amd.csv
awk -F, '!/^#/ && NF>1 && $1 != "Test" { print $1 }' \
  "$OUT/$m" | sort > "$OUT/.keys.$m"
ls "$OUT"/*.litmus | sed 's|.*/||; s|\.litmus$||' | sort > "$OUT/.keys.tests"
if ! diff -q "$OUT/.keys.$m" "$OUT/.keys.tests" >/dev/null; then
  echo "FAIL: $m does not key the x86 corpus exactly:" >&2
  diff "$OUT/.keys.tests" "$OUT/.keys.$m" | head -20 >&2
  exit 1
fi
rm -f "$OUT/.keys.$m" "$OUT/.keys.tests"
echo "generate-x86: re-keyed control-map-amd.csv onto all $n tests"
