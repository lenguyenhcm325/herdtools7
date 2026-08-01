Layer-1 exhaustive spec of oracle-compare.sh's decision logic (no golden covers
it; the forall quantifier inversion is subtle -- see TEST-PLAN.md sec 4).  The
frozen fixtures obs.txt + oracle.csv drive the FULL 6-cell matrix
{MATCH, MISMATCH, NO-ORACLE} x {exists, forall} in a single run.  A MISMATCH
(forbidden outcome observed) makes the harness exit 1 -- that nonzero `[1]' is
part of the frozen expectation, proving the CI gate bites.

  $ bash ../../oracle-compare.sh obs.txt oracle.csv
  Oracle:       oracle.csv
  Observations: obs.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT     NOTE
  ----           -----   --------   ------       -----          ------     ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH      relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH   FORBIDDEN OUTCOME SEEN
  LB-sys         exists  Never      -            -              NO-ORACLE  not in this oracle (GH200/PTX?)
  SB-sys-fa      forall  Sometimes  Disallowed   PTX            MATCH      forbidden, not seen
  MP-sys-fa      forall  Never      Disallowed   PTX            MISMATCH   FORBIDDEN OUTCOME SEEN
  LB-sys-fa      forall  Sometimes  -            -              NO-ORACLE  not in this oracle (GH200/PTX?)
  
  6 test(s): 2 MATCH, 2 MISMATCH, 2 NO-ORACLE
  [1]

The STATISTICS section, which the matrix above never reaches: obs.txt carries no
HetStats lines, so it prints the table alone.  obs-stats.txt does carry them --
printed by het_verdict.h itself over five synthetic record streams, one per
reporting path -- and drives the section end to end.

  $ bash ../../oracle-compare.sh obs-stats.txt oracle-stats.csv > stats.out
  [1]
  $ sed -n '4,10p' stats.out
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT     NOTE
  ----           -----   --------   ------       -----          ------     ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH      relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH   FORBIDDEN OUTCOME SEEN
  SB-sys-2s      exists  Never      Disallowed   CMCM           MATCH      forbidden, not seen
  MP-sys-2s      exists  Never      Disallowed   CMCM           MATCH      forbidden, not seen
  LB-sys         exists  Never      -            -              NO-ORACLE  not in this oracle (GH200/PTX?)

Each test is headed by its result from that table, and the block underneath is
het_stats_print's own output, reprinted verbatim.
  $ grep -E '^(SB|MP|LB)-sys[^ ]* : ' stats.out
  SB-sys : MATCH   oracle=Allowed
  MP-sys-F : MISMATCH   oracle=Disallowed
  SB-sys-2s : MATCH   oracle=Disallowed
  MP-sys-2s : MATCH   oracle=Disallowed
  LB-sys : NO-ORACLE   oracle=NO-ORACLE
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
