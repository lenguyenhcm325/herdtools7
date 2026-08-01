#!/usr/bin/env bash
# Validate a scoped GPU .cat against the GPU-only oracle.
#
# Runs herd7 (ptx.bell + the model's .cat) over hetlitmus/tests/gpu-only/*.litmus
# and prints a comparison table
#   test | computed | expected | match
# against that model's expected-*.csv.
#
#   amd     amd-gcn3.cat vs expected-amd-gcn3.csv (PLDI'23 GCN3_X86), which
#           carries verdicts for the 8 PLDI'23-anchored tests only.
#   nvidia  nvidia-ptx.cat vs expected-nvidia.csv, 137 rows all machine-computed
#           by this same cat.  The 8 anchored rows were ALSO hand-derived from
#           the PTX model and are reproduced by the cat -- they are printed
#           first and tagged [anchor].
#
# Run from the herdtools7 repo root, with herd7 built in _build (see memory
# herdtools7-build-run):
#     bash hetlitmus/cats/run-gpu-only.sh [amd|nvidia]     (default amd)
#     bash hetlitmus/cats/run-gpu-only-nvidia.sh           (the nvidia entry point)
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="$BIN:$PATH"

BELL=hetlitmus/bells/ptx.bell
TESTDIR=hetlitmus/tests/gpu-only

case "${1:-amd}" in
  amd)    CAT=hetlitmus/cats/amd-gcn3.cat
          CSV=$TESTDIR/expected-amd-gcn3.csv; ALL=0; W=12; TAIL=6;;
  nvidia) CAT=hetlitmus/cats/nvidia-ptx.cat
          CSV=$TESTDIR/expected-nvidia.csv;   ALL=1; W=20; TAIL=16;;
  *) echo "usage: $0 [amd|nvidia]" >&2; exit 2;;
esac

# The 8 PLDI'23-anchored tests (hand-derived verdicts); printed first.
ANCHORS="MP-sys MP-sys-F MP-cta-F LB-sys SB-sys SB-sys-F IRIW-sys IRIW-sys-F"
is_anchor() { case " $ANCHORS " in *" $1 "*) return 0;; *) return 1;; esac; }

# Map oracle vocabulary (Allowed/Disallowed) to herd vocabulary (Allowed/Forbidden).
norm() { case "$1" in Allowed) echo Allowed;; Disallowed|Forbidden) echo Forbidden;; *) echo "$1";; esac; }

# verdict <test> : run herd7 and turn the Observation line into Allowed/Forbidden.
# NB: herd7 line 1 ("Test <name> Allowed") is the test KIND, not the result. The
# real verdict is the witness count for the `exists' condition on the
# "Observation <name> Never|Sometimes|Always" line: Never => the targeted (weak)
# outcome is unreachable => Forbidden; Sometimes/Always => Allowed.
verdict() {
  local obs
  obs=$(herd7 -set-libdir herd/libdir -bell "$BELL" -cat "$CAT" \
          "$TESTDIR/$1.litmus" 2>/dev/null \
        | sed -n 's/^Observation [^ ]* \(Never\|Sometimes\|Always\).*/\1/p')
  case "$obs" in
    Never)            echo Forbidden;;
    Sometimes|Always) echo Allowed;;
    *)                echo ERROR;;
  esac
}

sep() { printf -- '%s+-----------+-----------+%s\n' \
          "$(printf '%*s' $((W+1)) '' | tr ' ' -)" \
          "$(printf '%*s' "$TAIL" '' | tr ' ' -)"; }

pass=0; total=0
run_one() {
  local t="$1" tag="$2"
  total=$((total+1))
  local v exp_raw exp m
  v=$(verdict "$t")
  exp_raw=$(awk -F, -v n="$t" '$1==n{print $2}' "$CSV")
  exp=$(norm "$exp_raw")
  if [ "$v" = "$exp" ]; then m="OK"; pass=$((pass+1)); else m="MISMATCH"; fi
  printf '%-*s | %-9s | %-9s | %s%s\n' "$W" "$t" "$v" "$exp" "$m" "$tag"
}

printf '%-*s | %-9s | %-9s | %s\n' "$W" "test" "computed" "expected" "match"
sep
TAG=""; [ "$ALL" = 1 ] && TAG="   [anchor]"
for t in $ANCHORS; do run_one "$t" "$TAG"; done
if [ "$ALL" = 1 ]; then
  sep
  for f in "$TESTDIR"/*.litmus; do
    t=$(basename "$f" .litmus)
    is_anchor "$t" && continue
    run_one "$t" ""
  done
fi

sep
printf 'RESULT: %d/%d match\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
