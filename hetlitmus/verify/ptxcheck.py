#!/usr/bin/env python3
"""One emitted CUDA harness carries exactly the memory ops its .litmus
annotates, read off `nvcc --ptx' with no GPU and no kernel launch
(hetlitmus/docs/faithfulness.md).  Per test:
  1. the ordered inline-asm PTX op stream == the .litmus (kind, order, scope);
     on a het test each lane's ops follow its rendezvous arrival and poll
  2. no system-scope op outside the inline-asm stream
  3. (het) the CPU column's mnemonics == the emitted _cpu.c asm block
Exit 0 PASS, 1 FAIL (per-position diff), 2 an annotation outside the tables,
3 error.  --ptx reads a frozen PTX instead of emitting and compiling.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
NVCC = shutil.which("nvcc") or "/usr/local/cuda/bin/nvcc"

# ---- the tables; a token outside them hard-fails (exit 2) ----------------
GPU_ORDER = {"relaxed": "relaxed", "acquire": "acquire", "release": "release",
             "acqrel": "acq_rel", "sc": "sc"}         # LISA tag -> PTX token
GPU_SCOPE = ("cta", "gpu", "sys")                     # spelt alike both sides
GPU_KIND = {"w": "st", "r": "ld", "f": "fence"}
# An sc access is the scope's fence.sc, then the access [CCCL cuda_ptx_generated.h].
SC_ACCESS = {"st": "relaxed", "ld": "acquire"}
# AArch64 memory and ordering mnemonics; `mov' is recognised and skipped.
CPU_MEM = ("str", "ldr", "stlr", "ldar", "ldapr", "dmb")
DMB_OPTION = ("sy", "st", "ld")     # a barrier's ordered pairs live in its option
# A het lane's rendezvous as libcu++ lowers het_rdv_device: arrival, then poll.
RDV = [("atom", "relaxed", "sys"), ("ld", "relaxed", "sys")]


class CompletenessError(Exception):
    """An annotation token that is not in the tables."""


# ---- .litmus parsing (hipsrccheck.py and covercheck.py import it) ----------

GPU_CELL = re.compile(r'^([wrf])\[([a-z_]+)\s*,\s*([a-z]+)\]')
PROC = re.compile(r'^P(\d+)(?::(\w+))?$')


def read_litmus(path):
    with open(path) as f:
        return f.read()


def litmus_kind(text):
    """'LISA' (gpu-only) or 'Het', the first header word."""
    return text.split()[0]


def litmus_name(text):
    return text.split()[1]


def parse_body(text):
    """([(proc_index, device_tag)] in column order, the grid rows); an
    untagged column is gpu on a LISA test and hard-fails on a Het one."""
    lines = text.splitlines()
    hdr = next((i for i, ln in enumerate(lines) if re.match(r'^\s*P\d+\b', ln)), None)
    if hdr is None:
        raise ValueError("no 'P0..' program header row found")
    split = lambda ln: [c.strip() for c in ln.strip().rstrip(';').split('|')]
    het = litmus_kind(text) == 'Het'
    procs = []
    for tok in split(lines[hdr]):
        m = PROC.match(tok)
        if not m:
            raise ValueError("bad proc header column: %r" % tok)
        if m.group(2) is None and het:
            raise CompletenessError("het proc header column %r carries no device tag"
                                    % tok)
        procs.append((int(m.group(1)), m.group(2) or "gpu"))
    rows = []
    for ln in lines[hdr + 1:]:
        if '|' not in ln:
            break
        rows.append(split(ln))
    return procs, rows


def device_class(dev):
    """'gpu' or 'cpu' for a column device tag."""
    if dev.lower() == 'gpu':
        return 'gpu'
    if dev.lower() in ('cpu', 'x86_64'):
        return 'cpu'
    raise CompletenessError("unrecognized device tag %r" % dev)


def gpu_ops(cells):
    """A GPU column's cells as (kind, order, scope) in PTX spelling."""
    ops = []
    for c in filter(None, (c.strip() for c in cells)):
        m = GPU_CELL.match(c)
        if not m:
            raise CompletenessError("unrecognized GPU cell %r" % c)
        op, order, scope = m.groups()
        if order not in GPU_ORDER or scope not in GPU_SCOPE:
            raise CompletenessError("unknown memory order or scope in %r" % c)
        ops.append((GPU_KIND[op], GPU_ORDER[order], scope))
    return ops


def cpu_op(mn, opts, where):
    """One AArch64 instruction as its mnemonic, `dmb <option>', or None (mov)."""
    if mn == "mov":
        return None
    if mn not in CPU_MEM:
        raise CompletenessError("unknown CPU mnemonic %r in %s" % (mn, where))
    if mn != "dmb":
        return mn
    if not opts or opts[0] not in DMB_OPTION:
        raise CompletenessError("unmodelled dmb option %r in %s" % (opts[:1], where))
    return "dmb " + opts[0]


def cpu_ops(cells):
    """A CPU column's memory and ordering ops, in order."""
    ops = []
    for c in filter(None, (c.strip() for c in cells)):
        toks = c.replace(',', ' ').lower().split()
        op = cpu_op(toks[0], toks[1:], "the .litmus CPU column")
        if op:
            ops.append(op)
    return ops


def instance_of(path):
    """One .litmus as dict(name, kind, pattern, gpu=[(proc, ops)], cpu=[...])."""
    text = read_litmus(path)
    procs, rows = parse_body(text)
    cols = [[row[c] if c < len(row) else '' for row in rows] for c in range(len(procs))]
    sides = [device_class(dev) for _, dev in procs]
    inst = dict(name=litmus_name(text), kind=litmus_kind(text),
                pattern=",".join(sides), gpu=[], cpu=[])
    for (pidx, _), side, col in zip(procs, sides, cols):
        inst[side].append((pidx, (gpu_ops if side == 'gpu' else cpu_ops)(col)))
    return inst


def ptx_profile(ops):
    """The PTX stream of a column: an sc access is its fence + access."""
    out = []
    for kind, order, scope in ops:
        if order == "sc" and kind in SC_ACCESS:
            out.append(("fence", "sc", scope))
            order = SC_ACCESS[kind]
        out.append((kind, order, scope))
    return out


# ---- emit (.litmus -> kernel source [+ _cpu.c]) and compile (-> PTX) ------

def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True)


def emit_harness(litmus_path, outdir, target="cuda"):
    """litmus7 -gpu-target <target> into outdir: (kernel source, _cpu.c or
    None).  gpu-only: <outdir>/<name>.<ext>; het: <outdir>/<name>/<name>.<ext>."""
    name = litmus_name(read_litmus(litmus_path))
    ext = {"cuda": ".cu", "hip": ".hip"}[target]
    r = run([LITMUS7, "-gpu-target", target, "-set-libdir", LIBDIR,
             "-o", outdir, litmus_path])
    het = os.path.join(outdir, name, name + ext)
    if os.path.exists(het):
        cpu_c = os.path.join(outdir, name, name + "_cpu.c")
        return het, (cpu_c if os.path.exists(cpu_c) else None)
    flat = os.path.join(outdir, name + ext)
    if os.path.exists(flat):
        return flat, None
    raise RuntimeError("litmus7 emitted no %s for %s\n%s"
                       % (ext, litmus_path, r.stdout))


def compile_ptx(cu_path, ptx_path):
    # sm_90: the arch the emitted comp.sh builds with (litmus/hetDialect.ml).
    r = run([NVCC, "-std=c++17", "-arch=sm_90", "--ptx", "-o", ptx_path, cu_path])
    if r.returncode != 0 or not os.path.exists(ptx_path):
        raise RuntimeError("nvcc --ptx failed for %s:\n%s" % (cu_path, r.stdout))


# ---- the observed streams ---------------------------------------------------

OPLINE = re.compile(r'^\s*(ld|st|atom|red|fence|membar)\.([a-z0-9_.]+)')
PTX_ORDERS, PTX_SCOPES = set(GPU_ORDER.values()), set(GPU_SCOPE)


def ptx_ops(ptx_text):
    """(the inline-asm ops as (kind, order, scope) in textual order, the
    system-scope op lines outside inline asm).  An asm line carrying no order
    token is scaffolding, not an op."""
    ops, stray, in_asm = [], [], False
    for s in map(str.strip, ptx_text.splitlines()):
        if s.startswith('// begin inline asm') or s.startswith('// end inline asm'):
            in_asm = s.startswith('// begin')
            continue
        m = OPLINE.match(s)
        if not m:
            continue
        quals = m.group(2).split('.')
        order = next((q for q in quals if q in PTX_ORDERS), None)
        scope = next((q for q in quals if q in PTX_SCOPES), None)
        if not in_asm:
            if scope == 'sys':
                stray.append(s)
        elif order is not None:
            ops.append((m.group(1), order, scope))
    return ops, stray


ASM_STR = re.compile(r'"\s*([a-zA-Z][a-zA-Z0-9.]*)([^"]*)\\n"')


def cpu_asm_ops(cpu_c_text):
    """The memory and ordering ops of the __aarch64__ asm block, in order;
    ASM_STR's leading letter skips litmus7's `#' marker literals."""
    lines = cpu_c_text.splitlines()
    start = next((i for i, ln in enumerate(lines) if '__aarch64__' in ln), 0)
    ops = []
    for ln in lines[start:]:
        if ln.strip().startswith('#else'):
            break
        # finditer: C concatenates adjacent literals, so one line may carry two.
        for m in ASM_STR.finditer(ln):
            op = cpu_op(m.group(1).lower(),
                        m.group(2).lower().replace(',', ' ').split(), "_cpu.c")
            if op:
                ops.append(op)
    return ops


# ---- the checks -------------------------------------------------------------

def diff(expected, observed, fmt):
    """One line per position where the two streams differ."""
    out = []
    for i in range(max(len(expected), len(observed))):
        e = fmt(expected[i]) if i < len(expected) else "<none>"
        o = fmt(observed[i]) if i < len(observed) else "<none>"
        if e != o:
            out.append("  [%d] expected %-22s observed %-22s   <<< MISMATCH"
                       % (i, e, o))
    return out


def check(litmus_path, ptx_override=None):
    """(name, kind, the FAIL lines) for one .litmus; no line means PASS."""
    inst = instance_of(litmus_path)
    het = inst['kind'] == 'Het'
    expected = []
    for _, ops in inst['gpu']:
        expected += (RDV if het else []) + ptx_profile(ops)
    tmp = tempfile.mkdtemp(prefix="ptxcheck_")
    try:
        cpu_c = None
        if ptx_override is None:
            cu, cpu_c = emit_harness(litmus_path, tmp)
            ptx_override = os.path.join(tmp, inst['name'] + ".ptx")
            compile_ptx(cu, ptx_override)
        ptx_text = read_litmus(ptx_override)
        cpu_text = read_litmus(cpu_c) if cpu_c else None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    observed, stray = ptx_ops(ptx_text)
    bad = []
    if observed != expected:
        bad.append("FAIL: GPU ordered model-op stream differs")
        bad += diff(expected, observed, lambda op: "%s.%s.%s" % op)
    if stray:
        bad.append("FAIL: %d system-scope op(s) emitted OUTSIDE the inline-asm "
                   "stream" % len(stray))
        bad += ["  stray: " + s for s in stray[:8]]
    if het and inst['cpu']:
        cpu_expected = [op for _, ops in inst['cpu'] for op in ops]
        if cpu_text is None:
            bad.append("FAIL: het test has CPU columns but no _cpu.c emitted")
        elif cpu_asm_ops(cpu_text) != cpu_expected:
            bad.append("FAIL: CPU memory-op stream differs (litmus column vs _cpu.c)")
            bad += diff(cpu_expected, cpu_asm_ops(cpu_text), str)
    return inst['name'], inst['kind'], bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("litmus", help=".litmus test path")
    ap.add_argument("--ptx", help="read this PTX instead of emitting and "
                                  "compiling (hetlitmus/tests/cram/ptx-negatives.t)")
    args = ap.parse_args()
    try:
        name, kind, bad = check(args.litmus, args.ptx)
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        return 2
    except Exception as e:
        print("ERROR: %s" % e)
        return 3
    print("=== %s [%s] ===" % (name, kind))
    for ln in bad:
        print(ln)
    print("RESULT:", "FAIL" if bad else "PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
