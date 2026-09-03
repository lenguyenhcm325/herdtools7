Unit spec of the corpus rule functions in tests/_grid_lib.sh
(hetlitmus/docs/corpus-grid.md).

Each call is wrapped in `bash -c': dune cram runs a `$' line under dash, which
cannot source a bash script with `declare -A'.

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
acqrel: reads -> Acquire AND writes -> Release, reachable only through the
two-sided family.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys acqrel PodWW Rfe PodRR Fre'
  PodWWReleaseSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys
Same-location program order: a Pos<XY> edge carries its location letter into the
fence spelling (FenceSc<Scope>s<XY>), and reaches a non-fence order unchanged.
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
render_2s_cpu -- the CPU renderer by ISA.  aarch64 is the two-sided order-pair
dispatcher, the ONLY caller of render_cpu_cycle's partial-barrier branches; `ra'
reproduces acqrel token for token.
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu aarch64 ra PodWR Fre PodWR Fre'
  PodWRLQ FreQL PodWRLQ FreQL
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu aarch64 sy PodWR Fre PodWR Fre'
  DMB.SYdWR Fre DMB.SYdWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu aarch64 st PodWR Fre PodWR Fre'
  DMB.STdWR Fre DMB.STdWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu aarch64 ld PodWR Fre PodWR Fre'
  DMB.LDdWR Fre DMB.LDdWR Fre
x86_64: `sy' is MFence on each intra-proc edge; `ra'/`st'/`ld' are the bare cycle.
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu x86_64 sy PodWR Fre PodWR Fre'
  MFencedWR Fre MFencedWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu x86_64 sy PosWR Fre Coe'
  MFencesWR Fre Coe
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu x86_64 ra PodWR Fre PodWR Fre'
  PodWR Fre PodWR Fre
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu x86_64 ld PodWR Fre PodWR Fre'
  PodWR Fre PodWR Fre
An ISA with no profile is refused, not rendered bare.
  $ bash -c 'source ../_grid_lib.sh; render_2s_cpu riscv sy PodWR Fre PodWR Fre; echo "exit $?"'
  unknown cpu arch: riscv (one of: aarch64 x86_64)
  exit 1
render_2s_gpu -- the GPU half of the same grid: `ra' delegates to render_cycle sys
acqrel; sc/rel/acq/acqrel keep accesses Relaxed and spell a standalone fence edge.
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu ra PodWR Fre PodWR Fre'
  PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu sc PodWR Fre PodWR Fre'
  FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
`sc' reproduces render_cycle sys fence token for token.
  $ bash -c 'source ../_grid_lib.sh; render_cycle sys fence PodWR Fre PodWR Fre'
  FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceScSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu rel PodWR Fre PodWR Fre'
  FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceReleaseSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu acq PodWR Fre PodWR Fre'
  FenceAcquireSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceAcquireSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ bash -c 'source ../_grid_lib.sh; render_2s_gpu acqrel PodWR Fre PodWR Fre'
  FenceAcqrelSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys FenceAcqrelSysdWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
That loop spells its own fence edge, so the location letter is pinned here too.
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
