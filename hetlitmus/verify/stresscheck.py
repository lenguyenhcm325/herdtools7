#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# stresscheck.py  --  HetLitmus static stress-LIVENESS checker (sibling of ptxcheck.py)
# ---------------------------------------------------------------------------
# ptxcheck asks "does the harness carry EXACTLY the tested memory ops?", and is
# deliberately BLIND to the stress layer: stress is scaffolding, not a model op, so
# it carries no order/scope qualifier and never enters the op stream.  That leaves
# no gate able to see whether the stress layer exists at all -- and a layer nvcc has
# folded away still compiles, still passes every other gate, and turns each
# non-observation into a clean-looking "Never" worth nothing.  This checker asks the
# one question ptxcheck cannot:
#
#     does the emitted PTX still CONTAIN the stress traffic it claims to?
#
# It is a GATE, not a report: a mechanism that cannot be observed to be alive must
# be assumed dead.  Context: hetlitmus/docs/faithfulness.md; the forensics are in
# env-research/impl-briefs/B4-fix-impl-brief.md.
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
# (the bracketed name is what `--checks' calls it)
#
#   1. isolation is sound            n_none == 0                        [anchor]
#   2. test lanes carry pre-stress   n_pre  has >= 1 load AND >= 1 store   [pre]
#   3. stress blocks carry mem-str.  n_mem  has >= 1 load AND >= 1 store   [mem]
#   4. the shipped default is live   n_both >= max(n_pre, n_mem) > 0   [default]
#      ...and het_stress.h's own pattern defaults are ones (2)/(3) swept, which
#      is what makes n_pre and n_mem readable out of that sweep
#   5. THE PATTERN IS A RUNTIME VALUE: counts are INVARIANT under
#      -DHET_{PRE,MEM}_STRESS_PATTERN=0..3.                        [pre and mem]
#
# (5) is the sharp one.  A compile-time pattern makes the count swing with the -D
# and can fold the loop away entirely (per-pattern op counts measured on sm_90 are
# in B4-fix-impl-brief.md, issue 1); a runtime pattern emits all four branches, so
# the count cannot move.  Invariance IS the property "no autotuner config can
# silently switch the stress off", which is what the stress tuner needs.  Requiring
# a store as well as a load in (2)/(3) keeps the access sequence mixed: a
# pattern chain with no reachable store branch hammers a region nothing ever
# writes.
#
# Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
# ---------------------------------------------------------------------------

import argparse
import hashlib
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

# The access pattern each knob falls back to when nothing -D's it, read out of
# the het_stress.h emitted beside the harness (hetEmit copies it verbatim) and
# asserted at check 4, which is where the reuse these values license is derived.
SHIPPED_PATTERNS = {"HET_PRE_STRESS_PATTERN": 3, "HET_MEM_STRESS_PATTERN": 0}
PATTERN_DEFAULT_RE = re.compile(
    r"^#define\s+(HET_(?:PRE|MEM)_STRESS_PATTERN)\s+(\d+)", re.M)


def header_pattern_defaults(hdir):
    """{knob: value} from the het_stress.h beside the harness, or None."""
    p = os.path.join(hdir, "het_stress.h")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return {m.group(1): int(m.group(2))
                for m in PATTERN_DEFAULT_RE.finditer(f.read())}


def header_digest(hdir):
    """Short sha256 of the het_stress.h beside the harness, or `absent'.

    Printed in the banner because the device probe compiles against that header and
    nothing else of the harness: two runs reporting the same digest ran the same
    device probe, which is what lets a multi-test caller pay for it once.
    """
    p = os.path.join(hdir, "het_stress.h")
    if not os.path.exists(p):
        return "absent"
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:12]


# ---------------------------------------------------------------------------
# THE CHECK SELECTION.  Each check below is named, and `--checks' runs only the
# ones named.  A negative control that can reach exactly one of them says so, so
# the nvcc compiles the others need are not run for a mutation that cannot move
# them -- and the run is then evidence about the named check and nothing else,
# which a bare exit code never was.  `all' is every check; `structural' is every
# one but the device probe, which asks a question no compile can.
# ---------------------------------------------------------------------------
CHECKS = ("anchor", "pre", "mem", "default", "device-probe")
CHECK_GROUPS = {"all": CHECKS, "structural": ("anchor", "pre", "mem", "default")}


def select_checks(spec):
    sel = set()
    for w in spec.split(","):
        w = w.strip()
        if w in CHECK_GROUPS:
            sel.update(CHECK_GROUPS[w])
        elif w in CHECKS:
            sel.add(w)
        else:
            raise SystemExit("stresscheck: unknown check %r (have: %s)"
                             % (w, ", ".join(CHECKS + tuple(CHECK_GROUPS))))
    if not sel:
        raise SystemExit("stresscheck: --checks selected nothing to run")
    # Check 4 compares the shipped default against the two per-class sweeps, so
    # it cannot be asked for without them.
    if "default" in sel:
        sel.update(("pre", "mem"))
    return sel


class Counts:
    def __init__(self, ld=0, st=0):
        self.ld, self.st = ld, st

    @property
    def total(self):
        return self.ld + self.st

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


def check_cu(cu_path, arch="sm_90", verbose=True, sel=None):
    """Run the checks, then report.  The checks live in a nested function so that the two
    that STOP the run -- no stress layer at all, and an unsound isolation anchor -- reach
    the reporting block like every other failure: a refusal nobody can read is a bare
    exit code, and the anchor's is the one that says this checker must be re-grounded."""
    lines, ok = [], [True]
    sel = set(CHECKS) if sel is None else sel

    def fail(msg):
        ok[0] = False
        lines.append("FAIL: " + msg)

    def note(msg):
        lines.append(msg)

    name = os.path.basename(cu_path)
    hdir = os.path.dirname(os.path.abspath(cu_path))
    note("=== stress liveness: %s [%s] checks=%s het_stress.h=%s ==="
         % (name, arch, ",".join(c for c in CHECKS if c in sel),
            header_digest(hdir)))

    def checks():
        with open(cu_path) as f:
            src = f.read()
        # Never pass vacuously on a harness that has no stress layer at all.
        if "het_do_stress" not in src:
            fail("%s carries NO stress layer (no het_do_stress call): on the NVIDIA "
                 "GTX Titan the inter-CTA lb and sb tests were observed 0 per 100k "
                 "without memory stress [Alglave15 Tab. 6]" % name)
            return

        tmp = tempfile.mkdtemp(prefix="stresscheck_")
        try:
            # ---- 1. isolation anchor: with both toggles folded off, NO stress op --
            if "anchor" in sel:
                none = counts_of(cu_path, ["-DHET_PRE_STRESS_PCT=0", "-DHET_MEM_STRESS_PCT=0"],
                                 arch, tmp)
                if none.total != 0:
                    fail("isolation anchor is NOT clean: %s plain scratchpad op(s) survive "
                         "with both stress toggles compiled off.  Either -DHET_*_PCT=0 no "
                         "longer folds, or a NON-stress object is being accessed as u32 -- "
                         "in both cases the per-lane-class attribution below is unsound and "
                         "this checker must be re-grounded before it is trusted." % none)
                    return
                note("  isolation anchor OK (both toggles off -> 0 scratchpad ops: the u32 "
                     "signature is pure and -DHET_*_PCT=0 folds)")

            # ---- 2/3/5. per lane class, swept over every access pattern ------------
            sweep = {}
            for key, cls, pct_off, pat_knob in (
                    ("pre", "test lanes  (pre-stress)", "-DHET_MEM_STRESS_PCT=0",
                     "-DHET_PRE_STRESS_PATTERN="),
                    ("mem", "stress blks (mem-stress)", "-DHET_PRE_STRESS_PCT=0",
                     "-DHET_MEM_STRESS_PATTERN=")):
                if key not in sel:
                    continue
                per_pat = sweep[key] = {}
                for p in PATTERNS:
                    per_pat[p] = counts_of(cu_path, [pct_off, pat_knob + str(p)], arch, tmp)
                for p in PATTERNS:
                    c = per_pat[p]
                    if c.ld < 1 or c.st < 1:
                        fail("%s carry NO stress traffic at pattern %d (%s).  The "
                             "scratchpad must be both READ and WRITTEN: the most "
                             "effective access sequences mix loads and stores "
                             "[Sorensen16 sec 3.3]." % (cls, p, c))
                distinct = {(per_pat[p].ld, per_pat[p].st) for p in PATTERNS}
                if len(distinct) != 1:
                    fail("%s: the scratchpad-op count MOVES with -D%s* (%s).  A "
                         "compile-time pattern lets nvcc fold the if-chain to one branch "
                         "and delete the loop entirely (pattern 3 = ld;ld is "
                         "side-effect-free).  Pass the pattern as a kernel ARGUMENT."
                         % (cls, pat_knob.split('=')[0][2:],
                            ", ".join("p%d: %s" % (p, per_pat[p]) for p in PATTERNS)))
                else:
                    note("  %s live and pattern-INVARIANT over p=0..3 (%s)"
                         % (cls, per_pat[0]))

            # ---- 4. the shipped default carries both -------------------------------
            # Its two per-class parts are the sweep above, read at the pattern the
            # header would have supplied: `-DHET_PRE_STRESS_PATTERN=3' and the
            # header's own `#ifndef ... #define ... 3' hand nvcc the same macro,
            # so the compile is the same compile.  That equality holds only while
            # the shipped defaults are patterns the sweep covers, which is what
            # the assertion below is for -- the reuse is not sound without it.
            # `both' is NOT reusable: no -DHET_*_PCT=0 folds anything away in it.
            if "default" in sel:
                shipped = header_pattern_defaults(hdir)
                if shipped is None:
                    fail("no het_stress.h beside %s, so the pattern defaults check 4 "
                         "reuses the sweep at cannot be read" % name)
                elif shipped != SHIPPED_PATTERNS:
                    fail("het_stress.h ships %s, but check 4 reads its per-class parts "
                         "out of the -DHET_*_STRESS_PATTERN sweep, which covers %s and "
                         "expects the defaults to be %s.  With the header on a value "
                         "the sweep does not cover, the two would be different compiles "
                         "and check 4 would be comparing the shipped config against a "
                         "config nothing ships."
                         % (shipped, list(PATTERNS), SHIPPED_PATTERNS))
                else:
                    both = counts_of(cu_path, [], arch, tmp)
                    pre = sweep["pre"][SHIPPED_PATTERNS["HET_PRE_STRESS_PATTERN"]]
                    mem = sweep["mem"][SHIPPED_PATTERNS["HET_MEM_STRESS_PATTERN"]]
                    if both.total < max(pre.total, mem.total) or both.total == 0:
                        fail("the SHIPPED default config carries %s, less than one of its "
                             "parts (pre %s / mem %s)" % (both, pre, mem))
                    else:
                        note("  shipped default OK (%s = pre %s + mem %s), and "
                             "het_stress.h still defaults to the swept patterns %s"
                             % (both, pre, mem, SHIPPED_PATTERNS))

            # ---- 6. the RUNTIME tally.  Everything above is STRUCTURAL -------------
            if "device-probe" in sel:
                device_probe(hdir, fail, note)
        except RuntimeError as e:
            fail(str(e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    checks()
    if verbose:
        for ln in lines:
            print(ln)
    return ok[0], lines


# ===========================================================================
# het_do_stress's RUNTIME tally, live BOTH WAYS on device      [device-probe]
# ===========================================================================
# Checks 1-5 above are STRUCTURAL: they prove the scratchpad accesses are in the
# emitted PTX and cannot be folded away.  They cannot prove the loop ever RUNS,
# which is why het_verdict() would otherwise be unable to disqualify a run on
# HET_REQ_GPU_STRESS.
#
# het_stress.h counts het_do_stress rounds (HET_TALLY_STRESS_ROUNDS).  A counter
# is only evidence if it can be shown to move AND to stay at zero, so this probe
# drives het_do_stress on the real device and asserts BOTH:
#     iterations > 0  =>  tally != 0     (the mechanism is live)
#     iterations == 0 =>  tally == 0     (the counter is not stuck on)
#
# This is a PLUMBING/ABI probe on a disjoint scratchpad -- no litmus test, no
# shared memory, no memory-model claim.  It is sound on any CUDA device (the dev
# box included); nothing about the SCIENCE is being run here.

PROBE_SRC = r"""
/* GENERATED by hetlitmus/verify/stresscheck.py -- do not edit. */
#include <cstdio>
#include <cstdint>
#include <cuda/atomic>
#include "het_stress.h"

__global__ void probe(uint32_t* scratch, uint32_t* loc, uint32_t* tally,
                      uint32_t iters, uint32_t pat) {
  het_do_stress(scratch, loc, iters, pat, tally);
}

int main(void) {
  uint32_t *scratch, *loc, *tally;
  cudaMalloc(&scratch, sizeof(uint32_t) * HET_SCRATCH_SIZE);
  cudaMalloc(&loc,     sizeof(uint32_t) * 8);
  cudaMalloc(&tally,   sizeof(uint32_t) * HET_TALLY_N);
  uint32_t loc_h[8] = {0,1,2,3,4,5,6,7};
  cudaMemcpy(loc, loc_h, sizeof loc_h, cudaMemcpyHostToDevice);

  /* pat 0..3 x {iters=64 (ON), iters=0 (OFF)} */
  for (uint32_t pat = 0; pat < 4; pat++) {
    for (int on = 1; on >= 0; on--) {
      cudaMemset(scratch, 0, sizeof(uint32_t) * HET_SCRATCH_SIZE);
      cudaMemset(tally,   0, sizeof(uint32_t) * HET_TALLY_N);
      probe<<<8, 1>>>(scratch, loc, tally, on ? 64u : 0u, pat);
      cudaError_t e = cudaDeviceSynchronize();
      if (e != cudaSuccess) { printf("CUDAERR %s\n", cudaGetErrorString(e)); return 2; }
      uint32_t t_h[HET_TALLY_N];
      cudaMemcpy(t_h, tally, sizeof t_h, cudaMemcpyDeviceToHost);
      printf("pat=%u on=%d rounds=%u\n", pat, on, t_h[HET_TALLY_STRESS_ROUNDS]);
    }
  }
  return 0;
}
"""


def device_probe(hdir, fail, note):
    """Compile + RUN het_do_stress on the device; require live-when-on, zero-when-off."""
    if not os.path.exists(os.path.join(hdir, "het_stress.h")):
        fail("device-probe: het_stress.h is not next to the .cu -- cannot probe the "
             "tally")
        return
    tmp = tempfile.mkdtemp(prefix="stress_probe_")
    try:
        src = os.path.join(tmp, "probe.cu")
        with open(src, "w") as f:
            f.write(PROBE_SRC)
        exe = os.path.join(tmp, "probe")
        # sm_86 == the dev box.  The probe is arch-agnostic scaffolding; it is the
        # RUN that matters, and it must run on the machine the gate runs on.
        cc = subprocess.run(
            [NVCC, "-std=c++17", "-arch=sm_86", "-I", hdir, src, "-o", exe],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if cc.returncode != 0:
            fail("device-probe: the het_do_stress probe does not compile:\n%s"
                 % cc.stdout)
            return
        r = subprocess.run([exe], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=120)
        if r.returncode != 0:
            # No usable GPU is a REFUSAL, not a pass: the runtime tally is the only
            # evidence the stress loop executes, so a gate that silently skips it
            # is no gate at all.
            fail("device-probe: the het_do_stress probe did not RUN (rc=%d).  The "
                 "runtime tally is the ONLY evidence the GPU stress loop executes -- "
                 "structural checks 1-5 above cannot see it.  Output:\n%s"
                 % (r.returncode, r.stdout))
            return
        on_vals, off_vals = [], []
        for ln in r.stdout.splitlines():
            m = re.match(r"pat=(\d+) on=(\d+) rounds=(\d+)", ln)
            if m:
                (on_vals if m.group(2) == "1" else off_vals).append(
                    (int(m.group(1)), int(m.group(3))))
        if len(on_vals) != 4 or len(off_vals) != 4:
            fail("device-probe: the probe did not report all 8 configurations:\n%s"
                 % r.stdout)
            return
        dead = [p for p, v in on_vals if v == 0]
        if dead:
            fail("device-probe: het_do_stress completed ZERO rounds at pattern(s) %s "
                 "with iterations=64.  The GPU stress layer is in the PTX and does NOT "
                 "RUN." % dead)
        stuck = [p for p, v in off_vals if v != 0]
        if stuck:
            fail("device-probe: the round tally is NONZERO at pattern(s) %s with "
                 "iterations=0.  A counter that cannot go to zero would report a dead "
                 "stress layer as live." % stuck)
        if not dead and not stuck:
            note("  device-probe: het_do_stress's runtime tally is live BOTH ways "
                 "(iters=64 -> rounds=%s ; iters=0 -> rounds=0 for every pattern)"
                 % sorted({v for _, v in on_vals}))
    except subprocess.TimeoutExpired:
        fail("device-probe: the het_do_stress probe hung")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def emit_cu(litmus_path):
    """litmus7-emit a het test; return (cu_path, tmpdir_to_clean)."""
    tmp = tempfile.mkdtemp(prefix="stressemit_")
    r = subprocess.run([LITMUS7, "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", tmp, litmus_path],
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
    ap.add_argument("--checks", default="all",
                    help="which checks to run: a comma list of %s, or the groups "
                         "%s (default all)"
                         % (", ".join(CHECKS), ", ".join(sorted(CHECK_GROUPS))))
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    sel = select_checks(args.checks)

    if not args.cu and not args.litmus:
        ap.error("give a .litmus test or --cu <file>")
    tmp = None
    try:
        cu = args.cu
        if cu is None:
            cu, tmp = emit_cu(args.litmus)
        ok, _ = check_cu(cu, arch=args.arch, verbose=not args.quiet, sel=sel)
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
