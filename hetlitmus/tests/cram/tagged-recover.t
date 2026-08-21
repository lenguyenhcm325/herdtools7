Store-tag + recovery guard.  The het harness carries the K*(_n+1)+mu store tags,
uint64 read buffers off the race path, and the het_obs_record recovery scan; the
standalone GPU-only path stays UNTAGGED, because the tag context is gated on het
emission.

CPU side: the tagged body sources each store value from a K*(_n+1)+mu REGISTER
operand (no `mov #imm'), preserves the tested mnemonic verbatim, and widens to
64-bit %x.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'mov %w' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c || true
  0
  $ grep -c 'stlr %x\[_v0\],\[%\[x\]\]' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ sed -n '/^void het_run_P0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -c 'uint64_t _v0 = (uint64_t)3 \* (_n + 1) + 1;'
  1

The CPU signature is widened and takes threads _n (no *out pointers).
  $ grep -c 'void het_run_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1

Driver: uint64 shared vars, per-load read buffers in device memory
(cudaMalloc) mirrored to the host, and the het_obs_record recovery scan; no
__out.  The shared vars are allocated one at a time through gd_alloc_shared
(shared-alloc.t (a)); the read buffers stay off the race path.
  $ grep -c 'uint64_t \*x; gd_alloc_shared((void\*\*)&x, sizeof(uint64_t));' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMalloc(&bufP1_0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMemcpy(bufP1_0_h' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
het_obs_record lives in the shared het_verdict.h, next to the decision rule that
reads it: ONE DEFINITION, shared by every harness and by verdictcheck.py, so the
gate exercises the struct that actually ships.

  $ grep -c '#include "het_verdict.h"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'typedef struct het_obs_record' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_obs_record_print(stdout' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '#define K_TAG 3' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'int _weak =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '__out' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

GPU side: the two GPU stores carry the tag as uint64 atomic_ref stores (the
observer lane's uint64 loads are counted separately below).
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -c 'ref.store(' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  2
  $ grep -c 'ref.store(((uint64_t)5 \* (_n + 1) + 3)' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

Observers: every test whose condition names a memory location (every 2+2W, R, S,
CoWR and CoRW2) adds ONE GPU observer lane plus ONE CPU observer pthread, so
NPART grows by 2; each snoops every observed location, and a per-run ws scan
fills _loc with the same-observer-thread cycle -- the observer-buffer method of
[Srivastava24 sec 3.3].

NPART counts the participants: 2 procs + 2 observers = 4.  Pin the total and
state the arithmetic, so a wrong lane count cannot hide inside a plausible
number.
  $ grep -c '#define NPART 4' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c 'cpu_obs_thread' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  2
  $ grep -c 'int _loc = ((_ws_x_c && _ws_y_c) || (_ws_x_g && _ws_y_g))' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

GATE 1: no test may emit a constant detector.  A constant-false _weak reports
"Never" on every run, and a spurious "Never" is an observation nothing produced,
so the emitter refuses to emit one.  This can only regress by removing that
refusal.
  $ grep -cE 'int _weak = [01];' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

GATE 2: a CPU-side read is bound to its buffer by LOAD NODE, not by device, so
MP-gc (GPU writes, CPU reads) is the same exact O(N) scan as MP-cg, just over the
host buffer.
  $ litmus7 -gpu-target cuda -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'int _weak = ((bufP1_0\[_f\] != 0 && bufP1_0\[_f\] % K_TAG == 2) && (bufP1_1\[_f\] < (uint64_t)K_TAG\*_m0 + 1));' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1

GATE 3: T_L>=2 windowing.  SB has no rf anchor (both reads are fr), so the
partner's frame is SEARCHED over [c-W, c+W] around the synchrony point decoded
from read-buffer 1, guarded by that tag being real -- a cold frame has no
synchrony point, and counting it would report 100% weak
([Srivastava24 sec 4.1]).
  $ litmus7 -gpu-target cuda -o . ../het/SB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'if (bufP0_0\[_f\] != 0) {' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3
  $ grep -c 'for (_t1 = _c1_lo; _t1 <= _c1_hi && !_rwin; ++_t1)' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_WINDOW' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3

The exhaustive COUNT (ground truth for calibrating W) is emitted too, capped so
it cannot blow up at N=1e6 -- and it records whether it ran, so a capped-out run
is never misread as "exhaustively counted zero".
  $ grep -c 'const int _exh = (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX);' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c '_rec.exhaustive_valid = _exh;' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1

The other direction: MP has no windowed proc (T_L<=1), so its O(N) scan IS the
ground truth at any N and the flag is the literal 1.  Setting it to
(SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX) everywhere would make it 0 on every row of
the corpus at the default N=100000 (the cap is 4096), and the rule -- which
refuses a credible null unless the flag is 1 -- would call every run COLD
forever: a decision rule that always says the same thing.
  $ grep -c '_rec.exhaustive_valid = 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

GATE 4: LB's two rf edges decode each other exactly (no window): P1's frame is
pinned by P0's read, and P1's read must decode back to P0's own frame _f.
2 is the PREAMBLE BASELINE, not a bumped pin: the `#ifndef HET_WINDOW / #define'
pair is emitted unconditionally, and each windowed read adds one further line, so
2 means "no windowed read here" exactly as the 3 above means "one".
  $ litmus7 -gpu-target cuda -o . ../het/LB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'bufP1_0_h\[(_m1 - 1)\] / K_TAG == (uint64_t)(_f + 1)' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_WINDOW' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
  2

GATE 5: an fr-against-init cycle (R) is weak precisely when its read is COLD, so
the histogram must be fed on (_hot || _weak) -- gating on _hot alone drops
exactly the frames R exists to count, and oracle-compare.sh would then parse the
empty histogram as "Never".  The guard is emitted for every read-buffer test;
checked here on the LB render.
  $ grep -c 'if (_hot || _weak) {' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
  1

GATE 6: LDAPR is RCpc (ARMv8.3).  Neither native gcc on Grace nor
`clang --target=aarch64-linux-gnu' enables it by default, so the tagged body must
carry the extension itself or every two-sided (-2s) test fails to ASSEMBLE.
  $ grep -c '.arch_extension rcpc' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s_cpu.c
  1
A plain-LDR body must NOT carry it.
  $ litmus7 -gpu-target cuda -o . ../het/WRC-ccg-cta-relaxed.litmus >/dev/null 2>&1
  $ grep -c 'arch_extension' WRC-ccg-cta-relaxed/WRC-ccg-cta-relaxed_cpu.c || true
  0

GATE: the standalone GPU-only path (CudaLang.dump) is UNTAGGED -- plain int
atomic_ref, no K_TAG, no het_obs_record, no uint64 widening.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'K_TAG|het_obs_record|atomic_ref<uint64_t' MP-sys-acquire.cu || true
  0
