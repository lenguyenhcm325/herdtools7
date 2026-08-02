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
printed `unknown oracle verdict "NO-ORACLE"' -- expected-nvidia.csv carries 42
such rows, so the harness misreported both shipped oracles.

  $ bash ../../oracle-compare.sh obs.txt oracle.csv
  Oracle:       oracle.csv
  Observations: obs.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH          relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN
  LB-sys         exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  SB-sys-fa      forall  Sometimes  Disallowed   PTX            MATCH          forbidden, not seen
  MP-sys-fa      forall  Never      Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN
  LB-sys-fa      forall  Sometimes  -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  WS-sys         exists  Sometimes  NO-ORACLE    PTX            NO-ORACLE      model silence: this oracle makes no claim here
  BOGUS-sys      exists  Never      ?            -              UNINTERPRETED  unknown oracle verdict "Perhaps"
  
  8 test(s): 2 MATCH, 2 MISMATCH, 1 NO-ORACLE, 3 UNINTERPRETED
  [1]

The STATISTICS section, which the matrix above never reaches: obs.txt carries no
HetStats lines, so it prints the table alone.  obs-stats.txt does carry them --
printed by het_verdict.h itself over five synthetic record streams, one per
reporting path -- and drives the section end to end.

  $ bash ../../oracle-compare.sh obs-stats.txt oracle-stats.csv > stats.out
  [1]
  $ sed -n '4,10p' stats.out
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH          relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN
  SB-sys-2s      exists  Never      Disallowed   CMCM           MATCH          forbidden, not seen
  MP-sys-2s      exists  Never      Disallowed   CMCM           MATCH          forbidden, not seen
  LB-sys         exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)

Each test is headed by its result from that table, and the block underneath is
het_stats_print's own output, reprinted verbatim.
  $ grep -E '^(SB|MP|LB)-sys[^ ]* : ' stats.out
  SB-sys : MATCH   oracle=Allowed
  MP-sys-F : MISMATCH   oracle=Disallowed
  SB-sys-2s : MATCH   oracle=Disallowed
  MP-sys-2s : MATCH   oracle=Disallowed
  LB-sys : UNINTERPRETED   oracle=NO-ORACLE
  $ grep -c '^HetStats [A-Za-z0-9.-]*: ' stats.out
  5

Reprinting is what keeps this section from drifting away from the harness, and
the two things a re-implementation got wrong are pinned here: the within-run
correlation reading is VISIBLE (it is dropped by anything that decodes only the
flag bits below it), and the bound is labelled per EFFECTIVE SAMPLE with the
run-level bound printed beside it, not in place of it.
  $ grep -c 'within-run correlation' stats.out
  4
  $ grep -c 'tau IS NOT RESOLVED' stats.out
  1
  $ grep -c 'rate PER EFFECTIVE SAMPLE' stats.out
  1
  $ grep -c 'implied RUN-level bound' stats.out
  1

The block is delimited by indentation, so the per-run HetVerdict output around it
does not leak in.
  $ grep -c 'DISCARD this null' obs-stats.txt
  4
  $ grep -c 'DISCARD this null' stats.out || true
  0

What the section adds on top is the campaign-level roll-up: the negative control
over the Disallowed rows, and the two counts that say a row must not be tabulated.
  $ grep 'NEGATIVE CONTROL (campaign-level)' stats.out
  NEGATIVE CONTROL (campaign-level): 1 of 3 should-be-FORBIDDEN test(s) fired.
  $ grep '^VOID:' stats.out
  VOID: 1 row(s) came from a harness that was never demonstrably hot -- DISCARDED.
  $ grep '^VACUOUS:' stats.out
  VACUOUS: 1 null(s) bound their rate at >= 1, i.e. at nothing.  Grow R (Q3 F4).

The 5-column AMD form of the oracle CSV carries the provenance GRADE in field 4,
and PORT2-R2-amd-oracle.md sect 9.2 makes the verdict printer switch its mismatch
sentence on it: only `artifact' is full strength, i.e. reportable as a candidate
refutation of the compound memory model.  The three MISMATCH rows below are the
SAME observation and differ ONLY in column 4, so the SENTENCE is the deliverable
-- reading the enum would not catch a printer that ignores the grade.  The
4-column NVIDIA form has no grade and prints the unqualified sentence, which is
the block at the top of this file.

  $ bash ../../oracle-compare.sh obs-amd.txt oracle-amd.csv
  Oracle:       oracle-amd.csv
  Observations: obs-amd.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  MP-cg-sys-acquire exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- full strength: CANDIDATE CMCM REFUTATION
  WRC-ccg-sys-relaxed exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- capped (derived): indicts THIS ORACLE ROW first not the CMCM
  IRIW-gccc-sys-acquire exists  Sometimes  Disallowed   AMD-CDNA3-x86  MISMATCH       FORBIDDEN OUTCOME SEEN -- capped (decision): indicts THIS ORACLE ROW first not the CMCM
  2+2W-cg-sys-fence exists  Sometimes  NO-ORACLE    AMD-CDNA3-x86  NO-ORACLE      model silence: this oracle makes no claim here
  MP-cg-sys-relaxed exists  Sometimes  Allowed      AMD-CDNA3-x86  MATCH          relaxation seen
  NOT-IN-THE-AMD-ORACLE exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  
  6 test(s): 1 MATCH, 3 MISMATCH, 1 NO-ORACLE, 1 UNINTERPRETED
  [1]
