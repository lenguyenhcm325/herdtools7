B1 regression guard: the shared litmus vars + the rendezvous barrier must go
through the per-target gd_alloc_shared / gd_free_shared allocator (Q8 R1/R2/R4),
NOT the old hard-coded *MallocManaged.  The allocator SELECTS THE PROPERTY UNDER
TEST (system malloc/ATS cache-line CHI coherence on GH200; fine-grained
hipMallocManaged on MI300A; cudaMallocManaged only as the dev-box/CI fallback), so
this is correctness, not tuning.  We emit the representative MP shape once (both
.cu and .hip) and assert the structural invariants with robust counts.

  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1

(a) the shared vars (x, y) AND the barrier route through gd_alloc_shared (3 call
sites), and each is freed by the allocator-aware gd_free_shared (3 frees).
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  3
  $ grep -cE 'gd_free_shared\((x|y|barrier)\)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  3

(b) gd_alloc_shared / gd_free_shared are each defined exactly once (file scope).
  $ grep -c 'static void gd_alloc_shared' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'static void gd_free_shared' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(c) CUDA dispatch: query cudaDevAttrPageableMemoryAccess, take the malloc branch on
a pageable device (GH200) and the cudaMallocManaged fallback otherwise, with a
MATCHING free (free() for malloc, cudaFree for managed -- a mismatched free is UB).
  $ grep -c 'cudaDevAttrPageableMemoryAccess' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '\*_pp = malloc' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMallocManaged(_pp' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -cE 'free\(_p\).*cudaFree\(_p\)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(d) __out is OFF the concurrent-race path -- it stays managed (cudaMallocManaged +
cudaFree), NOT routed through gd_alloc_shared.
  $ grep -c 'int \*__out; cudaMallocManaged' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaFree(__out)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(e) the design-doc-flagged wrong banner ("*MallocManaged (CPU/GPU-coherent ...)")
is gone.
  $ grep -c 'CPU/GPU-coherent on GH200' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

The HIP twin renders from the same template: gd_alloc_shared is fine-grained
hipMallocManaged (no malloc/ATS dispatch -- MI300A's unified HBM pool needs none),
and __out likewise stays hipMallocManaged.
  $ grep -c 'hipMallocManaged(_pp' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip
  3
  $ grep -c 'int \*__out; (void)hipMallocManaged' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip
  1
