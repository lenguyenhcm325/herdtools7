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
  het_cpu_first_touch(*_pp, _bytes);   /* untouched pages all map to one zero page */
  return 0;
}
static void gd_free_noise(void* _p){
  free(_p);
}
