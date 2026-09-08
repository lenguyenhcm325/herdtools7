/* het_stress.h -- the GPU memory-stress layer, ported from cuda-litmus
 * [CudaLitmus]. The scratchpad is device-only memory disjoint from every
 * test location [Sorensen16 sec 1]: on-die caches only, NOT the host-device
 * window.  Design: hetlitmus/docs/00-environment-design.md "GPU stress". */
#ifndef HET_STRESS_H
#define HET_STRESS_H

#include <stdint.h>
#include <stdio.h>      /* het_report_spread */
#include "het_cpu_stress.h"   /* het_draw */

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* Knobs -- a seed, NOT a tuning: [CudaLitmus]'s params/stress_params.txt except
 * HET_GPU_MEM_STRESS_PCT.  Re-tune on the target [Kirkham20 sec 6.4]. */
#ifndef HET_GPU_SCRATCH_WORDS
#define HET_GPU_SCRATCH_WORDS 4608     /* scratchpad size, in uint32 words     */
#endif
#ifndef HET_GPU_WORDS_PER_REGION
#define HET_GPU_WORDS_PER_REGION 16    /* patch size P [Sorensen16 sec 3.2]    */
#endif
#ifndef HET_GPU_SPREAD
#define HET_GPU_SPREAD 9               /* spread m [Sorensen16 sec 3.4]        */
#endif
#ifndef HET_GPU_STRESS_ASSIGN
#define HET_GPU_STRESS_ASSIGN 1        /* 0 = round-robin, 1 = chunking        */
#endif
#ifndef HET_GPU_MEM_STRESS_PCT
#define HET_GPU_MEM_STRESS_PCT 100     /* % of test ITERATIONS hammered, one grid-wide
                                          draw each; 100 = [WebGPULitmus]'s all-stress */
#endif
#ifndef HET_GPU_MEM_STRESS_ROUNDS
#define HET_GPU_MEM_STRESS_ROUNDS 445
#endif
/* Divergence: [CudaLitmus] litmus.cuh:346 passes a count here, matching no branch. */
#ifndef HET_GPU_MEM_STRESS_PATTERN
#define HET_GPU_MEM_STRESS_PATTERN 0   /* 0 = st;st, the pure writer [Sorensen16 sec 3.3] */
#endif
#ifndef HET_GPU_PRE_STRESS_PCT
#define HET_GPU_PRE_STRESS_PCT 65      /* % of iterations a test lane self-stresses */
#endif
#ifndef HET_GPU_PRE_STRESS_ROUNDS
#define HET_GPU_PRE_STRESS_ROUNDS 57
#endif
#ifndef HET_GPU_PRE_STRESS_PATTERN
#define HET_GPU_PRE_STRESS_PATTERN 3   /* 3 = ld;ld                            */
#endif

/* Outside 0..3 no branch matches and the loop spins while the tally reads live. */
#if (HET_GPU_PRE_STRESS_PATTERN) < 0 || (HET_GPU_PRE_STRESS_PATTERN) > 3
#error "HET_GPU_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_GPU_MEM_STRESS_PATTERN) < 0 || (HET_GPU_MEM_STRESS_PATTERN) > 3
#error "HET_GPU_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif

#ifndef HET_SEED
#define HET_SEED 1        /* the schedule is a function of the seed
                             [GPUHarbor23 sec 3.4]; the fallback when no
                             entropy draw is available */
#endif
#ifndef HET_GPU_STRESS_BLOCKS
#define HET_GPU_STRESS_BLOCKS (-1)     /* -1 = auto: fill the co-resident grid */
#endif
#ifndef HET_GPU_STRESS_MAX_POLLS
#define HET_GPU_STRESS_MAX_POLLS 10000000u /* safety net, NOT a knob: a poll is
                                              microseconds, so this bounds wall time */
#endif

/* Liveness tally the host reads back: TRUNC = blocks that hit HET_GPU_STRESS_MAX_POLLS;
 * NOISE / NOISE_ROUNDS = noise blocks that ran a round / the max any ran (lane 0
 * bumps, so blocks); STRESS_ROUNDS = max rounds one lane's het_do_stress ran. */
#define HET_TALLY_TRUNC         0
#define HET_TALLY_NOISE         1
#define HET_TALLY_NOISE_ROUNDS  2
#define HET_TALLY_STRESS_ROUNDS 3
#define HET_TALLY_N             4

/* Compiler builtins, NOT scoped atomics: a bare `atom.global.*' stays out of the
 * tested op stream (hetlitmus/docs/faithfulness.md). */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  /* Device scope on both vendors, so the poll crosses blocks. */
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

/* [CudaLitmus] functions.cu:19, the pair of [Kirkham20 sec 3.1], plain so it adds
 * no ordering edge.  `pattern' must be a RUNTIME value, or the loop counts on with
 * its traffic folded away (hetlitmus/docs/faithfulness.md "Runtime stress pattern"). */
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

/* [CudaLitmus] runner.cu:130, host side: HET_GPU_SPREAD distinct regions, a random
 * word each, assigned round-robin or chunked.  Divergence: a real dedup. */
#if HET_GPU_SPREAD < 1
#error "HET_GPU_SPREAD must be >= 1 (the spread m)"
#endif
/* Chunking realises fewer lines than the knob when the grid is smaller than
   HET_GPU_SPREAD, so count what was assigned. */
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
    /* The pool can run out; the targets drawn so far are a valid smaller spread. */
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
