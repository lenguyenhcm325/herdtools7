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
in the CPU wrapper (2 total), each with gd_bar fired ONCE before it (2 arrivals).

The arrival count is matched on `_bar.fetch_add' -- the barrier's OWN atomic -- and
NOT on a bare `fetch_add'.  B5 added the first non-barrier atomic RMW to this file
(the CPU stress tally's __atomic_fetch_add), which a bare `fetch_add' count would
have swept up: the check would then have read 3 and, once bumped to 3, would have
been satisfied by a genuine THIRD BARRIER ARRIVAL -- exactly the regression it exists
to catch.  Matching the barrier's own spelling keeps it discriminating.  (ptxcheck's
barrier whitelist guards the same invariant independently, at the PTX level: one
system-scope fetch_add per barrier-joining GPU lane.)
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2
  $ grep -c '_bar.fetch_add' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2

(d) a SINGLE terminal device sync per RUN.  This is B2's invariant: the kernel is
persistent, so the run loop must sync exactly ONCE, at the end -- a sync inside the
loop would serialise the free-running window and destroy the whole design.

Scoped to the run loop, not counted file-wide.  B5 added a second
cudaDeviceSynchronize in gd_alloc_noise (waiting for the one-shot prefetch that moves
the HBM noise buffer across the interconnect), which happens ONCE at start-up, before
any run, and does not touch this invariant.  Bumping the count to 2 would have made
this check satisfiable by a genuine SECOND SYNC IN THE RUN LOOP -- exactly the
regression it exists to catch.  Scope, don't bump.
  $ sed -n '/for (int _run=0; _run<NUMBER_OF_RUN/,/^  }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'cudaDeviceSynchronize'
  1
  $ sed -n '/^static int gd_alloc_noise/,/^}$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'cudaDeviceSynchronize'
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
