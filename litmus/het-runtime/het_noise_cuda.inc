/* The noise buffers -- a fourth object class, disjoint from the shared test vars
   and barrier (gd_alloc_shared), the GPU stress scratchpad (cudaMalloc) and the
   CPU enemy scratchpad (host malloc).  Both are system memory and differ only in
   where their pages are homed, which is what `_where' selects, so each side
   stream-reads the other unit's memory and crosses the link
   [Fusco24 sec III-E.1].  Returns 0 = homed on the other unit, -1 = refused: a
   buffer that cannot be homed there generates local traffic, not interconnect
   traffic, and is refused rather than run. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  static int _said = 0;
  *_pp = NULL;
  if (!_shared_pageable()) {
    /* No pageable-memory access: no ATS and no home to select
       (hetlitmus/docs/00-environment-design.md sec 3.6). */
    if (!_said) {
      _said = 1;
      fprintf(stderr,
              "HetLitmus WARNING: this device reports cudaDevAttrPageableMemoryAccess=0, "
              "so no noise buffer can be homed on the other unit -- the noise pair is "
              "refused.\n");
    }
    return -1;
  }
  *_pp = malloc(_bytes);
  if (*_pp == NULL) return -1;
  /* Advise, THEN fault the pages in: first touch is what places a page, so advice
     afterwards would advise pages that already have a home, and an untouched
     buffer generates no traffic while the round counts still look healthy
     (het_cpu_first_touch in het_cpu_stress.h). */
  int _dev = 0;
  int _home = (_where == 1) ? _dev : cudaCpuDeviceId;   /* 1 = HBM, 2 = DDR */
  cudaError_t _e1 = cudaMemAdvise(*_pp, _bytes, cudaMemAdviseSetPreferredLocation, _home);
  cudaError_t _e2 = cudaMemAdvise(*_pp, _bytes, cudaMemAdviseSetAccessedBy, _dev);
  cudaError_t _e3 = cudaMemAdvise(*_pp, _bytes, cudaMemAdviseSetAccessedBy, cudaCpuDeviceId);
  if (_e1 != cudaSuccess || _e2 != cudaSuccess || _e3 != cudaSuccess) {
    fprintf(stderr,
            "HetLitmus WARNING: cudaMemAdvise REFUSED (%s / %s / %s) -- the %s noise "
            "buffer has no home on the other unit and is refused.\n",
            cudaGetErrorString(_e1), cudaGetErrorString(_e2), cudaGetErrorString(_e3),
            (_where == 1) ? "HBM" : "DDR");
    free(*_pp); *_pp = NULL;
    return -1;
  }
  het_cpu_first_touch(*_pp, _bytes);
  /* The CPU did the touching, so the pages are homed on DDR.  Advice alone will
     not move resident pages, so the buffer that must live on HBM is prefetched
     across, and a refused prefetch refuses the buffer: pages left on DDR
     generate local traffic, not interconnect traffic. */
  if (_where == 1) {
    cudaError_t _e = cudaMemPrefetchAsync(*_pp, _bytes, 0, 0);
    if (_e == cudaSuccess) _e = cudaDeviceSynchronize();
    if (_e != cudaSuccess) {
      fprintf(stderr,
              "HetLitmus WARNING: cudaMemPrefetchAsync of the HBM noise buffer FAILED "
              "(%s) -- its pages stay where the CPU first touched them, so the "
              "buffer is refused.\n",
              cudaGetErrorString(_e));
      free(*_pp); *_pp = NULL;
      return -1;
    }
  }
  return 0;
}
static void gd_free_noise(void* _p){
  free(_p);
}
