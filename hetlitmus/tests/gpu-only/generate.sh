#!/bin/bash
# Task 3 — generate the PLDI'23 GPU-only litmus corpus as scoped LISA tests.
#
# Each test is a closed critical cycle of annotated edges; diy7 attaches one
# memory-order tag and one scope tag per memory access (vocabulary defined in
# hetlitmus/bells/ptx.bell). Edge token = <base-edge><atom(src)><atom(dst)>,
# atom rendered as <Order><Scope> (gen/common/edge.ml `pp_edge_compat`).
#
# Cycles, variants and expected outcomes follow the PLDI'23 Compound Memory
# Models artifact (Goens, Chakraborty, Sarkar, Agarwal, Oswald, Nagarajan,
# PLDI 2023): the artifact's expected.csv (build target GCN3_X86 = AMD GCN3 GPU +
# x86 CPU; mirrored locally, AMD-tagged, as expected-amd-gcn3.csv) +
# gem5-resources/gpu/GPU_Litmus_test/{MP,LB,SB,IRIW}.
# Faithful detail from the HIP sources: the relaxed ("-sys") variants use plain
# accesses (modelled here as 'relaxed); the synchronised ("-F") variants use
# release stores + acquire loads (NOT full fences) — confirmed for MP, SB, IRIW.
# In MP only the flag variable is rel/acq, data stays relaxed.
# See hetlitmus/docs/gpu-only-corpus.md.

set -e
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)
BIN="$REPO/_build/install/default/bin"
COMMON="-set-libdir $REPO/herd/libdir -bell $REPO/hetlitmus/bells/ptx.bell -arch LISA"

# Scope trees. diyone7 emits the `-scopes` structure directly into the test body
# as a parseable `scopes:` tree (lib/coreDumper.ml), which herd reads into the
# tag2scope relations the .cat uses. We pass an explicit nested tree so all three
# levels (system > gpu > cta) are present and tag2scope('cta|'gpu|'sys) resolve in
# every test; each thread is in its own CTA. To synchronise two threads at CTA
# scope, place them in the SAME `(cta P0 P1)` group -- the .cat reads the instance
# structure and fires the sync, no model change needed.
TREE2="(sys (gpu (cta P0) (cta P1)))"
TREE4="(sys (gpu (cta P0) (cta P1) (cta P2) (cta P3)))"

gen () { # name  scopes-tree  edges...
  local name="$1" tree="$2"; shift 2
  "$BIN/diyone7" $COMMON -name "$name" -scopes "$tree" "$@"
  echo "  generated $name.litmus  [scopes: $tree]"
}

# --- MP: P0:{Wx,Wy} | P1:{Ry,Rx}  cycle PodWW Rfe PodRR Fre ---
# MP-sys (Allowed): fully relaxed
gen MP-sys "$TREE2" \
  PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
# MP-sys-F (Disallowed): flag release/acquire at system scope, data relaxed
gen MP-sys-F "$TREE2" \
  PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys
# MP-cta-F (Allowed): flag release/acquire at CTA scope, threads in distinct CTAs
gen MP-cta-F "$TREE2" \
  PodWWRelaxedCtaReleaseCta RfeReleaseCtaAcquireCta PodRRAcquireCtaRelaxedCta FreRelaxedCtaRelaxedCta

# --- LB: P0:{Rx,Wy} | P1:{Ry,Wx}  cycle PodRW Rfe PodRW Rfe ---
# LB-sys (Disallowed): fully relaxed (LB-sys-F is omitted by the artifact)
gen LB-sys "$TREE2" \
  PodRWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys

# --- SB: P0:{Wx,Ry} | P1:{Wy,Rx}  cycle PodWR Fre PodWR Fre ---
# SB-sys (Allowed): fully relaxed
gen SB-sys "$TREE2" \
  PodWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys PodWRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
# SB-sys-F (Disallowed): release stores + acquire loads at system scope
gen SB-sys-F "$TREE2" \
  PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys

# --- IRIW: 2 writers + 2 readers  cycle Rfe PodRR Fre Rfe PodRR Fre ---
# IRIW-sys (Allowed): fully relaxed
gen IRIW-sys "$TREE4" \
  RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys \
  RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
# IRIW-sys-F (Disallowed): release stores + acquire loads at system scope
gen IRIW-sys-F "$TREE4" \
  RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys \
  RfeReleaseSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysReleaseSys

echo "Done. Corpus in $(pwd)"
