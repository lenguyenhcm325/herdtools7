#!/usr/bin/env bash
# HetLitmus Tier-4 -- oracle-comparison harness.  Spec, comparison semantics and
# a worked example: hetlitmus/docs/oracle-harness.md.
#
# Reads litmus7 "Observation <name> <Never|Sometimes|Always> ..." lines and
# compares each against the reference oracle CSV given as the second argument:
#
#   MATCH          the observation is consistent with the oracle verdict
#   MISMATCH       a FORBIDDEN outcome was observed -- a genuine model violation
#   NO-ORACLE      the CSV HAS this row and it says NO-ORACLE: EARNED model
#                  silence -- the supplied CSV does not decide this test
#   UNINTERPRETED  the test is ABSENT from this CSV, so there is no frame for it
#                  at all -- or the CSV carries a verdict this harness does not
#                  know, which is a corrupt oracle and never a pass
#
# The last two are kept apart deliberately: a corpus the supplied CSV never
# covered is absent from it row by row, and reading that as model silence would
# report "the model makes no claim here" off a file that simply has no rows.
# All four RESULTs are pinned by tests/cram/oracle-negatives.t.
#
# NO-ORACLE is a first-class result, not a default to "pass".  An oracle grounds
# only the platform it was derived for: the PLDI'23 expected.csv is the gem5
# GCN3_X86 oracle (AMD GCN3 GPU + x86 CPU), which covers the GPU-only AMD corpus
# and says nothing about a heterogeneous AArch64+PTX GH200 test.  Refusing to
# assume a verdict for a test it cannot ground is what keeps the grounded rows
# honest and makes a missing oracle visible per test rather than hidden.
#
# The quantifier matters: litmus reports Never/Sometimes/Always relative to the
# test's validation, and `forall' inverts what "Never" means, so the harness
# recovers it from the "Condition <quant> (...)" line preceding each Observation
# (oracle-harness.md sec 1 and 3).  No Condition line => `exists'.
#
# A second section says what each verdict is statistically WORTH: het_stats_print's
# own per-test block, reprinted verbatim under that test's result, plus a
# campaign-level negative control rolled up from the `HetStats' data lines
# (het_verdict.h, het_stats_line).  The interpretation is written once, in C, beside
# the numbers it belongs to; restating it here is how the two drift apart.  The
# section appears only when the log carries those lines, so a log without them (the
# synthesized samples, the cram fixtures) prints the table alone.
#
# THIS FILE IS THE ONLY PLACE THE VERDICT VOCABULARY SURVIVES.  The harness
# characterizes: it reports observations and carries no prediction, so every
# Allowed/Disallowed word below comes from the user-supplied CSV and from nowhere
# in the run log.
#
# Usage:   ./oracle-compare.sh <observations-file> <oracle-csv>
#   observations-file : a litmus7 log, or any file containing Observation lines
#   oracle-csv        : reference CSV the caller supplies, columns
#                       "Litmus,Expected,Model,Source" ('#' comment lines and the
#                       header row are skipped).  This branch ships none for the
#                       het corpus and derives none, so the argument is the whole
#                       supply (docs/oracle-harness.md).
#
# THE MISMATCH SENTENCE (PORT2-R2-amd-oracle.md sect 9.2 as amended by P2e).  A
# forbidden outcome seen is a disagreement between a RUN and a DERIVATION, and
# the derivation is the nearer of the two candidate culprits: no row of a
# derived oracle is a hardware measurement.  So the note says so unconditionally
# and points the reader at the row's own Source column.  There is no grade: P2e
# removed the provenance column and the two-key rule that produced it.
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
# het_stats_print, whose second field ends in ":" and which is REPRINTED VERBATIM:
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
        # sect 9.2 as amended by P2e: one sentence, and it names the nearer
        # candidate culprit.  The oracle row is a derivation, not a measurement.
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
    printf "OVERLAPPING frames per N iterations (PerpLE VI-B.1), so a frame count fed into\n"
    printf "the 1-e^{-n} recipe returns ~1 VACUOUSLY.\n\n"

    ndis = 0; ndis_fired = 0; nvoid = 0; nvac = 0
    for (si = 0; si < nstats; si++) {
      t = sorder[si]
      # THE CLASS COMES FROM THE CSV, never from the log: the harness carries no
      # prediction and prints none, so a roll-up that read one off a run line
      # would be reading a field that no longer exists (and, before A2, one the
      # emitter put there).  A test the CSV does not cover has no class here.
      orc = (t in orac) ? orac[t] : "-"
      ob = S[t, "obs"]; pb = S[t, "p_bound"] + 0

      if (orc == "Disallowed") { ndis++; if (ob != "Never" && ob != "VOID") ndis_fired++ }
      if (ob == "VOID") nvoid++
      # The bounded rate is a PROBABILITY, so a bound at or above 1 bounds nothing --
      # the same test the harness prints the null under.
      if (ob == "Never" && pb >= 1) nvac++

      printf "%s : %s   oracle=%s\n", t, (t in resmap) ? resmap[t] : "-", orc
      if (nblk[t] + 0 == 0)
        printf "  (this log carries the HetStats data line but not the het_stats_print block)\n"
      for (bi = 0; bi < nblk[t]; bi++) printf "%s\n", block[t, bi]
      printf "\n"
    }
    # ---- the campaign-level NEGATIVE CONTROL (Q3 R4-iii; PerpLE VII-A). ------
    # PerpLE co-runs forbidden tests and confirms they stay at zero.  The same
    # assurance across this campaign comes from the oracle-Disallowed rows: if the
    # decoder invented cycles, they are where it would show.
    printf "---------------------------------------------------------------------\n"
    printf "NEGATIVE CONTROL (campaign-level): %d of %d should-be-FORBIDDEN test(s) fired.\n", \
           ndis_fired, ndis
    if (ndis == 0)
      printf "  (no Disallowed tests in this log -- the decoder is NOT vouched for here.)\n"
    else if (ndis_fired == 0)
      printf "  The decoder does not generate false positives on this run:\n    \"PerpLE%s failure to observe these forbidden outcomes can be viewed as a\n     reassurance that PerpLE does not generate false positives.\"  -- PerpLE VII-A.\n", "'\''s"
    else
      printf "  *** A FORBIDDEN OUTCOME FIRED.  Either this oracle row is wrong (it is a\n      DERIVATION over cited sources, not a measurement) or the DECODER is unsound, in\n      which case every null in this campaign is void.  The SIGHTING TIER above is what\n      tells an artefact from a real observation: an artefact does not reproduce across\n      re-seeded runs.  Do not report either way until it is settled.\n"
    if (nvoid > 0)
      printf "VOID: %d row(s) came from a harness that was never demonstrably hot -- DISCARDED.\n", nvoid
    if (nvac > 0)
      printf "VACUOUS: %d null(s) bound their rate at >= 1, i.e. at nothing.  Grow R (Q3 F4).\n", nvac
    printf "---------------------------------------------------------------------\n"
  }

  if (nmis > 0) exit 1
}
' "$OBS"
