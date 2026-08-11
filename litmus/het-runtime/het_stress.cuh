/* =========================================================================
 * het_stress.cuh -- HetLitmus GPU memory-stress layer.
 * Emitted verbatim into every harness dir; edit litmus/het-runtime/het_stress.cuh,
 * never a harness-dir copy.  Included by both <test>.cu and <test>.hip.
 * Maintainer notes: litmus/het-runtime/README.md; spec: env-research/Q5-gpu-stress.md.
 *
 * Code source, and the condition of its reuse.  Ported from cuda-litmus (Reese
 * Levine), https://github.com/reeselevine/cuda-litmus -- functions.cu (do_stress,
 * spin, permute_id, stripe_workgroup), litmus.cuh (StressParams/KernelParams,
 * PRE_STRESS, MEM_STRESS), runner.cu (setScratchLocations, percentageCheck).  That
 * repository carries no licence file, and reuse here is cleared on condition of
 * CITATION -- so each mechanism keeps both its code source and its defining paper:
 *
 *   scratchpad; critical patch size P; access sequence sigma; spread m;
 *   occupancy-scaled stressing-thread count
 *     -- Sorensen & Donaldson, "Exposing Errors Related to Weak Memory in GPU
 *        Applications", PLDI'16, sections 1 and 3.  Nvidia silicon only -- see
 *        the VENDOR SPLIT below.
 *   the named stress-parameter space, its autotuning, the reproducibility bound
 *     -- Kirkham, Sorensen, Tureci, Martonosi, "Foundations of Empirical Memory
 *        Consistency Testing", OOPSLA'20, section 3.1.
 *   the four incantations (memory stress, thread synchronisation, thread
 *   randomisation, occupancy) and the busy-wait deadlock guard
 *     -- Alglave et al., "GPU Concurrency: Weak Behaviours and Programming
 *        Assumptions", ASPLOS'15, section 4.3.
 *   the co-prime permutation / Parallel Test Environment
 *     -- Levine et al., "MC Mutants", ASPLOS'23, section 4.1.
 *   the seeded Park-Miller RNG, so a run replays from its seed
 *     -- Levine et al., "GPUHarbor", ISSTA'23, section 3.4.
 *
 * VENDOR SPLIT -- keep the qualifier; this header is included by the AMD .hip
 * render too.  On Nvidia silicon the stress layer decides whether anything is
 * observed at all: Alglave 4.3.1 reports sb and lb at zero on a GTX Titan in every
 * column without memory stress.  On AMD it is a rate amplifier, not an on/off
 * switch -- the same table has lb at 10959/100k on a Radeon HD 7970 with no
 * incantations at all.  "Zero without stress" is an Nvidia result and stays scoped
 * to Nvidia.  (env-research/impl-briefs/B4-fix-impl-brief.md, issue 4.)
 *
 * Object classes.  The scratchpad below is GPU-only device memory (cudaMalloc /
 * hipMalloc), disjoint from every test location -- that disjointness is what keeps
 * the stress sound (S&D).  The shared litmus variables and the cross-device
 * barrier are a different class and go through gd_alloc_shared; the full list of
 * classes lives at litmus/hetDialect.ml, gd_shared_mem_defs / gd_noise_mem_defs.
 *
 * Reach.  The scratchpad hammers the GPU's on-die L1/L2.  It does not by itself
 * widen the CPU-GPU (NVLink-C2C) window; that needs interconnect-crossing traffic
 * and is het_cpu_stress.h's job.
 *
 * Three deliberate divergences from cuda-litmus, each stated where it lives:
 *   * the MEM_STRESS pattern-argument slot, which upstream fills with an
 *     iteration count (at HET_MEM_STRESS_PATTERN);
 *   * the region dedup: upstream declares a used-region set and queries it, but
 *     NEVER INSERTS INTO IT, so it never dedups and its realised spread is <= m
 *     (at het_set_scratch_locations);
 *   * the access pattern, which must stay a runtime value or the loop is deleted
 *     (at het_do_stress).
 * Forensics: env-research/impl-briefs/B4-impl-brief.md and B4-fix-impl-brief.md.
 * ========================================================================= */
#ifndef HET_STRESS_CUH
#define HET_STRESS_CUH

#include <stdint.h>
#include <stdio.h>      /* het_report_spread: a degraded stress layer must say so */

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* -------------------------------------------------------------------------
 * Stress knobs -- A SEED, NOT A TUNED CONFIGURATION.  These are cuda-litmus's
 * committed params/stress_params.txt: a device-scope, GPU-only autotuner output,
 * produced while the MEM_STRESS pattern bug (below) held its mem-stress knobs
 * inert.  HetLitmus tests system scope across a CPU-GPU interconnect, and Kirkham
 * OOPSLA'20 6.4 records that "parameters for one chip may not be optimal on
 * another chip, even from the same vendor."  Re-tune on the target hardware; every
 * knob is -D-overridable so a sweep needs no re-emission.
 * ------------------------------------------------------------------------- */
#ifndef HET_SCRATCH_SIZE
#define HET_SCRATCH_SIZE 4608          /* scratchpad size, in uint32 words     */
#endif
#ifndef HET_STRESS_LINE_SIZE
#define HET_STRESS_LINE_SIZE 16        /* S&D "critical patch size" P          */
#endif
#ifndef HET_STRESS_TARGETS
#define HET_STRESS_TARGETS 9           /* S&D "spread" m: lines hammered at once */
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
/* Divergence from cuda-litmus: an upstream bug we do not reproduce.  Upstream's
   MEM_STRESS() [litmus.cuh:346] passes `pre_stress_iterations' in do_stress's
   PATTERN slot, where PRE_STRESS() [litmus.cuh:338] passes `pre_stress_pattern'.
   do_stress's if-chain has no else and the committed config sets
   preStressIterations=57, so mem-stress spins 445 times matching no branch and
   memStressPattern is never read; with preStressPattern=3 (ld;ld) that leaves the
   shipped configuration never writing the scratchpad at all.  HetLitmus passes the
   pattern correctly, so scratchpad store traffic appears here for the first time.
   Consequence: upstream's params/stress_params.txt is not a valid tuning seed for
   us, and re-tuning on the target hardware is mandatory. */
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
   stress loop spin doing nothing, silently -- which is how the upstream
   MEM_STRESS bug hid.  A stress layer that quietly does nothing falsifies every
   non-observation it produces, so refuse to compile instead.  A pattern sourced
   from a config file at RUN time is outside this guard's reach and must be
   validated there. */
#if (HET_PRE_STRESS_PATTERN) < 0 || (HET_PRE_STRESS_PATTERN) > 3
#error "HET_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_MEM_STRESS_PATTERN) < 0 || (HET_MEM_STRESS_PATTERN) > 3
#error "HET_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif

#ifndef HET_BARRIER_PCT
#define HET_BARRIER_PCT 68             /* % of iterations the GPU test lanes
                                          hit the device-scope window-opener   */
#endif
#ifndef HET_SEED
#define HET_SEED 1                     /* fixed => a run replays from its seed
                                          (GPUHarbor).  The HET_SEED env var
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
 * LIVENESS TALLY.  Device counters the host reads back and prints.  Everything in
 * this file is invisible to the L0 faithfulness gate by design -- stress is
 * scaffolding, not a tested op -- so only a runtime counter can tell a live stress
 * layer from one the compiler folded away or the co-residency cap squeezed to
 * zero, and a dead one still yields a clean-looking "Never".
 *
 *   RDV / CAP     how each het_spin ended: rendezvous, or the 1024-spin deadlock
 *                 cap.  A mostly-CAP spin is a fixed-length delay loop, not a
 *                 window-opener; the ratio is also the datum HET_BARRIER_PCT is
 *                 tuned against.
 *   TRUNC         stress lanes that hit HET_STRESS_MAX_ROUNDS, i.e. stopped
 *                 stressing while tested lanes were still running.  Such a run is
 *                 not comparable with a fully stressed one.
 *   NOISE /       interconnect-noise blocks that completed at least one streaming
 *   NOISE_ROUNDS  round, and the max rounds any one block completed.  Zero NOISE
 *                 with the noise enabled means the run is not C2C-stressed.
 *   STRESS_ROUNDS max rounds any one het_do_stress call completed.  It proves the
 *                 loop RAN; that the loop still contains its scratchpad accesses
 *                 is hetlitmus/verify/stresscheck.py's job.  Neither check
 *                 subsumes the other.
 *
 * The *_ROUNDS counters use atomicMax, not atomicAdd: a summed uint32 round count
 * wraps on a long run, and a wrapped-to-zero tally reads exactly like a mechanism
 * that never ran.
 * ------------------------------------------------------------------------- */
#define HET_TALLY_RDV           0
#define HET_TALLY_CAP           1
#define HET_TALLY_TRUNC         2
#define HET_TALLY_NOISE         3
#define HET_TALLY_NOISE_ROUNDS  4
#define HET_TALLY_STRESS_ROUNDS 5
#define HET_TALLY_N             6

/* -------------------------------------------------------------------------
 * Seeded Park-Miller (Lehmer minimal-standard) RNG.       [GPUHarbor ISSTA'23]
 *
 * Adaptation: cuda-litmus re-rolls its probabilistic toggles on the HOST and
 * cudaMemcpy's a fresh KernelParams before every relaunch.  This kernel is
 * perpetual -- launched once, looping inside -- so there is no per-iteration host
 * round-trip and the toggles are decided device-side.  Seeding per (lane, run)
 * from a fixed seed keeps a run replayable.  (Q5-gpu-stress.md 3.4.)
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
/* cuda-litmus's percentageCheck (runner.cu:106), moved device-side. */
__device__ __host__ static inline int het_rng_pct(het_rng_t* r, int pct) {
  return (int)(het_rng_next(r) % 100u) < pct;
}

/* -------------------------------------------------------------------------
 * Scaffolding counters.  Deliberately compiler BUILTINS, not libcu++/HIP scoped
 * atomics: these are bookkeeping on a device-only scratch word, not memory-model
 * ops of the test.  A builtin lowers to a bare `atom.global.*' carrying no
 * memory-order qualifier, outside the PTX inline-asm markers, so it stays out of
 * the op stream hetlitmus/verify/ptxcheck.py compares -- which is correct, it is
 * not a tested op.  Reading through an RMW (add 0) resolves in L2, so no
 * L1-caching question arises.
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
 * het_do_stress -- cuda-litmus functions.cu:19, loop body ported verbatim.  Each
 * stressing thread repeats a 2-instruction access sequence on its workgroup's
 * scratch line: pattern 0 = st;st, 1 = st;ld, 2 = ld;st, 3 = ld;ld (Kirkham's
 * AccessPattern A0;A1; S&D's longer sigma is not implemented upstream and is not
 * reproduced here).  Pattern 0 is the only pure writer, and store traffic --
 * invalidating lines, forcing ownership transfer -- is the strong stressor.
 *
 * CALLER CONTRACT: `pattern' must arrive as a runtime value (a kernel argument).
 * Handed a compile-time constant, nvcc folds the if-chain to one branch, and
 * branch 3 (ld;ld, the tuned pre-stress default) is side-effect-free, so the
 * entire loop is deleted while the source still reads correctly.  The accesses are
 * deliberately plain and non-volatile -- upstream's -- so the traffic is ordinary
 * cacheable traffic that thrashes the testing thread's own L1 (Kirkham 3.1) and
 * adds no ordering edge to the test; keeping them plain is what makes the runtime
 * pattern load-bearing rather than a style choice.  hetlitmus/verify/stresscheck.py
 * fails the build if the pattern becomes a -D again: it asserts the PTX
 * scratchpad-op count is invariant under -DHET_*_PATTERN, the property a
 * compile-time pattern destroys.  (B4-fix-impl-brief.md, issue 1.)
 *
 * Added here, not upstream: the [tally] parameter and the closing het_scratch_max.
 * The counter is taken outside the loop, so the stress traffic itself is
 * byte-for-byte upstream's and no atomic lands in the stress stream.
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
 * het_spin -- the device-scope window-opener.  cuda-litmus functions.cu:10
 * (`spin'); Alglave ASPLOS'15 4.3.4 (thread synchronisation: atomically increment
 * a counter and busy-wait, taking care to avoid deadlock).
 *
 * It aligns the GPU test lanes of one instance so their critical accesses race.
 * It is NOT the cross-device rendezvous: that is the system-scope gd_bar in the
 * driver, which fires once, outside the perpetual loop.  A per-iteration
 * cross-device barrier would mask the tested order and stall (Srivastava 4.1), so
 * the two stay separate -- different scope, variable and lifetime.  This one sits
 * on a scratch word that is not a test location, so it adds no ordering edge.
 *
 * Deadlock guard, verbatim from upstream: the wait is capped at 1024 spins.  GPUs
 * give no forward-progress guarantee across workgroups, so a lane waiting on an
 * unscheduled lane would hang the kernel, and a silent hang is indistinguishable
 * from a genuine non-observation.  A cap exit is a barrier that did not
 * rendezvous, so each exit is tallied by reason (RDV / CAP) and the host prints
 * the ratio; that print is the only way this mechanism can be seen to be alive.
 *
 * CALLER CONTRACT (perpetual loop).  Upstream relaunches per test iteration, so
 * its counter is fresh each time and it waits for `blockDim.x *
 * testing_workgroups' -- Alglave 4.3.4, "busy-waiting until the counter reaches
 * the number of threads participating in the test".  This kernel loops inside, so
 * the counter only ever grows.  The caller must therefore (a) pass a limit indexed
 * by the number of barriers TAKEN SO FAR (_nb * lanes), and (b) draw the take/skip
 * roll from a lane-independent stream, seeded by the iteration rather than the
 * lane.  Then every lane takes the same barriers, contributes exactly one
 * increment to each, and the counter reaches _nb*lanes exactly when the last lane
 * arrives.  A per-lane draw makes the limit unreachable from the first skipped
 * roll onward and turns every spin into a full 1024-iteration delay loop that
 * aligns nothing.  Upstream is immune because its toggle is one host-set boolean,
 * uniform across the launch [litmus.cuh:340].  (B4-fix-impl-brief.md, issue 2.)
 * ------------------------------------------------------------------------- */
__device__ static void het_spin(uint32_t* barrier, uint32_t limit,
                                uint32_t* tally) {
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
  uint32_t val = __hip_atomic_fetch_add(barrier, 1u, __ATOMIC_RELAXED,
                                        __HIP_MEMORY_SCOPE_AGENT);
  int i = 0;
  while (i < 1024 && val < limit) {
    val = __hip_atomic_load(barrier, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT);
    i++;
  }
#else
  cuda::atomic_ref<uint32_t, cuda::thread_scope_device> _b(*barrier);
  uint32_t val = _b.fetch_add(1u, cuda::memory_order_relaxed);
  int i = 0;
  while (i < 1024 && val < limit) {
    val = _b.load(cuda::memory_order_relaxed);
    i++;
  }
#endif
  /* (val >= limit) is the loop's success exit; anything else means i hit 1024
     with the counter still short. */
  het_scratch_bump(&tally[(val >= limit) ? HET_TALLY_RDV : HET_TALLY_CAP]);
}

/* -------------------------------------------------------------------------
 * het_set_scratch_locations -- cuda-litmus runner.cu:130 (`setScratchLocations'),
 * host side.  Picks HET_STRESS_TARGETS distinct stress lines at random out of
 * (HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE) regions, one random word within each,
 * then maps workgroups onto those lines:
 *
 *   strategy 0 (round-robin): consecutive workgroups -> separate lines
 *   strategy 1 (chunking):    a run of consecutive workgroups -> the same line
 *
 * Distinct lines keep each stresser on a fresh cache line (S&D's critical patch);
 * the spread controls how many lines are contended at once.  Driven by rand(),
 * which the driver seeds per run, so the layout is replayable.
 *
 * Divergence from cuda-litmus: WE DEDUP, upstream only looks like it does.
 * Upstream declares `std::set<int> usedRegions' [runner.cu:131] and guards its
 * draw with it [runner.cu:135] but never inserts into the set, so count() is
 * always 0, the guard never spins, and two of its stressTargetLines can land on
 * the same region; its realised spread is <= m, not m.  The scan below is the dedup
 * upstream intended.  Consequences: upstream's tuned m is not our m (a second
 * reason re-tuning is mandatory), and our scan can exhaust the region pool, which
 * upstream's dead code could not -- hence the explicit break.
 * ------------------------------------------------------------------------- */
#if HET_STRESS_TARGETS < 1
#error "HET_STRESS_TARGETS must be >= 1 (it is S&D's spread m)"
#endif
/* The realised spread can be smaller than the knob, silently: chunking divides
   num_workgroups by HET_STRESS_TARGETS, so a grid smaller than the target count
   gives per == 0 and the tail case dumps every workgroup on the last line --
   realised spread 1, while the knob still says m.  Round-robin degrades more
   gently but still leaves targets unused.  The stress is then weaker than the
   configuration claims, and the stress tuner sweeps exactly these knobs
   (HET_STRESS_BLOCKS x HET_STRESS_TARGETS), so it must never score a spread-1
   config as if it were spread-m.  Count what was actually assigned and say so.
   (Q5-gpu-stress.md 8.) */
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
            "lines (S&D's spread m).  The stress is weaker than the configuration "
            "says; raise the grid or lower HET_STRESS_TARGETS.\n",
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
    /* Our dedup is real (upstream's is dead code, see above), so it can exhaust
       the region pool and spin forever.  Stop instead -- the targets already drawn
       are still a valid, smaller spread. */
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

#endif /* HET_STRESS_CUH */
