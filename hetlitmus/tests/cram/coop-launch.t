B2 regression guard: the emitted het GPU driver must be a persistent, launch-once
perpetual loop whose forward progress is guaranteed by cudaLaunchCooperativeKernel
(HIP: hipLaunchCooperativeKernel), NOT the old per-iteration <<<>>> relaunch.  We
emit the representative MP shape once (het emission needs no -set-libdir; one run
emits both .cu and .hip) and assert the structural invariants with robust counts.

  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1

(a) exactly ONE cooperative launch, and ZERO chevron launches, per run.
  $ grep -c cudaLaunchCooperativeKernel MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '<<<' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(b,c) the inner free-running window: one for(_n<SIZE_OF_TEST) in the kernel AND one
in the CPU wrapper (2 total), each with gd_bar fired ONCE before it (2 fetch_add).
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2
  $ grep -c 'fetch_add' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2

(d) a SINGLE terminal device sync per run.
  $ grep -c 'cudaDeviceSynchronize' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(e) cooperative launch is used ONLY for co-residency: no cooperative_groups.h, no
grid.sync().
  $ grep -cE 'cooperative_groups|grid\.sync' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(f) the perpetual bounds are Cfg-driven #defines; no re-hardcoded relaunch loop.
  $ grep -cE '#define SIZE_OF_TEST|#define NUMBER_OF_RUN' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2
  $ grep -c 'const int iterations' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(g) the grid <= co-resident cap guard is installed (B4 raises _grid but keeps it).
  $ grep -c '_grid > _maxGrid' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The HIP twin renders the same shape from the same template: one hipLaunchCooperativeKernel.
  $ grep -c hipLaunchCooperativeKernel MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.hip
  1
