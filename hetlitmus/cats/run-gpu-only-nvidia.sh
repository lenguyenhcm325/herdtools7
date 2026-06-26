#!/usr/bin/env bash
# Validate the NVIDIA PTX scoped .cat against the GPU-only oracle (ALL tests).
#
# Runs herd7 (ptx.bell + nvidia-ptx.cat) over EVERY test in
# hetlitmus/tests/gpu-only/*.litmus and prints a comparison table
#   test | computed | expected | match
# against hetlitmus/tests/gpu-only/expected-nvidia.csv (137 rows, all
# machine-computed by this same cat; the 8 PLDI'23-anchored rows were ALSO
# hand-derived from the PTX model and are reproduced by the cat -- they are
# printed first and tagged [anchor]).
#
# Counterpart to run-gpu-only.sh (the AMD/GCN3 runner, 8 tests). Run from the
# herdtools7 repo root with herd7 built in _build (see memory herdtools7-build-run):
#     bash hetlitmus/cats/run-gpu-only-nvidia.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="$ROOT/_build/install/default/bin:$PATH"

BELL=hetlitmus/bells/ptx.bell
CAT=hetlitmus/cats/nvidia-ptx.cat
TESTDIR=hetlitmus/tests/gpu-only
CSV=$TESTDIR/expected-nvidia.csv

# The 8 PLDI'23-anchored tests (hand-derived NVIDIA verdicts); printed first.
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

printf '%-20s | %-9s | %-9s | %s\n' "test" "computed" "expected" "match"
printf -- '---------------------+-----------+-----------+----------------\n'

pass=0; total=0

run_one() {
  local t="$1" tag="$2"
  total=$((total+1))
  local v exp_raw exp m
  v=$(verdict "$t")
  exp_raw=$(awk -F, -v n="$t" '$1==n{print $2}' "$CSV")
  exp=$(norm "$exp_raw")
  if [ "$v" = "$exp" ]; then m="OK"; pass=$((pass+1)); else m="MISMATCH"; fi
  printf '%-20s | %-9s | %-9s | %s%s\n' "$t" "$v" "$exp" "$m" "$tag"
}

# Anchors first (tagged), then the rest of the grid in sorted order.
for t in $ANCHORS; do run_one "$t" "   [anchor]"; done
printf -- '---------------------+-----------+-----------+----------------\n'
for f in "$TESTDIR"/*.litmus; do
  t=$(basename "$f" .litmus)
  is_anchor "$t" && continue
  run_one "$t" ""
done

printf -- '---------------------+-----------+-----------+----------------\n'
printf 'RESULT: %d/%d match\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
