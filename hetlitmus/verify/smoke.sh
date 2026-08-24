#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke.sh -- Layer-3 compile-smoke for the HetLitmus toolchain.
#
# "Does the emitted harness actually compile end-to-end?"  The faithfulness sweep
# (tokens.sh) `nvcc --ptx'-compiles every gpu-only .cu but exercises neither
# the het harness's CPU side, the `nvcc -c'/ptxas object stage, nor the AMD/HIP
# render.  smoke.sh emits a curated rep sample and drives each test's own
# comp.sh (compile-only: gcc host +
# `clang --target=aarch64-linux-gnu' real AArch64 asm + `nvcc -std=c++17
# -arch=sm_90 -c' + `hipcc --offload-arch=gfx942 -c').  Needs nvcc/hipcc/clang
# but NO GPU -- `-arch' is a compile target, not a device requirement; only
# launching a kernel needs hardware (Layer 4).  Reuses comp.sh verbatim (no new
# build code); see hetlitmus/docs/TEST-PLAN.md sec.5.
#
# The reps -- 1-11 each hit one distinct compile path once, 12 is the
# counterfactual, and NREPS below counts them all:
#   1. MP-cg-cta-acquire       het one-sided; plain CPU STR/LDR + barrier
#   2. 2+2W-cg-sys-acqrel-2s   het two-sided; CPU STLR (store-only shape: no load)
#   3. MP-gc-sys-acqrel-2s     het two-sided GPU->CPU; the only rep emitting a CPU
#                              load-acquire (LDAPR, RCpc, needs -march=armv8.3-a)
#   4. 2+2W-cg-sys-fence-2s    het two-sided; CPU DMB.SY fence
#   5. IRIW-cgcc-cta-relaxed   het 4-proc; largest barrier / scaffolding
#   6. WRC-ccg-cta-relaxed     het 3-proc; buys down the proc-scaling assumption
#   7. MP-cg-sys-relaxed-x86_64 (HIP)  the AMD render -- the only rep here that
#                              compiles a .hip (hipbuildcheck.py compiles and
#                              links one too).  It comes from tests/het-x86
#                              because a HIP harness is the (x86_64, hip) pair.
#   8. MP-cg-sys-sy.acq-2s     order-pair; the only rep emitting inline
#                              `fence.acquire.sys', which needs sm_90 [CCCL];
#                              also the first rep whose test name contains a `.'
#   9. S-gc-sys-ra.rel-2s      order-pair; the only rep emitting inline
#                              `fence.release.sys', paired with CPU STLR/LDAPR,
#                              and an outcome column read out of a location
#  10. MP-cg-sys-st.sc-2s      the CPU `dmb st' form
#  11. MP-gc-sys-ld.sc-2s      the CPU `dmb ld' form on the GPU->CPU cut (the CPU
#                              proc reads).
#                              Which of the three barrier forms is emitted is
#                              pinned by `tokens.sh all' (ptxcheck.check_cpu).
#  12. MP-cg-cta-acquire       the counterfactual: a syntax error injected into
#                              a SCRATCH _cpu.c must break comp.sh.
#
# Usage:
#   bash hetlitmus/verify/smoke.sh          # run every rep (pre-commit gate)
#
# Exit 0 (prints `SMOKE OK') iff every rep passes.  A missing hipcc skips the
# hip rep loudly -- it NEVER counts as a pass.  The reps that ran are counted
# (`n', bumped inside each rep) and the count is asserted against NREPS before
# any OK is printed, so a rep dropped from the list reddens the gate instead of
# shrinking it silently.
# ---------------------------------------------------------------------------
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

HET_DIR="$REPO/hetlitmus/tests/het"
# The committed fixture for the (x86_64, hip) pair.  The HIP rep does not come
# from $HET_DIR: those tests have an AArch64 CPU column, so they render the
# (AArch64, hip) pair, which is not the .hip this rep is here to compile.
HETX86_DIR="$REPO/hetlitmus/tests/het-x86"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NREPS=12          # keep in sync with the rep list in the header and below
fails=0
skips=0
n=0               # reps that actually RAN; asserted == NREPS before any OK

# ---- het rep, either dialect: emit the harness dir, run its OWN comp.sh -----
# litmus7 -o <d> writes a nested <d>/<name>/ dir holding <name>.cu (or .hip),
# <name>_cpu.c, outs.c and comp.sh.  `sh comp.sh <dialect>' compiles only (-c, no
# link, no GPU), printing `HetLitmus: compile OK' and exiting 0 on success (set -e
# inside).  The CUDA and HIP reps are the SAME rep; the case table below is the
# whole of their divergence (banner tag, scratch-dir prefix, which `+ ' trace
# lines are echoed on success, and how a comp.sh failure names itself).
#
# `tool' is an optional presence guard, checked AFTER the banner so the rep is
# always announced: empty means none (the CUDA lane's compilers are the gate's own
# prerequisites), a named-but-absent tool SKIPS the rep loudly and counts as a
# skip -- never as a pass, because a gate that reports success when it did not run
# is worse than no gate.
#
# Why the HIP lane is guarded rather than dropped: "one template, two renders" is
# only an invariant if something renders the second one.  While that lane was
# ungated, a symbol declared inside the CUDA dialect's allocator but read by the
# shared driver template broke every .hip, with the CUDA lane and every gate in
# the suite still green.
_smoke_het_rep() { # name dialect tool blurb srcdir
  local name="$1" dialect="$2" tool="$3" blurb="$4" srcdir="$5"
  local tag pfx filter faillabel d out rc
  case "$dialect" in
    cuda) tag='het'     pfx=e filter='^\+ '      faillabel='comp.sh' ;;
    hip)  tag='het/HIP' pfx=h filter='^\+ hipcc' faillabel='comp.sh hip' ;;
    *) printf '  FAIL %s (smoke.sh: unknown dialect %s)\n' "$name" "$dialect"
       fails=$((fails+1)); return ;;
  esac
  n=$((n+1))
  printf '\n[%d/%d] %-9s%-22s -- %s\n' "$n" "$NREPS" "$tag" "$name" "$blurb"
  if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    printf '  SKIP %s -- %s NOT FOUND: the AMD render is UNVERIFIED by this\n' "$name" "$tool"
    printf '       run.  It is a real compile target, not a formality; install ROCm or\n'
    printf '       run this gate where %s exists before trusting the .hip lane.\n' "$tool"
    skips=$((skips+1)); return
  fi
  d="$WORK/${pfx}_$name"; mkdir -p "$d"
  # THE RENDER THIS REP COMPILES: one vendor per emission, so the .hip reps
  # must be emitted with -gpu-target hip or comp.sh would have no hip arm.
  if ! out="$(litmus7 -gpu-target "$dialect" -set-libdir litmus/libdir -o "$d" "$srcdir/$name.litmus" 2>&1)"; then
    printf '%s\n' "$out"; printf '  FAIL %s (emission)\n' "$name"; fails=$((fails+1)); return
  fi
  out="$(cd "$d/$name" && sh comp.sh "$dialect" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'HetLitmus: compile OK'; then
    printf '%s\n' "$out" | grep -E "$filter|HetLitmus: compile OK"
    printf '  PASS %s\n' "$name"
  else
    printf '%s\n' "$out"; printf '  FAIL %s (%s rc=%d)\n' "$name" "$faillabel" "$rc"; fails=$((fails+1))
  fi
}

# The names the rep list calls.
smoke_het() { _smoke_het_rep "$1" cuda '' "$2" "$HET_DIR"; }        # name blurb
smoke_het_hip() { _smoke_het_rep "$1" hip hipcc "$2" "$HETX86_DIR"; }  # name blurb

# ---- the compile-failure counterfactual (rep 12) --------------------------
# Breaks a SCRATCH copy of an emitted _cpu.c and requires comp.sh to fail; the
# committed corpus is never touched.
smoke_het_uncompilable() { # name blurb
  local name="$1" blurb="$2" d cpu out rc
  n=$((n+1))
  printf '\n[%d/%d] %-9s%-22s -- %s\n' "$n" "$NREPS" 'het/neg' "$name" "$blurb"
  d="$WORK/x_$name"; mkdir -p "$d"
  if ! out="$(litmus7 -gpu-target cuda -set-libdir litmus/libdir -o "$d" "$HET_DIR/$name.litmus" 2>&1)"; then
    printf '%s\n' "$out"; printf '  FAIL %s (emission)\n' "$name"; fails=$((fails+1)); return
  fi
  cpu="$d/$name/${name}_cpu.c"
  if [ ! -s "$cpu" ]; then
    printf '  FAIL %s (no %s_cpu.c to break, so nothing was injected)\n' "$name" "$name"
    fails=$((fails+1)); return
  fi
  printf '\nvoid HETLITMUS_NOT_C(void) { @@@ this is not C @@@ }\n' >> "$cpu"
  out="$(cd "$d/$name" && sh comp.sh cuda 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -iE 'error' | head -3
  # A nonzero rc is also what a harness broken for its own reasons earns, so the
  # compiler has to name HETLITMUS_NOT_C, the function the injection added.
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'HetLitmus: compile OK' \
     && printf '%s' "$out" | grep -q 'HETLITMUS_NOT_C'; then
    printf '  PASS %s (comp.sh rc=%d, no compile-OK line, error names HETLITMUS_NOT_C)\n' \
      "$name" "$rc"
  else
    printf '%s\n' "$out"
    printf '  FAIL %s (comp.sh rc=%d: a _cpu.c that is not C reported compile OK, or failed without the compiler naming HETLITMUS_NOT_C)\n' \
      "$name" "$rc"
    fails=$((fails+1))
  fi
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  all)
    printf '===== HetLitmus Layer-3 compile-smoke (%d reps; nvcc+hipcc+clang, NO GPU) =====\n' "$NREPS"
    smoke_het     MP-cg-cta-acquire     "one-sided; plain CPU STR/LDR + barrier + nvcc -c"
    smoke_het     2+2W-cg-sys-acqrel-2s "two-sided; CPU STLR (2+2W is store-only: NO load)"
    # MP-gc puts the loads on the CPU, so -2s acqrel emits a real LDAPR; 2+2W
    # above is store-only and no other rep emits one (header, rep 3).
    smoke_het     MP-gc-sys-acqrel-2s   "two-sided GPU->CPU; CPU LDAPR (RCpc, needs -march=armv8.3-a)"
    smoke_het     2+2W-cg-sys-fence-2s  "two-sided; CPU DMB.SY fence"
    smoke_het     IRIW-cgcc-cta-relaxed "4-proc; largest barrier / scaffolding"
    smoke_het     WRC-ccg-cta-relaxed   "3-proc; buys down the proc-scaling assumption"
    # The only rep whose render is a .hip, so it is where a CUDA/HIP divergence
    # in the shared runtime headers shows up.
    smoke_het_hip MP-cg-sys-relaxed-x86_64 "the AMD render, (x86_64, hip) pair (hipcc -c, gfx942)"
    smoke_het     MP-cg-sys-sy.acq-2s   "order-pair; inline fence.acquire.sys"
    smoke_het     S-gc-sys-ra.rel-2s    "order-pair; inline fence.release.sys + CPU STLR/LDAPR"
    smoke_het     MP-cg-sys-st.sc-2s    "order-pair; CPU dmb st + fence.sc.sys"
    smoke_het     MP-gc-sys-ld.sc-2s    "order-pair; CPU dmb ld on the gc cut"
    smoke_het_uncompilable MP-cg-cta-acquire "a broken scratch _cpu.c must FAIL comp.sh"
    printf '\n=====================================================================\n'
    # Anti-vacuity: the verdict below reports what RAN, so a deleted or
    # commented-out rep reddens the gate instead of shrinking it silently.
    if [ "$n" -ne "$NREPS" ]; then
      printf 'SMOKE FAILED: %d rep(s) ran, expected %d -- the rep list shrank\n' \
        "$n" "$NREPS"; exit 1
    fi
    if [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d reps passed)\n' "$n" "$NREPS"; exit 0
    fi
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d passed, %d SKIPPED -- see above; the skipped lane is UNVERIFIED)\n' \
        "$((n-skips))" "$NREPS" "$skips"; exit 0
    fi
    printf 'SMOKE FAILED: %d/%d rep(s) failed\n' "$fails" "$NREPS"; exit 1 ;;
  *) printf 'usage: %s [all]\n' "$0"; exit 64 ;;
esac
