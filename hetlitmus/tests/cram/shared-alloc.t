Shared-memory allocation guard (B1; env-research/Q8-allocation.md R1-R4).
The shared litmus vars and the rendezvous barrier route through the per-target
gd_alloc_shared / gd_free_shared allocator, never a hard-coded *MallocManaged.
That allocator SELECTS THE PROPERTY UNDER TEST -- system malloc/ATS cache-line
CHI coherence on GH200, fine-grained hipMallocManaged on MI300A,
cudaMallocManaged only as the dev-box/CI fallback -- so it is correctness, not
tuning.  One representative MP shape is emitted in both dialects and checked
with scoped counts.

Two allocation paths exist, so two harnesses are emitted.  448 of the 450 het
tests co-run at least a canary and carve their shared vars out of one
cache-line-padded arena ((f), (g)).  The per-variable path is left to the two
tests that are themselves the Layer-B canary and so cannot co-run themselves,
MP-{cg,gc}-sys-relaxed (control-map.csv: `self'); MP-cg-sys-relaxed guards it.

  $ litmus7 -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1

Single-instance means no arena, so the per-variable calls below are the ones
this harness actually makes.
  $ grep -c '#define HET_CANARY_COMPILED_IN 0' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_shared_arena' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0

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

(c) CUDA dispatch: query cudaDevAttrPageableMemoryAccess, take the malloc branch
on a pageable device (GH200) and the cudaMallocManaged fallback otherwise, with a
matching free (free() for malloc, cudaFree for managed -- a mismatched free is UB).

Each grep is SCOPED to one function body rather than counted file-wide, and that
is the rule everywhere in this file.  A file-wide count no longer discriminates:
the mode banner in (h) queries cudaDevAttrPageableMemoryAccessUsesHostPageTables
-- a different attribute whose name CONTAINS this one -- and the mode resolver's
FATAL message names the attribute in prose, so raising the expectation to absorb
them lets the check pass for a harness that has lost the dispatch query entirely.
The trailing comma is required for the same reason: the UsesHostPageTables
spelling cannot produce it.
  $ sed -n '/^static int _shared_pageable/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | grep -c 'cudaDevAttrPageableMemoryAccess,'
  1
  $ ALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu)
  $ printf '%s\n' "$ALLOC" | grep -c '\*_pp = malloc'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaMallocManaged(_pp'
  1
  $ printf '%s\n' "$ALLOC" | grep -c 'cudaHostAlloc(_pp'
  1

Three allocators, so three matching frees -- all selected by the one cached mode,
never by a second device query.  Drift between the alloc-time and the free-time
answer (a forced HET_ALLOC, a second device) would free a malloc'd pointer with
cudaFree: undefined behaviour that need not fault on the managed dev-box path and
would first surface on GH200.  So each free must be present, the choice must be
_het_alloc_mode(), and no attribute query may survive in the free.
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

(d) __out is gone and the per-load read buffers sit off the concurrent-race path
-- device memory (cudaMalloc) plus a host mirror for the post-run scan, not
routed through gd_alloc_shared -- while the shared vars are uint64_t (B3).
  $ grep -c '__out' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
  $ grep -c 'cudaMalloc(&bufP' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  2
  $ grep -c 'uint64_t \*x; gd_alloc_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

(e) no banner claims *MallocManaged is "CPU/GPU-coherent" on GH200: managed
memory there is software page migration, not the hardware cache-line coherence
under test (Q8-allocation.md F1).  The banner that does print is (h)'s, and it
prints measured attributes.
  $ grep -c 'CPU/GPU-coherent on GH200' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0

The HIP twin renders from the same template: gd_alloc_shared is fine-grained
hipMallocManaged (no malloc/ATS dispatch -- MI300A's unified HBM pool needs
none), and the read buffers are device hipMalloc, no __out.  Scoped to
gd_alloc_shared's body for the same reason as (c).
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

(f) the co-run arena.  A should-be-forbidden test co-runs mu(T) and the canary,
and disjoint addresses are not enough: two variables on one cache line are ONE
COHERENCE UNIT, so mu(T)'s traffic would drag T's line around and the control
would perturb the very test it exists to vouch for (Q4-positive-control.md 3.1 /
8.4).  Six separate 8-byte mallocs cannot prevent that; one padded arena can, and
it still goes through gd_alloc_shared with a matching gd_free_shared (B6b).
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

The arena is not plain malloc: that is the enemy-scratchpad class (host-only,
disjoint), and putting the tested locations there would take them off the
coherent path entirely, leaving the harness testing nothing.
  $ grep -c 'malloc_check(.*_shared_arena' $CO.cu || true
  0

The HIP twin carves the same arena from its own gd_alloc_shared (fine-grained
hipMallocManaged): one template, two renders.
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena' $CO.hip
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $CO.hip
  6

(g) the arena is sized from the instance population, not from a fixed 3.  The 395
canary-only harnesses carve a TWO-INSTANCE arena, so a slot count computed for
three instances would either overlap the barrier onto a tested variable (the
rendezvous counter and a litmus location become one coherence unit) or leave the
last slot past the end of the allocation.  Count the slots and pin the size.

MP-cg-sys-acquire is Allowed -> T + canary, 2 instances, 2 vars each: 4 shared
slots + barrier = 5, allocated 6 lines (one line of alignment slack, because _sa
rounds the base up).
  $ litmus7 -o . ../het/MP-cg-sys-acquire.litmus >/dev/null 2>&1
  $ AC=MP-cg-sys-acquire/MP-cg-sys-acquire
  $ grep -c 'cache-line-padded shared slots: t_x t_y can_x can_y + barrier' $AC.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena, (size_t)HET_CACHE_LINE\*6)' $AC.cu
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $AC.cu
  4

The barrier gets its own line, past the last variable, never sharing one with a
tested location.
  $ grep -c 'int \*barrier = (int\*)(_sa + (size_t)HET_CACHE_LINE\*4);' $AC.cu
  1

(h) HET_ALLOC: three named modes, resolved once, every illegal one FATAL (PORT1).
The CUDA Programming Guide 5.7.3 states when a cuda::thread_scope_system atomic
actually is atomic: on system-allocated memory iff pageableMemoryAccess is 1, on
managed memory iff concurrentManagedAccess is 1, on mapped memory iff
hostNativeAtomicSupported is 1 (plain naturally-aligned 1/2/4/8/16-byte
loads/stores on mapped memory are the one exception).  Every tested access here,
and the rendezvous barrier, is such an atomic, so a mode whose condition does not
hold is not a weaker experiment -- it is undefined, and its histogram means
nothing.  Hence exit(2), never a warning and never a silent fallback to auto.

  $ REL=MP-cg-sys-relaxed/MP-cg-sys-relaxed
  $ grep -c 'getenv("HET_ALLOC")' $REL.cu
  1
  $ MODE=$(sed -n '/^static int _het_alloc_mode/,/^}/p' $REL.cu)

Unset/auto is exactly the pageable-vs-managed dispatch of (c), so a bare run
stays byte-for-byte the pre-HET_ALLOC behaviour and every null recorded before it
sits on the same footing.
  $ printf '%s\n' "$MODE" | grep -c '_mode = _pg ? HET_ALLOC_MALLOC : HET_ALLOC_MANAGED;'
  1

Resolved once and cached -- the early return is what makes (c)'s free rule sound.
  $ printf '%s\n' "$MODE" | grep -c 'static int _mode = -1;'
  1
  $ printf '%s\n' "$MODE" | grep -c 'if (_mode >= 0) return _mode;'
  1

Three exit(2)s in the resolver, one per precondition above: an unknown knob
value, malloc without pageable access, managed without concurrent access.
  $ printf '%s\n' "$MODE" | grep -c 'exit(2);'
  3
  $ printf '%s\n' "$MODE" | grep -c 'is not a shared-memory mode'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccess=0'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrConcurrentManagedAccess=0'
  1

pinned is permitted without native host atomics -- it is the escape hatch for a
box that has neither of the other two -- but it says what it cannot promise: the
plain tested accesses stand, the barrier's read-modify-write does not.
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrHostNativeAtomicSupported'
  2
  $ printf '%s\n' "$MODE" | grep -c 'the run can hang at'
  1

The banner is the ATS-vs-HMM discriminator (usesHostPageTables: 1 = hardware
coherence, 0 = software), printed before the guards so a FATAL is readable, and
on stdout so the run log carries it.
  $ printf '%s\n' "$MODE" | grep -c 'HetLitmus: shared-mem mode=%s (HET_ALLOC=%s'
  1
  $ printf '%s\n' "$MODE" | grep -c 'usesHostPageTables=%d concurrentManagedAccess=%d)'
  1
  $ printf '%s\n' "$MODE" | grep -c 'cudaDevAttrPageableMemoryAccessUsesHostPageTables'
  1

The HIP render is deliberately out of scope: MI300A's allocator is its own
decision (Q8-allocation.md R2, fine-grained hipMallocManaged), and HET_ALLOC
appearing in the .hip would mean the modes leaked across dialects.
  $ grep -c 'HET_ALLOC' $REL.hip || true
  0
