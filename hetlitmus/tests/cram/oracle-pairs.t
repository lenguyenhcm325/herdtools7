THE ORACLE PAIR TABLE (litmus/hetOracle.ml).  A compound harness is a CPU ISA and
a GPU dialect running one test, and the model prediction it carries belongs to the
PAIR: expected-nvidia.csv is derived for Grace(AArch64)+Hopper and expected-amd.csv
for Zen-4(x86-64)+CDNA3, so a cell neither file speaks for must not be filled in
from a neighbour.  Three states, and each is pinned here: POPULATED stamps its
oracle and its machine, REGISTERED NO-ORACLE stamps ORACLE_NONE and names no
machine at all, ABSENT refuses.

(a) POPULATED: the stamp every run prints, byte for byte.  This string is what a
result is filed under -- a harness tagged from the wrong pair compiles, runs and
reports identically, and only this line says which model it was claiming to test.
  $ mkdir aa
  $ litmus7 -gpu-target cuda -o aa ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -c '_rec.oracle_source = "expected-nvidia.csv:NVIDIA-PTX-AArch64";' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ mkdir xh
  $ litmus7 -gpu-target hip -o xh ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c '_rec.oracle_source = "expected-amd.csv:AMD-CDNA3-x86";' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(b) ...and the MACHINE each populated pair is entitled to name, stamped as defines
het_verdict.h prints its interconnect prose from.  Keyed on the PAIR, never on the
dialect: keyed on the dialect the dev-tier x86+CUDA emission in (c) would stamp
"the Grace half" on a machine with no Grace in it.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_LINK_NAME "NVLink-C2C"
  #define HET_HOST_HALF "the Grace half"
  #define HET_DEV_HALF "the Hopper half"
  #define HET_ALGLAVE_ZERO_MEASURED 1
  #define HET_PLACE_LEVER "cudaMemAdvise"

HET_ALGLAVE_ZERO_MEASURED is absent on the AMD pair (the "zero without stress"
figure was measured on NVIDIA parts and no equivalent is published for MI300A),
and so is HET_PLACE_LEVER (the HIP render carries no placement code at all).  An
absent define is the SAFE direction: het_verdict.h's default names the mechanism.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_LINK_NAME "Infinity Fabric"
  #define HET_HOST_HALF "the x86 half"
  #define HET_DEV_HALF "the MI300A device half"

(c) THE LANDMINE.  (x86_64, cuda) is REGISTERED WITHOUT AN ORACLE -- it is the
dev box, and no compound model has been instantiated for an x86-64 host with an
NVIDIA device.  Keyed on the CPU ISA alone, as the emitter was until this table
existed, that emission read the AMD control map and tagged all 411 harnesses with
MI300A verdicts.  Now it stamps ORACLE_NONE directly, from the table row, and the
AMD oracle's NAME appears nowhere in the harness directory.
  $ mkdir xc
  $ litmus7 -gpu-target cuda -o xc ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c '_rec.het_oracle = ORACLE_NONE;' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  1
  $ grep -c 'X86_64, cuda) is registered without one' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  1
  $ grep -rlE 'expected-amd|AMD-CDNA3-x86' xc | wc -l
  0

It names no MACHINE either: with no defines stamped, het_verdict.h's generic
wording stands, so no verdict this harness prints claims to be a Grace or a
Hopper.
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|ALGLAVE_ZERO_MEASURED)' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu || true
  0

What the CUDA render still carries is its own DIALECT payload's design notes:
het_alloc_cuda.inc, het_noise_cuda.inc and het_stress.cuh describe mechanisms
derived for GH200 and name it, and one stress warning in het_noise_cuda.inc is
worded for that part.  Tracked by count so it cannot grow unnoticed; the verdict
layer, which is what a result is read off, is define-driven and carries none of
it.
  $ grep -ciE 'nvlink|grace|hopper' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  10

(d) ABSENT: (AArch64, hip) is in no row, so emission REFUSES.  It names the pair
-- the reader's next question is which one -- and it writes nothing, because a
half-written harness directory is indistinguishable from a complete one to every
script that globs for them.
  $ mkdir absent
  $ litmus7 -gpu-target hip -o absent ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) ../het/MP-cg-sys-relaxed.litmus: no oracle is registered for the CPU-ISA x GPU-dialect pair (AArch64, hip).  The model prediction a harness carries belongs to the PAIR, so tagging this one from a neighbouring row would stamp it with a prediction derived for another machine.  Registered pairs: (AArch64, cuda), (X86_64, hip), (X86_64, cuda).  Add the pair to litmus/hetOracle.ml, or pass -allow-no-oracle to emit it as a characterization-only harness (new hardware only; the stamp discloses the override).
  exit 3
  $ ls absent

(e) ...and `-allow-no-oracle' is the disclosed way past it, for a machine nobody
has an oracle for yet.  It emits, it stamps ORACLE_NONE, and the stamp SAYS the
override was used -- a harness emitted past a refusal must not read like a
registered one in a results tree six months later.  No committed script passes
this flag; hetlitmus/verify/allow-no-oracle-gate.sh enforces that over the tree.
  $ mkdir override
  $ litmus7 -allow-no-oracle -gpu-target hip -o override ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1; echo "exit $?"
  exit 0
  $ ls override/MP-cg-sys-relaxed | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed.hip
  $ grep -c '_rec.het_oracle = ORACLE_NONE;' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1
  $ grep -c '_rec.oracle_source = "(NO-ORACLE: (AArch64, hip) is UNREGISTERED, emitted under -allow-no-oracle)";' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF)' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip || true
  0

(f) CROSS-VENDOR RESIDUE IN THE RENDER.  A single-vendor harness still carries
comparative comments -- het_alloc_hip.inc explains the HIP lane by contrast with
the CUDA one, and its `#error' names the CUDA-only lever it refuses.  Those are
deliberate and are whitelisted BY COUNT here, so the residue is tracked rather
than remembered: a new mention moves this number and has to be argued for.
  $ grep -oiE 'cuda|nvcc|nvidia' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip | sort | uniq -c | sed 's/^ *//'
  7 CUDA
  1 NVIDIA
  4 cuda
  $ grep -oiE '\bhip\b|hipcc|\bamd\b|mi300|cdna' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | sort | uniq -c | sed 's/^ *//'
  1 HIP
  1 MI300

What is NOT whitelisted at any count: a claim about the machine.  A render may
compare itself to the other vendor's; it may not say it IS one.
  $ grep -ciE 'nvlink|grace|hopper|expected-nvidia|NVIDIA-PTX' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -ciE 'infinity fabric|expected-amd|AMD-CDNA3' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
