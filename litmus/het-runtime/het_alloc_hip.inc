/* Shared litmus vars + barrier use fine-grained coherent memory.
   hipMallocManaged is fine-grained BY DEFAULT on MI300A -- the only coherence mode
   usable for system-scope CPU<->GPU synchronisation *while the kernel is live*
   (coarse-grained memory becomes visible only at a kernel-boundary sync, which
   would void every heterogeneous test).  Which allocator runs decides what
   property the harness tests, so this is correctness rather than tuning; see
   env-research/Q8-allocation.md.  MI300A's unified HBM pool needs no page
   migration, so no dispatch is required for correctness, and the free matches
   (hipFree).  A malloc plus HSA_XNACK=1 variant is a runtime-env choice, not a
   codegen one.  The read buffers are not routed here -- device memory
   (hipMalloc), off the coherent race path.

   "Fine-grained by default" is the ROCm runtime's own statement, not an
   inference: hipMemAdviseSetCoarseGrain is documented in hip_runtime_api.h as
   "The default memory model is fine-grain.  That allows coherent operations
   between host and device, while executing kernels.  The coarse-grain can be
   used for data that only needs to be coherent at dispatch boundaries for better
   performance" (ROCm 7.2.4).  Nothing here ever advises coarse grain.

   ONE MODE, AND IT SAYS SO.  The CUDA render dispatches over three HET_ALLOC
   modes; this one implements exactly one, so every other spelling is REFUSED
   rather than quietly ignored.  A HET_ALLOC=malloc that silently allocated
   fine-grained managed memory would run a different experiment from the one
   asked for and report it under the asked-for name -- the same class of defect
   as a stress knob that is read but never applied.  There is deliberately no
   fallback: see the FATAL below. */
#define HET_HIP_ALLOC_MANAGED 1
/* HET_PLACE IS REFUSED HERE, FOR THE SAME REASON AS HET_ALLOC=malloc.  The
   placement lever is CUDA API (cudaMemAdvise / cudaMemPrefetchAsync) and lives
   in het_alloc_cuda.inc; this render has no placement code at all.  But
   HET_PLACE is an #ifndef knob, it is swept by the tuner, and BOTH renders print
   it -- `place=%d' in the cpu-stress banner and `place_mode' in the per-run
   statistics record -- because those two lines are emitted once for both
   dialects.  So `make hip-bin HIPCC="hipcc -DHET_PLACE=1"' would have produced a
   log reading `place=1 ... place_fail=0': prefer-HBM placement requested, no
   refusals recorded.  Both halves false -- nothing was placed and nothing could
   have been refused, because _het_place_failures has no writer on this lane.
   That is a knob read into the log and never applied, with a companion counter
   that is constant-0 so no reader can tell (the shape of B4's inert stress and
   B6a's constant-0 exhaustive_valid).
   Refused at COMPILE time rather than warned about at run time -- the opposite
   of the CUDA render's _het_place_inert -- because there the mode is chosen at
   run time by HET_ALLOC and placement genuinely exists in one of the three
   modes, whereas here the answer is already known when the .hip is compiled.
   HET_PLACE=0 is the default and the only value this lane can honour, so a
   normal AMD build is unaffected; with it pinned to 0, `place=0 place_fail=0' is
   a true statement rather than an unfalsifiable one. */
#if (HET_PLACE) != 0
# error "HET_PLACE is a CUDA-only lever (cudaMemAdvise); the @HIP_RENDER@ render has no placement code, so a non-zero HET_PLACE would be reported in the banner and the statistics record without anything having been placed.  @NO_PLACE_WHY@ -- use HET_PLACE=0 and drive the interconnect with the noise knobs instead."
#endif
static int _het_hip_attr(hipDeviceAttribute_t _a){
  int _v = 0;
  (void)hipDeviceGetAttribute(&_v, _a, 0);
  return _v;
}
/* APU (MI300A) vs discrete (MI300X): hipDeviceAttributeIntegrated, documented in
   hip_runtime_api.h as "Device is integrated GPU" and mirrored by
   hipDeviceProp_t::integrated, "APU vs dGPU".  gcnArchName cannot make this call
   -- both parts report gfx942 -- and the distinction is not cosmetic: MI300A is
   an APU whose CCD and XCD chiplets share ONE HBM pool, while MI300X is a
   discrete accelerator reached over a host interconnect.  Their coherence
   behaviour is not the same experiment and an MI300X sighting must never be
   reported as an MI300A result (env-research PORT2 scope decision, 2026-08-01).
   The class is therefore stamped into the banner, so the log a run leaves behind
   carries it whether or not anyone reads this file. */
static const char* _het_amd_part_class(int _integrated){
  return _integrated ? "APU(@APU_CLASS@)" : "DISCRETE(@DGPU_CLASS@)";
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
  /* The banner precedes the guards ON PURPOSE -- a FATAL below is only actionable
     if the attributes that caused it are already in the log. */
  printf("HetLitmus: shared-mem mode=managed (HET_ALLOC=%s amd_part_class=%s "
         "integrated=%d managedMemory=%d concurrentManagedAccess=%d "
         "pageableMemoryAccess=%d)\n",
         (_v != NULL && *_v != '\0') ? _v : "unset",
         _het_amd_part_class(_integrated), _integrated, _managed, _cma, _pg);
  fflush(stdout);
  /* hipMallocManaged DEGRADES SILENTLY, and the degradation is exactly the thing
     under test.  hip_runtime_api.h: "If HMM is not supported, the function
     behaves the same as hipMallocHost", and it asks for the capability check by
     name -- "It is recommend to do the capability check before call this API".
     hipMallocHost is pinned host memory, not fine-grained device-coherent
     memory, so the harness would keep running and quietly stop testing the
     coherence path.  Fatal, never a warning. */
  if (!_managed) {
    fprintf(stderr,
            "HetLitmus FATAL: this device reports hipDeviceAttributeManagedMemory=0, "
            "so hipMallocManaged falls back to hipMallocHost (pinned host memory) "
            "instead of fine-grained managed memory.  The shared vars and the "
            "rendezvous barrier would then sit off the coherent path and the "
            "histogram would mean nothing.  There is no other mode on this render.\n");
    exit(2);
  }
  /* Same precondition the CUDA render enforces, for the same reason: every het
     test has the CPU touching the shared allocation WHILE the kernel is live. */
  if (!_cma) {
    fprintf(stderr,
            "HetLitmus FATAL: this device reports "
            "hipDeviceAttributeConcurrentManagedAccess=0: the CPU may not touch a "
            "managed allocation while the kernel is live, and a system-scope atomic "
            "on it is not atomic.  EVERY heterogeneous test here does exactly that, "
            "so there is nothing to salvage.\n");
    exit(2);
  }
  /* Not fatal: MI300X is the Phase-3a machinery bring-up target and must be able
     to run.  It is announced on stderr AND stamped in the banner above so that no
     discrete-part histogram can later be read as an MI300A result by someone
     holding only the log. */
  if (!_integrated) {
    fprintf(stderr,
            "HetLitmus WARNING: hipDeviceAttributeIntegrated=0 -- this is a DISCRETE "
            "AMD GPU (@DGPU_NAME@), not @APU_NAME@.  The APU shares one HBM "
            "pool between the CCD and XCD chiplets; a discrete part is reached over "
            "a host interconnect.  This run is valid as machinery bring-up and must "
            "NOT be reported as @APU_RESULT@.\n");
  }
  return _mode;
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  (void)_het_alloc_mode();               /* resolve + guard once, before the first alloc */
  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */
  /* There is no placement lever on MI300A: one HBM pool shared by the CCD (CPU)
     and XCD (GPU) chiplets means no LPDDR/HBM split, no first-touch home to
     choose and nothing to pin.  Its analogue of the interconnect lever is
     CONTENTION, which the noise pair below supplies when both sides stream the
     same coherent pool (env-research/Q6-cpu-interconnect-stress.md sec 3.4). */
}
static void gd_free_shared(void* _p){
  /* Cached mode, NOT a re-query -- one mode here, but the free stays keyed on the
     resolver so that adding a second mode cannot leave a mismatched free behind. */
  (void)_het_alloc_mode();
  (void)hipFree(_p);
}
