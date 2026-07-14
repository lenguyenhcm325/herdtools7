B4 regression guard: the emitted het harness must carry the GPU memory-stress
layer (ported from cuda-litmus), and must carry it in the shape the design
requires -- stress in DEVICE memory, disjoint from the test; the device-scope
window-opener kept SEPARATE from the system-scope cross-device rendezvous; and
the B2/B3 invariants (co-residency guard, observer slot, pinned trip counts)
still standing underneath it.

Stress is not an optimisation: on NVIDIA silicon (our GH200 target) the harness
observes nothing without it -- "we did not observe sb and lb on Titan without
this incantation" (Alglave ASPLOS'15 4.3.1; Table 6: sb/lb are 0 in every column
without memory stress), and S&D PLDI'16 went 0/1000 -> 102/1000 on a Tesla K20 by
adding it.  On AMD the same paper saw weak behaviours WITHOUT stress (lb:
10959/100k, no incantations), so for the .hip render this layer amplifies rates
rather than enabling observation at all -- do not repeat the unqualified claim.

  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ S=S-cg-sys-fence/S-cg-sys-fence

(a) the ported stress layer is emitted ONCE per harness dir and included by BOTH
renders -- one shared header, so all reused cuda-litmus code and its mandatory
citations sit in one auditable file.
  $ test -f MP-cg-sys-acqrel-2s/het_stress.cuh && echo present
  present
  $ grep -c '#include "het_stress.cuh"' $MP.cu $MP.hip
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip:1
  $ grep -c 'cuda-litmus' MP-cg-sys-acqrel-2s/het_stress.cuh > /dev/null && echo cited
  cited

(b) TWO OBJECT CLASSES, TWO ALLOCATORS.  The scratchpad is GPU-only and disjoint
from every test location, so it lives in DEVICE memory -- it must NOT go through
gd_alloc_shared, which is the coherent allocator that selects the property under
test (B1/Q8).  Confusing the two would put stress traffic on the tested cache
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
  $ grep -c 'hipMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MP.hip
  1

(c) the pure-stress workgroups: every block above the test/observer blocks
hammers the scratchpad, and the grid is raised toward the co-resident cap while
the B2 guard STAYS (an over-large cooperative launch must be rejected at launch,
not silently deadlock -- a silent hang is indistinguishable from a genuine
non-observation).
  $ grep -c 'blockIdx.x >= HET_TEST_BLOCKS' $MP.cu
  1
  $ grep -c '_grid > _maxGrid' $MP.cu
  1
  $ grep -c '_stressBlocks = (HET_STRESS_BLOCKS >= 0)' $MP.cu
  1

(d) the device-scope window-opener is SEPARATE from the system-scope rendezvous.
het_spin aligns the GPU test lanes; gd_bar is the CPU<->GPU start barrier and
fires ONCE, outside the perpetual loop.  Merging them would put a per-iteration
CROSS-DEVICE barrier in the loop, which masks the tested order and stalls
(Srivastava 4.1).  One spin call per GPU test lane; the two gd_bar fetch_adds
(GPU lane + CPU thread) are untouched.
  $ grep -c 'het_spin(_spin_bar' $MP.cu
  1

(The arrival count matches `_bar.fetch_add', the barrier's OWN atomic, not a bare
`fetch_add'.  B5 added the first non-barrier atomic RMW to this file -- the CPU
stress tally -- and a bare count would have swept it up; bumping the expectation to
3 would then have left the check satisfiable by a real THIRD BARRIER ARRIVAL, which
is the regression it exists to catch.  Same reasoning in coop-launch.t.)
  $ grep -c '_bar.fetch_add' $MP.cu
  2

and the barrier is ALL-OR-NONE, with its limit indexed by the barriers TAKEN --
the adaptation the perpetual loop forces.  Upstream relaunches per iteration, so
its counter is fresh each time and its toggle is one host-set boolean, uniform
across the launch: all testing threads spin, or none do (litmus.cuh:340).  Our
counter grows, so the limit must grow with it -- and it is only ATTAINABLE if
every lane contributes exactly one increment to each barrier.  Hence: the roll is
drawn from a LANE-INDEPENDENT stream (keyed by the iteration, not the lane), and
the limit counts taken barriers (_nb), not iterations.
  $ grep -c 'het_rng_init(_seed ^ 0x9e3779b9u, (uint32_t)_n)' $MP.cu
  1
  $ grep -c 'het_spin(_spin_bar, _nb \* HET_SPIN_LANES, _stress_tally)' $MP.cu
  1

A per-lane roll with an iteration-indexed limit ((_n+1)*lanes) is the B4 bug: a
lane increments on only HET_BARRIER_PCT% of iterations while the limit rises every
iteration, so the counter falls permanently behind and every spin burns the full
1024-spin deadlock cap instead of rendezvousing (measured on device: 99.6% cap-
released, counter deficit 627).  It must not come back.
  $ grep -c '(uint32_t)(_n + 1) \* HET_SPIN_LANES' $MP.cu || true
  0

(e) the ACCESS PATTERN reaches het_do_stress as a RUNTIME kernel argument, never
as a compile-time constant.  Two bugs meet in this one line.  Upstream's: the 4th
argument of do_stress is the PATTERN and MEM_STRESS() passes an ITERATION COUNT
there (litmus.cuh:346), so mem-stress spun doing nothing.  Ours: a compile-time
pattern lets nvcc fold the if-chain to the one live branch, and the tuned default
(3 = ld;ld, whose loads only feed a `break') is then side-effect-free -- so nvcc
DELETED the whole loop (0 scratchpad ops in the emitted PTX; -DHET_MEM_STRESS_
PATTERN=3 emptied the entire kernel).  hetlitmus/verify/stresscheck.py is the gate.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat)' $MP.cu
  1
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat)' $MP.cu
  1
  $ grep -c 'uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;' $MP.cu
  1
  $ grep -c 'uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;' $MP.cu
  1

and an out-of-range pattern is refused at COMPILE time -- het_do_stress's if-chain
has no else, so pattern 57 (upstream's) silently stresses NOTHING.
  $ grep -c '#error "HET_PRE_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.cuh
  1
  $ grep -c '#error "HET_MEM_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.cuh
  1

(e2) LIVENESS TALLY: every mechanism in the stress layer is invisible to the L0
faithfulness gate (it is scaffolding, not a tested op), so its health is measured
at run time or not at all -- both critical B4 defects shipped through five green
gates.  het_spin tallies how each spin ended (rendezvous vs the 1024-spin deadlock
cap); the stress lanes flag a HET_STRESS_MAX_ROUNDS cap-exit, which means stress
STOPPED while the test was still running.  The host prints both and carries them
into the HetObs record, so B7 can disqualify a run and B8 can tune against it.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1
  $ grep -c 'HetLitmus stress: spins=%llu rendezvous=%llu cap=%llu' $MP.cu
  1
  $ grep -c 'spin=%llu/%llu stress_trunc=%llu' $MP.cu
  1
  $ grep -c 'het_scratch_bump(&tally\[(val >= limit) ? HET_TALLY_RDV : HET_TALLY_CAP\])' MP-cg-sys-acqrel-2s/het_stress.cuh
  1

(e3) the two UPSTREAM bugs are disclosed in the emitted header, not just in a
commit message: we cite Levine, so a reader must be able to tell which lines are
theirs.  Bug 2 is the dead dedup -- setScratchLocations declares std::set
usedRegions and queries it but never inserts, so it never dedups and its realised
spread is <= m.  We dedup for real, which is a behavioural divergence.
disclosed BOTH in the header (where a reader looks for the provenance) and at the
code site (where a maintainer looks before "restoring" upstream's version):
  $ grep -c 'NEVER INSERTS INTO IT' MP-cg-sys-acqrel-2s/het_stress.cuh
  1
  $ grep -c 'never inserts into the set' MP-cg-sys-acqrel-2s/het_stress.cuh
  1

and the Alglave "zero without stress" result is qualified to NVIDIA, because this
header is #include'd by the .hip (AMD) render too -- on AMD the same paper saw lb
without any incantation.
  $ grep -c 'VENDOR SPLIT' MP-cg-sys-acqrel-2s/het_stress.cuh
  2

(f) the stress toggles are decided DEVICE-side off a seeded Park-Miller stream:
the perpetual kernel has no per-iteration host round-trip to re-roll them, and a
fixed seed keeps a run replayable (GPUHarbor).  The lane draws its own stream (for
the pre-stress toggle, which feeds no shared counter); the barrier's stream is the
LANE-INDEPENDENT one checked in (d).
  $ grep -c 'het_rng_t _rng = het_rng_init(_seed, blockIdx.x \* blockDim.x + threadIdx.x)' $MP.cu
  1

(g) on an OBSERVER test (condition names a coherence-final location), the B3
observer keeps its reserved grid slot and its pinned trip count, and it does NOT
spin -- its job is to sample the shared locations densely, and gating it on the
test lanes would couple two lanes that run at different rates.  So: 2 test blocks
(GPU proc + observer), 2 perpetual lanes, but only 1 spin; and BOTH `unroll 1'
pragmas survive (dropping either re-breaks faithfulness -- nvcc unrolls the loop
and the PTX then carries many times the declared ops).
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES|SPIN_LANES)' $S.cu
  #define HET_TEST_BLOCKS 2
  #define HET_GPU_LANES 2
  #define HET_SPIN_LANES 1
  $ grep -c 'het_spin(_spin_bar' $S.cu
  1
  $ grep -c '#pragma unroll 1' $S.cu
  2

(h) the HIP twin renders the same shape from the same template (per-dialect
fields, not per-dialect branches), and the header's one divergence -- device-scope
atomics, which CUDA and HIP genuinely spell differently -- resolves to the HIP
spelling.
  $ grep -c 'het_spin(_spin_bar' $S.hip
  1
  $ grep -c '__HIP_MEMORY_SCOPE_AGENT' S-cg-sys-fence/het_stress.cuh
  2
