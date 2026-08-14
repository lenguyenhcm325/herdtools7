Layer-1 byte-freeze of ptxcheck.py's discriminating power (belt-and-suspenders;
the eyeball gap is already closed in the gated verify/tokens.sh selftest, see
TEST-PLAN.md sec 4).  corrupt-strengthen.ptx is a committed, frozen PTX in which
the single relaxed load of MP-sys-F (`ld.relaxed.sys') was strengthened to
`ld.acquire.sys'.  The checker must catch the one-token deviation and FAIL (exit
1) -- with NO GPU and NO nvcc, because --ptx feeds the frozen text directly.

  $ python3 ../../verify/ptxcheck.py ../gpu-only/MP-sys-F.litmus --ptx corrupt-strengthen.ptx -q
  RESULT: FAIL
  [1]
