Layer-1 byte-freeze of ptxcheck.py's discriminating power: the one place the
checker is required to reject, so a checker that passed everything would be
caught here.  corrupt-strengthen.ptx is a committed, frozen PTX in which the
single relaxed load of MP-sys-F (`ld.relaxed.sys') was strengthened to
`ld.acquire.sys'.  Fed back through --ptx, the checker must catch the one-token
deviation and FAIL (exit 1) -- with NO GPU and NO nvcc, because --ptx reads the
frozen text directly.

  $ python3 ../../verify/ptxcheck.py ../gpu-only/MP-sys-F.litmus --ptx corrupt-strengthen.ptx -q
  RESULT: FAIL
  [1]
