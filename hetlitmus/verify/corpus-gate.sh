#!/usr/bin/env bash
# The Layer-2 golden gate: corpus + emission regression, needing no nvcc and no
# GPU.  Layer map and promote model: hetlitmus/docs/TEST-PLAN.md ("Coverage
# map", "Layer 2 - Generate", "Golden & promote model").
#
# 0 only if all three checks are clean:
#   1. Corpus -- regenerate both corpora into a temp tree and compare with the
#      committed one by name set and by bytes.  A `git status --porcelain'
#      assertion cannot: an empty porcelain is also what a generator that wrote
#      nothing leaves behind.
#   2. Census -- the .litmus counts against EXPECT_GPU / EXPECT_HET below.
#   3. Emission -- re-emit gpu-only once per GPU target and byte-diff the
#      committed samples; one emission renders one vendor (litmus/hetDialect.ml).
# Nothing writes inside the repo; both stages go to a temp dir.
#
# Usage:  corpus-gate.sh (no arguments).  Exit: 0 = PASS, 1 = drift, 2 = infra.

set -uo pipefail   # NOT -e: we run every check and aggregate, not fail-fast.

if [ "$#" -ne 0 ]; then
  echo "usage: corpus-gate.sh   (no arguments)" >&2
  exit 2
fi

# --- locate repo (hetlitmus/verify/ -> hetlitmus/ -> repo root) --------------
. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
cd "$REPO"

export PATH="$BIN:$PATH"          # generate.sh resolves tools via $REPO/_build,
                                  # but keep PATH set for any bare-name callers.

GPU_DIR="hetlitmus/tests/gpu-only"
HET_DIR="hetlitmus/tests/het"
CUDA_OUT="hetlitmus/cuda-out"
HIP_OUT="hetlitmus/hip-out"
EXPECT_GPU=173
EXPECT_HET=471

fail=0

# --- toolchain guard ---------------------------------------------------------
for b in diyone7 hetgen7 litmus7; do
  if [ ! -e "$BIN/$b" ]; then
    echo "FATAL: $BIN/$b not built -- run 'make all' in $REPO" >&2
    exit 2
  fi
done

# --- scratch (auto-cleaned so the tree stays pristine) -----------------------
EMITTMP="$(mktemp -d "${TMPDIR:-/tmp}/hetlitmus-gate.XXXXXX")"
cleanup() { rm -rf "$EMITTMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. CORPUS REGRESSION  (regenerate out of tree; compare names + bytes)
# ---------------------------------------------------------------------------

# corpus_regen SRCDIR OUTDIR -- run SRCDIR's generator so it writes into OUTDIR.
corpus_regen() {
  bash "$1/generate.sh" "$2"
}

# What one generator run produces: its tests plus the @all manifest.  Anything
# else a corpus directory holds (the generators themselves) is not generated and
# is not this check's business.
list_products() {
  ( cd "$1" && ls -1 ) 2>/dev/null | grep -E '\.litmus$|^@all$' | LC_ALL=C sort
}

# corpus_check WORKROOT -- regenerate both corpora under WORKROOT and compare
# each against its committed directory.  0 = clean, 1 = drift, 2 = infra error.
corpus_check() {
  local root="$1" drift=0 label src out f
  for label in gpu het; do
    case "$label" in
      gpu) src="$GPU_DIR" ;;
      het) src="$HET_DIR" ;;
    esac
    out="$root/$label"
    mkdir -p "$out"
    if ! corpus_regen "$src" "$out" >"$root/$label.gen.log" 2>&1; then
      echo "FATAL: the generator for $src failed:" >&2
      cat "$root/$label.gen.log" >&2
      return 2
    fi
    list_products "$src" >"$root/$label.committed"
    list_products "$out" >"$root/$label.fresh"
    while read -r f; do
      [ -n "$f" ] || continue
      echo "  DRIFT: $src/$f is committed but the generator did not produce it"
      drift=1
    done < <(comm -23 "$root/$label.committed" "$root/$label.fresh")
    while read -r f; do
      [ -n "$f" ] || continue
      echo "  DRIFT: the generator produced $f, which $src does not carry"
      drift=1
    done < <(comm -13 "$root/$label.committed" "$root/$label.fresh")
    while read -r f; do
      [ -n "$f" ] || continue
      cmp -s "$src/$f" "$out/$f" && continue
      echo "  DRIFT: $src/$f differs from its regeneration"
      diff -u "$src/$f" "$out/$f" | head -20 | sed 's/^/        /'
      drift=1
    done < <(comm -12 "$root/$label.committed" "$root/$label.fresh")
    echo "        $src: $(wc -l <"$root/$label.committed" | tr -d ' ') committed / $(wc -l <"$root/$label.fresh" | tr -d ' ') regenerated"
  done
  return $drift
}

echo "HetLitmus Layer-2 golden gate  (repo: $REPO)"
echo "=================================================================="

echo "[1/3] Corpus regression (regenerate out of tree + byte-diff the committed one)"
corpus_check "$EMITTMP/regen"
case "$?" in
  0) echo "  PASS: both corpora regenerate byte-identical to the committed tree" ;;
  1) echo "  FAIL: the regeneration diverged from the committed corpus -- tool"
     echo "        drift, or a hand-edited .litmus.  Review the paths above, then"
     echo "        commit the new corpus if the change was intended."
     fail=1 ;;
  *) exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 2. CENSUS  (the grid did not silently change size)
# ---------------------------------------------------------------------------
echo "[2/3] Census (.litmus counts)"
n_gpu=$(find "$GPU_DIR" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')
n_het=$(find "$HET_DIR" -maxdepth 1 -name '*.litmus' | wc -l | tr -d ' ')
echo "        gpu-only: $n_gpu .litmus (expect $EXPECT_GPU)"
echo "        het:      $n_het .litmus (expect $EXPECT_HET)"
if [ "$n_gpu" = "$EXPECT_GPU" ] && [ "$n_het" = "$EXPECT_HET" ]; then
  echo "  PASS: census $EXPECT_GPU + $EXPECT_HET"
else
  echo "  FAIL: census mismatch (expected $EXPECT_GPU + $EXPECT_HET)"
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
  echo "GATE: PASS  (corpus clean, census $n_gpu+$n_het, emission $match/$total)"
  exit 0
else
  echo "GATE: FAIL  (see the offending paths/diffs above)"
  exit 1
fi
