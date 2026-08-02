#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# l0_tokens.sh -- drive ptxcheck.py over the HetLitmus corpus.
#
# L0 is the static, hardware-free faithfulness check: for every emitted GPU (and
# het CPU) harness, the kind+order+scope of every memory op must match its
# .litmus annotation exactly (hetlitmus/docs/verify-l0.md).  This script loops
# the corpus and prints a per-test PASS/FAIL table + tally; the sub-commands
# exercise the completeness guard and the negative controls that give the gate
# its teeth.  Mirrors hetlitmus/cats/run-gpu-only.sh.
#
# Usage:
#   bash hetlitmus/verify/l0_tokens.sh            # gpu-only + het table + tally
#   bash hetlitmus/verify/l0_tokens.sh gpu-only   # just the 137 gpu-only
#   bash hetlitmus/verify/l0_tokens.sh het        # just the 411 het
#   bash hetlitmus/verify/l0_tokens.sh guard      # completeness-guard report
#   bash hetlitmus/verify/l0_tokens.sh selftest   # inject weaken+strengthen
#   JOBS=8 bash hetlitmus/verify/l0_tokens.sh     # parallelism (default 4)
# ---------------------------------------------------------------------------
set -u

. "$(dirname "$0")/../paths.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # absolute; selftest [10] re-runs it
cd "$REPO"
export PATH="/usr/local/cuda/bin:$BIN:$PATH"

CHECK="$REPO/hetlitmus/verify/ptxcheck.py"
# Overridable so the census guard below can be bitten (point at an empty dir ->
# the expected 137/411 fails).  Default is the real corpus.
GPU_DIR="${GPU_DIR:-$REPO/hetlitmus/tests/gpu-only}"
HET_DIR="${HET_DIR:-$REPO/hetlitmus/tests/het}"
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
  # `pass -eq total' is VACUOUSLY true on an empty or misnamed corpus (0 -eq 0):
  # it would report OK for zero tests.  So assert the known census (het=411,
  # gpu-only=137), the same exact-count discipline corpus-gate and verdictcheck
  # use; a census change then has to be a deliberate edit to the call site.
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

  printf '\n-- distinct GPU annotations (<kind>[order,scope]) and their mapping --\n'
  # heredoc supplies python's PROGRAM via `-`, so the annotation DATA must arrive
  # by a file path in argv (piping into `python3 - <<PY` would be swallowed by
  # the heredoc); the empty-list case is itself a hard fail (no vacuous pass).
  #
  # The KIND token is matched as `[a-z_]+', not as the allow-list `[wrf]': every
  # kind ptxcheck maps is one of w/r/f, so a `[wrf]' extractor made the kind
  # lookup below constant-true AND -- the real cost -- silently dropped any
  # annotation carrying a NEW kind (an `rmw[..]'), so the one thing this section
  # exists to catch could never reach it.  Same no-allow-list discipline as the
  # CPU half below.  Widening the extractor adds no hits on today's corpus: 17
  # distinct annotations before and after.
  local annof="$RESDIR/gpu_annos.txt"
  grep -rhoE '[a-z_]+\[[a-z_]+,[a-z_]+\]' "$GPU_DIR"/*.litmus "$HET_DIR"/*.litmus \
    | sort -u > "$annof"
  python3 - "$REPO" "$annof" <<'PY'
import sys, re, importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ptxcheck", os.path.join(sys.argv[1], "hetlitmus/verify/ptxcheck.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with open(sys.argv[2]) as fh:
    annos = [l.strip() for l in fh if l.strip()]
bad = 0
for a in annos:
    k, o, s = re.match(r'([a-z_]+)\[([a-z_]+),([a-z_]+)\]', a).groups()
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
  python3 - "$REPO" "$HET_DIR" <<'PY'
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

# ---- negative/completeness self-test on COPIED artifacts (gated) ----------
# Sections [0]-[12] below: a clean control that must PASS(0), then one injection
# per way the lowering or the scaffolding can silently die, each of which must
# FAIL(1) (or hard-fail(2) for an unmodelled token).  Aggregates: returns nonzero
# if any actual rc differs from its expectation.  Operates only on copies -- the
# committed .litmus corpus is never touched.  Every injection is cmp-verified to
# have actually changed its input, since a sed that matches nothing would turn a
# whole section into a vacuous pass.
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

  # ---- [5b] the CPU barrier option -------------------------------------------
  # `DMB SY' / `DMB ST' / `DMB LD' supply three different orderings and the
  # corpus carries all three (ptxcheck.py CPU_BARRIER_OPTION).  Two separate
  # properties, so two bites:
  #   (i)  DISCRIMINATION -- an emitted `dmb sy' lowered to `dmb st' must FAIL(1)
  #        naming the mismatch.
  #   (ii) completeness -- an option that is not modelled must hard-fail(2)
  #        instead of being compared as an opaque string.  `DMB ISH' is the case
  #        that matters: a strictly narrower shareability domain that cannot be
  #        assumed to reach the GPU across C2C.
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

    # (ii) unmodelled option, consistent on BOTH sides -- the case a pure
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

  # (iii) the other direction: a partial barrier silently STRENGTHENED to the
  # full one.  MP-cg-sys-st.sc-2s is oracle-Disallowed because `DMB ST' orders
  # its CPU proc's W;W pair, so a harness quietly running `dmb sy' instead would
  # still print a null -- one no longer about the primitive the row tests.
  printf '\n[5c] Q10b: a PARTIAL CPU barrier strengthened dmb st -> dmb sy must FAIL(1)\n'
  local ST=MP-cg-sys-st.sc-2s SL2="$HET_DIR/MP-cg-sys-st.sc-2s.litmus"
  local sd="$sc/st" scpu
  mkdir -p "$sd"
  litmus7 -set-libdir litmus/libdir -o "$sd" "$SL2" >/dev/null 2>&1
  scpu="$sd/$ST/${ST}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$sd/st.ptx" "$sd/$ST/$ST.cu" >/dev/null 2>&1
  if [ ! -s "$scpu" ] || [ ! -s "$sd/st.ptx" ]; then
    echo "  *** could not emit het harness/_cpu.c for $ST"
    fails=$((fails+1))
  elif ! grep -qiE '"[[:space:]]*dmb[[:space:]]+st' "$scpu"; then
    echo "  *** $ST _cpu.c has no 'dmb st' -- the Q10b emitter arm is not firing"
    fails=$((fails+1))
  else
    echo "  confirmed: $ST _cpu.c contains 'dmb st' ($(grep -ci 'dmb st' "$scpu") block(s): T + mu)"
    python3 "$CHECK" "$SL2" --ptx "$sd/st.ptx" --cpu-c "$scpu" -q >/dev/null 2>&1; rc=$?
    _expect "dmb st control (unmodified)" 0 "$rc" || fails=$((fails+1))
    sed 's/\bdmb st\b/dmb sy/g' "$scpu" > "$sd/sy_cpu.c"
    if cmp -s "$scpu" "$sd/sy_cpu.c"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [dmb st -> dmb sy]\n'
      fails=$((fails+1))
    else
      out="$(python3 "$CHECK" "$SL2" --ptx "$sd/st.ptx" --cpu-c "$sd/sy_cpu.c" 2>&1)"; rc=$?
      echo "$out" | grep -E 'MISMATCH' | head -2
      _expect "emitted dmb st STRENGTHENED to dmb sy" 1 "$rc" || fails=$((fails+1))
    fi
  fi

  # ---- [6] the GPU stress layer's ops are modelled, and the model bites -------
  # The stress layer adds ops to the kernel, so ptxcheck carries an expectation
  # for them; an expectation that cannot fail is worse than none.  The
  # load-bearing case is the first: widening the device-scope window-opener to
  # system scope turns it into a per-iteration CROSS-DEVICE barrier, which masks
  # the order under test (ptxcheck.py check_spin).  The last case guards the
  # blind spot the stress layer could hide in -- a sys-scope op from a compiler
  # builtin sits outside the inline-asm markers, where the model-op check cannot
  # see it.
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

    # Every bite writes a FRESH artifact path.  A helper that reuses one fixed
    # path hands the checker the PREVIOUS bite's corrupt artifact whenever its
    # own injector fails to produce one, and the section then reports a pass for
    # the wrong reason instead of the vacuous-bite failure it owes.
    local b4n=0
    _b4bite() { # label sed-expr
      local lbl="$1" expr="$2" rc out
      b4n=$((b4n+1)); out="$b4/bite$b4n.ptx"
      sed "$expr" "$b4/clean.ptx" > "$out"
      if [ ! -s "$out" ]; then
        printf '  *** BITE PRODUCED NO ARTIFACT    [%s]\n' "$lbl"
        return 1
      fi
      if cmp -s "$b4/clean.ptx" "$out"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      python3 "$CHECK" "$B4L" --ptx "$out" --cpu-c "$b4cpu" -q >/dev/null 2>&1; rc=$?
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
    # check, which is exactly why check_no_stray_sys exists.  Its own path (not
    # the _b4bite series') and its exit status is read: the injector reports
    # `done' and a silent failure must surface as a vacuous bite, not inherit a
    # neighbouring bite's still-corrupt PTX.
    python3 - "$b4/clean.ptx" "$b4/stray.ptx" <<'PY'
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
    b4rc=$?
    if [ "$b4rc" -ne 0 ] || [ ! -s "$b4/stray.ptx" ] \
       || cmp -s "$b4/clean.ptx" "$b4/stray.ptx"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [stray builtin sys-scope op]\n'
      fails=$((fails+1))
    else
      python3 "$CHECK" "$B4L" --ptx "$b4/stray.ptx" --cpu-c "$b4cpu" -q >/dev/null 2>&1; b4rc=$?
      _expect "stray builtin sys-scope op (outside inline asm)" 1 "$b4rc" || fails=$((fails+1))
    fi
  fi

  # ---- [7] the stress layer is live, and the liveness gate bites -------------
  # ptxcheck is blind to the stress layer by design (scaffolding carries no
  # order/scope qualifier, so it is not a model op), which is how a pre-stress
  # incantation that nvcc had dead-code-eliminated to zero instructions once
  # passed every gate (verify-l0.md, "Scope / limits").  stresscheck.py closes
  # that: it counts scratchpad ops in the emitted PTX per lane class and asserts
  # the count is INVARIANT under -DHET_*_PATTERN -- i.e. that the pattern is a
  # runtime value, so no autotuner config can switch the stress off.  Prove it
  # bites, or it is decoration.
  printf '\n[7] B4-fix stress liveness: the gate must FAIL(1) on a dead stress layer\n'
  local SL="$REPO/hetlitmus/verify/stresscheck.py"
  local S4T=MP-cg-sys-acqrel-2s
  local S4L="$HET_DIR/$S4T.litmus" s4="$sc/s4" s4cu s4rc
  mkdir -p "$s4"
  litmus7 -set-libdir litmus/libdir -o "$s4" "$S4L" >/dev/null 2>&1
  s4cu="$s4/$S4T/$S4T.cu"
  if [ ! -s "$s4cu" ]; then
    echo "  *** could not emit the het harness for $S4T"
    fails=$((fails+1))
  else
    # control: the shipped harness must PASS -- this doubles as stresscheck's own
    # regression test, and is what reddens if the stress layer goes dead again
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
    # Both call sites: hand het_do_stress a compile-time pattern and the tuned
    # default (3 = ld;ld) is dead-code-eliminated away.
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

  # ---- [8] the CPU + interconnect stress layer's gate must bite --------------
  # cpustresscheck.py is the one checker able to catch a regression that
  # preserves the source text while killing the COMPILED mechanism -- strip
  # `volatile' and the enemy still reads beautifully and issues nothing -- so it
  # needs a negative control of its own.  Seven injections, one per way the layer
  # can silently die: five mutate het_cpu_stress.h (the mechanisms), two the
  # emitted .cu driver (invariants S5/S6 -- a noise buffer that fits in cache,
  # and enemies pointed at the locations under test).
  printf '\n[8] B5 CPU/interconnect stress: the liveness gate must FAIL(1) on a dead layer\n'
  local CS="$REPO/hetlitmus/verify/cpustresscheck.py"
  local B5T=MP-cg-sys-acqrel-2s
  local B5L="$HET_DIR/$B5T.litmus" b5="$sc/b5" b5rc
  mkdir -p "$b5"
  litmus7 -set-libdir litmus/libdir -o "$b5" "$B5L" >/dev/null 2>&1
  if [ ! -s "$b5/$B5T/het_cpu_stress.h" ] || [ ! -s "$b5/$B5T/$B5T.cu" ]; then
    echo "  *** could not emit the B5 het harness for $B5T"
    fails=$((fails+1))
  else
    # control: the shipped harness must PASS -- this doubles as cpustresscheck's
    # own regression test
    python3 "$CS" "$B5L" --harness-dir "$b5/$B5T" >/dev/null 2>&1; b5rc=$?
    _expect "B5 control (shipped CPU/interconnect layer)" 0 "$b5rc" || fails=$((fails+1))

    # The optional 4th argument is a phrase the FAIL output must contain.  Six of
    # the seven injections below break a mechanism no other assertion looks at, so
    # a nonzero exit can only have come from the one they broke; injection (5)
    # does not have that luxury -- it lands inside S3, next to the load and store
    # counts, and a bite that tripped THOSE instead would report OK for a check it
    # never exercised.  So it names the sentence it is owed.
    _b5bite() { # label  file  sed-expr  [phrase the failure must print]
      local lbl="$1" file="$2" expr="$3" want="${4:-}" rc out
      rm -rf "$b5/mut"; cp -r "$b5/$B5T" "$b5/mut"
      sed -i "$expr" "$b5/mut/$file"
      if cmp -s "$b5/$B5T/$file" "$b5/mut/$file"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      out="$(python3 "$CS" "$B5L" --harness-dir "$b5/mut" 2>&1)"; rc=$?
      # Both assertions always run: reporting only the first would hide an exit
      # code that is right for a reason that is not.
      local bad=0
      _expect "$lbl" 1 "$rc" || bad=1
      if [ -n "$want" ] && ! printf '%s\n' "$out" | grep -qF "$want"; then
        printf '  *** WRONG REASON: the failure never printed %s    [%s]\n' \
               "$want" "$lbl"
        printf '%s\n' "$out" | grep -F 'FAIL:' | head -2
        bad=1
      fi
      return "$bad"
    }

    # (1) the one a naive gate waves through.  Without `volatile' the enemy's
    # discarded reads `(void)*l' are provably useless and clang deletes all of
    # them, and sigma 0's double store collapses to one.  The loop survives, so
    # it still LOOKS like a stressor; it just issues no read traffic.
    _b5bite "enemy scratchpad volatile STRIPPED (all read traffic deleted)" \
            het_cpu_stress.h \
            's/volatile uint64_t \*scratch/uint64_t *scratch/; s/volatile uint64_t \*l =/uint64_t *l =/' \
            || fails=$((fails+1))

    # (2) sigma as a compile-time constant: the optimiser folds the switch to one
    # branch and, for ld;ld, deletes the loop -- section [7]'s bug, CPU side.
    _b5bite "sigma made COMPILE-TIME (an autotuner config can delete the stress)" \
            het_cpu_stress.h \
            's/switch (a->seq) {/switch (HET_CPU_ENEMY_SEQ) {/' \
            || fails=$((fails+1))

    # (3) the M3 preload made inert -- the incantation is still there and still
    # called, it just issues no cache hints.  Only a run can see this.
    _b5bite "preload hints DROPPED (M3 incantation inert)" \
            het_cpu_stress.h \
            's/^  uint32_t n = 0u;/  uint32_t n = 0u; return n;/' \
            || fails=$((fails+1))

    # (4) first-touch dropped: an unwritten malloc'd buffer is ONE shared zero
    # page, so the "noise" streams a single cache line out of L1 and crosses
    # nothing.
    _b5bite "noise first-touch DROPPED (8 GB buffer is one shared zero page)" \
            het_cpu_stress.h \
            's|^void het_cpu_first_touch(void \*p, size_t bytes) {|void het_cpu_first_touch(void *p, size_t bytes) { (void)p; (void)bytes; return;|' \
            || fails=$((fails+1))

    # (5) the STRAIGHT-LINE enemy: both loops removed, everything else left alone.
    # This is the shape the pre-repair "still a loop" test could not reject.  It
    # counted every branch to a `.LBB' label, forward ones included, and a body
    # with both loops gone still shows 16 of them -- the `switch (a->seq)' arms,
    # plus the ldxr/stxr RETRY loops an inlined __atomic_fetch_add lowers to, which
    # are genuine back edges that outlive the stress.  So the check now asks for a
    # back edge that ENCLOSES the traffic it is supposed to be repeating (a
    # discarded load or a scratchpad store), the way obscheck._loops decides
    # direction.  The sed is scoped to het_cpu_enemy's body and brace-balanced --
    # `while (go)' -> `if (go)', the index loop -> a plain block -- so the enemy
    # still compiles and still issues its loads and stores; it issues them once.
    _b5bite "enemy LOOPS REMOVED (traffic still there, nothing repeats it)" \
            het_cpu_stress.h \
            '/^void \*het_cpu_enemy/,/^}/{s/while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {/if (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {/; s/for (uint32_t r = 0; r < a->nidx; r++) {/{ uint32_t r = 0;/}' \
            'NO back edge around its scratchpad traffic' \
            || fails=$((fails+1))

    # (6) driver: the noise working set decoupled from HET_NOISE_MB and shrunk
    # below the LLC -- served from cache, zero interconnect traffic, every
    # counter still moving.  This is what invariant S5 is for.
    _b5bite "noise buffer UNDERSIZED (fits in cache => no C2C traffic)" \
            "$B5T.cu" \
            's|uint64_t _noise_words = (uint64_t)HET_NOISE_MB \* 1024ull \* 1024ull / sizeof(uint64_t);|uint64_t _noise_words = 4096ull;|' \
            || fails=$((fails+1))

    # (7) driver: the enemies pointed at a test variable.  Not a weaker
    # experiment but a fabricated one -- an enemy writing the location under test
    # can manufacture the weak behaviour outright.  This is what invariant S6 is
    # for.  The target is `t_x', not `x': this test co-runs three instances, so
    # every instance's locations are prefixed, and aliasing onto a name that does
    # not exist would fail to COMPILE (cpustresscheck exit 2, a toolchain error)
    # instead of tripping S6 -- a bite that fails for the wrong reason.
    _b5bite "enemy scratchpad ALIASED onto a test variable (fabricates outcomes)" \
            "$B5T.cu" \
            's/_ea\[_e\]\.scratch = _cpu_scratch;/_ea[_e].scratch = t_x;/' \
            || fails=$((fails+1))

    rm -rf "$b5/mut"
  fi

  # =========================================================================
  # [9] the co-run: does the faithfulness gate actually see the control?
  # =========================================================================
  # mu(T) and the canary run INSIDE T's harness, so a null on T is read against a
  # known-Allowed weak behaviour that fired on the same C2C path -- which makes
  # the control's lowering as load-bearing as T's:
  #   lanes missing        HET_CONTROL_COMPILED_IN still says 1, so every null it
  #                        gates silently reads as a credible null.
  #   mutant weakened      a different mutant: it no longer isolates the
  #                        primitive under test, so the vouch is misdirected.
  #   mutant strengthened  may never fire, leaving the control cold, which
  #                        discards every null on T.
  # ptxcheck models every lane of every instance; prove it bites on each.
  printf '\n[9] B6b co-run: the gate must FAIL(1) when a CONTROL instance is corrupted\n'
  local B6T=MP-cg-sys-fence-2s
  local B6L="$HET_DIR/$B6T.litmus" b6="$sc/b6" b6rc
  mkdir -p "$b6"
  litmus7 -set-libdir litmus/libdir -o "$b6" "$B6L" >/dev/null 2>&1
  if [ ! -s "$b6/$B6T/$B6T.cu" ]; then
    echo "  *** could not emit the B6b co-run harness for $B6T"
    fails=$((fails+1))
  elif ! grep -q '#define HET_CONTROL_COMPILED_IN 1' "$b6/$B6T/$B6T.cu"; then
    # Never let the section pass vacuously on a single-instance emit: a co-run
    # harness that is not co-running is the failure it exists to prevent.
    echo "  *** $B6T did not emit a CO-RUN harness (HET_CONTROL_COMPILED_IN != 1)"
    fails=$((fails+1))
  else
    nvcc -std=c++17 -arch=sm_90 --ptx -o "$b6/clean.ptx" "$b6/$B6T/$B6T.cu" 2>/dev/null
    python3 "$CHECK" "$B6L" --ptx "$b6/clean.ptx" --cpu-c "$b6/$B6T/${B6T}_cpu.c" \
      >/dev/null 2>&1; b6rc=$?
    _expect "B6b control (shipped co-run harness: T + mu(T) + canary)" 0 "$b6rc" \
      || fails=$((fails+1))

    # As in section [6]: a FRESH .ptx per bite.  Deleting the canary's lane by
    # raw string slicing can leave source nvcc rejects, and with one shared
    # mut.ptx that compile failure silently re-checked the PREVIOUS bite's
    # artifact -- still corrupt, so ptxcheck still returned 1 and the section
    # reported OK for a corruption it had never seen.
    local b6n=0
    _b6bite() { # label  file  python-corruption-of-$IN-to-$OUT  ptx|cpu
      local lbl="$1" src="$2" prog="$3" kind="$4" rc mptx
      rm -rf "$b6/mut"; cp -r "$b6/$B6T" "$b6/mut"
      IN="$b6/$B6T/$src" OUT="$b6/mut/$src" python3 -c "$prog" 2>/dev/null || {
        printf '  *** BITE SCRIPT FAILED (nothing to corrupt)    [%s]\n' "$lbl"; return 1; }
      if cmp -s "$b6/$B6T/$src" "$b6/mut/$src"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      if [ "$kind" = ptx ]; then
        b6n=$((b6n+1)); mptx="$b6/mut$b6n.ptx"
        nvcc -std=c++17 -arch=sm_90 --ptx -o "$mptx" "$b6/mut/$B6T.cu" 2>/dev/null
        if [ ! -s "$mptx" ]; then
          printf '  *** BITE COMPILE FAILED (no PTX to check)    [%s]\n' "$lbl"
          return 1
        fi
        python3 "$CHECK" "$B6L" --ptx "$mptx" \
          --cpu-c "$b6/$B6T/${B6T}_cpu.c" >/dev/null 2>&1; rc=$?
      else
        python3 "$CHECK" "$B6L" --ptx "$b6/clean.ptx" \
          --cpu-c "$b6/mut/${B6T}_cpu.c" >/dev/null 2>&1; rc=$?
      fi
      _expect "$lbl" 1 "$rc"
    }

    # (1) the mutant's ordering primitive silently weakened.  mu(MP-*-fence-2s)
    # is MP-*-fence, whose GPU fence.sc is the primitive T's null is about;
    # weaken it and mu vouches for a different interleaving than the one T's
    # ordering is claimed to prevent.
    _b6bite "mu(T)'s GPU fence.sc WEAKENED to acq_rel (no longer the minimal mutant)" \
            "$B6T.cu" '
import os
s=open(os.environ["IN"]).read()
i=s.index("if (blockIdx.x == 1 && threadIdx.x == 0) {")
j=s.index("if (blockIdx.x == 2 && threadIdx.x == 0) {")
b=s[i:j]; nb=b.replace("fence.sc.sys","fence.acq_rel.sys")
assert nb!=b
open(os.environ["OUT"],"w").write(s[:i]+nb+s[j:])' ptx || fails=$((fails+1))

    # (2) the canary's lane deleted, while HET_CONTROL_COMPILED_IN still says 1.
    _b6bite "the canary's entire GPU lane DELETED (a control that is not there)" \
            "$B6T.cu" '
import os
s=open(os.environ["IN"]).read()
i=s.index("if (blockIdx.x == 2 && threadIdx.x == 0) {")
j=s.index("if (blockIdx.x >= HET_TEST_BLOCKS) {")
assert i<j
open(os.environ["OUT"],"w").write(s[:i]+s[j:])' ptx || fails=$((fails+1))

    # (3) the mutant's CPU body silently strengthened, so it may never fire and
    # every null on T is discarded as COLD-INVALID on a test that looks healthy.
    # No backslashes in this program: it reaches python -c through bash single
    # quotes, where an escaped \n would be mangled into a bite that corrupts
    # nothing and so passes for free.  chr(92) is the backslash the asm needs.
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

  # =========================================================================
  # [10] the CORPUS-LEVEL guards: do they fail on a corpus that is not there,
  # and on an op kind nothing models?
  # =========================================================================
  # Sections [0]-[9] all bite the checker.  These two bite the SWEEP: the census
  # tripwire in run_dir (`pass -eq total' is vacuously true on 0 tests) and the
  # completeness extractor in guard_report are the whole defence against a green
  # run over a corpus that silently vanished or grew a token nothing maps.
  # GPU_DIR/HET_DIR are overridable precisely so both can be bitten; until this
  # section nothing ever did, so neither had been seen to fail.
  printf '\n[10] corpus guards: an EMPTY corpus and an UNMODELLED op kind must FAIL(1)\n'
  local g10="$sc/g10" out10 rc10
  rm -rf "$g10"; mkdir -p "$g10/empty" "$g10/gpu"
  out10="$(GPU_DIR="$g10/empty" bash "$SELF" gpu-only 2>&1)"; rc10=$?
  printf '%s\n' "$out10" | grep -E 'CENSUS FAIL' | head -1
  _expect "census guard on an EMPTY gpu-only dir (0 tests, 0 failures)" 1 "$rc10" \
    || fails=$((fails+1))

  cp "$GPU_DIR"/*.litmus "$g10/gpu/"
  # `q' is a kind ptxcheck's GPU_KIND has no entry for.  A `[wrf]'-shaped
  # extractor never handed such a token to the mapping check at all -- it
  # dropped it, which is the failure mode the widened extractor exists to close.
  printf ' q[relaxed,sys] x 1 ;\n' >> "$g10/gpu/MP-sys-F.litmus"
  if cmp -s "$GPU_DIR/MP-sys-F.litmus" "$g10/gpu/MP-sys-F.litmus"; then
    printf '  *** VACUOUS BITE: the unknown-kind injection changed nothing\n'
    fails=$((fails+1))
  else
    out10="$(GPU_DIR="$g10/gpu" bash "$SELF" guard 2>&1)"; rc10=$?
    printf '%s\n' "$out10" | grep -E 'UNMAPPED' | head -1
    _expect "completeness guard on an unmodelled kind q[relaxed,sys]" 1 "$rc10" \
      || fails=$((fails+1))
  fi
  rm -rf "$g10"

  # =========================================================================
  # [11] the ops emitted BEFORE the first rendezvous barrier
  # =========================================================================
  # split_het_segments anchors every segment on a barrier fetch_add, so anything
  # ahead of the FIRST one falls outside every segment: it reaches neither
  # barrier_ops nor model_per_segment, and the het branch feeds check_gpu the
  # segments, not the raw stream.  check_no_stray_sys cannot see it either -- that
  # one reads only the text OUTSIDE the inline-asm markers, and this op is inside
  # them.  So the hole was one-sided and had exactly one shape: an EXTRA model op
  # at the top of a het kernel, compared against nothing.
  printf '\n[11] a model op emitted BEFORE the first rendezvous barrier must FAIL(1)\n'
  local A12T=MP-cg-sys-acqrel-2s
  local A12L="$HET_DIR/$A12T.litmus" a12="$sc/a12" a12cpu
  mkdir -p "$a12"
  litmus7 -set-libdir litmus/libdir -o "$a12" "$A12L" >/dev/null 2>&1
  a12cpu="$a12/$A12T/${A12T}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$a12/clean.ptx" "$a12/$A12T/$A12T.cu" >/dev/null 2>&1
  if [ ! -s "$a12/clean.ptx" ] || [ ! -s "$a12cpu" ]; then
    echo "  *** could not emit/compile the het harness for $A12T"
    fails=$((fails+1))
  else
    python3 "$CHECK" "$A12L" --ptx "$a12/clean.ptx" --cpu-c "$a12cpu" -q >/dev/null 2>&1; rc=$?
    _expect "pre-barrier control (clean het PTX)" 0 "$rc" || fails=$((fails+1))

    # A rogue `st.relaxed.sys' in its own inline-asm block spliced ahead of the
    # first `// begin inline asm' -- i.e. in front of lane 0's fetch_add anchor.
    # A store is deliberate: it is not an atom/red at system scope, so it cannot
    # become an anchor itself and move the segmentation, it can only land outside
    # it.  Its own path and its own exit status, as in section [6].
    python3 - "$a12/clean.ptx" "$a12/pre.ptx" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, done = [], False
for l in open(src).read().splitlines():
    if not done and l.strip().startswith('// begin inline asm'):
        out += ['\t// begin inline asm',
                '\tst.relaxed.sys.b32 [%rd116],%r193;',
                '\t// end inline asm']
        done = True
    out.append(l)
open(dst, 'w').write("\n".join(out) + "\n")
sys.exit(0 if done else 1)
PY
    rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$a12/pre.ptx" ] \
       || cmp -s "$a12/clean.ptx" "$a12/pre.ptx"; then
      printf '  *** VACUOUS BITE: injection changed nothing    [pre-barrier model op]\n'
      fails=$((fails+1))
    else
      out="$(python3 "$CHECK" "$A12L" --ptx "$a12/pre.ptx" --cpu-c "$a12cpu" 2>&1)"; rc=$?
      _expect "a model op ahead of lane 0's rendezvous" 1 "$rc" || fails=$((fails+1))
      # And the REASON, aggregated separately: an injected op that broke the
      # ordered comparison instead would be a different check firing, and this
      # section would report OK for a hole still open.
      if printf '%s\n' "$out" | grep -qF 'BEFORE the first rendezvous barrier'; then
        printf '%s\n' "$out" | grep -F 'BEFORE the first rendezvous barrier' | head -1
      else
        printf '  *** WRONG REASON: not the pre-barrier failure    [pre-barrier model op]\n'
        printf '%s\n' "$out" | grep -E 'FAIL|RESULT' | head -2
        fails=$((fails+1))
      fi
    fi
  fi

  # =========================================================================
  # [12] the device tag on a het proc header is not guessable
  # =========================================================================
  # An untagged column used to default to "gpu".  On a gpu-only LISA test that is
  # right by construction -- one device -- but on a Het test it is a guess, and
  # the dangerous case is the guess that happens to be CORRECT: an untagged GPU
  # column parsed, compared and PASSED, so the tag that decides which ISA a column
  # is checked against was not being read at all.  It now hard-fails (exit 2).
  # Both arms read the message, because exit 2 alone does not separate the fix
  # from the bug: stripping the CPU tag hard-failed before it too, but as
  # `unrecognized GPU cell 'MOV W0,#1'' -- the right exit for the wrong reason.
  printf '\n[12] a het proc header with NO device tag must HARD-FAIL(2)\n'
  local DVT=MP-cg-sys-acqrel-2s
  local dt="$sc/dt" dtcpu
  rm -rf "$dt"; mkdir -p "$dt"
  litmus7 -set-libdir litmus/libdir -o "$dt" "$HET_DIR/$DVT.litmus" >/dev/null 2>&1
  dtcpu="$dt/$DVT/${DVT}_cpu.c"
  nvcc -std=c++17 -arch=sm_90 --ptx -o "$dt/clean.ptx" "$dt/$DVT/$DVT.cu" >/dev/null 2>&1
  # The corpus is copied whole, as in [5b](ii): load_control_map reads
  # control-map.csv beside the .litmus and het_instances then opens the mutant and
  # the canary beside it, so a lone file would fail on a missing co-run instance
  # rather than on the tag -- a bite that never reaches the parser it is aimed at.
  cp -r "$HET_DIR" "$dt/corpus"
  if [ ! -s "$dt/clean.ptx" ] || [ ! -s "$dtcpu" ] || [ ! -s "$dt/corpus/$DVT.litmus" ]; then
    echo "  *** could not emit/compile the het harness (or copy the corpus) for $DVT"
    fails=$((fails+1))
  else
    python3 "$CHECK" "$dt/corpus/$DVT.litmus" --ptx "$dt/clean.ptx" --cpu-c "$dtcpu" \
      -q >/dev/null 2>&1; rc=$?
    _expect "device-tag control (corpus copy, tags intact)" 0 "$rc" || fails=$((fails+1))

    _dtbite() { # label  sed-expr
      local lbl="$1" expr="$2" rc out
      cp "$HET_DIR/$DVT.litmus" "$dt/corpus/$DVT.litmus"
      sed -i "$expr" "$dt/corpus/$DVT.litmus"
      if cmp -s "$HET_DIR/$DVT.litmus" "$dt/corpus/$DVT.litmus"; then
        printf '  *** VACUOUS BITE: injection changed nothing    [%s]\n' "$lbl"
        return 1
      fi
      out="$(python3 "$CHECK" "$dt/corpus/$DVT.litmus" --ptx "$dt/clean.ptx" \
             --cpu-c "$dtcpu" 2>&1)"; rc=$?
      local bad=0
      _expect "$lbl" 2 "$rc" || bad=1
      if printf '%s\n' "$out" | grep -qF 'carries NO device tag'; then
        printf '%s\n' "$out" | grep -F 'carries NO device tag' | head -1
      else
        printf '  *** WRONG REASON: not the untagged-column hard-fail    [%s]\n' "$lbl"
        printf '%s\n' "$out" | tail -1
        bad=1
      fi
      return "$bad"
    }
    _dtbite "P1's :gpu tag STRIPPED (the old default guessed this one RIGHT)" \
            's/P1:gpu/P1    /' || fails=$((fails+1))
    _dtbite "P0's :cpu tag STRIPPED (a CPU column read as a GPU one)" \
            's/P0:cpu/P0    /' || fails=$((fails+1))

    # ...and the rule is HET-scoped, not a blanket ban: the gpu-only corpus is
    # untagged by construction and must still parse.  Asserted against the same
    # clean control section [0] built, after confirming $T really is untagged --
    # on a tagged test this arm would pass for free.
    if grep -qE '^[[:space:]]*P[0-9]+:' "$L"; then
      echo "  *** $T's proc header IS tagged -- the untagged-gpu-only arm is vacuous"
      fails=$((fails+1))
    else
      python3 "$CHECK" "$L" --ptx "$sc/clean.ptx" -q >/dev/null 2>&1; rc=$?
      _expect "an UNTAGGED gpu-only header still parses (the rule is het-scoped)" \
              0 "$rc" || fails=$((fails+1))
    fi
    rm -rf "$dt/corpus"
  fi

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "SELFTEST OK"
    return 0
  fi
  echo "SELFTEST FAILED: $fails control(s) did not behave as expected"
  return 1
}

# ---- one liveness sweep: run a checker over its reps and tally --------------
# Shared by the two reports below, which are the same loop: run CHECKER once per
# rep, count nonzero exits, and print an OK line naming the reps that ran (so a
# shrunken rep list is visible) or a failure line counting them.  Only the reps,
# the checker and the two label strings differ -- and the rep-selection rationale
# stays at each call site, where it is the thing worth reading.
#   $1 banner (printed between `===== '), $2 tag, $3 what-failed, $4 checker,
#   $5.. the reps.
_liveness_report() {
  local banner="$1" tag="$2" what="$3" checker="$4"
  shift 4
  local reps="$*"
  local fails=0 rc t
  printf '\n===== %s =====\n' "$banner"
  for t in $reps; do
    printf '\n-- %s --\n' "$t"
    python3 "$REPO/hetlitmus/verify/$checker" "$HET_DIR/$t.litmus"; rc=$?
    [ "$rc" -ne 0 ] && fails=$((fails+1))
  done
  printf '\n'
  if [ "$fails" -eq 0 ]; then
    echo "$tag OK (${reps// /, })"
    return 0
  fi
  echo "$tag FAILED: $fails rep(s) $what"
  return 1
}

# ---- stress liveness (the other L0 gate; see stresscheck.py) ----------------
# ptxcheck proves the harness carries exactly the tested ops and is blind to the
# stress layer; stresscheck.py proves the scaffolding is there at all (see
# section [7]).  Three reps, one per GPU-lane shape, because the pre-stress lives
# in the test lanes and the mem-stress in the pure-stress blocks:
#   MP-cg-sys-acqrel-2s   1 GPU test lane, no observer
#   S-cg-sys-fence        1 GPU test lane + the observer lane (which must NOT spin)
#   IRIW-gcgc-sys-fence   2 GPU test lanes (the shape where the spin has partners)
stress_report() {
  _liveness_report "STRESS LIVENESS: is the B4 layer actually in the PTX?" \
    STRESS "carry a dead stress layer" stresscheck.py \
    MP-cg-sys-acqrel-2s S-cg-sys-fence IRIW-gcgc-sys-fence
}

# ---- CPU + interconnect stress liveness (see cpustresscheck.py) -------------
# stresscheck.py above covers the GPU scratchpad layer.  The CPU side adds three
# mechanisms no structural gate can see: the M3 preload (host cache hints -- no
# order, no scope, not a model op), the CPU enemies (host threads that never
# enter the PTX at all) and the C2C noise pair.  cpustresscheck.py asks the two
# questions the structural gates cannot -- did they survive the OPTIMISER (read
# off the compiled -O2 asm, on both host ISAs), and do they do anything at run
# time (a host-side probe, checked live-when-on and zero-when-off, since a tally
# that cannot go to zero is not evidence of liveness).
#
# Two reps are enough: the CPU stress layer is per-proc, not per-GPU-lane shape.
#   MP-cg-sys-acqrel-2s   the -2s shape -- the CPU issues the tested STLRs, so this
#                         is where injecting stress could corrupt the hypothesis
#   S-cg-sys-fence        has the observer thread (pinned, but NOT preloaded)
cpustress_report() {
  _liveness_report "CPU + INTERCONNECT STRESS LIVENESS: does the B5 layer run?" \
    CPUSTRESS "carry a dead CPU/interconnect stress layer" cpustresscheck.py \
    MP-cg-sys-acqrel-2s S-cg-sys-fence
}

# ---------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  gpu-only)  run_dir "$GPU_DIR" gpu-only 137 ;;
  het)       run_dir "$HET_DIR" het 411 ;;
  guard)     guard_report; exit $? ;;
  selftest)  selftest; exit $? ;;
  stress)    stress_report; exit $? ;;
  cpustress) cpustress_report; exit $? ;;
  all)
    rc=0
    run_dir "$GPU_DIR" gpu-only 137 || rc=1
    run_dir "$HET_DIR" het 411 || rc=1
    exit $rc ;;
  *) echo "usage: $0 [all|gpu-only|het|guard|selftest|stress|cpustress]"; exit 64 ;;
esac
