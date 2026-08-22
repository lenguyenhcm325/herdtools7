CPU-side + interconnect stress guard (hetlitmus/docs/00-environment-design.md
sec 3.6).
The emitted het harness carries both stress layers in the shape the design
requires: host ISA asm kept out of the nvcc translation unit, the -2s invariants
held by construction, four object classes in four allocators, and the stress
orchestration in the one order that makes it run at all.

Per-device stress widens the INTRA-DEVICE window, while the heterogeneous weak
behaviour lives in the cross-device one -- a store in flight across the
interconnect but not yet globally visible.  CPU cache stress never crosses the
link and GPU scratchpad stress never leaves the die, so Half 2 (placement in
(g), the noise pair in (h))
is the only lever that does.  It is also the methodological addition beyond
[Bagchi26 sec 4.2], which stresses both devices and carries no link-directed
component; its efficacy is an inference, not a measurement, so the claim is
"additive, composable, most specific to the cross-device window", never "more
effective than per-device stress" (docs/00-environment-design.md sec 3.6 bounds
it, and says why it is confounded too).

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and a HIP harness is the (x86_64, hip) one.  The
CPU column differs; everything these sections read is the GPU render and the
shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ MPH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
  $ S=S-cg-sys-fence/S-cg-sys-fence

Counts that a wrong site could satisfy are SCOPED to one function body rather
than raised to a file-wide total: a raised total can be met by a lane that lost
its mechanism while another gained two.  That rule governs every count below.

(a) the host ISA must not reach nvcc.  cpu_thread_P<n> and main() both live in
the .cu -- <test>_cpu.c holds only the opaque tested body -- so the preload
primitives (dc civac / prfm on AArch64, clflush / prefetcht0 on x86) cannot be
emitted at either injection site without making nvcc swallow AArch64 asm on an
x86 build host.  They live in het_cpu_stress.h behind HET_CPU_STRESS_IMPL, which
only <test>_cpu.c defines (gcc, and clang --target=aarch64); the .cu includes the
same header and sees declarations only.
  $ test -f MP-cg-sys-acqrel-2s/het_cpu_stress.h && echo present
  present
  $ grep -c '#define HET_CPU_STRESS_IMPL' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ grep -c '#define HET_CPU_STRESS_IMPL' $MP.cu || true
  0
  $ grep -c '#include "het_cpu_stress.h"' $MP.cu $MPH.hip MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip:1
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c:1

and NO host ISA asm appears in the .cu at all:
  $ grep -cE 'dc civac|prfm |clflush|prefetcht0' $MP.cu || true
  0

(a2) no <pthread.h> in het_cpu_stress.h.  It reaches x86 glibc's
__cleanup_fct_attribute, which is __attribute__((__regparm__(1))), and regparm is
invalid on AArch64; comp.sh cross-assembles <test>_cpu.c and verify/smoke.sh
gates on it, so a stray include fails the smoke gate on every het test.  The
thread bodies need only the pthread entry-point signature; pthread_create is
called from the .cu, which is built for the native host.  The per-header
verification (which includes do survive the cross-compile) is in
litmus/het-runtime/README.md.
  $ grep -c '#include <pthread.h>' MP-cg-sys-acqrel-2s/het_cpu_stress.h || true
  0
  $ grep -c '#include <pthread.h>' $MP.cu
  1

(b) -2s invariant (ii): nothing is injected inside the tested body.  For a
two-sided test the CPU issues the ordering instructions under test (STLR/LDAPR/
DMB.SY) -- they ARE the hypothesis, so a fence or atomic between the two tested
accesses would change what is being tested.  T's own body must stay exactly its
two tested stores, with the preload outside it, before the call.
  $ sed -n '/^void het_run_P0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE '"(stlr|ldapr|dmb|str|ldr)'
  2
  $ sed -n '/^#if defined(__aarch64__)/,/^#else/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE 'het_cpu_preload|het_cpu_affinity|dc civac|prfm' || true
  0

Both tested stores are the release form this two-sided row is about, and nothing
weaker stands in for either.
  $ sed -n '/^void het_run_P0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -coE '"stlr '
  2

The preload is called per iteration, before the tested body, on this proc's own
test variables.  A cache hint changes residency, not program order, so preloading
the very variables under test is -2s-safe -- and it cannot drift into the tested
sequence, because het_run_*_P0 is a call into another translation unit and every
primitive is asm volatile with a "memory" clobber.
  $ sed -n '/^static void\* cpu_thread_P0/,/^}/p' $MP.cu | grep -c 'het_cpu_preload(_pl, 2, &_plrng, HET_CPU_PRELOAD_PCT)'
  1
  $ sed -n '/^static void\* cpu_thread_P0/,/^}/p' $MP.cu | grep -c 'void\* const _pl\[2\] = { (void\*)a->x, (void\*)a->y }'
  1

and affinity is applied BEFORE the rendezvous, so the thread is already on its
core when the race starts:
  $ grep -A2 'static void\* cpu_thread_P0' $MP.cu | grep -c 'het_cpu_affinity(a->_core, a->_tally)'
  1

(c) -2s invariant (i): the enemy and noise traffic is disjoint from the test.  An
enemy that WRITES a test variable injects co/rf edges and the run stops being a
test of the CPU/GPU order ([Sorensen16 sec 1], quoted verbatim in
het_cpu_stress.h).  So no stress object may ever be x, y or barrier.
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(_cpu_scratch|_cpu_idx)' $MP.cu
  2
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(x|y|barrier)' $MP.cu || true
  0
  $ grep -cE '_na\.buf *= *\(volatile const uint64_t\*\)_noise_hbm' $MP.cu
  1

(d) four object classes, four allocators; confusing any two puts stress traffic
on a tested cache line.  The shared test vars and the barrier go through
gd_alloc_shared (coherent -- the property under test); the GPU stress scratchpad
through cudaMalloc (device-only, disjoint); the CPU enemy scratchpad through
plain host malloc (CPU-only, disjoint); and the noise buffers through
gd_alloc_noise (homed on the OTHER processing unit).  The first two classes are
read on this same MP-cg-sys-acqrel-2s render elsewhere -- the shared allocator
and its matching free in shared-alloc.t (a), the GPU scratchpad in stress.t (b).
What is pinned here is the barrier's own allocation, which nothing else reads;
the two CPU-side classes; and the refusal that keeps the enemy scratchpad off
the coherent allocator.
  $ grep -c 'int \*barrier; gd_alloc_shared((void\*\*)&barrier, sizeof(int));' $MP.cu
  1
  $ grep -c 'malloc_check(sizeof(uint64_t)\*HET_CPU_SCRATCH_WORDS)' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_ddr' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_hbm' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_cpu_scratch' $MP.cu || true
  0

(e) the stress orchestration order.  cpustresscheck.py cannot see this property
-- its dynamic probe drives the header's mechanisms with its own flag and never
exercises the emitted driver -- so it is gated here, structurally.  The order IS
the mechanism: raise stress_go, then spawn the enemies and the noise, then the
test threads and the kernel.  A flag raised after the enemies were spawned races
them; one raised after the test finished means they never ran at all.

The test-thread spawn is matched on the wrapper (`, cpu_thread_'), so a shape
with several CPU procs is covered by the same pattern; a pattern that matched
none would leave $TH empty and this guard vacuously true.  First spawn after the
enemies, last spawn before the launch, so the ordering is asserted for every
test thread.
  $ GO=$(grep -n '__atomic_store_n(&_stress_go, 1' $MP.cu | cut -d: -f1)
  $ EN=$(grep -n 'pthread_create(&_eth' $MP.cu | cut -d: -f1)
  $ TH=$(grep -n ', cpu_thread_' $MP.cu | head -1 | cut -d: -f1)
  $ TZ=$(grep -n ', cpu_thread_' $MP.cu | tail -1 | cut -d: -f1)
  $ LA=$(grep -n 'cudaLaunchCooperativeKernel' $MP.cu | cut -d: -f1)
  $ [ -n "$TH" ] && [ -n "$TZ" ] && echo 'test-thread spawns found'
  test-thread spawns found
  $ [ "$GO" -lt "$EN" ] && [ "$EN" -lt "$TH" ] && [ "$TZ" -lt "$LA" ] && echo 'go < enemies < test threads (all) < launch'
  go < enemies < test threads (all) < launch

and it comes down only after the device has drained, so the stress covers the
whole tested window and no more -- the enemy has to run at least as long as the
test.  Lowering it before the sync would stop the stress while
GPU lanes were still looping; never lowering it would hang the join.  The anchor
is the TERMINAL sync -- `cudaError_t _s = cudaDeviceSynchronize()' -- not any
cudaDeviceSynchronize: gd_alloc_noise has its own, one-shot at start-up, waiting
for the prefetch that moves the HBM noise buffer across the interconnect.
  $ SY=$(grep -n '_s = cudaDeviceSynchronize' $MP.cu | cut -d: -f1)
  $ OFF=$(grep -n '__atomic_store_n(&_stress_go, 0' $MP.cu | cut -d: -f1)
  $ JN=$(grep -n 'pthread_join(_eth' $MP.cu | cut -d: -f1)
  $ [ "$SY" -lt "$OFF" ] && [ "$OFF" -lt "$JN" ] && echo 'device sync < lower go < join enemies'
  device sync < lower go < join enemies

(f) sigma is a RUNTIME FIELD, not a -D the compiler can fold.  A compile-time
access pattern lets the compiler fold the stress switch to the one live branch:
on the GPU twin, whose accesses are non-volatile, a branch that writes nothing
then loses its loads to hoisting and the traffic goes with them.  The CPU enemy
has the identical shape, so the -D knob is read host-side and handed over as a
runtime value.  cpustresscheck.py's enemy-seq-runtime check gates the compiled
consequence: the op count must be invariant under -DHET_CPU_ENEMY_SEQ.
  $ grep -c '_ea\[_e\].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;' $MP.cu
  1
  $ grep -c 'switch (a->seq)' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

and the enemy's accesses are `volatile' -- without it the compiler deletes the
read side of every pattern (sigma 3 becomes a no-op) and collapses sigma 0's
double store.
  $ grep -c 'volatile uint64_t \*l = a->scratch' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

(g) Half 2a -- placement, at the seam inside gd_alloc_shared's system-malloc
branch.  A cudaMemAdvise that is REFUSED must never be swallowed: a placement
knob that says "remote" while the pages sat where first touch left them is an
inert mechanism reporting itself as live.
  $ grep -c 'cudaMemAdviseSetPreferredLocation' $MP.cu
  1
  $ grep -c 'cudaMemAdviseSetAccessedBy' $MP.cu
  2
  $ grep -c '_het_place(\*_pp, _bytes, HET_PLACE)' $MP.cu
  1
  $ grep -c '_het_place_failures++' $MP.cu
  2

The default is 0 = first-touch, deliberately (het_alloc_cuda.inc says why): the
net effect of pinning is confounded, since it widens the window but slows the
loop, so sightings = yield x rate could move either way and nobody has measured
it.
  $ grep -A1 '#ifndef HET_PLACE' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_PLACE 0'
  1

The HIP twin has NO placement, and that is a finding rather than an omission:
the render has no page-placement API to call, and an APU such as MI300A has one
HBM pool shared by the CCD and XCD chiplets -- no LPDDR/HBM split, nothing to
place.  Its analogue is cross-chiplet contention, which the same noise pair
provides.  The grep matches the API call, not the word: the .hip explains at
length why there is no cudaMemAdvise here, so a bare `MemAdvise' count would be
satisfied by the prose that documents its absence.
  $ grep -cE '(cuda|hip)MemAdvise\(' $MPH.hip || true
  0
  $ grep -cE '(cuda|hip)MemAdvise\(' $MP.cu
  3
  $ grep -c 'CONTENTION' $MPH.hip
  2

(h) Half 2b -- the noise pair of [Fusco24 sec III-E.1], its construction quoted
verbatim in het_cpu_stress.h: each processing unit continuously stream-reads the
OTHER one's memory.  The device half runs as extra blocks of the persistent grid,
never as a second __global__, because ptxcheck scans the whole PTX file in flat
order and slices that one op stream per lane -- a second kernel would drop its
ops into the middle of the stream being sliced.
  $ grep -c '__global__' $MP.cu
  1
  $ grep -c 'blockIdx.x < HET_TEST_BLOCKS + _noise_blocks' $MP.cu
  1
  $ grep -c 'volatile const uint64_t\* _nb = (volatile const uint64_t\*)_noise_ddr' $MP.cu
  1
  $ grep -c 'pthread_create(&_nth, NULL, het_cpu_noise, &_na)' $MP.cu
  1

The working set is the whole point: a buffer that fits in cache is served from
cache and crosses nothing.  HET_NOISE_MB is 8 GB per buffer, HET_LLC_MB is the
threshold it must exceed, and a sub-LLC configuration is warned about at run
time.
  $ grep -A1 '#ifndef HET_NOISE_MB' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_NOISE_MB 8192'
  1
  $ grep -c 'HET_NOISE_MB < HET_LLC_MB' $MP.cu
  1

HET_LLC_MB is supplied per build (NVCC="nvcc -DHET_LLC_MB=<MB>").  Both branches
of the header define HET_LLC_MB_IS_FALLBACK -- an undefined macro reads as 0
under #if -- and the driver carries both arms of the warning, the fallback one
disclosing that the default was measured on another part.
  $ grep -c '^#define HET_LLC_MB_IS_FALLBACK' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  2
  $ grep -c '#if HET_LLC_MB_IS_FALLBACK' $MP.cu
  1
  $ grep -c 'a FALLBACK figure, measured on another part' $MP.cu
  1

(h2) and the noise buffer must be real memory.  A malloc'd buffer that has never
been WRITTEN is not backed by physical memory at all -- Linux maps every
untouched anonymous page to one shared, read-only zero page -- so a noise kernel
reading an 8 GB buffer that was never first-touched touches a single cache line,
is served entirely from L1, and generates no interconnect traffic while reporting
healthy round counts (het_cpu_stress.h carries the figures).  So both renders
fault the pages in, and cpustresscheck.py's first-touch check proves at run time
that it works.
  $ grep -c 'het_cpu_first_touch(\*_pp, _bytes)' $MP.cu
  2
  $ grep -c 'het_cpu_first_touch(\*_pp, _bytes)' $MPH.hip
  1

and on a CUDA render the CPU's first touch homes the pages on DDR, so the buffer
that must live on HBM -- the one the host thread streams, so each read crosses
the interconnect -- is prefetched across; a refusal is reported, because an "HBM"
buffer that is really on DDR generates local traffic, not interconnect traffic.
  $ grep -c 'cudaMemPrefetchAsync(\*_pp, _bytes, 0, 0)' $MP.cu
  1
  $ grep -c 'cudaMemPrefetchAsync of the HBM noise buffer FAILED' $MP.cu
  1

(i) liveness is REPORTED, because nothing in this layer is visible to a
structural gate and a layer that has silently stopped working looks exactly like
one that is working.  Every counter below exists because its mechanism has a way
to die.
  $ grep -c 'HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds' $MP.cu
  1
  $ grep -c 'ZERO preload hints were issued' $MP.cu
  1
  $ grep -c '%s of the %s noise did NOT run.  This run is not interconnect-stressed' $MP.cu
  1
  $ grep -c 'sched_setaffinity call(s) FAILED' $MP.cu
  1
  $ sed -n '/^static void het_obs_record_print/,/^}/p' MP-cg-sys-acqrel-2s/het_verdict.h | grep -c 'enemies=%u enemy_rounds=%llu'
  1

and the two knobs the interconnect lever is driven with travel WITH the result.
The working set is what decides whether the noise crosses anything at all --
below the last-level cache the buffer is served from cache -- so a log that does
not record it cannot tell a good config from a dead stressor.
  $ grep -c 'noise_ws=%uMB place=%u' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c '_rec.noise_ws_mb = (uint32_t)HET_NOISE_MB' $MP.cu
  1

(j) the sources are cited in the emitted header, not merely in a commit message:
we reuse this work, and for [CudaLitmus], which carries no licence file, citation
is the condition of that reuse.  A reader must be able to tell which ideas are
ours.
  $ grep -c '\[Alglave11' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  4
  $ grep -c '\[Sorensen16' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  6
  $ grep -c '\[Fusco24' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  3
  $ grep -c '\[Schieffer24' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1
  $ grep -c '\[Wahlgren25' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1
  $ grep -c 'an INFERENCE, and a confounded one' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

(k) the observer test renders the same shape: the observer is PINNED but not
preloaded, because its job is to sample the shared locations densely and a cache
hint per iteration would only thin the sampling (same reason the GPU observer
lane gets no pre-stress; stress.t (g)).

The preload check is a negative (expects 0), and a negative whose anchor matches
nothing reports 0 and "passes" while checking nothing, so it is paired with a
positive on the worker thread: the asymmetry (worker preloads, observer does
not) is the invariant, and pinning one side of it alone can go vacuous
unnoticed.
  $ grep -A2 'static void\* cpu_obs_thread' $S.cu | grep -c 'het_cpu_affinity(a->_core, a->_tally)'
  1
  $ grep -A4 'static void\* cpu_obs_thread' $S.cu | grep -c 'het_cpu_preload' || true
  0

The worker DOES preload -- so the 0 above is a real absence, not a failed match.
  $ awk '/^static void\* cpu_thread_P0\(void\* _a\)/,/^}$/' $S.cu | grep -c 'het_cpu_preload'
  1
