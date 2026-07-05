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

# ---- gating helper: compare an actual rc to its expected rc ----------------
# Prints `exit=<act> (expect <exp>) ...` and returns 0 on match, 1 on mismatch,
# so callers can AGGREGATE (no eyeball-only pass-through).
_expect() { # label expected actual
  local label="$1" exp="$2" act="$3"
  if [ "$act" -eq "$exp" ]; then
    printf 'exit=%d (expect %d) OK    [%s]\n' "$act" "$exp" "$label"
    return 0
  fi
  printf 'exit=%d (expect %d) *** MISMATCH ***    [%s]\n' "$act" "$exp" "$label"
  return 1
}

# ---- completeness-guard report (GATED) ------------------------------------
# Every distinct corpus annotation/mnemonic must map into ptxcheck's tables, and
# the unknown-annotation demo must hard-fail (exit 2).  Aggregates: returns
# NONZERO if any section fails; prints GUARD OK only when all pass.
guard_report() {
  printf '\n===== COMPLETENESS GUARD: distinct corpus annotations =====\n'
  local fails=0 rc

  printf '\n-- distinct GPU annotations (w/r/f[order,scope]) and their mapping --\n'
  # heredoc supplies python's PROGRAM via `-`, so the annotation DATA must arrive
  # by a file path in argv (piping into `python3 - <<PY` would be swallowed by
  # the heredoc); the empty-list case is itself a hard fail (no vacuous pass).
  local annof="$RESDIR/gpu_annos.txt"
  grep -rhoE '[wrf]\[[a-z_]+,[a-z]+\]' "$GPU_DIR"/*.litmus "$HET_DIR"/*.litmus \
    | sort -u > "$annof"
  python3 - "$ROOT" "$annof" <<'PY'
import sys, re, importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ptxcheck", os.path.join(sys.argv[1], "hetlitmus/verify/ptxcheck.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with open(sys.argv[2]) as fh:
    annos = [l.strip() for l in fh if l.strip()]
bad = 0
for a in annos:
    k, o, s = re.match(r'([wrf])\[([a-z_]+),([a-z]+)\]', a).groups()
    ok = (k in m.GPU_KIND) and (o in m.GPU_ORDER) and (s in m.GPU_SCOPE)
    if not ok:
        bad += 1
    print("  %-20s -> %s" % (a, "MAPPED" if ok else "*** UNMAPPED ***"))
if not annos:
    print("  *** no GPU annotations extracted -- corpus empty or path wrong")
    bad += 1
sys.exit(1 if bad else 0)
PY
  rc=$?; [ "$rc" -ne 0 ] && fails=$((fails+1))

  printf '\n-- distinct CPU mnemonics (het CPU columns, PATTERN-extracted) and their mapping --\n'
  # No allow-list: pull the leading opcode token of EVERY cell in EVERY het CPU
  # column, so a NEW/unmapped mnemonic surfaces instead of being silently
  # dropped, then check each against ptxcheck.CPU_MNEMONIC.
  python3 - "$ROOT" "$HET_DIR" <<'PY'
import sys, re, os, glob, importlib.util
root, het_dir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "ptxcheck", os.path.join(root, "hetlitmus/verify/ptxcheck.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen, errs = {}, 0
for f in sorted(glob.glob(os.path.join(het_dir, "*.litmus"))):
    try:
        procs, rows = m.parse_body(m.read_litmus(f))
        ncol = len(procs)
        cols = [[] for _ in range(ncol)]
        for row in rows:
            for c in range(ncol):
                cols[c].append(row[c] if c < len(row) else '')
        for col, (pidx, dev) in enumerate(procs):
            if m.device_class(dev) != 'cpu':
                continue
            for cell in cols[col]:
                cell = cell.strip()
                if not cell:
                    continue
                mo = re.match(r'([A-Za-z][A-Za-z0-9.]*)', cell)  # leading opcode
                if not mo:
                    continue
                mn = mo.group(1).upper()
                seen[mn] = seen.get(mn, 0) + 1
    except Exception as e:
        errs += 1
        print("  PARSE-ERROR %s: %s" % (os.path.basename(f), e))
bad = 0
for mn in sorted(seen):
    mapped = mn.lower() in m.CPU_MNEMONIC
    if not mapped:
        bad += 1
    print("  %-8s -> %-16s (%d cells)"
          % (mn, "MAPPED" if mapped else "*** UNMAPPED ***", seen[mn]))
sys.exit(1 if (bad or errs) else 0)
PY
  rc=$?; [ "$rc" -ne 0 ] && fails=$((fails+1))

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
  local out
  out="$(python3 "$CHECK" "$u" 2>&1)"; rc=$?
  echo "$out" | grep -E 'COMPLETENESS|HARD-FAIL' || echo "$out"
  printf 'exit=%d (expect 2)\n' "$rc"
  [ "$rc" -ne 2 ] && fails=$((fails+1))

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "GUARD OK"
    return 0
  fi
  echo "GUARD FAILED: $fails guard section(s) did not behave as expected"
  return 1
}

# ---- negative/completeness self-test on COPIED artifacts (GATED) ----------
# Six controls: [0] clean PASS, [1] weaken order, [2] strengthen order,
# [3] weaken scope, [4] miscount (drop an op), [5] CPU STLR->STR on a het test.
# Each injection is expected to FAIL(1); the two controls PASS(0).  Aggregates:
# returns NONZERO if any actual rc != expected; prints SELFTEST OK only if all
# match.  Operates ONLY on copies -- the corpus .litmus files are untouched.
selftest() {
  printf '\n===== SELF-TEST: negative controls on copied artifacts =====\n'
  local sc="$RESDIR/self" T=MP-sys-F fails=0 rc out
  local L="$GPU_DIR/$T.litmus"
  mkdir -p "$sc"
  litmus7 -set-libdir litmus/libdir -o "$sc" "$L" >/dev/null 2>&1
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$sc/clean.ptx" "$sc/$T.cu" >/dev/null 2>&1
  if [ ! -s "$sc/clean.ptx" ]; then
    echo "SELF-TEST ERROR: could not emit/compile $T PTX"
    return 1
  fi

  printf '\n[0] clean PTX (control): expect PASS(0)\n'
  python3 "$CHECK" "$L" --ptx "$sc/clean.ptx" -q >/dev/null 2>&1; rc=$?
  _expect "clean control" 0 "$rc" || fails=$((fails+1))

  printf '\n[1] WEAKEN order  st.release.sys -> st.relaxed.sys: expect FAIL(1)\n'
  sed 's/st\.release\.sys/st.relaxed.sys/' "$sc/clean.ptx" > "$sc/i1.ptx"
  out="$(python3 "$CHECK" "$L" --ptx "$sc/i1.ptx" 2>&1)"; rc=$?
  echo "$out" | grep -E 'MISMATCH|RESULT'
  _expect "weaken order" 1 "$rc" || fails=$((fails+1))

  printf '\n[2] STRENGTHEN order  ld.relaxed.sys -> ld.acquire.sys: expect FAIL(1)\n'
  sed 's/ld\.relaxed\.sys/ld.acquire.sys/' "$sc/clean.ptx" > "$sc/i2.ptx"
  out="$(python3 "$CHECK" "$L" --ptx "$sc/i2.ptx" 2>&1)"; rc=$?
  echo "$out" | grep -E 'MISMATCH|RESULT'
  _expect "strengthen order" 1 "$rc" || fails=$((fails+1))

  printf '\n[3] WEAKEN scope  st.release.sys -> st.release.cta: expect FAIL(1)\n'
  sed 's/st\.release\.sys/st.release.cta/' "$sc/clean.ptx" > "$sc/i3.ptx"
  out="$(python3 "$CHECK" "$L" --ptx "$sc/i3.ptx" 2>&1)"; rc=$?
  echo "$out" | grep -E 'MISMATCH|RESULT'
  _expect "weaken scope" 1 "$rc" || fails=$((fails+1))

  printf '\n[4] MISCOUNT  delete the st.release.sys.b32 op line: expect FAIL(1)\n'
  sed '/st\.release\.sys\.b32/d' "$sc/clean.ptx" > "$sc/i4.ptx"
  out="$(python3 "$CHECK" "$L" --ptx "$sc/i4.ptx" 2>&1)"; rc=$?
  echo "$out" | grep -E 'MISMATCH|RESULT'
  _expect "miscount (dropped op)" 1 "$rc" || fails=$((fails+1))

  printf '\n[5] CPU faithfulness on a two-sided acqrel het _cpu.c: control PASS(0), STLR->STR FAIL(1)\n'
  local HT=2+2W-cg-sys-acqrel-2s HL="$HET_DIR/2+2W-cg-sys-acqrel-2s.litmus"
  local hd="$sc/het" cpu_c
  mkdir -p "$hd"
  litmus7 -set-libdir litmus/libdir -o "$hd" "$HL" >/dev/null 2>&1
  cpu_c="$hd/$HT/${HT}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$hd/het.ptx" "$hd/$HT/$HT.cu" >/dev/null 2>&1
  if [ ! -s "$cpu_c" ] || [ ! -s "$hd/het.ptx" ]; then
    echo "  *** could not emit het harness/_cpu.c for $HT"
    fails=$((fails+1))
  elif ! grep -qiE '"[[:space:]]*stlr\b' "$cpu_c"; then
    echo "  *** $HT _cpu.c has no STLR -- wrong test picked"
    fails=$((fails+1))
  else
    echo "  confirmed: $HT _cpu.c contains STLR (release-store)"
    python3 "$CHECK" "$HL" --ptx "$hd/het.ptx" --cpu-c "$cpu_c" -q >/dev/null 2>&1; rc=$?
    _expect "het CPU control (unmodified)" 0 "$rc" || fails=$((fails+1))
    sed 's/\bstlr\b/str/Ig' "$cpu_c" > "$hd/str_cpu.c"
    out="$(python3 "$CHECK" "$HL" --ptx "$hd/het.ptx" --cpu-c "$hd/str_cpu.c" 2>&1)"; rc=$?
    echo "$out" | grep -E 'MISMATCH|RESULT'
    _expect "het CPU STLR->STR injection" 1 "$rc" || fails=$((fails+1))
  fi

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "SELFTEST OK"
    return 0
  fi
  echo "SELFTEST FAILED: $fails control(s) did not behave as expected"
  return 1
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only) run_dir "$GPU_DIR" gpu-only ;;
  het)      run_dir "$HET_DIR" het ;;
  guard)    guard_report; exit $? ;;
  selftest) selftest; exit $? ;;
  all)
    rc=0
    run_dir "$GPU_DIR" gpu-only || rc=1
    run_dir "$HET_DIR" het || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|gpu-only|het|guard|selftest]"; exit 64 ;;
esac
