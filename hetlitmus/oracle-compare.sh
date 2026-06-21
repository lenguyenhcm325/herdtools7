#!/usr/bin/env bash
# HetLitmus Tier-4 -- oracle-comparison harness.
#
# Reads litmus7 "Observation <name> <Never|Sometimes|Always> ..." lines (the
# verdict litmus7 prints after running a test) and compares each against a
# reference oracle CSV passed EXPLICITLY as the second argument.  It emits one
# of three results per test:
#
#   MATCH      observation is consistent with the oracle verdict
#   MISMATCH   a FORBIDDEN outcome was observed (oracle says Disallowed but the
#              relaxed outcome was seen) -- a genuine model violation / finding
#   NO-ORACLE  the test is absent from the given oracle CSV, so no claim is made
#
# Why NO-ORACLE is a first-class result (not a default to "pass"): the PLDI'23
# expected.csv is the gem5 GCN3_X86 oracle = AMD GCN3 GPU + x86 CPU only.  It
# covers the GPU-only AMD corpus, but the heterogeneous GH200 tests (AArch64 CPU
# + PTX GPU, e.g. MP-het) have NO oracle yet -- a separate expected-nvidia.csv
# must be derived from the NVIDIA PTX model.  The harness therefore refuses to
# assume a verdict for tests it cannot ground, marking them NO-ORACLE.  See
# hetlitmus/docs/oracle-harness.md and hetlitmus/docs/gpu-only-corpus.md.
#
# Comparison semantics (litmus methodology): the only hard contradiction is
# observing a forbidden outcome.  An "Allowed" relaxation that is simply never
# exhibited on a given run is consistent with the model (it MAY happen), so it
# is a MATCH (annotated "allowed, not exhibited").
#
# Usage:   ./oracle-compare.sh <observations-file> <oracle-csv>
#   observations-file : a litmus7 log, or any file containing Observation lines
#   oracle-csv        : reference CSV, columns "Litmus,Expected,Model,Source"
#                       ('#' comment lines and the header row are skipped)
#
# Exit status: 0 if no MISMATCH, 1 if any MISMATCH (so it is CI-usable).  The
# table is printed regardless of exit status.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <observations-file> <oracle-csv>" >&2
  exit 2
fi
OBS="$1"
ORACLE="$2"
[ -r "$OBS" ]    || { echo "error: cannot read observations '$OBS'" >&2; exit 2; }
[ -r "$ORACLE" ] || { echo "error: cannot read oracle csv '$ORACLE'" >&2; exit 2; }

echo "Oracle:       $ORACLE"
echo "Observations: $OBS"
echo

awk -v oracle_csv="$ORACLE" '
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
BEGIN {
  # --- load the oracle CSV into name -> (verdict, model) ---
  while ((getline line < oracle_csv) > 0) {
    if (line ~ /^[ \t]*#/ || trim(line) == "") continue
    n = split(line, f, ",")
    name = trim(f[1])
    if (name == "Litmus") continue            # header row
    orac[name]   = trim(f[2])
    model[name] = (n >= 3) ? trim(f[3]) : "?"
  }
  close(oracle_csv)
  fmt = "%-14s %-10s %-12s %-14s %-10s %s\n"
  printf fmt, "TEST", "OBSERVED", "ORACLE", "MODEL", "RESULT", "NOTE"
  printf fmt, "----", "--------", "------", "-----", "------", "----"
  nmatch = 0; nmis = 0; nno = 0
}
/^Observation/ {
  test = $2; obs = $3
  if (test in orac) {
    verdict = orac[test]; mdl = model[test]
    if (verdict == "Disallowed") {
      if (obs == "Never") { result="MATCH";    note="forbidden, not seen" }
      else                { result="MISMATCH"; note="FORBIDDEN OUTCOME SEEN" }
    } else if (verdict == "Allowed") {
      if (obs == "Never") { result="MATCH"; note="allowed, not exhibited" }
      else                { result="MATCH"; note="relaxation seen" }
    } else {
      result="NO-ORACLE"; note="unknown oracle verdict \"" verdict "\""
      verdict="?"; mdl="-"
    }
  } else {
    verdict="-"; mdl="-"; result="NO-ORACLE"; note="not in this oracle (GH200/PTX?)"
  }
  if (result=="MATCH") nmatch++
  else if (result=="MISMATCH") nmis++
  else nno++
  printf fmt, test, obs, verdict, mdl, result, note
}
END {
  printf "\n%d test(s): %d MATCH, %d MISMATCH, %d NO-ORACLE\n", \
         nmatch+nmis+nno, nmatch, nmis, nno
  if (nmis > 0) exit 1
}
' "$OBS"
