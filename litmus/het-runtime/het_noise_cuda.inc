/* The noise buffers -- a fourth object class, disjoint from the shared test vars
   and barrier (gd_alloc_shared), the GPU stress scratchpad (cudaMalloc) and the
   CPU enemy scratchpad (host malloc).  Both are system memory and differ only in
   where their pages are homed, which is what `_where' selects, so each side
   stream-reads the other unit's memory and crosses the link
   [Fusco24 sec III-E.1].  Returns 0 = placed, 1 = allocated but not
   interconnect-capable (degraded), -1 = failed; the caller must say which, since
   a run whose interconnect stressor is inert must NEVER be reported as an
   interconnect-stressed run. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  if (!_shared_pageable()) {
    /* No pageable-memory access: no ATS and no placement lever.  Allocate so the
       plumbing runs, but this is NOT interconnect stress, and the degraded return
       code is what makes the driver say so. */
    *_pp = NULL;
    if (cudaMallocManaged(_pp, _bytes) != cudaSuccess || *_pp == NULL) return -1;
    /* Without concurrent managed access the host may not touch a managed buffer
       while a kernel is live (hetlitmus/docs/00-environment-design.md sec 3.6). */
    if (_where == 1 && !_het_dev_attr(cudaDevAttrConcurrentManagedAccess)) {
      cudaFree(*_pp); *_pp = NULL;
      return -1;
    }
    het_cpu_first_touch(*_pp, _bytes);   /* managed memory is lazily populated too */
    return 1;
  }
  *_pp = malloc(_bytes);
  if (*_pp == NULL) return -1;
  int _before = _het_place_failures;
  /* Advise, THEN fault the pages in: first touch is what places a page, so advice
     afterwards would advise pages that already have a home, and an untouched
     buffer generates no traffic while the round counts still look healthy
     (het_cpu_first_touch in het_cpu_stress.h). */
  _het_place(*_pp, _bytes, _where);
  het_cpu_first_touch(*_pp, _bytes);
  /* The CPU did the touching, so the pages are homed on DDR.  Advice alone will
     not move resident pages, so the buffer that must live on HBM is prefetched
     across -- and a refusal is reported, because a "HBM" buffer really on DDR
     generates local traffic, not interconnect traffic. */
  if (_where == 1) {
    cudaError_t _e = cudaMemPrefetchAsync(*_pp, _bytes, 0, 0);
    if (_e == cudaSuccess) _e = cudaDeviceSynchronize();
    if (_e != cudaSuccess) {
      _het_place_failures++;
      fprintf(stderr,
              "HetLitmus WARNING: cudaMemPrefetchAsync of the HBM noise buffer FAILED "
              "(%s) -- its pages stay where the CPU first touched them, so the host "
              "noise crosses no interconnect.\n",
              cudaGetErrorString(_e));
    }
  }
  return (_het_place_failures > _before) ? 1 : 0;
}
static void gd_free_noise(void* _p){
  if (_p == NULL) return;
  if (_shared_pageable()) { free(_p); } else { cudaFree(_p); }
}
