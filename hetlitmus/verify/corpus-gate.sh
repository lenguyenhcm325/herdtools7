#!/usr/bin/env bash
# The corpus + emission golden gate: no nvcc, no GPU, nothing written inside the
# repo (hetlitmus/docs/README-tests.md).  0 only if:
#   1. Corpus -- gpu-only, het and the tests/het-x86 fixture regenerate into a
#      temp tree with the same name set (the fixture as a SUBSET) and same bytes.
#   2. Census -- the .litmus counts match verify/census.sh's pins.
#   3. Emission -- the committed cuda-out/*.cu and hip-out/*.hip re-emit byte for
#      byte, one lane per dialect.
# A miss means a committed artefact is no longer what the tools produce; `make
# hetlitmus-promote' regenerates every set this gate pins.
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

# The census has two homes, one per language, and a gate reading one of them
# says nothing about the corpus the other language's gates sweep.
want_census="$CENSUS_GPU_ONLY $CENSUS_HET $CENSUS_COVER"
py_census="$(cd "$HETL/verify" &&
  python3 -c 'import census; print(census.GPU_ONLY, census.HET, census.COVER)')"
if [ "$py_census" != "$want_census" ]; then
  echo "FATAL: census.py answers '$py_census', census.sh '$want_census'" >&2
  exit 2
fi

export PATH="$BIN:$PATH"          # generate.sh resolves tools via $REPO/_build,
                                  # but keep PATH set for any bare-name callers.

GPU_DIR="hetlitmus/tests/gpu-only"
HET_DIR="hetlitmus/tests/het"
X86_DIR="hetlitmus/tests/het-x86"
CUDA_OUT="hetlitmus/cuda-out"
HIP_OUT="hetlitmus/hip-out"
EXPECT_GPU="$CENSUS_GPU_ONLY"
EXPECT_HET="$CENSUS_HET"

# The fixture's tests, named rather than globbed so that a file deleted from it
# is a failure and NOT an empty loop; the glob arm below rejects a fifth file.
X86_TESTS=(MP-cg-sys-relaxed-x86_64
           MP-cg-sys-acqrel-2s-x86_64
           S-cg-sys-fence-x86_64
           CoRR-cg-sys-fence-2s-x86_64)

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

# What one generator run produces: its tests plus the @all manifest.  Anything
# else a corpus directory holds is not generated.
list_products() {
  ( cd "$1" && ls -1 ) 2>/dev/null | grep -E '\.litmus$|^@all$' | LC_ALL=C sort
}

# fixture_drift OUTDIR -- the het-x86 label: the fixture carries four of the
# x86_64 rendering's tests, so the name set is compared one way only.
fixture_drift() {
  local out="$1" drift=0 t n=0 f base
  for t in "${X86_TESTS[@]}"; do
    if [ ! -f "$X86_DIR/$t.litmus" ]; then
      echo "  DRIFT: $X86_DIR/$t.litmus is committed nowhere -- the fixture lost it"
      drift=1; continue
    fi
    if [ ! -f "$out/$t.litmus" ]; then
      echo "  DRIFT: the x86_64 rendering no longer carries $t.litmus"
      drift=1; continue
    fi
    n=$((n + 1))
    cmp -s "$X86_DIR/$t.litmus" "$out/$t.litmus" && continue
    echo "  DRIFT: $X86_DIR/$t.litmus differs from its regeneration"
    diff -u "$X86_DIR/$t.litmus" "$out/$t.litmus" | head -20 | sed 's/^/        /'
    drift=1
  done
  for f in "$X86_DIR"/*.litmus; do
    base="$(basename "$f" .litmus)"
    case " ${X86_TESTS[*]} " in *" $base "*) continue ;; esac
    echo "  DRIFT: $f sits in the fixture and no check compares it"
    drift=1
  done
  if [ "$n" -ne "${#X86_TESTS[@]}" ]; then
    echo "  DRIFT: compared $n of ${#X86_TESTS[@]} fixtures -- a comparison that did not happen is not a pass"
    drift=1
  fi
  echo "        $X86_DIR: $n of ${#X86_TESTS[@]} fixture(s) compared against the x86_64 rendering"
  return $drift
}

# corpus_check WORKROOT -- regenerate each corpus under WORKROOT and compare it
# against its committed directory.  0 = clean, 1 = drift, 2 = infra error.
corpus_check() {
  local root="$1" drift=0 label src gen args out f
  for label in gpu het x86; do
    case "$label" in
      gpu) src="$GPU_DIR" ; gen="$GPU_DIR/generate.sh" ; args="" ;;
      het) src="$HET_DIR" ; gen="$HET_DIR/generate.sh" ; args="" ;;
      x86) src="$X86_DIR" ; gen="$HET_DIR/generate.sh" ; args="--cpu-arch x86_64" ;;
    esac
    out="$root/$label"
    mkdir -p "$out"
    if ! bash "$gen" $args "$out" >"$root/$label.gen.log" 2>&1; then
      echo "FATAL: the generator $gen $args failed:" >&2
      cat "$root/$label.gen.log" >&2
      return 2
    fi
    if [ "$label" = x86 ]; then
      fixture_drift "$out" || drift=1
      continue
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

echo "HetLitmus corpus golden gate  (repo: $REPO)"
echo "=================================================================="

echo "[1/3] Corpus regression (regenerate out of tree + byte-diff the committed one)"
corpus_check "$EMITTMP/regen"
case "$?" in
  0) echo "  PASS: both corpora and the het-x86 fixture regenerate byte-identical" ;;
  1) echo "  FAIL: the regeneration diverged from the committed tree -- tool drift,"
     echo "        or a hand-edited .litmus.  Review the paths above, then"
     echo "        'make hetlitmus-promote' if the change was intended."
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
