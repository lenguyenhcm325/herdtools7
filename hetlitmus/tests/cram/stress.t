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
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE' $MP.cu
  1
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch_loc' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_scratch' $MP.cu || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE' $MPH.hip
  1

(c) the blocks above the test blocks split into DDR-noise readers and scratchpad
stressers; the grid is raised toward the co-resident cap (coop-launch.t (g)).
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
  _gpu_iter

(d2) the noise tally counts blocks, not threads: thread 0 alone bumps it, and that
guarded bump is the only bump of that tally.
  $ grep -c 'if (_r > 0 && threadIdx.x == 0) het_scratch_bump(&_stress_tally\[HET_TALLY_NOISE\]);' $MP.cu
  1
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_NOISE\]);' $MP.cu
  1

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

(e2) the block flags a cap-exit through lane 0, so stress that stopped while the
test was still running reaches the record once per block.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1
  $ grep -c 'if (_polls >= HET_STRESS_MAX_ROUNDS && threadIdx.x == 0)' $MP.cu
  1

(e3) and the shipped defaults: pattern 0 is the memory stress's only pure
writer, so a drift would leave it reading and never writing.
  $ grep -c '#define HET_PRE_STRESS_PATTERN 3' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c '#define HET_MEM_STRESS_PATTERN 0' MP-cg-sys-acqrel-2s/het_stress.h
  1

(f) the stress toggles are drawn device-side, each a function of the seed, the
participant the decision belongs to and the index alone.
  $ grep -c 'const uint32_t _who = blockIdx.x \* blockDim.x + threadIdx.x;' $MP.cu
  1
  $ grep -c '(int)(het_draw(_seed, _who, 2u\*(uint64_t)_n) % 100u) < HET_PRE_STRESS_PCT' $MP.cu
  1
  $ grep -c '(int)(het_draw(_seed, HET_WHO_GRID, _v) % 100u) < HET_MEM_STRESS_PCT' $MP.cu
  1

(f2) the mem-stress toggle is one draw per test ITERATION: lane 0 alone polls the
clock and broadcasts it, and an off-iteration idles instead of hammering.
  $ grep -c 'if (threadIdx.x == 0) _clk = het_scratch_read(_gpu_iter);' $MP.cu
  2
  $ grep -c 'het_scratch_read(_gpu_iter)' $MP.cu
  2
  $ grep -c 'uint32_t _v = _clk;' $MP.cu
  2
  $ grep -c 'het_idle();' $MP.cu
  1

(f2b) every intra-block barrier sits inside the stress region, so a test block
reaches NONE of them.
  $ grep -c '__shared__ uint32_t _clk;' $MP.cu
  1
  $ grep -c '__syncthreads();' $MP.cu
  4
  $ sed -n '/if (blockIdx.x >= HET_TEST_BLOCKS) {/,$p' $MP.cu | grep -c '__syncthreads();'
  4

(f3) that iteration count is published by exactly ONE test lane, from inside the
loop it counts.
  $ grep -c 'het_scratch_bump(_gpu_iter);' $MP.cu
  1
  $ sed -n '/#pragma unroll 1/,/^    }$/p' $MP.cu | grep -c 'het_scratch_bump(_gpu_iter);'
  1

(g) a shape whose outcome carries a location column runs no extra lane for it,
and every `unroll 1' pragma survives per lane.
  $ grep -E '^#define HET_TEST_BLOCKS' $S.cu
  #define HET_TEST_BLOCKS 1
  $ grep -c '#pragma unroll 1' $S.cu
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' $S.cu | grep -c 'het_do_stress(_scratch'
  1

(h) the HIP twin renders the same shape from the same template.
  $ grep -c 'het_do_stress(_scratch' $SH.hip
  2
