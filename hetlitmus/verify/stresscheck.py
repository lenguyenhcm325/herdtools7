#!/usr/bin/env python3
"""HetLitmus -- the GPU stress-liveness gate (hetlitmus/docs/faithfulness.md,
"GPU stress liveness at run time").  A miss means a null was
scored on a stress layer nvcc folded away or the device never ran.

  anchor        both PCT toggles off leaves exactly the render's buffer stores
  pre, mem      each lane class keeps >= 1 scratchpad load AND store, at every
                -DHET_{PRE,MEM}_STRESS_PATTERN=0..3
  gpu-noise     the noise stream survives nvcc, invariant over its block count
  device-probe  the round tally is nonzero at iters=64 and zero at iters=0

Usage: <het .litmus> [--arch sm_NN] [--no-device] [-q]; --no-device drops the
last check alone.  Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
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
PATTERNS = (0, 1, 2, 3)
NOISE_BLOCKS = (0, 4, 16)


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


def counts_of(cu_path, flags, arch, tmp):
    return count_stress_ops(ptx_of(cu_path, flags, arch, tmp))


def check_cu(cu_path, arch="sm_90", verbose=True, device=True):
    """Run the checks, then report.  The two that stop the run -- no stress layer,
    and an unsound isolation anchor -- report through this same block."""
    lines, ok = [], [True]

    def fail(msg):
        ok[0] = False
        lines.append("FAIL: " + msg)

    def note(msg):
        lines.append(msg)

    name = os.path.basename(cu_path)
    hdir = os.path.dirname(os.path.abspath(cu_path))
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
            base = counts_of(cu_path,
                             ["-DHET_PRE_STRESS_PCT=0", "-DHET_MEM_STRESS_PCT=0"],
                             arch, tmp)
            if (base.ld, base.st) != (0, n_buf):
                fail("isolation anchor is NOT clean: %s plain u32 op(s) survive with "
                     "both stress toggles compiled off, and this render writes %d "
                     "read-buffer store(s).  Either -DHET_*_PCT=0 no longer folds or "
                     "some other non-stress object is accessed as u32, and the "
                     "attribution below is unsound." % (base, n_buf))
                return
            note("  anchor OK (both toggles off -> exactly the %d read-buffer "
                 "store(s) this render writes)" % n_buf)

            # ---- pre/mem, swept over every access pattern.  Folding one class's
            # percentage to 0 deletes its calls, so what survives is the other's.
            for cls, pct_off, pat_knob in (
                    ("test lanes  (pre-stress)", "-DHET_MEM_STRESS_PCT=0",
                     "-DHET_PRE_STRESS_PATTERN="),
                    ("stress blks (mem-stress)", "-DHET_PRE_STRESS_PCT=0",
                     "-DHET_MEM_STRESS_PATTERN=")):
                per_pat = {}
                for p in PATTERNS:
                    per_pat[p] = counts_of(cu_path, [pct_off, pat_knob + str(p)],
                                           arch, tmp) - base
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
                         "compile-time pattern folds the if-chain to one branch, and "
                         "a branch that writes nothing loses its loads to hoisting, "
                         "leaving the round counting without the traffic.  Pass the "
                         "pattern as a kernel ARGUMENT."
                         % (cls, pat_knob.split('=')[0][2:],
                            ", ".join("p%d: %s" % (p, per_pat[p]) for p in PATTERNS)))
                else:
                    note("  %s live and pattern-INVARIANT over p=0..3 (%s)"
                         % (cls, per_pat[0]))

            # ---- gpu-noise: the device half of the interconnect noise pair -------
            n_on = count_noise_ops(ptx_of(cu_path, [], arch, tmp))
            if n_on < 1:
                fail("gpu-noise-live: the emitted PTX carries NO volatile 64-bit "
                     "global load -- nvcc deleted the device-side noise stream.  Its "
                     "accumulator must be kept alive (volatile reads + a sink).")
            else:
                note("  gpu-noise-live: the device-side noise survives nvcc (%d "
                     "volatile 64-bit global load(s))" % n_on)
            per_blk = {b: count_noise_ops(
                ptx_of(cu_path, ["-DHET_NOISE_GPU_BLOCKS=%d" % b], arch, tmp))
                for b in NOISE_BLOCKS}
            if len({n_on, *per_blk.values()}) != 1:
                fail("gpu-noise-runtime: the noise-op count MOVES with "
                     "-DHET_NOISE_GPU_BLOCKS (%s vs %d by default).  A compile-time "
                     "block count lets nvcc delete the noise for a config a sweep may "
                     "pick; it must be a RUNTIME kernel argument." % (per_blk, n_on))
            else:
                note("  gpu-noise-runtime: the count is INVARIANT over "
                     "-DHET_NOISE_GPU_BLOCKS=%s"
                     % "/".join(str(b) for b in NOISE_BLOCKS))

            # ---- and the runtime tally.  Everything above is structural.
            if device:
                device_probe(hdir, fail, note)
            else:
                note("  device-probe SKIPPED (--no-device): nothing here says the "
                     "stress loop RAN")
        except RuntimeError as e:
            fail(str(e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    checks()
    if verbose:
        for ln in lines:
            print(ln)
    return ok[0], lines


# ---- device-probe: het_do_stress's runtime tally, live BOTH ways ----------
# Nothing static says the loop ran, and one pattern suffices.
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

  /* pattern 0 (st;st) x {iters=64 (ON), iters=0 (OFF)} */
  for (int on = 1; on >= 0; on--) {
    cudaMemset(scratch, 0, sizeof(uint32_t) * HET_SCRATCH_SIZE);
    cudaMemset(tally,   0, sizeof(uint32_t) * HET_TALLY_N);
    probe<<<8, 1>>>(scratch, loc, tally, on ? 64u : 0u, 0u);
    cudaError_t e = cudaDeviceSynchronize();
    if (e != cudaSuccess) { printf("CUDAERR %s\n", cudaGetErrorString(e)); return 2; }
    uint32_t t_h[HET_TALLY_N];
    cudaMemcpy(t_h, tally, sizeof t_h, cudaMemcpyDeviceToHost);
    printf("on=%d rounds=%u\n", on, t_h[HET_TALLY_STRESS_ROUNDS]);
  }
  return 0;
}
"""


def device_probe(hdir, fail, note):
    """Compile + RUN het_do_stress on the device; require live-when-on and
    zero-when-off.  The probe records nothing, so it builds for this box."""
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
        cc = subprocess.run(
            [NVCC, "-std=c++17", "-arch=native", "-I", hdir, src, "-o", exe],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if cc.returncode != 0:
            fail("device-probe: the het_do_stress probe does not compile:\n%s"
                 % cc.stdout)
            return
        r = subprocess.run([exe], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=120)
        if r.returncode != 0:
            # No usable GPU is a REFUSAL, not a pass: the tally is the only evidence
            # the loop executes, and the checks above cannot see it.
            fail("device-probe: the het_do_stress probe did not RUN (rc=%d).  The "
                 "runtime tally is the only evidence the GPU stress loop executes.  "
                 "Output:\n%s" % (r.returncode, r.stdout))
            return
        rounds = {}
        for ln in r.stdout.splitlines():
            m = re.match(r"on=(\d+) rounds=(\d+)", ln)
            if m:
                rounds[int(m.group(1))] = int(m.group(2))
        if len(rounds) != 2:
            fail("device-probe: the probe reported %d of 2 configurations:\n%s"
                 % (len(rounds), r.stdout))
            return
        if rounds[1] == 0:
            fail("device-probe: het_do_stress completed ZERO rounds with "
                 "iterations=64.  The GPU stress layer is in the PTX and does not "
                 "run.")
        if rounds[0] != 0:
            fail("device-probe: the round tally is %d with iterations=0.  A counter "
                 "that cannot go to zero would report a dead stress layer as live."
                 % rounds[0])
        if rounds[1] and not rounds[0]:
            note("  device-probe: the runtime tally is live BOTH ways (iters=64 -> "
                 "rounds=%d ; iters=0 -> rounds=0)" % rounds[1])
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
    ap.add_argument("litmus", help="het .litmus test to emit and check")
    ap.add_argument("--arch", default="sm_90",
                    help="nvcc -arch for the --ptx compiles (default sm_90, "
                         "matching the run harness)")
    ap.add_argument("--no-device", dest="device", action="store_false",
                    help="run the nvcc-only checks and skip the device probe")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    tmp = None
    try:
        cu, tmp = emit_cu(args.litmus)
        ok, _ = check_cu(cu, arch=args.arch, verbose=not args.quiet,
                         device=args.device)
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
