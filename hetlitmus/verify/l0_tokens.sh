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
#   bash hetlitmus/verify/l0_tokens.sh het        # just the 386 het
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
# Overridable so the F4 census guard can be BITTEN (point at an empty dir -> the
# expected 137/386 fails).  Default is the real corpus, so normal runs are unchanged.
GPU_DIR="${GPU_DIR:-$ROOT/hetlitmus/tests/gpu-only}"
HET_DIR="${HET_DIR:-$ROOT/hetlitmus/tests/het}"
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
  local dir="$1" label="$2" expect="${3:-0}"
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
  # F4 (DR1-B): `pass -eq total' is VACUOUSLY true on an empty/misnamed corpus
  # (0 -eq 0) -- it would print "faithfulness (523): OK" for ZERO tests, the exact
  # inert-gate class this project keeps shipping.  Assert the KNOWN census
  # (het=386, gpu-only=137), the same exact-count discipline corpus-gate and
  # verdictcheck use; a census change then has to be a deliberate edit to the
  # CALL SITE, never an accident.
  if [ "$expect" -gt 0 ] && [ "$total" -ne "$expect" ]; then
    printf 'CENSUS FAIL %s: %d .litmus emitted, expected %d (empty/misnamed corpus?)\n' \
           "$label" "$total" "$expect" >&2
    return 1
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

  # ---- [5b] Q10b: the CPU BARRIER OPTION -------------------------------------
  # `DMB SY' / `DMB ST' / `DMB LD' are THREE different instructions
  # (d5033fbf / d5033ebf / d5033dbf) supplying three different orderings
  # ({WW,RR,WR,RW} / {WW} / {RR,RW} -- ordercheck.py Phase 1), and since Q10b
  # lifted the hetCpuBody.ml blocker all three are in the corpus.  Two SEPARATE
  # properties, so two bites:
  #   (i)  DISCRIMINATION -- an emitted `dmb sy' silently lowered to `dmb st'
  #        must FAIL(1) naming the mismatch.  This already held before Q10b (the
  #        compared op tuple has always carried the option); the bite PINS it,
  #        because the corpus now actually varies the option.
  #   (ii) COMPLETENESS -- an option that is NOT modelled must HARD-FAIL(2)
  #        instead of being compared as an opaque string.  Before Q10b it was
  #        not: rewriting the corpus's `DMB SY' to the inner-shareable `DMB ISH'
  #        -- a strictly narrower shareability domain that cannot be assumed to
  #        reach the GPU across C2C -- and matching the emitted asm to it passed
  #        this gate with rc=0.  ptxcheck.CPU_BARRIER_OPTION closes that.
  printf '\n[5b] Q10b CPU barrier option: weakened option FAIL(1), unmodelled option HARD-FAIL(2)\n'
  local DT=2+2W-cg-sys-fence-2s DL="$HET_DIR/2+2W-cg-sys-fence-2s.litmus"
  local dd="$sc/dmb" dcpu
  mkdir -p "$dd"
  litmus7 -set-libdir litmus/libdir -o "$dd" "$DL" >/dev/null 2>&1
  dcpu="$dd/$DT/${DT}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$dd/dmb.ptx" "$dd/$DT/$DT.cu" >/dev/null 2>&1
  if [ ! -s "$dcpu" ] || [ ! -s "$dd/dmb.ptx" ]; then
    echo "  *** could not emit het harness/_cpu.c for $DT"
    fails=$((fails+1))
  elif ! grep -qiE '"[[:space:]]*dmb[[:space:]]+sy' "$dcpu"; then
    echo "  *** $DT _cpu.c has no 'dmb sy' -- wrong test picked"
    fails=$((fails+1))
  else
    echo "  confirmed: $DT _cpu.c contains 'dmb sy' (full system barrier)"
    python3 "$CHECK" "$DL" --ptx "$dd/dmb.ptx" --cpu-c "$dcpu" -q >/dev/null 2>&1; rc=$?
    _expect "CPU barrier control (unmodified)" 0 "$rc" || fails=$((fails+1))

    sed 's/\bdmb sy\b/dmb st/g' "$dcpu" > "$dd/st_cpu.c"
    if cmp -s "$dcpu" "$dd/st_cpu.c"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [dmb sy -> dmb st]\n'
      fails=$((fails+1))
    else
      out="$(python3 "$CHECK" "$DL" --ptx "$dd/dmb.ptx" --cpu-c "$dd/st_cpu.c" 2>&1)"; rc=$?
      echo "$out" | grep -E 'MISMATCH' | head -2
      _expect "emitted dmb sy WEAKENED to dmb st" 1 "$rc" || fails=$((fails+1))
    fi

    # (ii) unmodelled option, CONSISTENT on both sides -- the case a pure
    # expected-vs-observed comparison cannot see.  The whole corpus copy is
    # rewritten so the co-run mutant/canary columns agree too.
    rm -rf "$dd/ish"; cp -r "$HET_DIR" "$dd/ish"
    sed -i 's/DMB SY/DMB ISH/' "$dd"/ish/*.litmus
    sed 's/\bdmb sy\b/dmb ish/g' "$dcpu" > "$dd/ish_cpu.c"
    if cmp -s "$dcpu" "$dd/ish_cpu.c" || ! grep -q 'DMB ISH' "$dd/ish/$DT.litmus"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [DMB SY -> DMB ISH]\n'
      fails=$((fails+1))
    else
      out="$(python3 "$CHECK" "$dd/ish/$DT.litmus" --ptx "$dd/dmb.ptx" \
             --cpu-c "$dd/ish_cpu.c" 2>&1)"; rc=$?
      echo "$out" | grep -E 'COMPLETENESS' | head -1
      _expect "unmodelled barrier option DMB ISH (both sides agree)" 2 "$rc" \
        || fails=$((fails+1))
    fi
    rm -rf "$dd/ish"
  fi

  # ---- [6] B4: the GPU stress layer's ops are MODELLED, and the model bites ----
  # The stress layer adds ops to the kernel, so ptxcheck had to grow an
  # expectation for them.  An expectation that cannot fail is worse than none, so
  # prove each one bites.  The load-bearing case is the FIRST: widening the
  # device-scope window-opener to SYSTEM scope would silently turn it into a
  # per-iteration CROSS-DEVICE barrier, which masks the very order under test
  # (Srivastava 4.1).  The last case guards the blind spot the stress layer could
  # otherwise hide in: a sys-scope op emitted by a compiler BUILTIN sits outside
  # the PTX inline-asm markers, where the model-op check cannot see it.
  #
  # Each injection is verified to ACTUALLY change the file first -- a sed that
  # silently matches nothing would make this whole section a vacuous pass.
  printf '\n[6] B4 stress layer: spin + stray-sys injections must FAIL(1)\n'
  local B4T=MP-cg-sys-acqrel-2s
  local B4L="$HET_DIR/$B4T.litmus" b4="$sc/b4" b4cpu b4rc
  mkdir -p "$b4"
  litmus7 -set-libdir litmus/libdir -o "$b4" "$B4L" >/dev/null 2>&1
  b4cpu="$b4/$B4T/${B4T}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$b4/clean.ptx" "$b4/$B4T/$B4T.cu" >/dev/null 2>&1
  if [ ! -s "$b4/clean.ptx" ] || [ ! -s "$b4cpu" ]; then
    echo "  *** could not emit/compile the B4 het harness for $B4T"
    fails=$((fails+1))
  elif ! grep -q 'het_spin' "$b4/$B4T/$B4T.cu"; then
    echo "  *** $B4T.cu has no het_spin -- the stress layer is not emitted"
    fails=$((fails+1))
  else
    # control: the unmodified stress-bearing harness must PASS
    python3 "$CHECK" "$B4L" --ptx "$b4/clean.ptx" --cpu-c "$b4cpu" -q >/dev/null 2>&1; b4rc=$?
    _expect "B4 control (stress layer present)" 0 "$b4rc" || fails=$((fails+1))

    _b4bite() { # label sed-expr
      local lbl="$1" expr="$2" rc
      sed "$expr" "$b4/clean.ptx" > "$b4/bite.ptx"
      if cmp -s "$b4/clean.ptx" "$b4/bite.ptx"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      python3 "$CHECK" "$B4L" --ptx "$b4/bite.ptx" --cpu-c "$b4cpu" -q >/dev/null 2>&1; rc=$?
      _expect "$lbl" 1 "$rc"
    }
    _b4bite "spin WIDENED to sys scope (= a per-iteration cross-device barrier)" \
            's/atom\.add\.relaxed\.gpu/atom.add.relaxed.sys/' || fails=$((fails+1))
    _b4bite "spin narrowed gpu -> cta" \
            's/atom\.add\.relaxed\.gpu/atom.add.relaxed.cta/' || fails=$((fails+1))
    _b4bite "spin strengthened relaxed -> acquire" \
            's/atom\.add\.relaxed\.gpu/atom.add.acquire.gpu/' || fails=$((fails+1))
    _b4bite "spin fetch_add dropped" \
            '/atom\.add\.relaxed\.gpu/d' || fails=$((fails+1))
    _b4bite "spin busy-wait load dropped" \
            '/ld\.relaxed\.gpu/d' || fails=$((fails+1))

    # a builtin sys-scope op (e.g. __threadfence_system() sneaking into stress
    # code) lands OUTSIDE the inline-asm markers -- invisible to the op-stream
    # check, which is exactly why check_no_stray_sys exists.
    python3 - "$b4/clean.ptx" "$b4/bite.ptx" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, in_asm, done = [], False, False
for l in open(src).read().splitlines():
    s = l.strip()
    if s.startswith('// begin inline asm'):
        in_asm = True
    if not in_asm and not done and s.startswith('ret;'):
        out.append('\tfence.sc.sys;')   # mimics __threadfence_system()
        done = True
    out.append(l)
    if s.startswith('// end inline asm'):
        in_asm = False
open(dst, 'w').write("\n".join(out) + "\n")
sys.exit(0 if done else 1)
PY
    if cmp -s "$b4/clean.ptx" "$b4/bite.ptx"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [stray builtin sys-scope op]\n'
      fails=$((fails+1))
    else
      python3 "$CHECK" "$B4L" --ptx "$b4/bite.ptx" --cpu-c "$b4cpu" -q >/dev/null 2>&1; b4rc=$?
      _expect "stray builtin sys-scope op (outside inline asm)" 1 "$b4rc" || fails=$((fails+1))
    fi
  fi

  # ---- [7] B4-fix: the stress layer is LIVE, and the liveness gate bites ------
  # ptxcheck is blind to the stress layer BY DESIGN (scaffolding carries no
  # order/scope qualifier, so it is not a model op).  That blind spot let B4 ship
  # a pre-stress incantation that nvcc DELETED -- a compile-time access pattern
  # folds do_stress's if-chain to `ld;ld', whose loads only feed a `break', which
  # is provably side-effect-free.  Zero instructions, five green gates.
  #
  # stresscheck.py closes it: it counts scratchpad ops in the emitted PTX per
  # lane class, and asserts the count is INVARIANT under -DHET_*_PATTERN (which
  # is the property "the pattern is a runtime value" -- i.e. no autotuner config
  # can silently switch the stress off).  Prove it BITES, or it is decoration.
  #
  # Each injection mutates a COPY of the emitted .cu and is verified to actually
  # change the file first (cmp -s), so no bite can pass vacuously.
  printf '\n[7] B4-fix stress liveness: the gate must FAIL(1) on a dead stress layer\n'
  local SL="$ROOT/hetlitmus/verify/stresscheck.py"
  local S4T=MP-cg-sys-acqrel-2s
  local S4L="$HET_DIR/$S4T.litmus" s4="$sc/s4" s4cu s4rc
  mkdir -p "$s4"
  litmus7 -set-libdir litmus/libdir -o "$s4" "$S4L" >/dev/null 2>&1
  s4cu="$s4/$S4T/$S4T.cu"
  if [ ! -s "$s4cu" ]; then
    echo "  *** could not emit the het harness for $S4T"
    fails=$((fails+1))
  else
    # control: the shipped harness must PASS (this is also the gate's own
    # regression test -- it failed here before the B4-fix, with 0 pre-stress ops)
    python3 "$SL" --cu "$s4cu" -q >/dev/null 2>&1; s4rc=$?
    _expect "stress liveness control (unmodified harness)" 0 "$s4rc" || fails=$((fails+1))

    _s4bite() { # label sed-expr
      local lbl="$1" expr="$2" rc
      rm -rf "$s4/mut"; cp -r "$s4/$S4T" "$s4/mut"
      sed -i "$expr" "$s4/mut/$S4T.cu"
      if cmp -s "$s4cu" "$s4/mut/$S4T.cu"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      python3 "$SL" --cu "$s4/mut/$S4T.cu" -q >/dev/null 2>&1; rc=$?
      _expect "$lbl" 1 "$rc"
    }
    # THE historical B4 bug, both call sites: hand het_do_stress a compile-time
    # pattern and the tuned default (3 = ld;ld) is dead-code-eliminated away.
    _s4bite "pre-stress pattern made compile-time (the B4 regression itself)" \
            's/HET_PRE_STRESS_ITER, _pre_pat/HET_PRE_STRESS_ITER, HET_PRE_STRESS_PATTERN/' \
            || fails=$((fails+1))
    _s4bite "mem-stress pattern made compile-time (the B8 autotune blast radius)" \
            's/HET_MEM_STRESS_ITER, _mem_pat/HET_MEM_STRESS_ITER, HET_MEM_STRESS_PATTERN/' \
            || fails=$((fails+1))
    _s4bite "pre-stress call dropped (test lanes stop self-stressing)" \
            '/het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER/d' \
            || fails=$((fails+1))
    _s4bite "mem-stress call dropped (stressing workgroups stop stressing)" \
            '/het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER/d' \
            || fails=$((fails+1))
    rm -rf "$s4/mut"
  fi

  # ---- [8] B5: the CPU + interconnect stress layer's gate must BITE -----------
  # B5 shipped cpustresscheck.py with NO negative control.  That is the sharpest
  # possible omission: cpustresscheck is the ONE checker able to catch a regression
  # that preserves the source text while killing the COMPILED mechanism (strip
  # `volatile' and the enemy still reads beautifully and issues nothing), and it was
  # itself unguarded.  A checker nobody has ever seen fail is not evidence.
  #
  # Six injections, one per way the layer can silently die.  Four mutate
  # het_cpu_stress.h (the mechanisms); two mutate the emitted .cu DRIVER (the
  # invariants S5/S6 -- a noise buffer that fits in cache, and enemies pointed at
  # the very locations under test).  Every one is verified to ACTUALLY change the
  # file (cmp -s) before its result is believed: a sed that silently matched nothing
  # would make this whole section a vacuous pass, and that has happened here before.
  printf '\n[8] B5 CPU/interconnect stress: the liveness gate must FAIL(1) on a dead layer\n'
  local CS="$ROOT/hetlitmus/verify/cpustresscheck.py"
  local B5T=MP-cg-sys-acqrel-2s
  local B5L="$HET_DIR/$B5T.litmus" b5="$sc/b5" b5rc
  mkdir -p "$b5"
  litmus7 -set-libdir litmus/libdir -o "$b5" "$B5L" >/dev/null 2>&1
  if [ ! -s "$b5/$B5T/het_cpu_stress.h" ] || [ ! -s "$b5/$B5T/$B5T.cu" ]; then
    echo "  *** could not emit the B5 het harness for $B5T"
    fails=$((fails+1))
  else
    # control: the SHIPPED harness must PASS.  (This doubles as cpustresscheck's own
    # regression test -- it is what fails if B5's fixes are ever reverted.)
    python3 "$CS" "$B5L" --harness-dir "$b5/$B5T" >/dev/null 2>&1; b5rc=$?
    _expect "B5 control (shipped CPU/interconnect layer)" 0 "$b5rc" || fails=$((fails+1))

    _b5bite() { # label  file  sed-expr
      local lbl="$1" file="$2" expr="$3" rc
      rm -rf "$b5/mut"; cp -r "$b5/$B5T" "$b5/mut"
      sed -i "$expr" "$b5/mut/$file"
      if cmp -s "$b5/$B5T/$file" "$b5/mut/$file"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      python3 "$CS" "$B5L" --harness-dir "$b5/mut" >/dev/null 2>&1; rc=$?
      _expect "$lbl" 1 "$rc"
    }

    # (1) THE one that a naive gate waves through.  Without `volatile' the enemy's
    # discarded reads `(void)*l' are provably useless and clang deletes ALL of them,
    # and sigma 0's double store collapses to one.  The loop survives, so it still
    # LOOKS like a stressor; it just issues no read traffic and half the writes.
    _b5bite "enemy scratchpad volatile STRIPPED (all read traffic deleted)" \
            het_cpu_stress.h \
            's/volatile uint64_t \*scratch/uint64_t *scratch/; s/volatile uint64_t \*l =/uint64_t *l =/' \
            || fails=$((fails+1))

    # (2) sigma as a compile-time constant: the optimiser folds the switch to one
    # branch and, for ld;ld, deletes the loop.  This is B4's bug on the CPU side.
    _b5bite "sigma made COMPILE-TIME (an autotuner config can delete the stress)" \
            het_cpu_stress.h \
            's/switch (a->seq) {/switch (HET_CPU_ENEMY_SEQ) {/' \
            || fails=$((fails+1))

    # (3) the M3 preload made inert -- the incantation is still there and still
    # called, it just issues no cache hints.  Only a RUN can see this.
    _b5bite "preload hints DROPPED (M3 incantation inert)" \
            het_cpu_stress.h \
            's/^  uint32_t n = 0u;/  uint32_t n = 0u; return n;/' \
            || fails=$((fails+1))

    # (4) first-touch dropped: an unwritten malloc'd buffer is ONE shared zero page,
    # so the 8 GB "noise" streams a single cache line out of L1 and crosses nothing.
    _b5bite "noise first-touch DROPPED (8 GB buffer is one shared zero page)" \
            het_cpu_stress.h \
            's|^void het_cpu_first_touch(void \*p, size_t bytes) {|void het_cpu_first_touch(void *p, size_t bytes) { (void)p; (void)bytes; return;|' \
            || fails=$((fails+1))

    # (5) DRIVER: the noise working set decoupled from HET_NOISE_MB and shrunk below
    # the LLC -- served from cache, zero interconnect traffic, every counter still
    # moving.  Caught by S5 (which is why S5 had to be written).
    _b5bite "noise buffer UNDERSIZED (fits in cache => no C2C traffic)" \
            "$B5T.cu" \
            's|uint64_t _noise_words = (uint64_t)HET_NOISE_MB \* 1024ull \* 1024ull / sizeof(uint64_t);|uint64_t _noise_words = 4096ull;|' \
            || fails=$((fails+1))

    # (6) DRIVER: the enemies pointed at a TEST VARIABLE.  Not a weaker experiment --
    # a fabricated one: an enemy writing the location under test can manufacture the
    # weak behaviour outright.  Caught by S6 (which is why S6 had to be written).
    # B6b: the tested location is `t_x', not `x' -- MP-cg-sys-acqrel-2s is a
    # should-be-FORBIDDEN test, so its harness CO-RUNS T + mu(T) + the canary and
    # every instance's locations are prefixed.  Aliasing onto a name that does not
    # exist would make the harness fail to COMPILE, and cpustresscheck would exit 2
    # (toolchain error) instead of 1 (the S6 violation) -- a bite that "fails" for
    # the wrong reason is not a bite.  Point it at a location that is genuinely
    # under test, which is the corruption S6 exists to catch.
    _b5bite "enemy scratchpad ALIASED onto a test variable (fabricates outcomes)" \
            "$B5T.cu" \
            's/_ea\[_e\]\.scratch = _cpu_scratch;/_ea[_e].scratch = t_x;/' \
            || fails=$((fails+1))

    rm -rf "$b5/mut"
  fi

  # =========================================================================
  # [9] B6b -- THE CO-RUN.  Does the faithfulness gate actually SEE the control?
  # =========================================================================
  # The whole point of B6b is that mu(T) and the canary run INSIDE T's harness, so
  # a null on T can be read against a known-ALLOWED weak behaviour that fired on the
  # same C2C path.  That makes the CONTROL's lowering as load-bearing as T's:
  #
  #   * a control whose lanes are MISSING is a positive control that is not there --
  #     but HET_CONTROL_COMPILED_IN still says 1, so every null it gates silently
  #     becomes a *credible* null.  The most dangerous failure available here.
  #   * a mutant whose ordering was silently WEAKENED is a different mutant: it no
  #     longer isolates the primitive under test, so the vouch is for the wrong thing.
  #   * a mutant whose ordering was silently STRENGTHENED may not fire at all,
  #     leaving the control permanently cold -- which DISCARDS every null on T.
  #
  # ptxcheck now models every lane of every instance.  Prove it BITES on each.
  printf '\n[9] B6b co-run: the gate must FAIL(1) when a CONTROL instance is corrupted\n'
  local B6T=MP-cg-sys-fence-2s
  local B6L="$HET_DIR/$B6T.litmus" b6="$sc/b6" b6rc
  mkdir -p "$b6"
  litmus7 -set-libdir litmus/libdir -o "$b6" "$B6L" >/dev/null 2>&1
  if [ ! -s "$b6/$B6T/$B6T.cu" ]; then
    echo "  *** could not emit the B6b co-run harness for $B6T"
    fails=$((fails+1))
  elif ! grep -q '#define HET_CONTROL_COMPILED_IN 1' "$b6/$B6T/$B6T.cu"; then
    # A co-run harness that is not co-running is the failure this whole task exists
    # to prevent.  Never let the section pass vacuously on a single-instance emit.
    echo "  *** $B6T did not emit a CO-RUN harness (HET_CONTROL_COMPILED_IN != 1)"
    fails=$((fails+1))
  else
    nvcc -std=c++17 -arch=sm_90 --ptx -o "$b6/clean.ptx" "$b6/$B6T/$B6T.cu" 2>/dev/null
    python3 "$CHECK" "$B6L" --ptx "$b6/clean.ptx" --cpu-c "$b6/$B6T/${B6T}_cpu.c" \
      >/dev/null 2>&1; b6rc=$?
    _expect "B6b control (shipped co-run harness: T + mu(T) + canary)" 0 "$b6rc" \
      || fails=$((fails+1))

    _b6bite() { # label  file  python-corruption-of-$IN-to-$OUT  ptx|cpu
      local lbl="$1" src="$2" prog="$3" kind="$4" rc
      rm -rf "$b6/mut"; cp -r "$b6/$B6T" "$b6/mut"
      IN="$b6/$B6T/$src" OUT="$b6/mut/$src" python3 -c "$prog" 2>/dev/null || {
        printf '  *** BITE SCRIPT FAILED (nothing to corrupt)    [%s]\n' "$lbl"; return 1; }
      if cmp -s "$b6/$B6T/$src" "$b6/mut/$src"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      if [ "$kind" = ptx ]; then
        nvcc -std=c++17 -arch=sm_90 --ptx -o "$b6/mut.ptx" "$b6/mut/$B6T.cu" 2>/dev/null
        python3 "$CHECK" "$B6L" --ptx "$b6/mut.ptx" \
          --cpu-c "$b6/$B6T/${B6T}_cpu.c" >/dev/null 2>&1; rc=$?
      else
        python3 "$CHECK" "$B6L" --ptx "$b6/clean.ptx" \
          --cpu-c "$b6/mut/${B6T}_cpu.c" >/dev/null 2>&1; rc=$?
      fi
      _expect "$lbl" 1 "$rc"
    }

    # (1) the mutant's ordering primitive silently WEAKENED.  mu(MP-*-fence-2s) is
    # MP-*-fence: its GPU fence.sc IS the primitive whose absence T's null is about.
    # Weaken it and mu is no longer THE minimal mutant -- it vouches for a different
    # interleaving than the one T's ordering is claimed to prevent.
    _b6bite "mu(T)'s GPU fence.sc WEAKENED to acq_rel (no longer the minimal mutant)" \
            "$B6T.cu" '
import os
s=open(os.environ["IN"]).read()
i=s.index("if (blockIdx.x == 1 && threadIdx.x == 0) {")
j=s.index("if (blockIdx.x == 2 && threadIdx.x == 0) {")
b=s[i:j]; nb=b.replace("fence.sc.sys","fence.acq_rel.sys")
assert nb!=b
open(os.environ["OUT"],"w").write(s[:i]+nb+s[j:])' ptx || fails=$((fails+1))

    # (2) the canary's lane DELETED.  HET_CONTROL_COMPILED_IN still says 1, so every
    # null this harness prints would be gated on a control that is not running.
    _b6bite "the canary's entire GPU lane DELETED (a control that is not there)" \
            "$B6T.cu" '
import os
s=open(os.environ["IN"]).read()
i=s.index("if (blockIdx.x == 2 && threadIdx.x == 0) {")
j=s.index("if (blockIdx.x >= HET_TEST_BLOCKS) {")
assert i<j
open(os.environ["OUT"],"w").write(s[:i]+s[j:])' ptx || fails=$((fails+1))

    # (3) the mutant's CPU body silently STRENGTHENED.  A mutant that is not strictly
    # weaker than T may never fire -- and a control that never fires does not weaken
    # a null, it DISCARDS it (COLD-INVALID), forever, on a test that looks healthy.
    # (No backslashes in this program: it is passed through bash single quotes to
    # python -c, and an escaped \n here would be mangled into a bite that corrupts
    # nothing -- which passes for free.  chr(92) is the backslash the asm needs.)
    _b6bite "mu(T)'s CPU body STRENGTHENED with a dmb sy (mutant no longer weaker)" \
            "${B6T}_cpu.c" '
import os
BS = chr(92); Q = chr(34); NL = chr(10)
s = open(os.environ["IN"]).read()
i = s.index("void het_run_mu_P0"); j = s.index("void het_run_can_P0")
b = s[i:j]
anchor = "asm __volatile__(" + NL
k = b.index(anchor) + len(anchor)
ins = "    " + Q + "dmb sy" + BS + "n" + Q + NL
nb = b[:k] + ins + b[k:]
assert nb != b
open(os.environ["OUT"], "w").write(s[:i] + nb + s[j:])' cpu || fails=$((fails+1))

    rm -rf "$b6/mut"
  fi

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "SELFTEST OK"
    return 0
  fi
  echo "SELFTEST FAILED: $fails control(s) did not behave as expected"
  return 1
}

# ---- stress liveness (the OTHER L0 gate; see stresscheck.py) ----------------
# ptxcheck proves the harness carries exactly the TESTED ops.  It is blind to the
# stress layer by design -- and B4 shipped a stress layer that compiled to zero
# instructions and passed every gate.  stresscheck.py proves the scaffolding is
# there at all.  Three reps, one per GPU-lane shape, because the pre-stress lives
# in the test lanes and the mem-stress in the pure-stress blocks:
#   MP-cg-sys-acqrel-2s   1 GPU test lane, no observer
#   S-cg-sys-fence        1 GPU test lane + the observer lane (which must NOT spin)
#   IRIW-gcgc-sys-fence   2 GPU test lanes (the shape where the spin has partners)
stress_report() {
  local reps="MP-cg-sys-acqrel-2s S-cg-sys-fence IRIW-gcgc-sys-fence"
  local fails=0 rc t
  printf '\n===== STRESS LIVENESS: is the B4 layer actually in the PTX? =====\n'
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    python3 "$ROOT/hetlitmus/verify/stresscheck.py" "$HET_DIR/$t.litmus"; rc=$?
    [ "$rc" -ne 0 ] && fails=$((fails+1))
  done
  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "STRESS OK (${reps// /, })"
    return 0
  fi
  echo "STRESS FAILED: $fails rep(s) carry a dead stress layer"
  return 1
}

# ---- CPU + interconnect stress liveness (B5; see cpustresscheck.py) ---------
# stresscheck.py above covers the B4 GPU scratchpad layer.  B5 adds two more
# mechanisms that NO structural gate can see -- the M3 preload (host cache hints:
# no order, no scope, not a model op), the CPU enemies (host threads that never
# enter the PTX at all) and the C2C noise pair.  cpustresscheck.py asks the two
# questions the structural gates cannot: did they survive the OPTIMISER (read off
# the COMPILED -O2 asm, on both host ISAs), and do they actually DO anything at run
# time (a host-side probe, checked LIVE-when-on and ZERO-when-off -- a tally that
# cannot go to zero is not evidence of liveness).
#
# Two reps are enough: the CPU stress layer is per-PROC, not per-GPU-lane shape.
#   MP-cg-sys-acqrel-2s   the -2s shape -- the CPU issues the tested STLRs, so this
#                         is where injecting stress could corrupt the hypothesis
#   S-cg-sys-fence        has the observer thread (pinned, but NOT preloaded)
cpustress_report() {
  local reps="MP-cg-sys-acqrel-2s S-cg-sys-fence"
  local fails=0 rc t
  printf '\n===== CPU + INTERCONNECT STRESS LIVENESS: does the B5 layer run? =====\n'
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    python3 "$ROOT/hetlitmus/verify/cpustresscheck.py" "$HET_DIR/$t.litmus"; rc=$?
    [ "$rc" -ne 0 ] && fails=$((fails+1))
  done
  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "CPUSTRESS OK (${reps// /, })"
    return 0
  fi
  echo "CPUSTRESS FAILED: $fails rep(s) carry a dead CPU/interconnect stress layer"
  return 1
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only)  run_dir "$GPU_DIR" gpu-only 137 ;;
  het)       run_dir "$HET_DIR" het 386 ;;
  guard)     guard_report; exit $? ;;
  selftest)  selftest; exit $? ;;
  stress)    stress_report; exit $? ;;
  cpustress) cpustress_report; exit $? ;;
  all)
    rc=0
    run_dir "$GPU_DIR" gpu-only 137 || rc=1
    run_dir "$HET_DIR" het 386 || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|gpu-only|het|guard|selftest|stress|cpustress]"; exit 64 ;;
esac
