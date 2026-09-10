#!/usr/bin/env python3
"""HetLitmus -- the GPU stress-liveness gate (hetlitmus/docs/faithfulness.md
"Scope and limits").  The round tally counts loop trips, not memory ops, so
this reads the PTX of `nvcc --ptx' on one het render instead:
  anchor     both PCT toggles off leaves exactly the render's read-buffer stores
  pre, mem   each class keeps >= 1 scratchpad load AND store
  gpu-noise  the noise stream survives as volatile 64-bit loads
A miss means a null was scored on a stress layer nvcc folded away.
Usage: stresscheck.py <het .litmus>.  Needs nvcc, no device.
Exit 0 = PASS, 1 = FAIL, 2 = error.
"""

import argparse
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ptxcheck as ptx

# A plain 32-bit global load or store outside the inline-asm stream is a
# scratchpad access; the noise stream is volatile and 64-bit.
ASM = re.compile(r'// begin inline asm.*?// end inline asm', re.S)
LD = re.compile(r'^\s*ld\.global\.u32\b', re.M)
ST = re.compile(r'^\s*st\.global\.u32\b', re.M)
NOISE = re.compile(r'^\s*ld\.volatile\.global\.u64\b', re.M)
# The render's own plain-u32 stores, one per (GPU proc, load): the anchor.
BUF_STORE = re.compile(r'^\s+bufP\d+_\d+\[_n\] = r\d+;', re.M)
OFF = {"pre": "-DHET_GPU_PRE_STRESS_PCT=0", "mem": "-DHET_GPU_MEM_STRESS_PCT=0"}


def ops(cu, tmp, flags):
    """(loads, stores, noise loads) of the PTX compiled under flags."""
    out = os.path.join(tmp, "v.ptx")
    ptx.compile_ptx(cu, out, flags)
    with open(out) as fh:
        text = ASM.sub("", fh.read())
    return len(LD.findall(text)), len(ST.findall(text)), len(NOISE.findall(text))


def check(litmus_path):
    """The FAIL lines for one het .litmus."""
    tmp = tempfile.mkdtemp(prefix="stresscheck_")
    try:
        cu, cpu_c = ptx.emit_harness(litmus_path, tmp)
        if cpu_c is None:
            return ["%s emitted no _cpu.c: not a het test" % litmus_path]
        with open(cu) as fh:
            n_buf = len(BUF_STORE.findall(fh.read()))
        ld, st, noise = ops(cu, tmp, [OFF["pre"], OFF["mem"]])
        print("  anchor: %d ld + %d st with both toggles off; %d read-buffer store(s)"
              % (ld, st, n_buf))
        if (ld, st) != (0, n_buf):
            return ["anchor: %d ld + %d st survive both toggles off, not 0 + %d"
                    % (ld, st, n_buf)]
        bad = []
        for cls, other in (("pre", "mem"), ("mem", "pre")):
            l, s = ops(cu, tmp, [OFF[other]])[:2]
            print("  %s-stress: %d ld + %d st" % (cls, l, s - n_buf))
            if l < 1 or s - n_buf < 1:
                bad.append("%s-stress carries %d ld + %d st, not one of each or more"
                           % (cls, l, s - n_buf))
        print("  gpu-noise: %d volatile 64-bit load(s)" % noise)
        if noise < 1:
            bad.append("gpu-noise: no volatile 64-bit global load survives nvcc")
        return bad
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("litmus", help="het .litmus test to emit and check")
    a = ap.parse_args()
    print("=== stress liveness: %s ===" % os.path.basename(a.litmus))
    try:
        bad = check(a.litmus)
    except (RuntimeError, OSError) as e:
        print("ERROR: %s" % e)
        return 2
    for m in bad:
        print("FAIL: %s" % m)
    print("RESULT:", "FAIL" if bad else "PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
