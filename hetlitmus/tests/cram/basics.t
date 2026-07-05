Layer-1 unit spec of the corpus rule functions in tests/_grid_lib.sh.  This is a
curated sample -- ONE line per rule branch, NOT the 132-cell grid (that is the
Layer-2 corpus golden's job; see TEST-PLAN.md sec 2 "Coverage map").  dune cram
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
render_cpu_cycle -- the AArch64 mirror.  acqrel: read -> LDAPR (Q), write -> STLR (L).
  $ bash -c 'source ../_grid_lib.sh; render_cpu_cycle acqrel PodWR Fre PodWR Fre'
  PodWRLQ FreQL PodWRLQ FreQL
fence: each intra-proc Pod<XY> becomes the full-barrier edge DMB.SYd<XY>.
  $ bash -c 'source ../_grid_lib.sh; render_cpu_cycle fence PodWW Rfe PodRR Fre'
  DMB.SYdWW Rfe DMB.SYdRR Fre
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
