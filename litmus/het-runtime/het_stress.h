/* het_stress.h -- the GPU memory-stress layer, ported from cuda-litmus;
 * citation is the condition of that reuse [CudaLitmus].  Included by both
 * <test>.cu and <test>.hip; edit litmus/het-runtime/het_stress.h, never a
 * harness-dir copy.  The scratchpad is GPU-only device memory (cudaMalloc /
 * hipMalloc), disjoint from every test location [Sorensen16 sec 1]; the other
 * object classes are in litmus/hetDialect.ml.  It loads the on-die L1/L2 only,
 * NOT the host-device window -- that is het_cpu_stress.h's.
 * Zero without stress is NVIDIA's; Radeon lb fires anyway [Alglave15 sec 4.3.1 Tab. 6].
 * Design: hetlitmus/docs/00-environment-design.md "GPU stress". */
#ifndef HET_STRESS_H
#define HET_STRESS_H

#include <stdint.h>
#include <stdio.h>      /* het_report_spread */
#include "het_cpu_stress.h"   /* het_draw: the stress schedule, host and device */

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* Stress knobs -- a seed, NOT a tuning.  All but HET_GPU_MEM_STRESS_PCT are
 * [CudaLitmus]'s committed params/stress_params.txt: one chip, device scope,
 * GPU-only.  Re-tune on the target hardware [Kirkham20 sec 6.4]; every knob is
 * -D-overridable, so a sweep needs no re-emission. */
#ifndef HET_GPU_SCRATCH_WORDS
#define HET_GPU_SCRATCH_WORDS 4608     /* scratchpad size, in uint32 words     */
#endif
#ifndef HET_GPU_WORDS_PER_REGION
#define HET_GPU_WORDS_PER_REGION 16    /* critical patch size P [Sorensen16 sec 3.2] */
#endif
#ifndef HET_GPU_SPREAD
#define HET_GPU_SPREAD 9               /* spread m: lines at once [Sorensen16 sec 3.4] */
#endif
#ifndef HET_GPU_STRESS_ASSIGN
#define HET_GPU_STRESS_ASSIGN 1        /* 0 = round-robin, 1 = chunking        */
#endif
#ifndef HET_GPU_MEM_STRESS_PCT
#define HET_GPU_MEM_STRESS_PCT 100     /* % of test ITERATIONS the scratchpad is
                                          hammered in; one draw per iteration,
                                          read by every stress block.  100 is
                                          [WebGPULitmus]'s all-stress preset */
#endif
#ifndef HET_GPU_MEM_STRESS_ROUNDS
#define HET_GPU_MEM_STRESS_ROUNDS 445
#endif
/* Divergence from [CudaLitmus]: its MEM_STRESS() [litmus.cuh:346] passes an
   iteration count in do_stress's pattern slot, so the mem-stress loop matches no
   branch; here the pattern is passed as the pattern. */
#ifndef HET_GPU_MEM_STRESS_PATTERN
#define HET_GPU_MEM_STRESS_PATTERN 0   /* 0 = st;st, the only pure writer; stores
                                          alone rank lowest [Sorensen16 sec 3.3] */
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

/* A pattern outside 0..3 matches no branch of het_do_stress's if-chain: the loop
   spins doing nothing while the tally still reads live.  A pattern reaching
   het_do_stress from a config file at run time is outside this guard's reach. */
#if (HET_GPU_PRE_STRESS_PATTERN) < 0 || (HET_GPU_PRE_STRESS_PATTERN) > 3
#error "HET_GPU_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_GPU_MEM_STRESS_PATTERN) < 0 || (HET_GPU_MEM_STRESS_PATTERN) > 3
#error "HET_GPU_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif

#ifndef HET_SEED
#define HET_SEED 1        /* the stress schedule is a function of the seed
                             [GPUHarbor23 sec 3.4]; hardware timing is not, so a
                             run does not repeat.  A run that pins no HET_SEED
                             draws its base from entropy instead; this default is
                             what is left when no draw is available */
#endif
#ifndef HET_GPU_STRESS_BLOCKS
#define HET_GPU_STRESS_BLOCKS (-1)     /* -1 = auto: fill the co-resident grid */
#endif
#ifndef HET_GPU_STRESS_MAX_POLLS
#define HET_GPU_STRESS_MAX_POLLS 10000000u /* safety net, NOT a knob: a stress
                                              block must not spin for ever.  A
                                              poll is one het_do_stress call or
                                              one het_idle, both microseconds,
                                              so this is a wall-time budget */
#endif

/* Liveness tally -- device counters the host reads back: TRUNC = stress blocks
 * that hit HET_GPU_STRESS_MAX_POLLS, NOISE / NOISE_ROUNDS = noise blocks that ran a
 * streaming round and the max any one ran; lane 0 bumps those three, so they
 * count blocks.  STRESS_ROUNDS = max rounds one lane's het_do_stress ran.  None
 * of it enters the tested op stream, so only a counter tells live from folded. */
#define HET_TALLY_TRUNC         0
#define HET_TALLY_NOISE         1
#define HET_TALLY_NOISE_ROUNDS  2
#define HET_TALLY_STRESS_ROUNDS 3
#define HET_TALLY_N             4

/* Scaffolding counters -- compiler builtins, NOT scoped atomics: a builtin
 * lowers to a bare `atom.global.*' with no memory-order qualifier, so this
 * bookkeeping stays out of the tested op stream
 * (hetlitmus/docs/faithfulness.md). */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  /* Device-scope on both vendors, so the poll crosses blocks: HIP folds the
     idempotent RMW to an agent-scope load. */
  return atomicAdd(p, 0u);
}
__device__ static inline void het_scratch_bump(uint32_t* p) {
  (void)atomicAdd(p, 1u);
}
/* atomicMax, NOT atomicAdd: a summed uint32 wraps on a long run, and a
   wrapped-to-zero tally reads exactly like a mechanism that never ran. */
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

/* het_do_stress -- [CudaLitmus] functions.cu:19; the two-instruction access
 * sequence of [Kirkham20 sec 3.1], plain and non-volatile so it adds no ordering
 * edge.  Caller contract: `pattern' must arrive as a RUNTIME value -- folded to
 * a constant, the loop keeps counting with its traffic gone
 * (hetlitmus/docs/faithfulness.md, "Runtime stress pattern"). */
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

/* het_set_scratch_locations -- [CudaLitmus] runner.cu:130, host side.  Picks
 * HET_GPU_SPREAD distinct regions out of HET_GPU_SCRATCH_WORDS /
 * HET_GPU_WORDS_PER_REGION, one random word in each, then maps workgroups onto them
 * (strategy 0 round-robin, 1 chunking).  Divergence from [CudaLitmus]: the dedup
 * here is real, so it can exhaust the region pool -- hence the break. */
#if HET_GPU_SPREAD < 1
#error "HET_GPU_SPREAD must be >= 1 (the spread m)"
#endif
/* The realised spread can be smaller than the knob, silently: chunking gives
   per == 0 when the grid is smaller than HET_GPU_SPREAD, and the tail case
   then dumps every workgroup on the last line -- realised spread 1 while the
   knob still says m.  HET_GPU_STRESS_BLOCKS x HET_GPU_SPREAD is what a hardware
   sweep turns, so count what was assigned and say so. */
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
  /* Zero first, then fill: a stress lane indexes scratchpad[locations[blockIdx.x]],
     so an unwritten entry is an out-of-bounds device write. */
  for (int j = 0; j < num_workgroups; j++) { locations[j] = 0u; }
  for (int i = 0; i < HET_GPU_SPREAD; i++) {
    int region, dup;
    /* A real dedup can exhaust the region pool; stop rather than spin -- the
       targets already drawn are a valid, smaller spread. */
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
