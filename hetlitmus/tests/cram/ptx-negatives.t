ptxcheck.py fails when the PTX has an acquire load where the test has a relaxed one.
  $ python3 ../../verify/ptxcheck.py MP-sys-F.litmus --ptx corrupt-strengthen.ptx
  === MP-sys-F [LISA] ===
  FAIL: GPU ordered model-op stream differs
    [3] expected ld.relaxed.sys         observed ld.acquire.sys           <<< MISMATCH
  RESULT: FAIL
  [1]
