Layer-1 exhaustive spec of oracle-compare.sh's decision logic (no golden covers
it; the forall quantifier inversion is subtle -- see TEST-PLAN.md sec 4).  The
frozen fixtures obs.txt + oracle.csv drive the FULL matrix
{MATCH, MISMATCH, NO-ORACLE, UNINTERPRETED} x {exists, forall} in a single run.
A MISMATCH (forbidden outcome observed) makes the harness exit 1 -- that nonzero
`[1]' is part of the frozen expectation, proving the CI gate bites.

The last two rows are the 2026-08-02 (P2a) split that
env-research/PORT2-R2-amd-oracle.md sect 1.3 demands: a test the oracle HAS and
declines to decide (WS-sys, EARNED model silence) must not read the same as a
test the oracle does not have at all (the LB rows).  Aliasing them is how an
MI300X run -- which has no oracle by design, so every row is absent -- would have
printed as model silence.  BOGUS-sys carries a verdict string the harness does
not know: that is a corrupt oracle and it fails closed to UNINTERPRETED, never to
a pass.  Before the fix, a CSV verdict of NO-ORACLE ALSO fell into that arm and
printed `unknown oracle verdict "NO-ORACLE"' -- expected-nvidia.csv carries 76
such rows (42 until NVOR demoted 32 more on 2026-08-06 and its Phase-D3 repair 2
more the same day), so the harness misreported both shipped oracles.

  $ bash ../../oracle-compare.sh obs.txt oracle.csv
  Oracle:       oracle.csv
  Observations: obs.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH          relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  LB-sys         exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  SB-sys-fa      forall  Sometimes  Disallowed   PTX            MATCH          forbidden, not seen
  MP-sys-fa      forall  Never      Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  LB-sys-fa      forall  Sometimes  -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  WS-sys         exists  Sometimes  NO-ORACLE    PTX            NO-ORACLE      model silence: this oracle makes no claim here
  BOGUS-sys      exists  Never      ?            -              UNINTERPRETED  unknown oracle verdict "Perhaps"
  
  8 test(s): 2 MATCH, 2 MISMATCH, 1 NO-ORACLE, 3 UNINTERPRETED
  [1]

The STATISTICS section, which the matrix above never reaches: obs.txt carries no
HetStats lines, so it prints the table alone.  obs-stats.txt does carry them --
printed by het_verdict.h itself over five synthetic record streams, one per
reporting path -- and drives the section end to end.  The harness prints no
verdict class of its own, so every ORACLE column below is read from the CSV.

  $ bash ../../oracle-compare.sh obs-stats.txt oracle-stats.csv > stats.out
  [1]
  $ sed -n '4,10p' stats.out
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH          relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  SB-sys-2s      exists  Never      Disallowed   CMCM           MATCH          forbidden, not seen
  MP-sys-2s      exists  Never      Disallowed   CMCM           MATCH          forbidden, not seen
  LB-sys         exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)

Each test is headed by its result from that table, and the block underneath is
het_stats_print's own output, reprinted verbatim.  LB-sys reads `oracle=-'
because it is ABSENT from the CSV and the run log no longer carries a class of
its own -- the two states the P2a split exists to keep apart.
  $ grep -E '^(SB|MP|LB)-sys[^ ]* : ' stats.out
  SB-sys : MATCH   oracle=Allowed
  MP-sys-F : MISMATCH   oracle=Disallowed
  SB-sys-2s : MATCH   oracle=Disallowed
  MP-sys-2s : MATCH   oracle=Disallowed
  LB-sys : UNINTERPRETED   oracle=-
  $ grep -c '^HetStats [A-Za-z0-9.-]*: ' stats.out
  5

Reprinting is what keeps this section from drifting away from the harness, and
what a null now says is what is pinned here: the two NEVER rows carry all four
sentences of it -- no rate is attached, which control actually vouched, that the
row is characterization and agrees with no model, and the effort behind the zero
-- so a reprint that dropped any of them would show up as a count of 1 rather
than 2.  The vouching sentence names the PER-CELL tier, not the pooled channel
the precheck read, because the two can disagree.
  $ grep -c 'NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL' stats.out
  2
  $ grep -c 'vouched for by' stats.out
  2
  $ grep -c 'these cells are NOT-OBSERVED-MU-HOT' stats.out
  2
  $ grep -c 'CHARACTERIZATION, NEVER VALIDATION' stats.out
  2
  $ grep -c 'effort: [0-9]* run(s)' stats.out
  2

The block is delimited by indentation, so the per-run HetVerdict output around it
does not leak in.
  $ grep -c 'DISCARD this null' obs-stats.txt
  4
  $ grep -c 'DISCARD this null' stats.out || true
  0

What the section adds on top is the campaign-level roll-up: the negative control
over the Disallowed rows, and the count that says a row must not be tabulated.
  $ grep 'NEGATIVE CONTROL (campaign-level)' stats.out
  NEGATIVE CONTROL (campaign-level): 1 of 3 should-be-FORBIDDEN test(s) fired.
  $ grep '^VOID:' stats.out
  VOID: 1 row(s) came from a harness that was never demonstrably hot -- DISCARDED.

The AMD oracle drives the SAME decision logic on a different Model string, and
the mismatch sentence is UNCONDITIONAL (PORT2-R2-amd-oracle.md sect 9.2 as
amended by P2e): no row of either oracle is a hardware measurement, so a
forbidden outcome seen indicts THE ORACLE ROW first, never the compound model.
The three MISMATCH rows below carry three different Source strings and must all
print that one sentence -- a printer that graded them would be visible here,
because the SENTENCE is the deliverable and not the enum.  Nothing in the file
distinguishes them, and nothing may.

  $ bash ../../oracle-compare.sh obs-amd.txt oracle-amd.csv
  Oracle:       oracle-amd.csv
  Observations: obs-amd.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  MP-cg-sys-acquire exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  WRC-ccg-sys-relaxed exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  IRIW-gccc-sys-acquire exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  2+2W-cg-sys-fence exists  Sometimes  NO-ORACLE    AMD-CDNA3-x86  NO-ORACLE      model silence: this oracle makes no claim here
  MP-cg-sys-relaxed exists  Sometimes  Allowed      AMD-CDNA3-x86  MATCH          relaxation seen
  NOT-IN-THE-AMD-ORACLE exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  
  6 test(s): 1 MATCH, 3 MISMATCH, 1 NO-ORACLE, 1 UNINTERPRETED
  [1]
