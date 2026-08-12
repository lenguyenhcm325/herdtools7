Positive-control guard (hetlitmus/docs/positive-control.md).  Every "Never" this
harness prints is uninterpretable unless a weak behaviour of the same shape fired
on the same run, on the same C2C path, under the same stress.  This file pins the
pieces that make that true, and above all the two ways it can go quietly wrong: a
null reported as credible while no control is actually co-running, and a
`not measured' exhaustive count read as a `measured zero'.

The control names come from tests/het/control-map.csv, derived from the corpus by
controlmap.py and never rewritten from the test's name.  mu(T) is T's structural
twin at the LATTICE FLOOR -- every ordering annotation dropped on both sides --
so mu(MP-cg-sys-acqrel-2s) is MP-cg-sys-relaxed, which on this row is also its
Layer-B canary: two instances of the same program on disjoint lines, feeding two
independent channels.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME "MP-cg-sys-relaxed"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The gc mirror carries the gc canary, not the cg one: the canary has to cross the
interconnect the same way round as the test it vouches for, so a gc-cut row gets
a gc-cut canary and a gc-cut mu.  A canary matched on shape but not on DIRECTION
would vouch for traffic the test never generates.
  $ litmus7 -gpu-target cuda -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -E '^#define HET_(MU|CANARY)_NAME' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  #define HET_MU_NAME "MP-gc-sys-relaxed"      /* Layer A: the lattice-floor sibling */
  #define HET_CANARY_NAME "MP-gc-sys-relaxed"  /* Layer B: the universal het-MP floor */

HET_CONTROL_COMPILED_IN=1 is the highest-stakes value in the codebase: it says a
real mu(T) (Layer A) is CO-RUNNING in this launch, so a null may be read against
it.  Flip it without the co-run behind it and every "Never" silently becomes a
*credible* "Never" -- an unfalsifiable null.  Everything below exists to make the
1 true, not merely present.

  $ grep -c '#define HET_CONTROL_COMPILED_IN 1' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The Layer-B canary rides a SEPARATE flag rather than widening this one.  "A canary
is co-running" and "the sibling of this test is co-running" are different claims,
and only the second says this shape's own window was demonstrably hit; collapsed
into one bit, a null on a test that can have no sibling would start reading as
vouched-for.  So the Layer-A guard is exactly the 333 rows OFF the lattice floor,
and the 78 rows AT it -- the fully-relaxed ones, which nothing can be weaker than
-- say so in their own flag.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -c 'HET_MU_NAME NULL' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1
  $ grep -c '#define HET_CONTROL_COMPILED_IN 0' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1
  $ grep -c '#define HET_CANARY_COMPILED_IN 1' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1

...and it says WHY in words, in the harness itself, because a results tree read
six months on cannot re-derive it: a floor row is canary-only by construction,
not because a map went missing.
  $ grep -c 'No Layer-A mu(T) co-runs here: this test is at the lattice floor' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1

...and the canary really is IN there, not merely named: its own instance, its own
K, its own recovery scan feeding its own channel.  A name is not a co-run -- the
map names a canary for all 411 rows -- so both are checked.
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1
  $ grep -c 'recovery scan: MP-cg-sys-relaxed' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1
The canary's count and its per-window sub-tally are bumped on ONE line under ONE
predicate.  That pairing is what makes `sum(canary_win[]) == canary_target_count'
an invariant, and that invariant is the only run-time evidence that the
sub-tallies are alive at all (het_stats_compute raises HET_ST_WIN_DESYNC when it
breaks).  Pin the pair, not just the count: a window bump that drifted onto its
own line under its own condition could silently stop tracking.  (B7;
statistics.t.)

  $ grep -c 'if (_weak) { _rec.canary_target_count++; _rec.canary_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1
  $ grep -cE '^#define CAN_K_TAG 3' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  1

TWO MORE SHAPES FOR THE CHECKS BELOW.  The record stamp is written per harness,
so it is read on three of them rather than one; S-cg-sys-fence is read again
further down, for its reporting tier.
  $ litmus7 -gpu-target cuda -o . ../het/IRIW-cgcg-sys-fence-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1

A ZEROED RECORD CAN NEVER SPEAK.  het_obs_record is memset(0) before it is
filled, so a record an emitter forgot to fill is indistinguishable from one whose
run saw nothing -- unless one field cannot be forged by zero.  rec_magic is that
field: het_verdict() returns COLD-INVALID before reading anything else unless it
matches, and the emitter writes the SYMBOL, so a rename is a compile error rather
than a silent mis-read.
  $ grep -c '#define HET_REC_MAGIC 0x48455431u' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'if (r->rec_magic != HET_REC_MAGIC) {' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -hc '_rec.rec_magic = HET_REC_MAGIC;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu S-cg-sys-fence/S-cg-sys-fence.cu IRIW-cgcg-sys-fence-2s/IRIW-cgcg-sys-fence-2s.cu
  1
  1
  1

THE SHARPEST INSTANCE: THE CANARY ITSELF.  MP-cg-sys-relaxed is the Layer-B
canary for 335 rows of control-map.csv and is itself at the lattice floor.  It
cannot co-run itself (the map says `self') and has no sibling weaker than it, so
both flags are 0 and it stays single-instance -- while being the one test whose
entire job is to fire.  It names itself as its canary, which is how het_verdict.h
tells "this test IS the canary" (designed) from "the canary went missing" (a bug).
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -E '^#define HET_(CONTROL|CANARY)_COMPILED_IN' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_CONTROL_COMPILED_IN 0
  #define HET_CANARY_COMPILED_IN 0
  $ grep -c 'HET_CANARY_NAME "MP-cg-sys-relaxed"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

THREE INSTANCES, THREE K's.  K is 3 for MP/SB/LB but 4 for R/S (three stores, not
two), and the canary is always an MP -- so every R/S control harness genuinely
mixes K=4 and K=3 in one translation unit.  A single TU-wide K_TAG would decode
one instance's tags with the other's modulus: wrong writer (tag % K), wrong
iteration (tag / K), fictional cycles, and no structural gate could see it.
mu is structurally identical to T, so MU_K_TAG always equals T_K_TAG.

  $ grep -E '^#define (T|MU|CAN)_K_TAG' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  #define T_K_TAG   3   /* MP-cg-sys-acqrel-2s (T) */
  #define MU_K_TAG  3   /* MP-cg-sys-relaxed (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

The S/R class is where the K's actually differ:
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -E '^#define (T|MU|CAN)_K_TAG' S-cg-sys-fence-2s/S-cg-sys-fence-2s.cu
  #define T_K_TAG   4   /* S-cg-sys-fence-2s (T) */
  #define MU_K_TAG  4   /* S-cg-sys-relaxed (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed (canary) */

NPART IS A SUM, NOT A CONSTANT.  S and R carry observer lanes (1 GPU + 1 CPU), so
their instances are NPART 4, not 2 -- an S/R co-run harness is 10, not 6.
Hardcode 6 and the system-scope rendezvous releases before the S/R observers
arrive: a barrier that looks alive and is not.  Three populations are checked,
because getting one right and the others wrong is exactly how this would ship.

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

A FLOOR row is two instances, not three: 4 (a 2+2W with observers) + 2 = 6, and
one block fewer than the same shape off the floor.
  $ grep -E '^#define (NPART|HET_TEST_BLOCKS|HET_GPU_LANES|HET_SPIN_LANES)' 2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed.cu
  #define NPART 6
  #define HET_TEST_BLOCKS 3
  #define HET_GPU_LANES 3
  #define HET_SPIN_LANES 2

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
outcomes never pollute T's histogram.  mu and the canary being the SAME program
here is exactly why the channels have to stay separate.
  $ grep -cE '_rec\.target_count_exhaustive\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.control_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE '_rec\.canary_target_count\+\+' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

control_Prep reads control_target_count, so it must be computed AFTER the mu(T)
scan.  Computed up front it could only ever be 1 - e^0 = 0: harmless while no
control is compiled in, a silent lie the moment one is.  The scan is located by
its ROLE, not by the mu's name, which on this row the canary shares.
  $ MU=$(grep -n 'recovery scan: MP-cg-sys-relaxed -- Layer A' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | cut -d: -f1)
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
O(N^T_L) search actually ran, and at production N it does not.  Keying the control
off it would leave control_target_count structurally zero on that row, so the null
would be cold-invalid forever, and a positive control that CANNOT FIRE is not a
control.  The control counts the windowed detector instead -- a strict subset of
the exhaustive scan under the same predicate, so it can miss cycles but cannot
invent them.
  $ litmus7 -gpu-target cuda -o . ../het/SB-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -c '_rec.exhaustive_valid = _t_exh;' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1
  $ grep -c 'HET_MU_NAME "SB-cg-sys-relaxed"' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1

The windowed control detector is emitted on every row that carries a mu.
  $ litmus7 -gpu-target cuda -o . ../het/LB-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ grep -c 'if (_weak) { _rec.control_target_count++; _rec.control_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' LB-cg-sys-fence-2s/LB-cg-sys-fence-2s.cu
  1

control_exhaustive_valid = _mu_exh is emitted only where the MUTANT is itself
windowed, which is a property of the mutant's shape and not of T's.  SB's floor
sibling is another T_L>=2 shape, so SB emits it; LB's floor sibling decodes every
frame exactly, so LB does not.  Both directions are pinned, because a line
emitted everywhere and a line emitted nowhere are equally uninformative.
  $ grep -c '_rec.control_exhaustive_valid = _mu_exh;' SB-cg-sys-fence-2s/SB-cg-sys-fence-2s.cu
  1
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

NOTHING ABOVE IS A CUDA FACT.  Every pin so far reads a .cu, so a control layer
that silently degraded on the other dialect would pass all of it; the (x86_64,
hip) render is checked on its own bytes.  S-cg-sys-fence-x86_64 is the sharper
subject than the MP rows: its mu and its canary are DIFFERENT tests, so a render
that collapsed the two channels onto one instance shows up here and nowhere else.
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/S-cg-sys-fence-x86_64.litmus >/dev/null 2>&1
  $ SH=hip/S-cg-sys-fence-x86_64/S-cg-sys-fence-x86_64
  $ grep -E '^#define HET_(MU|CANARY)_NAME' $SH.hip
  #define HET_MU_NAME "S-cg-sys-relaxed-x86_64"      /* Layer A: the lattice-floor sibling */
  #define HET_CANARY_NAME "MP-cg-sys-relaxed-x86_64"  /* Layer B: the universal het-MP floor */
  $ grep -E '^#define HET_(CONTROL|CANARY)_COMPILED_IN' $SH.hip
  #define HET_CONTROL_COMPILED_IN 1
  #define HET_CANARY_COMPILED_IN 1
  $ grep -E '^#define (T|MU|CAN)_K_TAG' $SH.hip
  #define T_K_TAG   4   /* S-cg-sys-fence-x86_64 (T) */
  #define MU_K_TAG  4   /* S-cg-sys-relaxed-x86_64 (mu(T)) */
  #define CAN_K_TAG 3   /* MP-cg-sys-relaxed-x86_64 (canary) */
  $ grep -cE '^void het_run_(t|mu|can)_P0' hip/S-cg-sys-fence-x86_64/S-cg-sys-fence-x86_64_cpu.c
  6

...and the floor row of that same fixture names no mu at all, on the hip side
too: the two lanes agree about which rows have a Layer A, which is the property
that would break first if a dialect stopped reading the map.
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -E '^#define HET_(MU|CANARY)_NAME' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_MU_NAME NULL
  #define HET_CANARY_NAME "MP-cg-sys-relaxed-x86_64"  /* Layer B: the universal het-MP floor */

The GPU-only path never sees any of this: the whole positive-control layer is
het-only.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -cE 'HET_CONTROL_COMPILED_IN|het_verdict|control_target_count' MP-sys-acquire.cu || true
  0
