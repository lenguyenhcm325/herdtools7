hetlitmus/docs/faithfulness.md

The one place ptxcheck.py must reject: MP-sys-F's frozen PTX with its single
`ld.relaxed.sys' strengthened to `ld.acquire.sys', read back with no nvcc.
  $ python3 ../../verify/ptxcheck.py ../gpu-only/MP-sys-F.litmus --ptx corrupt-strengthen.ptx
  === MP-sys-F [LISA] ===
  FAIL: GPU ordered model-op stream differs
    [3] expected ld.relaxed.sys         observed ld.acquire.sys           <<< MISMATCH
    no stray system-scope ops outside the model-op stream
  RESULT: FAIL
  [1]
