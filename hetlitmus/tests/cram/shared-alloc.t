B1 regression guard: the shared litmus vars + the rendezvous barrier must go
through the per-target gd_alloc_shared / gd_free_shared allocator (Q8 R1/R2/R4),
NOT the old hard-coded *MallocManaged.  The allocator SELECTS THE PROPERTY UNDER
TEST (system malloc/ATS cache-line CHI coherence on GH200; fine-grained
hipMallocManaged on MI300A; cudaMallocManaged only as the dev-box/CI fallback), so
this is correctness, not tuning.  We emit the representative MP shape once (both
.cu and .hip) and assert the structural invariants with robust counts.

THE REPRESENTATIVE FOR THE PER-VARIABLE PATH IS NOW MP-cg-sys-RELAXED.

B6b co-ran mu(T) + canary on the 16 Disallowed tests, which carve their shared vars
out of ONE cache-line-padded arena (guarded in (f) below).  This file then picked
MP-cg-sys-ACQUIRE to keep guarding the per-variable path, on the reasoning that it was
"still what 322 of the 338 het harnesses use".

B6c MAKES THAT REASONING FALSE, and the honest move is to say so rather than to leave
the guard pointing at a harness that no longer takes the path.  Every test that has a
canary to co-run now co-runs one (Q4 R5), so 336 of the 338 take the ARENA.  The only
harnesses still on the per-variable path are the two that ARE the Layer-B canary and so
cannot co-run themselves -- MP-{cg,gc}-sys-relaxed (control-map.csv: `self').  The
guard therefore MOVES to one of them, at full strength, rather than being deleted or
loosened.  The path is still live, still emitted, and still checked; it is simply no
longer the common case.

  $ litmus7 -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1

It really is single-instance: no co-run, so no arena, so the per-variable calls below
are the ones this harness actually makes.
  $ grep -c '#define HET_CANARY_COMPILED_IN 0' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_shared_arena' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0

(a) the shared vars (x, y) AND the barrier route through gd_alloc_shared (3 call
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

(c) CUDA dispatch: query cudaDevAttrPageableMemoryAccess, take the malloc branch on
a pageable device (GH200) and the cudaMallocManaged fallback otherwise, with a
MATCHING free (free() for malloc, cudaFree for managed -- a mismatched free is UB).

Each grep below is SCOPED to gd_alloc_shared's own body.  B5 added gd_alloc_noise,
which makes the same pageable-vs-managed dispatch for a different object class (the
C2C noise buffers), so a file-wide count would now read 2 -- and bumping it to 2
would have made this check satisfiable by a SECOND allocator sneaking into
gd_alloc_shared, which is the very confusion it exists to prevent.  Scope, don't bump.

PORT1 makes the same point a second time, and harder.  The mode banner queries
cudaDevAttrPageableMemoryAccessUsesHostPageTables -- a DIFFERENT attribute whose name
CONTAINS the one below -- so the old file-wide count now reads 4.  Bumping it to 4
would have made this check pass for a harness that had lost the dispatch query
entirely and gained four mentions of the ATS/HMM discriminator.  Scope it to
_shared_pageable's own body and require the comma that closes the argument, which the
UsesHostPageTables spelling cannot produce.
  $ sed -n '/^static int _shared_pageable/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | grep -c 'cudaDevAttrPageableMemoryAccess,'
  1
  $ ALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu)
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = malloc'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaMallocManaged(_pp'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaHostAlloc(_pp'
  1

THREE allocators now, so THREE matching frees -- and all three selected by the ONE
cached mode, never by a second device query.  gd_free_shared used to RE-QUERY
cudaDevAttrPageableMemoryAccess, so any drift between the alloc-time and the
free-time answer (a forced HET_ALLOC, a second device) would free a malloc'd pointer
with cudaFree: UB that need not fault on the managed dev-box path and would first
surface on GH200.  The old one-line regex `free(_p).*cudaFree(_p)' only ever checked
that two frees shared a source line, which the switch does not do; assert instead
that each free is present, that the choice is _het_alloc_mode(), and that no
attribute query survives in the free.
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

(d) B3: __out is gone; the per-load read buffers are OFF the concurrent-race path
-- device memory (cudaMalloc) + a host mirror for the post-run scan -- NOT routed
through gd_alloc_shared, and the shared vars are widened to uint64_t.
  $ grep -c '__out' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
  $ grep -c 'cudaMalloc(&bufP' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  2
  $ grep -c 'uint64_t \*x; gd_alloc_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

(e) the design-doc-flagged wrong banner ("*MallocManaged (CPU/GPU-coherent ...)")
is gone.
  $ grep -c 'CPU/GPU-coherent on GH200' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0

The HIP twin renders from the same template: gd_alloc_shared is fine-grained
hipMallocManaged (no malloc/ATS dispatch -- MI300A's unified HBM pool needs none),
and the read buffers are device hipMalloc (off the race path), no __out.  Scoped to
gd_alloc_shared's body for the same reason as (c): B5's gd_alloc_noise allocates the
C2C noise buffers the same way, and a file-wide count would stop discriminating.
  $ sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip | grep -c 'hipMallocManaged(_pp'
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc' MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  3
  $ grep -c '__out' MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip || true
  0
  $ grep -c '(void)hipMalloc(&bufP' MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
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

(g) B6c -- THE ARENA IS SIZED FROM THE INSTANCE POPULATION, NOT FROM THE NUMBER 3.
The 320 canary-only harnesses carve a TWO-instance arena, and this is the case the
B6b code was never asked to produce.  A slot count still computed for three instances
would either overlap the barrier onto a tested variable (silent, catastrophic: the
rendezvous counter and a litmus location become ONE coherence unit) or leave the
last slot past the end of the allocation.  Count the slots and pin the size.

MP-cg-sys-acquire is Allowed -> T + canary, 2 instances, 2 vars each: 4 shared slots
+ barrier = 5, allocated 6 lines (one line of alignment slack, because _sa rounds the
base UP).
  $ litmus7 -o . ../het/MP-cg-sys-acquire.litmus >/dev/null 2>&1
  $ AC=MP-cg-sys-acquire/MP-cg-sys-acquire
  $ grep -c 'cache-line-padded shared slots: t_x t_y can_x can_y + barrier' $AC.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena, (size_t)HET_CACHE_LINE\*6)' $AC.cu
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $AC.cu
  4

The barrier gets its OWN line, past the last variable -- never sharing one with a
tested location.
  $ grep -c 'int \*barrier = (int\*)(_sa + (size_t)HET_CACHE_LINE\*4);' $AC.cu
  1

(h) PORT1 -- HET_ALLOC: THREE NAMED MODES, RESOLVED ONCE, EVERY ILLEGAL ONE FATAL.
The CUDA C++ Memory Model states when a cuda::thread_scope_system atomic actually is
atomic: on system-allocated memory iff pageableMemoryAccess is 1, on managed memory
iff concurrentManagedAccess is 1, on mapped memory iff hostNativeAtomicSupported is 1
(plain naturally-aligned loads/stores of <= 16 bytes on mapped memory are the one
exception).  Every tested access here, and the rendezvous barrier, IS such an atomic.
So a mode whose condition does not hold is not a weaker experiment -- it is
undefined, and the histogram it produces means nothing.  exit(2), not a warning, and
never a silent fallback to auto.

  $ REL=MP-cg-sys-relaxed/MP-cg-sys-relaxed
  $ grep -c 'getenv("HET_ALLOC")' $REL.cu
  1
  $ MODE=$(sed -n '/^static int _het_alloc_mode/,/^}/p' $REL.cu)

Unset/auto is EXACTLY the B1 dispatch.  A bare run must stay byte-for-byte the old
behaviour, or every null recorded before PORT1 sits on a different footing.
  $ printf '%s\n' "$MODE" | grep -c '_mode = _pg ? HET_ALLOC_MALLOC : HET_ALLOC_MANAGED;'
  1

Resolved once and cached -- the early return is what makes (c)'s free rule sound.
  $ printf '%s\n' "$MODE" | grep -c 'static int _mode = -1;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'if (_mode >= 0) return _mode;'
  1

Three exit(2)s in the resolver: an unknown knob value, malloc without pageable
access, managed without concurrent access.
  $ printf '%s\n' "$MODE" | grep -c 'exit(2);'
  3
  $ printf '%s\n' "$MODE" | grep -c 'is not a shared-memory mode'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccess=0'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrConcurrentManagedAccess=0'
  1

pinned is PERMITTED without native host atomics -- it is the escape hatch for a box
that has neither of the other two -- but it says what it cannot promise: the plain
tested accesses stand, the barrier's read-modify-write does not.
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrHostNativeAtomicSupported'
  2
  $ printf '%s\n' "$MODE" | grep -c 'the run can hang at'
  1

The banner is the ATS-vs-HMM discriminator (usesHostPageTables: 1 = hardware
coherence, 0 = software), printed BEFORE the guards so a FATAL is readable, and on
stdout so the run log carries it.
  $ printf '%s\n' "$MODE" | grep -c 'HetLitmus: shared-mem mode=%s (HET_ALLOC=%s'
  1
  $ printf '%s\n' "$MODE" | grep -c 'usesHostPageTables=%d concurrentManagedAccess=%d)'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccessUsesHostPageTables'
  1

THE HIP RENDER IS NOT IN SCOPE.  MI300A's allocator is its own decision (Q8 R2,
fine-grained hipMallocManaged) and PORT1 did not touch it; HET_ALLOC appearing in the
.hip would mean the modes leaked across dialects.
  $ grep -c 'HET_ALLOC' $REL.hip || true
  0
