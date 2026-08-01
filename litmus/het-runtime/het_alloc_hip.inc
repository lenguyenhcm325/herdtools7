/* Shared litmus vars + barrier use fine-grained coherent memory.
   hipMallocManaged is fine-grained BY DEFAULT on MI300A -- the only coherence mode
   usable for system-scope CPU<->GPU synchronisation *while the kernel is live*
   (coarse-grained memory becomes visible only at a kernel-boundary sync, which
   would void every heterogeneous test).  Which allocator runs decides what
   property the harness tests, so this is correctness rather than tuning; see
   env-research/Q8-allocation.md.  MI300A's unified HBM pool needs no page
   migration, so no dispatch is required for correctness, and the free matches
   (hipFree).  A malloc plus HSA_XNACK=1 variant is a runtime-env choice, not a
   codegen one.  The read buffers are not routed here -- device memory
   (hipMalloc), off the coherent race path. */
static void gd_alloc_shared(void** _pp, size_t _bytes){
  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */
  /* There is no placement lever on MI300A: one HBM pool shared by the CCD (CPU)
     and XCD (GPU) chiplets means no LPDDR/HBM split, no first-touch home to
     choose and nothing to pin.  Its analogue of the interconnect lever is
     CONTENTION, which the noise pair below supplies when both sides stream the
     same coherent pool (env-research/Q6-cpu-interconnect-stress.md sec 3.4). */
}
static void gd_free_shared(void* _p){
  (void)hipFree(_p);
}
