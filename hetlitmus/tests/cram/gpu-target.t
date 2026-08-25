`-gpu-target' (litmus/hetDialect.ml; hetlitmus/docs/hip-emitter.md).

(a) a CUDA emission carries the .cu and not the .hip.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ ls MP-cg-sys-relaxed | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed.cu

(b) ...and its build files and its prose name that vendor only.
  $ grep -ciE 'hip|amd' MP-cg-sys-relaxed/comp.sh MP-cg-sys-relaxed/Makefile MP-cg-sys-relaxed/README.md || true
  MP-cg-sys-relaxed/comp.sh:0
  MP-cg-sys-relaxed/Makefile:0
  MP-cg-sys-relaxed/README.md:0
  $ grep -c 'Usage: sh comp.sh \[cuda|cuda-link\]' MP-cg-sys-relaxed/comp.sh
  1

(c) the HIP emission is the mirror image, from the (x86_64, hip) fixture: the
flag names a GPU dialect, but a harness is a (CPU ISA x GPU dialect) pair.
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ ls hip/MP-cg-sys-relaxed-x86_64 | grep -E '\.(cu|hip)$'
  MP-cg-sys-relaxed-x86_64.hip
  $ H=hip/MP-cg-sys-relaxed-x86_64
  $ grep -ciE 'cuda|nvidia|nvcc' $H/comp.sh $H/Makefile $H/README.md || true
  hip/MP-cg-sys-relaxed-x86_64/comp.sh:0
  hip/MP-cg-sys-relaxed-x86_64/Makefile:0
  hip/MP-cg-sys-relaxed-x86_64/README.md:0

(d) the .hip banner names the hip build commands, not a rule this directory has
no arm for.
  $ grep -c 'comp.sh hip-link / make hip-bin' hip/MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64.hip
  1

(e) both ways, the absent vendor's build entry points refuse by name, leaving no
object and no binary; GNU make's `make:' prefix follows MAKELEVEL, so it is unread.
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

(g) and so does omitting it: there is no default vendor.
  $ mkdir flagless
  $ litmus7 -o flagless ../het/MP-cg-sys-relaxed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) ../het/MP-cg-sys-relaxed.litmus: -gpu-target <cuda|hip> is required: an emission renders ONE GPU dialect, and the harness it writes carries only that vendor's render and build targets
  exit 3
  $ ls flagless

(h) the GPU-only (scoped LISA) arm takes the same flag and refuses the same way.
  $ mkdir gpu
  $ litmus7 -gpu-target cuda -o gpu ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ ls gpu | grep -E '\.(cu|hip)$'
  MP-sys-acquire.cu
  $ mkdir gpu-flagless
  $ litmus7 -o gpu-flagless ../gpu-only/MP-sys-acquire.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (gpu-only) ../gpu-only/MP-sys-acquire.litmus: -gpu-target <cuda|hip> is required: an emission renders ONE GPU dialect, and the harness it writes carries only that vendor's render and build targets
  exit 3

(i) a plain CPU-only litmus7 run neither needs the flag nor is changed by it.
The libdir is walked up from cwd because it cannot be a dune dep (see ./dune).
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
