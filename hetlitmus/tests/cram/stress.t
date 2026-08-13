GPU memory-stress guard (B4; env-research/Q5-gpu-stress.md).  The emitted het
harness carries the stress layer ported from cuda-litmus, in the shape the design
requires: stress in DEVICE memory, disjoint from the test; the device-scope
window-opener kept separate from the system-scope cross-device rendezvous; and
the perpetual-loop invariants (co-residency guard, observer slot, pinned trip
counts) still standing underneath it.

Stress is not an optimisation: on NVIDIA silicon (our GH200 target) the harness
observes nothing without it, whereas the same source saw weak behaviours on AMD
with no incantation at all, so on the .hip render this layer amplifies rates
rather than enabling observation.  The quotes, tables and vendor split live once,
in the emitted het_stress.h (pinned in (e3)); do not repeat the claim
unqualified.

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and (x86_64, hip) is the one this project has an
MI300A row for (litmus/hetMachine.ml).  The CPU column differs; everything these
sections read is the GPU render and the shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86/S-cg-sys-fence-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ S=S-cg-sys-fence/S-cg-sys-fence
  $ MPH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
  $ SH=hip/S-cg-sys-fence-x86_64/S-cg-sys-fence-x86_64

(a) the ported stress layer is emitted ONCE per harness dir and included by that
dir's render -- one shared header, so all reused cuda-litmus code and its
mandatory citations sit in one auditable file.
  $ test -f MP-cg-sys-acqrel-2s/het_stress.h && echo present
  present
  $ grep -c '#include "het_stress.h"' $MP.cu $MPH.hip
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip:1
  $ grep -c 'cuda-litmus' MP-cg-sys-acqrel-2s/het_stress.h > /dev/null && echo cited
  cited

(b) two object classes, two allocators.  The scratchpad is GPU-only and disjoint
from every test location, so it lives in DEVICE memory: it must not go through
gd_alloc_shared, the coherent allocator that selects the property under test
(shared-alloc.t).  Confusing the two would put stress traffic on the tested cache
lines.
  $ grep -c 'cudaMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MP.cu
  1
  $ grep -c 'cudaMalloc(&_scratch_loc' $MP.cu
  1
  $ grep -c 'cudaMalloc(&_spin_bar' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_scratch' $MP.cu || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&_spin_bar' $MP.cu || true
  0
  $ grep -c 'hipMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MPH.hip
  1

(c) the pure-stress workgroups: every block above the test/observer blocks
hammers the scratchpad, and the grid is raised toward the co-resident cap.  The
launch guard that must survive that raise -- an over-large cooperative launch is
REJECTED at launch rather than silently deadlocking, a silent hang being
indistinguishable from a genuine non-observation -- is pinned once, in
coop-launch.t (g), which reads this same render.
  $ grep -c 'blockIdx.x >= HET_TEST_BLOCKS' $MP.cu
  1
  $ grep -c '_stressBlocks = (HET_STRESS_BLOCKS >= 0)' $MP.cu
  1

(d) the device-scope window-opener is SEPARATE from the system-scope rendezvous.
het_spin aligns the GPU test lanes; gd_bar is the CPU<->GPU start barrier and
fires once, outside the perpetual loop.  Merging them would put a per-iteration
cross-device barrier in the loop, which masks the tested order and stalls
(Srivastava 4.1).  One spin call per GPU test lane; one gd_bar fetch_add per
barrier-joining participant.

MP-cg-sys-acqrel-2s is a co-run harness -- T, mu(T) and the canary share this
launch -- so there are three GPU test lanes and three CPU threads.  The per-lane
invariant is what is asserted: exactly one spin per test lane, and (below)
exactly one inside T's own lane, so a total of 3 cannot be satisfied by a lane
that lost its spin while another gained two.
  $ grep -c 'het_spin(_spin_bar' $MP.cu
  3
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' $MP.cu | grep -c 'het_spin(_spin_bar'
  1

All three lanes spin on the SAME device-scope word, and HET_SPIN_LANES is their
sum.  That is required, not incidental: the barrier's limit is
_nb*HET_SPIN_LANES, so a lane that joined the spin without being counted in
HET_SPIN_LANES would make the limit unreachable and every spin would burn the
1024-iteration deadlock cap.
  $ grep -c '#define HET_SPIN_LANES 3' $MP.cu
  1

(The cross-device arrivals themselves -- six on `_bar.fetch_add', one inside T's
own lane -- are pinned in coop-launch.t (b,c), on this same render.)

and the barrier is ALL-OR-NONE, with its limit indexed by the barriers taken --
the adaptation the perpetual loop forces.  Upstream relaunches per iteration, so
its counter is fresh each time and its toggle is one host-set boolean, uniform
across the launch: all testing threads spin, or none do (litmus.cuh:340).  Our
counter grows, so the limit must grow with it, and it is only attainable if every
lane contributes exactly one increment to each barrier.  Hence the roll is drawn
from a lane-independent stream (keyed by the iteration, not the lane) and the
limit counts taken barriers (_nb), not iterations -- so all three co-running
instances reach the same verdict for iteration _n.
  $ grep -c 'het_rng_init(_seed ^ 0x9e3779b9u, (uint32_t)_n)' $MP.cu
  3
  $ grep -c 'het_spin(_spin_bar, _nb \* HET_SPIN_LANES, _stress_tally)' $MP.cu
  3

A per-lane roll with an iteration-indexed limit ((_n+1)*lanes) is the defect this
pins: a lane increments on only HET_BARRIER_PCT% of iterations while the limit
rises every iteration, so the counter falls permanently behind and every spin
burns the full 1024-spin deadlock cap instead of rendezvousing (measured on
device: 99.6% cap-released, counter deficit 627 --
env-research/impl-briefs/B4-fix-impl-brief.md).
  $ grep -c '(uint32_t)(_n + 1) \* HET_SPIN_LANES' $MP.cu || true
  0

(e) the ACCESS PATTERN reaches het_do_stress as a runtime kernel argument, never
as a compile-time constant.  Two defects meet in this one line: upstream passes
an iteration count where do_stress expects the pattern (litmus.cuh:346), so
mem-stress spins doing nothing; and a compile-time pattern lets nvcc fold the
if-chain to the one live branch, which for the tuned default (3 = ld;ld, whose
loads only feed a `break') is side-effect-free, taking the whole loop with it
(env-research/impl-briefs/B4-fix-impl-brief.md).  hetlitmus/verify/stresscheck.py
is the gate, and _stress_tally counts the rounds het_do_stress completed, so a
layer that is present in the PTX and never executes is visible to het_verdict().
The pre-stress runs in every test lane, so the control is stressed exactly as T.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally)' $MP.cu
  3
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;' $MP.cu
  1
  $ grep -c 'uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;' $MP.cu
  1

and an out-of-range pattern is refused at COMPILE time -- het_do_stress's
if-chain has no else, so upstream's pattern 57 would silently stress nothing.
  $ grep -c '#error "HET_PRE_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c '#error "HET_MEM_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.h
  1

(e2) liveness tally: every mechanism in the stress layer is invisible to the L0
faithfulness gate (it is scaffolding, not a tested op), so its health is measured
at RUN TIME or not at all.  het_spin tallies how each spin ended (rendezvous vs
the 1024-spin deadlock cap); the stress lanes flag a HET_STRESS_MAX_ROUNDS
cap-exit, which means stress stopped while the test was still running.  The host
prints both and carries them into the HetObs record, so the statistics layer can
disqualify a run and the tuner can tune against it.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1
  $ grep -c 'HetLitmus stress: spins=%llu rendezvous=%llu cap=%llu' $MP.cu
  1
  $ grep -c 'spin=%llu/%llu stress_trunc=%llu' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_scratch_bump(&tally\[(val >= limit) ? HET_TALLY_RDV : HET_TALLY_CAP\])' MP-cg-sys-acqrel-2s/het_stress.h
  1

(e3) the two UPSTREAM defects are disclosed in the emitted header, not just in a
commit message: we cite Levine, so a reader must be able to tell which lines are
theirs.  The second is a dead dedup -- setScratchLocations declares a std::set of
used regions and queries it but never inserts, so it never dedups and its
realised spread is <= m.  We dedup for real, which is a behavioural divergence,
disclosed both in the header (where a reader looks for provenance) and at the
code site (where a maintainer looks before "restoring" upstream's version).
  $ grep -c 'NEVER INSERTS INTO IT' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c 'never inserts into the set' MP-cg-sys-acqrel-2s/het_stress.h
  1

and the Alglave "zero without stress" result is qualified to NVIDIA, because this
header is #include'd by the .hip (AMD) render too -- on AMD the same paper saw lb
without any incantation.
  $ grep -c 'VENDOR SPLIT' MP-cg-sys-acqrel-2s/het_stress.h
  2

(f) the stress toggles are decided DEVICE-side off a seeded Park-Miller stream:
the perpetual kernel has no per-iteration host round-trip to re-roll them, and a
fixed seed keeps a run replayable (GPUHarbor).  The lane draws its own stream for
the pre-stress toggle, which feeds no shared counter; the barrier's stream is the
lane-independent one checked in (d).
  $ grep -c 'het_rng_t _rng = het_rng_init(_seed, blockIdx.x \* blockDim.x + threadIdx.x)' $MP.cu
  1

(g) on an OBSERVER test (condition names a coherence-final location) the observer
keeps its reserved grid slot and its pinned trip count, and it does not spin --
its job is to sample the shared locations densely, and gating it on the test
lanes would couple two lanes that run at different rates.

S-cg-sys-fence is off the lattice floor, so it co-runs three instances and every
count here is a SUM over them.  T (an S) contributes 2 blocks (GPU proc +
observer), 2 lanes and 1 spin -- the observer does not spin -- mu(T) is an S too
and contributes the same, and the canary (an MP) contributes 1 block, 1 lane and
1 spin: totals 5 blocks, 5 lanes, 3 spins.  SPIN_LANES (3) staying strictly below
GPU_LANES (5) is the property that matters; hardcode any of these and the
system-scope rendezvous releases before the observers arrive.

Every `unroll 1' pragma survives per instance -- dropping one lets nvcc unroll
that perpetual loop, and the PTX then carries many times the declared ops, which
is the faithfulness gate's subject -- so the file-wide count is 5: two each for T
and mu(T), one for the canary.
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES|SPIN_LANES)' $S.cu
  #define HET_TEST_BLOCKS 5
  #define HET_GPU_LANES 5
  #define HET_SPIN_LANES 3
  $ grep -c 'het_spin(_spin_bar' $S.cu
  3
  $ grep -c '#pragma unroll 1' $S.cu
  5

The observer lanes are still the ones that do NOT spin: their block bodies carry
the perpetual loop but no het_spin.  Checked PER LANE by extracting each block
body, because the file-wide sum of 3 below is equally satisfied by one lane
spinning twice and an observer once -- which is the exact regression this guards.
The blocks are T's GPU proc, T's observer, mu(T)'s GPU proc, mu(T)'s observer,
the canary.
  $ for b in 0 1 2 3 4; do sed -n "/if (blockIdx.x == $b && threadIdx.x == 0) {/,/^  }$/p" $S.cu | grep -c 'het_spin(_spin_bar'; done
  1
  0
  1
  0
  1
  $ grep -c 'het_spin(_spin_bar, _nb \* HET_SPIN_LANES, _stress_tally)' $S.cu
  3

(h) the HIP twin renders the same shape from the same template (per-dialect
fields, not per-dialect branches), and the header's one divergence -- device-scope
atomics, which CUDA and HIP genuinely spell differently -- resolves to the HIP
spelling.
  $ grep -c 'het_spin(_spin_bar' $SH.hip
  3
  $ grep -c '__HIP_MEMORY_SCOPE_AGENT' hip/S-cg-sys-fence-x86_64/het_stress.h
  2
