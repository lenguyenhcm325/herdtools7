B6 regression guard: the positive control, and the co-run that makes it real.

Every "Never" this harness prints is uninterpretable unless a known-ALLOWED weak
behaviour fired on the same run, on the same C2C path, under the same stress.  This
guards the pieces that make that true -- and, above all, the two ways it could go
quietly wrong: a null reported as credible while no control is actually co-running,
and a `not measured' exhaustive count read as a `measured zero'.

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

THE HIGHEST-STAKES VALUE IN THE CODEBASE.  HET_CONTROL_COMPILED_IN=1 says a real
mu(T) (Layer A) is CO-RUNNING in this launch, so a null may be read against it.  Flip
it without the co-run behind it and every "Never" silently becomes a *credible*
"Never" -- an unfalsifiable null that reads as confirmation of the CMCM.  Everything
below this line exists to make the 1 TRUE, not merely present.

  $ grep -c '#define HET_CONTROL_COMPILED_IN 1' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

B6c GAVE THE OTHER 322 TESTS A CANARY -- AND DID NOT TOUCH THIS FLAG.
B6c co-runs the Layer-B canary on every test that has one (Q4 R5), which is the whole
non-Disallowed corpus.  The obvious way to record that would have been to let
HET_CONTROL_COMPILED_IN rise to 1 on all of them.  THAT WOULD HAVE BEEN THE BUG: "a
canary is co-running" and "the minimal mutant OF THIS TEST is co-running" are
different claims, and only the second licenses a CREDIBLE-NULL.  Collapsed into one
bit, a null on a test that has no mutant at all would start reading as vouched-for.

So the flag SPLIT rather than widened, and the Layer-A guard below is UNCHANGED --
still exactly the 16 Disallowed tests.  A canary-only harness says so in its own flag.
  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME NULL' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c '#define HET_CONTROL_COMPILED_IN 0' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c '#define HET_CANARY_COMPILED_IN 1' S-cg-sys-fence/S-cg-sys-fence.cu
  1

...and the canary really is IN there, not merely named: its own instance, its own K,
its own recovery scan feeding its own channel.  A NAME IS NOT A CO-RUN -- the map
names a canary for all 338 rows, and before B6c 320 of them named one they did not
run.  That is exactly the drift the flag exists to catch, so both are checked.
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c 'recovery scan: MP-cg-sys-relaxed' S-cg-sys-fence/S-cg-sys-fence.cu
  1
B7: the canary's count and its PER-WINDOW sub-tally are bumped on ONE line under ONE
predicate.  That pairing is not cosmetic -- it is what makes `sum(canary_win[]) ==
canary_target_count' an INVARIANT, and that invariant is the only run-time evidence
that the sub-tallies are alive at all (het_stats_compute raises HET_ST_WIN_DESYNC when
it breaks).  Pin the pair, not just the count: a window bump that drifted onto its own
line under its own condition could silently stop tracking.

  $ grep -c 'if (_weak) { _rec.canary_target_count++; _rec.canary_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -cE '^#define CAN_K_TAG 3' S-cg-sys-fence/S-cg-sys-fence.cu
  1

THE ORACLE CLASS (B6c).  Without it het_verdict() framed all 338 tests as
should-be-forbidden, so any test that observed its weak outcome printed "the
should-be-FORBIDDEN outcome was OBSERVED ... A single sighting REFUTES the model's
prediction".  Only 16 of the 338 are Disallowed.  286 are oracle-ALLOWED -- there the
weak outcome is EXPECTED, and seeing it CONFIRMS the model is not over-strong -- and
36 are NO-ORACLE.  322 harnesses stood ready to print a LOUD FALSE REFUTATION of the
compound memory model.  Each class must carry its own tag, read from control-map.csv
field 2, and the emitter must never fall back to a default.
  $ litmus7 -o . ../het/IRIW-cgcg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -h '_rec.het_oracle' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu S-cg-sys-fence/S-cg-sys-fence.cu IRIW-cgcg-sys-fence-2s/IRIW-cgcg-sys-fence-2s.cu
      _rec.het_oracle = ORACLE_DISALLOWED;
      _rec.het_oracle = ORACLE_ALLOWED;
      _rec.het_oracle = ORACLE_NONE;

ORACLE_UNSET IS 0 SO THAT A FORGOTTEN TAG FAILS LOUD.  het_obs_record is memset(0)
before it is filled, so the zero value is what an emitter that skipped the field would
produce.  Had DISALLOWED been 0, that omission would have silently restored the false
refutation.  It is the first enumerator, and het_verdict() fails closed on it.
  $ grep -c 'ORACLE_UNSET = 0,' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'if (r->het_oracle == ORACLE_UNSET) {' MP-cg-sys-acqrel-2s/het_verdict.h
  1

THE SHARPEST INSTANCE: THE CANARY ITSELF.  MP-cg-sys-relaxed is oracle-Allowed AND is
the Layer-B canary for 265 rows of control-map.csv.  It cannot co-run itself (the map
says `self'), so BOTH flags are 0 and it stays single-instance -- and pre-B6c, the one
test whose entire job is to FIRE would have printed a refutation of the compound model
every time it did its job.  It names itself as its canary, which is how het_verdict.h
tells "this test IS the canary" (designed) from "the canary went missing" (a bug).
  $ litmus7 -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -E '^#define HET_(CONTROL|CANARY)_COMPILED_IN' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_CONTROL_COMPILED_IN 0
  #define HET_CANARY_COMPILED_IN 0
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_rec.het_oracle = ORACLE_ALLOWED;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

THREE INSTANCES, THREE K's.  K is 3 for MP/SB/LB but 4 for R/S (three stores, not
two), and the canary is always an MP -- so every R/S control harness genuinely mixes
K=4 and K=3 in ONE translation unit.  A single TU-wide K_TAG would decode one
instance's tags with the other's modulus: wrong writer (tag % K), wrong iteration
(tag / K), fictional cycles, and no structural gate could see it.

  $ grep -E '^#define (T|MU|CAN)_K_TAG' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  #define T_K_TAG   3   /* MP-cg-sys-acqrel-2s (T) */
  #define MU_K_TAG  3   /* MP-cg-sys-acquire (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

The S/R class is where the K's actually differ:
  $ litmus7 -o . ../het/S-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -E '^#define (T|MU|CAN)_K_TAG' S-cg-sys-fence-2s/S-cg-sys-fence-2s.cu
  #define T_K_TAG   4   /* S-cg-sys-fence-2s (T) */
  #define MU_K_TAG  4   /* S-cg-sys-fence (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

NPART IS A SUM, NOT A CONSTANT.  S and R carry observer lanes (1 GPU + 1 CPU), so
their instances are NPART 4, not 2 -- an S/R co-run harness is 10, not 6.  Hardcode 6
and the system-scope rendezvous releases before the S/R observers arrive: a barrier
that looks alive and is not.  Both classes are checked, because getting one right and
the other wrong is exactly how this would ship.

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

THREE CPU BODIES, THREE NAMES.  het_run_P<proc> was named from the proc number
ALONE, so T's P0 and mu(T)'s P0 were both `het_run_P0': a duplicate symbol at best,
and at worst the driver calling the WRONG TEST'S BODY -- which would tally one
instance's cycles against another's name and make the whole control a fiction.
  $ grep -c '^void het_run_t_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2
  $ grep -c '^void het_run_mu_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2
  $ grep -c '^void het_run_can_P0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  2

(2 each: the real AArch64 body under #if defined(__aarch64__), and the portable
compile-only shim under #else.)

DISJOINT CACHE-LINE-PADDED LOCATIONS (Q4 3.1).  Disjoint ADDRESSES are not enough:
two variables on one cache line are ONE coherence unit, so mu(T)'s traffic would drag
T's line around and the control would perturb the very test it exists to vouch for.
One gd_alloc_shared arena (the allocator SELECTS the property under test -- it must
still be the coherent one), carved one line apart.
  $ grep -c 'HET_CACHE_LINE 128' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -oE 'uint64_t \*(t|mu|can)_[xy] = \(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\);' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  uint64_t *t_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*0);
  uint64_t *t_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*1);
  uint64_t *mu_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*2);
  uint64_t *mu_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*3);
  uint64_t *can_x = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*4);
  uint64_t *can_y = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*5);

THREE RECOVERY SCANS, THREE CHANNELS.  The controls are tallied by the SAME scan as
T (Q4 3.2: "the control is not special-cased, it is another instance whose target is
tallied by the identical scan") -- but into their OWN channels, so their outcomes
never pollute T's histogram.
  $ grep -cE '_rec\.target_count_exhaustive\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.control_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.canary_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

control_Prep reads control_target_count, so it MUST be computed after the mu(T) scan.
Computed up front (as B6a did) it could only ever be 1 - e^0 = 0: harmless while no
control was compiled in, a silent lie the moment one was.
  $ MU=$(grep -n 'recovery scan: MP-cg-sys-acquire' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | cut -d: -f1)
  $ PR=$(grep -n '_rec.control_Prep = 1.0 - exp' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | cut -d: -f1)
  $ [ -n "$MU" ] && [ -n "$PR" ] && [ "$MU" -lt "$PR" ] && echo 'mu(T) scan < control_Prep'
  mu(T) scan < control_Prep

EXHAUSTIVE_VALID IS A VALIDITY FLAG, NOT A FORMALITY, AND EACH INSTANCE HAS ITS OWN.
It was set to (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX) for every test -- which at the
default N=100000 is 0 for ALL 338, while a T_L<=1 test decodes every frame exactly and
counts unconditionally.  Left that way, B6's rule (which refuses a credible null
unless the flag is 1) would have called every run COLD forever: a decision rule that
always says the same thing.

MP has no windowed proc (T_L<=1): the O(N) scan IS the ground truth at any N.
  $ grep -c '_rec.exhaustive_valid = 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

SB's second reader has no rf anchor (T_L>=2), so its count only exists if the
O(N^T_L) search actually ran -- and mu(SB-*-sys-fence-2s) IS SB-*-sys-acqrel-2s, a
T_L>=2 shape TOO.  Its exhaustive count is therefore 0 BY CONSTRUCTION at production
N.  Keying the control off it would leave control_target_count structurally zero on 2
of the 16 control harnesses, so those nulls would be COLD-INVALID forever: a positive
control that CANNOT FIRE is not a control.  The control counts the WINDOWED detector
(a strict subset of the exhaustive scan under the same predicate -- it can miss
cycles, it cannot invent them), and control_exhaustive_valid says so.
  $ litmus7 -o . ../het/SB-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -c '_rec.exhaustive_valid = _t_exh;' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.control_exhaustive_valid = _mu_exh;' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1
  $ grep -c 'if (_weak) { _rec.control_target_count++; _rec.control_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
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

  $ grep -E '_rec\.(confidence|reporting) =' S-cg-sys-fence/S-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_ADVISORY;

The GPU-only path never sees any of this (the whole B6 layer is het-only).
  $ litmus7 -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -cE 'HET_CONTROL_COMPILED_IN|het_verdict|control_target_count' MP-sys-acquire.cu || true
  0
