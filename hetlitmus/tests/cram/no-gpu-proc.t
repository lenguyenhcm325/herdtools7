The gpu-proc requirement (litmus/hetEmit.ml, gen/hetGen.ml).

(a) an all-CPU `Het' test is refused, and no harness directory is written.
  $ cat > SB-cpu-only.litmus <<'EOF'
  > Het SB-cpu-only
  > {
  > }
  >  P0:x86_64     | P1:x86_64     ;
  >  movl $1,(x)   | movl $1,(y)   ;
  >  movl (y),%eax | movl (x),%eax ;
  > scopes: (sys)
  > exists (0:eax=0 /\ 1:eax=0)
  > EOF
  $ mkdir out
  $ litmus7 -gpu-target cuda -o out SB-cpu-only.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) SB-cpu-only.litmus: hetlitmus: SB-cpu-only has no gpu proc; a het test needs at least one, and an all-CPU test is litmus7's own X86_64 path
  exit 3
  $ ls out

(b) so is a hetgen7 `-devices' list naming no gpu proc, on hetgen7's own fatal path.
  $ hetgen7 -set-libdir ../../../herd/libdir -bell ../../bells/ptx.bell -cpu-arch x86_64 -devices cpu,cpu -name SB -cpu 'PodWR Fre PodWR Fre' -gpu 'PodWR Fre PodWR Fre' 2>&1 >/dev/null; echo "exit $?"
  Fatal error: exception Misc.Fatal("-devices cpu,cpu names no gpu proc; a het test needs at least one, and an all-CPU cycle is diyone7's own -arch X86_64/AArch64")
  exit 2
