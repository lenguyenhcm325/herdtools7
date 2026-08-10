#!/usr/bin/env bash
# HetLitmus inert-data gate: the two het verdict CSVs stay data nothing reads.
#
# tests/het/expected-nvidia.csv and tests/het/expected-amd.csv are unmaintained
# artifacts of the archived derivation effort (branch hetlitmus-oracle-derivation);
# docs/oracle-harness.md is the standing statement and their own headers repeat
# it.  What would quietly end that is a new in-tree reference -- a gate
# reading one, a script defaulting to one, a doc calling one the corpus's oracle
# again.  So: both files must still declare themselves unmaintained, and every
# tracked file naming either must be on the allowlist below, one justified line
# each.  Anything else fails by file and line.
#
# The basename `expected-nvidia.csv' is SHARED with the live GPU-only lane oracle
# tests/gpu-only/expected-nvidia.csv, which no name scan can tell apart, so each
# allowlist line says which of the two files its entry means.  A path assembled
# at run time ("$dir/expected-$vendor.csv") is invisible to a text scan; nothing
# in the tree does that (measured 2026-08-10).
#
# Usage:  hetlitmus/verify/inertcheck.sh [--bite]
# Exit:   0 = PASS, 1 = a reference or a missing banner (printed), 2 = infra error.

set -uo pipefail   # NOT -e: run every check and aggregate, not fail-fast.

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
cd "$REPO"

SELF="hetlitmus/verify/inertcheck.sh"
NV="hetlitmus/tests/het/expected-nvidia.csv"
AMD="hetlitmus/tests/het/expected-amd.csv"
BANNER="UNMAINTAINED ARTIFACT"

# Every name form a reference takes, including the brace spelling.  The trailing
# character class is what keeps the OTHER files out: expected-amd-gcn3.csv (the
# live GPU-only AMD oracle) and the -declined/-x2a round-trip outputs named in
# the two headers.
PAT='expected-nvidia\.csv|expected-amd\.csv|expected-(nvidia|amd)([^-.[:alnum:]]|$)|expected-\{'

# --- allowlist: path | why this file may name one ----------------------------
# Out of the scan: the two CSVs (a file naming itself is not a reference) and
# this gate (it has to spell both names to go looking for them).
ALLOW='
# (a) the GPU-only lane, untouched by the pivot: these mean the LIVE oracle
#     tests/gpu-only/expected-nvidia.csv, machine-computed by nvidia-ptx.cat.
hetlitmus/cats/nvidia-ptx.cat|the .cat names the 137-row file it machine-checks
hetlitmus/cats/run-gpu-only.sh|that check runner reads it as its input CSV
hetlitmus/docs/nvidia-ptx-cat.md|the .cat lane doc
hetlitmus/docs/gpu-only-corpus.md|that corpus doc
hetlitmus/docs/corpus-grid.md|the grid doc oracle-status note, on the same file
hetlitmus/tests/gpu-only/expected-amd-gcn3.csv|its header names its NVIDIA counterpart in the same directory
# (b) the het files, as offline data: named, never opened by the toolchain.
hetlitmus/oracle-compare.sh|the offline consumer -- the only tool that can read one, and only from the CSV argument its caller passes
hetlitmus/tests/cram/oracle-negatives.t|prose measuring that harness NO-ORACLE arm against the row count of one
hetlitmus/tests/cram/oracle.csv|hand-authored fixture: prose cites the gpu-only file its real rows came from and both het NO-ORACLE counts, which are stale
hetlitmus/tests/cram/oracle-stats.csv|the other half of that fixture pair: prose plus a synthetic Source string, both inert text to the harness
hetlitmus/verify/x86bodycheck.py|comment on why the x86 renderings keep the unsuffixed test names both CSVs key on
# (c) negative assertions: these name one in order to prove it is ABSENT.
hetlitmus/verify/emit-all.sh|the cross-vendor forbidden-word list for the x86:cuda lane
hetlitmus/tests/cram/machine-pairs.t|greps emitted trees to prove no harness carries the word
hetlitmus/verify/verdictcheck.py|a bite injects an oracle-source stamp into an emitted harness and requires the gate to redden
'

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hetlitmus-inert.XXXXXX")" || exit 2
trap 'rm -rf "$SCRATCH"' EXIT

# --- the two halves, as functions so --bite can drive them off real inputs ---

banner_ok() {   # $1 = a verdict CSV; does it still say it is unmaintained?
  grep -qF -- "$BANNER" "$1"
}

hits_of() {     # $@ = extra paths folded into the tracked set (--bite only)
  { git grep -nIE -e "$PAT"
    [ "$#" -gt 0 ] && grep -HnIE -e "$PAT" "$@" ; } \
  | grep -vE "^($SELF|$NV|$AMD):"
}

judge() {       # $1 = allowlist text; stdin = hits; prints offenders, rc 1 if any
  local allow="$1" hits bad=0 line f p
  hits="$(cat)"
  local paths; paths="$(printf '%s\n' "$allow" | awk -F'|' 'NF && $1 !~ /^#/ {print $1}')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%:*}"
    printf '%s\n' "$paths" | grep -qxF -- "$f" && continue
    echo "  FAIL: $line"
    bad=1
  done <<EOF
$hits
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$hits" | awk -F: -v p="$p" '$1==p{f=1} END{exit !f}' && continue
    echo "  FAIL: allowlist entry no longer names either CSV, so drop it: $p"
    bad=1
  done <<EOF
$paths
EOF
  return "$bad"
}

# --- --bite: each half must fail, and fail on the thing that was broken ------

if [ "${1:-}" = "--bite" ]; then
  ok=0
  echo "HetLitmus inert-data gate -- bite"
  echo "=================================================================="

  strip="$SCRATCH/nobanner.csv"
  grep -vF -- "$BANNER" "$NV" > "$strip"
  if banner_ok "$strip"; then
    echo "  *** DID NOT BITE   [a verdict CSV dropped its unmaintained banner]"; ok=1
  else
    echo "  BITES (gate failed, as it must)   [a verdict CSV dropped its unmaintained banner]"
  fi

  newref="$SCRATCH/a-fresh-caller.sh"
  printf '# reaches for %s\n' "$NV" > "$newref"
  out="$(hits_of "$newref" | judge "$ALLOW")"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF -- "$newref"; then
    echo "  BITES (gate failed, as it must)   [an unlisted file names an inert CSV]"
  else
    echo "  *** DID NOT BITE (rc=$rc)   [an unlisted file names an inert CSV]"; ok=1
  fi

  dropped="hetlitmus/oracle-compare.sh"
  shrunk="$(printf '%s\n' "$ALLOW" | awk -F'|' -v d="$dropped" '$1!=d')"
  out="$(hits_of | judge "$shrunk")"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF -- "$dropped"; then
    echo "  BITES (gate failed, as it must)   [a legitimate referencer left the allowlist]"
  else
    echo "  *** DID NOT BITE (rc=$rc)   [a legitimate referencer left the allowlist]"; ok=1
  fi

  echo "=================================================================="
  [ "$ok" -eq 0 ] && { echo "BITE: PASS (all three injections failed the gate)"; exit 0; }
  echo "BITE: FAIL (an injection went unnoticed)"; exit 1
fi

# --- the gate ----------------------------------------------------------------

fail=0
echo "HetLitmus inert-data gate  (repo: $REPO)"
echo "=================================================================="

echo "[1/2] Banner (both files still declare themselves unmaintained)"
for f in "$NV" "$AMD"; do
  if banner_ok "$f"; then
    echo "  PASS: $f"
  else
    echo "  FAIL: $f no longer carries \"$BANNER\" -- an inert file that stopped saying so"
    fail=1
  fi
done

echo "[2/2] Reference surface (tracked files naming either)"
hits="$(hits_of)"
n_hits=$(printf '%s\n' "$hits" | grep -c . )
n_files=$(printf '%s\n' "$hits" | awk -F: 'NF{print $1}' | sort -u | wc -l | tr -d ' ')
n_allow=$(printf '%s\n' "$ALLOW" | awk -F'|' 'NF && $1 !~ /^#/' | wc -l | tr -d ' ')
echo "        $n_hits reference(s) in $n_files file(s); allowlist carries $n_allow"
if printf '%s\n' "$hits" | judge "$ALLOW"; then
  echo "  PASS: every file naming one is on the allowlist, and every entry still earns its line"
else
  echo "        an inert artifact is being read again, or the allowlist has rotted:"
  echo "        add the file to the allowlist in $SELF with its one-line reason,"
  echo "        or stop referring to hetlitmus/tests/het/expected-*.csv."
  fail=1
fi

echo "=================================================================="
if [ "$fail" -eq 0 ]; then
  echo "GATE: PASS  (banner intact, $n_hits reference(s) all accounted for)"
  exit 0
fi
echo "GATE: FAIL  (see the offending paths above)"
exit 1
