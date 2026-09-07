/* The noise buffer on MI300A -- same threads, same streaming, same disjointness
   as the CUDA render, a different mechanism.  One HBM pool is the one home of
   every page, so neither reader crosses a link; what loads the part is
   contention on the one shared coherent pool, measured on it as CPU throughput
   at 11-25 % of baseline once thousands of GPU threads share a highly contended
   array [Wahlgren25 sec 4.4].  Attributing that to CCD-XCD traffic, and the step
   from "per-access fabric traffic is not automatic here" to "contention drives
   it", are inferences [Schieffer24 sec II.C].  Returns 0 or -1. */
static int gd_alloc_noise(void** _pp, size_t _bytes){
  /* No concurrent-managed-access test here: _het_alloc_mode (het_alloc_hip.inc)
     exits on that attribute before the first allocation of any class. */
  *_pp = NULL;
  if (hipMallocManaged(_pp, _bytes) != hipSuccess || *_pp == NULL) return -1;
  /* Fault the pages in: an untouched managed buffer generates no coherence
     traffic, so the chiplets would have no lines to bounce
     (het_cpu_first_touch in het_cpu_stress.h). */
  het_cpu_first_touch(*_pp, _bytes);
  return 0;
}
static void gd_free_noise(void* _p){
  if (_p != NULL) (void)hipFree(_p);
}
