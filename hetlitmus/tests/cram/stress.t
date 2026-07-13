B4 regression guard: the emitted het harness must carry the GPU memory-stress
layer (ported from cuda-litmus), and must carry it in the shape the design
requires -- stress in DEVICE memory, disjoint from the test; the device-scope
window-opener kept SEPARATE from the system-scope cross-device rendezvous; and
the B2/B3 invariants (co-residency guard, observer slot, pinned trip counts)
still standing underneath it.

Stress is not an optimisation: without it the harness observes nothing (Alglave
ASPLOS'15 Table 6 -- sb/lb weak counts are 0 in every no-incantation column;
S&D PLDI'16 went 0/1000 -> 102/1000 by adding it).

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
  $ grep -c 'fetch_add' $MP.cu
  2

and its limit is ITERATION-INDEXED -- the adaptation the perpetual loop forces.
Upstream relaunches per iteration so its barrier counter is fresh each time; a
counter that only grew would be satisfied from iteration 1 onward and the barrier
would silently stop barriering.
  $ grep -c '(uint32_t)(_n + 1) \* HET_SPIN_LANES' $MP.cu
  1

(e) the cuda-litmus MEM_STRESS pattern-argument bug is FIXED on the way in: the
4th argument of do_stress is the PATTERN, and upstream passes an ITERATION COUNT
there (litmus.cuh:346), so mem-stress spun doing nothing and the only
scratchpad-WRITER pattern was never reachable.  Both call sites must pass a
pattern in the pattern slot.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, HET_PRE_STRESS_PATTERN)' $MP.cu
  1
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, HET_MEM_STRESS_PATTERN)' $MP.cu
  1

(f) the stress toggles are decided DEVICE-side off a seeded Park-Miller stream:
the perpetual kernel has no per-iteration host round-trip to re-roll them, and a
fixed seed keeps a run replayable (GPUHarbor).
  $ grep -c 'het_rng_init(_seed' $MP.cu
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
