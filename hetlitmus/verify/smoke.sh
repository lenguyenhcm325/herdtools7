#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke.sh -- Layer-3 compile-smoke for the HetLitmus toolchain.
#
# "Does the emitted harness actually COMPILE end-to-end?"  The faithfulness sweep
# (l0_tokens.sh) `nvcc --ptx'-compiles every gpu-only .cu but exercises neither
# the het harness's CPU side, the `nvcc -c'/ptxas object stage, the AMD/HIP
# render, nor the Hopper-cluster inline-PTX path.  smoke.sh emits a curated
# 12-rep sample and drives each test's OWN comp.sh (compile-only: gcc host +
# `clang --target=aarch64-linux-gnu' real AArch64 asm + `nvcc -std=c++17
# -arch=sm_90 -c' + `hipcc --offload-arch=gfx942 -c').  Needs nvcc/hipcc/clang
# but NO GPU -- `-arch' is a compile target, not a device requirement; only
# launching a kernel needs hardware (Layer 4).  Reuses comp.sh verbatim (no new
# build code); see hetlitmus/docs/TEST-PLAN.md sec.5.
#
# The 12 reps -- each hits one distinct compile path once:
#   1. MP-cg-cta-acquire       het one-sided; plain CPU STR/LDR + barrier
#   2. 2+2W-cg-sys-acqrel-2s   het two-sided; CPU STLR (store-only shape: no load)
#   3. MP-gc-sys-acqrel-2s     het two-sided GPU->CPU; the only rep emitting a CPU
#                              load-acquire (LDAPR, RCpc, .arch_extension rcpc)
#   4. 2+2W-cg-sys-fence-2s    het two-sided; CPU DMB.SY fence
#   5. IRIW-cgcc-cta-relaxed   het 4-proc; largest barrier / scaffolding
#   6. WRC-ccg-cta-relaxed     het 3-proc; buys down the proc-scaling assumption
#   7. tests/cluster/MP-cluster  gpu-only Hopper cluster inline-PTX fence path
#   8. MP-cg-sys-acqrel-2s (HIP) the AMD/MI300A render -- the only place in the
#                              whole suite that compiles a .hip at all
#   9. MP-cg-sys-sy.acq-2s     order-pair; the only rep emitting inline
#                              `fence.acquire.sys' (PTX ISA 8.6 / sm_90), with a
#                              compiled-in co-run control (mu = MP-cg-sys-ld.acq-2s;
#                              MP-cg-sys-acquire is that row's MuAlt);
#                              also the first rep whose test name contains a `.'
#  10. S-gc-sys-ra.rel-2s      order-pair; the only rep emitting inline
#                              `fence.release.sys', paired with CPU STLR/LDAPR,
#                              and the largest co-run in the corpus (K=4, NPART=10)
#  11. MP-cg-sys-st.sc-2s      the CPU `dmb st' form; its mu is st.rel, so the
#                              harness carries two `dmb st' asm blocks
#  12. MP-gc-sys-ld.sc-2s      the CPU `dmb ld' form on the GPU->CPU cut (the CPU
#                              proc reads), mu = ld.acq -> two `dmb ld' blocks.
#                              These reps claim only that the three barrier forms
#                              BUILD; which one is emitted is pinned by
#                              l0_tokens.sh selftest [5b].
#
# Usage:
#   bash hetlitmus/verify/smoke.sh          # run all 12 reps (pre-commit gate)
#   bash hetlitmus/verify/smoke.sh bite     # prove the gate has teeth (self-test)
#
# Exit 0 (prints `SMOKE OK') iff all 12 reps compile.  A missing hipcc SKIPS rep 8
# loudly -- it never counts as a pass.
# ---------------------------------------------------------------------------
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

HET_DIR="$REPO/hetlitmus/tests/het"
CLU_DIR="$REPO/hetlitmus/tests/cluster"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NREPS=12          # keep in sync with the rep list in the header and below
fails=0
skips=0
n=0

# ---- het rep: emit the Tier-2 harness dir, run its OWN comp.sh -------------
# litmus7 -o <d> writes a nested <d>/<name>/ dir holding <name>.cu, <name>_cpu.c,
# outs.c and comp.sh.  `sh comp.sh cuda' compiles only (-c, no link, no GPU),
# printing `HetLitmus: compile OK' and exiting 0 on success (set -e inside).
smoke_het() { # name blurb
  local name="$1" blurb="$2" d out rc
  n=$((n+1))
  printf '\n[%d/%d] het      %-22s -- %s\n' "$n" "$NREPS" "$name" "$blurb"
  d="$WORK/e_$name"; mkdir -p "$d"
  if ! out="$(litmus7 -set-libdir litmus/libdir -o "$d" "$HET_DIR/$name.litmus" 2>&1)"; then
    printf '%s\n' "$out"; printf '  FAIL %s (emission)\n' "$name"; fails=$((fails+1)); return
  fi
  out="$(cd "$d/$name" && sh comp.sh cuda 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'HetLitmus: compile OK'; then
    printf '%s\n' "$out" | grep -E '^\+ |HetLitmus: compile OK'
    printf '  PASS %s\n' "$name"
  else
    printf '%s\n' "$out"; printf '  FAIL %s (comp.sh rc=%d)\n' "$name" "$rc"; fails=$((fails+1))
  fi
}

# ---- het rep, HIP/MI300A render: the SAME harness through `comp.sh hip' -----
# "One template, two renders" is only an invariant if something renders the
# second one: while this lane was ungated, a symbol declared inside the CUDA
# dialect's allocator but read by the shared driver template broke every .hip,
# with the CUDA lane and every gate in the suite still green.
#
# If hipcc is absent the rep is SKIPPED, loudly, and counted as a skip -- never
# as a pass, because a gate that reports success when it did not run is worse
# than no gate.
smoke_het_hip() { # name blurb
  local name="$1" blurb="$2" d out rc
  n=$((n+1))
  printf '\n[%d/%d] het/HIP  %-22s -- %s\n' "$n" "$NREPS" "$name" "$blurb"
  if ! command -v hipcc >/dev/null 2>&1; then
    printf '  SKIP %s -- hipcc NOT FOUND: the AMD/MI300A render is UNVERIFIED by this\n' "$name"
    printf '       run.  It is a real compile target, not a formality; install ROCm or\n'
    printf '       run this gate where hipcc exists before trusting the .hip lane.\n'
    skips=$((skips+1)); return
  fi
  d="$WORK/h_$name"; mkdir -p "$d"
  if ! out="$(litmus7 -set-libdir litmus/libdir -o "$d" "$HET_DIR/$name.litmus" 2>&1)"; then
    printf '%s\n' "$out"; printf '  FAIL %s (emission)\n' "$name"; fails=$((fails+1)); return
  fi
  out="$(cd "$d/$name" && sh comp.sh hip 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'HetLitmus: compile OK'; then
    printf '%s\n' "$out" | grep -E '^\+ hipcc|HetLitmus: compile OK'
    printf '  PASS %s\n' "$name"
  else
    printf '%s\n' "$out"; printf '  FAIL %s (comp.sh hip rc=%d)\n' "$name" "$rc"; fails=$((fails+1))
  fi
}

# ---- cluster rep: gpu-only, flat .cu, bare `nvcc -c' -----------------------
# The cluster family is GPU-only (no CPU side, no comp.sh) and sits outside the
# faithfulness sweep (l0_tokens covers only gpu-only + het), so smoke is its ONLY
# compile check.  Emit the flat <name>.cu, then object-compile it.
smoke_cluster() { # name blurb
  local name="$1" blurb="$2" d out rc
  n=$((n+1))
  printf '\n[%d/%d] cluster  %-22s -- %s\n' "$n" "$NREPS" "$name" "$blurb"
  d="$WORK/e_$name"; mkdir -p "$d"
  if ! out="$(litmus7 -set-libdir litmus/libdir -o "$d" "$CLU_DIR/$name.litmus" 2>&1)"; then
    printf '%s\n' "$out"; printf '  FAIL %s (emission)\n' "$name"; fails=$((fails+1)); return
  fi
  printf '+ nvcc -std=c++17 -arch=sm_90 -c %s.cu\n' "$name"
  out="$(nvcc -std=c++17 -arch=sm_90 -c "$d/$name.cu" -o /dev/null 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS %s\n' "$name"
  else
    printf '%s\n' "$out"; printf '  FAIL %s (nvcc -c rc=%d)\n' "$name" "$rc"; fails=$((fails+1))
  fi
}

# ---- gate teeth: corrupt a scratch copy of an emitted harness, expect FAIL --
# Emit a throwaway het harness, inject a syntax error into its (scratch) _cpu.c,
# and confirm comp.sh now exits NONZERO.  Proves smoke actually bites; operates
# only on the temp emit dir -- the committed .litmus corpus is never touched.
bite() {
  local name=MP-cg-cta-acquire d cpu out rc
  printf '===== SMOKE BITE: syntax error in a scratch _cpu.c must FAIL the gate =====\n'
  d="$WORK/bite"; mkdir -p "$d"
  litmus7 -set-libdir litmus/libdir -o "$d" "$HET_DIR/$name.litmus" >/dev/null 2>&1
  cpu="$d/$name/${name}_cpu.c"
  if [ ! -s "$cpu" ]; then
    printf 'BITE ERROR: could not emit %s harness\n' "$name"; return 1
  fi
  printf '\nvoid HETLITMUS_SMOKE_BITE(void) { @@@ this is not C @@@ }\n' >> "$cpu"
  printf 'injected a syntax error into a scratch copy of %s_cpu.c\n' "$name"
  out="$(cd "$d/$name" && sh comp.sh cuda 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -iE 'error|HetLitmus: compile OK' | head -5
  printf 'comp.sh rc=%d (expect NONZERO)\n\n' "$rc"
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'HetLitmus: compile OK'; then
    printf 'BITE OK: the gate has teeth (corruption -> compile failure)\n'
    return 0
  fi
  printf 'BITE FAILED: corruption did NOT fail the gate -- smoke is toothless\n'
  return 1
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  bite) bite; exit $? ;;
  all)
    printf '===== HetLitmus Layer-3 compile-smoke (%d reps; nvcc+hipcc+clang, NO GPU) =====\n' "$NREPS"
    smoke_het     MP-cg-cta-acquire     "one-sided; plain CPU STR/LDR + barrier + nvcc -c"
    smoke_het     2+2W-cg-sys-acqrel-2s "two-sided; CPU STLR (2+2W is store-only: NO load)"
    # MP-gc puts the loads on the CPU, so -2s acqrel emits a real LDAPR; 2+2W
    # above is store-only and no other rep emits one (header, rep 3).
    smoke_het     MP-gc-sys-acqrel-2s   "two-sided GPU->CPU; CPU LDAPR (RCpc, needs .arch_extension rcpc)"
    smoke_het     2+2W-cg-sys-fence-2s  "two-sided; CPU DMB.SY fence"
    smoke_het     IRIW-cgcc-cta-relaxed "4-proc; largest barrier / scaffolding"
    smoke_het     WRC-ccg-cta-relaxed   "3-proc; buys down the proc-scaling assumption"
    smoke_cluster MP-cluster            "Hopper cluster inline-PTX fence path (nvcc -c)"
    # This rep carries the most CPU/interconnect-stress surface (a -2s CPU body,
    # the preload, the enemies, both halves of the C2C noise), so it is the one
    # most likely to expose a CUDA/HIP dialect divergence.
    smoke_het_hip MP-cg-sys-acqrel-2s   "the AMD/MI300A render (hipcc -c, gfx942)"
    # The four order-pair reps below are all oracle-Disallowed, so each also
    # exercises the co-run control (HET_CONTROL_COMPILED_IN=1) on that family.
    smoke_het     MP-cg-sys-sy.acq-2s   "Q10 order-pair; inline fence.acquire.sys + co-run mu"
    smoke_het     S-gc-sys-ra.rel-2s    "Q10 order-pair; inline fence.release.sys + CPU STLR/LDAPR"
    smoke_het     MP-cg-sys-st.sc-2s    "Q10b order-pair; CPU dmb st (x2: T + mu) + fence.sc.sys"
    smoke_het     MP-gc-sys-ld.sc-2s    "Q10b order-pair; CPU dmb ld (x2: T + mu) on the gc cut"
    printf '\n=====================================================================\n'
    if [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d reps compiled)\n' "$NREPS" "$NREPS"; exit 0
    fi
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d compiled, %d SKIPPED -- see above; the skipped lane is UNVERIFIED)\n' \
        "$((NREPS-skips))" "$NREPS" "$skips"; exit 0
    fi
    printf 'SMOKE FAILED: %d/%d rep(s) did not compile\n' "$fails" "$NREPS"; exit 1 ;;
  *) printf 'usage: %s [all|bite]\n' "$0"; exit 64 ;;
esac
