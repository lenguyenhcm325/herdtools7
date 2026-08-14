#!/usr/bin/env bash
# Oracle comparison: read litmus7 "Observation <name> <Never|Sometimes|Always>"
# lines and classify each against a reference verdict CSV the caller supplies,
# as MATCH / MISMATCH / NO-ORACLE / UNINTERPRETED.  Comparison semantics, the
# quantifier inversion, the statistics section and a worked example:
# hetlitmus/docs/oracle-harness.md; tests/cram/oracle-negatives.t pins all four.
#
# NO-ORACLE and UNINTERPRETED are kept apart: a CSV that has the row and
# declines to decide it is earned model silence, a test the CSV never covered
# has no frame at all, and reading the second as the first reports "the model
# makes no claim here" off a file that simply has no rows.
#
# The verdict vocabulary enters ONLY through the CSV.  This harness
# characterizes: it reports observations and carries no prediction, so every
# Allowed/Disallowed word below comes from the caller's file and none from the
# run log.
#
# Usage:   ./oracle-compare.sh <observations-file> <oracle-csv>
#   observations-file : a litmus7 log, or any file containing Observation lines
#   oracle-csv        : the reference CSV, columns "Litmus,Expected,Model,Source"
#                       ('#' comment lines and the header row are skipped).  This
#                       branch ships none and derives none, so the argument is
#                       the whole supply.
# Exit status: 0 if no MISMATCH, 1 if any (so it is CI-usable); the table is
# printed either way.
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
  fmt = "%-14s %-7s %-10s %-12s %-14s %-14s %s\n"
  printf fmt, "TEST", "QUANT", "OBSERVED", "ORACLE", "MODEL", "RESULT", "NOTE"
  printf fmt, "----", "-----", "--------", "------", "-----", "------", "----"
  nmatch = 0; nmis = 0; nno = 0; nun = 0
  pending_quant = ""
}
# The litmus "Condition <quant> (...) is [NOT ]validated" line precedes the
# Observation line of its test (litmus/skelUtil.ml); stash the quantifier for the
# next Observation.  "~exists" reads like "exists" -- only forall flips.
/^Condition/ {
  pending_quant = ($0 ~ /forall/) ? "forall" : "exists"
  next
}
# The harness prints its own aggregate twice.  Two shapes both begin "HetStats " --
# the key=value line, which drives the roll-up below, and the human block from
# het_stats_print, whose second field ends in ":" and which is reprinted VERBATIM:
# the interpretation is written once, in C, next to the numbers it belongs to.
/^HetStats / {
  if ($2 ~ /:$/) {
    blk = $2; sub(/:$/, "", blk)
    nblk[blk] = 0
    block[blk, nblk[blk]++] = $0
    next
  }
  blk = ""
  t = $2
  for (i = 3; i <= NF; i++) {
    p = index($i, "=")
    if (p > 0) S[t, substr($i, 1, p-1)] = substr($i, p+1)
  }
  if (!(t in seen_stats)) { seen_stats[t] = 1; sorder[nstats++] = t }
  next
}
# het_stats_print indents every continuation line of its block, so the first
# unindented line ends it (and is still offered to the rules below).
blk != "" {
  if ($0 ~ /^[ \t]/) { block[blk, nblk[blk]++] = $0; next }
  blk = ""
}
/^Observation/ {
  test = $2; obs = $3
  quant = (pending_quant != "") ? pending_quant : "exists"
  pending_quant = ""
  # Was the targeted predicate of the oracle witnessed?  For exists/~exists that
  # is obs != "Never"; for forall the Never/Sometimes-Always reading is inverted
  # ("Never" = predicate held for ALL executions; see header), so "seen" flips.
  if (quant == "forall") seen = (obs == "Never")
  else                   seen = (obs != "Never")
  if (test in orac) {
    verdict = orac[test]; mdl = model[test]
    if (verdict == "Disallowed") {
      if (seen) {
        result="MISMATCH"
        # One constant sentence on every MISMATCH row, naming the nearer
        # candidate culprit: the oracle row is a derivation, not a measurement.
        # Nothing in the CSV may grade one row against another -- only Litmus,
        # Expected and Model are parsed out of it, and Source reaches no
        # printed line.
        note="FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM"
      }
      else      { result="MATCH";    note="forbidden, not seen" }
    } else if (verdict == "Allowed") {
      result="MATCH"; note = seen ? "relaxation seen" : "allowed, not exhibited"
    } else if (verdict == "NO-ORACLE") {
      # EARNED model silence: the oracle has the row and declines to decide it.
      result="NO-ORACLE"; note="model silence: this oracle makes no claim here"
    } else {
      # A verdict string this harness does not know is a CORRUPT oracle, not a
      # pass and not silence.  Fail closed and name the value.
      result="UNINTERPRETED"; note="unknown oracle verdict \"" verdict "\""
      verdict="?"; mdl="-"
    }
  } else {
    verdict="-"; mdl="-"; result="UNINTERPRETED"
    note="ABSENT from this oracle -- no frame for this test (never model silence)"
  }
  if (result=="MATCH") nmatch++
  else if (result=="MISMATCH") nmis++
  else if (result=="NO-ORACLE") nno++
  else nun++
  resmap[test] = result          # the statistics section reprints it per test
  printf fmt, test, quant, obs, verdict, mdl, result, note
}
END {
  printf "\n%d test(s): %d MATCH, %d MISMATCH, %d NO-ORACLE, %d UNINTERPRETED\n", \
         nmatch+nmis+nno+nun, nmatch, nmis, nno, nun

  # ================= the statistics roll-up ================================
  # Layered on top of the table above; absent from a log that carries no HetStats.
  if (nstats > 0) {
    printf "\n"
    printf "=====================================================================\n"
    printf "STATISTICS -- what each verdict is WORTH\n"
    printf "=====================================================================\n"
    printf "Each block below is reprinted verbatim from het_stats_print (het_verdict.h),\n"
    printf "under the oracle RESULT from the table above.  The replication unit is the\n"
    printf "(instance,run) CELL, never the frame: the recovery scan validates N^{T_L}\n"
    printf "OVERLAPPING frames per N iterations (PerpLE VI-B.1), so the frame count is not\n"
    printf "a count of independent replicates.\n\n"

    ndis = 0; ndis_fired = 0; nvoid = 0
    for (si = 0; si < nstats; si++) {
      t = sorder[si]
      # The class comes from the CSV and NEVER from the log: the harness carries
      # no prediction and prints none, so a roll-up that read one off a run line
      # would be reading a field that does not exist.  A test the CSV does not
      # cover has no class here.
      orc = (t in orac) ? orac[t] : "-"
      ob = S[t, "obs"]

      if (orc == "Disallowed") { ndis++; if (ob != "Never" && ob != "VOID") ndis_fired++ }
      if (ob == "VOID") nvoid++

      printf "%s : %s   oracle=%s\n", t, (t in resmap) ? resmap[t] : "-", orc
      if (nblk[t] + 0 == 0)
        printf "  (this log carries the HetStats data line but not the het_stats_print block)\n"
      for (bi = 0; bi < nblk[t]; bi++) printf "%s\n", block[t, bi]
      printf "\n"
    }
    # ---- the campaign-level negative control ---------------------------------
    # The rows the supplied CSV marks Disallowed are where an inventive decoder
    # would show, so they carry the assurance that this campaign invents no
    # cycles.  The sentence printed below names its source.
    printf "---------------------------------------------------------------------\n"
    printf "NEGATIVE CONTROL (campaign-level): %d of %d should-be-FORBIDDEN test(s) fired.\n", \
           ndis_fired, ndis
    if (ndis == 0)
      printf "  (no Disallowed tests in this log -- the decoder is NOT vouched for here.)\n"
    else if (ndis_fired == 0)
      printf "  The decoder does not generate false positives on this run:\n    \"PerpLE%s failure to observe these forbidden outcomes can be viewed as a\n     reassurance that PerpLE does not generate false positives.\"  -- PerpLE VII-A.\n", "'\''s"
    else
      printf "  *** A FORBIDDEN OUTCOME FIRED: either this oracle row (a DERIVATION, not a\n      measurement) is wrong or the decoder is unsound, in which case every null here is\n      void.  Settle it against the SIGHTING TIER -- an artefact does not reproduce across\n      re-seeded runs -- before reporting either way.\n"
    if (nvoid > 0)
      printf "VOID: %d row(s) came from a harness that was never demonstrably hot -- DISCARDED.\n", nvoid
    printf "---------------------------------------------------------------------\n"
  }

  if (nmis > 0) exit 1
}
' "$OBS"
