#!/usr/bin/env bash
# =========================================================================
# HetLitmus dev-tier SPOT-CHECK BUNDLE -- built on the dev box, shipped whole.
#
#   hetlitmus/spotcheck/pack-bundle.sh [OUTDIR]
#   -> OUTDIR/hetlitmus-spotcheck-<rev>.tar.gz
#
# WHY A BUNDLE AND NOT A CHECKOUT.  An emitted harness dir is SELF-CONTAINED:
# litmus7 writes outs.c/h, het_stress.cuh, het_cpu_stress.h and het_verdict.h
# into every dir at emission time.  So the rented instance needs no repo, no
# OCaml, no dune and no litmus7 -- just nvcc, gcc, make and python3.  That also
# pins the experiment: the bundle carries the git revision it was emitted from,
# and nothing on the instance can drift from it.
#
# WHAT IS IN IT
#   tests/<name>/        the emitted harness dirs named in TESTS.txt
#   control-map.csv      oracle class + mu(T) + canary per test  (campaign.py)
#   expected-nvidia.csv  the GH200 oracle -- carried for provenance, NOT to be
#                        read as the oracle for a non-GH200 box
#   campaign.py          the cross-invocation pooling driver
#   probe.cu probe.sh    what does this machine offer (run FIRST)
#   ladder.sh run-one.sh the seven rungs, and campaign.py's --runner template
#   TESTS.txt README.md  the subset + its rationale, and how to drive it
#   STAMP                revision, date, census, emitter fingerprint
#
# FAIL-LOUD.  Every name in TESTS.txt must resolve to an emitted dir.  A typo
# there would otherwise ship a bundle that is quietly one test short, and the
# instance session would run the ladder against a subset nobody chose.
#
# CUDA BUNDLE.  probe.cu, ladder.sh's `comp.sh cuda && make cuda-bin' and
# expected-nvidia.csv make this the NVIDIA dev-tier bundle, so it ships the
# emission lane to match (GPU_TARGET below); an AMD bundle is that variable plus
# an AMD probe and oracle, not a change here.
# =========================================================================
# Needs bash (arrays, mapfile); re-exec rather than fail obscurely under dash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HETL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HETL/.." && pwd)"

LITMUS7="$REPO/_build/install/default/bin/litmus7"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

OUTDIR="${1:-$HERE/bundle-out}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# The emission lane this bundle ships (litmus7 -gpu-target): one vendor per
# harness dir, and the ladder in here builds the CUDA one.
GPU_TARGET="${GPU_TARGET:-cuda}"
TESTS_FILE="${TESTS_FILE:-$HERE/TESTS.txt}"
[ -r "$TESTS_FILE" ] || { echo "error: no $TESTS_FILE" >&2; exit 2; }

mapfile -t WANT < <(grep -vE '^[[:space:]]*(#|$)' "$TESTS_FILE" | awk '{print $1}')
[ "${#WANT[@]}" -gt 0 ] || { echo "error: $TESTS_FILE names no tests" >&2; exit 2; }
echo "[1/5] subset: ${#WANT[@]} tests -- ${WANT[*]}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "[2/5] emitting the full corpus into scratch (emit-all.sh is the instrument)"
if ! "$HETL/verify/emit-all.sh" "$SCRATCH/emit" > "$SCRATCH/emit.log" 2>&1; then
  echo "FAIL: emit-all.sh did not complete; last 20 lines:" >&2
  tail -20 "$SCRATCH/emit.log" >&2
  exit 1
fi
tail -1 "$SCRATCH/emit.log"

REV="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUNDLE="$SCRATCH/hetlitmus-spotcheck-$REV"
mkdir -p "$BUNDLE/tests"

echo "[3/5] pruning to the subset (a name that does not resolve is fatal)"
missing=()
for t in "${WANT[@]}"; do
  if [ -d "$SCRATCH/emit/het-$GPU_TARGET/$t" ]; then
    cp -r "$SCRATCH/emit/het-$GPU_TARGET/$t" "$BUNDLE/tests/$t"
  else
    missing+=("$t")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $TESTS_FILE names ${#missing[@]} test(s) with no emitted harness dir:" >&2
  for m in "${missing[@]}"; do echo "        $m" >&2; done
  echo "      The corpus emitted $(find "$SCRATCH/emit/het-$GPU_TARGET" -mindepth 1 -maxdepth 1 -type d | wc -l) dirs." >&2
  echo "      Refusing to ship a bundle that is silently short of the chosen subset." >&2
  exit 1
fi

echo "[4/5] adding driver, probe, ladder, oracles, stamp"
cp "$HETL/campaign.py"                 "$BUNDLE/"
cp "$HETL/tests/het/control-map.csv"   "$BUNDLE/"
cp "$HETL/tests/het/expected-nvidia.csv" "$BUNDLE/"
cp "$HERE/probe.cu" "$HERE/probe.sh" "$HERE/ladder.sh" "$HERE/run-one.sh" \
   "$HERE/TESTS.txt" "$HERE/README.md" "$BUNDLE/"
chmod +x "$BUNDLE/probe.sh" "$BUNDLE/ladder.sh" "$BUNDLE/run-one.sh"

{
  echo "bundle=hetlitmus-spotcheck"
  echo "git_rev=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo nogit)"
  echo "git_rev_short=$REV"
  echo "git_branch=$(cd "$REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo nogit)"
  # Dirty = ANY uncommitted change under litmus/ or hetlitmus/, untracked files
  # included: a bundle whose scripts exist only in someone's working tree is not
  # reproducible from git_rev, and the STAMP must not imply that it is.
  echo "git_dirty=$( [ -z "$(cd "$REPO" && git status --porcelain -- litmus hetlitmus 2>/dev/null)" ] && echo no || echo YES )"
  echo "packed_date=$(date -Is 2>/dev/null || date)"
  echo "packed_host=$(uname -sm)"
  echo "corpus_emitted=$(find "$SCRATCH/emit/het-$GPU_TARGET" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "subset_count=${#WANT[@]}"
  for t in "${WANT[@]}"; do
    echo "subset_test=$t class=$(awk -F, -v t="$t" '$1==t{print $2}' "$HETL/tests/het/expected-nvidia.csv" | head -1)"
  done
  echo "emitter_sha256=$(sha256sum "$REPO/litmus/hetEmit.ml" | cut -d' ' -f1)"
  echo "verdict_h_sha256=$(sha256sum "$REPO/litmus/het-runtime/het_verdict.h" | cut -d' ' -f1)"
  echo "# Dev-tier bundle.  Results from it are MACHINERY evidence only and must"
  echo "# never be merged with GH200 evaluation data (see README.md)."
} > "$BUNDLE/STAMP"

echo "[5/5] tarring"
TAR="$OUTDIR/hetlitmus-spotcheck-$REV.tar.gz"
tar -C "$SCRATCH" -czf "$TAR" "hetlitmus-spotcheck-$REV"
echo ""
echo "bundle: $TAR  ($(du -h "$TAR" | cut -f1))"
echo "        ${#WANT[@]} harness dirs, rev $REV"
echo "next:   scp it over, tar xzf, sh probe.sh, then sh ladder.sh"
