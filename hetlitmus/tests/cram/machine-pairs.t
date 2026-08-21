THE MACHINE TABLE (litmus/hetMachine.ml).  A compound harness is a CPU ISA and a
GPU dialect running one test, and the machine it may NAME belongs to the PAIR: an
AArch64 CPU column rendered against HIP is a part neither GH200 nor MI300A.
Every pair EMITS; what the table decides is what the render is entitled to claim.

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

(a) Every render stamps the record, exactly once and by the SYMBOL.
het_verdict() reads no field of a record that does not carry HET_REC_MAGIC, so a
render that lost this line would discard every run it ever made.  The two REGISTERED
pairs are read by hetlitmus-recfields, over this same MP-cg-sys-relaxed shape and
by the same rule; the (X86_64, hip) half stays here because the sections below
read that render for its machine defines, and the two dev-tier pairs -- which no
other gate emits -- are read at (c) and (d).
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(b) ...and the MACHINE each pair with a row is entitled to name, stamped as
defines het_verdict.h prints its interconnect prose from.  Keyed on the PAIR,
never on the dialect: keyed on the dialect the dev-tier x86+CUDA emission in (c)
would stamp "the Grace half" on a machine with no Grace in it.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_LINK_NAME "NVLink-C2C"
  #define HET_HOST_HALF "the Grace half"
  #define HET_DEV_HALF "the Hopper half"
  #define HET_LLC_MB 114
  #define HET_ALGLAVE_ZERO_MEASURED 1
  #define HET_PLACE_LEVER "cudaMemAdvise"

HET_ALGLAVE_ZERO_MEASURED is absent on the AMD pair (the "zero without stress"
figure of [Alglave15 sec 4.3.1] is the NVIDIA GTX Titan's -- inter-CTA lb and sb
at 0 per 100k in every unstressed column -- and no equivalent is published for
MI300A),
and so is HET_PLACE_LEVER (the HIP render carries no placement code at all).  An
absent define is the SAFE direction: het_verdict.h's default names the mechanism.
HET_LLC_MB is not absent, because a figure IS published for this part -- 256 MB
of MALL ([Tee25 Table 1]) against Grace's 114 ([Bagchi26 Table 1]), so the ported
constant UNDER-fires the noise-buffer guard here and the target's own figure is
the conservative reading too.
  $ grep -E '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED|PLACE_LEVER)' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_LINK_NAME "Infinity Fabric"
  #define HET_HOST_HALF "the x86 half"
  #define HET_DEV_HALF "the MI300A device half"
  #define HET_LLC_MB 256

Each stamps its OWN pair name.  Read as the whole matched line rather than as a
count, so a renamed pair and a missing define do not share one number.
  $ grep -E '^#define HET_PAIR_NAME' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_PAIR_NAME "(AArch64, cuda)"
  $ grep -E '^#define HET_PAIR_NAME' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  #define HET_PAIR_NAME "(X86_64, hip)"

(c) THE LANDMINE.  (x86_64, cuda) is REGISTERED WITHOUT A MACHINE ROW -- it is
the dev box, and it is neither published part -- so its harnesses may name
neither.  The MI300A machine words appear nowhere in the harness directory.
(`MI300A' alone is not the pin: the CPU stress payload's comments compare the
two hosts by name, and section (f) tracks that residue by count.)
  $ mkdir xc
  $ litmus7 -gpu-target cuda -o xc ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  1
  $ grep -rlE 'Infinity Fabric' xc | wc -l
  0

It names no MACHINE at all: with no defines stamped, het_verdict.h's generic
wording stands, so nothing this harness prints claims to be a Grace or a Hopper,
and no number it prints claims to be this part's last-level cache.  What it does
stamp is the build fact true of the binary whatever the table says -- which pair
it was built for -- and the render says WHY it named no machine, because a
registered pair that is deliberately nameless and a pair nobody has considered
read alike six months later in a results tree.
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu || true
  0
  $ grep -E '^#define HET_PAIR_NAME' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  #define HET_PAIR_NAME "(X86_64, cuda)"
  $ grep -c 'no machine row backs this' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu
  1

(d) UNREGISTERED: (AArch64, hip) is in no row, and it EMITS -- warned, not
refused.  The tool characterizes, so a pair nobody has a machine for still has a
machine somebody can run: what it loses is the right to name it.  The render says
so in band, and stamps not one machine define.
  $ mkdir ah
  $ litmus7 -gpu-target hip -o ah ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1; echo "exit $?"
  exit 0
  $ litmus7 -gpu-target hip -o ah ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null | grep -c 'is in no row of litmus/hetMachine.ml'
  2
  $ ls ah/MP-cg-sys-relaxed | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed.hip
  $ grep -c '_rec.rec_magic = HET_REC_MAGIC;' ah/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1
  $ grep -cE '^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)' ah/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip || true
  0
  $ grep -E '^#define HET_PAIR_NAME' ah/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  #define HET_PAIR_NAME "(AArch64, hip)"
  $ grep -c 'is in no' ah/MP-cg-sys-relaxed/MP-cg-sys-relaxed.hip
  1

(e) WHAT A LANE SAYS, which is a different surface from what it stamps: a
sentence can name a part without any define producing the word, and that is the
only defect in the table nothing downstream could catch -- a harness naming the
wrong machine compiles, runs and reports exactly like one naming the right one.
brandscan.py reads the string literals a driver PRINTS (comments stripped, so the
payloads' comparative notes and their citations survive) plus the README and the
build files, and it is keyed on ENTITLEMENT: the two lanes with a row print their
own machine's words all over, and only the other row's are a finding.
  $ python3 ../../verify/brandscan.py --entitled none ah xc
  brandscan: 2 path(s), no machine word outside the none row
  $ python3 ../../verify/brandscan.py --entitled gh200 aa
  brandscan: 1 path(s), no machine word outside the gh200 row
  $ python3 ../../verify/brandscan.py --entitled mi300a xh
  brandscan: 1 path(s), no machine word outside the mi300a row

...and it is not vacuous.  Two plants in a COPY of the nameless lane, one in the
README's target line and one split across two adjacent literals of a printed
warning -- the shape a per-line grep of `fprintf(' lines cannot see:
  $ cp -r xc xc-planted
  $ P=xc-planted/MP-cg-sys-relaxed-x86_64
  $ sed -i 's/^Target: NVIDIA CUDA\.$/Target: NVIDIA GH200 (CUDA)./' $P/README.md
  $ printf 'static void _planted(void){ fprintf(stderr, "the Grace "\n  "half is idle\\n"); }\n' >> $P/MP-cg-sys-relaxed-x86_64.cu
  $ python3 ../../verify/brandscan.py --entitled none xc-planted; echo "exit $?"
  xc-planted/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu:752: names 'Grace' (the gh200 row's word; this lane is entitled to none): the Grace half is idle
  xc-planted/MP-cg-sys-relaxed-x86_64/README.md:23: names 'GH200' (the gh200 row's word; this lane is entitled to none): Target: NVIDIA GH200 (CUDA).
  FAIL: 2 machine word(s) in a lane entitled to none -- a harness that names the wrong machine runs and reports like one that names the right one
  exit 1

(f) CROSS-VENDOR RESIDUE IN THE RENDER.  A single-vendor harness still carries
comparative comments -- het_alloc_hip.inc explains the HIP lane by contrast with
the CUDA one, and its `#error' names the CUDA-only lever it refuses.  Those are
deliberate and are whitelisted BY COUNT here, so the residue is tracked rather
than remembered: a new mention moves this number and has to be argued for.  The
vendor words below are not machine words -- a dialect is not a part -- which is
why they are counted here and not left to (e).
  $ grep -oiE 'cuda|nvcc|nvidia' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip | sort | uniq -c | sed 's/^ *//'
  7 CUDA
  1 NVIDIA
  4 cuda
  $ grep -oiE '\bhip\b|hipcc|\bamd\b|mi300|cdna' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | sort | uniq -c | sed 's/^ *//'
  1 HIP
  1 MI300

The CUDA render also carries its own DIALECT payload's design notes:
het_alloc_cuda.inc, het_noise_cuda.inc and het_stress.h describe mechanisms
derived for GH200 and name it in COMMENTS, which is where all of the residue
below now is -- the two stress warnings those payloads print take their machine
nouns from the row that resolved (litmus/hetMachine.ml mc_words), so on this lane
they print none.  Whitelisted PER WORD, in the same style, so the residue is
tracked rather than remembered: a bumpable single total is satisfiable by
swapping one mention for another.  The pin is on the RENDER, the file a reader
opens; (e) is the pin on what it says.
  $ grep -oiE 'nvlink|grace|hopper|c2c|gh200' xc/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.cu | sort | uniq -c | sed 's/^ *//'
  11 C2C
  9 GH200
  3 Grace
  3 Hopper
  3 NVLink

What is NOT whitelisted at any count: a claim about the machine.  A render may
compare itself to the other vendor's; it may not say it IS one.
  $ grep -ciE 'nvlink|grace|hopper' xh/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip || true
  0
  $ grep -ciE 'infinity fabric' aa/MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu || true
  0
