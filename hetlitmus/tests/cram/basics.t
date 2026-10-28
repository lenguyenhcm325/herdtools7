Unit spec of the corpus rule functions in tests/grid.py.

  $ g () { PYTHONDONTWRITEBYTECODE=1 python3 -c "
  > import sys; sys.path.insert(0, '..'); import grid; from grid import *
  > try: print($1)
  > except grid.GridError as e: print(e); sys.exit(1)
  > "; }

render_gpu: rlx makes every access Relaxed.
  $ g 'render_gpu("sys", "rlx", "PodWW Rfe PodRR Fre")'
  PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
acq: reads -> Acquire, writes -> Relaxed.
  $ g 'render_gpu("gpu", "acq", "PodWW Rfe PodRR Fre")'
  PodWWRelaxedGpuRelaxedGpu RfeRelaxedGpuAcquireGpu PodRRAcquireGpuAcquireGpu FreAcquireGpuRelaxedGpu
rel: writes -> Release, reads -> Relaxed.
  $ g 'render_gpu("sys", "rel", "PodWW Rfe PodRR Fre")'
  PodWWReleaseSysReleaseSys RfeReleaseSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysReleaseSys
ra: reads -> Acquire AND writes -> Release.
  $ g 'render_gpu("sys", "ra", "PodWW Rfe PodRR Fre")'
  PodWWReleaseSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys
sc: every access Sc.
  $ g 'render_gpu("sys", "sc", "PodWW Rfe PodRR Fre")'
  PodWWScSysScSys RfeScSysScSys PodRRScSysScSys FreScSysScSys
Fence orders keep accesses Relaxed and add a fence edge per Pod<XY>.
  $ g 'render_gpu("cta", "fsc", "PodWW Rfe PodRR Fre")'
  FenceScCtadWWRelaxedCtaRelaxedCta RfeRelaxedCtaRelaxedCta FenceScCtadRRRelaxedCtaRelaxedCta FreRelaxedCtaRelaxedCta
  $ g 'render_gpu("sys", "fsc", "PodWR Fre PodWR Fre")'
  FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ g 'render_gpu("gpu", "facq", "PodWR Fre PodWR Fre")'
  FenceAcquireGpudWRRelaxedGpuRelaxedGpu FreRelaxedGpuRelaxedGpu FenceAcquireGpudWRRelaxedGpuRelaxedGpu FreRelaxedGpuRelaxedGpu
  $ g 'render_gpu("sys", "frel", "PodWR Fre PodWR Fre")'
  FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ g 'render_gpu("cta", "fra", "PodWR Fre PodWR Fre")'
  FenceAcqrelCtadWRRelaxedCtaRelaxedCta FreRelaxedCtaRelaxedCta FenceAcqrelCtadWRRelaxedCtaRelaxedCta FreRelaxedCtaRelaxedCta
A Pos<XY> edge carries its location letter into the fence spelling.
  $ g 'render_gpu("sys", "fsc", "Rfe PosRR Fre")'
  RfeRelaxedSysRelaxedSys FenceScSyssRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ g 'render_gpu("sys", "acq", "Rfe PosRR Fre")'
  RfeRelaxedSysAcquireSys PosRRAcquireSysAcquireSys FreAcquireSysRelaxedSys
An order or a scope outside the tables is refused.
  $ g 'render_gpu("sys", "acqrel", "PodWW Rfe PodRR Fre")'; echo "exit $?"
  bad gpu order: acqrel (one of: rlx acq rel ra sc fsc facq frel fra)
  exit 1
  $ g 'render_gpu("cluster", "rlx", "PodWW Rfe PodRR Fre")'; echo "exit $?"
  bad scope: cluster (one of: cta gpu sys)
  exit 1

render_cpu: aarch64 plain is the bare cycle.
  $ g 'render_cpu("aarch64", "plain", "PodWR Fre PodWR Fre")'
  PodWR Fre PodWR Fre
ra: read -> LDAPR (Q), write -> STLR (L).
  $ g 'render_cpu("aarch64", "ra", "PodWR Fre PodWR Fre")'
  PodWRLQ FreQL PodWRLQ FreQL
sy: each intra-proc Pod<XY> becomes the full-barrier edge DMB.SYd<XY>.
  $ g 'render_cpu("aarch64", "sy", "PodWW Rfe PodRR Fre")'
  DMB.SYdWW Rfe DMB.SYdRR Fre
  $ g 'render_cpu("aarch64", "sy", "PodWR Fre PodWR Fre")'
  DMB.SYdWR Fre DMB.SYdWR Fre
The same letter reaches the CPU barrier edge: a same-location pair gives DMB.SYs<XY>.
  $ g 'render_cpu("aarch64", "sy", "PosWR Fre Coe")'
  DMB.SYsWR Fre Coe
st / ld: the partial barriers.
  $ g 'render_cpu("aarch64", "st", "PodWR Fre PodWR Fre")'
  DMB.STdWR Fre DMB.STdWR Fre
  $ g 'render_cpu("aarch64", "ld", "PodWR Fre PodWR Fre")'
  DMB.LDdWR Fre DMB.LDdWR Fre
x86_64: plain is the bare cycle; mf is MFence on each intra-proc edge.
  $ g 'render_cpu("x86_64", "plain", "PodWR Fre PodWR Fre")'
  PodWR Fre PodWR Fre
  $ g 'render_cpu("x86_64", "mf", "PodWR Fre PodWR Fre")'
  MFencedWR Fre MFencedWR Fre
  $ g 'render_cpu("x86_64", "mf", "PosWR Fre Coe")'
  MFencesWR Fre Coe
An ISA with no profile, or an order outside it, is refused.
  $ g 'render_cpu("riscv", "mf", "PodWR Fre PodWR Fre")'; echo "exit $?"
  unknown cpu arch: riscv (one of: aarch64 x86_64)
  exit 1
  $ g 'render_cpu("x86_64", "sy", "PodWR Fre PodWR Fre")'; echo "exit $?"
  bad cpu order: sy for x86_64 (one of: plain mf)
  exit 1

cut_tag -- device-cut abbreviation, 2-proc and 3-proc.
  $ g 'cut_tag("cpu,gpu")'
  cg
  $ g 'cut_tag("gpu,cpu,cpu")'
  gcc

scope_tree: one CTA per proc.
  $ g 'scope_tree(2)'
  (sys (gpu (cta 0) (cta 1)))
  $ g 'scope_tree(3)'
  (sys (gpu (cta 0) (cta 1) (cta 2)))

cut_classes: SB is one segment twice, so one class.
  $ g '" ".join(cut_classes("PodWR Fre PodWR Fre"))'
  cg
MP: two different segments, so both cuts.
  $ g '" ".join(cut_classes("PodWW Rfe PodRR Fre"))'
  cg gc
IRIW: invariant under rotation by two procs, so each class is that orbit.
  $ g '" ".join(cut_classes("Rfe PodRR Fre Rfe PodRR Fre"))'
  cccg ccgc ccgg cgcg cggc cggg gcgc gcgg
WRC has no symmetry.
  $ g '" ".join(cut_classes("Rfe PodRW Rfe PodRR Fre"))'
  ccg cgc cgg gcc gcg ggc
3.2W: all three threads have the same shape.
  $ g '" ".join(cut_classes("PodWW Coe PodWW Coe PodWW Coe"))'
  ccg cgg
