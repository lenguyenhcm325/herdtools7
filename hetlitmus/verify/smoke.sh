#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke.sh -- Layer-3 compile-smoke for the HetLitmus toolchain.
#
# "Does the emitted harness actually COMPILE end-to-end?"  The faithfulness
# sweep (l0_tokens.sh) already `nvcc --ptx`-compiles every gpu-only .cu, but it
# does NOT exercise the het harness's CPU side, the `nvcc -c`/ptxas object
# stage, or the Hopper-cluster inline-PTX path.  smoke.sh closes that gap by
# emitting a curated 6-rep sample and driving each test's OWN `comp.sh`
# (compile-only: gcc host + `clang --target=aarch64-linux-gnu` real AArch64 asm
# + `nvcc -std=c++17 -arch=sm_90 -c`).  Needs nvcc+clang but NO GPU -- `-arch`
# is a compile target, not a device requirement; only *launching* a kernel
# needs hardware (that is Layer 4).  Reuses `comp.sh` verbatim (no new build
# code); see hetlitmus/docs/TEST-PLAN.md sec.5.
#
# The 6 reps -- each hits one distinct compile path once:
#   1. MP-cg-cta-acquire       het one-sided; plain CPU STR/LDR + barrier
#   2. 2+2W-cg-sys-acqrel-2s   het two-sided; CPU STLR + LDAPR (release/acquire)
#   3. 2+2W-cg-sys-fence-2s    het two-sided; CPU DMB.SY fence
#   4. IRIW-cgcc-cta-relaxed   het 4-proc; largest barrier / scaffolding
#   5. WRC-ccg-cta-relaxed     het 3-proc; buys down the proc-scaling assumption
#   6. tests/cluster/MP-cluster  gpu-only Hopper cluster inline-PTX fence path
#
# Usage:
#   bash hetlitmus/verify/smoke.sh          # run all 6 reps (pre-commit gate)
#   bash hetlitmus/verify/smoke.sh bite      # prove the gate has TEETH (self-test)
#
# Exit 0 (prints `SMOKE OK`) iff all 6 reps compile; nonzero if any rep fails.
# ---------------------------------------------------------------------------
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="/usr/local/cuda/bin:$ROOT/_build/install/default/bin:$PATH"

HET_DIR="$ROOT/hetlitmus/tests/het"
CLU_DIR="$ROOT/hetlitmus/tests/cluster"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
n=0

# ---- het rep: emit the Tier-2 harness dir, run its OWN comp.sh -------------
# litmus7 -o <d> writes a NESTED <d>/<name>/ dir holding <name>.cu, <name>_cpu.c,
# outs.c and comp.sh.  `sh comp.sh cuda` compiles-only (-c, no link, no GPU),
# printing `HetLitmus: compile OK` and exiting 0 on success (set -e inside).
smoke_het() { # name blurb
  local name="$1" blurb="$2" d out rc
  n=$((n+1))
  printf '\n[%d/6] het      %-22s -- %s\n' "$n" "$name" "$blurb"
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

# ---- cluster rep: gpu-only, flat .cu, bare `nvcc -c` -----------------------
# The cluster family is GPU-only (no CPU side, no comp.sh) AND sits OUTSIDE the
# faithfulness sweep (l0_tokens covers only gpu-only + het), so smoke is its
# ONLY compile check.  Emit the flat <name>.cu, then object-compile it.
smoke_cluster() { # name blurb
  local name="$1" blurb="$2" d out rc
  n=$((n+1))
  printf '\n[%d/6] cluster  %-22s -- %s\n' "$n" "$name" "$blurb"
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
    printf '===== HetLitmus Layer-3 compile-smoke (6 reps; nvcc+clang, NO GPU) =====\n'
    smoke_het     MP-cg-cta-acquire     "one-sided; plain CPU STR/LDR + barrier + nvcc -c"
    smoke_het     2+2W-cg-sys-acqrel-2s "two-sided; CPU STLR + LDAPR (release/acquire)"
    smoke_het     2+2W-cg-sys-fence-2s  "two-sided; CPU DMB.SY fence"
    smoke_het     IRIW-cgcc-cta-relaxed "4-proc; largest barrier / scaffolding"
    smoke_het     WRC-ccg-cta-relaxed   "3-proc; buys down the proc-scaling assumption"
    smoke_cluster MP-cluster            "Hopper cluster inline-PTX fence path (nvcc -c)"
    printf '\n=====================================================================\n'
    if [ "$fails" -eq 0 ]; then
      printf 'SMOKE OK  (6/6 reps compiled)\n'; exit 0
    fi
    printf 'SMOKE FAILED: %d/6 rep(s) did not compile\n' "$fails"; exit 1 ;;
  *) printf 'usage: %s [all|bite]\n' "$0"; exit 64 ;;
esac
