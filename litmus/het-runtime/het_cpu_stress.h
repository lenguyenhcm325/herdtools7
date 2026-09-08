/* =========================================================================
 * het_cpu_stress.h -- CPU-side (half 1) and interconnect (half 2) stress, the
 * levers on the cross-device window per-device stress never reaches.
 * Emitted verbatim into every harness dir; edit this file, never a copy.
 * <test>_cpu.c includes it with HET_CPU_STRESS_IMPL and compiles the bodies;
 * the .cu / .hip see only knobs, structs and declarations -- the bodies are
 * host-ISA inline asm nvcc must NOT meet.
 * Design: hetlitmus/docs/00-environment-design.md "Interconnect stress".
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

/* Half 1 knobs -- CPU-side stress.  Every numeric is a seed, not a tuning
 * [Alglave11 sec 4] [Kirkham20 sec 6.4]; all are -D-overridable. */
#ifndef HET_CPU_STRESS_THREADS
#define HET_CPU_STRESS_THREADS (-1)  /* -1 = auto: every spare core (see main()) */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the stress scratchpad  */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* spread m [Sorensen16]: distinct lines hit   */
#endif
#ifndef HET_CPU_WORDS_PER_REGION
#define HET_CPU_WORDS_PER_REGION 8  /* 8 x 8 B = one 64 B line per region        */
#endif
#ifndef HET_CPU_STRESS_PATTERN
#define HET_CPU_STRESS_PATTERN 0  /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld [Sorensen16 sec 3.3] */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* % of iterations preloading the test vars    */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* pin threads to cores (sched_setaffinity)    */
#endif
#ifndef HET_CPU_FIRST_CORE
#define HET_CPU_FIRST_CORE 0      /* test, noise, stress threads pin upward from it */
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS and the driver */
#endif

/* Half 2 knobs -- interconnect: the noise knobs, consumed on both sides. */
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* the noise buffer [Fusco24 sec III-C]; it must
                                     EXCEED the last-level cache (HET_LLC_MB)   */
#endif
#ifndef HET_CPU_NOISE_THREADS
#define HET_CPU_NOISE_THREADS 1   /* host half: threads, one slice of the buffer each */
#endif
#ifndef HET_GPU_NOISE_BLOCKS
#define HET_GPU_NOISE_BLOCKS 8    /* device half: extra blocks of the PERSISTENT grid */
#endif
#ifndef HET_NOISE_WORDS_PER_ROUND
#define HET_NOISE_WORDS_PER_ROUND 4096  /* words streamed between stop-flag checks */
#endif
#ifndef HET_NOISE_STRIDE
#define HET_NOISE_STRIDE 1        /* words between consecutive noise reads         */
#endif

/* The last-level cache the noise buffer must EXCEED [Fusco24 sec III-E.1]; the
   build supplies it per target, the default is [Bagchi26 Table 1]'s largest. */
#ifndef HET_LLC_MB
#define HET_LLC_MB 114
#define HET_LLC_MB_IS_FALLBACK 1
#else
#define HET_LLC_MB_IS_FALLBACK 0
#endif

#if (HET_CPU_STRESS_PATTERN) < 0 || (HET_CPU_STRESS_PATTERN) > 3
#error "HET_CPU_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_CPU_SPREAD) < 1
#error "HET_CPU_SPREAD must be >= 1 (the spread m)"
#endif
#if (HET_CPU_WORDS_PER_REGION) < 1
#error "HET_CPU_WORDS_PER_REGION must be >= 1"
#endif
/* Either is a no-op noise stream whose round counters still look healthy. */
#if (HET_NOISE_STRIDE) < 1
#error "HET_NOISE_STRIDE must be >= 1 (0 re-reads ONE location for ever: no traffic)"
#endif
#if (HET_NOISE_WORDS_PER_ROUND) < 1
#error "HET_NOISE_WORDS_PER_ROUND must be >= 1 (0 streams nothing)"
#endif
#if (HET_NOISE_MB) < 1
#error "HET_NOISE_MB must be >= 1"
#endif
#if (HET_CPU_NOISE_THREADS) < 0
#error "HET_CPU_NOISE_THREADS must be >= 0 (0 = the host half off)"
#endif
#if (HET_CPU_NOISE_THREADS) > 1024
#error "HET_CPU_NOISE_THREADS too large (max 1024)"
#endif
/* A slice shorter than one round's words re-reads its few words for ever. */
#if (HET_CPU_NOISE_THREADS) > 0 && \
    (HET_NOISE_MB) * 131072 < (HET_CPU_NOISE_THREADS) * (HET_NOISE_WORDS_PER_ROUND)
#error "HET_CPU_NOISE_THREADS slices HET_NOISE_MB below one HET_NOISE_WORDS_PER_ROUND per thread"
#endif
#if (HET_LLC_MB) < 1
#error "HET_LLC_MB must be >= 1 (0 silences the below-cache warning for every run)"
#endif

/* Liveness tally: the ONLY run-time evidence this layer ran. */
typedef struct het_cpu_tally {
  uint64_t stress_rounds;
  uint64_t stress_accesses;
  uint64_t preload_ops;
  uint64_t cpu_noise_rounds;
  uint64_t cpu_noise_words;
  uint32_t stress_threads_realised; /* stress threads that entered their loop    */
  uint32_t aff_failures;      /* sched_setaffinity failures                      */
  uint32_t preload_inert;     /* 1 => this host has NO cache primitives          */
} het_cpu_tally;

/* Stress-thread arguments; every behavioural field is a runtime value. */
typedef struct het_cpu_stress_args {
  volatile uint64_t *scratch; /* DISJOINT host scratchpad, never a test var      */
  const uint32_t *idx;        /* shuffled region indices (the indirection)       */
  uint32_t nidx;              /* spread m: regions per round                     */
  uint32_t words_per_region;
  uint32_t pattern;           /* sigma, 0..3                                     */
  int core;                   /* -1 = unpinned                                   */
  int *go;                    /* the stop flag, set BEFORE the threads spawn     */
  het_cpu_tally *tally;
} het_cpu_stress_args;

/* Host noise arguments: `buf' is this thread's slice, disjoint from the others'. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* the device half reads the same buffer        */
  uint64_t words;
  uint32_t words_per_round;
  uint32_t stride;
  int core;
  int *go;
  het_cpu_tally *tally;
} het_cpu_noise_args;

/* The stress schedule: one stateless draw, host and device -- splitmix64 [Vigna15]
   at index k of stream (seed, who).  hetlitmus/docs/00-environment-design.md "Rendezvous". */
#if defined(__CUDACC__) || defined(__HIP_PLATFORM_AMD__) || \
    defined(__HIP_DEVICE_COMPILE__)
#define HET_DRAW_ATTR __host__ __device__ static inline
#else
#define HET_DRAW_ATTR static inline
#endif
HET_DRAW_ATTR uint32_t het_draw(uint32_t seed, uint32_t who, uint64_t k) {
  uint64_t z = (((uint64_t)seed << 32) | (uint64_t)who)
             + k * 0x9E3779B97F4A7C15ull;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return (uint32_t)(z ^ (z >> 31));
}
/* One decision per (who, k).  The ids are pairwise distinct: a GPU thread's
   global id stays below 2^31 in an occupancy-bounded grid, these lie above it. */
#define HET_WHO_CPU(c)   (0x80000000u | (uint32_t)(c))
#define HET_WHO_GRID     0xFFFFFFFDu
#define HET_WHO_SCRATCH  0xFFFFFFFEu
#define HET_WHO_SHUFFLE  0xFFFFFFFFu
/* k per participant: a GPU test lane draws 2n and 2n+1 at iteration n, the grid
   its mem-stress toggle at n, a CPU test thread 1+2*nvars per iteration. */

/* API.  Bodies are compiled ONLY into <test>_cpu.c (HET_CPU_STRESS_IMPL). */
int      het_cpu_affinity(int core, het_cpu_tally *t);  /* 0 = pinned, -1 = failed */
int      het_cpu_ncores(void);
/* Returns the hints issued: the caller flushes once, no atomic bump in the tested loop. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t seed,
                         uint32_t who, uint64_t k0, int pct);
/* HET_CPU_PRELOAD_LIVE for the .cu driver, which cannot read the macro. */
int      het_cpu_preload_live(void);
/* 0 = drawn, -1 = none available, which the caller must report. */
int      het_seed_entropy(uint32_t *out);
void    *het_cpu_stress(void *a);  /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the host half of the noise pair*/
/* One write per page: Linux maps every untouched anonymous page to ONE zero
   page, so an unwritten buffer streams one line and stresses nothing. */
void     het_cpu_first_touch(void *p, size_t bytes);
/* The permutation is a function of the run's seed. */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n, uint32_t seed);

#ifdef HET_CPU_STRESS_IMPL
#include <sched.h>
#include <unistd.h>
#include <sys/random.h>

/* 31 bits, so _seed0 + _run cannot wrap into another invocation's range;
   hetlitmus/campaign.py draws its base at the same width. */
int het_seed_entropy(uint32_t *out) {
  uint32_t s;
  if (getrandom(&s, sizeof s, GRND_NONBLOCK) != (ssize_t)sizeof s) return -1;
  *out = s & 0x7fffffffu;
  return 0;
}

/* Cache primitives reused from litmus7's litmus/libdir/_{aarch64,x86_64}/_cache.h
 * (CeCILL-B).  Whether `dc civac', cleaning to the point of coherence GH200
 * shares over C2C, reaches the cross-device path is unmeasured. */
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
  /* x86 has no store-intent hint litmus7 found, so prefetcht0 again. */
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
#else
#define HET_CPU_PRELOAD_LIVE 0
/* No cache primitives: het_cpu_preload says so rather than counting hints it never issued. */
static inline void het_cache_flush(void *p) { (void)p; }
static inline void het_cache_touch(void *p) { (void)p; }
static inline void het_cache_touch_store(void *p) { (void)p; }
#endif

int het_cpu_ncores(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return (n < 1) ? 1 : (int)n;
}

/* litmus7's write_one_affinity recipe (libdir/_linux_affinity.c).  Divergence:
 * a failed pin is counted and reported by main(), never errexit()ed mid-campaign. */
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

/* Preload runs BEFORE het_run_P<n>, never inside it: a cache hint changes
 * residency, not program order, and its "memory" clobber keeps it there. */
int het_cpu_preload_live(void) { return HET_CPU_PRELOAD_LIVE; }

uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t seed,
                         uint32_t who, uint64_t k0, int pct) {
#if HET_CPU_PRELOAD_LIVE == 0
  (void)vars; (void)nvars; (void)seed; (void)who; (void)k0; (void)pct;
  return 0u;                        /* inert; the driver reports it */
#else
  uint32_t n = 0u;
  for (int i = 0; i < nvars; i++) {
    /* [CudaLitmus runner.cu:106] */
    if ((int)(het_draw(seed, who, k0 + 2u*(uint64_t)i) % 100u) >= pct) continue;
    /* litmus7's RandomPL: flush / touch / touch-for-store, per variable */
    switch (het_draw(seed, who, k0 + 2u*(uint64_t)i + 1u) % 3u) {
    case 0:  het_cache_flush(vars[i]);       break;
    case 1:  het_cache_touch(vars[i]);       break;
    default: het_cache_touch_store(vars[i]); break;
    }
    n++;
  }
  return n;
#endif
}

/* Disjoint-scratchpad stress threads [Sorensen16 sec 1], not concurrent copies
 * of the test [Alglave11 sec 3], which do not compose with a persistent kernel.
 * `pattern' stays a RUNTIME field and the accesses volatile, or -O2 deletes them. */
void *het_cpu_stress(void *_a) {
  het_cpu_stress_args *a = (het_cpu_stress_args *)_a;
  het_cpu_affinity(a->core, a->tally);
  __atomic_fetch_add(&a->tally->stress_threads_realised, 1u, __ATOMIC_RELAXED);

  uint64_t rounds = 0, accesses = 0;
  uint32_t i = 0;
  /* Atomic every round: a hoisted plain load would never stop the thread. */
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t r = 0; r < a->nidx; r++) {
      /* Indirect through the shuffled index [Alglave11 sec 3], scratchpad ONLY;
         consecutive regions are one line apart [Sorensen16 sec 3.4]. */
      volatile uint64_t *l =
        a->scratch + (size_t)a->idx[r] * (size_t)a->words_per_region;
      switch (a->pattern) {
      case 0:  *l = i; *l = i + 1;        break;   /* st;st */
      case 1:  *l = i; (void)*l;          break;   /* st;ld */
      case 2:  (void)*l; *l = i;          break;   /* ld;st */
      default: (void)*l; (void)*l;        break;   /* ld;ld */
      }
      accesses += 2;
    }
    i++;
    rounds++;
  }
  /* One flush: an atomic bump per round would make the tally itself contended. */
  __atomic_fetch_add(&a->tally->stress_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->stress_accesses, accesses, __ATOMIC_RELAXED);
  return NULL;
}

/* A host noise thread stream-reads its own slice, the threads dividing the
 * buffer as [Fusco24 sec III-B.2]'s do; `buf' is volatile, no value escapes. */
void *het_cpu_noise(void *_a) {
  het_cpu_noise_args *a = (het_cpu_noise_args *)_a;
  het_cpu_affinity(a->core, a->tally);

  uint64_t rounds = 0, words = 0, i = 0;
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t c = 0; c < a->words_per_round; c++) {
      (void)a->buf[i];
      i += a->stride;
      if (i >= a->words) i = 0;    /* wrap: keep the whole working set streaming */
    }
    words += a->words_per_round;
    rounds++;
  }
  __atomic_fetch_add(&a->tally->cpu_noise_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->cpu_noise_words, words, __ATOMIC_RELAXED);
  return NULL;
}

/* `volatile', or the compiler deletes the loop and the buffer stays on the zero page. */
void het_cpu_first_touch(void *p, size_t bytes) {
  long ps = sysconf(_SC_PAGESIZE);
  if (ps < 1) ps = 4096;
  volatile unsigned char *b = (volatile unsigned char *)p;
  for (size_t i = 0; i < bytes; i += (size_t)ps) b[i] = 1u;
  if (bytes > 0) b[bytes - 1] = 1u;      /* the tail page, if bytes is not a multiple */
}

/* Fisher-Yates over het_draw at the run's own seed (seed0 + run). */
void het_cpu_shuffle(uint32_t *idx, uint32_t n, uint32_t seed) {
  uint64_t k = 0;
  for (uint32_t i = 0; i < n; i++) idx[i] = i;
  for (uint32_t i = n; i > 1; i--) {
    uint32_t j = het_draw(seed, HET_WHO_SHUFFLE, k++) % i;
    uint32_t t = idx[i - 1]; idx[i - 1] = idx[j]; idx[j] = t;
  }
}

#endif /* HET_CPU_STRESS_IMPL */

#ifdef __cplusplus
}
#endif
#endif /* HET_CPU_STRESS_H */
