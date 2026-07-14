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
  $ sed -n '/^void het_run_t_P0/,/^}/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c | grep -c 'uint64_t _v0 = (uint64_t)3 \* (_n + 1) + 1;'
  1

B6b: this is a CO-RUN harness (T + mu(T) + the canary), so the tag plan is asserted
per INSTANCE.  All three MP instances happen to have K=3 -- and each still tags with
its OWN K, which is what matters the moment an R/S harness puts K=4 beside K=3.
  $ grep -c 'uint64_t _v0 = (uint64_t)3 \* (_n + 1) + 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  3

CPU signature is widened + threads _n (no *out pointers) -- and PREFIXED, so T's P0
and mu(T)'s P0 are not the same symbol.
  $ grep -c 'void het_run_t_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ grep -c 'void het_run_mu_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1

Driver (Decision 3/4): uint64 shared vars, per-load read buffers in device memory
(cudaMalloc) mirrored to the host, and the het_obs_record recovery scan; no __out.
(The shared vars come from the co-run's ONE cache-line-padded gd_alloc_shared arena
-- still the coherent allocator, which is what selects the property under test; see
shared-alloc.t (f).  The read buffers stay OFF the race path, per instance.)
  $ grep -c 'uint64_t \*t_x = (uint64_t\*)(_sa + (size_t)HET_CACHE_LINE\*0)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMalloc(&t_bufP1_0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMemcpy(t_bufP1_0_h' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
B6: het_obs_record moved OUT of the .cu and into the shared het_verdict.h, next to
the decision rule that reads it -- one definition, shared by every harness and by
verdictcheck.py, so the gate exercises the struct that actually ships.

  $ grep -c '#include "het_verdict.h"' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'typedef struct het_obs_record' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_obs_record_print(stdout' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '#define T_K_TAG   3' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

THREE INSTANCES, THREE DETECTORS -- and B3c GATE 1 below now covers all three, so a
constant-false detector on the CONTROL (which would leave it permanently cold, and
so discard every null it was supposed to vouch for) is refused exactly as one on T is.
  $ grep -c 'int _weak =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  3
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

B3c GATE 1: NO test may emit a constant detector.  HET_PENDING (=0) is gone from
the emitter entirely -- a constant-false _weak reports "Never" on every run, and
a spurious "Never" on a should-be-forbidden test reads as CONFIRMING the model.
(This killed 266 of the 338 het tests before B3c.)  The emitter now refuses to
emit a constant _weak at all, so this can only regress by removing that check.
  $ grep -cE 'HET_PENDING' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0
  $ grep -cE 'int _weak = [01];' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

B3c GATE 2: a CPU-side read is bound to its buffer by LOAD NODE, not by device --
so MP-gc (GPU writes, CPU reads) is the SAME exact O(N) scan as MP-cg, just over
the host buffer.  Before B3c its detector was the constant HET_PENDING.
  $ litmus7 -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'int _weak = ((t_bufP1_0\[_f\] != 0 && t_bufP1_0\[_f\] % T_K_TAG == 2) && (t_bufP1_1\[_f\] < (uint64_t)T_K_TAG\*_m0 + 1));' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1

B3c GATE 3: T_L>=2 windowing.  SB has no rf anchor (both reads are fr), so the
partner's frame is SEARCHED over [c-W, c+W] around the synchrony point decoded
from read-buffer 1 -- guarded by that tag being real (a cold frame has no
synchrony point, and counting it would report 100% weak; Srivastava 4.4).
  $ litmus7 -o . ../het/SB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'if (bufP0_0\[_f\] != 0) {' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3
  $ grep -c 'for (_t1 = _c1_lo; _t1 <= _c1_hi && !_rwin; ++_t1)' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_WINDOW' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3

The exhaustive COUNT (ground truth for calibrating W) is emitted too, capped so
it cannot blow up at N=1e6 -- and it records WHETHER it ran, so a capped-out run
is never misread as "exhaustively counted zero".
  $ grep -c 'const int _exh = (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX);' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c '_rec.exhaustive_valid = _exh;' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1

B3c GATE 4: LB's two rf edges decode each other exactly (no window): P1's frame
is pinned by P0's read, and P1's read must decode back to P0's own frame _f.
  $ litmus7 -o . ../het/LB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 't_bufP1_0_h\[(_m1 - 1)\] / T_K_TAG == (uint64_t)(_f + 1)' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_WINDOW' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu || true
  2

B3c GATE 5: an fr-against-init cycle (R) is weak precisely when its read is COLD,
so the histogram must be fed on (_hot || _weak) -- gating on _hot alone drops
exactly the frames R exists to count, and oracle-compare.sh would then parse the
empty histogram as "Never".
  $ grep -c 'if (_hot || _weak) {' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
  1

B3c GATE 6: LDAPR is RCpc (ARMv8.3).  Neither native gcc on Grace nor
`clang --target=aarch64-linux-gnu' enables it by default, so the tagged body must
carry the extension itself or every two-sided (-2s) test fails to ASSEMBLE.
  $ grep -c '.arch_extension rcpc' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s_cpu.c
  1
A plain-LDR body must NOT carry it (byte-identical to pre-B3c).
  $ litmus7 -o . ../het/WRC-ccg-cta-relaxed.litmus >/dev/null 2>&1
  $ grep -c 'arch_extension' WRC-ccg-cta-relaxed/WRC-ccg-cta-relaxed_cpu.c || true
  0

GATE: the standalone GPU-only path (CudaLang.dump) is UNtagged -- plain int
atomic_ref, no K_TAG, no het_obs_record, no uint64 widening.
  $ litmus7 -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'K_TAG|het_obs_record|atomic_ref<uint64_t' MP-sys-acquire.cu || true
  0
