/* The noise buffer -- same threads, same streaming, same disjointness as the
   CUDA render, a different allocator: hipMallocManaged.  Returns 0 or -1. */
static int gd_alloc_noise(void** _pp, size_t _bytes){
  /* No concurrent-managed-access test here: _het_alloc_mode (het_alloc_hip.inc)
     exits on that attribute before the first allocation of any class. */
  *_pp = NULL;
  if (hipMallocManaged(_pp, _bytes) != hipSuccess || *_pp == NULL) return -1;
  /* Fault the pages in: untouched, the buffer streams the zero page
     (het_cpu_first_touch in het_cpu_stress.h). */
  het_cpu_first_touch(*_pp, _bytes);
  return 0;
}
static void gd_free_noise(void* _p){
  if (_p != NULL) (void)hipFree(_p);
}
