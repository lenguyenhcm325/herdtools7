THE PAIR TABLE (litmus/hetOracle.ml).  A compound harness is a CPU ISA and a GPU
dialect running one test, and the machine it may NAME belongs to the PAIR: an
AArch64 CPU column rendered against HIP is a part neither GH200 nor MI300A.
Three states, and each is pinned here: POPULATED reads a control map and stamps
its machine, REGISTERED-WITHOUT-A-MAP stamps neither, ABSENT refuses.

The harness carries no model prediction at all, so what a result is filed under
is the PAIR NAME -- a harness built for the wrong pair compiles, runs and reports
identically, and only this define says which machine it was measuring.
  $ mkdir aa
  $ litmus7 -gpu-target cuda -o aa ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -c '#define HET_PAIR_NAME "(AArch64, cuda)"' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ mkdir xh
  $ litmus7 -gpu-target hip -o xh ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c '#define HET_PAIR_NAME "(X86_64, hip)"' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(a) POPULATED: every render stamps the record, exactly once and by the SYMBOL.
het_verdict() reads no field of a record that does not carry HET_REC_MAGIC, so a
render that lost this line would discard every run it ever made.
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(b) ...and the MACHINE each populated pair is entitled to name, stamped as defines
het_verdict.h prints its interconnect prose from.  Keyed on the PAIR, never on the
dialect: keyed on the dialect the dev-tier x86+CUDA emission in (c) would stamp
"the Grace half" on a machine with no Grace in it.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_LINK_NAME "NVLink-C2C"
  #define HET_HOST_HALF "the Grace half"
  #define HET_DEV_HALF "the Hopper half"
  #define HET_LLC_MB 114
  #define HET_ALGLAVE_ZERO_MEASURED 1
  #define HET_PLACE_LEVER "cudaMemAdvise"

HET_ALGLAVE_ZERO_MEASURED is absent on the AMD pair (the "zero without stress"
figure was measured on NVIDIA parts and no equivalent is published for MI300A),
and so is HET_PLACE_LEVER (the HIP render carries no placement code at all).  An
absent define is the SAFE direction: het_verdict.h's default names the mechanism.
HET_LLC_MB is not absent, because a figure IS published for this part -- 256 MB
of MALL against Grace's 114, so the ported constant UNDER-fires the noise-buffer
guard here and the target's own figure is the conservative reading too.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_LINK_NAME "Infinity Fabric"
  #define HET_HOST_HALF "the x86 half"
  #define HET_DEV_HALF "the MI300A device half"
  #define HET_LLC_MB 256

(c) THE LANDMINE.  (x86_64, cuda) is REGISTERED WITHOUT A CONTROL MAP -- it is
the dev box, and the AArch64 and x86 strength lattices differ, so a map derived
on one names siblings that are not weakenings on the other.  Keyed on the CPU ISA
alone, as the emitter was until this table existed, that emission read the AMD
control map for all 411 harnesses.  Now it reads none, and neither the AMD map's
own artefacts nor the MI300A machine words this lane must never claim appear
anywhere in the harness directory.  (`MI300A' alone is not the pin: the CPU
stress payload's comments compare the two hosts by name, and section (f) tracks
that residue by count.)
  $ mkdir xc
  $ litmus7 -gpu-target cuda -o xc ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  1
  $ grep -rlE 'expected-amd|AMD-CDNA3-x86|Infinity Fabric' xc | wc -l
  0

It names no MACHINE either: with no defines stamped, het_verdict.h's generic
wording stands, so nothing this harness prints claims to be a Grace or a Hopper,
and no number it prints claims to be this part's last-level cache.
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu || true
  0

What it DOES stamp is the two build facts, true of the binary whatever the table
row says: which pair it was built for -- the short name the verdict and statistics
layers print where they have to identify the target -- and that no
positive-control map was read for it, which is what stops the statistics layer
from reading "nothing co-runs" as "this row IS the canary".
  $ grep -E '^#define HET_(PAIR_NAME|NO_CONTROL_MAP)' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  #define HET_PAIR_NAME "(X86_64, cuda)"
  #define HET_NO_CONTROL_MAP 1

Both populated pairs name themselves and stamp NO such flag: they read a map.
  $ grep -E '^#define HET_(PAIR_NAME|NO_CONTROL_MAP)' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_PAIR_NAME "(AArch64, cuda)"
  $ grep -E '^#define HET_(PAIR_NAME|NO_CONTROL_MAP)' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_PAIR_NAME "(X86_64, hip)"

What the CUDA render still carries is its own DIALECT payload's design notes:
het_alloc_cuda.inc, het_noise_cuda.inc and het_stress.cuh describe mechanisms
derived for GH200 and name it, and one stress warning in het_noise_cuda.inc is
worded for that part.  Whitelisted PER WORD, in section (f)'s style, so the
residue is tracked rather than remembered: a bumpable single total is satisfiable
by swapping one mention for another, and the earlier `nvlink|grace|hopper' pattern
missed `c2c' and `gh200' outright, which are most of what is actually there.  The
pin is on the RENDER: the payload .inc files are pasted into it, and it is the
file a reader opens.  What a result is read off -- the verdict layer's printed
prose -- is define-driven and named none of this even when this pin was blind.
  $ grep -oiE 'nvlink|grace|hopper|c2c|gh200' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu | sort | uniq -c | sed 's/^ *//'
  13 C2C
  9 GH200
  5 Grace
  3 Hopper
  3 NVLink

(d) ABSENT: (AArch64, hip) is in no row, so emission REFUSES.  It names the pair
-- the reader's next question is which one -- and it writes nothing, because a
half-written harness directory is indistinguishable from a complete one to every
script that globs for them.
  $ mkdir absent
  $ litmus7 -gpu-target hip -o absent ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) ../het/MP-cg-sys-relaxed.litmus: no oracle is registered for the CPU-ISA x GPU-dialect pair (AArch64, hip).  The model prediction a harness carries belongs to the PAIR, so tagging this one from a neighbouring row would stamp it with a prediction derived for another machine.  Registered pairs: (AArch64, cuda), (X86_64, hip), (X86_64, cuda).  Add the pair to litmus/hetOracle.ml, or pass -allow-no-oracle to emit it as a characterization-only harness (new hardware only; the render discloses the override).
  exit 3
  $ ls absent

(e) ...and `-allow-no-oracle' is the disclosed way past it, for a machine that is
in no row yet.  It emits, and what it emits names its own pair, admits it read no
control map, and says in the render that it was emitted under the flag -- a harness
emitted past a refusal must not read like a registered one in a results tree six
months later.  No committed script passes this flag;
hetlitmus/verify/allow-no-oracle-gate.sh enforces that over the tree.
  $ mkdir override
  $ litmus7 -allow-no-oracle -gpu-target hip -o override ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1; echo "exit $?"
  exit 0
  $ ls override/MP-cg-sys-relaxed | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed.hip
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB)' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip || true
  0
  $ grep -E '^#define HET_(PAIR_NAME|NO_CONTROL_MAP)' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  #define HET_PAIR_NAME "(AArch64, hip)"
  #define HET_NO_CONTROL_MAP 1

Those two defines are exactly what a REGISTERED pair with no map stamps as well
(section (c)), so neither of them says a refusal was overridden.  One line does,
and it is the whole in-band trace: the flag is a human's, typed once, and the
person reading the results tree afterwards is not that human.
  $ grep -c 'EMITTED UNDER -allow-no-oracle' override/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1
  $ grep -c 'EMITTED UNDER -allow-no-oracle' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu || true
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

What is NOT whitelisted at any count: a claim about the machine, or the name of
a retired verdicts file.  A render may compare itself to the other vendor's; it
may not say it IS one, and it carries no verdict at all.
  $ grep -ciE 'nvlink|grace|hopper|expected-nvidia|NVIDIA-PTX' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -ciE 'infinity fabric|expected-amd|AMD-CDNA3' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
