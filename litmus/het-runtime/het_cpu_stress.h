/* =========================================================================
 * het_cpu_stress.h -- CPU-side (half 1) and interconnect (half 2) stress, the
 * two levers that load the cross-device window per-device stress never reaches.
 * Emitted verbatim into every harness dir; edit this file, never a copy.
 * <test>_cpu.c includes it with HET_CPU_STRESS_IMPL and compiles the bodies; the
 * .cu / .hip see only the knobs, the argument structs and the declarations --
 * the bodies are host-ISA inline asm nvcc must NOT meet.
 * Design and what is not ported: hetlitmus/docs/00-environment-design.md sec 3.6.
 * ========================================================================= */
#ifndef HET_CPU_STRESS_H
#define HET_CPU_STRESS_H

/* NO pthread header here: x86 glibc's does not cross-assemble for AArch64
   (litmus/het-runtime/README.md). */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Half 1 knobs -- CPU-side stress.  Every numeric here and below is a seed, not
 * a tuning: a good combination is a property of the testbed [Alglave11 sec 4]
 * and need not carry to another chip of the same vendor [Kirkham20 sec 6.4] --
 * re-tune on GH200 and again on MI300A.  All are -D-overridable, and main()
 * reports the realised counters and warns when one falls short of its knob. */
#ifndef HET_CPU_ENEMIES
#define HET_CPU_ENEMIES (-1)      /* -1 = auto: every spare core (see main())    */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the enemy scratchpad.
                                          Plain host malloc, disjoint from every
                                          test location, so it needs neither GPU
                                          coherence nor device memory.          */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* spread m [Sorensen16]: distinct lines hit   */
#endif
#ifndef HET_CPU_STRIDE
#define HET_CPU_STRIDE 8          /* word gap between regions: 8 x 8B = 64B, one
                                     cache line, so consecutive regions land on
                                     distinct lines.                            */
#endif
#ifndef HET_CPU_ENEMY_SEQ
#define HET_CPU_ENEMY_SEQ 0       /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld.  A
                                     stores-only sequence ranks lowest on most
                                     chips measured [Sorensen16 sec 3.3].  It
                                     reaches the enemy as a RUNTIME field.      */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* % of iterations a test thread preloads its
                                     own test variables (litmus7's RandomPL).   */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* pin threads to cores (sched_setaffinity)    */
#endif
#ifndef HET_CPU_TEST_CORE0
#define HET_CPU_TEST_CORE0 0      /* first core the CPU test threads are pinned to*/
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS, the driver
                                     and the GPU-launch thread.  Grace has no
                                     SMT, so litmus7's SMT knobs are inert there;
                                     on the x86 MI300A host (24c/48t over 3 CCDs)
                                     they are live.                             */
#endif

/* Half 2 knobs -- interconnect.  HET_PLACE is consumed in the .cu (it is vendor
 * API, not host asm); the noise knobs are consumed on both sides. */
#ifndef HET_PLACE
#define HET_PLACE 0               /* shared-var placement: 0 = first-touch
                                     (the default: plain malloc(), first touch
                                     decides), 1 = prefer HBM (pages home on the
                                     GPU), 2 = prefer DDR.  Do NOT promote a
                                     non-zero default without hardware evidence. */
#endif
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* per noise buffer, matching [Fusco24]'s 8 GB.
                                     It must EXCEED the last-level cache on the
                                     path or the reads hit cache and cross
                                     nothing -- see HET_LLC_MB.                 */
#endif
#ifndef HET_NOISE_CPU
#define HET_NOISE_CPU 1           /* the host half: a CPU thread stream-reading a
                                     buffer homed on device memory              */
#endif
#ifndef HET_NOISE_GPU_BLOCKS
#define HET_NOISE_GPU_BLOCKS 8    /* the device half: extra blocks of the
                                     PERSISTENT grid stream-reading a host-homed
                                     buffer, never a second __global__ whose ops
                                     would land in the flat GPU op stream.      */
#endif
#ifndef HET_NOISE_CHUNK
#define HET_NOISE_CHUNK 4096      /* words streamed per round before the stop flag
                                     is re-tested; it bounds how long the noise
                                     can outlive the test.                      */
#endif
#ifndef HET_NOISE_STRIDE
#define HET_NOISE_STRIDE 1        /* words between consecutive noise reads         */
#endif

/* The last-level cache the noise buffer must EXCEED: one that fits in it is
   served from cache and crosses nothing, an L2 caching peer HBM included
   [Fusco24 sec III-E.1].  The figure is per target and the build supplies it
   (hetlitmus/docs/het-emission.md "The pair a harness names"); the default is a
   fallback for another part, max(Grace L3 114, Hopper L2 51) [Bagchi26 Table 1]. */
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
#error "HET_CPU_SPREAD must be >= 1 (the spread m)"
#endif
#if (HET_CPU_STRIDE) < 1
#error "HET_CPU_STRIDE must be >= 1"
#endif
/* Stride 0 never advances the index (one location re-read out of L1 for ever)
   and chunk 0 never enters the inner loop: either is a no-op noise stream whose
   round counters still look healthy, so refuse to compile. */
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

/* Liveness tally -- the CPU twin of het_stress.h's.  None of this layer enters
 * the tested op stream, so these counters are the ONLY run-time evidence that it
 * ran: a zero round/op count means the mechanism never ran, a nonzero failure
 * count that a pin or a placement was refused. */
typedef struct het_cpu_tally {
  uint64_t enemy_rounds;      /* enemy loop iterations, summed over enemies      */
  uint64_t enemy_accesses;    /* scratchpad accesses issued by the enemies       */
  uint64_t preload_ops;       /* preload cache hints actually issued             */
  uint64_t noise_cpu_rounds;  /* host noise thread: streaming rounds             */
  uint64_t noise_cpu_words;   /* host noise thread: words read                   */
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

/* Host-side noise arguments.  `buf' is the OTHER unit's memory. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* device-homed: every read crosses the link    */
  uint64_t words;
  uint32_t chunk;             /* words per round before the stop flag is re-tested*/
  uint32_t stride;
  int core;
  int *go;
  het_cpu_tally *tally;
} het_cpu_noise_args;

/* API.  Bodies are compiled ONLY into <test>_cpu.c (HET_CPU_STRESS_IMPL). */
int      het_cpu_affinity(int core, het_cpu_tally *t);  /* 0 = pinned, -1 = failed */
int      het_cpu_ncores(void);
uint32_t het_cpu_rng_init(uint32_t seed, uint32_t lane);
/* Returns the hints issued, so the caller accumulates locally and flushes once:
   an atomic bump per hint would put scaffolding contention inside the tested
   loop, the one place it must NOT be. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct);
/* Exposes HET_CPU_PRELOAD_LIVE to the .cu driver, which cannot read the macro
   (defined only under HET_CPU_STRESS_IMPL).  The driver uses it so a host with
   no cache primitives does not request a preload that can only no-op, which
   would disqualify the run and turn every null cold. */
int      het_cpu_preload_live(void);
void    *het_cpu_enemy(void *a);   /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the host half of the noise pair*/
/* First touch, one write per page.  Linux maps every untouched anonymous page to
   one shared read-only zero page, so an unwritten 8 GB buffer streams one cache
   line and crosses NOTHING while the round counters look healthy.  It also
   decides the page's NUMA home on GH200, so the caller advises the preferred
   location before this call and prefetches after it. */
void     het_cpu_first_touch(void *p, size_t bytes);
/* Host-side, seeded from srand() by the driver, so a run replays from its seed
   [GPUHarbor23 sec 3.4]. */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n);

#ifdef HET_CPU_STRESS_IMPL
/* Implementation -- compiled ONLY in the <test>_cpu.c translation unit (gcc for
 * the build host, clang --target=aarch64-linux-gnu for real AArch64 asm); nvcc
 * never sees it. */
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <unistd.h>

/* Cache primitives, reused from litmus7's litmus/libdir/_aarch64/_cache.h and
 * _x86_64/_cache.h (CeCILL-B, as the rest of the tree).  On AArch64 `dc civac'
 * cleans and invalidates to the point of coherence, which on GH200 is the point
 * shared with the GPU over C2C; whether the preload therefore reaches the
 * cross-device path is unmeasured. */
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
  /* litmus7 found no x86 way to announce an intention to store, so this is
     prefetcht0 as well, not a store-intent hint. */
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
#else
#define HET_CPU_PRELOAD_LIVE 0
/* No cache primitives on this host: het_cpu_preload says so rather than
   returning a healthy-looking count of hints it never issued. */
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

/* Affinity: litmus7's write_one_affinity recipe (libdir/_linux_affinity.c),
 * reused rather than the file, this harness having no route through Skel.ml.
 * Divergence: litmus7 errexit()s on failure and a campaign must not die mid-run,
 * so a failed pin is counted here and reported by main() instead. */
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

/* Preload: called per iteration from cpu_thread_P<n>, BEFORE het_run_P<n> and
 * never inside it.  It targets the test variables on purpose and adds no
 * ordering -- a cache hint changes residency, not program order, and an opaque
 * call whose primitives all clobber "memory" cannot migrate into the tested
 * sequence. */
int het_cpu_preload_live(void) { return HET_CPU_PRELOAD_LIVE; }

uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct) {
#if HET_CPU_PRELOAD_LIVE == 0
  (void)vars; (void)nvars; (void)rng; (void)pct;
  return 0u;                        /* inert -- the driver reports it, see above */
#else
  uint32_t n = 0u;
  for (int i = 0; i < nvars; i++) {
    if (!het_cpu_rng_pct(rng, pct)) continue;
    /* litmus7's RandomPL: flush / touch / touch-for-store, drawn per variable
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

/* The disjoint-scratchpad enemy.  Divergence from litmus7: test repetition is
 * ported as disjoint-scratchpad enemy threads [Sorensen16 sec 1], not as
 * concurrent copies of the whole test [Alglave11 sec 3], which does not compose
 * with a persistent GPU kernel.  `seq' must stay a RUNTIME field and the
 * accesses `volatile', or -O2 folds the switch and deletes the reads. */
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
         rather than by walking r [Alglave11 sec 3], and ONLY on the scratchpad --
         the test variables stay direct.  Consecutive regions are `stride' words
         apart, so they land on distinct lines [Sorensen16 sec 3.4]. */
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
  /* One flush at the end: an atomic bump per round would make the tally itself a
     contended location and change the stress it measures. */
  __atomic_fetch_add(&a->tally->enemy_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->enemy_accesses, accesses, __ATOMIC_RELAXED);
  return NULL;
}

/* The host noise thread: the noise-kernel construction of [Fusco24 sec III-E.1]
 * -- stream-read a buffer homed on the other unit's memory, so every read that
 * misses cache crosses the interconnect.  The buffer is disjoint from every test
 * location.  `buf' is volatile, so the stream is issued with no value escaping. */
void *het_cpu_noise(void *_a) {
  het_cpu_noise_args *a = (het_cpu_noise_args *)_a;
  het_cpu_affinity(a->core, a->tally);

  uint64_t rounds = 0, words = 0, i = 0;
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t c = 0; c < a->chunk; c++) {
      (void)a->buf[i];
      i += a->stride;
      if (i >= a->words) i = 0;    /* wrap: keep the whole working set streaming */
    }
    words += a->chunk;
    rounds++;
  }
  __atomic_fetch_add(&a->tally->noise_cpu_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->noise_cpu_words, words, __ATOMIC_RELAXED);
  return NULL;
}

/* One write per page, `volatile' so it cannot be optimised away: a first-touch
   loop the compiler deletes leaves the buffer on the zero page, the failure it
   exists to prevent. */
void het_cpu_first_touch(void *p, size_t bytes) {
  long ps = sysconf(_SC_PAGESIZE);
  if (ps < 1) ps = 4096;
  volatile unsigned char *b = (volatile unsigned char *)p;
  for (size_t i = 0; i < bytes; i += (size_t)ps) b[i] = 1u;
  if (bytes > 0) b[bytes - 1] = 1u;      /* the tail page, if bytes is not a multiple */
}

/* The shuffle behind the indirection: Fisher-Yates over rand(), which the driver
   seeds per run from (seed0 + run). */
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
