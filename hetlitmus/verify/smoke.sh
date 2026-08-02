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
# loudly -- it never counts as a pass.  The reps that RAN are counted (`n', bumped
# inside each rep) and the count is asserted against NREPS before any OK is
# printed: `fails' can only be raised from inside a rep, so a rep that is never
# CALLED contributes nothing and a shrunken rep list would otherwise leave the
# gate green with the verdict line still claiming 12/12 -- the same vacuous-pass
# hole the census tripwires of l0_tokens.sh / corpus-gate.sh / emit-all.sh close.
# ---------------------------------------------------------------------------
set -u

. "$(dirname "$0")/../paths.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # absolute; the census bite copies it
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

HET_DIR="$REPO/hetlitmus/tests/het"
CLU_DIR="$REPO/hetlitmus/tests/cluster"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NREPS=12          # keep in sync with the rep list in the header and below
fails=0
skips=0
n=0               # reps that actually RAN; asserted == NREPS before any OK

# ---- het rep, either dialect: emit the Tier-2 harness dir, run its OWN comp.sh
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
_smoke_het_rep() { # name dialect tool blurb
  local name="$1" dialect="$2" tool="$3" blurb="$4"
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
    printf '  SKIP %s -- %s NOT FOUND: the AMD/MI300A render is UNVERIFIED by this\n' "$name" "$tool"
    printf '       run.  It is a real compile target, not a formality; install ROCm or\n'
    printf '       run this gate where %s exists before trusting the .hip lane.\n' "$tool"
    skips=$((skips+1)); return
  fi
  d="$WORK/${pfx}_$name"; mkdir -p "$d"
  if ! out="$(litmus7 -set-libdir litmus/libdir -o "$d" "$HET_DIR/$name.litmus" 2>&1)"; then
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

# The two names the rep list calls (and that bite_census counts by `^    smoke_').
smoke_het() { _smoke_het_rep "$1" cuda '' "$2"; }             # name blurb
smoke_het_hip() { _smoke_het_rep "$1" hip hipcc "$2"; }       # name blurb

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
bite_compile() {
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

# ---- gate teeth, second half: the REP CENSUS ------------------------------
# The compile bite above proves a broken harness reddens the gate; it says
# nothing about a rep that never runs, which is the cheaper way to lose
# coverage.  Delete every rep invocation from a scratch copy of this script and
# require the census to redden it -- before the `n' assertion that copy printed
# `SMOKE OK (12/12 reps compiled)' having compiled nothing.  Costs no compiler
# time precisely because the doctored copy runs zero reps.
bite_census() {
  local sc="$WORK/census" nreps out rc
  printf '\n===== SMOKE BITE: a rep list that ran NOTHING must FAIL the gate =====\n'
  # The copy sources paths.sh by relative path, so give it a sibling -- a stub
  # that sources the REAL one, since paths.sh self-locates and a plain copy
  # would hand the scratch run a bogus $REPO.
  mkdir -p "$sc/verify"
  printf '. "%s/paths.sh"\n' "$HETL" > "$sc/paths.sh"
  sed '/^    smoke_/d' "$SELF" > "$sc/verify/smoke.sh"
  if cmp -s "$SELF" "$sc/verify/smoke.sh"; then
    printf 'BITE FAILED (VACUOUS): deleting the rep invocations changed nothing\n'
    return 1
  fi
  nreps=$(grep -c '^    smoke_' "$SELF")
  printf 'deleted all %d rep invocations from a scratch copy of smoke.sh\n' "$nreps"
  out="$(bash "$sc/verify/smoke.sh" all 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -2
  printf 'scratch smoke.sh rc=%d (expect NONZERO)\n\n' "$rc"
  if [ "$rc" -ne 0 ] && \
     printf '%s' "$out" | grep -q "SMOKE FAILED: 0 rep(s) ran, expected $NREPS"; then
    printf 'BITE OK: the rep census has teeth (0 reps ran -> FAIL, not a green %d/%d)\n' \
      "$NREPS" "$NREPS"
    return 0
  fi
  printf 'BITE FAILED: a smoke run with ZERO reps did not redden the gate\n'
  return 1
}

bite() {
  local f=0
  bite_compile || f=1
  bite_census  || f=1
  [ "$f" -eq 0 ] || { printf '\nSMOKE BITE FAILED\n'; return 1; }
  printf '\nSMOKE BITE OK (compile + rep census)\n'
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
    # Anti-vacuity: the verdict below reports what RAN, so a deleted or
    # commented-out rep reddens the gate instead of shrinking it silently.
    if [ "$n" -ne "$NREPS" ]; then
      printf 'SMOKE FAILED: %d rep(s) ran, expected %d -- the rep list shrank\n' \
        "$n" "$NREPS"; exit 1
    fi
    if [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d reps compiled)\n' "$n" "$NREPS"; exit 0
    fi
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d compiled, %d SKIPPED -- see above; the skipped lane is UNVERIFIED)\n' \
        "$((n-skips))" "$NREPS" "$skips"; exit 0
    fi
    printf 'SMOKE FAILED: %d/%d rep(s) did not compile\n' "$fails" "$NREPS"; exit 1 ;;
  *) printf 'usage: %s [all|bite]\n' "$0"; exit 64 ;;
esac
