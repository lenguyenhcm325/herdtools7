/* The noise buffer -- a fourth object class, disjoint from the shared test vars
   and barrier (gd_alloc_shared), the GPU stress scratchpad (cudaMalloc) and the
   CPU stress scratchpad (host malloc).  One system buffer, stream-read by BOTH
   halves (hetlitmus/docs/environment-design.md "Interconnect stress").
   Returns 0, or -1 = refused: without pageable-memory access the GPU cannot
   read a system buffer. */
static int gd_alloc_noise(void** _pp, size_t _bytes){
  *_pp = NULL;
  if (!_shared_pageable()) {
    fprintf(stderr,
            "HetLitmus WARNING: this device reports cudaDevAttrPageableMemoryAccess=0, "
            "so the GPU cannot stream a system buffer -- the noise buffer is refused.\n");
    return -1;
  }
  *_pp = malloc(_bytes);
  if (*_pp == NULL) return -1;
  het_cpu_first_touch(*_pp, _bytes);   /* untouched, it streams the zero page */
  return 0;
}
static void gd_free_noise(void* _p){
  free(_p);
}
