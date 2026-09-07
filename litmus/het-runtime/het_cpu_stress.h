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
#ifndef HET_CPU_STRESS_THREADS
#define HET_CPU_STRESS_THREADS (-1)  /* -1 = auto: every spare core (see main()) */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the CPU stress scratchpad.
                                          Plain host malloc, disjoint from every
                                          test location, so it needs neither GPU
                                          coherence nor device memory.          */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* spread m [Sorensen16]: distinct lines hit   */
#endif
#ifndef HET_CPU_WORDS_PER_REGION
#define HET_CPU_WORDS_PER_REGION 8  /* words per region: 8 x 8 B = 64 B, one cache
                                       line, so consecutive regions land on
                                       distinct lines.                          */
#endif
#ifndef HET_CPU_STRESS_PATTERN
#define HET_CPU_STRESS_PATTERN 0  /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld.  A
                                     stores-only sequence ranks lowest on most
                                     chips measured [Sorensen16 sec 3.3].  It
                                     reaches the stress thread as a RUNTIME
                                     field.                                     */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* % of iterations a test thread preloads its
                                     own test variables (litmus7's RandomPL).   */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* pin threads to cores (sched_setaffinity)    */
#endif
#ifndef HET_CPU_FIRST_CORE
#define HET_CPU_FIRST_CORE 0      /* first core of the pinning layout: test, noise
                                     and stress threads are pinned upward from it */
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS, the driver
                                     and the GPU-launch thread.  Grace has no
                                     SMT, so litmus7's SMT knobs are inert there;
                                     on the x86 MI300A host (24c/48t over 3 CCDs)
                                     they are live.                             */
#endif

/* Half 2 knobs -- interconnect.  HET_PLACE is consumed in the .cu / .hip (the
 * node resolution is vendor API; the bind is het_place_shared below, host C);
 * the noise knobs are consumed on both sides. */
#ifndef HET_PLACE
#define HET_PLACE 0               /* shared-var placement: 0 = first touch
                                     decides, 1 = the GPU memory's NUMA node,
                                     2 = the host node nearest the device.  Do
                                     NOT promote a non-zero default without
                                     hardware evidence. */
#endif
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* per noise buffer, matching [Fusco24]'s 8 GB.
                                     It must EXCEED the last-level cache on the
                                     path or the reads hit cache and cross
                                     nothing -- see HET_LLC_MB.                 */
#endif
#ifndef HET_CPU_NOISE_THREADS
#define HET_CPU_NOISE_THREADS 1   /* the host half: CPU threads, each streaming
                                     its own slice of a device-homed buffer.
                                     hetlitmus/docs/00-environment-design.md 3.6 */
#endif
#ifndef HET_GPU_NOISE_BLOCKS
#define HET_GPU_NOISE_BLOCKS 8    /* the device half: extra blocks of the
                                     PERSISTENT grid stream-reading a host-homed
                                     buffer, never a second __global__ whose ops
                                     would land in the flat GPU op stream.      */
#endif
#ifndef HET_NOISE_WORDS_PER_ROUND
#define HET_NOISE_WORDS_PER_ROUND 4096  /* words streamed per round before the stop
                                           flag is re-tested; it bounds how long the
                                           noise can outlive the test.            */
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

#if (HET_CPU_STRESS_PATTERN) < 0 || (HET_CPU_STRESS_PATTERN) > 3
#error "HET_CPU_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_PLACE) < 0 || (HET_PLACE) > 2
#error "HET_PLACE must be 0 (first touch), 1 (the GPU memory's NUMA node) or 2 (the host node nearest the device)"
#endif
#if (HET_CPU_SPREAD) < 1
#error "HET_CPU_SPREAD must be >= 1 (the spread m)"
#endif
#if (HET_CPU_WORDS_PER_REGION) < 1
#error "HET_CPU_WORDS_PER_REGION must be >= 1"
#endif
/* Stride 0 never advances the index (one location re-read out of L1 for ever)
   and zero words per round never enter the inner loop: either is a no-op noise
   stream whose round counters still look healthy, so refuse to compile. */
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
#error "HET_CPU_NOISE_THREADS above 1024 overflows the driver's stack arrays"
#endif
/* A slice shorter than one round's words re-reads its few words for ever. */
#if (HET_CPU_NOISE_THREADS) > 0 && \
    (HET_NOISE_MB) * 131072 < (HET_CPU_NOISE_THREADS) * (HET_NOISE_WORDS_PER_ROUND)
#error "HET_CPU_NOISE_THREADS slices HET_NOISE_MB below one HET_NOISE_WORDS_PER_ROUND per thread"
#endif
#if (HET_LLC_MB) < 1
#error "HET_LLC_MB must be >= 1 (0 silences the below-cache warning for every run)"
#endif

/* Liveness tally -- the CPU twin of het_stress.h's.  None of this layer enters
 * the tested op stream, so these counters are the ONLY run-time evidence that it
 * ran: a zero round/op count means the mechanism never ran, a nonzero failure
 * count that a pin or a placement was refused. */
typedef struct het_cpu_tally {
  uint64_t stress_rounds;     /* stress loop iterations, summed over threads     */
  uint64_t stress_accesses;   /* scratchpad accesses issued by the stress threads*/
  uint64_t preload_ops;       /* preload cache hints actually issued             */
  uint64_t cpu_noise_rounds;  /* host noise threads: streaming rounds, summed    */
  uint64_t cpu_noise_words;   /* host noise threads: words read, summed          */
  uint32_t stress_threads_realised; /* stress threads that actually entered their loop */
  uint32_t aff_failures;      /* sched_setaffinity failures -- never silent      */
  uint32_t place_failures;    /* placement failures (filled by the render)      */
  uint32_t preload_inert;     /* 1 => this host has NO cache primitives at all   */
} het_cpu_tally;

/* Stress-thread arguments.  Every behavioural field is a runtime value
   (het_cpu_stress). */
typedef struct het_cpu_stress_args {
  volatile uint64_t *scratch; /* DISJOINT host scratchpad.  Never a test var.    */
  const uint32_t *idx;        /* shuffled region indices (the indirection)       */
  uint32_t nidx;              /* spread m -- how many regions per round          */
  uint32_t words_per_region;  /* region width in words                           */
  uint32_t pattern;           /* sigma, 0..3.  Runtime -- see het_cpu_stress.    */
  int core;                   /* core to pin to, or -1 for unpinned              */
  int *go;                    /* the stop flag; set BEFORE the stress threads
                                 are spawned                                     */
  het_cpu_tally *tally;
} het_cpu_stress_args;

/* Host-side noise arguments.  `buf' is the OTHER unit's memory: this thread's
   slice of the buffer, `words' long, disjoint from every other thread's. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* device-homed: every read crosses the link    */
  uint64_t words;
  uint32_t words_per_round;   /* words read before the stop flag is re-tested    */
  uint32_t stride;
  int core;
  int *go;
  het_cpu_tally *tally;
} het_cpu_noise_args;

/* The stress schedule.  One draw, host and device: splitmix64 [Vigna15]
   evaluated at index k -- draw k of the stream owned by (seed, who) is
   mix(x0 + k*gamma) with x0 = seed<<32 | who, so no stream is ever advanced and
   the value is the same wherever it is computed.
   Design: hetlitmus/docs/00-environment-design.md sec 3.3. */
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
/* Every (who, k) is ONE decision, drawn by whoever the decision belongs to; a
   grid-wide decision is drawn by every block and comes out the same.  The ids
   are pairwise distinct: a GPU thread is its global thread id, which an
   occupancy-bounded grid keeps below 2^31, and these lie above it. */
#define HET_WHO_CPU(c)   (0x80000000u | (uint32_t)(c))
#define HET_WHO_GRID     0xFFFFFFFDu
#define HET_WHO_SCRATCH  0xFFFFFFFEu
#define HET_WHO_SHUFFLE  0xFFFFFFFFu
/* k, per participant: a GPU test lane draws 2*n and 2*n+1 at iteration n (its
   pre-stress toggle, its release jitter), the grid its mem-stress toggle at the
   iteration index, a CPU test thread 1+2*nvars per iteration (jitter, then a
   toggle and a kind per test variable), and each id above counts its own draws
   from 0. */

/* API.  Bodies are compiled ONLY into <test>_cpu.c (HET_CPU_STRESS_IMPL). */
int      het_cpu_affinity(int core, het_cpu_tally *t);  /* 0 = pinned, -1 = failed */
int      het_cpu_ncores(void);
/* Returns the hints issued, so the caller accumulates locally and flushes once:
   an atomic bump per hint would put scaffolding contention inside the tested
   loop, the one place it must NOT be. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t seed,
                         uint32_t who, uint64_t k0, int pct);
/* Exposes HET_CPU_PRELOAD_LIVE to the .cu driver, which cannot read the macro
   (defined only under HET_CPU_STRESS_IMPL).  The driver uses it so a host with
   no cache primitives does not request a preload that can only no-op, which
   would disqualify the run and turn every null cold. */
int      het_cpu_preload_live(void);
/* The seed base of a run that pins no HET_SEED: 0 = drawn, -1 = none available,
   which the caller must report rather than pass off as a fresh draw. */
int      het_seed_entropy(uint32_t *out);
void    *het_cpu_stress(void *a);  /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the host half of the noise pair*/
/* First touch, one write per page.  Linux maps every untouched anonymous page to
   one shared read-only zero page, so an unwritten 8 GB buffer streams one cache
   line and crosses NOTHING while the round counters look healthy.  It also
   decides the page's NUMA home on GH200, so the caller advises the preferred
   location before this call and prefetches after it. */
void     het_cpu_first_touch(void *p, size_t bytes);
/* Host-side; the driver hands it the run's seed, so the permutation is a
   function of that seed (hetlitmus/docs/00-environment-design.md sec 3.3). */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n, uint32_t seed);
/* HET_PLACE's host half.  The render resolves the two candidate nodes with its
   vendor API; the choice, the bind, the fault-in and the read-back are Linux
   (hetlitmus/docs/00-environment-design.md sec 3.6). */
int      het_numa_online_nodes(void);  /* /sys/devices/system/node/online; 0 = unreadable */
int      het_numa_node_of_pci(const char *bdf);  /* /sys/bus/pci/devices/<bdf>/numa_node; -1 = unknown */
/* The node HET_PLACE=where selects, or -1 with the reason on stderr: the two
   candidates must be distinct online nodes, else binding separates nothing. */
int      het_place_target(int where, int node_gpu, int node_host, int nodes_online);
/* Bind [p, p+bytes) to the node het_place_target picks, fault the pages in and
   read the home back.  0 = placed; -1 = refused or pages left off node, the
   reason on stderr; the caller counts it. */
int      het_place_shared(void *p, size_t bytes, int where, int node_gpu, int node_host);

#ifdef HET_CPU_STRESS_IMPL
/* Implementation. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <unistd.h>
#include <sys/random.h>
#include <sys/syscall.h>

/* 31 bits, so _seed0 + _run cannot wrap into another invocation's seed range;
   hetlitmus/campaign.py draws its own base at the same width.  Why the flag,
   and why not getentropy: hetlitmus/docs/00-environment-design.md sec 3.3. */
int het_seed_entropy(uint32_t *out) {
  uint32_t s;
  if (getrandom(&s, sizeof s, GRND_NONBLOCK) != (ssize_t)sizeof s) return -1;
  *out = s & 0x7fffffffu;
  return 0;
}

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

uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t seed,
                         uint32_t who, uint64_t k0, int pct) {
#if HET_CPU_PRELOAD_LIVE == 0
  (void)vars; (void)nvars; (void)seed; (void)who; (void)k0; (void)pct;
  return 0u;                        /* inert -- the driver reports it, see above */
#else
  uint32_t n = 0u;
  for (int i = 0; i < nvars; i++) {
    /* [CudaLitmus runner.cu:106] */
    if ((int)(het_draw(seed, who, k0 + 2u*(uint64_t)i) % 100u) >= pct) continue;
    /* litmus7's RandomPL: flush / touch / touch-for-store, drawn per variable
       per iteration. */
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

/* The disjoint-scratchpad stress thread.  Divergence from litmus7: test
 * repetition is ported as disjoint-scratchpad stress threads [Sorensen16 sec 1],
 * not as concurrent copies of the whole test [Alglave11 sec 3], which does not
 * compose with a persistent GPU kernel.  `pattern' must stay a RUNTIME field and
 * the accesses `volatile', or -O2 folds the switch and deletes the reads. */
void *het_cpu_stress(void *_a) {
  het_cpu_stress_args *a = (het_cpu_stress_args *)_a;
  het_cpu_affinity(a->core, a->tally);
  __atomic_fetch_add(&a->tally->stress_threads_realised, 1u, __ATOMIC_RELAXED);

  uint64_t rounds = 0, accesses = 0;
  uint32_t i = 0;
  /* The stop flag is read atomically every round: a plain load could be hoisted
     out of the loop, and a stress thread that never re-reads its flag never
     stops. */
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t r = 0; r < a->nidx; r++) {
      /* Indirect access: the region is reached through a shuffled index array
         rather than by walking r [Alglave11 sec 3], and ONLY on the scratchpad --
         the test variables stay direct.  Consecutive regions are
         `words_per_region' words apart, so they land on distinct lines
         [Sorensen16 sec 3.4]. */
      volatile uint64_t *l =
        a->scratch + (size_t)a->idx[r] * (size_t)a->words_per_region;
      switch (a->pattern) {          /* sigma -- runtime, see above */
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
  __atomic_fetch_add(&a->tally->stress_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->stress_accesses, accesses, __ATOMIC_RELAXED);
  return NULL;
}

/* A host noise thread: [Fusco24 sec III-E.1]'s noise kernel over its own slice
 * of the buffer, the threads dividing it as [Fusco24 sec III-B.2]'s do --
 * stream-read memory homed on the other unit, so every read that misses cache
 * crosses the interconnect.  The buffer is disjoint from every test location.
 * `buf' is volatile: the stream is issued with no value escaping. */
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

/* The shuffle behind the indirection: Fisher-Yates over het_draw, at the run's
   own seed (seed0 + run). */
void het_cpu_shuffle(uint32_t *idx, uint32_t n, uint32_t seed) {
  uint64_t k = 0;
  for (uint32_t i = 0; i < n; i++) idx[i] = i;
  for (uint32_t i = n; i > 1; i--) {
    uint32_t j = het_draw(seed, HET_WHO_SHUFFLE, k++) % i;
    uint32_t t = idx[i - 1]; idx[i - 1] = idx[j]; idx[j] = t;
  }
}

#ifndef MPOL_BIND
#define MPOL_BIND 2               /* <linux/mempolicy.h>: the strict bind policy */
#endif
#ifndef MPOL_MF_MOVE
#define MPOL_MF_MOVE (1 << 1)     /* relocate pages that are already resident */
#endif
#define HET_NODEMASK_LONGS 8      /* 512 NUMA nodes -- more than any GH200/GB200 */

/* The kernel's cpulist format: "0", "0-3", "0,2-3". */
int het_numa_online_nodes(void) {
  FILE *f = fopen("/sys/devices/system/node/online", "r");
  char buf[256];
  int n = 0;
  if (f == NULL) return 0;
  if (fgets(buf, sizeof buf, f) == NULL) { fclose(f); return 0; }
  fclose(f);
  for (char *s = buf; *s != '\0'; ) {
    char *end;
    long lo = strtol(s, &end, 10), hi = lo;
    if (end == s) break;
    s = end;
    if (*s == '-') { hi = strtol(s + 1, &end, 10); if (end == s + 1) break; s = end; }
    if (hi >= lo) n += (int)(hi - lo + 1);
    if (*s == ',') s++; else break;
  }
  return n;
}

/* sysfs names the function in lower-case hex; the BDF a vendor API hands back
   need not be. */
int het_numa_node_of_pci(const char *bdf) {
  char id[32], path[80];
  size_t i;
  FILE *f;
  int node = -1;
  for (i = 0; i + 1 < sizeof id && bdf[i] != '\0'; i++)
    id[i] = (bdf[i] >= 'A' && bdf[i] <= 'F') ? (char)(bdf[i] - 'A' + 'a') : bdf[i];
  id[i] = '\0';
  if (i == 0) return -1;
  snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/numa_node", id);
  f = fopen(path, "r");
  if (f == NULL) return -1;
  if (fscanf(f, "%d", &node) != 1) node = -1;
  fclose(f);
  return node;
}

int het_place_target(int where, int node_gpu, int node_host, int nodes_online) {
  int node = (where == 2) ? node_host : node_gpu;
  if (node < 0 || node >= (int)(HET_NODEMASK_LONGS * 8 * sizeof(unsigned long))) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_PLACE=%d but this device exposes no target NUMA "
            "node -- the placement lever is INERT, this run is NOT placement-"
            "stressed.\n", where);
    return -1;
  }
  if (nodes_online < 2) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_PLACE=%d but %d NUMA node(s) are online -- the "
            "placement lever is INERT, this run is NOT placement-stressed.\n",
            where, nodes_online);
    return -1;
  }
  if (node_gpu == node_host) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_PLACE=%d but the GPU memory's node and the host "
            "node nearest the device are both node %d -- the placement lever is "
            "INERT, this run is NOT placement-stressed.\n", where, node);
    return -1;
  }
  return node;
}

/* Read the pages' real home back: move_pages with a NULL node array queries, it
   never relocates.  Returns pages NOT on _node -- all of them if the query fails. */
static long _het_pages_off_node(void* _p, size_t _np, long _ps, int _node){
  void** _pg = (void**)malloc(_np * sizeof *_pg);
  int*   _st = (int*)  malloc(_np * sizeof *_st);
  if (_pg == NULL || _st == NULL) { free(_pg); free(_st); return (long)_np; }
  for (size_t _i = 0; _i < _np; _i++) _pg[_i] = (char*)_p + _i * (size_t)_ps;
  long _off;
  if (syscall(SYS_move_pages, 0, _np, _pg, NULL, _st, 0) != 0) _off = (long)_np;
  else { _off = 0; for (size_t _i = 0; _i < _np; _i++) if (_st[_i] != _node) _off++; }
  free(_pg); free(_st);
  return _off;
}

int het_place_shared(void *p, size_t bytes, int where, int node_gpu, int node_host) {
  if (where == 0) return 0;
  int _node = het_place_target(where, node_gpu, node_host, het_numa_online_nodes());
  if (_node < 0) return -1;
  long _ps = sysconf(_SC_PAGESIZE); if (_ps < 1) _ps = 4096;
  size_t _np = (bytes + (size_t)_ps - 1) / (size_t)_ps;
  size_t _bits = 8 * sizeof(unsigned long);
  unsigned long _mask[HET_NODEMASK_LONGS];
  memset(_mask, 0, sizeof _mask);
  _mask[(size_t)_node / _bits] |= 1UL << ((size_t)_node % _bits);
  long _rc = syscall(SYS_mbind, p, _np * (size_t)_ps, MPOL_BIND,
                     _mask, (unsigned long)(8 * sizeof _mask), MPOL_MF_MOVE);
  het_cpu_first_touch(p, bytes);            /* fault the pages so they have a home */
  long _off = _het_pages_off_node(p, _np, _ps, _node);
  if (_rc != 0 || _off > 0) {               /* the bind or a page was refused */
    fprintf(stderr,
            "HetLitmus WARNING: HET_PLACE=%d left %ld of %zu page(s) off node %d "
            "-- this run is NOT placement-stressed.\n", where, _off, _np, _node);
    return -1;
  }
  return 0;
}

#endif /* HET_CPU_STRESS_IMPL */

#ifdef __cplusplus
}
#endif
#endif /* HET_CPU_STRESS_H */
