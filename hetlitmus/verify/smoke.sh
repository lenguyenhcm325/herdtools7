#!/usr/bin/env bash
# smoke.sh -- a curated rep sample of emitted harnesses compiles end to end
# through its own comp.sh: gcc for outs.c, gcc or a clang --target= cross
# assembly for the CPU body as the host decides, nvcc -c and hipcc -c
# (hetlitmus/docs/README-tests.md).  Needs nvcc, hipcc and clang but NO GPU --
# `-arch' is a compile target.  Each rep prints the compile path it covers.
# Exit 1 on a rep that fails and on a rep list that shrank below NREPS; a
# missing clang is comp.sh's own error exit, which the rep's rc check catches.
# A missing hipcc SKIPS the .hip rep loudly and never counts as a pass.
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

HET_DIR="$HET_CORPUS"
# The HIP reps read the x86_64 tree: $HET_DIR's AArch64 CPU columns render the
# (AArch64, hip) pair, not the (x86_64, hip) one those reps compile.
HETX86_DIR="$X86_CORPUS"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NREPS=5           # keep in sync with the rep list below
fails=0
skips=0
n=0               # reps that actually RAN; asserted == NREPS before any OK

# ---- het rep, either dialect: emit the harness dir, run its OWN comp.sh -----
# `tool' is an optional presence guard; empty means the gate's own cover it.
_smoke_het_rep() { # name dialect tool blurb srcdir
  local name="$1" dialect="$2" tool="$3" blurb="$4" srcdir="$5"
  local tag pfx filter faillabel d out rc
  case "$dialect" in
    cuda) tag='het'     pfx=e filter='^\+ '      faillabel='comp.sh' ;;
    hip)  tag='het/HIP' pfx=h filter='^\+ hipcc' faillabel='comp.sh hip' ;;
  esac
  n=$((n+1))
  printf '\n[%d/%d] %-9s%-22s -- %s\n' "$n" "$NREPS" "$tag" "$name" "$blurb"
  if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    printf '  SKIP %s -- no %s: this render is UNVERIFIED by this run\n' "$name" "$tool"
    skips=$((skips+1)); return
  fi
  d="$WORK/${pfx}_$name"; mkdir -p "$d"
  # The render this rep compiles: one vendor per emission, so the .hip reps
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

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  all)
    printf '===== HetLitmus compile-smoke (%d reps; nvcc+hipcc+clang, NO GPU) =====\n' "$NREPS"
    # The .hip rep: where a CUDA/HIP divergence in the shared runtime headers
    # shows up, with acquire atomics.
    smoke_het_hip MP-cg-sys-plain.acq-x86_64 "the AMD render's acquire atomics through hipcc (hipcc -c, gfx942)"
    smoke_het     MP-cg-sys-sy.facq     "CPU dmb sy + inline fence.acquire.sys, sm_90 [CCCL]"
    smoke_het     S-gc-sys-ra.frel      "CPU STLR/LDAPR + inline fence.release.sys"
    smoke_het     MP-cg-sys-st.fsc      "CPU dmb st + fence.sc.sys"
    smoke_het     MP-gc-sys-ld.fsc      "CPU dmb ld + fence.sc.sys on the gc cut"
    printf '\n=====================================================================\n'
    # Anti-vacuity: a deleted or commented-out rep reddens the gate instead of
    # shrinking it silently.
    if [ "$n" -ne "$NREPS" ]; then
      printf 'SMOKE FAILED: %d rep(s) ran, expected %d -- the rep list shrank\n' \
        "$n" "$NREPS"; exit 1
    fi
    if [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d reps passed)\n' "$n" "$NREPS"; exit 0
    fi
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK  (%d/%d passed, %d SKIPPED above -- those renders are UNVERIFIED)\n' \
        "$((n-skips))" "$NREPS" "$skips"; exit 0
    fi
    printf 'SMOKE FAILED: %d/%d rep(s) failed\n' "$fails" "$NREPS"; exit 1 ;;
  *) printf 'usage: %s [all]\n' "$0"; exit 64 ;;
esac
