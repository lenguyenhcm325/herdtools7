GPU memory-stress guard (hetlitmus/docs/00-environment-design.md sec 3.5).  The
emitted het harness carries the stress layer ported from [CudaLitmus], in the
shape the design requires: stress in DEVICE memory, disjoint from the test; every
scaffolding op confined to that scratchpad and to its own tally words; and the
perpetual-loop invariants (co-residency guard, pinned trip counts) still standing
underneath it.

Stress is not an optimisation: on the NVIDIA GTX Titan the inter-CTA lb and sb
tests were observed 0 per 100k without it, whereas the same source saw weak
behaviours on AMD with no incantation at all, so on the .hip render this layer
amplifies rates rather than enabling observation.  The quotes, tables and vendor split live once,
in the emitted het_stress.h (pinned in (e3)); do not repeat the claim
unqualified.

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and a HIP harness is the (x86_64, hip) one.  The
CPU column differs; everything these sections read is the GPU render and the
shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target hip -o hip ../het-x86/S-cg-sys-fence-x86_64.litmus >/dev/null 2>&1
  $ MP=MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s
  $ S=S-cg-sys-fence/S-cg-sys-fence
  $ MPH=hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64
  $ SH=hip/S-cg-sys-fence-x86_64/S-cg-sys-fence-x86_64

(a) the ported stress layer is emitted ONCE per harness dir and included by that
dir's render -- one shared header, so all reused [CudaLitmus] code and its
mandatory citations sit in one auditable file.
  $ test -f MP-cg-sys-acqrel-2s/het_stress.h && echo present
  present
  $ grep -c '#include "het_stress.h"' $MP.cu $MPH.hip
  MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu:1
  hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip:1
  $ grep -c 'cuda-litmus' MP-cg-sys-acqrel-2s/het_stress.h > /dev/null && echo cited
  cited

(b) two object classes, two allocators.  The scratchpad is GPU-only and disjoint
from every test location, so it lives in DEVICE memory: it must not go through
gd_alloc_shared, the coherent allocator that selects the property under test
(shared-alloc.t).  Confusing the two would put stress traffic on the tested cache
lines.
  $ grep -c 'cudaMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MP.cu
  1
  $ grep -c 'cudaMalloc(&_scratch_loc' $MP.cu
  1
  $ grep -c 'gd_alloc_shared((void\*\*)&_scratch' $MP.cu || true
  0
  $ grep -c 'hipMalloc(&_scratch, sizeof(uint32_t)\*HET_SCRATCH_SIZE)' $MPH.hip
  1

(c) the pure-stress workgroups: every block above the test blocks
hammers the scratchpad, and the grid is raised toward the co-resident cap.  The
launch guard that must survive that raise -- an over-large cooperative launch is
REJECTED at launch rather than silently deadlocking, a silent hang being
indistinguishable from a genuine non-observation -- is pinned once, in
coop-launch.t (g), which reads this same render.
  $ grep -c 'blockIdx.x >= HET_TEST_BLOCKS' $MP.cu
  1
  $ grep -c '_stressBlocks = (HET_STRESS_BLOCKS >= 0)' $MP.cu
  1

(d) the stress layer touches the SCRATCHPAD and nothing else.  A device-scope
counter on a scratch word adds no ordering edge to the tested locations; a
scaffolding op on a test location would fabricate the very outcome the row is
looking for.  The tally words are the scratchpad's, not a test variable's.
  $ grep -oE 'het_scratch_(bump|max|read)\([^,)]*' $MP.cu | sed 's/.*(//' | sort -u
  &_stress_tally[HET_TALLY_NOISE]
  &_stress_tally[HET_TALLY_NOISE_ROUNDS]
  &_stress_tally[HET_TALLY_TRUNC]
  _gpu_done

(The cross-device arrivals themselves are pinned in coop-launch.t (b,c), on this
same render.)

(e) the ACCESS PATTERN reaches het_do_stress as a runtime kernel argument, never
as a compile-time constant.  Two defects meet in this one line: upstream passes
an iteration count where do_stress expects the pattern ([CudaLitmus]
litmus.cuh:346), so mem-stress spins doing nothing; and a compile-time pattern
lets nvcc fold the if-chain to the one live branch, and the shipped pre-stress
default (3 = ld;ld, whose loads only feed a `break') writes nothing, so those
loads hoist out of the loop and leave the round counting without the traffic.
hetlitmus/verify/stresscheck.py
is the gate, and _stress_tally counts the rounds het_do_stress completed, so a
layer that is present in the PTX and never executes is visible to het_verdict().
The pre-stress runs in every test lane.
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally)' $MP.cu
  1
  $ grep -c 'uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;' $MP.cu
  1
  $ grep -c 'uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;' $MP.cu
  1

and an out-of-range pattern is refused at COMPILE time -- het_do_stress's
if-chain has no else, so upstream's pattern 57 would silently stress nothing.
  $ grep -c '#error "HET_PRE_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c '#error "HET_MEM_STRESS_PATTERN must be 0..3' MP-cg-sys-acqrel-2s/het_stress.h
  1

(e2) liveness tally: every mechanism in the stress layer is invisible to the
static faithfulness gate (it is scaffolding, not a tested op), so its health is measured
at RUN TIME or not at all.  The stress lanes flag a HET_STRESS_MAX_ROUNDS
cap-exit, which means stress stopped while the test was still running, and count
the rounds one het_do_stress call completed.  The host prints both and carries
them into the HetObs record, so the statistics layer can disqualify a run and a
hardware sweep can be scored on it.
  $ grep -c 'het_scratch_bump(&_stress_tally\[HET_TALLY_TRUNC\])' $MP.cu
  1
  $ grep -c 'HetLitmus stress: do_stress_rounds=%u' $MP.cu
  1
  $ grep -c 'stress_trunc=%llu do_stress_rounds=%llu' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_scratch_max(&tally\[HET_TALLY_STRESS_ROUNDS\], rounds)' MP-cg-sys-acqrel-2s/het_stress.h
  1

(e3) the two upstream defects are disclosed in the emitted header, not just in a
commit message: we cite [CudaLitmus], so a reader must be able to tell which
lines are theirs.  The second is a dead dedup -- setScratchLocations declares a std::set of
used regions and queries it but never inserts, so it never dedups and its
realised spread is <= m.  We dedup for real, which is a behavioural divergence,
disclosed both in the header (where a reader looks for provenance) and at the
code site (where a maintainer looks before "restoring" upstream's version).
  $ grep -c 'never inserts into the set' MP-cg-sys-acqrel-2s/het_stress.h
  1
  $ grep -c 'A real dedup (see above)' MP-cg-sys-acqrel-2s/het_stress.h
  1

and the "zero without stress" result of [Alglave15 sec 4.3.1] is qualified to
NVIDIA, because this header is #include'd by the .hip (AMD) render too -- on AMD
the same paper saw lb without any incantation.
  $ grep -c 'VENDOR SPLIT' MP-cg-sys-acqrel-2s/het_stress.h
  1

(f) the stress toggles are decided DEVICE-side off a seeded Park-Miller stream:
the perpetual kernel has no per-iteration host round-trip to re-roll them, and a
fixed seed keeps a run replayable ([GPUHarbor23 sec 3.4]).  The lane draws its own stream for
the pre-stress toggle, which feeds no shared counter; the barrier's stream is the
lane-independent one checked in (d).
  $ grep -c 'het_rng_t _rng = het_rng_init(_seed, blockIdx.x \* blockDim.x + threadIdx.x)' $MP.cu
  1

(g) a shape whose outcome carries a coherence-final location runs no extra lane
for it: the location's value is read out of its own slot after the run, so
S-cg-sys-fence has exactly the lanes its GPU procs ask for -- one block, one
lane -- and the pre-stress roll sits in it like any other lane's.

Every `unroll 1' pragma survives per lane -- dropping one lets nvcc unroll that
persistent loop, and the PTX then carries many times the declared ops, which is
the faithfulness gate's subject.
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES)' $S.cu
  #define HET_TEST_BLOCKS 1
  #define HET_GPU_LANES 1
  $ grep -c '#pragma unroll 1' $S.cu
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' $S.cu | grep -c 'het_do_stress(_scratch'
  1

(h) the HIP twin renders the same shape from the same template (per-dialect
fields, not per-dialect branches), and the header's one divergence -- the vendor
runtime header its scratchpad counters need -- resolves to the HIP spelling.
  $ grep -c 'het_do_stress(_scratch' $SH.hip
  2
  $ grep -c '#include <hip/hip_runtime.h>' hip/S-cg-sys-fence-x86_64/het_stress.h
  1
