/* Adapted from [CudaLitmus]. */
#ifndef HET_STRESS_H
#define HET_STRESS_H

#include <stdint.h>
#include <stdio.h>
#include "het_cpu_stress.h"

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* Defaults from [CudaLitmus params/stress_params.txt], except
 * HET_GPU_MEM_STRESS_PCT; tune them on the GPU under test, since settings
 * tuned on one chip may not suit another [Kirkham20]. */
#ifndef HET_GPU_SCRATCH_WORDS
#define HET_GPU_SCRATCH_WORDS 4608     /* uint32 words */
#endif
#ifndef HET_GPU_WORDS_PER_REGION
#define HET_GPU_WORDS_PER_REGION 16
#endif
#ifndef HET_GPU_SPREAD
#define HET_GPU_SPREAD 9
#endif
#ifndef HET_GPU_STRESS_ASSIGN
#define HET_GPU_STRESS_ASSIGN 1        /* 0 = round-robin, 1 = chunking */
#endif
#ifndef HET_GPU_MEM_STRESS_PCT
/* 100 is webgpu-litmus's allStressConfig,
   https://github.com/reeselevine/webgpu-litmus/blob/c7234af7cefd90f7206152b9255eee3e58ff989c/components/stressPanel.js#L190 */
#define HET_GPU_MEM_STRESS_PCT 100     /* % of iterations */
#endif
#ifndef HET_GPU_MEM_STRESS_ROUNDS
#define HET_GPU_MEM_STRESS_ROUNDS 445
#endif
#ifndef HET_GPU_MEM_STRESS_PATTERN
#define HET_GPU_MEM_STRESS_PATTERN 0   /* 0 = st;st */
#endif
#ifndef HET_GPU_PRE_STRESS_PCT
#define HET_GPU_PRE_STRESS_PCT 65      /* % of iterations */
#endif
#ifndef HET_GPU_PRE_STRESS_ROUNDS
#define HET_GPU_PRE_STRESS_ROUNDS 57
#endif
#ifndef HET_GPU_PRE_STRESS_PATTERN
#define HET_GPU_PRE_STRESS_PATTERN 3   /* 3 = ld;ld */
#endif

#if (HET_GPU_PRE_STRESS_PATTERN) < 0 || (HET_GPU_PRE_STRESS_PATTERN) > 3
#error "HET_GPU_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_GPU_MEM_STRESS_PATTERN) < 0 || (HET_GPU_MEM_STRESS_PATTERN) > 3
#error "HET_GPU_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif

#ifndef HET_SEED
#define HET_SEED 1        /* used only when no entropy draw is available */
#endif
#ifndef HET_GPU_STRESS_BLOCKS
#define HET_GPU_STRESS_BLOCKS (-1)     /* -1 = auto: fill the co-resident grid */
#endif
#ifndef HET_GPU_STRESS_MAX_POLLS
#define HET_GPU_STRESS_MAX_POLLS 10000000u
#endif

#define HET_TALLY_TRUNC         0
#define HET_TALLY_NOISE         1
#define HET_TALLY_NOISE_ROUNDS  2
#define HET_TALLY_STRESS_ROUNDS 3
#define HET_TALLY_N             4

/* Compiler builtins, NOT scoped atomics: a bare `atom.global.*' stays out of the
 * tested op stream. */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  return atomicAdd(p, 0u);
}
__device__ static inline void het_scratch_bump(uint32_t* p) {
  (void)atomicAdd(p, 1u);
}
/* atomicMax, NOT atomicAdd: a wrapped sum reads like a mechanism that never ran. */
__device__ static inline void het_scratch_max(uint32_t* p, uint32_t v) {
  (void)atomicMax(p, v);
}
/* An unstressed iteration's wait: it must touch no memory at all. */
__device__ static inline void het_idle(void) {
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
  __builtin_amdgcn_s_sleep(127);
#elif defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700
  __nanosleep(1000u);
#else
  __asm__ __volatile__("");
#endif
}

/* Adapted from [CudaLitmus functions.cu:19] [Kirkham20]; plain, so it
 * adds no ordering edge.  `pattern' must be a runtime value, or nvcc hoists the
 * traffic; nvcc 12.9 for sm_121 merges the ld;ld pair into one load. */
__device__ static void het_do_stress(uint32_t* scratchpad,
                                     uint32_t* scratch_locations,
                                     uint32_t iterations,
                                     uint32_t pattern,
                                     uint32_t* tally) {
  uint32_t rounds = 0;
  for (uint32_t i = 0; i < iterations; i++) {
    if (pattern == 0) {
      scratchpad[scratch_locations[blockIdx.x]] = i;
      scratchpad[scratch_locations[blockIdx.x]] = i + 1;
    } else if (pattern == 1) {
      scratchpad[scratch_locations[blockIdx.x]] = i;
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
    } else if (pattern == 2) {
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
      scratchpad[scratch_locations[blockIdx.x]] = i;
    } else if (pattern == 3) {
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
      uint32_t tmp2 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp2 > 100) { break; }
    }
    rounds++;
  }
  het_scratch_max(&tally[HET_TALLY_STRESS_ROUNDS], rounds);
}

/* Adapted from [CudaLitmus runner.cu:130]. */
#if HET_GPU_SPREAD < 1
#error "HET_GPU_SPREAD must be >= 1 (the spread m)"
#endif
__host__ static void het_report_spread(const uint32_t* locations, int num_workgroups) {
  int distinct = 0;
  for (int i = 0; i < num_workgroups; i++) {
    int seen = 0;
    for (int j = 0; j < i; j++) { if (locations[j] == locations[i]) { seen = 1; break; } }
    if (!seen) distinct++;
  }
  if (distinct < HET_GPU_SPREAD) {
    fprintf(stderr,
            "HetLitmus WARNING: realised stress spread is %d line(s), not "
            "HET_GPU_SPREAD=%d -- %d stressing workgroup(s) cannot cover %d "
            "lines.  The stress is weaker than the configuration says; raise "
            "the grid or lower HET_GPU_SPREAD.\n",
            distinct, (int)HET_GPU_SPREAD, num_workgroups,
            (int)HET_GPU_SPREAD);
  }
}
__host__ static void het_set_scratch_locations(uint32_t* locations,
                                              int num_workgroups,
                                              uint32_t seed) {
  int num_regions = HET_GPU_SCRATCH_WORDS / HET_GPU_WORDS_PER_REGION;
  int used[HET_GPU_SPREAD];
  int n_used = 0;
  uint64_t k = 0;
  /* Zero first: an unwritten entry is an out-of-bounds device write. */
  for (int j = 0; j < num_workgroups; j++) { locations[j] = 0u; }
  for (int i = 0; i < HET_GPU_SPREAD; i++) {
    int region, dup;
    if (n_used >= num_regions) { break; }
    do {
      region = (int)(het_draw(seed, HET_WHO_SCRATCH, k++) % (uint32_t)num_regions);
      dup = 0;
      for (int u = 0; u < n_used; u++) { if (used[u] == region) { dup = 1; break; } }
    } while (dup);
    used[n_used++] = region;
    int loc_in_region = (int)(het_draw(seed, HET_WHO_SCRATCH, k++)
                              % (uint32_t)HET_GPU_WORDS_PER_REGION);
    uint32_t target = (uint32_t)(region * HET_GPU_WORDS_PER_REGION + loc_in_region);
#if HET_GPU_STRESS_ASSIGN == 0
    for (int j = i; j < num_workgroups; j += HET_GPU_SPREAD) {
      locations[j] = target;
    }
#else
    {
      int per = num_workgroups / HET_GPU_SPREAD;
      for (int j = 0; j < per; j++) { locations[i * per + j] = target; }
      if (i == HET_GPU_SPREAD - 1 && num_workgroups % HET_GPU_SPREAD != 0) {
        for (int j = 0; j < num_workgroups % HET_GPU_SPREAD; j++) {
          locations[num_workgroups - j - 1] = target;
        }
      }
    }
#endif
  }
  het_report_spread(locations, num_workgroups);
}

#endif /* HET_STRESS_H */
