Persistent-loop guard (hetlitmus/docs/00-environment-design.md sec 3.3).  The
emitted het GPU driver is a persistent, launch-once loop whose forward progress
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

(b,c) the inner window: one for(_n<SIZE_OF_TEST) in the kernel and one in the
CPU wrapper, and INSIDE each of them the participant's own rendezvous, so every
iteration begins with both sides at the same iteration number.  A rendezvous
lifted out of a loop would join the two devices once and leave every iteration
after the first unsynchronised, which is why the counts below are scoped to the
loop and not to the file.

The two calls are named apart -- het_rdv_device on the GPU lane, het_rdv_host on
the CPU wrapper -- so a lane that lost its own and gained the other's cannot
satisfy a total.  (rdvcheck.py guards the same invariant over the whole corpus,
and ptxcheck's rendezvous whitelist guards it again at the PTX level: one
system-scope arrival per rendezvous-joining GPU lane.)

MP-cg-sys-acqrel-2s runs one GPU lane and one CPU wrapper, so each call appears
once and the loops total 3: the host readout walks the slots over a loop of its
own, after the run rather than inside it.
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  3
  $ grep -c 'het_rdv_device(' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'het_rdv_host(' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  1
  $ sed -n '/if (blockIdx.x == 0 && threadIdx.x == 0) {/,/^  }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n)'
  1
  $ sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^    }$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | grep -c 'het_rdv_device('
  1
  $ sed -n '/static void\* cpu_thread_P0/,/^}$/p' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu | sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^  }$/p' | grep -c 'het_rdv_host('
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
