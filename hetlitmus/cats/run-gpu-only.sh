#!/usr/bin/env bash
# Validate the AMD GCN3 scoped .cat against the GPU-only oracle.
#
# Runs herd7 (ptx.bell + amd-gcn3.cat) over every test in
# hetlitmus/tests/gpu-only/*.litmus and prints a comparison table
#   test | computed | expected | match
# against hetlitmus/tests/gpu-only/expected-amd-gcn3.csv.
#
# Run from the herdtools7 repo root, with herd7 built in _build (see memory
# herdtools7-build-run):  bash hetlitmus/cats/run-gpu-only.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="$ROOT/_build/install/default/bin:$PATH"

BELL=hetlitmus/bells/ptx.bell
CAT=hetlitmus/cats/amd-gcn3.cat
TESTDIR=hetlitmus/tests/gpu-only
CSV=$TESTDIR/expected-amd-gcn3.csv

# Map oracle vocabulary (Allowed/Disallowed) to herd vocabulary (Allowed/Forbidden).
norm() { case "$1" in Allowed) echo Allowed;; Disallowed|Forbidden) echo Forbidden;; *) echo "$1";; esac; }

printf '%-12s | %-9s | %-9s | %s\n' "test" "computed" "expected" "match"
printf -- '-------------+-----------+-----------+------\n'

pass=0; total=0
for t in MP-sys MP-sys-F MP-cta-F LB-sys SB-sys SB-sys-F IRIW-sys IRIW-sys-F; do
  total=$((total+1))
  # NB: herd7 line 1 ("Test <name> Allowed") is the test KIND, not the result.
  # The real verdict is the witness count for the `exists` condition, reported on
  # the "Observation <name> Never|Sometimes|Always" line: Never => the targeted
  # (weak) outcome is unreachable => Forbidden; Sometimes/Always => Allowed.
  obs=$(herd7 -set-libdir herd/libdir -bell "$BELL" -cat "$CAT" \
          "$TESTDIR/$t.litmus" 2>/dev/null \
          | sed -n 's/^Observation [^ ]* \(Never\|Sometimes\|Always\).*/\1/p')
  case "$obs" in
    Never)            verdict=Forbidden;;
    Sometimes|Always) verdict=Allowed;;
    *)                verdict=ERROR;;
  esac
  exp_raw=$(awk -F, -v n="$t" '$1==n{print $2}' "$CSV")
  exp=$(norm "$exp_raw")
  if [ "$verdict" = "$exp" ]; then m="OK"; pass=$((pass+1)); else m="MISMATCH"; fi
  printf '%-12s | %-9s | %-9s | %s\n' "$t" "$verdict" "$exp" "$m"
done

printf -- '-------------+-----------+-----------+------\n'
printf 'RESULT: %d/%d match\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
