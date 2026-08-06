Positive-control guard (B6; hetlitmus/docs/positive-control.md).  Every "Never"
this harness prints is uninterpretable unless a known-ALLOWED weak behaviour
fired on the same run, on the same C2C path, under the same stress.  This file
pins the pieces that make that true, and above all the two ways it can go quietly
wrong: a null reported as credible while no control is actually co-running, and a
`not measured' exhaustive count read as a `measured zero'.

The control names come from tests/het/control-map.csv, which is derived from the
corpus plus the oracle (controlmap.py), never rewritten from the test's name.
mu(MP-cg-*) is an -acquire variant because MP-cg's GPU proc reads; mu(MP-gc-*) is
a -release variant because MP-gc's GPU proc writes -- and MP-gc-sys-acquire does
not exist at all, so a name-rewriting map would point rows at a nonexistent test.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME "MP-cg-sys-acquire"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The gc mirror -- the GPU produces, so the mutant keeps the GPU's RELEASE -- used
to be pinned here on MP-gc-sys-acqrel-2s.  The NVOR regeneration (Nguyen
2026-08-06; env-research/NVOR-register.md) DECLINED to register the symmetric
meet, so every gc-cut Disallowed row is NO-ORACLE and no gc row carries a
Layer-A control any more.  What is pinned instead is that the demotion reached
the EMITTED harness: no mutant, control not compiled in, class ORACLE_NONE.  A
demotion that stopped at the CSV would leave the harness still claiming a
refutable prediction.
  $ litmus7 -gpu-target cuda -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME NULL' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1
  $ grep -c '#define HET_CONTROL_COMPILED_IN 0' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1
  $ grep -c '_rec.het_oracle = ORACLE_NONE;' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1

HET_CONTROL_COMPILED_IN=1 is the highest-stakes value in the codebase: it says a
real mu(T) (Layer A) is CO-RUNNING in this launch, so a null may be read against
it.  Flip it without the co-run behind it and every "Never" silently becomes a
*credible* "Never" -- an unfalsifiable null that reads as confirmation of the
compound model.  Everything below exists to make the 1 true, not merely present.

  $ grep -c '#define HET_CONTROL_COMPILED_IN 1' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The Layer-B canary rides a SEPARATE flag rather than widening this one.  "A
canary is co-running" and "the minimal mutant of this test is co-running" are
different claims, and only the second licenses a credible null; collapsed into
one bit, a null on a test that has no mutant at all would start reading as
vouched-for.  So the Layer-A guard is exactly the 18 Disallowed tests, and a
canary-only harness says so in its own flag.
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME NULL' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c '#define HET_CONTROL_COMPILED_IN 0' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c '#define HET_CANARY_COMPILED_IN 1' S-cg-sys-fence/S-cg-sys-fence.cu
  1

...and the canary really is IN there, not merely named: its own instance, its own
K, its own recovery scan feeding its own channel.  A name is not a co-run -- the
map names a canary for all 411 rows -- so both are checked.
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c 'recovery scan: MP-cg-sys-relaxed' S-cg-sys-fence/S-cg-sys-fence.cu
  1
The canary's count and its per-window sub-tally are bumped on ONE line under ONE
predicate.  That pairing is what makes `sum(canary_win[]) == canary_target_count'
an invariant, and that invariant is the only run-time evidence that the
sub-tallies are alive at all (het_stats_compute raises HET_ST_WIN_DESYNC when it
breaks).  Pin the pair, not just the count: a window bump that drifted onto its
own line under its own condition could silently stop tracking.  (B7;
statistics.t.)

  $ grep -c 'if (_weak) { _rec.canary_target_count++; _rec.canary_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -cE '^#define CAN_K_TAG 3' S-cg-sys-fence/S-cg-sys-fence.cu
  1

THE ORACLE CLASS.  het_verdict() must know which of the three classes a harness
is in, because the sentence it prints differs: on a Disallowed test a sighting
refutes the model's prediction; on an oracle-Allowed test the weak outcome is
expected, and seeing it confirms the model is not over-strong; a NO-ORACLE row
claims neither.  Only 18 of the 411 rows are Disallowed -- 319 are Allowed and 74
are NO-ORACLE -- so a harness that framed every test as should-be-forbidden would
put 393 loud false refutations on the table.  Each class carries its own tag,
read from control-map.csv field 2, and the emitter never falls back to a default.
  $ litmus7 -gpu-target cuda -o . ../het/IRIW-cgcg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -h '_rec.het_oracle' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu S-cg-sys-fence/S-cg-sys-fence.cu IRIW-cgcg-sys-fence-2s/IRIW-cgcg-sys-fence-2s.cu
      _rec.het_oracle = ORACLE_DISALLOWED;
      _rec.het_oracle = ORACLE_ALLOWED;
      _rec.het_oracle = ORACLE_NONE;

ORACLE_UNSET IS 0 SO THAT A FORGOTTEN TAG FAILS LOUD.  het_obs_record is
memset(0) before it is filled, so the zero value is what an emitter that skipped
the field would produce.  Had DISALLOWED been 0, that omission would silently
restore the false refutation.  It is the first enumerator, and het_verdict()
fails closed on it.
  $ grep -c 'ORACLE_UNSET = 0,' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'if (r->het_oracle == ORACLE_UNSET) {' MP-cg-sys-acqrel-2s/het_verdict.h
  1

THE SHARPEST INSTANCE: THE CANARY ITSELF.  MP-cg-sys-relaxed is oracle-Allowed
and is the Layer-B canary for 335 rows of control-map.csv.  It cannot co-run
itself (the map says `self'), so both flags are 0 and it stays single-instance --
while being the one test whose entire job is to fire.  It names itself as its
canary, which is how het_verdict.h tells "this test IS the canary" (designed)
from "the canary went missing" (a bug).
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -E '^#define HET_(CONTROL|CANARY)_COMPILED_IN' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_CONTROL_COMPILED_IN 0
  #define HET_CANARY_COMPILED_IN 0
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_rec.het_oracle = ORACLE_ALLOWED;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

THREE INSTANCES, THREE K's.  K is 3 for MP/SB/LB but 4 for R/S (three stores, not
two), and the canary is always an MP -- so every R/S control harness genuinely
mixes K=4 and K=3 in one translation unit.  A single TU-wide K_TAG would decode
one instance's tags with the other's modulus: wrong writer (tag % K), wrong
iteration (tag / K), fictional cycles, and no structural gate could see it.

  $ grep -E '^#define (T|MU|CAN)_K_TAG' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  #define T_K_TAG   3   /* MP-cg-sys-acqrel-2s (T) */
  #define MU_K_TAG  3   /* MP-cg-sys-acquire (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

The S/R class is where the K's actually differ:
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -E '^#define (T|MU|CAN)_K_TAG' S-cg-sys-fence-2s/S-cg-sys-fence-2s.cu
  #define T_K_TAG   4   /* S-cg-sys-fence-2s (T) */
  #define MU_K_TAG  4   /* S-cg-sys-fence (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

NPART IS A SUM, NOT A CONSTANT.  S and R carry observer lanes (1 GPU + 1 CPU), so
their instances are NPART 4, not 2 -- an S/R co-run harness is 10, not 6.
Hardcode 6 and the system-scope rendezvous releases before the S/R observers
arrive: a barrier that looks alive and is not.  Both classes are checked, because
getting one right and the other wrong is exactly how this would ship.

MP/LB/SB (no observers): 3 instances x 2 = 6
  $ grep -E '^#define (NPART|HET_TEST_BLOCKS|HET_GPU_LANES|HET_SPIN_LANES)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  #define NPART 6
  #define HET_TEST_BLOCKS 3
  #define HET_GPU_LANES 3
  #define HET_SPIN_LANES 3

S/R (T and mu(T) each carry an observer): 4 + 4 + 2 = 10
  $ grep -E '^#define (NPART|HET_TEST_BLOCKS|HET_GPU_LANES|HET_SPIN_LANES)' S-cg-sys-fence-2s/S-cg-sys-fence-2s.cu
  #define NPART 10
  #define HET_TEST_BLOCKS 5
  #define HET_GPU_LANES 5
  #define HET_SPIN_LANES 3

THREE CPU BODIES, THREE NAMES.  Naming het_run_P<proc> from the proc number alone
would make T's P0 and mu(T)'s P0 both `het_run_P0': a duplicate symbol at best,
and at worst the driver calling the wrong test's body -- which would tally one
instance's cycles against another's name and make the whole control a fiction.
  $ grep -c '^void het_run_t_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2
  $ grep -c '^void het_run_mu_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2
  $ grep -c '^void het_run_can_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2

(2 each: the real AArch64 body under #if defined(__aarch64__), and the portable
compile-only shim under #else.)

DISJOINT CACHE-LINE-PADDED LOCATIONS (Q4 3.1).  Disjoint addresses are not
enough: two variables on one cache line are one coherence unit, so mu(T)'s
traffic would drag T's line around and the control would perturb the very test it
exists to vouch for.  One gd_alloc_shared arena, carved one line apart, and the
allocator must stay the coherent one (shared-alloc.t (f)).
  $ grep -c 'HET_CACHE_LINE 128' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -oE 'uint64_t \*(t|mu|can)_[xy] = \(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\);' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  uint64_t *t_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*0);
  uint64_t *t_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*1);
  uint64_t *mu_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*2);
  uint64_t *mu_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*3);
  uint64_t *can_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*4);
  uint64_t *can_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*5);

THREE RECOVERY SCANS, THREE CHANNELS.  The controls are tallied by the same scan
as T -- the control is not special-cased, it is another instance whose target is
tallied by the identical scan (Q4 3.2) -- but into their own channels, so their
outcomes never pollute T's histogram.
  $ grep -cE '_rec\.target_count_exhaustive\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.control_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.canary_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

control_Prep reads control_target_count, so it must be computed AFTER the mu(T)
scan.  Computed up front it could only ever be 1 - e^0 = 0: harmless while no
control is compiled in, a silent lie the moment one is.
  $ MU=$(grep -n 'recovery scan: MP-cg-sys-acquire' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | cut -d: -f1)
  $ PR=$(grep -n '_rec.control_Prep = 1.0 - exp' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | cut -d: -f1)
  $ [ -n "$MU" ] && [ -n "$PR" ] && [ "$MU" -lt "$PR" ] && echo 'mu(T) scan < control_Prep'
  mu(T) scan < control_Prep

EXHAUSTIVE_VALID IS A VALIDITY FLAG, NOT A FORMALITY, AND EACH INSTANCE HAS ITS
OWN.  Set to (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX) for every test it would be 0 on
all 411 at the default N=100000 (the cap is 4096), including a T_L<=1 test that
decodes every frame exactly and counts unconditionally -- and the rule, which
refuses a credible null unless the flag is 1, would then call every run COLD
forever: a decision rule that always says the same thing.

MP has no windowed proc (T_L<=1): the O(N) scan IS the ground truth at any N.
  $ grep -c '_rec.exhaustive_valid = 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

SB's second reader has no rf anchor (T_L>=2), so its count only exists if the
O(N^T_L) search actually ran -- and mu(SB-*-sys-fence-2s) IS SB-*-sys-acqrel-2s,
a T_L>=2 shape too.  Its exhaustive count is therefore 0 by construction at
production N.  Keying the control off it would leave control_target_count
structurally zero on that row, so the null would be cold-invalid forever, and a
positive control that CANNOT FIRE is not a control.  The control counts the
windowed detector instead -- a strict subset of the exhaustive scan under the
same predicate, so it can miss cycles but cannot invent them.

The T_L>=2 emission is unchanged and still pinned on SB.  Its CONTROL half is
not: NVOR demoted every rf-free row (SB and R at sys+fence need an ARM DMB SY to
BE a PTX fence.sc, which is not registered), so SB-cg-sys-fence-2s is NO-ORACLE
and carries no mutant at all.
  $ litmus7 -gpu-target cuda -o . ../het/SB-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -c '_rec.exhaustive_valid = _t_exh;' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1
  $ grep -c 'HET_MU_NAME NULL' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1

The windowed control detector itself is pinned on a SURVIVING Disallowed row --
it is emitted on all 18 of them.
  $ litmus7 -gpu-target cuda -o . ../het/LB-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -c 'if (_weak) { _rec.control_target_count++; _rec.control_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' LB-cg-sys-fence-2s/LB-cg-sys-fence-2s.cu
  1

A MEASURED COVERAGE LOSS, pinned as an absence so its return is visible.
control_exhaustive_valid = _mu_exh is emitted only when the MUTANT is windowed,
and after NVOR no surviving Disallowed row has a windowed mutant (all 18 are
LB-cg / MP-cg / S-cg, whose mutants are one-sided T_L<=1 variants).  That code
path is therefore instantiated by ZERO shipping harnesses today.  It is not dead
code -- NVOR_ACCEPT_DECLINED=1 or a future registration re-arms the SB and R rows
-- but nothing in the shipped corpus exercises it, and this line is the record.
  $ grep -c '_rec.control_exhaustive_valid = _mu_exh;' LB-cg-sys-fence-2s/LB-cg-sys-fence-2s.cu
  0
  [1]

THE REPORTING TIER IS NOT THE MECHANISM TIER.  R and S are both mechanically
ADVISORY (one ws-location + a register), but S's read is an rf read -- a real
synchrony anchor -- while R has zero rf edges: its only read is the
fr-against-init, which in the weak case returns init, tag 0, so it decodes no
writer and no synchrony.  R borrows both its synchrony point and its ws edge from
the fragile observer, exactly like 2+2W, and is demoted for REPORTING only.

  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' R-cg-sys-fence/R-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_EXPLORATORY;

  $ grep -E '_rec\.(confidence|reporting) =' S-cg-sys-fence/S-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_ADVISORY;

The other two tiers, and which of the two fields the printed [...] label is.  The
pair above pins only the tier where the two fields DIFFER; the floor (2+2W, both
EXPLORATORY) and the ceiling (a pure-register shape, both ROBUST) would otherwise
be untested, so a rule collapsed to a constant would still pass.
env-research/decisions/taskP-decision.md `REPORTING-TIER UPDATE' puts R at
EXPLORATORY, which on the 411-test corpus gives ROBUST 294 / ADVISORY 53 (S) /
EXPLORATORY 64 (2+2W 11 + R 53).
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
      _rec.confidence = CONF_EXPLORATORY;
      _rec.reporting = CONF_EXPLORATORY;

  $ grep -E '_rec\.(confidence|reporting) =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
      _rec.confidence = CONF_ROBUST;
      _rec.reporting = CONF_ROBUST;

And the label the human reads is the REPORTING tier.  Printing `confidence' there
instead would relabel all 53 R rows [ADVISORY] -- claiming a null from a shape
that borrows both its synchrony point and its ws edge from the observer is as
good as one recovered from read buffers.  Pinned on the emitted header, not the
source copy.
  $ grep -c 'het_conf_name(_r->reporting)' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_conf_name(_r->confidence)' MP-cg-sys-acqrel-2s/het_verdict.h
  0
  [1]

The GPU-only path never sees any of this: the whole positive-control layer is
het-only.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -cE 'HET_CONTROL_COMPILED_IN|het_verdict|control_target_count' MP-sys-acquire.cu || true
  0
