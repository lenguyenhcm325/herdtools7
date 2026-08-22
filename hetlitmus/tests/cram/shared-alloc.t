Shared-memory allocation guard (hetlitmus/docs/00-environment-design.md sec 3.2).
The shared litmus vars and the rendezvous barrier route through the per-target
gd_alloc_shared / gd_free_shared allocator, never a hard-coded *MallocManaged.
That allocator SELECTS THE PROPERTY UNDER TEST -- system malloc/ATS cache-line
coherence over the host-device interconnect on the CUDA render, fine-grained
hipMallocManaged on the HIP one, cudaMallocManaged only as the dev-box/CI
fallback -- so it is correctness, not tuning.  One representative MP shape is
emitted once per dialect (litmus7 renders the one -gpu-target names) and checked
with scoped counts.

Every shared location is allocated on its own, one gd_alloc_shared call each,
so the free still matches the allocator.  Two shapes are emitted per dialect,
because a two-sided row and a fully-relaxed one differ in what their CPU column
does and this file reads the driver both carries.

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and a HIP harness is the (x86_64, hip) one.  The
CPU column differs; everything these sections read is the GPU render and the
shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1

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
on a pageable device and the cudaMallocManaged fallback otherwise, with a
matching free (free() for malloc, cudaFree for managed -- a mismatched free is UB).

Each grep is SCOPED to one function body rather than counted file-wide, and that
is the rule everywhere in this file.  A file-wide count cannot discriminate:
the mode banner in (e) queries cudaDevAttrPageableMemoryAccessUsesHostPageTables
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
would first surface on a pageable device.  So each free must be present, the
choice must be _het_alloc_mode(), and no attribute query may survive in the free.
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
-- device memory (cudaMalloc) plus a host mirror for the post-run readout, not
routed through gd_alloc_shared -- while a shared var is one int slot per
iteration (slot-readout.t).
  $ grep -c '__out' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
  $ grep -c 'cudaMalloc(&bufP' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  2
  $ grep -c 'int \*x; gd_alloc_shared' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The HIP twin renders from the same template: gd_alloc_shared is fine-grained
hipMallocManaged (no malloc/ATS dispatch -- an APU's unified HBM pool needs
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

(e) HET_ALLOC: three named modes, resolved once, every illegal one FATAL.
[CudaGuide "Atomicity"] states when a cuda::thread_scope_system atomic actually
is atomic: on system-allocated memory iff pageableMemoryAccess is 1, on
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

(f) HET_ALLOC on the HIP render: ONE mode, and every other spelling REFUSED.
The HIP allocator is its own decision (fine-grained hipMallocManaged,
docs/00-environment-design.md sec 3.2), so the CUDA modes must not leak across
dialects.  A .hip that did not mention HET_ALLOC at all would leave
`HET_ALLOC=malloc' on an AMD box silently ignored, allocating managed memory
under the name of an experiment it was not running: not mentioning a knob is not
the same as refusing it.  So the .hip names HET_ALLOC only to refuse -- no malloc
branch, no pinned branch, no second allocator.

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

Two exit(2)s guard the device, one guards the knob.  hipMallocManaged degrades
SILENTLY to hipMallocHost when HMM is absent -- [HipRuntimeApi] says so, and asks
for the capability check by name -- and pinned host memory is not the
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

Integrated vs discrete.  MI300A and MI300X both report gfx942, so gcnArchName
cannot tell them apart; hipDeviceAttributeIntegrated ("Device is integrated GPU")
can.  An APU whose CCD and XCD chiplets share one HBM pool is not the same
experiment as a discrete accelerator over a host interconnect, so the class is
stamped into the stdout banner -- the run log carries it whether or not anyone
reads the source -- and a discrete part is warned about rather than silently
accepted.  It is NOT fatal: a discrete part is a bring-up target and must be able
to run.
The attribute is QUERIED once and NAMED once, and the two are counted separately:
a bare count of the word passes for a harness that kept the warning text and lost
the query, which is a classification that always answers "APU".
  $ printf '%s\n' "$HMODE" | grep -c '_het_hip_attr(hipDeviceAttributeIntegrated)'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'hipDeviceAttributeIntegrated=0 -- this is a DISCRETE'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'amd_part_class=%s'
  1
  $ printf '%s\n' "$HMODE" | grep -c 'NOT be reported as an integrated-APU result'
  1
  $ grep -c 'DISCRETE(not-integrated)' $HREL
  1

The banner is on stdout and precedes the guards, so a FATAL is readable next to
the attributes that caused it -- the same rule as (e).
  $ printf '%s\n' "$HMODE" | grep -c 'HetLitmus: shared-mem mode=managed (HET_ALLOC=%s'
  1

(g) AND THE HARNESS CALLS IT.  Everything in (f) reads the resolver's own body,
which proves it is right and proves nothing about whether it ever runs.  On this
render the resolver's ONLY effect is the guard -- gd_alloc_shared just calls it
for the side effect and throws the value away -- so, unlike the CUDA render whose
gd_alloc_shared DISPATCHES on the returned mode and would not compile without it,
nothing structural holds the call in place: deleting that one statement from
het_alloc_hip.inc leaves this file, hipbuildcheck and `make hetlitmus-test' green
while the built harness ignores HET_ALLOC and both device preconditions at
allocation time -- the guard then fires in gd_free_shared, after the experiment
and after the histogram.  So the CALL SITE is pinned here too, scoped to the
function body.
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

(h) HET_PLACE is a CUDA-only lever and is REFUSED here at compile time.
Placement is cudaMemAdvise/cudaMemPrefetchAsync and lives in het_alloc_cuda.inc;
this render has none.  But HET_PLACE is an #ifndef knob, it is swept on
hardware, and BOTH dialects print it -- `place=%d' in the cpu-stress banner and
`place_mode' in the statistics record -- because those lines are emitted once for
both.  _het_place_failures has two READERS and no writer on this lane, so
`make hip-bin HIPCC="hipcc -DHET_PLACE=1"' would log `place=1 ... place_fail=0':
placement requested, no refusals, nothing placed and nothing placeable.  A knob read into the log and never applied, with a constant-0
companion so no reader can tell.  Refused at compile time rather than warned
about at run time (the CUDA render's _het_place_inert) because there the mode is
a run-time HET_ALLOC choice and placement genuinely exists in one of the three
modes, whereas here the answer is known when the .hip is compiled.
  $ grep -c '#if (HET_PLACE) != 0' $HREL
  1
  $ grep -c 'HET_PLACE is a CUDA-only lever' $HREL
  1
