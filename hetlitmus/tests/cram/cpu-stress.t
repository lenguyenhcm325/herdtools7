CPU-side + interconnect stress guard (hetlitmus/docs/00-environment-design.md
sec 3.6; hetlitmus/docs/het-emission.md, "The pair a harness names").

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ MPH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
  $ S=S-cg-sys-fence/S-cg-sys-fence

Counts that a wrong site could satisfy are SCOPED to one function body, never
raised to a file-wide total.

(a) the host ISA reaches no nvcc translation unit: the preload primitives live
in het_cpu_stress.h behind HET_CPU_STRESS_IMPL, which only <test>_cpu.c defines.
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
  $ grep -cE 'dc civac|prfm |clflush|prefetcht0' $MP.cu || true
  0

(a2) het_cpu_stress.h includes no <pthread.h>, which would not cross-assemble
for AArch64; the .cu, built for the native host, is where pthread_create lives.
  $ grep -c '#include <pthread.h>' MP-cg-sys-acqrel-2s/het_cpu_stress.h || true
  0
  $ grep -c '#include <pthread.h>' $MP.cu
  1

(b) nothing is injected inside the tested body: it stays litmus7's own code0,
its two tested stores in the release form this two-sided row is about.
  $ sed -n '/^__attribute__((noinline)) static void code0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE '"(stlr|ldapr|dmb|str|ldr)'
  2
  $ sed -n '/^#if defined(__aarch64__)/,/^#else/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -cE 'het_cpu_preload|het_cpu_affinity|dc civac|prfm' || true
  0
  $ sed -n '/^__attribute__((noinline)) static void code0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -coE '"stlr '
  2

The preload runs per iteration, before the tested body, on the slot of this
proc's own test variables, and the affinity call precedes the rendezvous.
  $ sed -n '/^static void\* cpu_thread_P0/,/^}/p' $MP.cu | grep -c 'het_cpu_preload(_pl, 2, a->_seed, _who, _kn + 1u, HET_CPU_PRELOAD_PCT)'
  1
  $ sed -n '/^static void\* cpu_thread_P0/,/^}/p' $MP.cu | grep -c 'void\* const _pl\[2\] = { (void\*)(a->x + _slot), (void\*)(a->y + _slot) }'
  1
  $ grep -A2 'static void\* cpu_thread_P0' $MP.cu | grep -c 'het_cpu_affinity(a->_core, a->_tally)'
  1

(c) the enemy and noise traffic is disjoint from the test: no stress object is
ever x, y or barrier [Sorensen16 sec 1].
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(_cpu_scratch|_cpu_idx)' $MP.cu
  2
  $ grep -cE '_ea\[_e\]\.(scratch|idx) *= *(x|y|barrier)' $MP.cu || true
  0
  $ grep -cE '_na\[_t\]\.buf *= *\(volatile const uint64_t\*\)_noise_hbm \+ \(uint64_t\)_t \* _noise_slice' $MP.cu
  1

(d) four object classes, four allocators: a slot for the rendezvous counter,
malloc for the CPU scratchpad, gd_alloc_noise for the noise buffers.
  $ grep -c 'uint64_t \*barrier; gd_alloc_shared((void\*\*)&barrier, sizeof(uint64_t)\*HET_SLOT_STRIDE_WORDS);' $MP.cu
  1
  $ grep -c 'malloc_check(sizeof(uint64_t)\*HET_CPU_SCRATCH_WORDS)' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_ddr' $MP.cu
  1
  $ grep -c 'gd_alloc_noise((void\*\*)&_noise_hbm' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_cpu_scratch' $MP.cu || true
  0

(e) the stress orchestration order, which no gate script reads: raise stress_go,
then spawn the enemies and the noise, then the test threads and the kernel.
  $ GO=$(grep -n '__atomic_store_n(&_stress_go, 1' $MP.cu | cut -d: -f1)
  $ EN=$(grep -n 'pthread_create(&_eth' $MP.cu | cut -d: -f1)
  $ TH=$(grep -n ', cpu_thread_' $MP.cu | head -1 | cut -d: -f1)
  $ TZ=$(grep -n ', cpu_thread_' $MP.cu | tail -1 | cut -d: -f1)
  $ LA=$(grep -n 'cudaLaunchCooperativeKernel' $MP.cu | cut -d: -f1)
  $ [ -n "$TH" ] && [ -n "$TZ" ] && echo 'test-thread spawns found'
  test-thread spawns found
  $ [ "$GO" -lt "$EN" ] && [ "$EN" -lt "$TH" ] && [ "$TZ" -lt "$LA" ] && echo 'go < enemies < test threads (all) < launch'
  go < enemies < test threads (all) < launch

and the flag comes down only after the TERMINAL sync -- not gd_alloc_noise's own
one-shot sync -- so the stress covers the whole tested window and no more.
  $ SY=$(grep -n '_s = cudaDeviceSynchronize' $MP.cu | cut -d: -f1)
  $ OFF=$(grep -n '__atomic_store_n(&_stress_go, 0' $MP.cu | cut -d: -f1)
  $ JN=$(grep -n 'pthread_join(_eth' $MP.cu | cut -d: -f1)
  $ [ "$SY" -lt "$OFF" ] && [ "$OFF" -lt "$JN" ] && echo 'device sync < lower go < join enemies'
  device sync < lower go < join enemies

(f) sigma is read host-side and handed over as a runtime field, never left for
the compiler to fold.
  $ grep -c '_ea\[_e\].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;' $MP.cu
  1

(g) placement binds the shared pages to a NUMA node and reads the home back, so a
page left off-node is never swallowed.
  $ grep -c '_het_place_shared(\*_pp, _bytes, HET_PLACE)' $MP.cu
  1
  $ grep -q 'syscall(SYS_mbind' $MP.cu && echo present
  present
  $ grep -q 'MPOL_BIND' $MP.cu && echo present
  present
  $ grep -q 'syscall(SYS_move_pages' $MP.cu && echo present
  present
  $ grep -q '_het_place_failures++' $MP.cu && echo present
  present
  $ grep -A1 '#ifndef HET_PLACE' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_PLACE 0'
  1

The HIP twin binds nothing: MI300A's one HBM pool makes a non-zero HET_PLACE a
compile error, so the render carries no mbind and its analogue is contention.
  $ grep -c 'SYS_mbind' $MPH.hip || true
  0
  $ grep -q 'SYS_mbind' $MP.cu && echo present
  present
  $ grep -q 'CONTENTION' $MPH.hip && echo present
  present

(h) the noise pair of [Fusco24 sec III-E.1] runs as extra blocks of the
persistent grid, never as a second __global__.
  $ grep -c '__global__' $MP.cu
  1
  $ grep -c 'blockIdx.x < HET_TEST_BLOCKS + _noise_blocks' $MP.cu
  1
  $ grep -c 'volatile const uint64_t\* _nb = (volatile const uint64_t\*)_noise_ddr' $MP.cu
  1
  $ grep -c 'if (pthread_create(&_nth\[_t\], NULL, het_cpu_noise, &_na\[_t\]) == 0) _noise_cpu_n++;' $MP.cu
  1

The host half is HET_NOISE_CPU_THREADS threads over equal disjoint slices, each
one subtracted from the enemy budget.
  $ grep -c '_nEnemy = _ncores - _nCpuTest - HET_NOISE_CPU_THREADS - HET_CPU_RESERVE_CORES;' $MP.cu
  1
  $ grep -c 'int _ecore0 = HET_CPU_TEST_CORE0 + _nCpuTest + HET_NOISE_CPU_THREADS;' $MP.cu
  1
  $ grep -c '_noise_slice = HET_NOISE_CPU_THREADS > 0 ? _noise_words / HET_NOISE_CPU_THREADS : 0;' $MP.cu
  1
  $ grep -c 'for (int _t = 0; _t < HET_NOISE_CPU_THREADS; ++_t) {' $MP.cu
  1
  $ grep -A1 '#ifndef HET_NOISE_CPU_THREADS' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_NOISE_CPU_THREADS 1'
  1

The working set is derived from HET_NOISE_MB and guarded against the last-level
cache: below it the buffer is served from cache and crosses nothing.
  $ grep -c 'uint64_t _noise_words = (uint64_t)HET_NOISE_MB \* 1024ull \* 1024ull / sizeof(uint64_t);' $MP.cu
  1
  $ grep -A1 '#ifndef HET_NOISE_MB' MP-cg-sys-acqrel-2s/het_cpu_stress.h | grep -c '#define HET_NOISE_MB 8192'
  1
  $ grep -c 'HET_NOISE_MB < HET_LLC_MB' $MP.cu
  1
  $ grep -c '#if HET_LLC_MB_IS_FALLBACK' $MP.cu
  1
  $ grep -c 'a FALLBACK figure, not this target' $MP.cu
  1

(h2) both renders fault the noise pages in, and on a CUDA render the HBM buffer
is prefetched across, a refusal being reported rather than swallowed.
  $ grep -q 'het_cpu_first_touch(\*_pp, _bytes)' $MP.cu && echo present
  present
  $ grep -c 'het_cpu_first_touch(\*_pp, _bytes)' $MPH.hip
  1
  $ grep -c 'cudaMemPrefetchAsync(\*_pp, _bytes, 0, 0)' $MP.cu
  1
  $ grep -c 'cudaMemPrefetchAsync of the HBM noise buffer FAILED' $MP.cu
  1

(h3) without pageable-memory access the noise buffers are refused, and a
placed one is a system malloc.
  $ sed -n '/^  if (!_shared_pageable()) {/,/^  }$/p' $MP.cu | grep -c 'return -1'
  1
  $ sed -n '/^static int gd_alloc_noise/,/^}$/p' $MP.cu | grep -c '\*_pp = malloc(_bytes);'
  1

(i) every counter of this layer is REPORTED, because a mechanism that has
silently stopped working looks exactly like one that is working.
  $ grep -c 'HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds' $MP.cu
  1
  $ grep -c 'ZERO preload hints were issued' $MP.cu
  1
  $ grep -c '%s of the %s noise did NOT run.  This run is not interconnect-stressed' $MP.cu
  2
  $ grep -c 'host noise thread(s) were spawned but completed ZERO rounds' $MP.cu
  1
  $ grep -c 'sched_setaffinity call(s) FAILED' $MP.cu
  1
  $ grep -c '_rec.noise_ws_mb = (uint32_t)HET_NOISE_MB' $MP.cu
  1

(i2) the two noise halves are requested by their knobs, not by what survived
allocation, so a refused half reads as requested-but-dead.
  $ grep -c '| ((HET_NOISE_CPU_THREADS > 0) ? HET_REQ_NOISE_CPU : 0u)' $MP.cu
  1
  $ grep -c '| ((_noiseBlocks > 0) ? HET_REQ_NOISE_GPU : 0u);' $MP.cu
  1

(k) a shape whose outcome carries a location column has one kind of CPU thread
only, and that thread preloads.
  $ grep -cE '^static void\* cpu_[A-Za-z_0-9]+\(void\* _a\)' $S.cu
  1
  $ grep -cE '^static void\* cpu_thread_P[0-9]+\(void\* _a\)' $S.cu
  1
  $ awk '/^static void\* cpu_thread_P0\(void\* _a\)/,/^}$/' $S.cu | grep -c 'het_cpu_preload'
  1
