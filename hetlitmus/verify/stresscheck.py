#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# stresscheck.py  --  HetLitmus L0 stress-LIVENESS checker  (sibling of ptxcheck.py)
# ---------------------------------------------------------------------------
# ptxcheck asks "does the harness carry EXACTLY the tested memory ops?".  It is
# deliberately BLIND to the stress layer: stress is scaffolding, not a model op,
# so it carries no order/scope qualifier and never enters the op stream.  That
# design is right -- and it left a hole big enough to drive two dead mechanisms
# through.  B4 shipped a stress layer in which the pre-stress incantation
# compiled to ZERO instructions (nvcc constant-folded the access pattern to
# `ld;ld', whose loads only feed a `break', and deleted the loop), and every gate
# in the suite stayed green, because no gate could see the stress layer at all.
#
# This checker closes that hole.  It asks the one question ptxcheck cannot:
#
#     does the emitted PTX still CONTAIN the stress traffic it claims to?
#
# It is the third instance of this project's recurring failure class (after the
# constant-true `_cond' and the constant-false `_weak'), so it is a GATE, not a
# report: a mechanism that cannot be observed to be alive must be assumed dead.
#
# ---------------------------------------------------------------------------
# HOW IT ATTRIBUTES OPS TO LANE CLASSES (without parsing PTX control flow)
#
# The op signature: a PLAIN (non-inline-asm) `ld.global.u32' / `st.global.u32'.
# In a het kernel this is the stress layer and nothing else -- every tested
# location and every read/observer buffer is uint64_t (st.global.u64) and every
# model op is inline-asm `.b32/.b64' carrying an order token; the scaffolding
# counters are atom/red, not ld/st.  The scratchpad and its location table are
# the only uint32_t objects a lane touches with plain accesses.  The `none'
# variant below PROVES this rather than asserting it (it must count 0).
#
# The attribution then uses the compiler's own dead-code elimination as the
# isolation tool, so no basic-block or predicate analysis is needed:
#
#   HET_PRE_STRESS_PCT=0  -> `if (het_rng_pct(&_rng, 0))' folds to false, so the
#                            TEST LANES' pre-stress call vanishes.
#   HET_MEM_STRESS_PCT=0  -> likewise for the STRESS BLOCKS' mem-stress call.
#
#   pre  variant (mem pct=0)  : every surviving op belongs to a TEST LANE.
#   mem  variant (pre pct=0)  : every surviving op belongs to a STRESS BLOCK.
#   none variant (both 0)     : must be 0 -- this is what makes the other two
#                               attributions sound, and it also proves the
#                               signature above is pure.
#
# ---------------------------------------------------------------------------
# WHAT IT ASSERTS
#
#   1. isolation is sound            n_none == 0
#   2. test lanes carry pre-stress   n_pre  has >= 1 load AND >= 1 store
#   3. stress blocks carry mem-str.  n_mem  has >= 1 load AND >= 1 store
#   4. the shipped default is live   n_both >= max(n_pre, n_mem) > 0
#   5. THE PATTERN IS A RUNTIME VALUE: counts are INVARIANT under
#      -DHET_{PRE,MEM}_STRESS_PATTERN=0..3.
#
# (5) is the sharp one.  A compile-time pattern makes the count swing with the
# -D (measured, sm_90, IRIW-gcgc-sys-fence: 228 / 4 / 28 / 0 ops for patterns
# 0/1/2/3 -- and 0 is the tuned default); a runtime pattern emits all four
# branches, so the count cannot move.  Invariance IS the property "no autotuner
# config can silently switch the stress off", which is what B8 needs and what the
# original port destroyed.  Requiring a store as well as a load in (2)/(3) pins
# the strong coherence stressor: a pattern chain with no reachable store branch
# hammers a region nothing ever writes.
#
# Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
# ---------------------------------------------------------------------------

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
NVCC = shutil.which("nvcc") or "/usr/local/cuda/bin/nvcc"

# A plain (non-inline-asm) 32-bit global load/store == a scratchpad access.
STRESS_OP = re.compile(r'^\s*(ld|st)\.global\.u32\b')
PATTERNS = (0, 1, 2, 3)


class Counts:
    def __init__(self, ld=0, st=0):
        self.ld, self.st = ld, st

    @property
    def total(self):
        return self.ld + self.st

    def __eq__(self, o):
        return self.ld == o.ld and self.st == o.st

    def __str__(self):
        return "%d ld + %d st = %d" % (self.ld, self.st, self.total)


def count_stress_ops(ptx_text):
    """Plain scratchpad ld/st in the kernel, EXCLUDING anything inside the PTX
    inline-asm markers (that region is the model-op stream ptxcheck owns; a
    stress op must never appear there, and by construction cannot)."""
    c = Counts()
    in_asm = False
    for line in ptx_text.splitlines():
        s = line.strip()
        if s.startswith('// begin inline asm'):
            in_asm = True
            continue
        if s.startswith('// end inline asm'):
            in_asm = False
            continue
        if in_asm:
            continue
        m = STRESS_OP.match(line)
        if m:
            if m.group(1) == 'ld':
                c.ld += 1
            else:
                c.st += 1
    return c


def ptx_of(cu_path, flags, arch, tmp):
    out = os.path.join(tmp, "v.ptx")
    cmd = [NVCC, "-std=c++17", "-arch=" + arch, "--ptx"] + flags + \
          ["-o", out, os.path.basename(cu_path)]
    r = subprocess.run(cmd, cwd=os.path.dirname(os.path.abspath(cu_path)),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError("nvcc --ptx failed (%s):\n%s" % (" ".join(flags), r.stdout))
    with open(out) as f:
        return f.read()


def counts_of(cu_path, flags, arch, tmp):
    return count_stress_ops(ptx_of(cu_path, flags, arch, tmp))


def check_cu(cu_path, arch="sm_90", verbose=True):
    lines, ok = [], [True]

    def fail(msg):
        ok[0] = False
        lines.append("FAIL: " + msg)

    def note(msg):
        lines.append(msg)

    name = os.path.basename(cu_path)
    note("=== stress liveness: %s [%s] ===" % (name, arch))

    with open(cu_path) as f:
        src = f.read()
    # Never pass vacuously on a harness that has no stress layer at all.
    if "het_do_stress" not in src:
        fail("%s carries NO stress layer (no het_do_stress call): the harness "
             "would observe nothing (Alglave 4.3.1 on Nvidia silicon)" % name)
        return ok[0], lines

    tmp = tempfile.mkdtemp(prefix="stresscheck_")
    try:
        # ---- 1. isolation anchor: with both toggles folded off, NO stress op --
        none = counts_of(cu_path, ["-DHET_PRE_STRESS_PCT=0", "-DHET_MEM_STRESS_PCT=0"],
                         arch, tmp)
        if none.total != 0:
            fail("isolation anchor is NOT clean: %s plain scratchpad op(s) survive "
                 "with both stress toggles compiled off.  Either -DHET_*_PCT=0 no "
                 "longer folds, or a NON-stress object is being accessed as u32 -- "
                 "in both cases the per-lane-class attribution below is unsound and "
                 "this checker must be re-grounded before it is trusted." % none)
            return ok[0], lines
        note("  isolation anchor OK (both toggles off -> 0 scratchpad ops: the u32 "
             "signature is pure and -DHET_*_PCT=0 folds)")

        # ---- 2/3/5. per lane class, swept over every access pattern ------------
        for cls, pct_off, pat_knob in (
                ("test lanes  (pre-stress)", "-DHET_MEM_STRESS_PCT=0",
                 "-DHET_PRE_STRESS_PATTERN="),
                ("stress blks (mem-stress)", "-DHET_PRE_STRESS_PCT=0",
                 "-DHET_MEM_STRESS_PATTERN=")):
            per_pat = {}
            for p in PATTERNS:
                per_pat[p] = counts_of(cu_path, [pct_off, pat_knob + str(p)], arch, tmp)
            for p in PATTERNS:
                c = per_pat[p]
                if c.ld < 1 or c.st < 1:
                    fail("%s carry NO stress traffic at pattern %d (%s).  The "
                         "scratchpad must be both READ and WRITTEN: store traffic "
                         "forces ownership transfer and is the strong coherence "
                         "stressor (S&D 3.3)." % (cls, p, c))
            distinct = {str(per_pat[p]) for p in PATTERNS}
            if len(distinct) != 1:
                fail("%s: the scratchpad-op count MOVES with -D%s* (%s).  The access "
                     "pattern is reaching het_do_stress as a COMPILE-TIME constant, "
                     "so nvcc folds its if-chain to one branch and can delete the "
                     "loop entirely (pattern 3 = ld;ld is side-effect-free -- that "
                     "is exactly the B4 regression).  Pass the pattern as a kernel "
                     "ARGUMENT."
                     % (cls, pat_knob.split('=')[0][2:],
                        ", ".join("p%d: %s" % (p, per_pat[p]) for p in PATTERNS)))
            else:
                note("  %s live and pattern-INVARIANT over p=0..3 (%s)"
                     % (cls, per_pat[0]))

        # ---- 4. the shipped default carries both -------------------------------
        both = counts_of(cu_path, [], arch, tmp)
        pre = counts_of(cu_path, ["-DHET_MEM_STRESS_PCT=0"], arch, tmp)
        mem = counts_of(cu_path, ["-DHET_PRE_STRESS_PCT=0"], arch, tmp)
        if both.total < max(pre.total, mem.total) or both.total == 0:
            fail("the SHIPPED default config carries %s, less than one of its parts "
                 "(pre %s / mem %s)" % (both, pre, mem))
        else:
            note("  shipped default OK (%s = pre %s + mem %s)" % (both, pre, mem))
    except RuntimeError as e:
        fail(str(e))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in lines:
            print(ln)
    return ok[0], lines


def emit_cu(litmus_path):
    """litmus7-emit a het test; return (cu_path, tmpdir_to_clean)."""
    tmp = tempfile.mkdtemp(prefix="stressemit_")
    r = subprocess.run([LITMUS7, "-set-libdir", LIBDIR, "-o", tmp, litmus_path],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    name = os.path.basename(litmus_path)[:-len(".litmus")]
    cu = os.path.join(tmp, name, name + ".cu")
    if not os.path.exists(cu):
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError("litmus7 emitted no het harness for %s (gpu-only tests "
                           "carry no stress layer -- this gate is het-only)\n%s"
                           % (litmus_path, r.stdout))
    return cu, tmp


def main():
    ap = argparse.ArgumentParser(description="HetLitmus stress-liveness checker")
    ap.add_argument("litmus", nargs="?", help="het .litmus test to emit and check")
    ap.add_argument("--cu", help="check this already-emitted .cu (used by the "
                                 "bite tests, which mutate a copy)")
    ap.add_argument("--arch", default="sm_90",
                    help="nvcc -arch (default sm_90, matching the run harness)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    if not args.cu and not args.litmus:
        ap.error("give a .litmus test or --cu <file>")
    tmp = None
    try:
        cu = args.cu
        if cu is None:
            cu, tmp = emit_cu(args.litmus)
        ok, _ = check_cu(cu, arch=args.arch, verbose=not args.quiet)
    except Exception as e:
        print("ERROR: %s" % e)
        sys.exit(2)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
