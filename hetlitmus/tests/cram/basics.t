Layer-1 unit spec of the corpus rule functions in tests/_grid_lib.sh.  This is a
curated sample -- ONE line per rule branch (and one per dispatch token of the
two-sided pair grid), NOT the whole shape x scope x order grid (that is the
Layer-2 corpus golden's job; see TEST-PLAN.md sec 2 "Coverage map").  The corpus golden byte-diffs what
these functions PRODUCE, which catches drift but cannot say the current rendering
is right; that is this file's job, so a branch missing here has no spec.  dune cram
runs each `$' line under /bin/sh (dash), which cannot `source' a bash script with
`declare -A', so each call is wrapped in `bash -c' (re-sourcing the pure lib is
free).

render_cycle -- the GPU/Bell annotator, one line per order branch, scope varied
so all of Sys/Gpu/Cta appear.  relaxed: every access Relaxed.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys relaxed PodWW Rfe PodRR Fre'
  PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
acquire: reads -> Acquire, writes -> Relaxed.
  $ bash -c 'source ../_grid_lib.sh; render_cycle gpu acquire PodWW Rfe PodRR Fre'
  PodWWRelaxedGpuRelaxedGpu RfeRelaxedGpuAcquireGpu PodRRAcquireGpuAcquireGpu FreAcquireGpuRelaxedGpu
release: writes -> Release, reads -> Relaxed.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys release PodWW Rfe PodRR Fre'
  PodWWReleaseSysReleaseSys RfeReleaseSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysReleaseSys
fence: accesses stay Relaxed; each intra-proc Pod<XY> becomes a scoped fence edge.
  $ bash -c 'source ../_grid_lib.sh; render_cycle cta fence PodWW Rfe PodRR Fre'
  FenceScCtadWWRelaxedCtaRelaxedCta RfeRelaxedCtaRelaxedCta FenceScCtadRRRelaxedCtaRelaxedCta FreRelaxedCtaRelaxedCta
acqrel: the complete pair in one cycle -- reads -> Acquire AND writes -> Release.
Reachable only through the two-sided family, so nothing else specifies it.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys acqrel PodWW Rfe PodRR Fre'
  PodWWReleaseSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys
Same-location program order: a Pos<XY> edge carries its own location letter into
the fence spelling (FenceSc<Scope>s<XY>, double s), and on a non-fence order the
base edge reaches the atom path unchanged.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys fence Rfe PosRR Fre'
  RfeRelaxedSysRelaxedSys FenceScSyssRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys acquire Rfe PosRR Fre'
  RfeRelaxedSysAcquireSys PosRRAcquireSysAcquireSys FreAcquireSysRelaxedSys
render_cpu_cycle -- the AArch64 mirror.  acqrel: read -> LDAPR (Q), write -> STLR (L).
  $ bash -c 'source ../_grid_lib.sh; render_cpu_cycle acqrel PodWR Fre PodWR Fre'
  PodWRLQ FreQL PodWRLQ FreQL
fence: each intra-proc Pod<XY> becomes the full-barrier edge DMB.SYd<XY>.
  $ bash -c 'source ../_grid_lib.sh; render_cpu_cycle fence PodWW Rfe PodRR Fre'
  DMB.SYdWW Rfe DMB.SYdRR Fre
The same letter reaches the CPU barrier edge: a same-location pair gives DMB.SYs<XY>.
  $ bash -c 'source ../_grid_lib.sh; render_cpu_cycle fence PosWR Fre Coe'
  DMB.SYsWR Fre Coe
render_2s_cpu -- the two-sided order-pair dispatcher, one line per dispatch
token, on the SB cycle the pair grid sweeps.  It is the ONLY caller of
render_cpu_cycle's partial-barrier branches, so st/ld here are also the unit spec
of DMB.ST / DMB.LD.  `ra' reproduces the acqrel line above token for token; that
identity is exactly what the branch asserts.
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu ra PodWR Fre PodWR Fre'
  PodWRLQ FreQL PodWRLQ FreQL
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu sy PodWR Fre PodWR Fre'
  DMB.SYdWR Fre DMB.SYdWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu st PodWR Fre PodWR Fre'
  DMB.STdWR Fre DMB.STdWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu ld PodWR Fre PodWR Fre'
  DMB.LDdWR Fre DMB.LDdWR Fre
render_2s_gpu -- the GPU half of the same grid.  `ra' delegates to render_cycle
sys acqrel (atoms on the accesses); sc/rel/acq keep every access Relaxed at sys
scope and put the ordering in a standalone Fence<o>Sysd<XY> edge, through their
own rendering loop rather than a parameter -- which is why each is pinned.
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu ra PodWR Fre PodWR Fre'
  PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu sc PodWR Fre PodWR Fre'
  FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu rel PodWR Fre PodWR Fre'
  FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu acq PodWR Fre PodWR Fre'
  FenceAcquireSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceAcquireSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
That loop spells its own fence edge, so the location letter is pinned here too;
the pair grid generates no same-location cell (SHAPE_2S_PAIR_CUTS says why).
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu sc Rfe PosRR Fre'
  RfeRelaxedSysRelaxedSys FenceScSyssRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
cut_tag -- device-cut abbreviation, 2-proc and 3-proc.
  $ bash -c 'source ../_grid_lib.sh; cut_tag cpu,gpu'
  cg
  $ bash -c 'source ../_grid_lib.sh; cut_tag gpu,cpu,cpu'
  gcc
scope_tree -- the parseable scopes: tree (each proc its own CTA), 2-proc and 3-proc.
  $ bash -c 'source ../_grid_lib.sh; scope_tree 2'
  (sys (gpu (cta 0) (cta 1)))
  $ bash -c 'source ../_grid_lib.sh; scope_tree 3'
  (sys (gpu (cta 0) (cta 1) (cta 2)))
arm_ord -- atom-mapping units pinned directly: acqrel read -> Q (LDAPR), write -> L (STLR).
  $ bash -c 'source ../_grid_lib.sh; arm_ord R acqrel'
  Q
  $ bash -c 'source ../_grid_lib.sh; arm_ord W acqrel'
  L
