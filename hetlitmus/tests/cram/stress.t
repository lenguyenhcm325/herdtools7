GPU memory-stress guard (hetlitmus/docs/00-environment-design.md sec 3.5;
hetlitmus/docs/het-emission.md, "The pair a harness names").

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86/S-cg-sys-fence-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ S=S-cg-sys-fence/S-cg-sys-fence
  $ MPH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
  $ SH=hip/S-cg-sys-fence-x86_64/S-cg-sys-fence-x86_64

(a) the ported stress layer is one shared header per harness dir, included by
that dir's render, carrying the [CudaLitmus] citation its reuse is conditioned on.
  $ test -f MP-cg-sys-acqrel-2s/het_stress.h && echo present
  present
  $ grep -c '#include "het_stress.h"' $MP.cu $MPH.hip
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip:1
  $ grep -c 'cuda-litmus' MP-cg-sys-acqrel-2s/het_stress.h > /dev/null && echo cited
  cited

(b) the scratchpad is DEVICE memory, never gd_alloc_shared, the coherent
allocator that selects the property under test (shared-alloc.t).
  $ grep -c 'cudaMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MP.cu
  1
  $ grep -c 'cudaMalloc(&_scratch_loc' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_scratch' $MP.cu || true
  0
  $ grep -c 'hipMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MPH.hip
  1

(c) every block above the test blocks hammers the scratchpad, and the grid is
raised toward the co-resident cap (the launch guard is in coop-launch.t (g)).
  $ grep -c 'blockIdx.x >= HET_TEST_BLOCKS' $MP.cu
  1
  $ grep -c '_stressBlocks = (HET_STRESS_BLOCKS >= 0)' $MP.cu
  1

(d) the stress layer touches the scratchpad and its own tally words, never a
test location.
  $ grep -oE 'het_scratch_(bump|max|read)\([^,)]*' $MP.cu | sed 's/.*(//' | sort -u
  &_stress_tally[HET_TALLY_NOISE]
  &_stress_tally[HET_TALLY_NOISE_ROUNDS]
  &_stress_tally[HET_TALLY_TRUNC]
  _gpu_done

(e) the access pattern reaches het_do_stress as a runtime kernel argument, and
the pre-stress runs in every test lane.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;' $MP.cu
  1
  $ grep -c 'uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;' $MP.cu
  1

(e2) the lane flags a cap-exit, so stress that stopped while the test was still
running reaches the record.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1

(e3) and the shipped defaults: pattern 0 is the memory stress's only pure
writer, so a drift would leave it reading and never writing.
  $ grep -c '#define HET_PRE_STRESS_PATTERN 3' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c '#define HET_MEM_STRESS_PATTERN 0' MP-cg-sys-acqrel-2s/het_stress.h
  1

(f) the stress toggles are drawn device-side from a seeded per-lane stream, so a
run replays from its seed with no host round-trip.
  $ grep -c 'het_rng_t _rng = het_rng_init(_seed, blockIdx.x \* blockDim.x + threadIdx.x)' $MP.cu
  1

(g) a shape whose outcome carries a location column runs no extra lane for it,
and every `unroll 1' pragma survives per lane.
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES)' $S.cu
  #define HET_TEST_BLOCKS 1
  #define HET_GPU_LANES 1
  $ grep -c '#pragma unroll 1' $S.cu
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' $S.cu | grep -c 'het_do_stress(_scratch'
  1

(h) the HIP twin renders the same shape from the same template.
  $ grep -c 'het_do_stress(_scratch' $SH.hip
  2
