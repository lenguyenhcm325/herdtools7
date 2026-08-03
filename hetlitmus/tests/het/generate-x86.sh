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
# Captured AFTER the cd, so it is absolute and independent of how we were
# invoked -- `dirname "$0"' is relative to the ORIGINAL cwd and is already stale
# by this line.
HETDIR="$(pwd)"
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
# Same loop as generate.sh section (D), INCLUDING its degenerate two-sided drop
# (generate.sh:127-133).  Without that drop this loop emitted one rendering more
# than the corpus has tests: IRIW-gcgc-sys-fence-2s-x86_64, byte-identical below
# the 2-line header to IRIW-gcgc-sys-fence-x86_64 -- both CPU procs of the
# gcgc cut are single writers, so the two-sided annotation has nothing to attach
# to.  generate.sh drops exactly that one on the aarch64 lattice, which is why
# tests/het has an IRIW-gcgc-sys-fence.litmus and no -2s sibling.  Dropping it
# here too makes the x86 renderings 1:1 with the 411-test corpus (measured:
# `comm' over the two name sets is empty in both directions), which is what
# lets the oracle / control map be keyed on the unsuffixed names.
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

# --- the AMD lane's two maps, RE-KEYED onto the x86 file names (P2d) ----------
# The emitter resolves both of these RELATIVE TO THE .litmus it is given
# (hetEmit.ml: HetControlMap.load / HetOracle.load, both ~dir:src_dir), so
# without them every x86 rendering emits `_rec.het_oracle = ORACLE_UNSET' and
# its harness reports a BUILD BUG instead of a result.  MEASURED before this
# block existed, 2026-08-03: 411 of 411.
#
# RE-KEYED, not copied.  The committed maps are keyed on the AArch64 test NAMES
# -- one row per shape x cut x scope x order, whatever ISA the CPU column is
# rendered in (that is what makes the oracle ISA-independent, see the header of
# this file) -- while these renderings are named `<test>-x86_64'.  The rewrite
# is mechanical and total: every NAME-valued field gets the suffix, so mu(T) and
# the canary still resolve to a .litmus that exists in $OUT.  `-' and `self' are
# sentinels, not names, and must NOT be suffixed.
#
# The file NAMES are kept (control-map-amd.csv / expected-amd.csv), not
# flattened to control-map.csv: hetCpuFront.X86_64 asks for those names, so a
# directory carrying the NVIDIA maps under their own names cannot be mistaken
# for an AMD lane, and hetOracle.load's Model guard refuses the swap outright.
#
# `-`, `self` and `none` are SENTINELS, not names, and must NOT be suffixed.
# MEASURED 2026-08-03: control-map-amd.csv carries `none' in 16 rows of column 3
# and in the same 16 rows of column 7 -- all of them Disallowed.  It means "no
# Layer-A mutant EXISTS for this row" (memo 7.D11; the MuRule column says which
# of the two admitted reasons applies), a case the AArch64 lattice never needs
# and control-map.csv therefore never spells.  Suffixed, it became the test name
# `none-x86_64' and litmus7 refused all 16:
#   HetLitmus REFUSED ... names the control none-x86_64, but
#   ./none-x86_64.litmus does not exist
# Fail-closed thanks to P2b, but 16 tests short of a corpus, and silently so
# before P2b.  litmus/hetControlMap.ml knows the same three sentinels.
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
# control-map-amd.csv: Test,Expected,Mu,MuExpected,MuRule,MuAlt,MuRelaxed,Canary
#   name-valued columns are 1 (Test), 3 (Mu), 6 (MuAlt), 7 (MuRelaxed), 8 (Canary)
rekey_names "$HETDIR/control-map-amd.csv" 1 3 6 7 8 > "$OUT/control-map-amd.csv"
# expected-amd.csv: Litmus,Expected,Model,Provenance,Source -- only column 1 is a name.
rekey_names "$HETDIR/expected-amd.csv" 1 > "$OUT/expected-amd.csv"

# Both maps must cover the corpus EXACTLY, in both directions.  A map row with
# no test is a stale name; a test with no map row emits ORACLE_UNSET, which is
# the failure this block exists to prevent -- and which is silent in the
# emitted C, so it has to be caught here.
for m in control-map-amd.csv expected-amd.csv; do
  awk -F, '!/^#/ && NF>1 && $1 != "Test" && $1 != "Litmus" { print $1 }' \
    "$OUT/$m" | sort > "$OUT/.keys.$m"
  ls "$OUT"/*.litmus | sed 's|.*/||; s|\.litmus$||' | sort > "$OUT/.keys.tests"
  if ! diff -q "$OUT/.keys.$m" "$OUT/.keys.tests" >/dev/null; then
    echo "FAIL: $m does not key the x86 corpus exactly:" >&2
    diff "$OUT/.keys.tests" "$OUT/.keys.$m" | head -20 >&2
    exit 1
  fi
  rm -f "$OUT/.keys.$m"
done
rm -f "$OUT/.keys.tests"
echo "generate-x86: re-keyed control-map-amd.csv + expected-amd.csv onto all $n tests"
