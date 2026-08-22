/* =========================================================================
 * het_stress.h -- HetLitmus GPU memory-stress layer.
 * Emitted verbatim into every harness dir; edit litmus/het-runtime/het_stress.h,
 * never a harness-dir copy.  Included by both <test>.cu and <test>.hip.
 * Maintainer notes: litmus/het-runtime/README.md; design:
 * hetlitmus/docs/00-environment-design.md sec 3.5.
 *
 * Code source, and the condition of the reuse.  This layer is ported from the
 * cuda-litmus repository, https://github.com/reeselevine/cuda-litmus
 * [CudaLitmus], which carries no licence file; citation is the condition of that
 * reuse, so every mechanism keeps its code source and its defining paper:
 *   scratchpad; critical patch size P; access sequence sigma; spread m;
 *   occupancy-scaled stressing-thread count [Sorensen16 sec 1, 3.2-3.4]
 *   the stress-parameter space          [Kirkham20 sec 3.1]
 *   the four incantations and the busy-wait deadlock guard
 *                                           [Alglave15 sec 4.3]
 *   the co-prime permutation / Parallel Test Environment
 *                                           [MCMutants23 sec 4.1]
 *   the seeded Park-Miller RNG, so a run replays from its seed
 *                                           [GPUHarbor23 sec 3.4]
 *
 * VENDOR SPLIT, stated once, here, because the AMD .hip render includes this
 * header too.  On the NVIDIA part measured, the stress layer decides whether
 * the inter-CTA lb and sb shapes are observed at all: both sit at zero on a GTX
 * Titan in every column without memory stress, while lb reaches 10959 per 100k
 * on a Radeon HD 7970 with no incantation at all [Alglave15 sec 4.3.1 Tab.6].
 * On AMD it is a rate amplifier, not an on/off switch, and "zero without
 * stress" is an NVIDIA result that stays scoped to NVIDIA.
 *
 * The scratchpad is GPU-only device memory (cudaMalloc / hipMalloc), disjoint
 * from every test location; that disjointness is what keeps the stress sound
 * [Sorensen16 sec 1].  The other object classes are listed at
 * litmus/hetDialect.ml, gd_shared_mem_defs / gd_noise_mem_defs.  It hammers the
 * GPU's on-die L1/L2 and does not by itself widen the host-device window --
 * that is het_cpu_stress.h's job.
 * ========================================================================= */
#ifndef HET_STRESS_H
#define HET_STRESS_H

#include <stdint.h>
#include <stdio.h>      /* het_report_spread: a degraded stress layer must say so */

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* -------------------------------------------------------------------------
 * Stress knobs -- A SEED, NOT A TUNED CONFIGURATION.  These are [CudaLitmus]'s
 * committed params/stress_params.txt: a device-scope, GPU-only tuning output,
 * produced while the MEM_STRESS pattern defect (below) held its mem-stress knobs
 * inert.  HetLitmus tests system scope across a host-device interconnect, and
 * "parameters for one chip may not be optimal on another chip, even from the same
 * vendor" [Kirkham20 sec 6.4].  Re-tune on the target hardware; every knob is
 * -D-overridable so a sweep needs no re-emission.
 * ------------------------------------------------------------------------- */
#ifndef HET_SCRATCH_SIZE
#define HET_SCRATCH_SIZE 4608          /* scratchpad size, in uint32 words     */
#endif
#ifndef HET_STRESS_LINE_SIZE
#define HET_STRESS_LINE_SIZE 16        /* critical patch size P [Sorensen16]   */
#endif
#ifndef HET_STRESS_TARGETS
#define HET_STRESS_TARGETS 9           /* spread m [Sorensen16]: lines at once  */
#endif
#ifndef HET_STRESS_ASSIGN
#define HET_STRESS_ASSIGN 1            /* 0 = round-robin, 1 = chunking        */
#endif
#ifndef HET_MEM_STRESS_PCT
#define HET_MEM_STRESS_PCT 20          /* % of rounds a stress lane hammers    */
#endif
#ifndef HET_MEM_STRESS_ITER
#define HET_MEM_STRESS_ITER 445
#endif
/* Divergence from [CudaLitmus]: its MEM_STRESS() [litmus.cuh:346] passes
   `pre_stress_iterations' in do_stress's PATTERN slot, where PRE_STRESS()
   [litmus.cuh:338] passes `pre_stress_pattern'.  The if-chain has no else, so
   with the committed preStressIterations=57 the mem-stress loop matches no branch
   and memStressPattern is never read; preStressPattern=3 (ld;ld) then leaves that
   configuration never writing the scratchpad at all.  Here the pattern is passed
   as the pattern, which is why params/stress_params.txt is NOT a valid tuning
   seed and re-tuning on the target hardware is mandatory. */
#ifndef HET_MEM_STRESS_PATTERN
#define HET_MEM_STRESS_PATTERN 0       /* 0 = st;st, the only PURE writer       */
#endif
#ifndef HET_PRE_STRESS_PCT
#define HET_PRE_STRESS_PCT 65          /* % of iterations a TEST lane self-stresses */
#endif
#ifndef HET_PRE_STRESS_ITER
#define HET_PRE_STRESS_ITER 57
#endif
#ifndef HET_PRE_STRESS_PATTERN
#define HET_PRE_STRESS_PATTERN 3       /* 3 = ld;ld                            */
#endif

/* het_do_stress's if-chain has no else, so a pattern outside 0..3 makes the
   stress loop spin doing nothing, silently -- which is how the MEM_STRESS defect
   above stays invisible.  A stress layer that quietly does nothing falsifies every
   non-observation it produces, so refuse to compile instead.  A pattern sourced
   from a config file at RUN time is outside this guard's reach and must be
   validated there. */
#if (HET_PRE_STRESS_PATTERN) < 0 || (HET_PRE_STRESS_PATTERN) > 3
#error "HET_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_MEM_STRESS_PATTERN) < 0 || (HET_MEM_STRESS_PATTERN) > 3
#error "HET_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif

#ifndef HET_SEED
#define HET_SEED 1                     /* fixed => a run replays from its seed
                                          [GPUHarbor23].  The HET_SEED env var
                                          overrides it at run time, so the campaign
                                          scheduler can vary the seed base without
                                          a rebuild per invocation.            */
#endif
#ifndef HET_STRESS_BLOCKS
#define HET_STRESS_BLOCKS (-1)         /* -1 = auto: fill the co-resident grid */
#endif
#ifndef HET_STRESS_MAX_ROUNDS
#define HET_STRESS_MAX_ROUNDS 1000000000u  /* safety net only: a stress lane must
                                          never outlive a hung test lane for
                                          ever.  NOT a tuning knob.            */
#endif

/* -------------------------------------------------------------------------
 * LIVENESS TALLY.  Device counters the host reads back and prints.  Nothing in
 * this file enters the tested op stream -- correctly: stress is scaffolding, not
 * a tested op -- so no static reading of the harness can see it, and only a
 * runtime counter tells a live stress layer from one the compiler folded away or
 * the co-residency cap squeezed to zero.  A dead one still yields a
 * clean-looking "Never".
 *
 *   TRUNC         stress lanes that hit HET_STRESS_MAX_ROUNDS, i.e. stopped
 *                 stressing while tested lanes were still running.  Such a run is
 *                 not comparable with a fully stressed one.
 *   NOISE /       interconnect-noise blocks that completed at least one streaming
 *   NOISE_ROUNDS  round, and the max rounds any one block completed.  Zero NOISE
 *                 with the noise enabled means the run is not C2C-stressed.
 *   STRESS_ROUNDS max rounds any one het_do_stress call completed.  It proves the
 *                 loop RAN; whether that loop still contains its scratchpad
 *                 accesses is a static question, and neither answer subsumes the
 *                 other.
 *
 * The *_ROUNDS counters use atomicMax, not atomicAdd: a summed uint32 round count
 * wraps on a long run, and a wrapped-to-zero tally reads exactly like a mechanism
 * that never ran.
 * ------------------------------------------------------------------------- */
#define HET_TALLY_TRUNC         0
#define HET_TALLY_NOISE         1
#define HET_TALLY_NOISE_ROUNDS  2
#define HET_TALLY_STRESS_ROUNDS 3
#define HET_TALLY_N             4

/* -------------------------------------------------------------------------
 * Seeded Park-Miller (Lehmer minimal-standard) RNG.            [GPUHarbor23 sec 3.4]
 *
 * Adaptation: [CudaLitmus] re-rolls its probabilistic toggles on the HOST and
 * cudaMemcpy's a fresh KernelParams before every relaunch.  This kernel is
 * perpetual -- launched once, looping inside -- so there is no per-iteration host
 * round-trip and the toggles are decided device-side.  Seeding per (lane, run)
 * from a fixed seed keeps a run replayable.
 * ------------------------------------------------------------------------- */
typedef struct { uint32_t s; } het_rng_t;

__device__ __host__ static inline het_rng_t het_rng_init(uint32_t seed, uint32_t lane) {
  het_rng_t r;
  uint32_t s = (seed ^ (lane * 2654435761u)) % 2147483647u;
  if (s == 0u) s = 1u;             /* Park-Miller degenerates at 0 */
  r.s = s;
  return r;
}
__device__ __host__ static inline uint32_t het_rng_next(het_rng_t* r) {
  r->s = (uint32_t)(((uint64_t)r->s * 16807ull) % 2147483647ull);
  return r->s;
}
/* [CudaLitmus]'s percentageCheck (runner.cu:106), moved device-side. */
__device__ __host__ static inline int het_rng_pct(het_rng_t* r, int pct) {
  return (int)(het_rng_next(r) % 100u) < pct;
}

/* -------------------------------------------------------------------------
 * Scaffolding counters.  Deliberately compiler BUILTINS, not libcu++/HIP scoped
 * atomics: these are bookkeeping on a device-only scratch word, not memory-model
 * ops of the test.  A builtin lowers to a bare `atom.global.*' carrying no
 * memory-order qualifier, outside the PTX inline-asm markers, so it stays out of
 * the tested op stream -- which is correct, it is not a tested op.  Reading
 * through an RMW (add 0) resolves in L2, so no L1-caching question arises.
 * ------------------------------------------------------------------------- */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  return atomicAdd(p, 0u);
}
__device__ static inline void het_scratch_bump(uint32_t* p) {
  (void)atomicAdd(p, 1u);
}
/* Volume counter; see the tally legend above on why this is atomicMax. */
__device__ static inline void het_scratch_max(uint32_t* p, uint32_t v) {
  (void)atomicMax(p, v);
}

/* -------------------------------------------------------------------------
 * het_do_stress -- [CudaLitmus] functions.cu:19, loop body ported verbatim.  Each
 * stressing thread repeats a 2-instruction access sequence on its workgroup's
 * scratch line: pattern 0 = st;st, 1 = st;ld, 2 = ld;st, 3 = ld;ld -- the
 * AccessPattern A0;A1 of [Kirkham20 sec 3.1].  The longer sigma of [Sorensen16
 * sec 3.3], up to five instructions, is in neither.  Pattern 0 is the only pure
 * writer, and in that same section every most-effective sequence mixes loads and
 * stores while on most chips the stores-only ones rank lowest.
 *
 * CALLER CONTRACT: `pattern' must arrive as a runtime value (a kernel argument).
 * Handed a compile-time constant, nvcc folds the if-chain to the one named
 * branch; the shipped pre-stress default (3 = ld;ld) writes nothing, so its
 * loads hoist out of the loop, leaving an empty counting loop that still feeds
 * the tally -- the mechanism reads live while its traffic is gone.  What each
 * compile-time pattern costs is measured in hetlitmus/docs/faithfulness.md.
 * The accesses stay plain and non-volatile, as upstream's are, so they are
 * ordinary cacheable traffic -- fresh lines in, remote lines invalidated
 * [Kirkham20 sec 3.1] -- and add no ordering edge to the test; keeping them
 * plain is what makes the runtime pattern load-bearing rather than a style
 * choice.  That the pattern is still a runtime value is checked by stresscheck.
 *
 * Added here, not upstream: the [tally] parameter and the closing het_scratch_max.
 * The counter is taken outside the loop, so no atomic lands in the stress traffic.
 * ------------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * het_set_scratch_locations -- [CudaLitmus] runner.cu:130 (`setScratchLocations'),
 * host side.  Picks HET_STRESS_TARGETS distinct stress lines at random out of
 * (HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE) regions, one random word within each,
 * then maps workgroups onto those lines:
 *
 *   strategy 0 (round-robin): consecutive workgroups -> separate lines
 *   strategy 1 (chunking):    a run of consecutive workgroups -> the same line
 *
 * Distinct lines keep each stresser on a fresh critical patch [Sorensen16 sec
 * 3.2]; the spread controls how many lines are contended at once.  Driven by
 * rand(), which the driver seeds per run, so the layout is replayable.
 *
 * Divergence from [CudaLitmus]: the dedup here is real, upstream's only looks it.
 * Upstream declares `std::set<int> usedRegions' [runner.cu:131] and guards its
 * draw with it [runner.cu:135] but never inserts into the set, so count() is
 * always 0, the guard never spins, and two of its stressTargetLines can land on
 * the same region; its realised spread is <= m, not m.  Consequences: its tuned m
 * is not this m -- a second reason re-tuning is mandatory -- and a real dedup can
 * exhaust the region pool, which dead code could not, hence the explicit break.
 * ------------------------------------------------------------------------- */
#if HET_STRESS_TARGETS < 1
#error "HET_STRESS_TARGETS must be >= 1 (it is the spread m of [Sorensen16 sec 3.4])"
#endif
/* The realised spread can be smaller than the knob, silently: chunking divides
   num_workgroups by HET_STRESS_TARGETS, so a grid smaller than the target count
   gives per == 0 and the tail case dumps every workgroup on the last line --
   realised spread 1, while the knob still says m.  Round-robin degrades more
   gently but still leaves targets unused.  The stress is then weaker than the
   configuration claims, and these two knobs (HET_STRESS_BLOCKS x
   HET_STRESS_TARGETS) are what a hardware sweep turns, so a spread-1 config must
   never be read as a spread-m one.  Count what was actually assigned and say so. */
__host__ static void het_report_spread(const uint32_t* locations, int num_workgroups) {
  int distinct = 0;
  for (int i = 0; i < num_workgroups; i++) {
    int seen = 0;
    for (int j = 0; j < i; j++) { if (locations[j] == locations[i]) { seen = 1; break; } }
    if (!seen) distinct++;
  }
  if (distinct < HET_STRESS_TARGETS) {
    fprintf(stderr,
            "HetLitmus WARNING: realised stress spread is %d line(s), not "
            "HET_STRESS_TARGETS=%d -- %d stressing workgroup(s) cannot cover %d "
            "lines (the spread m of [Sorensen16 sec 3.4]).  The stress is weaker "
            "than the configuration says; raise the grid or lower "
            "HET_STRESS_TARGETS.\n",
            distinct, (int)HET_STRESS_TARGETS, num_workgroups,
            (int)HET_STRESS_TARGETS);
  }
}
__host__ static void het_set_scratch_locations(uint32_t* locations, int num_workgroups) {
  int num_regions = HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE;
  int used[HET_STRESS_TARGETS];
  int n_used = 0;
  /* Every entry must be a valid index: a stress lane indexes the scratchpad by
     scratchpad[locations[blockIdx.x]], so an unwritten entry would be an
     out-of-bounds device write.  Zero first, then fill, so coverage is a property
     of the code rather than of an argument about it. */
  for (int j = 0; j < num_workgroups; j++) { locations[j] = 0u; }
  for (int i = 0; i < HET_STRESS_TARGETS; i++) {
    int region, dup;
    /* A real dedup (see above) can exhaust the region pool and spin forever.
       Stop instead -- the targets already drawn are still a valid, smaller
       spread. */
    if (n_used >= num_regions) { break; }
    do {
      region = rand() % num_regions;
      dup = 0;
      for (int u = 0; u < n_used; u++) { if (used[u] == region) { dup = 1; break; } }
    } while (dup);
    used[n_used++] = region;
    int loc_in_region = rand() % HET_STRESS_LINE_SIZE;
    uint32_t target = (uint32_t)(region * HET_STRESS_LINE_SIZE + loc_in_region);
#if HET_STRESS_ASSIGN == 0
    for (int j = i; j < num_workgroups; j += HET_STRESS_TARGETS) {
      locations[j] = target;
    }
#else
    {
      int per = num_workgroups / HET_STRESS_TARGETS;
      for (int j = 0; j < per; j++) { locations[i * per + j] = target; }
      if (i == HET_STRESS_TARGETS - 1 && num_workgroups % HET_STRESS_TARGETS != 0) {
        for (int j = 0; j < num_workgroups % HET_STRESS_TARGETS; j++) {
          locations[num_workgroups - j - 1] = target;
        }
      }
    }
#endif
  }
  het_report_spread(locations, num_workgroups);
}

#endif /* HET_STRESS_H */
