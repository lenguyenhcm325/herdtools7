/* The noise buffers on MI300A -- same threads, same streaming, same disjointness
   as the CUDA render, a different mechanism.  One HBM pool means no other memory
   to home a buffer in, so placement does not transfer; what does is contention on
   the one shared coherent pool, measured on this part as CPU throughput at
   11-25 % of baseline once thousands of GPU threads share a highly contended
   array [Wahlgren25 sec 4.4].  Attributing that to CCD-XCD traffic, and the step
   from "per-access fabric traffic is not automatic here" to "contention drives
   it", are inferences [Schieffer24 sec II.C].  `_where' is accepted and ignored:
   there is no home to select.  Returns 0 (no placement step can fail) or -1. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  (void)_where;
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
