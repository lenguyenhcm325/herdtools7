#!/usr/bin/env bash
# Pack the dev-tier spot-check bundle: emit the corpus, prune it to TESTS.txt's
# subset, add the driver, the probe and the ladder, stamp it and tar it.
#
#   hetlitmus/spotcheck/pack-bundle.sh [OUTDIR]
#   -> OUTDIR/hetlitmus-spotcheck-<rev>.tar.gz
#
# It refuses to ship a bundle that is short of the chosen subset, or whose
# widest-launch pick the corpus has outgrown.  A harness dir is self-contained,
# so the instance needs no repo; what travels and why: README.md beside this.
# Needs bash (arrays, mapfile); re-exec rather than fail obscurely under dash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HETL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HETL/.." && pwd)"

LITMUS7="$REPO/_build/install/default/bin/litmus7"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

# The emission lane this bundle ships (litmus7 -gpu-target): the ladder in here
# builds the CUDA one, so any other vendor is refused before anything is made.
GPU_TARGET="${GPU_TARGET:-cuda}"
[ "$GPU_TARGET" = cuda ] || {
  echo "error: GPU_TARGET=$GPU_TARGET -- ladder.sh and probe.cu are CUDA-only," >&2
  echo "       so this would ship harness dirs its own driver cannot build." >&2
  exit 2 ; }

OUTDIR="${1:-$HERE/bundle-out}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

TESTS_FILE="${TESTS_FILE:-$HERE/TESTS.txt}"
[ -r "$TESTS_FILE" ] || { echo "error: no $TESTS_FILE" >&2; exit 2; }

mapfile -t WANT < <(grep -vE '^[[:space:]]*(#|$)' "$TESTS_FILE" | awk '{print $1}')
[ "${#WANT[@]}" -gt 0 ] || { echo "error: $TESTS_FILE names no tests" >&2; exit 2; }
echo "[1/5] subset: ${#WANT[@]} tests -- ${WANT[*]}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "[2/5] emitting the het corpus into scratch"
EMIT="$SCRATCH/emit/het-$GPU_TARGET"
mkdir -p "$EMIT"
st=0
"$LITMUS7" -gpu-target "$GPU_TARGET" -set-libdir "$REPO/litmus/libdir" \
  -o "$EMIT" "$HETL"/tests/het/*.litmus > "$SCRATCH/emit.log" 2>&1 || st=$?
# litmus7's batch driver catches an emission exception and still exits 0, so the
# refusal marker is read as well as the status.
if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$SCRATCH/emit.log"; then
  echo "FAIL: emission exited $st or refused; last 20 lines:" >&2
  tail -20 "$SCRATCH/emit.log" >&2
  exit 1
fi
echo "      $(find "$EMIT" -mindepth 1 -maxdepth 1 -type d | wc -l) harness dirs"

REV="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUNDLE="$SCRATCH/hetlitmus-spotcheck-$REV"
mkdir -p "$BUNDLE/tests"

echo "[3/5] pruning to the subset (a name that does not resolve is fatal)"
missing=()
for t in "${WANT[@]}"; do
  if [ -d "$EMIT/$t" ]; then
    cp -r "$EMIT/$t" "$BUNDLE/tests/$t"
  else
    missing+=("$t")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $TESTS_FILE names ${#missing[@]} test(s) with no emitted harness dir:" >&2
  for m in "${missing[@]}"; do echo "        $m" >&2; done
  echo "      The corpus emitted $(find "$EMIT" -mindepth 1 -maxdepth 1 -type d | wc -l) dirs." >&2
  exit 1
fi

# The widest-launch row is the one subset choice that is a claim about the rest
# of the corpus, so it is re-measured here or not at all.
WIDEST_ROLE=3-widest-launch
mapfile -t WIDE < <(grep -vE '^[[:space:]]*(#|$)' "$TESTS_FILE" \
                    | awk -F'\t' -v r="$WIDEST_ROLE" '$2 == r {print $1}')
if [ "${#WIDE[@]}" -ne 1 ]; then
  echo "" >&2
  echo "FAIL: $TESTS_FILE has ${#WIDE[@]} row(s) with role '$WIDEST_ROLE'; the ladder" >&2
  echo "      runs exactly one widest-launch pick, so the claim cannot be checked." >&2
  exit 1
fi
# The two launch axes, maximised over the .cu files named; over a single harness
# that is just its own geometry, so one reader serves both sides.
axes_max() {
  awk '/^#define NPART /          {if ($3+0 > n) n = $3+0}
       /^#define HET_TEST_BLOCKS /{if ($3+0 > b) b = $3+0}
       END {print n+0, b+0}' "$@"
}
read -r wn wb <<<"$(axes_max "$BUNDLE/tests/${WIDE[0]}/${WIDE[0]}.cu")"
read -r mn mb <<<"$(axes_max "$EMIT"/*/*.cu)"
if [ "$wn" != "$mn" ] || [ "$wb" != "$mb" ]; then
  echo "" >&2
  echo "FAIL: ${WIDE[0]} is npart=$wn blocks=$wb, but the corpus reaches" >&2
  echo "      npart=$mn blocks=$mb; re-pick the row before packing." >&2
  exit 1
fi
echo "      widest launch: ${WIDE[0]} npart=$wn blocks=$wb (corpus maximum)"

echo "[4/5] adding driver, probe, ladder, stamp"
cp "$HETL/campaign.py"                 "$BUNDLE/"
cp "$HERE/probe.cu" "$HERE/probe-cuda.sh" "$HERE/ladder.sh" "$HERE/run-one.sh" \
   "$HERE/TESTS.txt" "$HERE/README.md" "$BUNDLE/"
chmod +x "$BUNDLE/probe-cuda.sh" "$BUNDLE/ladder.sh" "$BUNDLE/run-one.sh"

{
  echo "bundle=hetlitmus-spotcheck"
  echo "git_rev=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo nogit)"
  echo "git_rev_short=$REV"
  echo "git_branch=$(cd "$REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo nogit)"
  # Dirty = ANY uncommitted change under litmus/ or hetlitmus/, untracked files
  # included: such a bundle is not reproducible from git_rev.
  echo "git_dirty=$( [ -z "$(cd "$REPO" && git status --porcelain -- litmus hetlitmus 2>/dev/null)" ] && echo no || echo YES )"
  echo "packed_date=$(date -Is 2>/dev/null || date)"
  echo "packed_host=$(uname -sm)"
  echo "corpus_emitted=$(find "$EMIT" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "subset_count=${#WANT[@]}"
  # The geometry each pick was made for, read off the harness that shipped: the
  # launch size the rungs are keyed to, legible before the instance is rented.
  for t in "${WANT[@]}"; do
    cu="$BUNDLE/tests/$t/$t.cu"
    echo "subset_test=$t npart=$(sed -n 's/^#define NPART //p' "$cu" | head -1)" \
         "blocks=$(sed -n 's/^#define HET_TEST_BLOCKS //p' "$cu" | head -1)" \
         "gpu_lanes=$(sed -n 's/^#define HET_GPU_LANES //p' "$cu" | head -1)"
  done
  echo "emitter_sha256=$(sha256sum "$REPO/litmus/hetEmit.ml" | cut -d' ' -f1)"
  # hetDialect.ml carries the per-vendor records the render is built from, so
  # the emitter hash alone does not cover what a .cu contains.
  echo "dialect_sha256=$(sha256sum "$REPO/litmus/hetDialect.ml" | cut -d' ' -f1)"
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
echo "next:   scp it over, tar xzf, sh probe-cuda.sh, then sh ladder.sh"
