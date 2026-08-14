/* Shared litmus vars + rendezvous barrier.  THE ALLOCATOR SELECTS THE
   PROPERTY UNDER TEST: it decides whether the two sides touch one physical
   line over the machine's real coherence protocol, so it is correctness, not
   tuning.  Design: hetlitmus/docs/00-environment-design.md sec 3.2.

   HET_ALLOC picks the mode, resolved once per process; the free must match it:

     auto     pageableMemoryAccess ? malloc : managed  (default; unset = auto)
     malloc   system malloc()       -- GH200/Spark: ATS gives CPU and GPU one
                                      page table, so both touch the same cache
                                      line in place over NVLink-C2C via
                                      hardware CHI coherence.  This is the mode
                                      [Bagchi26] used.
     managed  cudaMallocManaged     -- dev-box/CI fallback only; on GH200 it
                                      2 MB-page-migrates under the concurrent
                                      race and masks the weak behaviour.
     pinned   cudaHostAlloc(Mapped) -- for a device that can do neither.

   The guards below are fatal, with deliberately no fallback to auto: each mode
   is a system-scope atomic only under a condition the memory model states
   outright -- system memory needs pageableMemoryAccess, managed needs
   concurrentManagedAccess, mapped needs hostNativeAtomicSupported, with a
   separate allowance for plain naturally-aligned 1/2/4/8/16-byte loads and
   stores on mapped memory [CudaGuide "Atomicity"].  Every tested access here,
   and the barrier, is such an atomic, so an unsupported mode is not slower or
   less faithful but undefined, and the histogram it produces means nothing.
   The banner also reports usesHostPageTables, which is the runtime's own
   hardware-vs-software coherence indicator [CudaGuide "Unified Memory
   Paradigms"]: it separates GH200 ATS (1) from an x86 box on HMM (0), both of
   which take the malloc branch and are not the same experiment.

   This knob moves this object class only.  gd_alloc_noise keeps its own
   dispatch and its own matching free, so forcing a mode here stays a contrast
   experiment about the tested memory instead of also disarming the
   interconnect stressor.  The read buffers are not routed here -- device
   memory, off the race path. */
static int _shared_pageable(void){
  int _p = 0;
  (void)cudaDeviceGetAttribute(&_p, cudaDevAttrPageableMemoryAccess, 0);
  return _p;
}
/* The three shared-memory modes, resolved ONCE.  The cache is not an
   optimisation: it is what guarantees gd_free_shared frees with the allocator
   that actually ran.  Re-querying the device could answer differently (a forced
   mode, a second device) and free a malloc'd pointer with cudaFree -- undefined
   behaviour that need not fault on the managed dev-box path and would first
   surface on GH200.  One resolution, one banner, one free rule.  Resolved on the
   first gd_alloc_shared, which main calls before creating any thread, so the
   lazy static needs no lock. */
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
            "auto (or unset), malloc, managed or pinned.  There is deliberately NO "
            "fallback to auto: a typo that silently selected a different allocator "
            "would silently select a different experiment.\n", _v);
    exit(2);
  }
  /* The banner precedes the guards ON PURPOSE -- a FATAL below is only actionable
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
            "malloc() pointer at all, and a system-scope atomic on one is not "
            "atomic.  Use HET_ALLOC=managed (needs concurrentManagedAccess=1) or "
            "HET_ALLOC=pinned.\n");
    exit(2);
  }
  if (_mode == HET_ALLOC_MANAGED && !_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: this run would use managed memory, but the device "
            "reports cudaDevAttrConcurrentManagedAccess=0: the CPU may not touch a "
            "managed allocation while the kernel is live (the access faults), and a "
            "system-scope atomic on it is not atomic.  EVERY heterogeneous test here "
            "does exactly that, so there is nothing to salvage -- rerun with "
            "HET_ALLOC=pinned, or on a device that supports concurrent managed "
            "access.\n");
    exit(2);
  }
  if (_mode == HET_ALLOC_PINNED &&
      !_het_dev_attr(cudaDevAttrHostNativeAtomicSupported)) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_ALLOC=pinned on a device with "
            "cudaDevAttrHostNativeAtomicSupported=0.  On mapped memory only plain "
            "naturally-aligned loads/stores of 1/2/4/8/16 bytes are system-scope "
            "atomic; a read-modify-write is NOT.  The tested accesses are plain "
            "loads and stores and stand, but the rendezvous BARRIER is a fetch_add "
            "shared with the CPU, so increments can be lost and the run can hang at "
            "the barrier.  Use a timeout, and do not read this mode as evidence "
            "about hardware atomicity.\n");
  }
  return _mode;
}
/* A placement request the selected mode cannot honour is announced, never
   swallowed -- same rule as the refused cudaMemAdvise below. */
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
/* PLACEMENT -- the first of the two interconnect-stress levers.  Pin the shared
   pages away from the participant that will read them, so the tested accesses
   cross NVLink-C2C instead of hitting a local copy.
   (hetlitmus/docs/00-environment-design.md sec 3.6.)

   Placement alone does NOT stress the interconnect, and shipping it alone would
   misreport a run as C2C-stressed: Hopper's L2 caches peer HBM as well as local
   HBM, so a remote-pinned line that stays L2-resident crosses nothing
   [Fusco24 sec III-E.1].  Sustained C2C traffic comes from the noise pair below
   and from the test's own coherence race; placement tunes the home and the
   first-touch latency.  Ship both.

   SetPreferredLocation on its own can be undone by the driver's access counters,
   which migrate a hot page local and silence exactly the traffic this creates, so
   SetAccessedBy is set on both participants to hold the mapping.  Whether that
   suffices on a given driver is a hardware question, so the pin is never assumed
   to have held -- hence the failure counter below.

   HET_PLACE defaults to 0 (first-touch): that is [Bagchi26]'s baseline, and the
   net effect of pinning is confounded -- it widens the window but slows the loop,
   and sightings = yield x rate is unmeasured.  Do not promote a non-zero default
   without hardware evidence.

   A refused cudaMemAdvise is counted, never swallowed: a placement knob that
   reports "remote" while the pages sat where first touch left them is an inert
   mechanism claiming to be live.  The counter is declared by the SHARED driver
   template rather than here, because both renders report it and only the
   mechanism that bumps it is CUDA-specific. */
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
            "did NOT place these pages; they are wherever first touch put them, so "
            "the tested accesses may never cross @LINK_OBJ@.  This run is NOT "
            "placement-stressed.\n",
            cudaGetErrorString(_e1), cudaGetErrorString(_e2), cudaGetErrorString(_e3),
            _where);
  }
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  int _m = _het_alloc_mode();
  if (_m == HET_ALLOC_MALLOC) {
    *_pp = malloc(_bytes);   /* GH200: ATS, in-place cache-line CHI coherence */
    _het_place(*_pp, _bytes, HET_PLACE);   /* the placement lever -- see above */
  } else if (_m == HET_ALLOC_MANAGED) {
    cudaMallocManaged(_pp, _bytes);   /* dev-box / CI fallback only */
    /* No placement here BY DESIGN: without pageable-memory access there is no ATS,
       no C2C and no placement lever at all -- managed memory just page-migrates over
       PCIe.  Advising it would be a no-op that looked like a knob. */
    _het_place_inert(_m);
  } else {
    /* Mapped page-locked host memory.  cudaHostAllocMapped puts it in the CUDA
       address space and the pointer the kernel uses IS the host pointer
       [CudaGuide "cudaMallocHost and cudaHostAlloc"], so there is no
       cudaHostGetDevicePointer and no second pointer for the driver to thread
       through.  Portable so the mapping survives a second context.  Freed with
       cudaFreeHost, never free(). */
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
