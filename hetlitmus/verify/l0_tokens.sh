#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# l0_tokens.sh -- drive ptxcheck.py over the HetLitmus corpus.
#
# L0 = the static, hardware-free faithfulness check: for every emitted GPU (and
# het CPU) harness, the order+scope+kind of every memory op must EXACTLY match
# its .litmus annotation (no weakening, strengthening, miscount, misplacement,
# or missing qualifier).  This script loops the corpus, prints a per-test
# PASS/FAIL table + tally, and (sub-commands) demonstrates the completeness
# guard and the weaken/strengthen self-test.  Mirrors hetlitmus/cats/run-gpu-only.sh.
#
# Usage:
#   bash hetlitmus/verify/l0_tokens.sh            # gpu-only + het table + tally
#   bash hetlitmus/verify/l0_tokens.sh gpu-only   # just the 137 gpu-only
#   bash hetlitmus/verify/l0_tokens.sh het        # just the 338 het
#   bash hetlitmus/verify/l0_tokens.sh guard      # completeness-guard report
#   bash hetlitmus/verify/l0_tokens.sh selftest   # inject weaken+strengthen
#   JOBS=8 bash hetlitmus/verify/l0_tokens.sh     # parallelism (default 4)
# ---------------------------------------------------------------------------
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ROOT
cd "$ROOT"
export PATH="/usr/local/cuda/bin:$ROOT/_build/install/default/bin:$PATH"

CHECK="$ROOT/hetlitmus/verify/ptxcheck.py"
GPU_DIR="$ROOT/hetlitmus/tests/gpu-only"
HET_DIR="$ROOT/hetlitmus/tests/het"
JOBS="${JOBS:-4}"
RESDIR="$(mktemp -d)"
trap 'rm -rf "$RESDIR"' EXIT

# ---- one test -> a single result line "VERDICT name" ----------------------
run_one() {
  local t="$1" name out rc
  name="$(basename "$t" .litmus)"
  out="$(python3 "$CHECK" "$t" -q 2>&1)"; rc=$?
  case "$rc" in
    0) echo "PASS $name" ;;
    1) echo "FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    2) echo "GUARD-FAIL $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
    *) echo "ERROR $name" ; echo "$out" > "$RESDIR/diff.$name" ;;
  esac
}
export -f run_one
export CHECK RESDIR

# ---- loop a directory, print table + tally --------------------------------
run_dir() {
  local dir="$1" label="$2"
  printf '\n===== L0 token check: %s =====\n' "$label"
  printf '%-34s | %s\n' "test" "verdict"
  printf -- '-----------------------------------+---------\n'
  local res="$RESDIR/res.$label"
  ls "$dir"/*.litmus 2>/dev/null | \
    xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} | sort -k2 > "$res"
  awk '{printf "%-34s | %s\n",$2,$1}' "$res"
  printf -- '-----------------------------------+---------\n'
  local total pass fail guard err
  total=$(wc -l < "$res")
  pass=$(grep -c '^PASS '       "$res" || true)
  fail=$(grep -c '^FAIL '       "$res" || true)
  guard=$(grep -c '^GUARD-FAIL ' "$res" || true)
  err=$(grep -c '^ERROR '       "$res" || true)
  printf 'TALLY %s: %d/%d PASS  (FAIL=%d  GUARD-FAIL=%d  ERROR=%d)\n' \
         "$label" "$pass" "$total" "$fail" "$guard" "$err"
  # echo any diffs for non-PASS tests so failures are never papered over
  if [ "$pass" -ne "$total" ]; then
    printf '\n--- diffs for non-PASS %s tests ---\n' "$label"
    grep -vE '^PASS ' "$res" | while read -r v n; do
      printf '>>> %s %s\n' "$v" "$n"; cat "$RESDIR/diff.$n" 2>/dev/null
    done
  fi
  [ "$pass" -eq "$total" ]
}

# ---- completeness-guard report --------------------------------------------
guard_report() {
  printf '\n===== COMPLETENESS GUARD: distinct corpus annotations =====\n'
  printf '\n-- distinct GPU annotations (w/r/f[order,scope]) and their mapping --\n'
  grep -rhoE '[wrf]\[[a-z_]+,[a-z]+\]' "$GPU_DIR"/*.litmus "$HET_DIR"/*.litmus \
    | sort -u | while read -r a; do
        python3 - "$a" <<'PY'
import sys, re, importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ptxcheck", os.path.join(os.environ["ROOT"], "hetlitmus/verify/ptxcheck.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = sys.argv[1]
k, o, s = re.match(r'([wrf])\[([a-z_]+),([a-z]+)\]', a).groups()
ok = (k in m.GPU_KIND) and (o in m.GPU_ORDER) and (s in m.GPU_SCOPE)
print("  %-20s -> %s" % (a, "MAPPED" if ok else "*** UNMAPPED ***"))
PY
      done
  printf '\n-- distinct CPU mnemonics (het CPU columns) and their mapping --\n'
  for f in "$HET_DIR"/*.litmus; do
    awk -F'|' 'f&&/\|/{for(i=1;i<=NF;i++)print $i} /^ *P[0-9].*:cpu|:aarch64/{f=1}' "$f"
  done 2>/dev/null | grep -oE '\b(MOV|STR|STLR|LDR|LDAR|LDAPR|DMB)\b' | sort -u | \
    while read -r mn; do
      python3 - "$mn" <<'PY'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ptxcheck", os.path.join(os.environ["ROOT"], "hetlitmus/verify/ptxcheck.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
mn = sys.argv[1].lower()
print("  %-8s -> %s" % (sys.argv[1], "MAPPED" if mn in m.CPU_MNEMONIC else "*** UNMAPPED ***"))
PY
    done
  printf '\n-- HARD-FAIL demo: an UNKNOWN annotation must abort (exit 2) --\n'
  local u="$RESDIR/UNKNOWN.litmus"
  cat > "$u" <<'EOF'
LISA UNKNOWN-anno
{
}
 P0                  | P1                  ;
 w[consume,sys] x 1  | r[acquire,sys] r0 x ;
scopes: (sys (gpu (cta 0) (cta 1)))
exists (1:r0=1)
EOF
  python3 "$CHECK" "$u"; printf 'exit=%d (expect 2)\n' "$?"
}

# ---- weaken/strengthen self-test on a COPIED ptx --------------------------
selftest() {
  printf '\n===== SELF-TEST: weaken + strengthen injection on a copied PTX =====\n'
  local sc="$RESDIR/self" T=MP-sys-F
  mkdir -p "$sc"
  litmus7 -set-libdir litmus/libdir -o "$sc" "$GPU_DIR/$T.litmus" >/dev/null 2>&1
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$sc/clean.ptx" "$sc/$T.cu" >/dev/null 2>&1
  printf '\n[0] clean PTX (control): expect PASS\n'
  python3 "$CHECK" "$GPU_DIR/$T.litmus" --ptx "$sc/clean.ptx" -q; printf 'exit=%d\n' "$?"
  printf '\n[1] WEAKENING st.release.sys -> st.relaxed.sys: expect FAIL\n'
  sed 's/st\.release\.sys/st.relaxed.sys/' "$sc/clean.ptx" > "$sc/weak.ptx"
  python3 "$CHECK" "$GPU_DIR/$T.litmus" --ptx "$sc/weak.ptx" | grep -E 'FAIL|MISMATCH|RESULT'
  python3 "$CHECK" "$GPU_DIR/$T.litmus" --ptx "$sc/weak.ptx" -q >/dev/null; printf 'exit=%d (expect 1)\n' "$?"
  printf '\n[2] STRENGTHENING ld.relaxed.sys -> ld.acquire.sys: expect FAIL\n'
  sed 's/ld\.relaxed\.sys/ld.acquire.sys/' "$sc/clean.ptx" > "$sc/strong.ptx"
  python3 "$CHECK" "$GPU_DIR/$T.litmus" --ptx "$sc/strong.ptx" | grep -E 'FAIL|MISMATCH|RESULT'
  python3 "$CHECK" "$GPU_DIR/$T.litmus" --ptx "$sc/strong.ptx" -q >/dev/null; printf 'exit=%d (expect 1)\n' "$?"
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only) run_dir "$GPU_DIR" gpu-only ;;
  het)      run_dir "$HET_DIR" het ;;
  guard)    guard_report ;;
  selftest) selftest ;;
  all)
    rc=0
    run_dir "$GPU_DIR" gpu-only || rc=1
    run_dir "$HET_DIR" het || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|gpu-only|het|guard|selftest]"; exit 64 ;;
esac
