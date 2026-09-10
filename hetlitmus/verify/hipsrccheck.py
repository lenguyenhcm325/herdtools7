#!/usr/bin/env python3
"""
hipsrccheck.py -- the HIP source gate (hetlitmus/docs/faithfulness.md).

One .litmus against the .hip litmus7 renders for it.  Every guarded GPU lane
is compared line for line with the lane the emitter writes for that column, so
each model op stands as its mapped builtin with its constants, comment and
operands, in column order, inside the one `#pragma unroll 1' loop behind the
rendezvous and the jitter, with nothing else in the lane; each x86_64 CPU
column is compared with the asm literals of its _cpu.c body.  A miss is an
emitter that renders an annotation as a different op, order, scope or operand,
or drops it.  `tokens.sh hipsrc' sweeps both corpora.

Usage:  hipsrccheck.py TEST.litmus
Exit 0 = PASS, 1 = FAIL (the first differing line), 2 = an annotation outside
the mapping tables, 3 = error.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
sys.path.insert(0, HERE)
import ptxcheck as ptx

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
CompletenessError = ptx.CompletenessError


# ===========================================================================
# 1. The mapping table -- litmus/HipLang.ml's own, as the expected side.  It is
#    also the completeness guard: a token that is not a key here hard-fails.
# ===========================================================================

# HipLang.hip_memory_order [HipAtomicHeader], [D75917].
HIP_ORDER = {
    "relaxed": "__ATOMIC_RELAXED",
    "acquire": "__ATOMIC_ACQUIRE",
    "release": "__ATOMIC_RELEASE",
    "acqrel":  "__ATOMIC_ACQ_REL",
    "sc":      "__ATOMIC_SEQ_CST",
}

# HipLang.hip_scope: the scope ladder is the HIP header's [HipAtomicHeader].
HIP_SCOPE = {
    "cta": "__HIP_MEMORY_SCOPE_WORKGROUP",
    "gpu": "__HIP_MEMORY_SCOPE_AGENT",
    "sys": "__HIP_MEMORY_SCOPE_SYSTEM",
}

# HipLang.hip_fence_scope: the AMDHSA sync-scope string __builtin_amdgcn_fence
# takes second [D75917], [AMDGPUUsage "Memory Scopes"].
HIP_FENCE_SCOPE = {
    "cta": "workgroup",
    "gpu": "agent",
    "sys": "",
}

# litmus/gpuLang.ml nregs_layout: the result slots one gpu-only proc owns in __out.
GPU_OUT_STRIDE = 4


# ===========================================================================
# 2. The expected side: the lane the emitters write for one column
# ===========================================================================

# The operand tail of a GPU cell:  w[o,s] <var> <value>   r[o,s] <dst> <var>   f[o,s]
CELL_TAIL = {
    "w": re.compile(r'^(?P<a>[A-Za-z_]\w*)\s+(?P<b>\S+)$'),
    "r": re.compile(r'^(?P<a>r\d+)\s+(?P<b>[A-Za-z_]\w*)$'),
    "f": re.compile(r'^$'),
}


def gpu_cells(cells):
    """A GPU column's cells as (kind, order, scope, opnd1, opnd2); a token or a
    tail outside the tables hard-fails."""
    out = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        m = ptx.GPU_CELL.match(c)
        if not m:
            raise CompletenessError("unrecognized GPU cell %r" % c)
        kind, order, scope = m.groups()
        if order not in HIP_ORDER:
            raise CompletenessError("unknown memory order %r in %r" % (order, c))
        if scope not in HIP_SCOPE:
            raise CompletenessError("unknown scope %r in %r" % (scope, c))
        t = CELL_TAIL[kind].match(c[m.end():].strip())
        if not t:
            raise CompletenessError(
                "GPU cell %r has an operand tail outside `w[o,s] var value', "
                "`r[o,s] rN var' and `f[o,s]'" % c)
        out.append((kind, order, scope, t.group('a'), t.group('b'))
                   if kind != 'f' else (kind, order, scope, None, None))
    return out


def regs_of(cells):
    """The lane's result registers: the load destinations, first seen first
    (litmus/gpuLang.ml result_regs)."""
    regs = []
    for kind, _o, _s, a, _b in cells:
        if kind == 'r' and a not in regs:
            regs.append(a)
    return regs


def op_lines(ind, cells, slotted):
    """The lines HipLang.dump_instr writes for a column's cells; [slotted]
    hands every access iteration _n's own slot of its location."""
    out = []
    for kind, order, scope, a, b in cells:
        o, s = HIP_ORDER[order], HIP_SCOPE[scope]
        if kind == 'f':
            out.append('%s__builtin_amdgcn_fence(%s, "%s"); // f[%s,%s]'
                       % (ind, o, HIP_FENCE_SCOPE[scope], order, scope))
            continue
        out.append("%s// %s[%s,%s] %s %s" % (ind, kind, order, scope, a, b))
        var = a if kind == 'w' else b
        ptr = "(%s + (_n)*HET_SLOT_STRIDE_WORDS)" % var if slotted else var
        if kind == 'w':
            out.append("%s__hip_atomic_store(%s, %s, %s, %s);" % (ind, ptr, b, o, s))
        else:
            out.append("%s%s = __hip_atomic_load(%s, %s, %s);" % (ind, a, ptr, o, s))
    return out


def het_lane(blk, lane, pidx, cells):
    """The het lane of litmus/hetGpuFile.ml dump_test_lane for one GPU proc."""
    regs = regs_of(cells)
    body = ["  if (blockIdx.x == %d && threadIdx.x == %d) {" % (blk, lane)]
    body += ["    int %s = 0;" % r for r in regs]
    body += [
        "    #pragma unroll 1",
        "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {",
        "      if ((int)(het_draw(_seed, _who, 2u*(uint64_t)_n) % 100u) < HET_GPU_PRE_STRESS_PCT)",
        "        het_do_stress(_scratch, _scratch_loc, HET_GPU_PRE_STRESS_ROUNDS, _pre_pat, _stress_tally);",
        "      _rdvG_P%d[_n] = het_rdv_device(barrier, (uint64_t)NPART*(uint64_t)(_n+1), _cap_gpu);" % pidx,
        "      het_rdv_jitter(het_draw(_seed, _who, 2u*(uint64_t)_n + 1u), HET_RELEASE_JITTER_SPINS);",
    ]
    body += op_lines("      ", cells, slotted=True)
    body += ["      bufP%d_%d[_n] = %s;" % (pidx, i, r) for i, r in enumerate(regs)]
    # ONE lane publishes the iteration clock the stress blocks poll.
    if (blk, lane) == (0, 0):
        body.append("      het_scratch_bump(_gpu_iter);")
    body += ["    }", "  }"]
    return body


def gpu_only_lane(blk, lane, pidx, cells):
    """The lane of litmus/gpuLang.ml dump_test for one gpu-only proc."""
    regs = regs_of(cells)
    body = ["  if (blockIdx.x == %d && threadIdx.x == %d) {" % (blk, lane)]
    body += ["    int %s = 0;" % r for r in regs]
    body += op_lines("    ", cells, slotted=False)
    body += ["    __out[%d * %d + %s] = %s;" % (pidx, GPU_OUT_STRIDE, r[1:], r)
             for r in regs]
    body.append("  }")
    return body


# The x86_64 CPU column as litmus7's ASMLang prints it: a global becomes its
# `%[g]' operand, a 32-bit register `%k[r..]', a 64-bit one `%[r..]'.
X86_REGS = "ax|bx|cx|dx|si|di|bp|sp"


def x86_cell(c):
    c = re.sub(r'\((\w+)\)', r'%[\1]', c)
    c = re.sub(r'%e(' + X86_REGS + r')\b', r'%k[r\1]', c)
    return re.sub(r'%r(' + X86_REGS + r')\b', r'%[r\1]', c)


# ===========================================================================
# 3. The observed side
# ===========================================================================

def emit_harness(litmus_path, name, outdir):
    """litmus7 -gpu-target hip; returns (hip_path, cpu_c_path_or_None)."""
    r = subprocess.run([LITMUS7, "-gpu-target", "hip", "-set-libdir", LIBDIR,
                        "-o", outdir, litmus_path],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    flat = os.path.join(outdir, name + ".hip")               # gpu-only
    nested = os.path.join(outdir, name, name + ".hip")       # het
    if os.path.exists(nested):
        cpu_c = os.path.join(outdir, name, name + "_cpu.c")
        return nested, (cpu_c if os.path.exists(cpu_c) else None)
    if os.path.exists(flat):
        return flat, None
    raise RuntimeError("litmus7 emitted no .hip for %s\n%s" % (litmus_path, r.stdout))


KERNEL_OPEN = re.compile(r'^__global__ void litmus_\w+\(')
LANE_GUARD = re.compile(r'^  if \(blockIdx\.x == (\d+) && threadIdx\.x == (\d+)\) \{$')


def lane_blocks(hip_text, path):
    """Each guarded lane of the kernel as ((blk, lane), [lines]), from its
    guard to the closing brace at the guard's indentation."""
    lines = hip_text.splitlines()
    start = next((i for i, l in enumerate(lines) if KERNEL_OPEN.match(l)), None)
    if start is None:
        raise RuntimeError("%s carries no `__global__ void litmus_...' kernel" % path)
    out, i = [], start
    while i < len(lines) and lines[i] != '}':
        m = LANE_GUARD.match(lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != '  }':
            j += 1
        if j == len(lines):
            raise RuntimeError("%s: the lane at line %d has no closing brace" % (path, i + 1))
        out.append(((int(m.group(1)), int(m.group(2))), lines[i:j + 1]))
        i = j + 1
    return out


X86_BLOCK = re.compile(r'#if defined\(__x86_64__\)(.*?)^#else', re.S | re.M)
X86_BODY = re.compile(r'^(?:__attribute__\(\(noinline\)\)\s*)?static void code(\d+)\(', re.M)
# One instruction per literal, closed by its newline escape; the `#START',
# `#_litmus_P<n>_<i>' and `#END' markers carry no op.
ASM_LIT = re.compile(r'"([^"\n]*)\\n(?:\\t)?"')


def x86_bodies(cpu_c_text, path):
    """Every body of the real x86_64 block as (proc, [instructions])."""
    m = X86_BLOCK.search(cpu_c_text)
    if not m:
        raise CompletenessError("%s carries no `#if defined(__x86_64__)' block" % path)
    blk, out = m.group(1), []
    heads = list(X86_BODY.finditer(blk))
    for k, h in enumerate(heads):
        end = heads[k + 1].start() if k + 1 < len(heads) else len(blk)
        lits = [l.strip() for l in ASM_LIT.findall(blk[h.start():end])]
        out.append((int(h.group(1)), [l for l in lits if l and not l.startswith('#')]))
    return out


# ===========================================================================
# 4. The check
# ===========================================================================

def diff_lines(who, want, got):
    """The first line on which the render departs from the expected lane."""
    for i in range(max(len(want), len(got))):
        w = want[i] if i < len(want) else "<end of lane>"
        g = got[i] if i < len(got) else "<end of lane>"
        if w != g:
            return ["%s line %d differs" % (who, i + 1),
                    "  expected: %s" % w.strip(), "  observed: %s" % g.strip()]
    return []


def check(litmus_path):
    """(name, kind, findings) for one .litmus; no finding means PASS."""
    text = ptx.read_litmus(litmus_path)
    name, kind = ptx.litmus_name(text), ptx.litmus_kind(text)
    procs, rows = ptx.parse_body(text)
    cols = [[row[c] if c < len(row) else '' for row in rows] for c in range(len(procs))]
    gpu = [(p, gpu_cells(cols[i])) for i, (p, dev) in enumerate(procs)
           if ptx.device_class(dev) == 'gpu']
    cpu = [(p, [x86_cell(c.strip()) for c in cols[i] if c.strip()])
           for i, (p, dev) in enumerate(procs) if ptx.device_class(dev) != 'gpu']
    lane_of = het_lane if kind == 'Het' else gpu_only_lane
    bad = []
    tmp = tempfile.mkdtemp(prefix="hipsrccheck_")
    try:
        hip_path, cpu_c = emit_harness(litmus_path, name, tmp)
        lanes = lane_blocks(open(hip_path).read(), hip_path)
        slots = [s for s, _ in lanes]
        if len(lanes) != len(gpu):
            bad.append("the kernel has %d guarded lane(s) for %d GPU proc(s)"
                       % (len(lanes), len(gpu)))
        elif len(set(slots)) != len(slots):
            bad.append("two procs share a launch slot: %s" % slots)
        elif kind == 'Het' and (0, 0) not in slots:
            bad.append("no lane runs at (workgroup 0, lane 0), so none bumps the "
                       "iteration clock the stress blocks poll")
        else:
            for ((blk, lane), got), (pidx, cells) in zip(lanes, gpu):
                bad += diff_lines("P%d" % pidx, lane_of(blk, lane, pidx, cells), got)
        if kind == 'Het':
            if cpu_c is None:
                bad.append("het test has CPU columns but no _cpu.c to read")
            else:
                got = x86_bodies(open(cpu_c).read(), cpu_c)
                if got != cpu:
                    bad.append("the x86_64 CPU columns and the _cpu.c bodies differ:")
                    bad.append("  expected: %s" % cpu)
                    bad.append("  observed: %s" % got)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return name, kind, bad


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus HIP source gate: .litmus annotation vs emitted HIP")
    ap.add_argument("litmus", help=".litmus test path")
    a = ap.parse_args()
    try:
        name, kind, bad = check(a.litmus)
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        sys.exit(2)
    except Exception as e:
        print("ERROR: %s" % e)
        sys.exit(3)
    print("=== %s [%s] ===" % (name, kind))
    for l in bad:
        print("FAIL: " + l if not l.startswith("  ") else l)
    print("RESULT:", "FAIL" if bad else "PASS")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
