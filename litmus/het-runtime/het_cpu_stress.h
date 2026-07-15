/* =========================================================================
 * het_cpu_stress.h -- HetLitmus CPU-side + interconnect (C2C) stress.
 * Emitted verbatim by litmus7 from litmus/het-runtime/het_cpu_stress.h (edit
 * the source, never a harness-dir copy); #include'd by <test>_cpu.c (with
 * HET_CPU_STRESS_IMPL, which compiles the bodies) and by <test>.cu / .hip (which
 * get only the knobs, the argument structs and the declarations).
 * =========================================================================
 * WHAT THIS LAYER IS FOR, AND WHY B4 WAS NOT ENOUGH
 *
 * het_stress.cuh hammers the GPU's own L1/L2 with a device-only scratchpad.  That
 * widens the INTRA-device window.  The heterogeneous weak behaviour does not live
 * there: it lives in the CROSS-device window -- the interval in which a store is
 * in flight across the CPU-GPU interconnect but not yet globally visible.  Per-
 * device stress on either side never loads that path.  This file adds the two
 * levers that do:
 *
 *   HALF 1 -- CPU-side stress.  The litmus7 "incantation" vocabulary, ported as
 *             RECIPES (never via Skel.ml): preload (M3), disjoint-scratchpad enemy
 *             threads (M1 in S&D's form), indirect access (M2), stride/spread (M4),
 *             affinity (M6).
 *   HALF 2 -- INTERCONNECT stress.  (a) placement: pin the shared pages remote to
 *             their consumer so the tested accesses cross C2C (this half lives in
 *             the .cu, next to gd_alloc_shared -- it is CUDA API, not host asm).
 *             (b) noise: each processing unit continuously stream-reads the OTHER
 *             one's memory, over a working set far larger than any cache.
 *
 * Half 2 is the thesis's methodological addition beyond Bagchi et al. (ISMM'26),
 * who stressed each device independently -- "Each was executed millions of times
 * with memory stressing [21] on both devices" (4.2) -- with NO link-directed
 * component anywhere in the paper (no placement, no cudaMemAdvise, no C2C noise).
 * Their interconnect is loaded only implicitly, by the test's own coherence race.
 *
 * -------------------------------------------------------------------------
 * HONESTY ABOUT WHAT HALF 2 BUYS.  This is an INFERENCE, not a measurement, and
 * it must be written that way in the thesis too.
 *
 *   * Fusco et al. measured BANDWIDTH degradation under noise (below).  Nobody
 *     has ever measured whether C2C saturation raises heterogeneous litmus YIELD.
 *   * It is also CONFOUNDED: remote placement and noise slow the whole loop, so
 *     there are fewer CPU/GPU rendezvous per second.  Sightings = yield x rate,
 *     and the net sign of that product is genuinely unknown.
 *
 * The defensible claim is therefore: interconnect stress is ADDITIVE AND
 * COMPOSABLE with per-device stress, and it is the lever most SPECIFIC to the
 * cross-device window.  It is NOT "more effective than per-device stress".  Do
 * not upgrade that sentence without hardware evidence.
 *
 * -------------------------------------------------------------------------
 * SOURCES.  Cited because we reuse them, and (for cuda-litmus, which carries no
 * licence file) because citation is the condition of reuse.
 *
 *   Alglave, Maranget, Sarkar, Sewell.  "Litmus: Running Tests against Hardware."
 *   TACAS'11, section 3 -- the CPU incantation vocabulary this half ports:
 *     NEXE     "To benefit from parallelism and stress the memory subsystem, given
 *               a test consisting of t threads P0,...,Pt-1, we run n = max(1, a/t)
 *               identical test instances concurrently on a machine with a cores."
 *     indirect "In direct mode the array cell is accessed directly as x[i]; hence
 *               cells are accessed sequentially and false sharing effects are
 *               likely.  In indirect mode (the default) the array cell is accessed
 *               by a shuffled array of pointers, giving a much greater variability
 *               of outcomes."
 *     preload  "If the (default) preload mode is enabled, a preliminary loop of
 *               size s reads a random subset of the memory locations accessed by
 *               Pk, also leading to a greater outcome variability."
 *   Its cache primitives are litmus7's own (litmus/libdir/_aarch64/_cache.h and
 *   _x86_64/_cache.h, CeCILL-B, reused verbatim below).
 *
 *   Sorensen & Donaldson.  "Exposing Errors Related to Weak Memory in GPU
 *   Applications."  PLDI'16 -- the disjoint-scratchpad invariant that makes ALL of
 *   this sound, and the named knobs (patch P, sequence sigma, spread m, distance):
 *     "The key part of our testing environment is a memory stressing strategy that
 *      targets a completely disjoint region of memory from the application data
 *      (called a scratchpad) using extra GPU threads disjoint from the threads that
 *      execute the application... Because the stressing threads and memory are
 *      disjoint from application threads and data, the set of possible behaviours a
 *      program can exhibit remains the same."
 *
 *   Alglave et al.  "GPU Concurrency: Weak Behaviours and Programming Assumptions."
 *   ASPLOS'15, section 4.3.1 -- the window-widening rationale this whole layer
 *   rests on, verbatim:
 *     "Stressing caching protocols might trigger weak behaviours.  For example, a
 *      bus may be more likely to transfer data out of order when it is under heavy
 *      stress than when it is only servicing a few requests."
 *   VENDOR SPLIT (see het_stress.cuh at length): "we did not observe sb and lb on
 *   Titan without this incantation", but "For AMD HD7970 we did not need memory
 *   stress to observe weak behaviour, although we observe mp consistently more when
 *   this incantation is enabled."  On Nvidia the stress layer is the difference
 *   between observing something and observing nothing; on AMD it amplifies a rate.
 *
 *   Fusco, Khalilov, Chrapek, Chukkapalli, Schulthess, Hoefler.  "Understanding
 *   Data Movement in Tightly Coupled Heterogeneous Systems: A Case Study with the
 *   Grace Hopper Superchip."  arXiv:2408.11556 -- the noise-kernel construction,
 *   verbatim:
 *     "we develop a Grace and a Hopper noise kernel that continuously reads from a
 *      large buffer of 8 GB.  To stress the C2C interconnect, the Grace noise kernel
 *      reads HBM system allocated memory and the Hopper noise kernel reads DDR
 *      allocated memory.  We start the noise kernel for one PU and run the read and
 *      write tests for the other PU."
 *   Effect: "Writes to HBM are the most impacted, with a Grace bandwidth of 17% and
 *   a Hopper bandwidth of 65% of the theoretical maximum."
 *   And the caveat that makes the WORKING SET load-bearing rather than decorative:
 *     "Hopper L2 cache can cache data that is physically allocated on HBM, both
 *      local and peer.  L2 resident peer HBM accesses are faster than local DDR
 *      accesses."
 *   -- i.e. a remote-pinned line that stays L2-resident crosses NOTHING.  Placement
 *   alone does not guarantee C2C traffic.  That is precisely why the noise exists,
 *   and why its buffer must exceed the last-level cache (see HET_NOISE_MB).
 *
 *   MI300A analogue (the AMD render): there is NO placement lever -- one HBM pool,
 *   no LPDDR/HBM split, no cudaMemAdvise equivalent.  The analogue is cross-chiplet
 *   coherence CONTENTION: co-hammer a shared fine-grained-coherent region whose
 *   working set defeats L2/Infinity-Cache residency.  Grounded in arXiv:2508.12743
 *   (co-running CPU+GPU atomics drops CPU throughput to 11-25%) and Schieffer et
 *   al., arXiv:2410.00801 ("each access to data located in remote coherent memory
 *   generates traffic over the CPU-GPU interconnect... on more recent systems, such
 *   as AMD MI300A, the no-caching restriction can be lifted").  Since caching is
 *   allowed on MI300A, per-access fabric traffic is NOT automatic and contention is
 *   what keeps the lines bouncing -- which is exactly what the noise pair below
 *   does when both sides stream the same coherent pool.  So the SAME noise code is
 *   the GH200 lever (by placement) and the MI300A lever (by contention); only the
 *   placement half is Nvidia-only.
 *
 * -------------------------------------------------------------------------
 * DIVERGENCES / DELIBERATE CHOICES.  Stated because a reviewer must be able to
 * tell what is ported from what is ours.
 *
 * (1) THE ACCESS SEQUENCE IS A RUNTIME VALUE, NOT A -D CONSTANT.  This is B4's
 *     scar tissue.  The GPU port first passed the access pattern as a compile-time
 *     -D; nvcc folded do_stress's if-chain to the one live branch, that branch
 *     (ld;ld) was provably side-effect-free, and THE ENTIRE STRESS LOOP WAS
 *     DELETED -- while every gate stayed green.  The CPU enemy has the identical
 *     shape (a sigma selector over an if/switch chain), so it gets the identical
 *     defence: `seq' arrives in het_cpu_enemy_args as a RUNTIME field, sourced
 *     from the -D knob host-side in main().  It is ALSO belt-and-braces here,
 *     because the enemy's accesses are `volatile' and so cannot be elided at all
 *     -- but the invariant that a knob cannot silently switch a stressor off is
 *     worth more than the one it costs, and hetlitmus/verify/cpustresscheck.py
 *     gates on it (the compiled op count must be INVARIANT under
 *     -DHET_CPU_ENEMY_SEQ).  Do not "simplify" it back into a #define.
 *
 * (2) M1 IS PORTED AS S&D-STYLE ENEMY THREADS, NOT AS litmus7's NEXE.  NEXE runs
 *     n = max(1, a/t) copies of the WHOLE TEST concurrently.  That does not
 *     compose with a persistent GPU kernel (the het instance count is capped by
 *     CPU cores, not by test replicas), so what is ported is the IDEA -- concurrent
 *     memory-subsystem contention -- in the disjoint-scratchpad form, which is
 *     automatically -2s-safe.  Q6 2.1 M1.
 *
 * (3) M5 (launch randomisation), M7 (per-cell barrier) and M8 (timebase release)
 *     are NOT ported.  M7 as a CPU<->GPU per-trial barrier is anti-correct: it
 *     masks the tested order and stalls (Srivastava 4.1).  M8 needs one shared
 *     counter, and Grace's cntvct_el0 and Hopper's %globaltimer have different
 *     epochs -- there is no shared clock to release on.  Q6 2.3.
 *
 * (4) EVERY numeric below is a SEED, not a tuning.  Alglave TACAS'11 4: stress is
 *     per-testbed.  Kirkham OOPSLA'20 6.4: "parameters for one chip may not be
 *     optimal on another chip, even from the same vendor."  Re-tune on GH200 and
 *     again on MI300A -- they do not even share the interconnect lever.  All knobs
 *     are -D-overridable so B8 can sweep them without re-emitting the harness, and
 *     main() prints the REALISED value of each (a knob that says 9 while the
 *     hardware realised 1 silently mis-tunes the autotuner -- het_report_spread in
 *     het_stress.cuh learned that the hard way).
 * ========================================================================= */
#ifndef HET_CPU_STRESS_H
#define HET_CPU_STRESS_H

/* NO <pthread.h> -- it does not survive `clang --target=aarch64-linux-gnu -c'
   (x86 glibc's __cleanup_fct_attribute is __attribute__((__regparm__(1))), which
   is invalid on AArch64), and that cross-assembly is a gated build step.  The
   thread bodies below need only the void*(void*) signature; pthread_create is
   called from the .cu, which is built for the native host.  These four DO cross-
   compile cleanly (verified). */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * HALF 1 KNOBS -- CPU-side stress.  Seeds, not a tuning (divergence (4)).
 * ------------------------------------------------------------------------- */
#ifndef HET_CPU_ENEMIES
#define HET_CPU_ENEMIES (-1)      /* -1 = auto: every spare core (see main())    */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the enemy scratchpad.
                                          A THIRD object class -- plain host
                                          malloc.  It is CPU-only and disjoint
                                          from every test location, so it needs
                                          neither GPU coherence (gd_alloc_shared)
                                          nor device memory (gd_dev_malloc).  Do
                                          not conflate the three.               */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* S&D "spread" m: distinct lines hammered     */
#endif
#ifndef HET_CPU_STRIDE
#define HET_CPU_STRIDE 8          /* M4 STRIDE: word gap between regions.  8 x 8B
                                     = 64B = one cache line, so consecutive
                                     regions land on distinct lines.             */
#endif
#ifndef HET_CPU_ENEMY_SEQ
#define HET_CPU_ENEMY_SEQ 0       /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld.
                                     0 is the only pure WRITER: store traffic
                                     invalidates lines and forces ownership
                                     transfer, which is the strong coherence
                                     stressor.  Reaches the enemy as a RUNTIME
                                     field -- divergence (1).                    */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* M3: % of iterations a TEST thread preloads
                                     its own test variables (litmus7's default
                                     preload mode is RandomPL).                  */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* M6: pin threads to cores (sched_setaffinity)*/
#endif
#ifndef HET_CPU_TEST_CORE0
#define HET_CPU_TEST_CORE0 0      /* first core the CPU test threads are pinned to*/
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS, the driver and
                                     the GPU-launch thread.  Grace has 72 cores and
                                     NO SMT (1 hw thread/core), so litmus7's SMT /
                                     hyperthread knobs are INERT there and affinity
                                     reduces to which core + L2/L3 locality; on the
                                     x86 MI300A host (24c/48t/3 CCD) they are live.
                                     Q6 2.5.                                     */
#endif

/* -------------------------------------------------------------------------
 * HALF 2 KNOBS -- interconnect (C2C).  HET_PLACE is consumed in the .cu (it is
 * CUDA API, not host asm); the noise knobs are consumed on both sides.
 * ------------------------------------------------------------------------- */
#ifndef HET_PLACE
#define HET_PLACE 0               /* shared-var placement:
                                     0 = first-touch (DEFAULT).  This is Bagchi's
                                         baseline -- they used plain malloc() and
                                         let first-touch decide -- and it is the
                                         honest default because Q6 3.3 finds the
                                         net effect of pinning CONFOUNDED (it
                                         widens the window but slows the loop) and
                                         nobody has measured which way it goes.
                                     1 = prefer HBM  (pages home on the GPU)
                                     2 = prefer DDR  (pages home on the CPU)
                                     B8 sweeps this.  Do NOT promote a non-zero
                                     default without hardware evidence.          */
#endif
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* per noise buffer.  Fusco's is 8 GB, and the
                                     size is NOT arbitrary: the buffer must exceed
                                     the last-level cache on the path or the reads
                                     hit cache and cross nothing (Grace L3 = 114 MB,
                                     Hopper L2 = 51 MB, Bagchi Tab. 1).  Checked at
                                     RUN time, loudly -- see HET_LLC_MB.          */
#endif
#ifndef HET_NOISE_CPU
#define HET_NOISE_CPU 1           /* the Grace half: a CPU thread stream-reading a
                                     HBM-homed buffer                             */
#endif
#ifndef HET_NOISE_GPU_BLOCKS
#define HET_NOISE_GPU_BLOCKS 8    /* the Hopper half: blocks of the PERSISTENT grid
                                     stream-reading a DDR-homed buffer.  They are
                                     extra blocks of the existing kernel, never a
                                     second __global__ -- a separate kernel would
                                     drop its ops into the middle of the flat PTX
                                     op stream that the L0 faithfulness gate slices
                                     per lane.                                    */
#endif
#ifndef HET_NOISE_CHUNK
#define HET_NOISE_CHUNK 4096      /* words streamed per round before re-testing the
                                     stop flag.  Bounds how long the noise can
                                     outlive the test.                            */
#endif
#ifndef HET_NOISE_STRIDE
#define HET_NOISE_STRIDE 1        /* words between consecutive noise reads         */
#endif

/* The last-level cache the noise buffer must EXCEED to generate any interconnect
   traffic at all: max(Grace L3 114 MB, Hopper L2 51 MB).  Fusco: for buffers
   larger than Grace L2, Hopper's DDR accesses "are never cached" -- but Hopper's
   L2 DOES cache HBM, "both local and peer", so a small buffer is served entirely
   from cache and the noise crosses nothing.  A sub-LLC noise buffer is a stressor
   that stresses nothing, so the driver WARNS at run time rather than let a green
   compile imply a live mechanism. */
#define HET_LLC_MB 114

#if (HET_CPU_ENEMY_SEQ) < 0 || (HET_CPU_ENEMY_SEQ) > 3
#error "HET_CPU_ENEMY_SEQ must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_PLACE) < 0 || (HET_PLACE) > 2
#error "HET_PLACE must be 0 (first-touch), 1 (prefer HBM) or 2 (prefer DDR)"
#endif
#if (HET_CPU_SPREAD) < 1
#error "HET_CPU_SPREAD must be >= 1 (it is S&D's spread m)"
#endif
#if (HET_CPU_STRIDE) < 1
#error "HET_CPU_STRIDE must be >= 1"
#endif
/* A zero stride or a zero chunk turns the noise stream into a no-op WITHOUT any
   other symptom: with stride 0 the index never advances, so the thread re-reads ONE
   location for ever (served from L1 -- no DRAM traffic, no C2C traffic); with chunk
   0 the inner loop never executes and the outer loop spins on the stop flag doing
   nothing.  Both would report healthy round counts.  This is the same shape as the
   upstream cuda-litmus MEM_STRESS bug -- a knob whose out-of-range value silently
   disables the mechanism it configures -- so, as there, refuse to compile. */
#if (HET_NOISE_STRIDE) < 1
#error "HET_NOISE_STRIDE must be >= 1 (0 re-reads ONE location for ever: no traffic)"
#endif
#if (HET_NOISE_CHUNK) < 1
#error "HET_NOISE_CHUNK must be >= 1 (0 streams nothing)"
#endif
#if (HET_NOISE_MB) < 1
#error "HET_NOISE_MB must be >= 1"
#endif

/* -------------------------------------------------------------------------
 * LIVENESS TALLY.  The CPU twin of het_stress.cuh's.  Same reason, restated
 * because it is the reason this project keeps shipping dead code: NOTHING in
 * this layer is visible to a structural gate.  The enemy threads touch a private
 * scratchpad; the preload emits cache hints; the noise streams a disjoint buffer.
 * None of it enters the tested op stream -- correctly, it is scaffolding -- and so
 * a layer that has silently stopped working looks EXACTLY like one that is
 * working.  These counters are the only thing that can tell the difference at run
 * time, and every one of them is here because the corresponding mechanism has a
 * plausible way to die:
 *
 *   enemy_rounds     0 => the enemies never ran (a stress_go set after they exited,
 *                    or a loop the optimiser proved side-effect-free and deleted).
 *   preload_ops      0 => the preload incantation is inert (a host ISA with no
 *                    cache primitives, or a 0% roll).
 *   noise_cpu_rounds 0 => the Grace half of the C2C noise never ran.
 *   aff_failures    >0 => sched_setaffinity FAILED and nobody would otherwise
 *                    know: every thread then lands on whatever core the scheduler
 *                    picks, the pinning is a fiction, and the stress topology is
 *                    not the one the tuning assumed.  litmus7 errexit()s here; we
 *                    must not die mid-campaign, but we must not be silent either.
 *   place_failures  >0 => cudaMemAdvise was REFUSED and the pages are wherever
 *                    first touch put them -- i.e. HET_PLACE did nothing while
 *                    claiming to place.  (Filled in the .cu, carried here so one
 *                    struct is the whole vital-signs record.)
 * ------------------------------------------------------------------------- */
typedef struct het_cpu_tally {
  uint64_t enemy_rounds;      /* enemy loop iterations, summed over enemies      */
  uint64_t enemy_accesses;    /* scratchpad accesses issued by the enemies       */
  uint64_t preload_ops;       /* M3 cache hints actually issued                  */
  uint64_t noise_cpu_rounds;  /* Grace noise thread: streaming rounds            */
  uint64_t noise_cpu_words;   /* Grace noise thread: words read                  */
  uint64_t noise_sink;        /* the streamed values, forced to ESCAPE (below)   */
  uint32_t enemies_realised;  /* enemy threads that actually entered their loop  */
  uint32_t aff_failures;      /* sched_setaffinity failures -- never silent      */
  uint32_t place_failures;    /* cudaMemAdvise failures (filled by the .cu)      */
  uint32_t preload_inert;     /* 1 => this host has NO cache primitives at all   */
} het_cpu_tally;

/* -------------------------------------------------------------------------
 * Enemy arguments.  EVERY behavioural field is a RUNTIME value (divergence (1)).
 * ------------------------------------------------------------------------- */
typedef struct het_cpu_enemy_args {
  volatile uint64_t *scratch; /* DISJOINT host scratchpad.  NEVER a test var.    */
  const uint32_t *idx;        /* M2: SHUFFLED region indices (indirection)       */
  uint32_t nidx;              /* M4: spread m -- how many regions per round      */
  uint32_t stride;            /* M4: word gap between regions                    */
  uint32_t seq;               /* sigma, 0..3.  RUNTIME -- see divergence (1).    */
  int core;                   /* M6: core to pin to, or -1 for unpinned          */
  int *go;                    /* the stop flag; set BEFORE the enemies are spawned*/
  het_cpu_tally *tally;
} het_cpu_enemy_args;

/* Grace-side noise arguments (Half 2b).  `buf' is the OTHER PU's memory. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* HBM-homed buffer -- every read crosses C2C   */
  uint64_t words;
  uint32_t chunk;             /* words per round before the stop flag is re-tested*/
  uint32_t stride;
  int core;
  int *go;
  het_cpu_tally *tally;
} het_cpu_noise_args;

/* -------------------------------------------------------------------------
 * API.  Bodies are compiled ONLY into <test>_cpu.c (HET_CPU_STRESS_IMPL).
 * ------------------------------------------------------------------------- */
int      het_cpu_affinity(int core, het_cpu_tally *t);  /* 0 = pinned, -1 = failed */
int      het_cpu_ncores(void);
uint32_t het_cpu_rng_init(uint32_t seed, uint32_t lane);
/* M3.  Returns the number of hints issued, so the caller can accumulate LOCALLY
   and flush once -- an atomic bump per hint would put scaffolding contention in
   the middle of the tested loop, which is the one place it must not be. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct);
void    *het_cpu_enemy(void *a);   /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the Grace half of the C2C noise*/
/* -------------------------------------------------------------------------
 * FIRST-TOUCH -- and this one is not a detail, it is the difference between a
 * noise buffer that stresses the interconnect and one that stresses NOTHING.
 *
 * A malloc'd buffer that has never been WRITTEN is not backed by physical memory.
 * Linux maps every untouched anonymous page to a single shared, read-only ZERO
 * PAGE.  So READING such a buffer -- which is exactly what a noise kernel does --
 * touches ONE physical cache line no matter how large the buffer is: every read
 * hits L1, and it generates no memory traffic, no DRAM traffic, and NO INTERCONNECT
 * TRAFFIC AT ALL.  An 8 GB noise buffer would be 4 KB of physical memory.
 *
 * Measured on the dev box, to make sure this is real and not folklore: reading 1 GiB
 * of untouched malloc'd memory grew RSS by 388 KB; first-touching the same buffer
 * grew RSS to 1,050,392 KB -- the actual gigabyte.
 *
 * A noise layer without this compiles, links, runs, reports healthy round counts,
 * and stresses nothing.  That is this project's signature failure, and it would have
 * been its fourth instance.
 *
 * It also decides the page's NUMA HOME on GH200 (first touch places it), which is
 * why the caller advises the preferred location BEFORE calling this, and prefetches
 * afterwards if the pages must end up on the far side.  One write per page suffices.
 * ------------------------------------------------------------------------- */
void     het_cpu_first_touch(void *p, size_t bytes);
/* Host-side, seeded from srand() by the driver, so a run replays from its seed
   (GPUHarbor ISSTA'23 3.4's reproducibility discipline). */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n);

#ifdef HET_CPU_STRESS_IMPL
/* ========================= IMPLEMENTATION =================================
 * Compiled ONLY in the <test>_cpu.c translation unit (gcc for the build host,
 * and clang --target=aarch64-linux-gnu for the real AArch64 asm).  nvcc never
 * sees a line of it.
 * ========================================================================= */
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <unistd.h>

/* ---- M3 cache primitives -------------------------------------------------
 * litmus7's own, reused VERBATIM from litmus/libdir/_aarch64/_cache.h and
 * litmus/libdir/_x86_64/_cache.h (CeCILL-B, as the rest of the tree).
 *
 * On AArch64 `dc civac' cleans+invalidates to the POINT OF COHERENCE -- which on
 * GH200 is the coherence point shared with the GPU over C2C.  So the preload
 * plausibly touches the cross-device path and not merely the CPU's own cache.
 * That is an INFERENCE (Q6 2.1 M3), unmeasured, and hardware-only: it may equally
 * be redundant with the coherence traffic the test's own race already generates.
 * Do not claim it in the thesis without measuring it.
 * ------------------------------------------------------------------------- */
#if defined(__aarch64__)
#define HET_CPU_ISA "aarch64"
#define HET_CPU_PRELOAD_LIVE 1
static inline void het_cache_flush(void *p) {
  asm __volatile__ ("dc civac,%[p]" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch(void *p) {
  asm __volatile__ ("prfm pldl1keep,[%[p]]" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch_store(void *p) {
  asm __volatile__ ("prfm pstl1keep,[%[p]]" :: [p] "r" (p) : "memory");
}
#elif defined(__x86_64__)
#define HET_CPU_ISA "x86_64"
#define HET_CPU_PRELOAD_LIVE 1
static inline void het_cache_flush(void *p) {
  asm __volatile__ ("clflush 0(%[p])" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch(void *p) {
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch_store(void *p) {
  /* litmus7's comment, kept: "Did not find how to announce intention to store
     for x86" -- so this is prefetcht0 as well, not a store-intent hint. */
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
#else
#define HET_CPU_ISA "portable"
#define HET_CPU_PRELOAD_LIVE 0
/* No cache primitives on this host.  The preload incantation is INERT here, and
   het_cpu_preload SAYS SO (once) rather than returning a healthy-looking count of
   hints it never issued.  An incantation that quietly does nothing is how a
   meaningless "Never" gets mistaken for a memory-model result. */
static inline void het_cache_flush(void *p) { (void)p; }
static inline void het_cache_touch(void *p) { (void)p; }
static inline void het_cache_touch_store(void *p) { (void)p; }
#endif

/* ---- seeded Park-Miller (host twin of het_stress.cuh's) ------------------ */
static inline uint32_t het_cpu_rng_next(uint32_t *s) {
  *s = (uint32_t)(((uint64_t)*s * 16807ull) % 2147483647ull);
  return *s;
}
static inline int het_cpu_rng_pct(uint32_t *s, int pct) {
  return (int)(het_cpu_rng_next(s) % 100u) < pct;
}
uint32_t het_cpu_rng_init(uint32_t seed, uint32_t lane) {
  uint32_t s = (seed ^ (lane * 2654435761u)) % 2147483647u;
  if (s == 0u) s = 1u;              /* Park-Miller degenerates at 0 */
  return s;
}

int het_cpu_ncores(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return (n < 1) ? 1 : (int)n;
}

/* ---- M6 affinity ---------------------------------------------------------
 * The reuse path is litmus7's write_one_affinity (libdir/_linux_affinity.c:117):
 * it bottoms out in sched_setaffinity with a one-CPU mask.  We reuse the RECIPE,
 * not the file (Q9: no route through Skel.ml).
 *
 * ONE DELIBERATE DIFFERENCE: litmus7 errexit()s on failure.  We must not kill a
 * campaign mid-run -- but we must not swallow it either.  A silently-failed pin
 * puts every thread wherever the scheduler likes, which changes the stress
 * topology completely while looking identical from the outside.  So: count it,
 * and let main() report it.
 * ------------------------------------------------------------------------- */
int het_cpu_affinity(int core, het_cpu_tally *t) {
  if (core < 0) return 0;                    /* unpinned by request */
  cpu_set_t m;
  CPU_ZERO(&m);
  CPU_SET(core, &m);
  if (sched_setaffinity(0, sizeof(m), &m) != 0) {
    if (t) __atomic_fetch_add(&t->aff_failures, 1u, __ATOMIC_RELAXED);
    return -1;
  }
  return 0;
}

/* ---- M3 preload ----------------------------------------------------------
 * Called from cpu_thread_P<n>, per iteration, BEFORE het_run_P<n> -- never
 * inside it (invariant (ii)).  It targets the TEST VARIABLES on purpose: that is
 * what M3 is.  It is -2s-safe anyway, because a cache hint changes RESIDENCY, not
 * program order, and because it cannot migrate into the tested sequence: the
 * tested body is an opaque call into another translation unit and every primitive
 * above is asm volatile with a "memory" clobber.
 * ------------------------------------------------------------------------- */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct) {
#if HET_CPU_PRELOAD_LIVE == 0
  (void)vars; (void)nvars; (void)rng; (void)pct;
  return 0u;                        /* inert -- the driver reports it, see above */
#else
  uint32_t n = 0u;
  for (int i = 0; i < nvars; i++) {
    if (!het_cpu_rng_pct(rng, pct)) continue;
    /* litmus7's RandomPL: flush / touch / touch-for-store, chosen per variable
       per iteration off the thread's own stream. */
    switch (het_cpu_rng_next(rng) % 3u) {
    case 0:  het_cache_flush(vars[i]);       break;
    case 1:  het_cache_touch(vars[i]);       break;
    default: het_cache_touch_store(vars[i]); break;
    }
    n++;
  }
  return n;
#endif
}

/* ---- M1 (S&D form) + M2 + M4: the disjoint-scratchpad enemy ---------------
 * The litmus7 NEXE recipe -- concurrent memory-subsystem contention -- realised in
 * S&D's disjoint-scratchpad form, which is what composes with a persistent GPU
 * kernel and is -2s-safe by construction (invariant (i)).
 *
 * THE ACCESSES ARE `volatile'.  This is load-bearing, and it is where the CPU
 * enemy DIVERGES from het_stress.cuh's GPU stresser, which is deliberately NON-
 * volatile (upstream's, so that its traffic is ordinary cacheable traffic that
 * thrashes the testing thread's own L1).  Here the loop's only observable effect
 * IS the memory traffic, so a non-volatile version is provably side-effect-free
 * and -O2 deletes it outright -- which is exactly how B4's stress layer died.
 * `volatile' forbids the compiler to elide or reorder the accesses while leaving
 * them ordinary cacheable traffic to the hardware, which is what we want.
 * hetlitmus/verify/cpustresscheck.py reads the COMPILED asm to prove the loop
 * survived, because reading the source proves nothing.
 * ------------------------------------------------------------------------- */
void *het_cpu_enemy(void *_a) {
  het_cpu_enemy_args *a = (het_cpu_enemy_args *)_a;
  het_cpu_affinity(a->core, a->tally);
  __atomic_fetch_add(&a->tally->enemies_realised, 1u, __ATOMIC_RELAXED);

  uint64_t rounds = 0, accesses = 0;
  uint32_t i = 0;
  /* The stop flag is read atomically every round: a plain load could be hoisted
     out of the loop, and an enemy that never re-reads its flag never stops. */
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t r = 0; r < a->nidx; r++) {
      /* M2 (indirect): the region is reached through a SHUFFLED index array, not
         by walking r -- "a shuffled array of pointers, giving a much greater
         variability of outcomes" (Alglave TACAS'11 3).  Indirection is applied to
         the SCRATCHPAD ONLY; the coherent single-word test variables stay direct.
         M4 (stride): consecutive regions are `stride' words apart, so they land on
         distinct cache lines -- the CPU-side analogue of S&D's spread/distance. */
      volatile uint64_t *l = a->scratch + (size_t)a->idx[r] * (size_t)a->stride;
      switch (a->seq) {              /* sigma -- RUNTIME, divergence (1) */
      case 0:  *l = i; *l = i + 1;        break;   /* st;st -- the pure WRITER */
      case 1:  *l = i; (void)*l;          break;   /* st;ld */
      case 2:  (void)*l; *l = i;          break;   /* ld;st */
      default: (void)*l; (void)*l;        break;   /* ld;ld */
      }
      accesses += 2;
    }
    i++;
    rounds++;
  }
  /* One flush at the end.  An atomic bump per round would make the tally itself a
     contended location and change the stress it is supposed to be measuring. */
  __atomic_fetch_add(&a->tally->enemy_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->enemy_accesses, accesses, __ATOMIC_RELAXED);
  return NULL;
}

/* ---- Half 2b: the GRACE noise thread -------------------------------------
 * Fusco's Grace noise kernel: continuously stream-read a buffer homed on the
 * OTHER processing unit's memory (HBM), so every read that misses cache crosses
 * the C2C interconnect.  The Hopper twin is emitted into the .cu as extra blocks
 * of the persistent grid (never a second kernel -- see the header of that file).
 *
 * The buffer is DISJOINT from every test location, so this is -2s-safe by the same
 * S&D invariant as the enemies.
 *
 * `buf' is volatile: the accumulator would otherwise be dead and -O2 would delete
 * the entire stream.  The accumulator is ALSO forced to escape into the tally --
 * belt and braces, because a noise thread that compiled to nothing would be the
 * fourth instance of this project's signature bug.
 * ------------------------------------------------------------------------- */
void *het_cpu_noise(void *_a) {
  het_cpu_noise_args *a = (het_cpu_noise_args *)_a;
  het_cpu_affinity(a->core, a->tally);

  uint64_t rounds = 0, words = 0, acc = 0, i = 0;
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t c = 0; c < a->chunk; c++) {
      acc += a->buf[i];
      i += a->stride;
      if (i >= a->words) i = 0;    /* wrap: keep the whole working set streaming */
    }
    words += a->chunk;
    rounds++;
  }
  __atomic_fetch_add(&a->tally->noise_cpu_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->noise_cpu_words, words, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->noise_sink, acc, __ATOMIC_RELAXED);
  return NULL;
}

/* ---- first-touch (see the declaration above for why this is load-bearing) --
 * One write per page.  `volatile' so it cannot be optimised away -- a first-touch
 * loop the compiler deletes leaves the buffer on the zero page, which is precisely
 * the failure it exists to prevent.
 * ------------------------------------------------------------------------- */
void het_cpu_first_touch(void *p, size_t bytes) {
  long ps = sysconf(_SC_PAGESIZE);
  if (ps < 1) ps = 4096;
  volatile unsigned char *b = (volatile unsigned char *)p;
  for (size_t i = 0; i < bytes; i += (size_t)ps) b[i] = 1u;
  if (bytes > 0) b[bytes - 1] = 1u;      /* the tail page, if bytes is not a multiple */
}

/* ---- M2: the shuffle behind the indirection ------------------------------
 * Fisher-Yates over rand(), which the driver seeds per run from (seed0 + run)
 * -- seed0 being HET_SEED or its runtime env override (B7b) -- so the layout is
 * replayable.  This is the CPU twin of het_set_scratch_locations' random line
 * choice in het_stress.cuh.
 * ------------------------------------------------------------------------- */
void het_cpu_shuffle(uint32_t *idx, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) idx[i] = i;
  for (uint32_t i = n; i > 1; i--) {
    uint32_t j = (uint32_t)(rand() % (int)i);
    uint32_t t = idx[i - 1]; idx[i - 1] = idx[j]; idx[j] = t;
  }
}

#endif /* HET_CPU_STRESS_IMPL */

#ifdef __cplusplus
}
#endif
#endif /* HET_CPU_STRESS_H */
