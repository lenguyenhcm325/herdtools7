Shared-memory allocation guard (hetlitmus/docs/00-environment-design.md sec 3.2).

One MP shape per dialect; the `.hip' comes from ../het-x86 because a HIP harness
is the (x86_64, hip) pair.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1

(a) the shared vars (x, y) and the barrier route through gd_alloc_shared (3 call
sites), and each is freed by the allocator-aware gd_free_shared (3 frees).
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  3
  $ grep -cE 'gd_free_shared\((x|y|barrier)\)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  3

(b) gd_alloc_shared / gd_free_shared are each defined exactly once (file scope).
  $ grep -c 'static void gd_alloc_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'static void gd_free_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

(c) CUDA dispatch: the pageable query picks malloc or the managed fallback and
each allocator has its matching free, every grep SCOPED to one function body.
  $ sed -n '/^static int _shared_pageable/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | grep -c 'cudaDevAttrPageableMemoryAccess,'
  1
  $ ALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu)
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = malloc'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaMallocManaged(_pp'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaHostAlloc(_pp'
  1
  $ FREE=$(sed -n '/^static void gd_free_shared/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu)
  $ printf '%s\n' "$FREE" | grep -cE '(^|[^a-zA-Z_])free\(_p\)'
  1
  $ printf '%s\n' "$FREE" | grep -c 'cudaFree(_p)'
  1
  $ printf '%s\n' "$FREE" | grep -c 'cudaFreeHost(_p)'
  1
  $ printf '%s\n' "$FREE" | grep -c '_het_alloc_mode()'
  1
  $ printf '%s\n' "$FREE" | grep -c 'cudaDeviceGetAttribute' || true
  0

(d) __out is gone; the read buffers are device memory, never gd_alloc_shared,
and a shared var is one int slot per iteration (slot-readout.t).
  $ grep -c '__out' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&bufP' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  2
  $ grep -c 'int \*x; gd_alloc_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

(d2) every device allocation is checked: the one bare cudaMalloc is gd_alloc_dev's
own, and the HIP twin's one bare hipMalloc likewise.
  $ grep -c 'cudaMalloc(' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'hipMalloc(' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

The HIP twin renders from the same template: fine-grained hipMallocManaged, no
CUDA-side allocator leaking across the dialects, device gd_alloc_dev, no __out.
  $ sed -n '/^static void gd_alloc_shared/,/^}/p' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip | grep -c 'hipMallocManaged(_pp'
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc|hipHostMalloc|HET_ALLOC_PINNED' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  3
  $ grep -c '__out' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&bufP' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  2

(e) HET_ALLOC on the CUDA render: the knob is read, unset is (c)'s dispatch, and
each of the three preconditions is exit(2) rather than a warning.
  $ REL=MP-cg-sys-relaxed/MP-cg-sys-relaxed
  $ grep -c 'getenv("HET_ALLOC")' $REL.cu
  1
  $ MODE=$(sed -n '/^static int _het_alloc_mode/,/^}/p' $REL.cu)
  $ printf '%s\n' "$MODE" | grep -c '_mode = _pg ? HET_ALLOC_MALLOC : HET_ALLOC_MANAGED;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'exit(2);'
  3
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccess=0'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrConcurrentManagedAccess=0'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrHostNativeAtomicSupported'
  2

(e2) the mode is resolved once and cached, which is what makes (c)'s free rule
sound, and the pinned mode says what it cannot promise.
  $ printf '%s\n' "$MODE" | grep -c 'static int _mode = -1;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'if (_mode >= 0) return _mode;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'a single lost increment leaves it one short of EVERY'
  1

(e3) the banner carries the ATS-vs-HMM discriminator, queried as well as printed,
so a render that kept the text and lost the query is not read as the same box.
  $ printf '%s\n' "$MODE" | grep -c 'HetLitmus: shared-mem mode=%s (HET_ALLOC=%s'
  1
  $ printf '%s\n' "$MODE" | grep -c 'usesHostPageTables=%d concurrentManagedAccess=%d)'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccessUsesHostPageTables'
  1

(f) every branch of the CUDA gd_alloc_shared checks its allocation: the pointer
starts NULL and each of the three failures is a sized FATAL and an exit(2).
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = NULL;'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'HetLitmus FATAL:'
  3
  $ printf '%s\n' "$ALLOC" | grep -c 'exit(2);'
  3

(g) the HIP harness calls it: gd_alloc_shared resolves the mode BEFORE the
allocation it then checks, and the free stays keyed on the resolver.
  $ HREL=hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  $ HALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' $HREL)
  $ printf '%s\n' "$HALLOC" | grep -c '_het_alloc_mode()'
  1
  $ R=$(printf '%s\n' "$HALLOC" | grep -n '_het_alloc_mode()' | head -1 | cut -d: -f1)
  $ A=$(printf '%s\n' "$HALLOC" | grep -n 'hipMallocManaged' | head -1 | cut -d: -f1)
  $ if [ -z "$R" ]; then echo 'NO GUARD IN gd_alloc_shared'
  >   elif [ -z "$A" ]; then echo 'NO hipMallocManaged IN gd_alloc_shared'
  >   elif [ "$R" -lt "$A" ]; then echo 'guard-before-alloc'
  >   else echo 'ALLOCATES BEFORE GUARDING' ; fi
  guard-before-alloc
  $ printf '%s\n' "$HALLOC" | grep -c '\*_pp = NULL;'
  1
  $ printf '%s\n' "$HALLOC" | grep -c 'HetLitmus FATAL:'
  1
  $ printf '%s\n' "$HALLOC" | grep -c 'exit(2);'
  1
  $ sed -n '/^static void gd_free_shared/,/^}/p' $HREL | grep -c '_het_alloc_mode()'
  1
