/* Shared litmus vars + rendezvous barrier.  The allocator selects the property
   under test -- whether the two sides touch one physical line over the machine's
   real coherence protocol -- so it is correctness, not tuning; the per-target
   choice is hetlitmus/docs/00-environment-design.md sec 3.2.
   HET_ALLOC (auto | malloc | managed | pinned; unset = auto) picks the mode once
   per process, and gd_free_shared must match it.  Each mode is a system-scope
   atomic ONLY under a condition of [CudaGuide "Atomicity"], which is why the
   guards below are fatal and none of them falls back to auto.
   This knob moves this object class only: gd_alloc_noise keeps its own dispatch
   and its own free, and the read buffers are device memory, off the race path. */
static int _shared_pageable(void){
  int _p = 0;
  (void)cudaDeviceGetAttribute(&_p, cudaDevAttrPageableMemoryAccess, 0);
  return _p;
}
/* Resolved ONCE and cached, because gd_free_shared must free with the allocator
   that actually ran: a re-query could answer differently (a forced mode, a second
   device) and hand a malloc'd pointer to cudaFree.  Resolution happens on the
   first gd_alloc_shared, which main calls before creating any thread, so the lazy
   static needs no lock. */
#define HET_ALLOC_MALLOC  0
#define HET_ALLOC_MANAGED 1
#define HET_ALLOC_PINNED  2
static int _het_dev_attr(cudaDeviceAttr _a){
  int _v = 0;
  (void)cudaDeviceGetAttribute(&_v, _a, 0);
  return _v;
}
static const char* _het_alloc_name(int _m){
  return (_m == HET_ALLOC_MALLOC) ? "malloc"
       : (_m == HET_ALLOC_MANAGED) ? "managed" : "pinned";
}
static int _het_alloc_mode(void){
  static int _mode = -1;
  const char *_v;
  int _pg, _ht, _cma;
  if (_mode >= 0) return _mode;
  _v = getenv("HET_ALLOC");
  _pg  = _shared_pageable();
  /* hardware (1) vs software (0) CPU/GPU coherence: both take the malloc branch
     and are NOT the same experiment [CudaGuide "Unified Memory Paradigms"] */
  _ht  = _het_dev_attr(cudaDevAttrPageableMemoryAccessUsesHostPageTables);
  _cma = _het_dev_attr(cudaDevAttrConcurrentManagedAccess);
  if (_v == NULL || *_v == '\0' || strcmp(_v, "auto") == 0) {
    _mode = _pg ? HET_ALLOC_MALLOC : HET_ALLOC_MANAGED;
  } else if (strcmp(_v, "malloc") == 0) {
    _mode = HET_ALLOC_MALLOC;
  } else if (strcmp(_v, "managed") == 0) {
    _mode = HET_ALLOC_MANAGED;
  } else if (strcmp(_v, "pinned") == 0) {
    _mode = HET_ALLOC_PINNED;
  } else {
    fprintf(stderr,
            "HetLitmus FATAL: HET_ALLOC=\"%s\" is not a shared-memory mode.  Use "
            "auto (or unset), malloc, managed or pinned.\n", _v);
    exit(2);
  }
  /* The banner precedes the guards on purpose: a fatal below is actionable only
     if the attributes that caused it are already in the log. */
  printf("HetLitmus: shared-mem mode=%s (HET_ALLOC=%s pageableMemoryAccess=%d "
         "usesHostPageTables=%d concurrentManagedAccess=%d)\n",
         _het_alloc_name(_mode), (_v != NULL && *_v != '\0') ? _v : "unset",
         _pg, _ht, _cma);
  fflush(stdout);
  if (_mode == HET_ALLOC_MALLOC && !_pg) {
    fprintf(stderr,
            "HetLitmus FATAL: HET_ALLOC=malloc but this device reports "
            "cudaDevAttrPageableMemoryAccess=0, so it cannot address a system "
            "malloc() pointer.  Use HET_ALLOC=managed (needs "
            "concurrentManagedAccess=1) or HET_ALLOC=pinned.\n");
    exit(2);
  }
  if (_mode == HET_ALLOC_MANAGED && !_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: this run would use managed memory, but the device "
            "reports cudaDevAttrConcurrentManagedAccess=0: the CPU may not touch a "
            "managed allocation while the kernel is live (the access faults).  "
            "Rerun with HET_ALLOC=pinned, or on a device that supports concurrent "
            "managed access.\n");
    exit(2);
  }
  if (_mode == HET_ALLOC_PINNED &&
      !_het_dev_attr(cudaDevAttrHostNativeAtomicSupported)) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_ALLOC=pinned on a device with "
            "cudaDevAttrHostNativeAtomicSupported=0.  On mapped memory only plain "
            "naturally-aligned loads/stores of 1/2/4/8/16 bytes are system-scope "
            "atomic; a read-modify-write is NOT.  The tested accesses are plain "
            "loads and stores, but the rendezvous counter is a fetch_add shared "
            "with the CPU, and it is monotone with iteration n's target "
            "NPART*(n+1): a single lost increment leaves it one short of EVERY "
            "later target, so that iteration and every iteration after it is "
            "discarded at its cap, and the run is COLD-INVALID once the discards "
            "pass HET_RDV_MAX_DISCARD_PCT of N.\n");
  }
  return _mode;
}
/* A placement request the selected mode cannot honour is announced, never
   swallowed. */
static void _het_place_inert(int _m){
  static int _said = 0;
  if (HET_PLACE == 0 || _said) return;
  _said = 1;
  fprintf(stderr,
          "HetLitmus WARNING: HET_PLACE=%d but the shared allocator is in %s mode, "
          "where cudaMemAdvise has no page to advise -- the placement lever is INERT "
          "for this run and the shared pages are wherever the runtime put them.\n",
          (int)HET_PLACE, _het_alloc_name(_m));
}
/* Placement -- an interconnect-stress lever: pin the shared pages away from the
   participant that reads them so the tested accesses cross the host-device link.
   Default 0 = first-touch.  A remote-pinned line that stays L2-resident crosses
   nothing [Fusco24 sec III-E.1], so placement ships with the noise pair and a
   refused advise is counted.  hetlitmus/docs/00-environment-design.md sec 3.6. */
static void _het_place(void* _p, size_t _bytes, int _where){
  if (_where == 0) return;                  /* first-touch: nothing to advise */
  int _dev = 0;
  int _home = (_where == 1) ? _dev : cudaCpuDeviceId;   /* 1 = HBM, 2 = DDR */
  cudaError_t _e1 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetPreferredLocation, _home);
  cudaError_t _e2 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetAccessedBy, _dev);
  cudaError_t _e3 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetAccessedBy, cudaCpuDeviceId);
  if (_e1 != cudaSuccess || _e2 != cudaSuccess || _e3 != cudaSuccess) {
    _het_place_failures++;
    fprintf(stderr,
            "HetLitmus WARNING: cudaMemAdvise REFUSED (%s / %s / %s) -- HET_PLACE=%d "
            "placed nothing; these pages are wherever first touch put them, so "
            "this run is NOT placement-stressed.\n",
            cudaGetErrorString(_e1), cudaGetErrorString(_e2), cudaGetErrorString(_e3),
            _where);
  }
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  int _m = _het_alloc_mode();
  *_pp = NULL;   /* the checks below must not read the caller's uninitialised pointer */
  if (_m == HET_ALLOC_MALLOC) {
    *_pp = malloc(_bytes);   /* GH200: ATS, in-place cache-line CHI coherence */
    if (*_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: malloc of %llu bytes failed -- HET_ALLOC=malloc "
              "has no shared memory to test on.\n",
              (unsigned long long)_bytes);
      exit(2);
    }
    _het_place(*_pp, _bytes, HET_PLACE);
  } else if (_m == HET_ALLOC_MANAGED) {
    cudaError_t _e = cudaMallocManaged(_pp, _bytes);   /* machinery fallback only */
    if (_e != cudaSuccess || *_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: cudaMallocManaged of %llu bytes failed (%s) -- "
              "HET_ALLOC=managed has no shared memory to test on.\n",
              (unsigned long long)_bytes, cudaGetErrorString(_e));
      exit(2);
    }
    /* No placement here: without pageable-memory access there is no ATS and no
       placement lever, so advising would be a no-op that looked like a knob. */
    _het_place_inert(_m);
  } else {
    /* Mapped page-locked host memory: the pointer the kernel uses is the host
       pointer itself [CudaGuide "cudaMallocHost and cudaHostAlloc"], so there is
       no second pointer to thread through.  Portable, so the mapping survives a
       second context; freed with cudaFreeHost, NEVER free(). */
    cudaError_t _e = cudaHostAlloc(_pp, _bytes,
                                   cudaHostAllocMapped | cudaHostAllocPortable);
    if (_e != cudaSuccess || *_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: cudaHostAlloc of %llu bytes failed (%s) -- "
              "HET_ALLOC=pinned has no shared memory to test on.\n",
              (unsigned long long)_bytes, cudaGetErrorString(_e));
      exit(2);
    }
    _het_place_inert(_m);
  }
}
static void gd_free_shared(void* _p){
  /* Cached mode, NOT a re-query: the free must match the allocator that ran. */
  int _m = _het_alloc_mode();
  if (_m == HET_ALLOC_MALLOC) { free(_p); }
  else if (_m == HET_ALLOC_MANAGED) { cudaFree(_p); }
  else { cudaFreeHost(_p); }
}
/* Device memory the harness keeps to itself (read buffers, scratchpad, tally):
   a NULL here would reach the launch, so a refused allocation ends the run. */
static void gd_alloc_dev(void** _pp, size_t _bytes, const char* _what){
  *_pp = NULL;
  cudaError_t _e = cudaMalloc(_pp, _bytes);
  if (_e != cudaSuccess || *_pp == NULL) {
    fprintf(stderr,
            "HetLitmus FATAL: cudaMalloc of %llu bytes for %s failed (%s) -- "
            "the harness has no device memory for it.\n",
            (unsigned long long)_bytes, _what, cudaGetErrorString(_e));
    exit(2);
  }
}
