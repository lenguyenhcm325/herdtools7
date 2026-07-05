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
