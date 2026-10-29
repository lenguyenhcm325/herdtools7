/* Each mode is system-scope atomic only under a condition of CUDA Programming
   Guide 5.7.3, so every guard below is fatal and none falls back.
   https://docs.nvidia.com/cuda/archive/13.4.2/cuda-programming-guide/05-appendices/cuda-cpp-memory-model.html#atomicity */
static int _shared_pageable(void){
  int _p = 0;
  (void)cudaDeviceGetAttribute(&_p, cudaDevAttrPageableMemoryAccess, 0);
  return _p;
}

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
  /* 1 = hardware, 0 = software CPU/GPU coherence; both take the malloc branch
     and are NOT the same experiment.
     https://docs.nvidia.com/cuda/archive/13.4.2/cuda-programming-guide/02-basics/understanding-memory.html#unified-memory-paradigms */
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
            "HetLitmus FATAL: HET_ALLOC=\"%s\" is not a shared-memory mode: use "
            "auto, malloc, managed or pinned.\n", _v);
    exit(2);
  }
  /* Banner before guards: a fatal below is readable only with its attributes logged. */
  printf("HetLitmus: shared-mem mode=%s (HET_ALLOC=%s pageableMemoryAccess=%d "
         "usesHostPageTables=%d concurrentManagedAccess=%d)\n",
         _het_alloc_name(_mode), (_v != NULL && *_v != '\0') ? _v : "unset",
         _pg, _ht, _cma);
  fflush(stdout);
  if (_mode == HET_ALLOC_MALLOC && !_pg) {
    fprintf(stderr,
            "HetLitmus FATAL: HET_ALLOC=malloc but cudaDevAttrPageableMemoryAccess=0: "
            "the GPU cannot address a malloc() pointer.  Use HET_ALLOC=managed or "
            "pinned.\n");
    exit(2);
  }
  /* https://docs.nvidia.com/cuda/archive/13.4.2/cuda-programming-guide/04-special-topics/unified-memory.html#coherency-and-concurrency */
  if (_mode == HET_ALLOC_MANAGED && !_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: managed mode but cudaDevAttrConcurrentManagedAccess=0: "
            "the CPU may not touch a managed allocation while the kernel is live.  "
            "Use HET_ALLOC=pinned.\n");
    exit(2);
  }
  if (_mode == HET_ALLOC_PINNED &&
      !_het_dev_attr(cudaDevAttrHostNativeAtomicSupported)) {
    fprintf(stderr,
            "HetLitmus WARNING: HET_ALLOC=pinned with "
            "cudaDevAttrHostNativeAtomicSupported=0: on mapped memory a "
            "read-modify-write is NOT system-scope atomic (plain aligned loads and "
            "stores are).  The tested accesses are plain, but the rendezvous counter "
            "is a fetch_add shared with the CPU, monotone with its target NPART*(n+1): "
            "a single lost increment leaves it one short of EVERY later target, every "
            "later iteration is discarded at its cap, and the run is COLD-INVALID once "
            "the discards pass HET_RDV_MAX_DISCARD_PCT of N.\n");
  }
  return _mode;
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  int _m = _het_alloc_mode();
  *_pp = NULL;
  if (_m == HET_ALLOC_MALLOC) {
    *_pp = malloc(_bytes);
    if (*_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: malloc of %llu bytes for the shared vars failed.\n",
              (unsigned long long)_bytes);
      exit(2);
    }
  } else if (_m == HET_ALLOC_MANAGED) {
    cudaError_t _e = cudaMallocManaged(_pp, _bytes);
    if (_e != cudaSuccess || *_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: cudaMallocManaged of %llu bytes for the shared vars "
              "failed (%s).\n",
              (unsigned long long)_bytes, cudaGetErrorString(_e));
      exit(2);
    }
  } else {
    /* Free with cudaFreeHost, never free().
       https://docs.nvidia.com/cuda/archive/13.4.2/cuda-programming-guide/02-basics/understanding-memory.html#cudamallochost-and-cudahostalloc */
    cudaError_t _e = cudaHostAlloc(_pp, _bytes,
                                   cudaHostAllocMapped | cudaHostAllocPortable);
    if (_e != cudaSuccess || *_pp == NULL) {
      fprintf(stderr,
              "HetLitmus FATAL: cudaHostAlloc of %llu bytes for the shared vars "
              "failed (%s).\n",
              (unsigned long long)_bytes, cudaGetErrorString(_e));
      exit(2);
    }
  }
}
static void gd_free_shared(void* _p){
  int _m = _het_alloc_mode();
  if (_m == HET_ALLOC_MALLOC) { free(_p); }
  else if (_m == HET_ALLOC_MANAGED) { cudaFree(_p); }
  else { cudaFreeHost(_p); }
}
static void gd_alloc_dev(void** _pp, size_t _bytes, const char* _what){
  *_pp = NULL;
  cudaError_t _e = cudaMalloc(_pp, _bytes);
  if (_e != cudaSuccess || *_pp == NULL) {
    fprintf(stderr,
            "HetLitmus FATAL: cudaMalloc of %llu bytes for %s failed (%s).\n",
            (unsigned long long)_bytes, _what, cudaGetErrorString(_e));
    exit(2);
  }
}
