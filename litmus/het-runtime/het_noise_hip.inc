/* THE NOISE BUFFERS on MI300A.  Same threads, same streaming, same
   disjointness; a different mechanism, because the hardware differs.

   On GH200 the noise crosses the interconnect because each buffer is homed on the
   other processing unit.  MI300A has a single HBM pool, so there is no other
   memory to home it in and placement does not transfer.  What transfers is
   CROSS-CHIPLET COHERENCE CONTENTION: both sides hammering the same fine-grained
   coherent region, over a working set that defeats L2 / Infinity-Cache residency,
   keeps the coherence protocol bouncing lines between the CCDs and the XCDs.

   Contention is necessary here precisely because caching is allowed here.  On
   the predecessor MI250X, GPU-side caching of coherent memory is disabled and every
   remote-coherent access generates fabric traffic for free; on MI300A that
   no-caching restriction can be lifted, so per-access traffic is not automatic and
   the lines must be kept moving (Schieffer et al., arXiv:2410.00801).  Corroborated
   by arXiv:2508.12743, where co-running CPU and GPU atomics on a contended shared
   array collapse CPU throughput.

   hipMallocManaged is fine-grained by default on MI300A, which is the coherence mode
   this needs.  `_where' is accepted and ignored: there is no home to select.
   Returns 0 (there is no placement step that could fail) or -1. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  (void)_where;
  *_pp = NULL;
  if (hipMallocManaged(_pp, _bytes) != hipSuccess || *_pp == NULL) return -1;
  /* FAULT THE PAGES IN.  Managed memory is lazily populated and an untouched buffer
     is backed by a single shared zero page, so streaming it would hit one cache
     line out of L1 and generate no coherence traffic; the contention this render
     relies on needs those lines to exist before the chiplets can bounce them
     (see het_cpu_first_touch in het_cpu_stress.h). */
  het_cpu_first_touch(*_pp, _bytes);
  return 0;
}
static void gd_free_noise(void* _p){
  if (_p != NULL) (void)hipFree(_p);
}
