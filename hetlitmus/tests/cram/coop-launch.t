Perpetual-loop guard (hetlitmus/docs/00-environment-design.md sec 3.3).  The emitted
het GPU driver is a persistent, launch-once perpetual loop whose forward progress
is guaranteed by cudaLaunchCooperativeKernel (HIP: hipLaunchCooperativeKernel),
never a per-iteration <<<>>> relaunch.  The representative MP shape is emitted
once per GPU dialect -- het emission needs no -set-libdir, and litmus7 renders
the ONE dialect -gpu-target names -- and the structural invariants are pinned
with robust counts.

The `.hip' renders come from ../het-x86, not from ../het: a harness is a
(CPU ISA x GPU dialect) PAIR, and a HIP harness is the (x86_64, hip) one.  The
CPU column differs; everything these sections read is the GPU render and the
shared runtime headers.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ mkdir hip
  $ litmus7 -gpu-target hip -o hip ../het-x86/MP-cg-sys-acqrel-2s-x86_64.litmus >/dev/null 2>&1

(a) exactly ONE cooperative launch, and ZERO chevron launches, per run.
  $ grep -c cudaLaunchCooperativeKernel MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c '<<<' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

(b,c) the inner free-running window: one for(_n<SIZE_OF_TEST) in the kernel and
one in the CPU wrapper, each with gd_bar fired once before it -- 2 loops and 2
arrivals.

The arrival count is matched on `_bar.fetch_add', the barrier's OWN atomic, and
not on a bare `fetch_add': the CPU stress tally is an atomic RMW in this file
too, which a bare count would sweep up, and bumping the expectation to absorb it
would leave the check satisfiable by a genuine third barrier arrival -- exactly
the regression it exists to catch.  (ptxcheck's barrier whitelist guards the same
invariant independently, at the PTX level: one system-scope fetch_add per
barrier-joining GPU lane.)

MP-cg-sys-acqrel-2s runs one GPU lane and one CPU wrapper.  The invariant is
per-participant -- one free-running window each, one barrier arrival before each
-- so the totals are 2.  The counts are also scoped to the GPU lane, so 2 cannot
be satisfied by a lane that lost its barrier while another gained a second loop.
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2
  $ grep -c '_bar.fetch_add' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  2
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)'
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c '_bar.fetch_add'
  1

and NPART counts them, so the rendezvous waits for both.
  $ grep -c '#define NPART 2' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

(d) a SINGLE terminal device sync per RUN.  The kernel is persistent, so the run
loop syncs exactly once, at the end: a sync inside the loop would serialise the
free-running window and destroy the whole design.

Scoped to the run loop, not counted file-wide.  gd_alloc_noise holds a second
cudaDeviceSynchronize -- waiting for the one-shot prefetch that moves the HBM
noise buffer across the interconnect -- which happens once at start-up, before
any run, and does not touch this invariant.  Bumping the count to 2 would make
this check satisfiable by a genuine second sync in the run loop.
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
when the stress layer raises _grid toward the cap.  stress.t (c) reads that
raise; this section reads the guard.
  $ grep -c '_grid > _maxGrid' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1

The HIP twin renders the same shape from the same template: one hipLaunchCooperativeKernel.
  $ grep -c hipLaunchCooperativeKernel hip/MP-cg-sys-acqrel-2s-x86_64/MP-cg-sys-acqrel-2s-x86_64.hip
  1
