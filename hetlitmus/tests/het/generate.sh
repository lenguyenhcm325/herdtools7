#!/usr/bin/env bash
# HetLitmus Tier-4 -- generate the heterogeneous (compound) litmus corpus with
# hetgen7 (gen/hetGen.ml).
#
# The diy cycle engine is monomorphic in one architecture, so hetgen7 runs it
# ONCE PER DEVICE on a device-appropriate cycle of the SAME logical shape, then
# keeps each processor's column from the run that owns that processor's device
# (-devices cpu,gpu) and merges columns + init + condition into one Tier-0 `Het`
# test:  P0 = CPU (AArch64, plain accesses), P1 = GPU (LISA/PTX, scoped acq/rel).
# Edge vocabulary is the same as the GPU-only corpus (see ../gpu-only/generate.sh
# and hetlitmus/bells/ptx.bell).  See hetlitmus/docs/het-generation.md.
set -e
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)
BIN="$REPO/_build/install/default/bin"
COMMON="-set-libdir $REPO/herd/libdir -bell $REPO/hetlitmus/bells/ptx.bell -devices cpu,gpu"

# --- SB-het: P0:{Wx,Ry} CPU | P1:{Wy,Rx} GPU; flags release/acquire, sys scope.
#     Condition spans BOTH procs -> exercises the per-proc condition merge.
"$BIN/hetgen7" $COMMON -name SB-het \
  -com "Heterogeneous store-buffering: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)" \
  -cpu "PodWR Fre PodWR Fre" \
  -gpu "PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys PodWRReleaseSysAcquireSys FreAcquireSysReleaseSys" \
  > SB-het.litmus
echo "generated SB-het.litmus"

# --- MP-het: regenerate and check it reproduces the hand-written Tier-0
#     reference MP-het.litmus (modulo table whitespace).  We do NOT overwrite the
#     hand-written file -- it is the stable Tier-0 artifact -- but we prove the
#     generator yields the same test.
"$BIN/hetgen7" $COMMON -name MP-het \
  -com "Heterogeneous message-passing: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)" \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys" \
  > /tmp/MP-het.regen.$$.litmus
if diff -w -q /tmp/MP-het.regen.$$.litmus MP-het.litmus >/dev/null; then
  echo "MP-het: generator reproduces hand-written MP-het.litmus (modulo whitespace)"
else
  echo "MP-het: WARNING generated output differs from MP-het.litmus" >&2
  diff -w /tmp/MP-het.regen.$$.litmus MP-het.litmus || true
fi
rm -f /tmp/MP-het.regen.$$.litmus

echo "Done. Het corpus in $(pwd)"
