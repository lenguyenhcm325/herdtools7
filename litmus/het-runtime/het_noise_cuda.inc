/* THE NOISE BUFFERS -- a FOURTH object class; the four must not be
   confused:

     shared test vars + barrier -> gd_alloc_shared  (coherent; the property under test)
     GPU stress scratchpad      -> cudaMalloc       (device-only, disjoint)
     CPU enemy scratchpad       -> host malloc      (CPU-only, disjoint)
     noise buffers              -> HERE             (system memory homed on the OTHER
                                                     PU, so streaming it crosses C2C)

   The construction is [Fusco24 sec III-E.1]'s: a Grace and a Hopper noise kernel
   each continuously stream-read a large buffer homed on the other unit -- Grace
   reads HBM, Hopper reads DDR.  BOTH buffers are system-allocated and differ only
   in where their pages are homed, which is what `_where' selects.

   Returns 0 = placed, 1 = allocated but NOT interconnect-capable (degraded), -1 =
   failed.  The caller must say which -- a noise buffer that could not be homed
   remotely generates no cross-device traffic, and a run whose interconnect stressor
   is inert must never be reported as an interconnect-stressed run. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  if (!_shared_pageable()) {
    /* No pageable-memory access: no ATS, no C2C, no placement lever.  Allocate so
       the plumbing is exercised, but this is NOT interconnect stress, and the
       degraded return code is what makes the driver say so. */
    *_pp = NULL;
    if (cudaMallocManaged(_pp, _bytes) != cudaSuccess || *_pp == NULL) return -1;
    het_cpu_first_touch(*_pp, _bytes);   /* managed memory is lazily populated too */
    return 1;
  }
  *_pp = malloc(_bytes);
  if (*_pp == NULL) return -1;
  int _before = _het_place_failures;
  /* ADVISE FIRST, then FAULT THE PAGES IN.  Both halves of the order matter: on
     GH200 first touch is what PLACES the page, so advice afterwards would be
     advising pages that already have a home; and the touch is not optional,
     because Linux backs every untouched anonymous page with ONE shared zero page,
     so streaming an untouched buffer hits a single cache line out of L1 and
     generates no memory and no C2C traffic while the round counts still look
     healthy (see het_cpu_first_touch in het_cpu_stress.h). */
  _het_place(*_pp, _bytes, _where);
  het_cpu_first_touch(*_pp, _bytes);
  /* The CPU did the touching, so the pages are now homed on DDR.  For the buffer
     that is supposed to live on HBM (the one the Grace noise thread streams, so that
     each of its reads CROSSES C2C) the advice alone will not move them -- it is a
     hint, and the pages are already resident.  Prefetch them across, and say so if
     the driver refuses: a "HBM" noise buffer that is really on DDR generates local
     traffic, not interconnect traffic, and the run is not C2C-stressed. */
  if (_where == 1) {
    cudaError_t _e = cudaMemPrefetchAsync(*_pp, _bytes, 0, 0);
    if (_e == cudaSuccess) _e = cudaDeviceSynchronize();
    if (_e != cudaSuccess) {
      _het_place_failures++;
      fprintf(stderr,
              "HetLitmus WARNING: cudaMemPrefetchAsync of the HBM noise buffer FAILED "
              "(%s) -- its pages are still homed where the CPU first touched them "
              "(DDR), so the @HOST@ noise thread is streaming LOCAL memory and crosses "
              "no interconnect.  This run is not @LINK@-stressed on the @HOST@ side.\n",
              cudaGetErrorString(_e));
    }
  }
  return (_het_place_failures > _before) ? 1 : 0;
}
static void gd_free_noise(void* _p){
  if (_p == NULL) return;
  if (_shared_pageable()) { free(_p); } else { cudaFree(_p); }
}
