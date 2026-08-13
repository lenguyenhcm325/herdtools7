Layer-1 exhaustive spec of oracle-compare.sh's decision logic (no golden covers
it; the forall quantifier inversion is subtle -- see TEST-PLAN.md sec 4).  The
frozen fixtures obs.txt + oracle.csv drive the FULL matrix
{MATCH, MISMATCH, NO-ORACLE, UNINTERPRETED} x {exists, forall} in a single run --
nine rows over the eight cells.
Both hand-authored pairs (obs.txt + oracle.csv, obs-amd.txt + oracle-amd.csv) are
invented throughout -- every name, verdict, Source and count -- so no row of
either is a claim about any real test, and the FX-/FXB- prefixes are there so
none can be read as one.  oracle-stats.csv, which the STATISTICS section below
uses, is the one fixture not like that; its own header says how.
FX-silent-forall is deliberately past the 14-column TEST field, because real test
names routinely overflow it and a fixture whose names all fitted would stop
pinning how the table renders when they do not.
A MISMATCH (forbidden outcome observed) makes the harness exit 1 -- that nonzero
`[1]' is part of the frozen expectation, proving the CI gate bites.

FX-silent, FX-silent-forall and the FX-absent rows are the 2026-08-02 (P2a)
split: a test the oracle HAS and declines to decide (EARNED model silence) must
not read the same as a test the oracle does not have at all.  Aliasing them is how
a run against a CSV that covers none of its tests -- every row absent -- would
print as model silence.  FX-corrupt carries a verdict string the harness does
not know: that is a corrupt oracle and it fails closed to UNINTERPRETED, never to
a pass.  A CSV verdict of NO-ORACLE must not reach that same arm, or an oracle
that declined to decide a row would have its silence reported as
`unknown oracle verdict "NO-ORACLE"'.

  $ bash ../../oracle-compare.sh obs.txt oracle.csv
  Oracle:       oracle.csv
  Observations: obs.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  FX-match-ex    exists  Sometimes  Allowed      FIXTURE        MATCH          relaxation seen
  FX-mismatch-ex exists  Sometimes  Disallowed   FIXTURE        MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  FX-absent-ex   exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  FX-match-fa    forall  Sometimes  Disallowed   FIXTURE        MATCH          forbidden, not seen
  FX-mismatch-fa forall  Never      Disallowed   FIXTURE        MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  FX-absent-fa   forall  Sometimes  -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  FX-silent      exists  Sometimes  NO-ORACLE    FIXTURE        NO-ORACLE      model silence: this oracle makes no claim here
  FX-silent-forall forall  Sometimes  NO-ORACLE    FIXTURE        NO-ORACLE      model silence: this oracle makes no claim here
  FX-corrupt     exists  Never      ?            -              UNINTERPRETED  unknown oracle verdict "Perhaps"
  
  9 test(s): 2 MATCH, 2 MISMATCH, 2 NO-ORACLE, 3 UNINTERPRETED
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

The second hand-authored pair runs the same decision logic over a differently
shaped CSV, and pins the mismatch sentence as UNCONDITIONAL: no row of a
supplied oracle is a hardware measurement, so a forbidden outcome seen indicts
that oracle row first, never the compound model.  The three MISMATCH rows below
carry three different Source strings and must all print that one sentence -- a
printer that graded them would be visible here, because the SENTENCE is the
deliverable and not the enum.  Nothing in the file distinguishes them, and
nothing may.

  $ bash ../../oracle-compare.sh obs-amd.txt oracle-amd.csv
  Oracle:       oracle-amd.csv
  Observations: obs-amd.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
  ----           -----   --------   ------       -----          ------         ----
  FXB-mism-1     exists  Sometimes  Disallowed   FIXTURE        MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  FXB-mism-2     exists  Sometimes  Disallowed   FIXTURE        MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  FXB-mism-3     exists  Sometimes  Disallowed   FIXTURE        MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
  FXB-silent     exists  Sometimes  NO-ORACLE    FIXTURE        NO-ORACLE      model silence: this oracle makes no claim here
  FXB-match      exists  Sometimes  Allowed      FIXTURE        MATCH          relaxation seen
  FXB-absent     exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
  
  6 test(s): 1 MATCH, 3 MISMATCH, 1 NO-ORACLE, 1 UNINTERPRETED
  [1]
