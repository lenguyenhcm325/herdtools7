/* =========================================================================
 * het_cpu_stress.h -- HetLitmus CPU-side + interconnect stress.
 * Emitted verbatim into every harness dir; edit litmus/het-runtime/het_cpu_stress.h,
 * never a harness-dir copy.  <test>_cpu.c includes it with HET_CPU_STRESS_IMPL and
 * compiles the bodies; <test>.cu / .hip see only the knobs, the argument structs
 * and the declarations -- the bodies are host-ISA inline asm nvcc must not meet.
 * Why this is a separate header, and the -2s invariants it holds by construction:
 * litmus/het-runtime/README.md.  Design:
 * hetlitmus/docs/00-environment-design.md sec 3.6.
 *
 * WHY THIS LAYER EXISTS.  het_stress.h's device-only scratchpad widens the
 * intra-device window.  The heterogeneous weak behaviour lives in the cross-device
 * window -- a store in flight across the host-device interconnect but not yet
 * globally visible -- which per-device stress on either side never loads.  Two
 * levers here do.  Half 1, CPU-side stress: litmus7's incantation vocabulary
 * ported as recipes (never through Skel.ml) -- preload, disjoint-scratchpad enemy
 * threads, indirect access, stride/spread, affinity.  Half 2, interconnect stress:
 * (a) placement, pinning the shared pages remote to their consumer, which lives in
 * the .cu beside gd_alloc_shared because it is vendor API rather than host asm;
 * and (b) noise, each processing unit continuously stream-reading the other one's
 * memory over a working set far larger than any cache.
 *
 * What half 2 buys is an INFERENCE, and a confounded one: placement and noise slow
 * the whole loop, so there are fewer rendezvous per second, and sightings = yield
 * x rate.  What it supports is that interconnect stress is additive with
 * per-device stress and is the lever most specific to the cross-device window --
 * not that it beats per-device stress.  Do not upgrade that without hardware
 * evidence.
 *
 * SOURCES, cited because they are reused; for [CudaLitmus], which carries no
 * licence file, citation is the condition of the reuse (stated once, het_stress.h).
 *   [Alglave11 sec 3] -- the CPU incantation vocabulary ported here: concurrent
 *     instances, indirect (shuffled-pointer) access, preload, affinity; and sec 4,
 *     that a good parameter combination is a property of the testbed.
 *   [Sorensen16 sec 1] -- the disjoint-scratchpad invariant that makes all of this
 *     sound, and (sec 3.2-3.4) the knobs patch P / sequence sigma / spread m.
 *   [Alglave15 sec 4.3.1] -- the window-widening hypothesis, that a bus under
 *     heavy stress is likelier to transfer data out of order, and the NVIDIA/AMD
 *     vendor split, which is stated once, in het_stress.h.
 *   [Fusco24 sec III-E.1] -- the noise-kernel construction (each unit
 *     stream-reads the other's memory from a large buffer), and the caveat that
 *     Hopper's L2 caches peer HBM, so placement alone does not guarantee that
 *     anything crosses.  See HET_NOISE_MB / HET_LLC_MB.
 *   [Schieffer24 sec II.C] and [Wahlgren25 sec 4.4] -- the MI300A analogue.
 *     There is no placement lever there (one HBM pool, no cudaMemAdvise
 *     equivalent); the analogue is cross-chiplet coherence contention, which the
 *     same noise pair produces when both sides stream one shared fine-grained
 *     coherent pool.  Only the placement half is NVIDIA-only.
 *   The cache primitives are litmus7's own, reused verbatim from
 *     litmus/libdir/_aarch64/_cache.h and _x86_64/_cache.h (CeCILL-B).
 *
 * NOT PORTED: launch randomisation; and a shared-timebase release, for which no
 * shared clock exists -- Grace's cntvct_el0 and Hopper's %globaltimer have
 * different epochs.
 * ========================================================================= */
#ifndef HET_CPU_STRESS_H
#define HET_CPU_STRESS_H

/* No <pthread.h> here: x86 glibc's copy does not survive the gated
   `clang --target=aarch64-linux-gnu -c' step (README.md has the detail).  The
   thread bodies below need only the void*(void*) signature; pthread_create is
   called from the .cu, which is built for the native host. */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * HALF 1 KNOBS -- CPU-side stress.  Every numeric here and below is a SEED, not a
 * tuning: a good combination is a property of the testbed [Alglave11 sec 4], and
 * a chip's parameters need not suit another chip of the same vendor [Kirkham20
 * sec 6.4].  Re-tune on GH200 and again on MI300A -- they do not even share the
 * interconnect lever.  All are -D-overridable so a sweep needs no re-emission, and
 * main() reports the realised counters and warns when one falls short of its knob,
 * because a knob that says 9 while the hardware realised 1 silently misstates the
 * stress that re-tuning reads.
 * ------------------------------------------------------------------------- */
#ifndef HET_CPU_ENEMIES
#define HET_CPU_ENEMIES (-1)      /* -1 = auto: every spare core (see main())    */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the enemy scratchpad.
                                          Plain host malloc -- CPU-only, disjoint
                                          from every test location, so it needs
                                          neither GPU coherence nor device memory.
                                          The object classes are listed at
                                          litmus/hetDialect.ml gd_noise_mem_defs. */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* spread m [Sorensen16]: distinct lines hit   */
#endif
#ifndef HET_CPU_STRIDE
#define HET_CPU_STRIDE 8          /* word gap between regions.  8 x 8B = 64B =
                                     one cache line, so consecutive regions land
                                     on distinct lines.                          */
#endif
#ifndef HET_CPU_ENEMY_SEQ
#define HET_CPU_ENEMY_SEQ 0       /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld.
                                     0 is the only pure writer, and on most GPUs
                                     measured a stores-only sequence ranks lowest
                                     [Sorensen16 sec 3.3].  It reaches the enemy
                                     as a RUNTIME field -- see het_cpu_enemy.    */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* % of iterations a TEST thread preloads its
                                     own test variables (litmus7's default preload
                                     mode is RandomPL).                          */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* pin threads to cores (sched_setaffinity)    */
#endif
#ifndef HET_CPU_TEST_CORE0
#define HET_CPU_TEST_CORE0 0      /* first core the CPU test threads are pinned to*/
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS, the driver and
                                     the GPU-launch thread.  Grace has 72 cores and
                                     no SMT, so litmus7's SMT/hyperthread knobs are
                                     inert there and affinity reduces to which core
                                     plus L2/L3 locality; on the x86 MI300A host
                                     (24c/48t over 3 CCDs) they are live.        */
#endif

/* -------------------------------------------------------------------------
 * HALF 2 KNOBS -- interconnect.  HET_PLACE is consumed in the .cu (it is vendor
 * API, not host asm); the noise knobs are consumed on both sides.
 * ------------------------------------------------------------------------- */
#ifndef HET_PLACE
#define HET_PLACE 0               /* shared-var placement:
                                     0 = first-touch (DEFAULT) -- plain malloc(),
                                         first touch decides, which is [Bagchi26]'s
                                         baseline and the honest default while the
                                         net effect of pinning stays confounded.
                                     1 = prefer HBM  (pages home on the GPU)
                                     2 = prefer DDR  (pages home on the CPU)
                                     Swept on hardware.  Do not promote a non-zero
                                     default without hardware evidence.          */
#endif
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* per noise buffer, matching [Fusco24]'s 8 GB.
                                     The size is not arbitrary: the buffer must
                                     exceed the last-level cache on the path, or
                                     the reads hit cache and cross nothing.
                                     Checked at run time -- see HET_LLC_MB.      */
#endif
#ifndef HET_NOISE_CPU
#define HET_NOISE_CPU 1           /* the host half: a CPU thread stream-reading a
                                     buffer homed on device memory               */
#endif
#ifndef HET_NOISE_GPU_BLOCKS
#define HET_NOISE_GPU_BLOCKS 8    /* the device half: blocks of the PERSISTENT grid
                                     stream-reading a host-homed buffer.  They are
                                     extra blocks of the existing kernel, never a
                                     second __global__ -- a separate kernel would
                                     drop its ops into the middle of the flat GPU
                                     op stream that a static faithfulness reading
                                     slices per lane.                             */
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
   traffic at all: a buffer that fits in it is served from cache and the noise
   crosses nothing, so the driver warns at run time rather than let a green
   compile imply a live mechanism.  The figure is per target and the build
   supplies it (NVCC="nvcc -DHET_LLC_MB=<MB>", hetlitmus/docs/het-emission.md);
   the default is a fallback measured on another part -- max(Grace L3 114 MB,
   Hopper L2 51 MB) [Bagchi26 Table 1] -- and the warning says so.  Both branches
   define the flag below: an undefined macro reads as 0 under #if. */
#ifndef HET_LLC_MB
#define HET_LLC_MB 114
#define HET_LLC_MB_IS_FALLBACK 1
#else
#define HET_LLC_MB_IS_FALLBACK 0
#endif

#if (HET_CPU_ENEMY_SEQ) < 0 || (HET_CPU_ENEMY_SEQ) > 3
#error "HET_CPU_ENEMY_SEQ must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_PLACE) < 0 || (HET_PLACE) > 2
#error "HET_PLACE must be 0 (first-touch), 1 (prefer HBM) or 2 (prefer DDR)"
#endif
#if (HET_CPU_SPREAD) < 1
#error "HET_CPU_SPREAD must be >= 1 (it is the spread m of [Sorensen16 sec 3.4])"
#endif
#if (HET_CPU_STRIDE) < 1
#error "HET_CPU_STRIDE must be >= 1"
#endif
/* A zero stride or a zero chunk turns the noise stream into a no-op with no other
   symptom, while the round counters still look healthy: stride 0 never advances
   the index, so the thread re-reads one location out of L1 for ever; chunk 0 never
   enters the inner loop.  Refuse to compile. */
#if (HET_NOISE_STRIDE) < 1
#error "HET_NOISE_STRIDE must be >= 1 (0 re-reads ONE location for ever: no traffic)"
#endif
#if (HET_NOISE_CHUNK) < 1
#error "HET_NOISE_CHUNK must be >= 1 (0 streams nothing)"
#endif
#if (HET_NOISE_MB) < 1
#error "HET_NOISE_MB must be >= 1"
#endif
#if (HET_LLC_MB) < 1
#error "HET_LLC_MB must be >= 1 (0 silences the below-cache warning for every run)"
#endif

/* -------------------------------------------------------------------------
 * LIVENESS TALLY -- the CPU twin of het_stress.h's.  Nothing in this layer shows
 * up in a static reading: the enemies touch a private scratchpad, the preload
 * emits cache hints, the noise streams a disjoint buffer, and none of it enters
 * the tested op stream (correctly -- it is scaffolding).  So a layer that has
 * silently stopped working looks exactly like one that is working, and these
 * counters are the only run-time evidence that distinguishes them.
 *
 *   enemy_rounds     0 => the enemies never ran (a stop flag set after they
 *                    exited, or a loop the optimiser deleted as side-effect-free).
 *   preload_ops      0 => the preload is inert (a host ISA with no cache
 *                    primitives, or a 0% roll).
 *   noise_cpu_rounds 0 => the host half of the interconnect noise never ran.
 *   aff_failures    >0 => sched_setaffinity failed, so every thread landed
 *                    wherever the scheduler chose and the stress topology is not
 *                    the one the tuning assumed.
 *   place_failures  >0 => cudaMemAdvise was refused, so HET_PLACE did nothing
 *                    while claiming to place.  (Filled in the .cu; carried here so
 *                    one struct is the whole vital-signs record.)
 * ------------------------------------------------------------------------- */
typedef struct het_cpu_tally {
  uint64_t enemy_rounds;      /* enemy loop iterations, summed over enemies      */
  uint64_t enemy_accesses;    /* scratchpad accesses issued by the enemies       */
  uint64_t preload_ops;       /* preload cache hints actually issued             */
  uint64_t noise_cpu_rounds;  /* host noise thread: streaming rounds             */
  uint64_t noise_cpu_words;   /* host noise thread: words read                   */
  uint64_t noise_sink;        /* the streamed values, forced to escape (below)   */
  uint32_t enemies_realised;  /* enemy threads that actually entered their loop  */
  uint32_t aff_failures;      /* sched_setaffinity failures -- never silent      */
  uint32_t place_failures;    /* cudaMemAdvise failures (filled by the .cu)      */
  uint32_t preload_inert;     /* 1 => this host has NO cache primitives at all   */
} het_cpu_tally;

/* Enemy arguments.  Every behavioural field is a runtime value (het_cpu_enemy). */
typedef struct het_cpu_enemy_args {
  volatile uint64_t *scratch; /* DISJOINT host scratchpad.  Never a test var.    */
  const uint32_t *idx;        /* shuffled region indices (the indirection)       */
  uint32_t nidx;              /* spread m -- how many regions per round          */
  uint32_t stride;            /* word gap between regions                        */
  uint32_t seq;               /* sigma, 0..3.  Runtime -- see het_cpu_enemy.     */
  int core;                   /* core to pin to, or -1 for unpinned              */
  int *go;                    /* the stop flag; set BEFORE the enemies are spawned*/
  het_cpu_tally *tally;
} het_cpu_enemy_args;

/* Host-side noise arguments (half 2b).  `buf' is the OTHER unit's memory. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* device-homed: every read crosses the link    */
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
/* The preload.  Returns the number of hints issued, so the caller can accumulate
   locally and flush once -- an atomic bump per hint would put scaffolding
   contention in the middle of the tested loop, the one place it must not be. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct);
/* Exposes the host-only HET_CPU_PRELOAD_LIVE to the .cu driver, which cannot read
   the macro (it is defined only under HET_CPU_STRESS_IMPL, which nvcc never
   compiles).  The driver sets `_ct.preload_inert = !het_cpu_preload_live()', so a
   host with no cache primitives does not request a preload that can only no-op --
   which would otherwise disqualify the run and turn every null cold. */
int      het_cpu_preload_live(void);
void    *het_cpu_enemy(void *a);   /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the host half of the noise pair*/
/* -------------------------------------------------------------------------
 * FIRST-TOUCH -- the difference between a noise buffer that stresses the
 * interconnect and one that stresses nothing.
 *
 * A malloc'd buffer that has never been WRITTEN is not backed by physical memory:
 * Linux maps every untouched anonymous page to a single shared, read-only zero
 * page.  Reading such a buffer -- exactly what a noise kernel does -- therefore
 * touches ONE physical cache line however large the buffer is: every read hits L1
 * and generates no DRAM and no interconnect traffic, while the round counters
 * still look healthy.  An 8 GB noise buffer would be 4 KB of physical memory.
 * Both halves of that -- the hazard and this call's fix -- are measured through
 * RSS by cpustresscheck.
 *
 * It also decides the page's NUMA home on GH200, which is why the caller advises
 * the preferred location BEFORE calling this and prefetches afterwards if the
 * pages must end up on the far side.  One write per page suffices.
 * ------------------------------------------------------------------------- */
void     het_cpu_first_touch(void *p, size_t bytes);
/* Host-side, seeded from srand() by the driver, so a run replays from its seed
   [GPUHarbor23 sec 3.4]. */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n);

#ifdef HET_CPU_STRESS_IMPL
/* ========================= IMPLEMENTATION =================================
 * Compiled ONLY in the <test>_cpu.c translation unit (gcc for the build host, and
 * clang --target=aarch64-linux-gnu for the real AArch64 asm).  nvcc never sees a
 * line of it.
 * ========================================================================= */
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <unistd.h>

/* ---- cache primitives ----------------------------------------------------
 * litmus7's own, reused verbatim from litmus/libdir/_aarch64/_cache.h and
 * litmus/libdir/_x86_64/_cache.h (CeCILL-B, as the rest of the tree).
 *
 * On AArch64 `dc civac' cleans and invalidates to the point of coherence, which on
 * GH200 is the coherence point shared with the GPU over C2C -- so the preload
 * plausibly touches the cross-device path and not merely the CPU's own cache.
 * That is an INFERENCE, unmeasured: it may equally be redundant with the coherence
 * traffic the test's own race already generates.  Measure it before claiming it.
 * ------------------------------------------------------------------------- */
#if defined(__aarch64__)
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
#define HET_CPU_PRELOAD_LIVE 0
/* No cache primitives on this host, so the preload is inert here and
   het_cpu_preload says so rather than returning a healthy-looking count of hints
   it never issued. */
static inline void het_cache_flush(void *p) { (void)p; }
static inline void het_cache_touch(void *p) { (void)p; }
static inline void het_cache_touch_store(void *p) { (void)p; }
#endif

/* ---- seeded Park-Miller (host twin of het_stress.h's) ------------------ */
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

/* ---- affinity ------------------------------------------------------------
 * The reuse path is litmus7's write_one_affinity (libdir/_linux_affinity.c:117):
 * it bottoms out in sched_setaffinity with a one-CPU mask.  The recipe is reused,
 * not the file: this harness has no route through Skel.ml.
 *
 * One deliberate difference: litmus7 errexit()s on failure.  A campaign must not
 * die mid-run, but a silently failed pin puts every thread wherever the scheduler
 * likes, which changes the stress topology while looking identical from outside.
 * So: count it, and let main() report it.
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

/* ---- preload -------------------------------------------------------------
 * Called from cpu_thread_P<n>, per iteration, BEFORE het_run_P<n> -- never inside
 * it (-2s invariant (ii), README.md).  It targets the test variables on purpose:
 * that is what a preload is, and it stays -2s-safe because a cache hint changes
 * residency rather than program order, and because it cannot migrate into the
 * tested sequence -- that body is an opaque call into another translation unit and
 * every primitive above is asm volatile with a "memory" clobber.
 * ------------------------------------------------------------------------- */
int het_cpu_preload_live(void) { return HET_CPU_PRELOAD_LIVE; }

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

/* ---- the disjoint-scratchpad enemy ----------------------------------------
 * Divergence from litmus7: concurrent instances are ported as enemy threads in the
 * form of [Sorensen16 sec 1], not as its own test repetition.  That runs
 * n = max(1, a/t) copies of the whole test concurrently [Alglave11 sec 3], which
 * does not compose with a persistent GPU kernel -- the het instance count is
 * capped by CPU cores, not test replicas -- so what is ported is the idea,
 * concurrent memory-subsystem contention, in the disjoint-scratchpad form, which
 * is -2s-safe by construction.
 *
 * `seq' is a RUNTIME field, and the accesses are `volatile'.  Both are
 * load-bearing.  A compile-time sigma lets the optimiser fold the switch to the
 * one branch -D named, and a branch whose accesses it can discard takes the
 * traffic with it -- the failure mode het_stress.h's caller contract describes.
 * Without `volatile' the loop's only observable effect is memory traffic it does
 * not name, so -O2 deletes the reads outright; this is where the CPU enemy
 * diverges from the GPU stresser, whose accesses are deliberately non-volatile.
 * `volatile' forbids elision and reordering while leaving the traffic ordinary
 * and cacheable to the hardware.  Both properties are read off the COMPILED asm
 * by cpustresscheck, because reading the source proves nothing.
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
      /* Indirect access: the region is reached through a shuffled index array
         rather than by walking r, which buys a much greater variability of
         outcomes [Alglave11 sec 3].  It is applied to the SCRATCHPAD ONLY; the
         coherent single-word test variables stay direct.  Consecutive regions are
         `stride' words apart, so they land on distinct cache lines -- the CPU-side
         analogue of the spread/distance of [Sorensen16 sec 3.4]. */
      volatile uint64_t *l = a->scratch + (size_t)a->idx[r] * (size_t)a->stride;
      switch (a->seq) {              /* sigma -- runtime, see above */
      case 0:  *l = i; *l = i + 1;        break;   /* st;st -- the pure writer */
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

/* ---- half 2b: the HOST noise thread --------------------------------------
 * The noise-kernel construction of [Fusco24 sec III-E.1]: continuously stream-read
 * a buffer homed on the other processing unit's memory, so every read that misses
 * cache crosses the interconnect.  The device twin is emitted into the .cu as
 * extra blocks of the persistent grid, never a second kernel (see
 * HET_NOISE_GPU_BLOCKS).  The buffer is disjoint from every test location, so this
 * is -2s-safe by the same disjointness invariant as the enemies.
 *
 * `buf' is volatile and the accumulator escapes into the tally: otherwise the
 * accumulator is dead and -O2 deletes the entire stream.
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

/* ---- the shuffle behind the indirection ----------------------------------
 * Fisher-Yates over rand(), which the driver seeds per run from (seed0 + run),
 * seed0 being HET_SEED or its run-time env override, so the layout is replayable.
 * The CPU twin of het_set_scratch_locations' random line choice.
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
