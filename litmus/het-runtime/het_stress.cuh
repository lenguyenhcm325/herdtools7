/* =========================================================================
 * het_stress.cuh -- HetLitmus GPU memory-stress layer.
 * Emitted verbatim by litmus7 from litmus/het-runtime/het_stress.cuh (edit the
 * source, never a harness-dir copy); included by <test>.cu/.hip.
 * =========================================================================
 * PORTED, WITH THE ADAPTATIONS NOTED BELOW, FROM cuda-litmus (Reese Levine),
 *   https://github.com/reeselevine/cuda-litmus
 *   -- functions.cu (do_stress, spin, permute_id, stripe_workgroup),
 *      litmus.cuh   (StressParams/KernelParams, PRE_STRESS, MEM_STRESS),
 *      runner.cu    (parseStressParamsFile, setScratchLocations, percentageCheck).
 * The repository carries NO licence file (all-rights-reserved by default);
 * reuse is cleared for this thesis ON CONDITION OF CITATION.  Each mechanism
 * below therefore carries BOTH its code source (cuda-litmus) AND the paper that
 * defines it:
 *
 *   scratchpad; critical patch size P; access sequence sigma; spread m;
 *   occupancy-scaled stressing-thread count
 *     -- Sorensen & Donaldson, "Exposing Errors Related to Weak Memory in GPU
 *        Applications", PLDI'16, sections 1/3.  (Their headline: "no erroneous
 *        behaviour is observed when conducting 1000 executions ... on a Tesla
 *        K20" -> "errors ... appear in 102 out of 1000 executions" once stressed,
 *        p.101.  Nvidia silicon -- see the VENDOR SPLIT below.)
 *   the named, enumerable stress-parameter space + autotuning + the
 *   reproducibility bound
 *     -- Kirkham, Sorensen, Tureci, Martonosi, "Foundations of Empirical Memory
 *        Consistency Testing", OOPSLA'20, section 3.1.
 *   the four "incantations" (memory stress, thread synchronisation, thread
 *   randomisation, occupancy) and the busy-wait DEADLOCK GUARD
 *     -- Alglave et al., "GPU Concurrency: Weak Behaviours and Programming
 *        Assumptions", ASPLOS'15, section 4.3.
 *
 * VENDOR SPLIT -- why this layer exists, stated honestly, because this header is
 * included by the .hip (AMD MI300A) render as well as the .cu (Nvidia GH200) one:
 *
 *   * NVIDIA (GTX Titan, and by lineage our GH200 target): the stress layer is
 *     the difference between observing something and observing nothing.
 *     "we did not observe sb and lb on Titan without this incantation"
 *     (Alglave 4.3.1, p.585).  Table 6 (p.584): sb and lb are 0 in EVERY column
 *     without memory stress (cols 1-8), and become non-zero only once it is
 *     enabled (cols 9-16).  Without stress the campaign is vacuous.
 *
 *   * AMD (Radeon HD 7970, the MI300A render's ancestor): NOT so, and the
 *     unqualified claim would be false.  "For AMD HD7970 we did not need memory
 *     stress to observe weak behaviour, although we observe mp consistently more
 *     when this incantation is enabled" (Alglave 4.3.1, p.585).  Table 6:
 *     lb is 10959/100k in column 1 -- no incantations at all -- while sb stays
 *     ~0 in every column.
 *
 *   * The paper's own summary (4.3, p.585): "The setup of Sec. 4.2 only witnessed
 *     weak behaviours in combination with incantations ON NVIDIA CHIPS; these
 *     incantations also influenced the incidence of weak behaviours on AMD chips."
 *
 *   So: on Nvidia this layer is load-bearing for observing anything; on AMD it is
 *   a rate and coverage amplifier, not an on/off switch.  Do not repeat the
 *   unqualified "zero without stress" line -- it is a Nvidia result.
 *
 *   the co-prime permutation / Parallel Test Environment (permute_id,
 *   stripe_workgroup)
 *     -- Levine et al., "MC Mutants", ASPLOS'23, section 4.1 ("(vP) mod N ...
 *        P co-prime to N").
 *   the seeded Park-Miller RNG (so a run is replayable from its seed)
 *     -- Levine et al., "GPUHarbor", ISSTA'23, section 3.4.
 *
 * -------------------------------------------------------------------------
 * TWO OBJECT CLASSES, TWO ALLOCATORS.  Do not confuse them:
 *
 *   * the shared litmus VARIABLES and the cross-device rendezvous BARRIER are
 *     the property under test.  They go through gd_alloc_shared (system malloc
 *     + ATS on GH200; fine-grained hipMallocManaged on MI300A) so both sides
 *     touch the same cache line in place over the real interconnect.
 *
 *   * the stress SCRATCHPAD below is GPU-only and DISJOINT from every test
 *     location.  It goes in plain DEVICE memory (cudaMalloc / hipMalloc): the
 *     CPU never touches it and it can never alias a test location.  That
 *     disjointness is exactly what makes the stress sound -- it raises the
 *     coherence traffic without changing the tested program's behaviour set
 *     (S&D: "a completely disjoint region of memory ... called a scratchpad").
 *
 * WHAT THIS LAYER DOES *NOT* DO.  The scratchpad hammers the GPU's ON-DIE
 * L1/L2 coherence.  It does not, by itself, widen the CPU-GPU (NVLink-C2C)
 * window -- that needs interconnect-crossing traffic (CPU-side stress + remote
 * page placement), which is a separate build.  Do not claim otherwise.
 *
 * -------------------------------------------------------------------------
 * DIVERGENCES FROM UPSTREAM.  Three, all deliberate.  We cite Levine, so a
 * reviewer must be able to tell which lines are theirs and which are not.
 *
 * (1) UPSTREAM BUG, FIXED: the MEM_STRESS pattern-argument slot.
 *
 *   do_stress(scratchpad, locations, iterations, PATTERN)     [functions.cu:19]
 *
 * but cuda-litmus's MEM_STRESS() [litmus.cuh:346] passes `pre_stress_iterations'
 * in the PATTERN slot, where PRE_STRESS() [litmus.cuh:338] correctly passes
 * `pre_stress_pattern'.  do_stress's body is if(p==0)...else if(p==3) with NO
 * else, and the committed tuned config sets preStressIterations=57.  57 matches
 * no branch, so mem-stress spins memStressIterations=445 times doing NOTHING,
 * and memStressPattern is never read.
 *
 * The sting: the tuned preStressPattern=3 is `ld;ld' (pure loads), and pattern 0
 * (`st;st') is the only scratchpad WRITER -- the dead one.  So in the shipped
 * configuration NOTHING ever writes the scratchpad: the whole stress layer is
 * READ-ONLY, reading a region that is never written.  Store traffic -- which
 * invalidates lines and forces ownership transfer, the strong coherence
 * stressor -- never happens.
 *
 * This does NOT invalidate cuda-litmus's published results (their pre-stress did
 * real work).  It means the knobs LABELLED "mem-stress" were not doing what
 * their names say.  HetLitmus passes the pattern correctly, so scratchpad store
 * traffic appears here for the first time.  CONSEQUENCE: cuda-litmus's committed
 * params/stress_params.txt is NOT a valid tuning seed for us, and re-tuning on
 * the target hardware is MANDATORY, not optional.
 *
 * (2) UPSTREAM BUG, DIVERGED: setScratchLocations' region dedup is DEAD CODE.
 *     Upstream declares `std::set<int> usedRegions' [runner.cu:131] and queries
 *     it -- `while (usedRegions.count(region)) region = rand() % numRegions;'
 *     [runner.cu:135] -- but NEVER INSERTS INTO IT (`grep -n "\.insert"
 *     runner.cu' finds nothing).  count() is therefore always 0: the loop never
 *     spins, upstream never dedups, and the SAME region can be drawn for several
 *     of its stressTargetLines.  Its realised spread is <= m, not m.
 *     het_set_scratch_locations below implements the dedup upstream INTENDED
 *     (a linear scan; no std::set dependency), so HetLitmus really does hammer m
 *     DISTINCT stress lines -- closer to S&D's "spread" than upstream is.  This
 *     is a behavioural divergence, not a faithful port: their tuned m and ours
 *     do not mean the same thing, which is a second reason re-tuning is
 *     mandatory.
 *
 * (3) OUR OWN BUG, FIXED (B4-fix): the ACCESS PATTERN MUST BE A RUNTIME VALUE.
 *     The first port passed the pattern as a compile-time -D constant.  nvcc then
 *     constant-folds do_stress's if(p==0)...else if(p==3) chain down to the one
 *     live branch -- and the tuned default, pattern 3, is `ld;ld' whose loaded
 *     values only feed a `break'.  That is provably side-effect-free, so nvcc
 *     DELETED THE WHOLE LOOP: measured on the emitted PTX (sm_90), the test lane
 *     carried 0 scratchpad ops, and -DHET_MEM_STRESS_PATTERN=3 emptied the entire
 *     kernel (0 ops).  The stress layer compiled, satisfied every gate, and did
 *     nothing.  Upstream is immune by accident of design: its pattern arrives
 *     through kernel_params (a runtime pointer), so the storing branches always
 *     survive.
 *     FIX: the patterns are passed to the kernel as ARGUMENTS (_pre_pat/_mem_pat
 *     in top_litmus.ml), sourced from the -D knobs HOST-side.  The knobs keep
 *     working; the device code cannot fold them.  DO NOT "simplify" them back
 *     into #defines here -- hetlitmus/verify/stresscheck.py fails the build if
 *     anyone does (it asserts the PTX scratchpad-op count is INVARIANT under
 *     -DHET_*_PATTERN, which is exactly the property a compile-time pattern
 *     destroys).
 * ========================================================================= */
#ifndef HET_STRESS_CUH
#define HET_STRESS_CUH

#include <stdint.h>
#include <stdio.h>      /* het_report_spread: a degraded stress layer must SAY so */

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* -------------------------------------------------------------------------
 * Stress knobs.  THESE VALUES ARE A SEED, NOT A TUNED CONFIGURATION.
 *
 * They are cuda-litmus's committed params/stress_params.txt, which is (a) a
 * DEVICE-scope, GPU-only, Hopper-class autotuner output, and (b) was tuned with
 * the MEM_STRESS pattern bug live -- so its mem-stress knobs were inert and its
 * scratchpad was never written.  HetLitmus tests SYSTEM scope across a CPU-GPU
 * interconnect.  Kirkham OOPSLA'20 section 6.4: "parameters for one chip may not
 * be optimal on another chip, even from the same vendor."
 *
 * Every value below is therefore a STARTING POINT that must be re-tuned on the
 * target hardware.  All are -D-overridable so an autotuner can sweep them
 * without re-emitting the harness.
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
#ifndef HET_MEM_STRESS_PATTERN
#define HET_MEM_STRESS_PATTERN 0       /* 0 = st;st -- the ONLY writer pattern,
                                          and the one cuda-litmus's bug made
                                          unreachable.  See the header comment. */
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

/* het_do_stress's if-chain has NO else, so a pattern outside 0..3 makes the
   stress loop spin doing NOTHING -- silently.  That is exactly how upstream's
   MEM_STRESS bug hid (it passed 57).  A silent no-op stress layer is a silent
   falsification of every non-observation, so refuse to compile instead.
   (B8 note: if you ever source a pattern from a config file at RUN time rather
   than from these -D knobs, re-validate it there -- this guard cannot see it.) */
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
#define HET_SEED 1                     /* fixed => a run is replayable (GPUHarbor).
                                          The HET_SEED *env var* overrides it at
                                          run time (B7b): the campaign scheduler
                                          must vary the seed base per invocation,
                                          and a rebuild per invocation is not a
                                          knob.  Unset env => this value.        */
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
 * LIVENESS TALLY (B4-fix).  Three device counters the host reads back and
 * prints, because every mechanism in this file is INVISIBLE to the L0
 * faithfulness gate by design (stress is scaffolding, not a tested op) -- and a
 * scaffolding layer that silently stops scaffolding produces a clean-looking
 * "Never" that is worth nothing.  Two of the three exist because that is
 * precisely what happened here (see divergence (3) above).
 *
 *   RDV   / CAP : how each het_spin ended.  The window-opener is meant to
 *                 RENDEZVOUS the GPU test lanes; the 1024-spin deadlock cap is
 *                 only a safety net (Alglave 4.3.4).  A spin that mostly exits
 *                 on the CAP is not a window-opener, it is a fixed-length delay
 *                 loop -- and only a runtime counter can tell the two apart.
 *                 This ratio is also the datum the tuning task (B8) tunes
 *                 HET_BARRIER_PCT against.
 *   TRUNC       : stress lanes that hit HET_STRESS_MAX_ROUNDS, i.e. STOPPED
 *                 STRESSING while tested lanes were still running.  Its result
 *                 is not comparable with a fully stressed one, so it must never
 *                 be silent.
 *   NOISE /     : B5, the Hopper half of the Fusco C2C noise pair.  NOISE counts
 *   NOISE_ROUNDS  the noise BLOCKS that completed at least one streaming round
 *                 (bounded by the grid, so it cannot overflow); NOISE_ROUNDS is
 *                 the MAX rounds any one block completed (atomicMax, likewise
 *                 overflow-safe -- a summed uint32 round count would wrap on a
 *                 long run and a wrapped-to-zero tally reads exactly like a dead
 *                 mechanism, which is the failure this whole tally exists to
 *                 prevent).  Zero NOISE with the noise enabled = the interconnect
 *                 stressor is not running, and the run is not C2C-stressed.
 *   STRESS_ROUNDS: B6b.  The gap B6a stated plainly and left open: het_do_stress
 *                 -- the scratchpad loop that IS the GPU stress -- had NO runtime
 *                 tally at all, so het_obs_record could not say whether it had
 *                 EXECUTED, only (via stresscheck.py, structurally) that it had
 *                 survived into the PTX.  het_verdict() therefore refused to
 *                 disqualify on HET_REQ_GPU_STRESS, because "a check that cannot
 *                 fail is worse than no check".  This closes it: the MAX rounds any
 *                 single het_do_stress call completed (atomicMax => overflow-safe,
 *                 like NOISE_ROUNDS; a summed count would wrap on a long run and a
 *                 wrapped-to-zero tally reads exactly like a dead mechanism).
 *
 *                 WHAT IT DOES AND DOES NOT PROVE, because the distinction is the
 *                 entire lesson of B4.  It proves the loop RAN.  It does NOT prove
 *                 the loop still CONTAINS its scratchpad accesses -- that is
 *                 stresscheck.py's job (the accesses must be in the emitted PTX and
 *                 INVARIANT under the -D pattern knobs, which is what makes them
 *                 undeletable).  B4 shipped a stress layer that was in the source,
 *                 dead-code-eliminated out of the PTX, and green on every gate;
 *                 neither check alone would have caught it, and neither is redundant.
 *
 *                 It has a NEW job in B6b too: a co-run harness reserves 3x-5x the
 *                 test blocks, so the stress population is the first thing the
 *                 co-residency cap squeezes to zero -- a run with the stress code
 *                 present, requested, and executed by nobody.
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
 * ADAPTATION (Q5 3.4): cuda-litmus re-rolls its probabilistic toggles ON THE
 * HOST and cudaMemcpy's a fresh KernelParams before every relaunch.  The
 * HetLitmus kernel is PERPETUAL -- launched once, looping inside -- so there is
 * no per-iteration host round-trip and the toggles must be decided device-side.
 * Seeding per (lane, run) from a fixed seed keeps a run replayable, which is
 * exactly why GPUHarbor uses this generator.
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
 * Scaffolding counters.
 *
 * DELIBERATELY compiler BUILTINS (atomicAdd), not libcu++/HIP scoped atomics:
 * these are bookkeeping on a device-only scratch word, NOT memory-model ops of
 * the test.  A builtin atomicAdd lowers to a bare `atom.global.add.u32' that
 * carries no memory-order qualifier and sits OUTSIDE the PTX inline-asm markers,
 * so it stays out of the op stream that the L0 faithfulness gate
 * (hetlitmus/verify/ptxcheck.py) checks -- which is correct, because it is not a
 * tested op.  Reading through an RMW (add 0) rather than a plain load keeps the
 * value device-coherent (it resolves in L2) with no L1-caching question.
 * ------------------------------------------------------------------------- */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  return atomicAdd(p, 0u);
}
__device__ static inline void het_scratch_bump(uint32_t* p) {
  (void)atomicAdd(p, 1u);
}
/* B5: a saturating-by-construction volume counter.  atomicMax, not atomicAdd:
   a SUMMED uint32 round count wraps on a long streaming run, and a tally that
   wrapped to zero is indistinguishable from a mechanism that never ran. */
__device__ static inline void het_scratch_max(uint32_t* p, uint32_t v) {
  (void)atomicMax(p, v);
}

/* -------------------------------------------------------------------------
 * do_stress -- cuda-litmus functions.cu:19-50, ported VERBATIM (only the types
 * and the name are ours).  Each stressing thread repeats a 2-instruction access
 * sequence on its workgroup's scratch line:
 *
 *     pattern 0 = st;st     1 = st;ld     2 = ld;st     3 = ld;ld
 *
 * (Kirkham's 2-instruction AccessPattern A0;A1; S&D's fuller sigma = (ld|st)+ up
 * to length 5 is not implemented upstream and is not reproduced here.)
 *
 * Pattern 0 is the only pure WRITER.  Store traffic invalidates lines and forces
 * ownership transfer, which is the strong coherence stressor -- and it is
 * precisely what cuda-litmus's shipped configuration never emitted (header).
 *
 * CALLER CONTRACT (load-bearing -- header divergence (3)): `pattern' MUST reach
 * this function as a RUNTIME value (a kernel argument).  Hand it a compile-time
 * constant and nvcc folds the if-chain to one branch; if that branch is 3
 * (`ld;ld', the tuned default) the body becomes provably side-effect-free and
 * THE ENTIRE LOOP IS DELETED.  The accesses below are deliberately plain and
 * non-volatile -- exactly upstream's -- so that the stress traffic is ordinary
 * cacheable traffic that thrashes the testing thread's own L1 (Kirkham 3.1's
 * whole point) and adds no ordering edge to the test.  Keeping them plain is
 * what makes the runtime pattern load-bearing rather than a style choice.
 * ------------------------------------------------------------------------- */
/* B6b DIVERGENCE (4) from cuda-litmus's do_stress: the [tally] parameter and the
   het_scratch_max at the end.  Upstream's loop body is reproduced VERBATIM (the
   four access patterns, the >100 early-outs, the plain non-volatile accesses); the
   only addition is a round counter, taken OUTSIDE the loop so the tested traffic is
   byte-for-byte upstream's and no atomic lands in the middle of the stress stream.
   It exists because B6a could not disqualify a run whose GPU stress never executed
   -- see HET_TALLY_STRESS_ROUNDS above. */
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
 * het_spin -- the DEVICE-SCOPE window-opener.  cuda-litmus functions.cu:10-17
 * (`spin'), Alglave ASPLOS'15 section 4.3.4 (the thread-synchronisation
 * incantation: "synchronise ... by atomically incrementing a counter and
 * busy-waiting ... take care to avoid deadlock"), Kirkham's Barrier+timeout.
 *
 * It aligns the GPU TEST LANES of an instance so their critical accesses race.
 * It is NOT the cross-device rendezvous: that is the system-scope gd_bar in the
 * driver, which fires ONCE, outside the perpetual loop.  A per-iteration
 * CROSS-DEVICE barrier would mask the tested order and stall (Srivastava
 * section 4.1), so the two must stay separate -- different scope, different
 * variable, different lifetime.  This one is device-scope, on a scratch word
 * that is not a test location, so it adds no ordering edge to the test.
 *
 * DEADLOCK GUARD (Alglave, verbatim from upstream): the wait is capped at 1024
 * spins.  GPUs give no forward-progress guarantee across workgroups, so a lane
 * that waits unboundedly for a lane that is not scheduled hangs the kernel --
 * and a silent hang is indistinguishable from a genuine non-observation.
 *
 * ADAPTATION (perpetual loop): upstream relaunches the kernel per test
 * iteration, so its barrier counter is fresh each time and it waits for
 * `blockDim.x * testing_workgroups' -- Alglave 4.3.4: "busy-waiting until the
 * counter reaches THE NUMBER OF THREADS PARTICIPATING IN THE TEST".  Our kernel
 * loops INSIDE, so a counter that only ever grows would be satisfied from
 * iteration 1 onward and the barrier would silently stop barriering.  The caller
 * therefore passes a limit indexed by the number of barriers TAKEN SO FAR
 * (_nb * lanes), and takes them ALL-OR-NONE: the caller's roll is drawn from a
 * LANE-INDEPENDENT stream (seeded by the iteration, not by the lane), so every
 * lane takes the same barriers, contributes exactly one increment to each, and
 * the counter reaches _nb*lanes EXACTLY when the last lane arrives.  Monotonic
 * counter, exactly-attainable target.
 *
 * B4-fix -- WHY THAT SENTENCE IS THE WHOLE MECHANISM.  The first version rolled
 * the toggle from the LANE'S OWN stream and indexed the limit by the ITERATION
 * ((_n+1)*lanes).  A lane then incremented on only ~68% of iterations while the
 * limit rose by `lanes' every iteration, so the counter fell permanently behind:
 * after the first skipped roll the limit was UNREACHABLE FOREVER, every spin ran
 * out the full 1024-iteration deadlock cap, and the "window-opener" was a
 * fixed-length delay loop that aligned nothing (simulated over the emitted
 * protocol: 99% of spins cap-released, final counter deficit 625; with the fix,
 * 100% rendezvous-released, deficit 0).  Upstream never hit this because its
 * toggle is ONE host-set boolean, uniform across the launch [litmus.cuh:340] --
 * all testing threads spin, or none do.  The uniformity is the invariant; the
 * per-lane draw broke it.  KEEP THE DRAW LANE-INDEPENDENT.
 *
 * DEADLOCK GUARD + LIVENESS TALLY: the wait is capped at 1024 spins (Alglave,
 * verbatim from upstream) -- GPUs give no forward-progress guarantee across
 * workgroups, and a silent hang is indistinguishable from a genuine
 * non-observation.  But a cap that fires is a barrier that did NOT rendezvous,
 * so each exit is tallied by its reason and the host prints the ratio: that is
 * the only way this mechanism can be seen to be alive (the L0 gate cannot see
 * it, and did not).
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
  /* Released by the rendezvous, or by the deadlock cap?  (val >= limit) is the
     loop's success exit; anything else means i hit 1024 with the counter still
     short.  A builtin atomicAdd on a device-only word: scaffolding, invisible to
     the model-op stream, which is why ptxcheck's stray-sys check exists. */
  het_scratch_bump(&tally[(val >= limit) ? HET_TALLY_RDV : HET_TALLY_CAP]);
}

/* -------------------------------------------------------------------------
 * The co-prime Parallel-Test-Environment primitives -- MC Mutants ASPLOS'23
 * section 4.1, cuda-litmus functions.cu:2-8.  (v*P) mod N with P co-prime to N
 * is a bijection, so it assigns each thread a partner / a location slot without
 * collisions while avoiding the ineffective n -> n+1 pattern.
 *
 * PORTED BUT NOT YET WIRED.  They belong to the GPU-only REPLICA population
 * (many independent instances of a gpu-only test per launch).  HetLitmus's
 * cross-device instance count is capped by CPU cores, not GPU threads, so the
 * het pair does not use them; they are here for the gpu-only companion
 * population, and left unreferenced deliberately.
 * ------------------------------------------------------------------------- */
[[maybe_unused]] __device__ static uint32_t het_permute_id(uint32_t id, uint32_t factor, uint32_t mask) {
  return (id * factor) % mask;
}
[[maybe_unused]] __device__ static uint32_t het_stripe_workgroup(uint32_t workgroup_id, uint32_t testing_workgroups) {
  return (workgroup_id + 1) % testing_workgroups;
}

/* -------------------------------------------------------------------------
 * het_set_scratch_locations -- cuda-litmus runner.cu:132-157
 * (`setScratchLocations'), HOST side.  Picks HET_STRESS_TARGETS distinct stress
 * lines at random out of (HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE) regions, one
 * random word within each, then maps workgroups onto those lines:
 *
 *   strategy 0 (round-robin): consecutive workgroups -> separate lines
 *   strategy 1 (chunking):    a run of consecutive workgroups -> the same line
 *
 * Distinct lines keep each stresser on a fresh cache line (S&D's critical patch);
 * the spread controls how many lines are contended at once.
 *
 * DIVERGENCE (header (2)) -- WE DEDUP, UPSTREAM ONLY LOOKS LIKE IT DOES.  Upstream
 * declares `std::set<int> usedRegions' [runner.cu:131] and guards its draw with
 * `while (usedRegions.count(region)) region = rand() % numRegions;' [runner.cu:135]
 * -- but it never inserts into the set (`grep -n "\.insert" runner.cu' finds
 * nothing), so count() is always 0, the guard never spins, and two of its
 * stressTargetLines can land on the SAME region.  Upstream's realised spread is
 * therefore <= m, not m.
 *
 * The linear scan below is the dedup upstream INTENDED, and it is real: the m
 * lines are distinct, which is what S&D's "spread" means.  Consequences to keep
 * in mind: (a) upstream's tuned m is not our m -- another reason re-tuning is
 * mandatory; (b) OUR loop would spin forever if it ever ran out of regions
 * (m > num_regions), which upstream's dead code could not -- hence the explicit
 * break below.  Driven by rand(), which the driver seeds per run, so the layout
 * is replayable.
 * ------------------------------------------------------------------------- */
#if HET_STRESS_TARGETS < 1
#error "HET_STRESS_TARGETS must be >= 1 (it is S&D's spread m)"
#endif
/* The REALISED spread can be smaller than the knob, silently.  Chunking divides
   num_workgroups by HET_STRESS_TARGETS, so a grid SMALLER than the target count
   gives workgroupsPerLocation = 0 and the tail case then dumps EVERY workgroup on
   the LAST line -- realised spread 1, while the knob still says m (verified on
   device: 6 workgroups, m=9 -> all 6 on one line; 64 workgroups, m=9 -> 9 distinct
   lines, as intended).  Round-robin degrades more gently but still leaves targets
   unused.  Either way the stress is weaker than the configuration claims, and B8
   sweeps exactly these knobs (HET_STRESS_BLOCKS x HET_STRESS_TARGETS), so it must
   never score a spread-1 config as if it were spread-m.  Count what was actually
   assigned and say so. */
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
  /* Every entry must be a VALID index: a stress lane indexes the scratchpad by
     scratchpad[locations[blockIdx.x]], so an unwritten entry would be an
     out-of-bounds device write.  Zero first, then fill (both strategies below do
     cover [0,num_workgroups), but this makes that a property of the code rather
     than of an argument about it). */
  for (int j = 0; j < num_workgroups; j++) { locations[j] = 0u; }
  for (int i = 0; i < HET_STRESS_TARGETS; i++) {
    int region, dup;
    /* Our dedup is REAL (upstream's is dead code, see above), so it can exhaust
       the region pool and spin forever.  Stop instead -- the targets we already
       have are still a valid, smaller spread. */
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
