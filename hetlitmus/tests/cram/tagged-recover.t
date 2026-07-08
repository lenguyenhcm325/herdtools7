B3 regression guard: the het harness must carry the K*(_n+1)+mu store tags, the
uint64 read buffers off the race path, and the het_obs_record recovery scan -- and
the standalone GPU-only path must stay UNtagged (the tag context is gated).

CPU side (Decision 1): the tagged body sources each store value from a
K*(_n+1)+mu REGISTER operand (no `mov #imm'), preserves the tested mnemonic
verbatim, and widens to 64-bit %x.
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'mov %w' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c || true
  0
  $ grep -c 'stlr %x\[_v0\],\[%\[x\]\]' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ grep -c 'uint64_t _v0 = (uint64_t)3 \* (_n + 1) + 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1

CPU signature is widened + threads _n (no *out pointers).
  $ grep -c 'void het_run_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1

Driver (Decision 3/4): uint64 shared vars, per-load read buffers in device memory
(cudaMalloc) mirrored to the host, and the het_obs_record recovery scan; no __out.
  $ grep -c 'uint64_t \*x; gd_alloc_shared' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMalloc(&bufP1_0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMemcpy(bufP1_0_h' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'typedef struct het_obs_record' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'het_obs_record_print(stdout' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '#define K_TAG 3' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'int _weak =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '__out' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

GPU side (Decision 2): the two GPU stores carry the tag as uint64 atomic_ref
stores (the observer lane's uint64 loads are counted separately below).
  $ litmus7 -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -c 'ref.store(' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  2
  $ grep -c 'ref.store(((uint64_t)5 \* (_n + 1) + 3)' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

Observers (Decision 4/5): the 72 add ONE GPU observer lane + ONE CPU observer
pthread (NPART grows by 2); each snoops every observed location, and a per-run
ws scan (Eq 3.12) fills _loc with the same-observer-thread cycle.
  $ grep -c '#define NPART 4' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c 'cpu_obs_thread' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  2
  $ grep -c 'int _loc = ((_ws_x_c && _ws_y_c) || (_ws_x_g && _ws_y_g))' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

GATE: the standalone GPU-only path (CudaLang.dump) is UNtagged -- plain int
atomic_ref, no K_TAG, no het_obs_record, no uint64 widening.
  $ litmus7 -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'K_TAG|het_obs_record|atomic_ref<uint64_t' MP-sys-acquire.cu || true
  0
