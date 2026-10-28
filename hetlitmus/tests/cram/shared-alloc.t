Shared-memory allocation guard.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-plain.rlx.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86_64/MP-cg-sys-plain.rlx-x86_64.litmus >/dev/null 2>&1

(a) the shared vars and the barrier go through gd_alloc_shared and gd_free_shared.
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  3
  $ grep -cE 'gd_free_shared\((x|y|barrier)\)' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  3

(b) gd_alloc_shared / gd_free_shared are each defined exactly once (file scope).
  $ grep -c 'static void gd_alloc_shared' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'static void gd_free_shared' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

(c) CUDA: the pageable query picks malloc or managed, each with its matching free.
  $ sed -n '/^static int _shared_pageable/,/^}/p' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu | grep -c 'cudaDevAttrPageableMemoryAccess,'
  1
  $ ALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu)
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = malloc'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaMallocManaged(_pp'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaHostAlloc(_pp'
  1
  $ FREE=$(sed -n '/^static void gd_free_shared/,/^}/p' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu)
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

(d) the read buffers are device memory, never gd_alloc_shared.
  $ grep -c '__out' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&bufP' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  2

(d2) every device allocation is checked.
  $ grep -c 'cudaMalloc(' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'hipMalloc(' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip
  1

The HIP twin: fine-grained hipMallocManaged, nothing CUDA-side.
  $ sed -n '/^static void gd_alloc_shared/,/^}/p' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip | grep -c 'hipMallocManaged(_pp'
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc|hipHostMalloc|HET_ALLOC_PINNED' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip
  3
  $ grep -c '__out' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip || true
  0
  $ grep -c 'gd_alloc_dev((void\*\*)&bufP' hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip
  2

(e) HET_ALLOC: each failed precondition is exit(2), not a warning.
  $ REL=MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx
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

(e2) the mode is resolved once and cached.
  $ printf '%s\n' "$MODE" | grep -c 'static int _mode = -1;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'if (_mode >= 0) return _mode;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'a single lost increment leaves it one short of EVERY'
  1

(e3) the banner carries the ATS-vs-HMM attribute, queried as well as printed.
  $ printf '%s\n' "$MODE" | grep -c 'HetLitmus: shared-mem mode=%s (HET_ALLOC=%s'
  1
  $ printf '%s\n' "$MODE" | grep -c 'usesHostPageTables=%d concurrentManagedAccess=%d)'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccessUsesHostPageTables'
  1

(f) every branch of the CUDA gd_alloc_shared checks its allocation.
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = NULL;'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'HetLitmus FATAL:'
  3
  $ printf '%s\n' "$ALLOC" | grep -c 'exit(2);'
  3

(g) the HIP harness resolves the mode before the allocation it checks.
  $ HREL=hip/MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64.hip
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
