`-gpu-target' -- litmus7's GPU emission target (litmus/hetDialect.ml).  ONE vendor
per emission: the harness directory carries that vendor's render and that vendor's
build arms, and nothing of any other vendor's.  The flag is MANDATORY on the two
GPU-emitting arms; a harness whose vendor came from a default is a harness nobody
chose, and on a box with one toolchain the wrong default is a build that fails
long after the choice was made.

(a) a CUDA emission: the .cu is there, the .hip is not.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ ls MP-cg-sys-relaxed | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed.cu

(b) ...and its build files name that vendor ONLY: no hip case arm, no hip-bin
rule, no HIPCC.  A grep for the WORD would also hit prose, so the emitted prose
is greped too -- under -gpu-target a single-vendor directory must not describe a
second vendor's targets to its reader either.
  $ grep -ciE 'hip|amd' MP-cg-sys-relaxed/comp.sh || true
  0
  $ grep -ciE 'hip|amd' MP-cg-sys-relaxed/Makefile || true
  0
  $ grep -ciE 'hip|amd' MP-cg-sys-relaxed/README.md || true
  0
  $ grep -c 'Usage: sh comp.sh \[cuda|cuda-link\]' MP-cg-sys-relaxed/comp.sh
  1

(c) the HIP emission is the mirror image, into its own directory.  It comes from
an x86-64 rendering, not from the AArch64 corpus above: `-gpu-target' names a GPU
dialect but a harness is a (CPU ISA x GPU dialect) PAIR, so a HIP harness here is
the (x86_64, hip) pair, from the committed fixture ../het-x86.
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ ls hip/MP-cg-sys-relaxed-x86_64 | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed-x86_64.hip
  $ grep -ciE 'cuda|nvidia|nvcc' hip/MP-cg-sys-relaxed-x86_64/comp.sh || true
  0
  $ grep -ciE 'cuda|nvidia|nvcc' hip/MP-cg-sys-relaxed-x86_64/Makefile || true
  0
  $ grep -ciE 'cuda|nvidia|nvcc' hip/MP-cg-sys-relaxed-x86_64/README.md || true
  0

(d) the .hip banner names the HIP build commands -- this directory carries the
hip arms and no cuda ones, so naming a cuda target here would send its reader to
a rule that does not exist.
  $ grep -c 'comp.sh hip-link / make hip-bin' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(e) BITE, both ways: the absent vendor's build entry points refuse by name.  Not
a silent no-op, and above all not a fall-through to the vendor that IS here -- a
`make hip-bin' that quietly linked the CUDA harness would hand back a binary for
the wrong device under the right name.  Each entry point is pinned by the exit
status and the payload of a single run; GNU make prefixes its diagnostics
`make:' or `make[1]:' according to MAKELEVEL, which is a property of how this
test was invoked and not of the harness, so the prefix is not read.  Neither
refusal needs a GPU toolchain: make refuses before running any recipe, and
comp.sh refuses in its target dispatch, leaving no object of the absent vendor
and no linked binary behind.
  $ cd MP-cg-sys-relaxed
  $ make hip-bin >/dev/null 2>../hip-bin.err; echo "exit $?"
  exit 2
  $ grep -cE "No rule to make target .hip-bin." ../hip-bin.err
  1
  $ sh comp.sh hip >/dev/null 2>../comp-hip.err; echo "exit $?"
  exit 2
  $ grep -c 'comp.sh: unknown target "hip" -- this directory is cuda-only (accepted: cuda|cuda-link)' ../comp-hip.err
  1
  $ ls MP-cg-sys-relaxed_hip.o MP-cg-sys-relaxed 2>/dev/null | wc -l
  0
  $ cd ../hip/MP-cg-sys-relaxed-x86_64
  $ make cuda-bin >/dev/null 2>../cuda-bin.err; echo "exit $?"
  exit 2
  $ grep -cE "No rule to make target .cuda-bin." ../cuda-bin.err
  1
  $ sh comp.sh cuda >/dev/null 2>../comp-cuda.err; echo "exit $?"
  exit 2
  $ grep -c 'comp.sh: unknown target "cuda" -- this directory is hip-only (accepted: hip|hip-link)' ../comp-cuda.err
  1
  $ ls MP-cg-sys-relaxed-x86_64.o MP-cg-sys-relaxed-x86_64 2>/dev/null | wc -l
  0
  $ cd ../..

(f) an unregistered target REFUSES, naming the accepted set, and writes nothing.
  $ mkdir bogus
  $ litmus7 -gpu-target sycl -o bogus ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) ../het/MP-cg-sys-relaxed.litmus: unknown -gpu-target "sycl" (accepted: cuda|hip)
  exit 3
  $ ls bogus

(g) and so does OMITTING it: no default vendor exists.  The message names the
flag and the accepted set, because the reader's next command is the fixed one.
  $ mkdir flagless
  $ litmus7 -o flagless ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) ../het/MP-cg-sys-relaxed.litmus: -gpu-target <cuda|hip> is required: an emission renders ONE GPU dialect, and the harness it writes carries only that vendor's render and build targets
  exit 3
  $ ls flagless

(h) the GPU-only (scoped LISA) arm takes the same flag, and refuses the same way.
  $ mkdir gpu
  $ litmus7 -gpu-target cuda -o gpu ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ ls gpu | grep -E '\.(cu|hip)$'
  MP-sys-acquire.cu
  $ mkdir gpu-flagless
  $ litmus7 -o gpu-flagless ../gpu-only/MP-sys-acquire.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (gpu-only) ../gpu-only/MP-sys-acquire.litmus: -gpu-target <cuda|hip> is required: an emission renders ONE GPU dialect, and the harness it writes carries only that vendor's render and build targets
  exit 3

(i) THE BOUNDARY.  `-gpu-target' is a GPU-emission option: a plain CPU-only
litmus7 run neither needs it nor is changed by it.  litmus7 is a general tool and
this branch must not make its upstream behaviour conditional on a HetLitmus flag.
This is the one emission here that needs litmus7's libdir, and the libdir is
located by walking up from cwd -- it cannot be a dune dep (see ./dune).
  $ LIB=$(d=.; while [ ! -f "$d/litmus/libdir/_aarch64/mbar.c" ] && [ "$(cd "$d" && pwd)" != / ]; do d=$d/..; done; echo "$d/litmus/libdir")
  $ test -f "$LIB/header.txt" && echo libdir-found
  libdir-found
  $ cat > SB.litmus <<'EOF'
  > AArch64 SB
  > { 0:X1=x; 0:X3=y; 1:X1=y; 1:X3=x; }
  >  P0           | P1           ;
  >  MOV W0,#1    | MOV W0,#1    ;
  >  STR W0,[X1]  | STR W0,[X1]  ;
  >  LDR W2,[X3]  | LDR W2,[X3]  ;
  > exists (0:X2=0 /\ 1:X2=0)
  > EOF
  $ mkdir plain
  $ litmus7 -set-libdir "$LIB" -o plain SB.litmus 2>&1 >/dev/null; echo "exit $?"
  exit 0
  $ ls plain/SB.c
  plain/SB.c
  $ grep -c gpu-target plain/SB.c plain/Makefile plain/comp.sh || true
  plain/SB.c:0
  plain/Makefile:0
  plain/comp.sh:0
