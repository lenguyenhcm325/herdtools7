#!/usr/bin/env bash
# The corpus + emission golden gate: no nvcc, no GPU, nothing written inside the
# repo (hetlitmus/docs/README-tests.md).  0 only if:
#   1. Corpus -- grid.py, run afresh into a temp tree, reproduces each built
#      tree (het, het-x86_64, gpu-only) file for file and byte for byte.
#   2. Census -- the .litmus counts of the built trees match verify/census.sh's
#      pins.
#   3. Emission -- the committed cuda-out/*.cu and hip-out/*.hip re-emit byte for
#      byte from the built gpu-only tree, one lane per dialect.
# A miss means a built tree is not what the generator produces now, or a
# committed sample is no longer what the emitter produces; `make
# hetlitmus-corpus-gen' rebuilds the trees, `make hetlitmus-promote' the samples.
#
# Usage:  corpus-gate.sh (no arguments).  Exit: 0 = PASS, 1 = drift, 2 = infra.

set -uo pipefail   # NOT -e: we run every check and aggregate, not fail-fast.

if [ "$#" -ne 0 ]; then
  echo "usage: corpus-gate.sh   (no arguments)" >&2
  exit 2
fi

# --- locate repo (hetlitmus/verify/ -> hetlitmus/ -> repo root) --------------
. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
. "$HETL/verify/census.sh"
cd "$REPO"

# Census and tree paths have two homes, one per language; a gate reading one
# says nothing about the corpus the other language's gates sweep.
want_homes="$CENSUS_GPU_ONLY $CENSUS_HET $CENSUS_HET_X86 $CENSUS_COVER $GPU_CORPUS $HET_CORPUS $X86_CORPUS"
py_homes="$(cd "$HETL/verify" &&
  python3 -c 'import census; print(census.GPU_ONLY, census.HET, census.HET_X86, census.COVER, census.GPU_DIR, census.HET_DIR, census.X86_DIR)')"
if [ "$py_homes" != "$want_homes" ]; then
  echo "FATAL: census.py answers '$py_homes', census.sh + paths.sh '$want_homes'" >&2
  exit 2
fi

GRID="$HETL/tests/grid.py"
BELL="$HETL/bells/gpu.bell"
CUDA_OUT="hetlitmus/cuda-out"
HIP_OUT="hetlitmus/hip-out"

fail=0

# --- toolchain guard ---------------------------------------------------------
for b in diyone7 hetgen7 litmus7; do
  if [ ! -e "$BIN/$b" ]; then
    echo "FATAL: $BIN/$b not built -- run 'make all' in $REPO" >&2
    exit 2
  fi
done
for d in "$HET_CORPUS" "$X86_CORPUS" "$GPU_CORPUS"; do
  if [ ! -d "$d" ]; then
    echo "FATAL: $d not built -- run 'make hetlitmus-corpus-gen' in $REPO" >&2
    exit 2
  fi
done

# --- scratch (auto-cleaned so the tree stays pristine) -----------------------
EMITTMP="$(mktemp -d "${TMPDIR:-/tmp}/hetlitmus-gate.XXXXXX")"
cleanup() { rm -rf "$EMITTMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. CORPUS REGRESSION  (run the generator afresh; diff -r against the built
#    tree, both ways: a file only one side holds is drift too)
# ---------------------------------------------------------------------------

# regen_check WORKROOT -- 0 = every tree reproduced, 1 = drift, 2 = infra.
regen_check() {
  local root="$1" drift=0 label built args out n
  for label in het het-x86_64 gpu-only; do
    case "$label" in
      het)        built="$HET_CORPUS"
                  args="--corpus het --cpu-arch aarch64 --hetgen7 $BIN/hetgen7" ;;
      het-x86_64) built="$X86_CORPUS"
                  args="--corpus het --cpu-arch x86_64 --hetgen7 $BIN/hetgen7" ;;
      gpu-only)   built="$GPU_CORPUS"
                  args="--corpus gpu-only --diyone7 $BIN/diyone7" ;;
    esac
    out="$root/$label"
    mkdir -p "$out"
    if ! python3 "$GRID" $args --out "$out" --bell "$BELL" --libdir "$HERDLIB" \
         >"$root/$label.gen.log" 2>&1; then
      echo "FATAL: grid.py $args failed:" >&2
      cat "$root/$label.gen.log" >&2
      return 2
    fi
    n="$(find "$out" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
      echo "FATAL: grid.py $args wrote no .litmus into $out" >&2
      return 2
    fi
    echo "        $(tail -n 1 "$root/$label.gen.log")"
    if diff -r "$built" "$out" >"$root/$label.diff" 2>&1; then
      echo "        $built: $n .litmus + @all, byte-identical to the fresh run"
    else
      echo "  DRIFT: $built differs from a fresh grid.py run:"
      head -n 40 "$root/$label.diff" | sed 's/^/        /'
      drift=1
    fi
  done
  return $drift
}

echo "HetLitmus corpus golden gate  (repo: $REPO)"
echo "=================================================================="

echo "[1/3] Corpus regression (grid.py afresh + diff -r against the built trees)"
regen_check "$EMITTMP/regen"
case "$?" in
  0) echo "  PASS: the three built trees are what grid.py produces now" ;;
  1) echo "  FAIL: a built tree diverged from a fresh generation -- a stale tree, or"
     echo "        a generator input dune does not track.  'make hetlitmus-corpus-gen'"
     echo "        rebuilds the trees."
     fail=1 ;;
  *) exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 2. CENSUS  (the grid did not silently change size)
# ---------------------------------------------------------------------------
echo "[2/3] Census (.litmus counts of the built trees)"
n_gpu=$(find "$GPU_CORPUS" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')
n_het=$(find "$HET_CORPUS" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')
n_x86=$(find "$X86_CORPUS" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')
echo "        gpu-only:   $n_gpu .litmus (expect $CENSUS_GPU_ONLY)"
echo "        het:        $n_het .litmus (expect $CENSUS_HET)"
echo "        het-x86_64: $n_x86 .litmus (expect $CENSUS_HET_X86)"
if [ "$n_gpu" = "$CENSUS_GPU_ONLY" ] && [ "$n_het" = "$CENSUS_HET" ] \
   && [ "$n_x86" = "$CENSUS_HET_X86" ]; then
  echo "  PASS: census $CENSUS_GPU_ONLY + $CENSUS_HET + $CENSUS_HET_X86"
else
  echo "  FAIL: census mismatch (expected $CENSUS_GPU_ONLY + $CENSUS_HET + $CENSUS_HET_X86)"
  fail=1
fi

# ---------------------------------------------------------------------------
# 3. EMISSION GOLDEN  (committed cuda-out/*.cu + hip-out/*.hip re-emit
#    byte-identical -- one lane per dialect, since one emission renders one)
# ---------------------------------------------------------------------------
echo "[3/3] Emission golden (committed cuda-out/*.cu + hip-out/*.hip)"
elog="$EMITTMP/emit.log"
if ! bash "$HETL/emit-cuda.sh" "$EMITTMP/cuda" >"$elog" 2>&1; then
  echo "FATAL: emit-cuda.sh failed:" >&2; cat "$elog" >&2; exit 2
fi
if ! bash "$HETL/emit-hip.sh" "$EMITTMP/hip" >"$elog" 2>&1; then
  echo "FATAL: emit-hip.sh failed:" >&2; cat "$elog" >&2; exit 2
fi

# Each committed sample is compared against the lane that renders it: a .cu is
# only produced by the cuda lane, a .hip only by the hip lane.
committed="$(git ls-files "$CUDA_OUT/*.cu" "$HIP_OUT/*.hip")"
total=0; match=0; emit_fail=0
for f in $committed; do
  total=$((total + 1))
  base="$(basename "$f")"
  case "$base" in
    *.cu)  lane="$EMITTMP/cuda" ; who="emit-cuda.sh" ;;
    *.hip) lane="$EMITTMP/hip"  ; who="emit-hip.sh"  ;;
    *)     echo "  DRIFT: committed sample $f has no known lane" ; emit_fail=1 ; continue ;;
  esac
  if [ ! -f "$lane/$base" ]; then
    echo "  DRIFT: $base is committed but $who did not produce it"
    emit_fail=1
    continue
  fi
  if diff -u "$f" "$lane/$base" >"$EMITTMP/diff.out" 2>&1; then
    match=$((match + 1))
  else
    echo "  DRIFT: $f differs from re-emission:"
    sed 's/^/        /' "$EMITTMP/diff.out"
    emit_fail=1
  fi
done
n_cu=$(git ls-files "$CUDA_OUT/*.cu" | wc -l | tr -d ' ')
n_hip=$(git ls-files "$HIP_OUT/*.hip" | wc -l | tr -d ' ')
echo "        $match/$total samples match ($n_cu .cu + $n_hip .hip)"
if [ "$total" -eq 0 ] || [ "$n_cu" -eq 0 ] || [ "$n_hip" -eq 0 ]; then
  # a dialect with zero committed samples would make the loop above vacuous
  echo "  FAIL: a dialect has no committed samples ($n_cu .cu, $n_hip .hip)"
  fail=1
elif [ "$emit_fail" -ne 0 ]; then
  echo "  FAIL: emission drift ($match/$total match)"
  fail=1
else
  echo "  PASS: emission golden ($match/$total match)"
fi

# ---------------------------------------------------------------------------
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
  echo "GATE: PASS  (trees reproduced, census $n_gpu+$n_het+$n_x86, emission $match/$total)"
  exit 0
else
  echo "GATE: FAIL  (see the offending paths/diffs above)"
  exit 1
fi
