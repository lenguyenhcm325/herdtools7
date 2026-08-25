/* Shared litmus vars + barrier use fine-grained coherent memory: hipMallocManaged
   is fine-grained by default [HipRuntimeApi "hipMemAdviseSetCoarseGrain"], the
   only coherence mode usable for system-scope CPU<->GPU synchronisation while the
   kernel is live.  Which allocator runs decides what property the harness tests,
   so this is correctness rather than tuning
   (hetlitmus/docs/00-environment-design.md sec 3.2).  MI300A's unified HBM pool
   needs no page migration, so no dispatch is required: this render implements
   exactly ONE mode, refuses every other spelling of HET_ALLOC rather than
   substituting for it, and frees with the matching hipFree.  The read buffers are
   device memory (hipMalloc), off the coherent race path. */
#define HET_HIP_ALLOC_MANAGED 1
/* HET_PLACE is a CUDA-only lever, but both renders print it, so a non-zero value
   here would reach the banner and the statistics record with nothing placed.
   Refused at compile time, where the answer is already known; 0 is the default and
   the only value this lane can honour.  The AMD analogue of the interconnect lever
   is CONTENTION, not placement (hetlitmus/docs/het-emission.md). */
#if (HET_PLACE) != 0
# error "HET_PLACE is a CUDA-only lever (cudaMemAdvise); the HIP render has no placement code, so a non-zero HET_PLACE would be reported in the banner and the statistics record without anything having been placed.  This render has no page-placement API to call -- use HET_PLACE=0 and drive the interconnect with the noise knobs instead."
#endif
static int _het_hip_attr(hipDeviceAttribute_t _a){
  int _v = 0;
  (void)hipDeviceGetAttribute(&_v, _a, 0);
  return _v;
}
/* APU (MI300A) vs discrete (MI300X): hipDeviceAttributeIntegrated is the only
   runtime query that separates them, since both report gfx942 [HipRuntimeApi
   "hipDeviceAttributeIntegrated"].  The APU's CCD and XCD chiplets share one HBM
   pool; a discrete part is reached over a host interconnect, so a discrete-part
   sighting is NOT an MI300A result.  The class is stamped into the banner. */
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
            "HIP render.  This render implements ONE mode -- fine-grained "
            "hipMallocManaged -- so use auto (or unset) or managed.  malloc and "
            "pinned exist on the CUDA render only; there is deliberately NO "
            "fallback here, because silently substituting managed for a requested "
            "malloc would run a different experiment under the requested name.\n",
            _v);
    exit(2);
  }
  /* The banner precedes the guards on purpose: a fatal below is actionable only
     if the attributes that caused it are already in the log. */
  printf("HetLitmus: shared-mem mode=managed (HET_ALLOC=%s amd_part_class=%s "
         "integrated=%d managedMemory=%d concurrentManagedAccess=%d "
         "pageableMemoryAccess=%d)\n",
         (_v != NULL && *_v != '\0') ? _v : "unset",
         _het_amd_part_class(_integrated), _integrated, _managed, _cma, _pg);
  fflush(stdout);
  /* hipMallocManaged degrades silently: without HMM it behaves as hipMallocHost
     [HipRuntimeApi "hipMallocManaged"], which is pinned host memory off the
     coherent path, so the harness would keep running and stop testing the very
     thing under test.  Fatal, never a warning. */
  if (!_managed) {
    fprintf(stderr,
            "HetLitmus FATAL: this device reports hipDeviceAttributeManagedMemory=0, "
            "so hipMallocManaged falls back to hipMallocHost (pinned host memory) "
            "instead of fine-grained managed memory.  The shared vars and the "
            "rendezvous barrier would then sit off the coherent path and the "
            "histogram would mean nothing.  There is no other mode on this render.\n");
    exit(2);
  }
  /* The precondition the CUDA render enforces too: every het test has the CPU
     touching the shared allocation while the kernel is live. */
  if (!_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: this device reports "
            "hipDeviceAttributeConcurrentManagedAccess=0: the CPU may not touch a "
            "managed allocation while the kernel is live, and a system-scope atomic "
            "on it is not atomic.  EVERY heterogeneous test here does exactly that, "
            "so there is nothing to salvage.\n");
    exit(2);
  }
  /* Not fatal: a discrete part is a valid bring-up target.  Announced on stderr
     and stamped in the banner, so no discrete-part histogram reads as an APU
     result. */
  if (!_integrated) {
    fprintf(stderr,
            "HetLitmus WARNING: hipDeviceAttributeIntegrated=0 -- this is a DISCRETE "
            "AMD GPU (not integrated), not an integrated APU.  The APU shares one HBM "
            "pool between the CCD and XCD chiplets; a discrete part is reached over "
            "a host interconnect.  This run is valid as machinery bring-up and must "
            "NOT be reported as an integrated-APU result.\n");
  }
  return _mode;
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  (void)_het_alloc_mode();               /* resolve + guard once, before the first alloc */
  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */
  /* No placement lever on MI300A: one HBM pool shared by the CCD (CPU) and XCD
     (GPU) chiplets leaves no first-touch home to choose.  Its analogue is
     contention, which the noise pair supplies
     (hetlitmus/docs/00-environment-design.md sec 3.6). */
}
static void gd_free_shared(void* _p){
  /* Cached mode, NOT a re-query: one mode here, but the free stays keyed on the
     resolver so a second mode cannot leave a mismatched free behind. */
  (void)_het_alloc_mode();
  (void)hipFree(_p);
}
