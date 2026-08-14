/* THE NOISE BUFFERS on MI300A.  Same threads, same streaming, same
   disjointness; a different mechanism, because the hardware differs.

   On GH200 the noise crosses the interconnect because each buffer is homed on the
   other processing unit.  MI300A has a single HBM pool, so there is no other
   memory to home it in and placement does not transfer.  What transfers is
   CROSS-CHIPLET COHERENCE CONTENTION: both sides hammering the same fine-grained
   coherent region, over a working set that defeats L2 / Infinity-Cache residency,
   keeps the coherence protocol bouncing lines between the CCDs and the XCDs.

   Contention is necessary here precisely because caching is allowed here.  On the
   predecessor MI250X, GPU-side caching of coherent memory is disabled and every
   access to remote coherent memory therefore generates interconnect traffic; on
   MI300A cache-coherent interconnects allow that no-caching restriction to be
   lifted [Schieffer24 sec II.C], so per-access traffic is not automatic and the
   lines must be kept moving.  That last step is an INFERENCE: the source measures
   MI250X and says only that the restriction can be lifted.  What is measured on
   MI300A is that co-running CPU and GPU atomics on a highly contended shared array
   cut CPU throughput to 11-25% of its isolated baseline [Wahlgren25 sec 4.4] --
   contention on one shared coherent pool, which is what this stresses.

   hipMallocManaged is fine-grained by default on MI300A (the shared allocator
   above cites the runtime's own statement), which is the coherence mode this
   needs.  `_where' is accepted and ignored: there is no home to select.
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
