What litmus7 refuses before it renders, and that it renders once
(litmus/gpuLang.ml, litmus/HetArch.ml, litmus/hetEmit.ml).

  $ mk () { sed -e "s/NAME/$1/" -e "s|GPUCELL|$2|" base.litmus > "$1.litmus"; mkdir "out-$1"; }
  $ cat > base.litmus <<'EOF'
  > Het NAME
  > {
  > 0:X1=x;
  > 0:X3=y;
  > }
  >  P0:cpu        | P1:gpu               ;
  >  MOV W0,#1     | r[acquire,sys] r0 y  ;
  >  STR W0,[X1]   | GPUCELL              ;
  >  MOV W2,#1     |                      ;
  >  STR W2,[X3]   |                      ;
  > scopes: (sys (gpu (cta P1)))
  > exists (1:r0=1)
  > EOF

(a) an instruction the GPU vocabulary does not admit.
  $ mk rmw 'rmw[relaxed,sys] r1 (add r1 1) x'
  $ litmus7 -gpu-target cuda -o out-rmw rmw.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) rmw.litmus: HetLitmus: P1 (gpu) rmw[relaxed,sys] r1 (add r1 1) x -- the GPU column admits loads, stores and fences only
  exit 3
  $ ls out-rmw

(b) a symbolic register on the GPU column.
  $ mk symreg 'r[relaxed,sys] %T1 x'
  $ litmus7 -gpu-target cuda -o out-symreg symreg.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) symreg.litmus: HetLitmus: P1 (gpu) r[relaxed,sys] %T1 x -- the GPU column takes numbered registers r0, r1, ...
  exit 3
  $ ls out-symreg

(c) an annotation list that is not one order then one scope.
  $ mk noorder 'w[] x 1'
  $ litmus7 -gpu-target cuda -o out-noorder noorder.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) noorder.litmus: HetLitmus: P1 (gpu) w[] x 1 -- a store takes one order from {relaxed,release,sc} then one scope from {cta,gpu,sys}
  exit 3
  $ ls out-noorder
  $ mk revorder 'w[sys,relaxed] x 1'
  $ litmus7 -gpu-target cuda -o out-revorder revorder.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) revorder.litmus: HetLitmus: P1 (gpu) w[sys,relaxed] x 1 -- a store takes one order from {relaxed,release,sc} then one scope from {cta,gpu,sys}
  exit 3
  $ ls out-revorder

(d) a relaxed fence, refused the same way on both targets.
  $ mk fence 'f[relaxed,sys]'
  $ mkdir out-fence-hip
  $ litmus7 -gpu-target cuda -o out-fence fence.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) fence.litmus: HetLitmus: P1 (gpu) f[relaxed,sys] -- a fence takes one order from {acquire,release,acq_rel,sc} then one scope from {cta,gpu,sys}
  exit 3
  $ ls out-fence
  $ litmus7 -gpu-target hip -o out-fence-hip fence.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) fence.litmus: HetLitmus: P1 (gpu) f[relaxed,sys] -- a fence takes one order from {acquire,release,acq_rel,sc} then one scope from {cta,gpu,sys}
  exit 3
  $ ls out-fence-hip

(e) two CPU procs naming two CPU ISAs, before any column is parsed.
  $ cat > mixed.litmus <<'EOF'
  > Het mixed
  > {
  > 0:X1=x;
  > 1:X1=y;
  > }
  >  P0:aarch64    | P1:x86_64     | P2:gpu               ;
  >  MOV W0,#1     | MOV W0,#1     | r[acquire,sys] r0 y  ;
  >  STR W0,[X1]   | STR W0,[X1]   | r[relaxed,sys] r1 x  ;
  > scopes: (sys (gpu (cta P2)))
  > exists (2:r0=1)
  > EOF
  $ mkdir out-mixed
  $ litmus7 -gpu-target cuda -o out-mixed mixed.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (isa-scan) mixed.litmus: HetLitmus: P0 is aarch64 and P1 is x86_64; every CPU proc of a heterogeneous test names one CPU ISA
  exit 3
  $ ls out-mixed

(f) an accepted test is announced once and emitted once, on both dispatch arms.
  $ mk ok 'r[relaxed,sys] r1 x'
  $ litmus7 -gpu-target cuda -o out-ok ok.litmus 2>banner.txt >/dev/null; echo "exit $?"
  exit 0
  $ grep -c 'HetLitmus: emitting CPU+GPU harness for ok' banner.txt
  1
  $ grep -c 'HetLitmus: emitted harness directory' banner.txt
  1
  $ cat > lisa.litmus <<'EOF'
  > LISA lisa
  > {
  > }
  >  P0                 | P1                  ;
  >  w[relaxed,sys] x 1 | r[relaxed,sys] r0 y ;
  >  w[relaxed,sys] y 1 | r[relaxed,sys] r1 x ;
  > exists (1:r0=1 /\ 1:r1=0)
  > EOF
  $ mkdir out-lisa
  $ litmus7 -gpu-target cuda -o out-lisa lisa.litmus 2>lisa.txt >/dev/null; echo "exit $?"
  exit 0
  $ grep -c 'HetLitmus: emitted CUDA' lisa.txt
  1

(g) a scopes: tree litmus7 cannot read, one naming a proc that is not a gpu
proc, and one leaving a gpu proc out.
  $ mk badtree 'r[relaxed,sys] r1 x'
  $ sed -i 's|scopes:.*|scopes: (sys (gpu (cta P1)|' badtree.litmus
  $ litmus7 -gpu-target cuda -o out-badtree badtree.litmus 2>badtree.err >/dev/null; echo "exit $?"
  exit 3
  $ grep -c 'HetLitmus: cannot read the scopes tree "(sys (gpu (cta P1)"' badtree.err
  1
  $ ls out-badtree
  $ mk straytree 'r[relaxed,sys] r1 x'
  $ sed -i 's|scopes:.*|scopes: (sys (gpu (cta P0)))|' straytree.litmus
  $ litmus7 -gpu-target cuda -o out-straytree straytree.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) straytree.litmus: HetLitmus: the scopes tree places P0, which is not a gpu proc
  exit 3
  $ ls out-straytree
  $ cat > omits.litmus <<'EOF'
  > Het omits
  > {
  > 0:X1=x;
  > }
  >  P0:cpu      | P1:gpu              | P2:gpu              ;
  >  MOV W0,#1   | r[acquire,sys] r0 y | r[relaxed,cta] r0 x ;
  >  STR W0,[X1] |                     |                     ;
  > scopes: (sys (gpu (cta P1)))
  > exists (1:r0=1)
  > EOF
  $ mkdir out-omits
  $ litmus7 -gpu-target cuda -o out-omits omits.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) omits.litmus: HetLitmus: the scopes tree places no P2; a declared tree places every gpu proc
  exit 3
  $ ls out-omits

(g2) a cta placing no proc: it would leave the block indices past it with no
lane at (0,0), and nothing to publish the iteration count.
  $ mk emptycta 'r[relaxed,sys] r1 x'
  $ sed -i 's|scopes:.*|scopes: (sys (gpu (cta) (cta P1)))|' emptycta.litmus
  $ litmus7 -gpu-target cuda -o out-emptycta emptycta.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (het) emptycta.litmus: HetLitmus: the scopes tree declares a cta with no proc; a declared cta places at least one gpu proc
  exit 3
  $ ls out-emptycta

(h) a second scopes: row.
  $ mk tworows 'r[relaxed,sys] r1 x'
  $ sed -i 's|^exists|scopes: (sys (gpu (cta P1)))\nexists|' tworows.litmus
  $ litmus7 -gpu-target cuda -o out-tworows tworows.litmus 2>&1 >/dev/null; echo "exit $?"
  HetLitmus REFUSED (isa-scan) tworows.litmus: HetLitmus: a heterogeneous test carries at most one scopes: row
  exit 3
  $ ls out-tworows
