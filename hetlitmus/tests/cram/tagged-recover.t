Store-tag + recovery guard (B3; env-research/decisions/B3-decision.md).  The het
harness carries the K*(_n+1)+mu store tags, uint64 read buffers off the race
path, and the het_obs_record recovery scan; the standalone GPU-only path stays
UNTAGGED, because the tag context is gated on het emission.

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

This is a co-run harness (T + mu(T) + the canary), so the tag plan is asserted
per INSTANCE.  All three MP instances happen to have K=3, and each still tags
with its own K -- which is what matters the moment an R/S harness puts K=4 beside
K=3 (positive-control.t).
  $ grep -c 'uint64_t _v0 = (uint64_t)3 \* (_n + 1) + 1;' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  3

The CPU signature is widened and takes threads _n (no *out pointers), and it is
PREFIXED, so T's P0 and mu(T)'s P0 are not the same symbol.
  $ grep -c 'void het_run_t_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1
  $ grep -c 'void het_run_mu_P0(uint64_t \*x, uint64_t \*y, int _n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s_cpu.c
  1

Driver (Decision 3/4): uint64 shared vars, per-load read buffers in device memory
(cudaMalloc) mirrored to the host, and the het_obs_record recovery scan; no
__out.  The shared vars come from the co-run's one cache-line-padded
gd_alloc_shared arena (shared-alloc.t (f)); the read buffers stay off the race
path, per instance.
  $ grep -c 'uint64_t \*t_x = (uint64_t\*)(_sa + (size_t)HET_CACHE_LINE\*0)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMalloc(&t_bufP1_0' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'cudaMemcpy(t_bufP1_0_h' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
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
  $ grep -c '#define T_K_TAG   3' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

Three instances, three detectors -- and GATE 1 below covers all three, so a
constant-false detector on the CONTROL (which would leave it permanently cold,
and so discard every null it was supposed to vouch for) is refused exactly as one
on T is.
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

Observers (Decision 4/5): the 117 tests whose condition names a memory location
(every 2+2W, R and S) add ONE GPU observer lane plus ONE CPU observer pthread, so
NPART grows by 2; each snoops every observed location, and a per-run ws scan
(Srivastava Eq 3.12) fills _loc with the same-observer-thread cycle.

NPART is a SUM over instances.  2+2W-cg-sys-fence is oracle-Allowed, so it
co-runs the Layer-B canary: 4 (2 procs + 2 observers) + 2 (the canary's MP) = 6.
The observer contribution -- the thing this section guards -- is unchanged at +2,
which is why an MP canary adds exactly 2 and not 4.  Pin the sum and state the
arithmetic, so a wrong instance count cannot hide inside a plausible number.
  $ grep -c '#define NPART 6' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c 'cpu_obs_thread' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  2
  $ grep -c 'int _t_loc = ((t__ws_x_c && t__ws_y_c) || (t__ws_x_g && t__ws_y_g))' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

The canary brings NO second observer (MP's condition names no coherence-final
location), so cpu_obs_thread stays at 2 occurrences -- definition plus
pthread_create -- for the one observer T actually has.
  $ grep -c 'can_cpu_obs_thread' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu || true
  0

GATE 1: no test may emit a constant detector.  A constant-false _weak reports
"Never" on every run, and a spurious "Never" on a should-be-forbidden test reads
as CONFIRMING the model, so the emitter refuses to emit one and HET_PENDING (=0)
is gone from it entirely (env-research/impl-briefs/B3c-impl-brief.md).  This can
only regress by removing that refusal.
  $ grep -cE 'HET_PENDING' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0
  $ grep -cE 'int _weak = [01];' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

GATE 2: a CPU-side read is bound to its buffer by LOAD NODE, not by device, so
MP-gc (GPU writes, CPU reads) is the same exact O(N) scan as MP-cg, just over the
host buffer.
  $ litmus7 -o . ../het/MP-gc-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'int _weak = ((t_bufP1_0\[_f\] != 0 && t_bufP1_0\[_f\] % T_K_TAG == 2) && (t_bufP1_1\[_f\] < (uint64_t)T_K_TAG\*_m0 + 1));' MP-gc-sys-acqrel-2s/MP-gc-sys-acqrel-2s.cu
  1

GATE 3: T_L>=2 windowing.  SB has no rf anchor (both reads are fr), so the
partner's frame is SEARCHED over [c-W, c+W] around the synchrony point decoded
from read-buffer 1, guarded by that tag being real -- a cold frame has no
synchrony point, and counting it would report 100% weak (Srivastava 4.4).
SB-cg-sys-acqrel-2s is oracle-Allowed, so it co-runs the canary and the test
under study carries the `t_' prefix: same scan, same counts, same window.
  $ litmus7 -o . ../het/SB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'if (t_bufP0_0\[_f\] != 0) {' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3
  $ grep -c 'for (_t1 = _c1_lo; _t1 <= _c1_hi && !_rwin; ++_t1)' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'HET_WINDOW' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3

The exhaustive COUNT (ground truth for calibrating W) is emitted too, capped so
it cannot blow up at N=1e6 -- and it records whether it ran, so a capped-out run
is never misread as "exhaustively counted zero".
  $ grep -c 'const int _t_exh = (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX);' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c '_rec.exhaustive_valid = _t_exh;' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1

The canary's own exhaustive_valid is separate and is 1: MP is T_L<=1, so its O(N)
scan is exact at any N.  T's is the one that gates T's null; the canary's gates
nothing, because a control that cannot fire is not a control.
  $ grep -c '_rec.canary_exhaustive_valid = 1;' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1

GATE 4: LB's two rf edges decode each other exactly (no window): P1's frame is
pinned by P0's read, and P1's read must decode back to P0's own frame _f.
2 is the PREAMBLE BASELINE, not a bumped pin: the `#ifndef HET_WINDOW / #define'
pair is emitted unconditionally, and each windowed read adds one further line, so
2 means "no windowed read here" exactly as the 3 above means "one".
  $ litmus7 -o . ../het/LB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 't_bufP1_0_h\[(_m1 - 1)\] / T_K_TAG == (uint64_t)(_f + 1)' LB-cg-sys-acqrel-2s/LB-cg-sys-acqrel-2s.cu
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
  $ litmus7 -o . ../het/WRC-ccg-cta-relaxed.litmus >/dev/null 2>&1
  $ grep -c 'arch_extension' WRC-ccg-cta-relaxed/WRC-ccg-cta-relaxed_cpu.c || true
  0

GATE: the standalone GPU-only path (CudaLang.dump) is UNTAGGED -- plain int
atomic_ref, no K_TAG, no het_obs_record, no uint64 widening.
  $ litmus7 -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'K_TAG|het_obs_record|atomic_ref<uint64_t' MP-sys-acquire.cu || true
  0
