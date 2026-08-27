Persistent-loop guard (hetlitmus/docs/00-environment-design.md sec 3.3).

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1

(a) exactly ONE cooperative launch and no chevron launch per run.
  $ grep -c cudaLaunchCooperativeKernel MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '<<<' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(b,c) the inner window: one GPU lane and one CPU wrapper, so the
for(_n<SIZE_OF_TEST) loops total 3 with the host readout's own walk.
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  3

NPART counts both participants, so the rendezvous waits for both.
  $ grep -c '#define NPART 2' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(d) exactly ONE terminal device sync per run, scoped to the run loop:
gd_alloc_noise holds a second, for the start-up prefetch before any run.
  $ sed -n '/for (int _run=0; _run<_runs_budget/,/^  }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'cudaDeviceSynchronize'
  1
  $ sed -n '/^static int gd_alloc_noise/,/^}$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'cudaDeviceSynchronize'
  1

(e) cooperative launch is used ONLY for co-residency: no cooperative_groups.h, no
grid.sync().
  $ grep -cE 'cooperative_groups|grid\.sync' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(f) the perpetual bounds are Cfg-driven #defines.
  $ grep -cE '#define SIZE_OF_TEST|#define NUMBER_OF_RUN' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2

(g) the grid <= co-resident cap guard, pinned here alone: it must stay installed
when the stress layer raises _grid toward the cap.
  $ grep -c '_grid > _maxGrid' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The HIP twin renders the same shape from the same template.
  $ grep -c hipLaunchCooperativeKernel hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip
  1

(h) the launch geometry is the test's own scope tree: two GPU procs in one cta
are one block of two lanes, in two ctas two blocks of one.
  $ cat > tree.litmus <<'EOF'
  > Het tree
  > {
  > 0:X1=x;
  > 0:X3=y;
  > }
  >  P0:cpu      | P1:gpu              | P2:gpu              ;
  >  MOV W0,#1   | r[acquire,sys] r0 y | r[relaxed,cta] r0 x ;
  >  STR W0,[X1] | r[relaxed,sys] r1 x |                     ;
  > scopes: TREE
  > exists (1:r0=1)
  > EOF
  $ geo () { sed "s|TREE|$1|" tree.litmus > "$2.litmus"; mkdir "$2"; litmus7 -gpu-target cuda -o "$2" "$2.litmus" >/dev/null 2>&1; grep -E '#define HET_(BLOCK_DIM|TEST_BLOCKS) ' "$2/tree/tree.cu"; }
  $ geo '(sys (gpu (cta P1 P2)))' onecta
  #define HET_BLOCK_DIM 2
  #define HET_TEST_BLOCKS 1
  $ geo '(sys (gpu (cta P1) (cta P2)))' twoctas
  #define HET_BLOCK_DIM 1
  #define HET_TEST_BLOCKS 2

The two-cta launch guards its lanes by block, the one-cta launch by lane.
  $ grep -c 'blockIdx.x == 1 && threadIdx.x == 0' twoctas/tree/tree.cu
  1
  $ grep -c 'blockIdx.x == 0 && threadIdx.x == 1' onecta/tree/tree.cu
  1
