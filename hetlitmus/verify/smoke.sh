#!/usr/bin/env bash
# smoke.sh -- a sample of emitted harnesses compiles through its own comp.sh.
# Needs nvcc, hipcc and clang, no GPU.  Exit 1 on a failing rep or fewer than NREPS.
set -u

. "$(dirname "$0")/../paths.sh"
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

HET_DIR="$HET_CORPUS"
HETX86_DIR="$X86_CORPUS"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NREPS=5           # keep in sync with the rep list below
fails=0
skips=0
n=0

_smoke_het_rep() {
  local name="$1" dialect="$2" tool="$3" blurb="$4" srcdir="$5"
  local tag pfx filter faillabel d out rc
  case "$dialect" in
    cuda) tag='het'     pfx=e filter='^\+ '      faillabel='comp.sh' ;;
    hip)  tag='het/HIP' pfx=h filter='^\+ hipcc' faillabel='comp.sh hip' ;;
  esac
  n=$((n+1))
  printf '\n[%d/%d] %-9s%-22s -- %s\n' "$n" "$NREPS" "$tag" "$name" "$blurb"
  if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    printf '  SKIP %s (no %s)\n' "$name" "$tool"
    skips=$((skips+1)); return
  fi
  d="$WORK/${pfx}_$name"; mkdir -p "$d"
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

smoke_het() { _smoke_het_rep "$1" cuda '' "$2" "$HET_DIR"; }
smoke_het_hip() { _smoke_het_rep "$1" hip hipcc "$2" "$HETX86_DIR"; }

cmd="${1:-all}"
case "$cmd" in
  all)
    printf '===== HetLitmus compile-smoke (%d reps; nvcc+hipcc+clang, NO GPU) =====\n' "$NREPS"
    smoke_het_hip MP-cg-sys-plain.acq-x86_64 "the AMD render's acquire atomics through hipcc (hipcc -c, gfx942)"
    smoke_het     MP-cg-sys-sy.facq     "CPU dmb sy + inline fence.acquire.sys, sm_90"
    smoke_het     S-gc-sys-ra.frel      "CPU STLR/LDAPR + inline fence.release.sys"
    smoke_het     MP-cg-sys-st.fsc      "CPU dmb st + fence.sc.sys"
    smoke_het     MP-gc-sys-ld.fsc      "CPU dmb ld + fence.sc.sys on the gc cut"
    printf '\n=====================================================================\n'
    # A deleted rep fails the gate instead of shrinking it.
    if [ "$n" -ne "$NREPS" ]; then
      printf 'SMOKE FAILED: %d rep(s) ran, expected %d -- the rep list shrank\n' \
        "$n" "$NREPS"; exit 1
    fi
    if [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ]; then
      printf 'SMOKE OK (%d/%d passed)\n' "$n" "$NREPS"; exit 0
    fi
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK (%d/%d passed, %d skipped)\n' \
        "$((n-skips))" "$NREPS" "$skips"; exit 0
    fi
    printf 'SMOKE FAILED: %d/%d rep(s) failed\n' "$fails" "$NREPS"; exit 1 ;;
  *) printf 'usage: %s [all]\n' "$0"; exit 64 ;;
esac
