B6 regression guard: the positive-control wiring.

Every "Never" this harness prints is uninterpretable unless a known-ALLOWED weak
behaviour fired on the same run, on the same C2C path, under the same stress.  This
guards the four pieces that make that true -- and, above all, the two ways it could
go quietly wrong: a null reported as credible while no control is compiled in, and
a `not measured' exhaustive count read as a `measured zero'.

The control names come from tests/het/control-map.csv, which is DERIVED from the
corpus + the oracle (controlmap.py) -- never from the test's name.  mu(MP-cg-*) is
an -acquire variant because MP-cg's GPU proc reads; mu(MP-gc-*) is a -release
variant because MP-gc's GPU proc writes, and MP-gc-sys-acquire does not exist at
all.  A name-rewriting map would silently point 2 of the 16 at a nonexistent test.

  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME "MP-cg-sys-acquire"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The gc mirror: the GPU produces, so the mutant keeps the GPU's RELEASE.
  $ litmus7 -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME "MP-gc-sys-release"' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1

THE LOUD SENTINEL.  B6a wires the map, the record, the rule and the report; the
multi-instance emitter that actually CO-RUNS mu(T) is B6b.  Until it lands the
control count is STRUCTURALLY zero, so the flag must say so and het_verdict() must
refuse to call any null credible.  A silently-absent control does not weaken a null,
it makes it unfalsifiable -- so this is the one value that must never drift to 1
without the co-run emitter behind it.
  $ grep -c '#define HET_CONTROL_COMPILED_IN 0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'NO CONTROL COMPILED INTO THIS' MP-cg-sys-acqrel-2s/het_verdict.h
  1

The record carries both control channels + the Kirkham reproducibility score, and
the verdict is PRINTED by the harness itself -- the interpretation travels with the
number rather than living in a note in the thesis.
  $ grep -c '_rec.control_Prep = 1.0 - exp' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'het_verdict_print(stdout' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

EXHAUSTIVE_VALID IS A VALIDITY FLAG, NOT A FORMALITY.  It was set to
(SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX) for every test -- which at the default
N=100000 is 0 for ALL 338, while a T_L<=1 test decodes every frame exactly and
counts unconditionally.  Left that way, B6's rule (which refuses a credible null
unless the flag is 1) would have called every run COLD forever: a decision rule that
always says the same thing.

MP has no windowed proc (T_L<=1): the O(N) scan IS the ground truth at any N.
  $ grep -c '_rec.exhaustive_valid = 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

SB's second reader has no rf anchor (T_L>=2): its count only exists if the
O(N^T_L) search actually ran, so there the flag stays honest about the cap.
  $ litmus7 -o . ../het/SB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c '_rec.exhaustive_valid = _exh;' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1

THE REPORTING TIER IS NOT THE MECHANISM TIER.  R and S are both mechanically
ADVISORY (one ws-location + a register), but S's read is an rf read -- a real
synchrony anchor -- while R has ZERO rf edges: its only read is the fr-against-init,
which in the WEAK case returns init, tag 0, so it decodes no writer and no
synchrony.  R borrows both its synchrony point and its ws edge from the fragile
observer, exactly like 2+2W, and is demoted for REPORTING only.

  $ litmus7 -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' R-cg-sys-fence/R-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_EXPLORATORY;

  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' S-cg-sys-fence/S-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_ADVISORY;

An Allowed row is not a forbidden test, so it gets no Layer-A mutant -- but it still
gets the Layer-B canary, because a NO-ORACLE/Allowed observation is only meaningful
against a demonstrably hot harness (it is characterization, never validation).
  $ grep -c 'HET_MU_NAME NULL' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' S-cg-sys-fence/S-cg-sys-fence.cu
  1

The GPU-only path never sees any of this (the whole B6 layer is het-only).
  $ litmus7 -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -cE 'HET_CONTROL_COMPILED_IN|het_verdict|control_target_count' MP-sys-acquire.cu || true
  0
