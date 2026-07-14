B1 regression guard: the shared litmus vars + the rendezvous barrier must go
through the per-target gd_alloc_shared / gd_free_shared allocator (Q8 R1/R2/R4),
NOT the old hard-coded *MallocManaged.  The allocator SELECTS THE PROPERTY UNDER
TEST (system malloc/ATS cache-line CHI coherence on GH200; fine-grained
hipMallocManaged on MI300A; cudaMallocManaged only as the dev-box/CI fallback), so
this is correctness, not tuning.  We emit the representative MP shape once (both
.cu and .hip) and assert the structural invariants with robust counts.

B6b: the representative is MP-cg-sys-ACQUIRE, not MP-cg-sys-acqrel-2s.  The latter is
a should-be-FORBIDDEN test, so its harness now CO-RUNS three instances and carves
their shared vars out of ONE cache-line-padded arena (guarded at the bottom of this
file).  The PER-VARIABLE path checked here is still what 322 of the 338 het harnesses
use, so it keeps its own guard, at full strength, on a harness that still takes it --
rather than being loosened to accommodate the 16.

  $ litmus7 -o . ../het/MP-cg-sys-acquire.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1

(a) the shared vars (x, y) AND the barrier route through gd_alloc_shared (3 call
sites), and each is freed by the allocator-aware gd_free_shared (3 frees).
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  3
  $ grep -cE 'gd_free_shared\((x|y|barrier)\)' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  3

(b) gd_alloc_shared / gd_free_shared are each defined exactly once (file scope).
  $ grep -c 'static void gd_alloc_shared' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1
  $ grep -c 'static void gd_free_shared' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1

(c) CUDA dispatch: query cudaDevAttrPageableMemoryAccess, take the malloc branch on
a pageable device (GH200) and the cudaMallocManaged fallback otherwise, with a
MATCHING free (free() for malloc, cudaFree for managed -- a mismatched free is UB).

Each grep below is SCOPED to gd_alloc_shared's own body.  B5 added gd_alloc_noise,
which makes the same pageable-vs-managed dispatch for a different object class (the
C2C noise buffers), so a file-wide count would now read 2 -- and bumping it to 2
would have made this check satisfiable by a SECOND allocator sneaking into
gd_alloc_shared, which is the very confusion it exists to prevent.  Scope, don't bump.
  $ grep -c 'cudaDevAttrPageableMemoryAccess' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1
  $ ALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-acquire/MP-cg-sys-acquire.cu)
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = malloc'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaMallocManaged(_pp'
  1
  $ sed -n '/^static void gd_free_shared/,/^}/p' MP-cg-sys-acquire/MP-cg-sys-acquire.cu | grep -cE 'free\(_p\).*cudaFree\(_p\)'
  1

(d) B3: __out is gone; the per-load read buffers are OFF the concurrent-race path
-- device memory (cudaMalloc) + a host mirror for the post-run scan -- NOT routed
through gd_alloc_shared, and the shared vars are widened to uint64_t.
  $ grep -c '__out' MP-cg-sys-acquire/MP-cg-sys-acquire.cu || true
  0
  $ grep -c 'cudaMalloc(&bufP' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  2
  $ grep -c 'uint64_t \*x; gd_alloc_shared' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1

(e) the design-doc-flagged wrong banner ("*MallocManaged (CPU/GPU-coherent ...)")
is gone.
  $ grep -c 'CPU/GPU-coherent on GH200' MP-cg-sys-acquire/MP-cg-sys-acquire.cu || true
  0

The HIP twin renders from the same template: gd_alloc_shared is fine-grained
hipMallocManaged (no malloc/ATS dispatch -- MI300A's unified HBM pool needs none),
and the read buffers are device hipMalloc (off the race path), no __out.  Scoped to
gd_alloc_shared's body for the same reason as (c): B5's gd_alloc_noise allocates the
C2C noise buffers the same way, and a file-wide count would stop discriminating.
  $ sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-acquire/MP-cg-sys-acquire.hip | grep -c 'hipMallocManaged(_pp'
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc' MP-cg-sys-acquire/MP-cg-sys-acquire.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-acquire/MP-cg-sys-acquire.hip
  3
  $ grep -c '__out' MP-cg-sys-acquire/MP-cg-sys-acquire.hip || true
  0
  $ grep -c '(void)hipMalloc(&bufP' MP-cg-sys-acquire/MP-cg-sys-acquire.hip
  2

(f) B6b -- THE CO-RUN ARENA.  A should-be-FORBIDDEN test co-runs mu(T) and the canary,
and disjoint ADDRESSES are not enough: two variables on one cache line are ONE
coherence unit, so mu(T)'s traffic would drag T's line around and the control would
perturb the very test it exists to vouch for (Q4 3.1 / 8.4).  Six separate 8-byte
mallocs cannot prevent that; one padded arena can.

What must NOT change is the ALLOCATOR -- it selects the property under test -- so the
arena still goes through gd_alloc_shared (system malloc/ATS on GH200), and its free
still matches (gd_free_shared).  A mismatched free is UB that may not fault on the
managed dev-box path and only surfaces on GH200.
  $ CO=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena' $CO.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&' $CO.cu
  1
  $ grep -c 'gd_free_shared(_shared_arena)' $CO.cu
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $CO.cu
  6
  $ grep -c 'HET_CACHE_LINE 128' $CO.cu
  1

The arena is NOT plain malloc: that would be the enemy-scratchpad class (host-only,
disjoint), and putting the tested locations there would take them off the coherent
path entirely -- the harness would then be testing nothing at all.
  $ grep -c 'malloc_check(.*_shared_arena' $CO.cu || true
  0

The HIP twin carves the same arena from its own gd_alloc_shared (fine-grained
hipMallocManaged): one template, two renders.
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena' $CO.hip
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $CO.hip
  6
