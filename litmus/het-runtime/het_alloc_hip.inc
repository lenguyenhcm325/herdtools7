/* Shared litmus vars + barrier: fine-grained hipMallocManaged, the default
   [HipRuntimeApi "hipMemAdviseSetCoarseGrain"] and the one coherence mode usable
   for system-scope CPU<->GPU synchronisation while the kernel is live.  Which
   allocator runs decides what property the harness tests, so it is correctness,
   not tuning (hetlitmus/docs/00-environment-design.md "Allocation").  This
   render implements ONE mode and refuses every other spelling of HET_ALLOC
   rather than substituting for it; the read buffers are device memory
   (hipMalloc). */
#define HET_HIP_ALLOC_MANAGED 1
static int _het_hip_attr(hipDeviceAttribute_t _a){
  int _v = 0;
  (void)hipDeviceGetAttribute(&_v, _a, 0);
  return _v;
}
/* APU (MI300A) vs discrete (MI300X): both report gfx942, and only
   hipDeviceAttributeIntegrated separates them [HipRuntimeApi
   "hipDeviceAttributeIntegrated"].  A discrete part sits behind a host
   interconnect, so its sighting is NOT an MI300A result; the class is stamped
   into the banner. */
static const char* _het_amd_part_class(int _integrated){
  return _integrated ? "APU(integrated)" : "DISCRETE(not-integrated)";
}
static int _het_alloc_mode(void){
  static int _mode = -1;
  const char *_v;
  int _integrated, _managed, _cma, _pg;
  if (_mode >= 0) return _mode;
  _v = getenv("HET_ALLOC");
  _integrated = _het_hip_attr(hipDeviceAttributeIntegrated);
  _managed    = _het_hip_attr(hipDeviceAttributeManagedMemory);
  _cma        = _het_hip_attr(hipDeviceAttributeConcurrentManagedAccess);
  _pg         = _het_hip_attr(hipDeviceAttributePageableMemoryAccess);
  if (_v == NULL || *_v == '\0' || strcmp(_v, "auto") == 0
      || strcmp(_v, "managed") == 0) {
    _mode = HET_HIP_ALLOC_MANAGED;
  } else {
    fprintf(stderr,
            "HetLitmus FATAL: HET_ALLOC=\"%s\" is not a shared-memory mode of the "
            "HIP render: use auto or managed.\n",
            _v);
    exit(2);
  }
  /* Banner before guards: a fatal below is readable only with its attributes logged. */
  printf("HetLitmus: shared-mem mode=managed (HET_ALLOC=%s amd_part_class=%s "
         "integrated=%d managedMemory=%d concurrentManagedAccess=%d "
         "pageableMemoryAccess=%d)\n",
         (_v != NULL && *_v != '\0') ? _v : "unset",
         _het_amd_part_class(_integrated), _integrated, _managed, _cma, _pg);
  fflush(stdout);
  /* Without HMM hipMallocManaged silently becomes hipMallocHost, pinned host
     memory off the coherent path [HipRuntimeApi "hipMallocManaged"]: fatal,
     never a warning. */
  if (!_managed) {
    fprintf(stderr,
            "HetLitmus FATAL: hipDeviceAttributeManagedMemory=0: hipMallocManaged "
            "would fall back to pinned host memory, off the coherent path.\n");
    exit(2);
  }
  /* Every het test has the CPU touching the shared allocation while the kernel
     is live. */
  if (!_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: hipDeviceAttributeConcurrentManagedAccess=0: the CPU "
            "may not touch a managed allocation while the kernel is live.\n");
    exit(2);
  }
  /* Not fatal: a discrete part is a valid bring-up target, announced and stamped
     so its histogram never reads as an APU result. */
  if (!_integrated) {
    fprintf(stderr,
            "HetLitmus WARNING: hipDeviceAttributeIntegrated=0: a discrete AMD GPU, "
            "so this is machinery bring-up, not an integrated-APU result.\n");
  }
  return _mode;
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  (void)_het_alloc_mode();               /* resolve + guard once, before the first alloc */
  *_pp = NULL;   /* never read the caller's uninitialised pointer */
  hipError_t _e = hipMallocManaged(_pp, _bytes);   /* fine-grained by default */
  if (_e != hipSuccess || *_pp == NULL) {
    fprintf(stderr,
            "HetLitmus FATAL: hipMallocManaged of %llu bytes for the shared vars "
            "failed (%s).\n",
            (unsigned long long)_bytes, hipGetErrorString(_e));
    exit(2);
  }
}
static void gd_free_shared(void* _p){
  /* Keyed on the cached mode, so a second mode could not leave a mismatched free. */
  (void)_het_alloc_mode();
  (void)hipFree(_p);
}
/* The harness's own device memory (read buffers, scratchpad, tally): a NULL
   would reach the launch, so a refused allocation ends the run. */
static void gd_alloc_dev(void** _pp, size_t _bytes, const char* _what){
  *_pp = NULL;
  hipError_t _e = hipMalloc(_pp, _bytes);
  if (_e != hipSuccess || *_pp == NULL) {
    fprintf(stderr,
            "HetLitmus FATAL: hipMalloc of %llu bytes for %s failed (%s).\n",
            (unsigned long long)_bytes, _what, hipGetErrorString(_e));
    exit(2);
  }
}
