Shared-memory allocation guard (B1; env-research/Q8-allocation.md R1-R4).
The shared litmus vars and the rendezvous barrier route through the per-target
gd_alloc_shared / gd_free_shared allocator, never a hard-coded *MallocManaged.
That allocator SELECTS THE PROPERTY UNDER TEST -- system malloc/ATS cache-line
CHI coherence on GH200, fine-grained hipMallocManaged on MI300A,
cudaMallocManaged only as the dev-box/CI fallback -- so it is correctness, not
tuning.  One representative MP shape is emitted once per dialect (litmus7
renders the one -gpu-target names) and checked with scoped counts.

Two allocation paths exist, so two harnesses are emitted.  409 of the 411 het
tests co-run at least a canary and carve their shared vars out of one
cache-line-padded arena ((f), (g)).  The per-variable path is left to the two
tests that are themselves the Layer-B canary and so cannot co-run themselves,
MP-{cg,gc}-sys-relaxed (control-map.csv: `self'); MP-cg-sys-relaxed guards it.

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and (x86_64, hip) is the one this project has an
MI300A row for (litmus/hetMachine.ml).  The CPU column differs; everything these
sections read is the GPU render and the shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1

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
  $ sed -n '/^static void gd_alloc_shared/,/^}/p' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip | grep -c 'hipMallocManaged(_pp'
  1
  $ grep -cE '_shared_pageable|\*_pp = malloc' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -c 'gd_alloc_shared((void\*\*)&' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  3
  $ grep -c '__out' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -c '(void)hipMalloc(&bufP' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  2

(f) the co-run arena.  A test off the lattice floor co-runs mu(T) and the canary,
and disjoint addresses are not enough: two variables on one cache line are ONE
COHERENCE UNIT, so mu(T)'s traffic would drag T's line around and the control
would perturb the very test it exists to vouch for (Q4-positive-control.md 3.1 /
8.4).  Six separate 8-byte mallocs cannot prevent that; one padded arena can, and
it still goes through gd_alloc_shared with a matching gd_free_shared (B6b).
  $ CO=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ COH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
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
hipMallocManaged): one template, two renders, and the same 6 slots -- this row is
off the lattice floor on BOTH lattices, so both co-run three instances.
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena' $COH.hip
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $COH.hip
  6

(g) the arena is sized from the instance population, not from a fixed 3.  The 78
lattice-floor rows carve a TWO-INSTANCE arena, so a slot count computed for three
instances would either overlap the barrier onto a tested variable (the rendezvous
counter and a litmus location become one coherence unit) or leave the last slot
past the end of the allocation.  Count the slots and pin the size.

2+2W-cg-sys-relaxed is AT the floor -> T + canary, 2 instances, 2 vars each: 4
shared slots + barrier = 5, allocated 6 lines (one line of alignment slack,
because _sa rounds the base up).
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ AC=2+2W-cg-sys-relaxed/2+2W-cg-sys-relaxed
  $ grep -c 'cache-line-padded shared slots: t_x t_y can_x can_y + barrier' $AC.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena, (size_t)HET_CACHE_LINE\*6)' $AC.cu
  1
  $ grep -cE '\(uint64_t\*\)\(_sa \+ \(size_t\)HET_CACHE_LINE\*[0-9]+\)' $AC.cu
  4

...and the three-instance arena of the same shape family is two lines longer,
which is what "sized from the population" means.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acquire.litmus >/dev/null 2>&1
  $ grep -c 'cache-line-padded shared slots: t_x t_y mu_x mu_y can_x can_y + barrier' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_shared_arena, (size_t)HET_CACHE_LINE\*8)' MP-cg-sys-acquire/MP-cg-sys-acquire.cu
  1

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

(i) HET_ALLOC on the HIP render: ONE mode, and every other spelling REFUSED.
MI300A's allocator is its own decision (Q8-allocation.md R2, fine-grained
hipMallocManaged), so the CUDA modes must not LEAK across dialects -- but until
2026-08-03 the .hip did not mention HET_ALLOC at all, which meant
`HET_ALLOC=malloc' on an AMD box was silently IGNORED and the run allocated
managed memory under the name of an experiment it was not running.  Not
mentioning a knob is not the same as refusing it.  The .hip now names HET_ALLOC
only to refuse: no malloc branch, no pinned branch, no second allocator.

  $ HREL=hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  $ grep -c 'getenv("HET_ALLOC")' $HREL
  1
  $ HMODE=$(sed -n '/^static int _het_alloc_mode/,/^}/p' $HREL)

One accepted branch -- unset, auto and managed all resolve to the same
fine-grained hipMallocManaged -- and nothing else does.
  $ printf '%s\n' "$HMODE" | grep -c '_mode = HET_HIP_ALLOC_MANAGED;'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'strcmp(_v, "managed") == 0'
  1

The CUDA-only modes are named in the refusal message and NOWHERE ELSE: no
dispatch, no allocator, no matching free.  A grep for the bare words would pass
on a .hip that had grown a malloc branch, so these are scoped to the calls.
  $ grep -cE '\*_pp = malloc|hipHostMalloc|HET_ALLOC_PINNED|_shared_pageable' $HREL || true
  0

Two exit(2)s guard the device, one guards the knob.  hipMallocManaged DEGRADES
SILENTLY to hipMallocHost when HMM is absent -- hip_runtime_api.h says so, and
asks for the capability check by name -- and pinned host memory is not the
coherent path this harness exists to test.  concurrentManagedAccess is the same
precondition the CUDA render enforces: every het test has the CPU touching the
shared allocation while the kernel is live.
  $ printf '%s\n' "$HMODE" | grep -c 'exit(2);'
  3
  $ printf '%s\n' "$HMODE" | grep -c 'is not a shared-memory mode of the'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'hipDeviceAttributeManagedMemory=0'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'hipDeviceAttributeConcurrentManagedAccess=0'
  1

MI300A vs MI300X.  Both parts report gfx942, so gcnArchName cannot tell them
apart; hipDeviceAttributeIntegrated ("Device is integrated GPU") can.  An APU
whose CCD and XCD chiplets share one HBM pool is not the same experiment as a
discrete accelerator over a host interconnect, so the class is stamped into the
stdout banner -- the run log carries it whether or not anyone reads the source --
and a discrete part is warned about rather than silently accepted.  It is NOT
fatal: MI300X is the Phase-3a bring-up target and must be able to run.
The attribute is QUERIED once and NAMED once, and the two are counted separately:
a bare count of the word passes for a harness that kept the warning text and lost
the query, which is a classification that always answers "APU".
  $ printf '%s\n' "$HMODE" | grep -c '_het_hip_attr(hipDeviceAttributeIntegrated)'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'hipDeviceAttributeIntegrated=0 -- this is a DISCRETE'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'amd_part_class=%s'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'NOT be reported as an MI300A result'
  1
  $ grep -c 'DISCRETE(MI300X-class)' $HREL
  1

The banner is on stdout and precedes the guards, so a FATAL is readable next to
the attributes that caused it -- the same rule as (h).
  $ printf '%s\n' "$HMODE" | grep -c 'HetLitmus: shared-mem mode=managed (HET_ALLOC=%s'
  1

(j) AND THE HARNESS CALLS IT.  Everything in (i) reads the resolver's own body,
which proves it is right and proves nothing about whether it ever runs.  On this
render the resolver's ONLY effect is the guard -- gd_alloc_shared just calls it
for the side effect and throws the value away -- so, unlike the CUDA render whose
gd_alloc_shared DISPATCHES on the returned mode and would not compile without it,
nothing structural holds the call in place.  MEASURED 2026-08-03: deleting that
one statement from het_alloc_hip.inc left this file green, hipbuildcheck at 69/69
PASS and `make hetlitmus-test' green, while the built harness ignored HET_ALLOC
and both device preconditions at allocation time -- the guard would then have
fired in gd_free_shared, after the experiment and after the histogram.  So the
CALL SITE is pinned here too, scoped to the function body.
  $ HALLOC=$(sed -n '/^static void gd_alloc_shared/,/^}/p' $HREL)
  $ printf '%s\n' "$HALLOC" | grep -c '_het_alloc_mode()'
  1

Order is part of the contract -- "resolve + guard once, BEFORE the first alloc".
A call below the allocation still exits(2), but only after the memory it exists
to vet has been handed out.  Compared rather than pinned to line numbers, so a
new comment in the body cannot turn this into a number someone bumps.
  $ R=$(printf '%s\n' "$HALLOC" | grep -n '_het_alloc_mode()' | head -1 | cut -d: -f1)
  $ A=$(printf '%s\n' "$HALLOC" | grep -n 'hipMallocManaged' | head -1 | cut -d: -f1)
  $ if [ -z "$R" ]; then echo 'NO GUARD IN gd_alloc_shared'
  >   elif [ -z "$A" ]; then echo 'NO hipMallocManaged IN gd_alloc_shared'
  >   elif [ "$R" -lt "$A" ]; then echo 'guard-before-alloc'
  >   else echo 'ALLOCATES BEFORE GUARDING' ; fi
  guard-before-alloc

The free stays keyed on the resolver as well, so a second mode could not leave a
mismatched free behind.
  $ sed -n '/^static void gd_free_shared/,/^}/p' $HREL | grep -c '_het_alloc_mode()'
  1

(k) HET_PLACE is a CUDA-only lever and is REFUSED here at compile time.
Placement is cudaMemAdvise/cudaMemPrefetchAsync and lives in het_alloc_cuda.inc;
this render has none.  But HET_PLACE is an #ifndef knob, it is swept by the
tuner, and BOTH dialects print it -- `place=%d' in the cpu-stress banner and
`place_mode' in the statistics record -- because those lines are emitted once for
both.  _het_place_failures has two READERS and no writer on this lane, so
`make hip-bin HIPCC="hipcc -DHET_PLACE=1"' would have logged `place=1 ...
place_fail=0': placement requested, no refusals, nothing placed and nothing
placeable.  A knob read into the log and never applied, with a constant-0
companion so no reader can tell.  Refused at compile time rather than warned
about at run time (the CUDA render's _het_place_inert) because there the mode is
a run-time HET_ALLOC choice and placement genuinely exists in one of the three
modes, whereas here the answer is known when the .hip is compiled.
  $ grep -c '#if (HET_PLACE) != 0' $HREL
  1
  $ grep -c 'HET_PLACE is a CUDA-only lever' $HREL
  1
