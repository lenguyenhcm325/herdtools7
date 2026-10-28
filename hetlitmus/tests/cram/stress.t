GPU memory-stress guard.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-ra.acq.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-plain.fsc.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86_64/MP-cg-sys-plain.acq-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86_64/S-cg-sys-plain.fsc-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-ra.acq/MP-cg-sys-ra.acq
  $ S=S-cg-sys-plain.fsc/S-cg-sys-plain.fsc
  $ MPH=hip/MP-cg-sys-plain.acq-x86_64/MP-cg-sys-plain.acq-x86_64
  $ SH=hip/S-cg-sys-plain.fsc-x86_64/S-cg-sys-plain.fsc-x86_64

(a) one shared stress header per harness dir, carrying the cuda-litmus citation.
  $ test -f MP-cg-sys-ra.acq/het_stress.h && echo present
  present
  $ grep -c '#include "het_stress.h"' $MP.cu $MPH.hip
  MP-cg-sys-ra.acq/MP-cg-sys-ra.acq.cu:1
  hip/MP-cg-sys-plain.acq-x86_64/MP-cg-sys-plain.acq-x86_64.hip:1
  $ grep -c 'cuda-litmus' MP-cg-sys-ra.acq/het_stress.h > /dev/null && echo cited
  cited

(b) the scratchpad is device memory, never gd_alloc_shared.
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch, sizeof(uint32_t)\*HET_GPU_SCRATCH_WORDS' $MP.cu
  1
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch_loc' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_scratch' $MP.cu || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&_scratch, sizeof(uint32_t)\*HET_GPU_SCRATCH_WORDS' $MPH.hip
  1

(c) the blocks above the test blocks are noise readers and scratchpad stressers.
  $ grep -c 'blockIdx.x >= HET_TEST_BLOCKS' $MP.cu
  1
  $ grep -c '_stressBlocks = (HET_GPU_STRESS_BLOCKS >= 0)' $MP.cu
  1

(d) the stress layer never touches a test location.
  $ grep -oE 'het_scratch_(bump|max|read)\([^,)]*' $MP.cu | sed 's/.*(//' | sort -u
  &_stress_tally[HET_TALLY_NOISE]
  &_stress_tally[HET_TALLY_NOISE_ROUNDS]
  &_stress_tally[HET_TALLY_TRUNC]
  _gpu_iter

(d2) the noise tally counts blocks: thread 0 alone bumps it.
  $ grep -c 'if (_r > 0 && threadIdx.x == 0) het_scratch_bump(&_stress_tally\[HET_TALLY_NOISE\]);' $MP.cu
  1
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_NOISE\]);' $MP.cu
  1

(e) the access pattern is a runtime kernel argument.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_GPU_PRE_STRESS_ROUNDS, _pre_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_GPU_MEM_STRESS_ROUNDS, _mem_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'uint32_t _pre_pat = (uint32_t)HET_GPU_PRE_STRESS_PATTERN;' $MP.cu
  1
  $ grep -c 'uint32_t _mem_pat = (uint32_t)HET_GPU_MEM_STRESS_PATTERN;' $MP.cu
  1

(e2) a cap-exit is flagged once per block.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1
  $ grep -c 'if (_polls >= HET_GPU_STRESS_MAX_POLLS && threadIdx.x == 0)' $MP.cu
  1

(e3) the shipped pattern defaults.
  $ grep -c '#define HET_GPU_PRE_STRESS_PATTERN 3' MP-cg-sys-ra.acq/het_stress.h
  1
  $ grep -c '#define HET_GPU_MEM_STRESS_PATTERN 0' MP-cg-sys-ra.acq/het_stress.h
  1

(f) the stress toggles are drawn device-side from (seed, who, index).
  $ grep -c 'const uint32_t _who = blockIdx.x \* blockDim.x + threadIdx.x;' $MP.cu
  1
  $ grep -c '(int)(het_draw(_seed, _who, 2u\*(uint64_t)_n) % 100u) < HET_GPU_PRE_STRESS_PCT' $MP.cu
  1
  $ grep -c '(int)(het_draw(_seed, HET_WHO_GRID, _v) % 100u) < HET_GPU_MEM_STRESS_PCT' $MP.cu
  1

(f2) the mem-stress toggle is one draw per test iteration.
  $ grep -c 'if (threadIdx.x == 0) _clk = het_scratch_read(_gpu_iter);' $MP.cu
  2
  $ grep -c 'het_scratch_read(_gpu_iter)' $MP.cu
  2
  $ grep -c 'uint32_t _v = _clk;' $MP.cu
  2
  $ grep -c 'het_idle();' $MP.cu
  1

(f2b) no test block reaches an intra-block barrier.
  $ grep -c '__shared__ uint32_t _clk;' $MP.cu
  1
  $ grep -c '__syncthreads();' $MP.cu
  4
  $ sed -n '/if (blockIdx.x >= HET_TEST_BLOCKS) {/,$p' $MP.cu | grep -c '__syncthreads();'
  4

(f3) exactly one test lane publishes the iteration count.
  $ sed -n '/#pragma unroll 1/,/^    }$/p' $MP.cu | grep -c 'het_scratch_bump(_gpu_iter);'
  1

(g) no extra lane for a location column, and every `unroll 1' pragma survives.
  $ grep -c '#pragma unroll 1' $S.cu
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' $S.cu | grep -c 'het_do_stress(_scratch'
  1

(h) the HIP twin renders the same shape from the same template.
  $ grep -c 'het_do_stress(_scratch' $SH.hip
  2
