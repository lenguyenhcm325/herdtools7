#!/usr/bin/env bash
# The Layer-2 golden gate: corpus + emission regression.
#
# The no-regression guarantee for the generator/emitter black box -- pin what
# the tools produce today and shout on any drift.  It needs no nvcc/clang and no
# GPU: a pure regenerate + emit + text-diff over the committed corpus.  Layer
# map and the promote model: hetlitmus/docs/TEST-PLAN.md sections 2 ("Coverage
# map"), 4 ("Layer 2 - Generate") and 7 ("Golden & promote model").
#
# What it does (return 0 only if corpus, census and emission are ALL clean):
#   1. Corpus regression -- regenerate both corpora into a temp tree and compare
#      the result against the committed one by name set and by bytes, so an
#      added, removed or modified test is named.  An in-place regen followed by
#      a `git status --porcelain' assertion cannot do this: an empty porcelain
#      is also what a generator that wrote nothing leaves behind, and a
#      hand-edited .litmus is clobbered by the regen before it is looked at.
#      --bite is that claim's evidence.
#   2. Census tripwire -- the .litmus counts against EXPECT_GPU / EXPECT_HET
#      below, so a grid that silently shrank or grew is named here.
#   3. Emission golden -- emit the gpu-only corpus once per GPU target into a
#      temp dir and byte-diff the committed samples of both dialects against
#      their own lane, .cu against the `-gpu-target cuda' lane and .hip against
#      the `-gpu-target hip' lane.  One emission renders one vendor
#      (litmus/hetDialect.ml), so the .hip lane is a second pass rather than an
#      option.  Emitting to a temp dir keeps the golden dirs pristine: a lane
#      drops every kernel of the corpus plus its C-runtime boilerplate, which
#      in-place would leave as untracked files.
#
# Non-destructive: nothing here writes inside the repo.  Both the regeneration
# and the emission go to a temp dir (auto-cleaned), so the working tree is
# untouched whether the gate passes or fails.
#
# Promote (when a change to the tools is intended): review `git diff`, then
#   - corpus:   regenerate + `git commit` the new .litmus (TEST-PLAN.md sect 7).
#   - emission: re-emit the samples into cuda-out/ + hip-out/ + `git commit`.
#
# Usage:  hetlitmus/verify/corpus-gate.sh [--bite]
# Exit:   0 = PASS, 1 = drift (offending paths/diffs printed), 2 = infra error.

set -uo pipefail   # NOT -e: we run every check and aggregate, not fail-fast.

# --- locate repo (hetlitmus/verify/ -> hetlitmus/ -> repo root) --------------
. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
cd "$REPO"

export PATH="$BIN:$PATH"          # generate.sh resolves tools via $REPO/_build,
                                  # but keep PATH set for any bare-name callers.

GPU_DIR="hetlitmus/tests/gpu-only"
HET_DIR="hetlitmus/tests/het"
CUDA_OUT="hetlitmus/cuda-out"
HIP_OUT="hetlitmus/hip-out"
EXPECT_GPU=137
EXPECT_HET=411

fail=0

MODE=check
case "${1:-}" in
  "")     ;;
  --bite) MODE=bite ;;
  *)      echo "usage: corpus-gate.sh [--bite]" >&2; exit 2 ;;
esac

# HET_GENERATE_SH is --bite's own seam and the bite sets it per arm; inherited
# from the environment it would let a caller decide what [1/3] compares against.
if [ -n "${HET_GENERATE_SH:-}" ]; then
  echo "FATAL: HET_GENERATE_SH is set in the environment -- it is --bite's seam," >&2
  echo "       and a run through someone else's generator checks nothing." >&2
  exit 2
fi

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
# HET_GENERATE_SH is --bite's seam and receives the same two arguments.
corpus_regen() {
  if [ -n "${HET_GENERATE_SH:-}" ]; then
    bash "$HET_GENERATE_SH" "$1" "$2"
  else
    bash "$1/generate.sh" "$2"
  fi
}

# What one generator run produces: its tests plus the @all manifest.  Anything
# else a corpus directory holds (the generators themselves, the control maps) is
# not generated and is not this check's business.
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

# --- the negative control ---------------------------------------------------
# A regression check nobody has seen fail is a claim.  Each arm swaps the
# generator through HET_GENERATE_SH and reruns the SAME comparison, and each has
# to name the file it broke and be shown non-vacuous against the workroot it left
# behind, so a red arm is the injection speaking and not a broken box.  The clean
# control is [1/3] itself, which `make hetlitmus-corpus' runs immediately before
# this and on the same tree; re-running it here would buy a second copy of it.
bite() {
  local tmp="$EMITTMP/bite" fails=0 victim rc n hit
  mkdir -p "$tmp"

  # The stubs, written here so a reader sees what each arm replaced.
  cat >"$tmp/noop.sh" <<'EOF'
#!/usr/bin/env bash
# Arm 1's generator: it writes nothing.  Why that is the interesting failure is
# in this file's header, item 1.
exit 0
EOF
  cat >"$tmp/tamper.sh" <<'EOF'
#!/usr/bin/env bash
# The shipped generator, then one emitted test given a trailing byte.
set -e
bash "$1/generate.sh" "$2"
[ "$1" != "$HET_BITE_DIR" ] || printf '(* bite *)\n' >>"$2/$HET_BITE_VICTIM"
EOF

  # The victim is the het corpus's first test by name, so both stubs and both
  # expectations below name one file that certainly exists.
  victim="$(list_products "$HET_DIR" | grep '\.litmus$' | head -1)"
  export HET_BITE_DIR="$HET_DIR" HET_BITE_VICTIM="$victim"

  echo "===== --bite: [1/3]'s OWN negative control ====="
  echo "  victim: $HET_DIR/$victim"

  arm() {                     # arm TAG WHY SEAM WANT_RC WANT_STR
    local tag="$1" why="$2" seam="$3" want_rc="$4" want="$5"
    local root="$tmp/$tag" log="$tmp/$tag.log"
    mkdir -p "$root"
    HET_GENERATE_SH="$seam"
    corpus_check "$root" >"$log" 2>&1
    rc=$?
    HET_GENERATE_SH=""
    n="$(grep -c '^  DRIFT: ' "$log")"
    echo "  [$tag] $why"
    echo "        -> rc $rc (expect $want_rc), $n drift line(s)"
    if [ "$rc" != "$want_rc" ]; then
      echo "        *** WRONG RESULT"
      head -10 "$log" | sed 's/^/        /'
      fails=$((fails + 1))
      return
    fi
    [ -n "$want" ] || return
    hit="$(grep -m1 -F -- "$want" "$log")"
    if [ -n "$hit" ]; then
      echo "        named drift FOUND:$hit"
    else
      echo "        *** named drift MISSING (wanted: $want)"
      fails=$((fails + 1))
    fi
  }

  arm 1 "a generator that writes nothing at all" \
      "$tmp/noop.sh" 1 "$HET_DIR/$victim is committed but the generator did not produce it"
  # Non-vacuity: the stub really produced no corpus, so arm 1's red is the
  # comparison talking and not a generator that quietly ran anyway.
  if [ -n "$(list_products "$tmp/1/het")" ]; then
    echo "        *** VACUOUS: the no-op generator still wrote products"
    fails=$((fails + 1))
  fi

  arm 2 "the shipped generator, then one emitted .litmus given a trailing byte" \
      "$tmp/tamper.sh" 1 "$HET_DIR/$victim differs from its regeneration"
  # Non-vacuity: the byte really landed, so arm 2's red is a byte comparison and
  # not a name-set difference wearing its message.
  if cmp -s "$HET_DIR/$victim" "$tmp/2/het/$victim"; then
    echo "        *** VACUOUS: the tampered rendering equals the committed file"
    fails=$((fails + 1))
  fi

  unset HET_BITE_DIR HET_BITE_VICTIM
  if [ "$fails" -ne 0 ]; then
    echo
    echo "CORPUS BITE FAILED: $fails arm(s) did not behave as the check claims"
    return 1
  fi
  echo
  echo "CORPUS BITE OK: [1/3] reddens, by file name, on both a generator that"
  echo "produces nothing and one byte of drift"
  return 0
}

if [ "$MODE" = bite ]; then
  bite
  exit $?
fi

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
