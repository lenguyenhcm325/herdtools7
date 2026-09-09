#!/usr/bin/env python3
"""HetLitmus -- the GPU stress-liveness gate (hetlitmus/docs/faithfulness.md,
"Scope and limits").  The round tally counts loop trips, not memory ops, so a
scratchpad stream nvcc folded away leaves every run reporting a live layer;
this reads the PTX instead.  A miss means a null was scored on a stress layer
nvcc folded away.

  anchor        both PCT toggles off leaves exactly the render's buffer stores
  pre, mem      each lane class keeps >= 1 scratchpad load AND store
  gpu-noise     the noise stream survives nvcc as volatile 64-bit loads

Usage: <het .litmus> [--arch sm_NN] [-q].  Needs nvcc, no device.
Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
"""

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
# The render's own plain-u32 stores, one per (GPU proc, load): they share the
# signature above, survive every toggle, and are the baseline the anchor pins.
BUF_STORE = re.compile(r'^\s+bufP\d+_\d+\[_n\] = r\d+;', re.M)
# The interconnect noise stream: 64-bit and volatile, where a scratchpad access
# is neither, and carrying no order token, so ptxcheck never sees it.
NOISE_OP = re.compile(r'^\s*ld\.volatile\.global\.u64\b')


class Counts:
    def __init__(self, ld=0, st=0):
        self.ld, self.st = ld, st

    @property
    def total(self):
        return self.ld + self.st

    def __sub__(self, other):
        return Counts(self.ld - other.ld, self.st - other.st)

    def __str__(self):
        return "%d ld + %d st = %d" % (self.ld, self.st, self.total)


def count_stress_ops(ptx_text):
    """Plain scratchpad ld/st in the kernel, EXCLUDING the PTX inline-asm regions:
    that stream is ptxcheck's, and a stress op cannot appear in it."""
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


def count_noise_ops(ptx_text):
    return sum(1 for ln in ptx_text.splitlines() if NOISE_OP.match(ln))


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


def check_cu(cu_path, arch="sm_90", verbose=True):
    """Run the checks, then report.  The two that stop the run -- no stress layer,
    and an unsound isolation anchor -- report through this same block."""
    lines, ok = [], [True]

    def fail(msg):
        ok[0] = False
        lines.append("FAIL: " + msg)

    def note(msg):
        lines.append(msg)

    name = os.path.basename(cu_path)
    note("=== stress liveness: %s [%s] ===" % (name, arch))

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
            # ---- anchor: with both toggles folded off the ONLY plain u32 ops
            # left are the buffer stores, which is what makes the rest attributable.
            n_buf = len(BUF_STORE.findall(src))
            base_ptx = ptx_of(cu_path,
                              ["-DHET_GPU_PRE_STRESS_PCT=0", "-DHET_GPU_MEM_STRESS_PCT=0"],
                              arch, tmp)
            base = count_stress_ops(base_ptx)
            if (base.ld, base.st) != (0, n_buf):
                fail("isolation anchor is NOT clean: %s plain u32 op(s) survive with "
                     "both stress toggles compiled off, and this render writes %d "
                     "read-buffer store(s).  Either -DHET_*_PCT=0 no longer folds or "
                     "some other non-stress object is accessed as u32, and the "
                     "attribution below is unsound." % (base, n_buf))
                return
            note("  anchor OK (both toggles off -> exactly the %d read-buffer "
                 "store(s) this render writes)" % n_buf)

            # ---- pre/mem: folding one class's percentage to 0 deletes its
            # calls, so what survives past the anchor is the other's.
            for cls, pct_off in (
                    ("test lanes  (pre-stress)", "-DHET_GPU_MEM_STRESS_PCT=0"),
                    ("stress blks (mem-stress)", "-DHET_GPU_PRE_STRESS_PCT=0")):
                c = count_stress_ops(ptx_of(cu_path, [pct_off], arch, tmp)) - base
                if c.ld < 1 or c.st < 1:
                    fail("%s carry NO stress traffic (%s).  The scratchpad must be "
                         "both READ and WRITTEN: the most effective access sequences "
                         "mix loads and stores [Sorensen16 sec 3.3]." % (cls, c))
                else:
                    note("  %s live (%s)" % (cls, c))

            # ---- gpu-noise: the device half of the interconnect noise pair, read
            # off the anchor's PTX, where no scratchpad traffic sits beside it.
            n_on = count_noise_ops(base_ptx)
            if n_on < 1:
                fail("gpu-noise-live: the emitted PTX carries NO volatile 64-bit "
                     "global load -- nvcc deleted the device-side noise stream.  Its "
                     "reads are volatile so the stream is issued with no value "
                     "escaping.")
            else:
                note("  gpu-noise-live: the device-side noise survives nvcc (%d "
                     "volatile 64-bit global load(s))" % n_on)
        except RuntimeError as e:
            fail(str(e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    checks()
    if verbose:
        for ln in lines:
            print(ln)
    return ok[0], lines


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
    ap.add_argument("litmus", help="het .litmus test to emit and check")
    ap.add_argument("--arch", default="sm_90",
                    help="nvcc -arch for the --ptx compiles (default sm_90, "
                         "matching the run harness)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    tmp = None
    try:
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
