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
# QUANTIFIER (exists vs forall): litmus reports "Never|Sometimes|Always"
# relative to the test's *validation*, and for a `forall' test it swaps the
# p_true/p_false roles internally (litmus/skelUtil.ml).  So for `forall' the
# meaning of "Never" is the MIRROR IMAGE of `exists': "Never" means the targeted
# predicate held in EVERY execution (no counterexample), whereas for `exists'
# "Never" means it was never witnessed.  The harness therefore recovers the
# quantifier from the litmus "Condition <exists|forall|~exists> (...)" line that
# precedes each Observation and INVERTS which observation counts as "the
# targeted outcome was seen" for forall (`~exists' reads like `exists').  A log
# with no Condition line (e.g. the synthesized sample) defaults to `exists', so
# existing behaviour is unchanged.
#
# B7 -- THE STATISTICS ANNOTATION (Q3 R6: AUGMENT this harness, do not replace it).
#
# Everything above is unchanged: the Observation parse and the MATCH/MISMATCH/NO-ORACLE
# table are byte-for-byte what they were.  What B7 ADDS is a second section, layered on
# top, that reads the `HetStats' lines the harness itself prints (het_verdict.h,
# het_stats_line) and turns each verdict into a QUANTIFIED one:
#
#   * a "Never" stops being a bare "Never".  It carries a 95% upper bound on the
#     behaviour's run-level rate, computed at the (instance,run) CELL -- never at the
#     frame, because the recovery scan validates N^{T_L} overlapping frames per N
#     iterations (PerpLE VI-B.1) and a frame count fed to Kirkham's 1-e^{-n} returns ~1
#     VACUOUSLY.  The bound is dispersion-aware: the rule-of-three constant 3 inflates
#     to ~19 on a geometric channel and ~200 on an extreme one, so a bare p < 3/N would
#     be a ~6x optimistic overclaim (Q3 2.4).
#   * a "Sometimes" carries P_rep = 1 - e^{-k_eff} over NON-DEGENERATE cells.
#   * a COLD run is VOID, not a non-observation.
#   * a MISMATCH carries a CORROBORATION TIER, because a false MISMATCH is a false
#     REFUTATION of the compound model -- the most damaging error this campaign can
#     make -- and Srivastava's constant-read artefact is a real way to forge one.
#     Nothing is ever suppressed: one sighting still refutes.
#
# The annotation only appears when the log actually carries HetStats lines, so a log
# without them (the synthesized samples, the cram fixtures) is handled exactly as before.
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
# strtonum() is a gawk extension; parse the flag word by hand so this stays portable.
function hex2dec(s,   i, c, d, v) {
  sub(/^0[xX]/, "", s); v = 0
  for (i = 1; i <= length(s); i++) {
    c = tolower(substr(s, i, 1)); d = index("0123456789abcdef", c) - 1
    if (d < 0) return v
    v = v * 16 + d
  }
  return v
}
function flag(v, bit) { return int(v / bit) % 2 }
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
  fmt = "%-14s %-7s %-10s %-12s %-14s %-10s %s\n"
  printf fmt, "TEST", "QUANT", "OBSERVED", "ORACLE", "MODEL", "RESULT", "NOTE"
  printf fmt, "----", "-----", "--------", "------", "-----", "------", "----"
  nmatch = 0; nmis = 0; nno = 0
  pending_quant = ""
}
# The litmus "Condition <quant> (...) is [NOT ]validated" line precedes the
# Observation line of its test (litmus/skelUtil.ml); stash the quantifier so the
# next Observation can read it.  "~exists" reads like "exists" (only forall flips).
/^Condition/ {
  pending_quant = ($0 ~ /forall/) ? "forall" : "exists"
  next
}
# B7: the harness prints its own aggregate as a machine-readable line.  Two shapes both
# begin "HetStats " -- the key=value line, and the human block whose second field ends
# in ":".  Only the former is data.
/^HetStats / {
  if ($2 ~ /:$/) next
  t = $2
  for (i = 3; i <= NF; i++) {
    p = index($i, "=")
    if (p > 0) S[t, substr($i, 1, p-1)] = substr($i, p+1)
  }
  if (!(t in seen_stats)) { seen_stats[t] = 1; sorder[nstats++] = t }
  next
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
      if (seen) { result="MISMATCH"; note="FORBIDDEN OUTCOME SEEN" }
      else      { result="MATCH";    note="forbidden, not seen" }
    } else if (verdict == "Allowed") {
      result="MATCH"; note = seen ? "relaxation seen" : "allowed, not exhibited"
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
  resmap[test] = result          # B7: the annotation section reprints it per test
  printf fmt, test, quant, obs, verdict, mdl, result, note
}
END {
  printf "\n%d test(s): %d MATCH, %d MISMATCH, %d NO-ORACLE\n", \
         nmatch+nmis+nno, nmatch, nmis, nno

  # ================= B7: THE STATISTICS ANNOTATION =========================
  # Layered on top of the table above; absent from a log that carries no HetStats.
  if (nstats > 0) {
    printf "\n"
    printf "=====================================================================\n"
    printf "STATISTICS (B7) -- what each verdict is WORTH\n"
    printf "=====================================================================\n"
    printf "The replication unit is the (instance,run) CELL, Y = 1[target_count >= 1].\n"
    printf "It is NOT the frame: the recovery scan validates N^{T_L} OVERLAPPING frames\n"
    printf "per N iterations (PerpLE VI-B.1), so a frame count fed into Kirkham%s\n", "'\''s"
    printf "1-e^{-n} returns ~1 VACUOUSLY -- not because the behaviour reproduces, but\n"
    printf "because the frame combinatorics inflate the count.\n\n"

    ndis = 0; ndis_fired = 0; nvoid = 0; nvac = 0
    for (si = 0; si < nstats; si++) {
      t = sorder[si]
      orc  = S[t, "oracle"];  ob = S[t, "obs"]
      R    = S[t, "R"] + 0;   us = S[t, "usable"] + 0
      k    = S[t, "k"] + 0;   ke = S[t, "k_eff"] + 0
      kr   = S[t, "k_runs"] + 0; dg = S[t, "degen"] + 0
      fw   = S[t, "F_win"] + 0
      fc   = S[t, "F_cell"] + 0
      mu   = S[t, "mu_upper"] + 0
      re   = S[t, "R_eff"] + 0
      pb   = S[t, "p_bound"] + 0
      pr   = S[t, "P_rep"] + 0
      ks   = S[t, "ks"];      ksw = S[t, "ks_split"] + 0
      tier = S[t, "tier"];    ctl = S[t, "ctrl"]
      N    = S[t, "N"];       fr  = S[t, "frames"]
      fl   = hex2dec(S[t, "flags"])

      f_unmeas = flag(fl, 1);   f_nonstat = flag(fl, 2)
      f_degen  = flag(fl, 4);   f_under   = flag(fl, 8)
      f_bursty = flag(fl, 16);  f_nochan  = flag(fl, 32)
      f_desync = flag(fl, 64);  f_kspow   = flag(fl, 128)
      f_trunc  = flag(fl, 256); f_canary  = flag(fl, 512)
      f_vacuous = flag(fl, 1024); f_self   = flag(fl, 2048)
      # A `self canary row co-runs no control, so a run in which it did not fire is COLD
      # and gets discarded -- "usable" is DEFINED BY firing there.  Its denominator must
      # be R, or a canary that fired in 3 runs of 10 reads as ALWAYS (3/3), and that rate
      # is what the whole campaign is calibrated against.
      den = f_self ? R : us
      unit = f_self ? "run" : "cell"

      if (orc == "Disallowed") { ndis++; if (ob != "Never" && ob != "VOID") ndis_fired++ }

      res = (t in resmap) ? resmap[t] : "-"
      printf "%s : %s   oracle=%s\n", t, res, orc

      # ---- observation, at the CELL unit
      if (ob == "Sometimes" || ob == "Always")
        printf "         observation = %s (%d/%d %ss; %d after the decode guard, %d distinct run(s))\n", \
               ob, k, den, unit, ke, kr
      else
        printf "         observation = %s (0/%d %ss)\n", ob, den, unit
      if (f_self)
        printf "                       (co-runs NO control -- it IS the canary -- so a run in which it did\n                       not fire is COLD and discarded.  Denominator is R, not usable cells.)\n"

      # ---- the liveness gate.  A COLD harness is VOID, not a non-observation.
      if (ob == "VOID") {
        nvoid++
        printf "         control     = COLD  ->  VOID (UNINTERPRETABLE)\n"
        printf "                       Not one of the %d runs was usable.  An empty histogram from a\n", R
        printf "                       dead harness is not a non-observation -- it is an absence of data.\n"
        printf "                       DISCARD this row; do not report it as \"not observed\".\n\n"
        continue
      }
      printf "         control     = LIVE (%s channel; %d/%d cells usable, tau_hot gate passed)\n", \
             ctl, us, R

      if (f_desync) {
        printf "         *** THE PER-WINDOW SUB-TALLIES DID NOT SUM TO THE CONTROL TOTAL ***\n"
        printf "                       The window bump is dead or mis-indexed; every dispersion number\n"
        printf "                       below would be fiction.  This is a BUILD BUG, not a result.\n"
      }
      if (f_nochan)
        printf "         *** a cell carried NEITHER a synchrony nor an observer decode (build bug)\n"
      if (f_trunc)
        printf "         *** more runs than HET_STATS_MAX_CELLS: the tail was NOT scored\n"

      # ---- SOMETIMES: reproducibility, at the cell unit, over clean cells only.
      if (ob == "Sometimes" || ob == "Always") {
        if (pr >= 0)
          printf "         P_rep       = 1 - e^-k_eff = %.2f%%  (k_eff = %d NON-DEGENERATE cells)\n", \
                 100 * pr, ke
        else if (f_nonstat)
          printf "         P_rep       = NOT REPORTED -- the control rate is NON-STATIONARY (KS split@%d).\n                       A reproducibility figure must never span a rate change (Q3 R4).\n", ksw
        else
          printf "         P_rep       = NOT REPORTED (no cell survived the decode guard, or the\n                       stationarity of the control could not be tested)\n"
        if (f_degen) {
          printf "         DEGENERATE  : %d sighting(s) came from a cell whose decode never varied\n", dg
          printf "                       (Srivastava%s constant-read artefact: a reader stuck on init or on\n", "'\''s"
          printf "                       one value yields a spurious 100%%/0%%).  They are REPORTED, never\n"
          printf "                       discarded -- falsification is one-sided -- but they do not COUNT\n"
          printf "                       toward corroboration.\n"
        }
        if (orc == "Disallowed") {
          printf "         TIER        = %s\n", tier
          if (tier == "MISMATCH-CONFIRMED")
            printf "                       Seen in %d distinct non-degenerate RUNS.  A decoder artefact does\n                       not reproduce across re-seeded runs: this REFUTES the CMCM%s prediction.\n", kr, "'\''s"
          else
            printf "                       Seen, but in only %d clean run(s) (<3).  BELIEVE IT AND REPORT IT --\n                       one sighting refutes -- but REPRODUCE it to >=3 clean runs before writing\n                       it up as a model violation.  A false MISMATCH is a false refutation.\n", kr
        }
      }

      # ---- NEVER: the false-negative bound.  This is the thesis%s validation claim.
      if (ob == "Never") {
        if (f_unmeas) {
          printf "         *** NO BOUND *** -- the dispersion could not be measured, and the textbook\n"
          printf "                       3/N is NOT substituted for one.  A bound that silently defaults to\n"
          printf "                       Poisson is the rule of three wearing a dispersion-aware hat.\n"
        } else if (f_vacuous) {
          nvac++
          printf "         p_run       < mu_upper/R_eff = %.4g / %.2f = %.4g   >= 1  *** VACUOUS ***\n", mu, re, pb
          printf "                       p_run is a PROBABILITY: a bound above 1 bounds NOTHING.  The control\n"
          printf "                       channel is bursty (F_win=%.2f), so zeros are cheap and this null is\n", fw
          printf "                       not evidence.  Do NOT tabulate the number.  REMEDY: grow R (more\n"
          printf "                       independent runs), NOT N (Q3 F4) -- extra N only adds correlated\n"
          printf "                       frames inside the same few alignment windows.\n"
        } else {
          printf "         p_run       < mu_upper(r_hat)/R_eff = %.4f / %.2f = %.4g   (95%%)\n", mu, re, pb
        }
        if (!f_unmeas) {
          printf "         dispersion  = F_win %.3f", fw
          if (f_bursty)     printf "  BURSTY: the rule-of-three constant 3 WIDENED to %.4g", mu
          else if (f_under) printf "  (under-dispersed: clamped to the Poisson floor, never tightened below 3)"
          printf "   [F_cell %.3f -> DEFF]\n", fc
          if (f_canary)
            printf "                       calibrated off the Layer-B CANARY, not this test%s own mu(T): a\n                       different SHAPE%s burstiness, so a weaker claim.\n", "'\''s", "'\''s"
          if (ks == "pass")
            printf "         stationarity= KS_pass\n"
          else if (ks == "SPLIT")
            printf "         stationarity= KS_split@%d  *** the control rate CHANGED mid-run.  Re-run split\n                       at the change-point and score the segments separately (Kirkham 5.1).\n", ksw
          else
            printf "         stationarity= NOT TESTED (underpowered) -- fails closed\n"
        }
        printf "         effort      = %d run(s) x N=%s iterations, %s frames examined\n", us, N, fr
        # What the null is a claim ABOUT depends entirely on the oracle class.
        if (orc == "Disallowed")
          printf "                       => CMCM VALIDATION: forbidden, and not observed under that effort.\n                          Consistency evidence, NOT a proof.\n"
        else if (orc == "Allowed")
          printf "                       => OBSERVABILITY, not validation: the outcome is PERMITTED, so this\n                          bounds OUR HARNESS%s reach, not the model.  Feeds B8.\n", "'\''s"
        else
          printf "                       => CHARACTERIZATION, never validation: the model is SILENT here.\n"
      }
      printf "\n"
    }

    # ---- THE CAMPAIGN-LEVEL NEGATIVE CONTROL (Q3 R4-iii; PerpLE VII-A). ------
    # PerpLE co-runs FORBIDDEN tests and confirms they stay at zero.  We get the same
    # assurance across the campaign from the 16 oracle-Disallowed rows: if the decoder
    # invented cycles, they are where it would show.
    printf "---------------------------------------------------------------------\n"
    printf "NEGATIVE CONTROL (campaign-level): %d of %d should-be-FORBIDDEN test(s) fired.\n", \
           ndis_fired, ndis
    if (ndis == 0)
      printf "  (no Disallowed tests in this log -- the decoder is NOT vouched for here.)\n"
    else if (ndis_fired == 0)
      printf "  The decoder does not generate false positives on this run:\n    \"PerpLE%s failure to observe these forbidden outcomes can be viewed as a\n     reassurance that PerpLE does not generate false positives.\"  -- PerpLE VII-A.\n", "'\''s"
    else
      printf "  *** A FORBIDDEN OUTCOME FIRED.  Either the CMCM is REFUTED (a result -- see the\n      corroboration tier above) or the DECODER is unsound, in which case every null in\n      this campaign is void.  The tier is what tells them apart: an artefact does not\n      reproduce across re-seeded runs.  Do not report either way until it is settled.\n"
    if (nvoid > 0)
      printf "VOID: %d row(s) came from a harness that was never demonstrably hot -- DISCARDED.\n", nvoid
    if (nvac > 0)
      printf "VACUOUS: %d null(s) bound their rate at >= 1, i.e. at nothing.  Grow R (Q3 F4).\n", nvac
    printf "---------------------------------------------------------------------\n"
  }

  if (nmis > 0) exit 1
}
' "$OBS"
