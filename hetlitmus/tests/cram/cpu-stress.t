B5 regression guard: the emitted het harness must carry the CPU-side stress layer
AND the interconnect (C2C) stress layer, in the shape the design requires -- host
ISA asm kept out of the nvcc translation unit; the -2s invariants held by
construction; four object classes in four allocators; and the stress orchestration
in the one order that makes it run at all.

B4 gave the GPU its stress layer.  Q6's central transfer finding is that this is
not enough: per-device stress widens the INTRA-device window, while the
heterogeneous weak behaviour lives in the CROSS-device one -- a store in flight
across C2C but not yet globally visible.  CPU cache stress never crosses the link;
GPU scratchpad stress never leaves the die.  The two levers that do are here.

Half 2 is also the thesis's methodological addition beyond Bagchi et al. (ISMM'26),
who stressed each device independently -- "Each was executed millions of times with
memory stressing [21] on both devices" -- with no link-directed component anywhere
in the paper.  Its EFFICACY, however, is an inference, not a measurement: Fusco
measured bandwidth, never weak-behaviour yield, and remote placement also slows the
loop.  The claim is "additive, composable, most specific to the cross-device
window" -- never "more effective than per-device stress".

  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ S=S-cg-sys-fence/S-cg-sys-fence

(a) THE HOST ISA MUST NOT REACH NVCC.  cpu_thread_P<n> and main() both live in the
.cu -- <test>_cpu.c holds only the opaque tested body -- so the M3 preload
primitives (dc civac / prfm on AArch64, clflush / prefetcht0 on x86) cannot be
emitted at either injection site: nvcc would have to swallow AArch64 asm on an x86
build host.  They live in het_cpu_stress.h, whose BODIES are behind
HET_CPU_STRESS_IMPL -- defined by <test>_cpu.c (gcc, and clang --target=aarch64)
and by nothing else.  The .cu includes the same header and sees declarations only.
  $ test -f MP-cg-sys-acqrel-2s/het_cpu_stress.h && echo present
  present
  $ grep -c '#define HET_CPU_STRESS_IMPL' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ grep -c '#define HET_CPU_STRESS_IMPL' $MP.cu || true
  0
  $ grep -c '#include "het_cpu_stress.h"' $MP.cu $MP.hip MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip:1
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c:1

and NO host ISA asm appears in the .cu at all:
  $ grep -cE 'dc civac|prfm |clflush|prefetcht0' $MP.cu || true
  0

(a2) NO <pthread.h> IN het_cpu_stress.h.  Verified, not assumed: <sched.h>,
<stdio.h>, <stdlib.h>, <string.h> and <unistd.h> all survive
`clang --target=aarch64-linux-gnu -c', but <pthread.h> does NOT -- it reaches x86
glibc's __cleanup_fct_attribute, which is __attribute__((__regparm__(1))), and
regparm is invalid on AArch64.  comp.sh cross-assembles <test>_cpu.c and smoke.sh
gates on it, so a stray include here fails the smoke gate on all 338 het tests.
The thread bodies need only the pthread entry-point signature; pthread_create is
called from the .cu, which is built for the native host.
  $ grep -c '#include <pthread.h>' MP-cg-sys-acqrel-2s/het_cpu_stress.h || true
  0
  $ grep -c '#include <pthread.h>' $MP.cu
  1

(b) -2s INVARIANT (ii): NOTHING IS INJECTED INSIDE THE TESTED BODY.  For a
two-sided test the CPU issues the ordering instructions under test (STLR/LDAPR/
DMB.SY) -- they ARE the hypothesis, so a fence or atomic between the two tested
accesses would change what is being tested.  het_run_P0 must therefore still be
exactly its two tested stores, and the preload must sit OUTSIDE it, before the call.
  $ sed -n '/^#if defined(__aarch64__)/,/^#else/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE '"(stlr|ldapr|dmb|str|ldr)'
  2
  $ sed -n '/^#if defined(__aarch64__)/,/^#else/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE 'het_cpu_preload|het_cpu_affinity|dc civac|prfm' || true
  0

The preload is called per iteration, before het_run_P0, on THIS proc's own test
variables.  A cache hint changes RESIDENCY, not program order, so preloading the
very variables under test is -2s-safe -- and it cannot drift into the tested
sequence, because het_run_P0 is a call into another translation unit and every
primitive is asm volatile with a "memory" clobber.
  $ grep -A2 'for (int _n=0; _n<SIZE_OF_TEST; ++_n) {' $MP.cu | grep -c 'het_cpu_preload(_pl, 2, &_plrng, HET_CPU_PRELOAD_PCT)'
  1
  $ grep -c 'void\* const _pl\[2\] = { (void\*)a->x, (void\*)a->y }' $MP.cu
  1

and affinity is applied BEFORE the rendezvous, so the thread is already on its core
when the race starts:
  $ grep -A2 'static void\* cpu_thread_P0' $MP.cu | grep -c 'het_cpu_affinity(a->_core, a->_tally)'
  1

(c) -2s INVARIANT (i): THE ENEMY AND NOISE TRAFFIC IS DISJOINT FROM THE TEST.  An
enemy that WRITES a test variable injects co/rf edges and the run stops being a test
of the CPU/GPU order.  S&D, verbatim: "Because the stressing threads and memory are
disjoint from application threads and data, the set of possible behaviours a program
can exhibit remains the same."  So no stress object may ever be x, y or barrier.
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(_cpu_scratch|_cpu_idx)' $MP.cu
  2
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(x|y|barrier)' $MP.cu || true
  0
  $ grep -cE '_na\.buf *= *\(volatile const uint64_t\*\)_noise_hbm' $MP.cu
  1

(d) FOUR OBJECT CLASSES, FOUR ALLOCATORS.  Each of the four existed as a bug once,
and confusing any two puts stress traffic on a tested cache line.  The shared test
vars and the barrier go through gd_alloc_shared (coherent -- the property under
test); the GPU stress scratchpad through cudaMalloc (device-only, disjoint); the CPU
enemy scratchpad through plain host malloc (CPU-only, disjoint -- new in B5); and the
noise buffers through gd_alloc_noise (homed on the OTHER processing unit -- new in
B5).
  $ grep -c 'gd_alloc_shared((void\*\*)&' $MP.cu
  3
  $ grep -c 'cudaMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MP.cu
  1
  $ grep -c 'malloc_check(sizeof(uint64_t)\*HET_CPU_SCRATCH_WORDS)' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_ddr' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_hbm' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_cpu_scratch' $MP.cu || true
  0

(e) THE STRESS ORCHESTRATION ORDER.  This is the one property cpustresscheck.py
CANNOT see -- its dynamic probe drives the header's mechanisms with its own flag and
never exercises the emitted driver -- so it is gated here, structurally.  The order
IS the mechanism: raise stress_go, THEN spawn the enemies and the noise, THEN the
test threads and the kernel.  A flag raised after the enemies were spawned races
them; one raised after the test finished means they never ran at all, which is
precisely the failure B4 shipped twice.
  $ GO=$(grep -n '__atomic_store_n(&_stress_go, 1' $MP.cu | cut -d: -f1)
  $ EN=$(grep -n 'pthread_create(&_eth' $MP.cu | cut -d: -f1)
  $ TH=$(grep -n 'pthread_create(&_th0' $MP.cu | cut -d: -f1)
  $ LA=$(grep -n 'cudaLaunchCooperativeKernel' $MP.cu | cut -d: -f1)
  $ [ "$GO" -lt "$EN" ] && [ "$EN" -lt "$TH" ] && [ "$TH" -lt "$LA" ] && echo 'go < enemies < test threads < launch'
  go < enemies < test threads < launch

and it comes DOWN only after the device has drained, so the stress covers the whole
tested window and no more (S&D knob F: the enemy runs at least as long as the test).
Lowering it before the sync would stop the stress while GPU lanes were still
looping; never lowering it would hang the join.
(The anchor is the TERMINAL sync -- `cudaError_t _s = cudaDeviceSynchronize()' -- not
any cudaDeviceSynchronize: gd_alloc_noise has its own, one-shot at start-up, waiting
for the prefetch that moves the HBM noise buffer across the interconnect.)
  $ SY=$(grep -n '_s = cudaDeviceSynchronize' $MP.cu | cut -d: -f1)
  $ OFF=$(grep -n '__atomic_store_n(&_stress_go, 0' $MP.cu | cut -d: -f1)
  $ JN=$(grep -n 'pthread_join(_eth' $MP.cu | cut -d: -f1)
  $ [ "$SY" -lt "$OFF" ] && [ "$OFF" -lt "$JN" ] && echo 'device sync < lower go < join enemies'
  device sync < lower go < join enemies

(f) SIGMA IS A RUNTIME FIELD, NOT A -D THE COMPILER CAN FOLD.  This is B4's scar
tissue: the GPU port passed the access pattern as a compile-time constant, nvcc
folded do_stress's if-chain to the one live branch, that branch was side-effect-free,
and the whole stress loop was DELETED while every gate stayed green.  The CPU enemy
has the identical shape, so it gets the identical defence -- the -D knob is read
host-side and handed over as a runtime value.  cpustresscheck.py S4 gates the
compiled consequence (the op count must be invariant under -DHET_CPU_ENEMY_SEQ).
  $ grep -c '_ea\[_e\].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;' $MP.cu
  1
  $ grep -c 'switch (a->seq)' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

and the enemy's accesses are `volatile' -- without it the compiler deletes the read
side of every pattern (sigma 3 becomes a no-op) and collapses sigma 0's double store.
  $ grep -c 'volatile uint64_t \*l = a->scratch' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

(g) HALF 2a -- PLACEMENT, at the B5 seam inside gd_alloc_shared's GH200 malloc
branch.  A cudaMemAdvise that is REFUSED must never be swallowed: a placement knob
that says "remote" while the pages sat where first touch left them is an inert
mechanism reporting itself as live.
  $ grep -c 'cudaMemAdviseSetPreferredLocation' $MP.cu
  1
  $ grep -c 'cudaMemAdviseSetAccessedBy' $MP.cu
  2
  $ grep -c '_het_place(\*_pp, _bytes, HET_PLACE)' $MP.cu
  1
  $ grep -c '_het_place_failures++' $MP.cu
  2

The default is 0 = first-touch, deliberately: that is Bagchi's baseline, and Q6 3.3
finds the net effect of pinning confounded (it widens the window but slows the loop,
so sightings = yield x rate could move either way, and nobody has measured it).
  $ grep -A1 '#ifndef HET_PLACE' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_PLACE 0'
  1

The HIP twin has NO placement, and that is a finding, not an omission: MI300A has one
HBM pool shared by the CCD and XCD chiplets -- no LPDDR/HBM split, nothing to place.
Its analogue is cross-chiplet CONTENTION, which the same noise pair provides.  (The
grep matches the API CALL, not the string: the .hip explains at length why there is
no cudaMemAdvise here, so a bare `MemAdvise' count would be satisfied by the prose
that documents its absence.)
  $ grep -cE '(cuda|hip)MemAdvise\(' $MP.hip || true
  0
  $ grep -cE '(cuda|hip)MemAdvise\(' $MP.cu
  3
  $ grep -c 'CONTENTION' $MP.hip
  2

(h) HALF 2b -- THE FUSCO NOISE PAIR.  Each processing unit continuously stream-reads
the OTHER one's memory: "the Grace noise kernel reads HBM system allocated memory and
the Hopper noise kernel reads DDR allocated memory."  The Hopper half runs as EXTRA
BLOCKS OF THE PERSISTENT GRID, never as a second __global__ -- ptxcheck scans the
whole PTX file in flat order and slices that one op stream per lane, so a second
kernel would drop its ops into the middle of the stream being sliced.
  $ grep -c '__global__' $MP.cu
  1
  $ grep -c 'blockIdx.x < HET_TEST_BLOCKS + _noise_blocks' $MP.cu
  1
  $ grep -c 'volatile const uint64_t\* _nb = (volatile const uint64_t\*)_noise_ddr' $MP.cu
  1
  $ grep -c 'pthread_create(&_nth, NULL, het_cpu_noise, &_na)' $MP.cu
  1

The working set is the whole point: a buffer that fits in cache is served from cache
and crosses nothing (Fusco: "Hopper L2 cache can cache data that is physically
allocated on HBM, both local and peer").  Grace L3 = 114 MB, Hopper L2 = 51 MB, and
Fusco's buffer is 8 GB.  A sub-LLC configuration is warned about at run time.
  $ grep -A1 '#ifndef HET_NOISE_MB' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_NOISE_MB 8192'
  1
  $ grep -c 'HET_NOISE_MB < HET_LLC_MB' $MP.cu
  1

(h2) AND THE NOISE BUFFER MUST BE REAL MEMORY.  The sharpest trap in this layer, and
the least obvious: a malloc'd buffer that has never been WRITTEN is not backed by
physical memory at all -- Linux maps every untouched anonymous page to ONE shared,
read-only zero page.  A noise kernel READING an 8 GB buffer that was never
first-touched therefore touches a SINGLE cache line, is served entirely from L1, and
generates no DRAM traffic and NO INTERCONNECT TRAFFIC WHATSOEVER, while reporting
perfectly healthy round counts.  (Measured on the dev box: reading 256 MB of
untouched memory backs 64 KB; first-touching it backs 262144 KB.)  So both renders
fault the pages in, and cpustresscheck.py D3 proves at run time that it works.
  $ grep -c 'het_cpu_first_touch(\*_pp, _bytes)' $MP.cu
  2
  $ grep -c 'het_cpu_first_touch(\*_pp, _bytes)' $MP.hip
  1

and on GH200 the CPU's first touch homes the pages on DDR, so the buffer that must
live on HBM -- the one the Grace thread streams, so each read CROSSES C2C -- is
prefetched across; a refusal is reported, because an "HBM" buffer that is really on
DDR generates local traffic, not interconnect traffic.
  $ grep -c 'cudaMemPrefetchAsync(\*_pp, _bytes, 0, 0)' $MP.cu
  1
  $ grep -c 'cudaMemPrefetchAsync of the HBM noise buffer FAILED' $MP.cu
  1

(i) LIVENESS IS REPORTED, because nothing in this layer is visible to a structural
gate and a layer that has silently stopped working looks exactly like one that is
working.  Every counter below exists because its mechanism has a way to die.
  $ grep -c 'HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds' $MP.cu
  1
  $ grep -c 'ZERO preload hints were issued' $MP.cu
  1
  $ grep -c 'the GPU half of the C2C noise did NOT run' $MP.cu
  1
  $ grep -c 'sched_setaffinity call(s) FAILED' $MP.cu
  1
  $ grep -c 'enemies=%u enemy_rounds=%llu' $MP.cu
  1

and the two knobs B8 tunes the interconnect lever against travel WITH the result.
The working set is the one that decides whether the noise crosses anything at all --
below the last-level cache the buffer is served from cache and generates no
interconnect traffic -- so a tuning log that does not record it cannot tell a good
config from a dead stressor.
  $ grep -c 'noise_ws=%uMB place=%u' $MP.cu
  1
  $ grep -c '_rec.noise_ws_mb = (uint32_t)HET_NOISE_MB' $MP.cu
  1

(j) THE SOURCES ARE CITED IN THE EMITTED HEADER, not merely in a commit message: we
reuse this work, and for cuda-litmus (no licence file) citation is the condition of
reuse.  A reader must be able to tell which ideas are ours.
  $ grep -c 'TACAS' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  3
  $ grep -c 'Sorensen & Donaldson' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1
  $ grep -c 'arXiv:2408.11556' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1
  $ grep -c 'arXiv:2410.00801' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1
  $ grep -c 'INFERENCE, not a measurement' MP-cg-sys-acqrel-2s/het_cpu_stress.h
  1

(k) the observer test renders the same shape: the observer is PINNED but NOT
preloaded (its job is to sample the shared locations densely, and a cache hint per
iteration would only thin the sampling -- the same reason B4 gave the GPU observer
lane no pre-stress).
  $ grep -A2 'static void\* cpu_obs_thread' $S.cu | grep -c 'het_cpu_affinity(a->_core, a->_tally)'
  1
  $ grep -A4 'static void\* cpu_obs_thread' $S.cu | grep -c 'het_cpu_preload' || true
  0
