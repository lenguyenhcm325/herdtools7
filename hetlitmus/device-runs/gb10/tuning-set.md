# GB10 stress-tuning set

Tests of the AArch64 het corpus, used by `runbook.sh` section 4.

## Why these rows

For each row, `tune_stress.py rank` finds the configuration that produced the row's weak outcome
most often per second; these per-row winners are the configurations the campaign runs. A row
therefore helps only if some configuration reveals its weak outcome. The rows were chosen so that:

1. each has shown its weak outcome on the GB10,
2. each should fire neither too often nor too rarely, since a saturated or a silent row scores every
   configuration alike, and
3. together they cover as many shapes, device cuts, scopes and orders as such rows allow.

## Coverage

| Property | Rows |
|---|---|
| 2 threads | MP-cg, MP-gc, LB-cg, SB-cg (both), S-gc |
| 3 threads | ISA2-gcc, ISA2-ccg, WRC-cgc, RWC-ccg |
| 4 threads | IRIW-cgcg, IRIW-ccgc |
| 2 GPU threads | IRIW-cgcg (all others have 1) |
| `sys` scope | all but MP-gc, S-gc and SB-cg-gpu |
| `gpu` scope | MP-gc-gpu-plain.rel, SB-cg-gpu-plain.fsc |
| `cta` scope | S-gc-cta-plain.rel |
| CPU `DMB SY` | SB-cg-sys-sy.facq (all others plain) |
| GPU `rel` | MP-gc-gpu-plain.rel, S-gc-cta-plain.rel |
| GPU `facq` | SB-cg-sys-sy.facq |
| GPU `fsc` | SB-cg-gpu-plain.fsc |
| GPU `rlx` | the other 8 rows |
