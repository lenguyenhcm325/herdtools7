#!/usr/bin/env python3
"""
hipsrccheck.py -- the HIP source gate (hetlitmus/docs/amd-faithfulness.md).

Per render it pins, in .litmus column order: each model op as its mapped builtin
with its constants, its comment and its operands; a het lane's ops unguarded in
one `#pragma unroll 1' loop with the rendezvous and jitter ahead of them; the het
scaffolding and the lane count; the x86_64 CPU column against the _cpu.c asm
block; and no other memory construct inside a lane.  A miss is an emitter that
renders an annotation as a different op, order, scope or operand, or drops it.

Usage:  hipsrccheck.py TEST.litmus [--hip-src F] [--cpu-c F] [-q]
        hipsrccheck.py --all [--gpu-dir D] [--x86-dir D] [--jobs N]
Exit 0 = PASS, 1 = FAIL (ordered diff), 2 = completeness hard-fail, 3 = error.
"""

import argparse
import concurrent.futures
import contextlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
sys.path.insert(0, HERE)
import census

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
PTXCHECK = os.path.join(HERE, "ptxcheck.py")

# The corpus, pinned.  The het half is the x86_64 rendering generate-x86.sh
# writes on demand, not the AArch64 one ptxcheck.py reads.
GPU_ONLY_DIR = os.path.join(REPO, "hetlitmus", "tests", "gpu-only")
GPU_ONLY_N = census.GPU_ONLY
GEN_X86 = os.path.join(REPO, "hetlitmus", "tests", "het", "generate-x86.sh")
X86_HET_N = census.HET


def _load_ptxcheck():
    spec = importlib.util.spec_from_file_location("ptxcheck", PTXCHECK)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ptx = _load_ptxcheck()
CompletenessError = ptx.CompletenessError


class GateError(Exception):
    """Raised when the gate cannot run at all (exit 3)."""


# ===========================================================================
# 1. The mapping table -- litmus/HipLang.ml's own, as the expected side.  It is
#    also the completeness guard: a constant that is not a value here hard-fails.
# ===========================================================================

# HipLang.hip_memory_order [HipAtomicHeader], [D75917].
HIP_ORDER = {
    "relaxed": "__ATOMIC_RELAXED",
    "acquire": "__ATOMIC_ACQUIRE",
    "release": "__ATOMIC_RELEASE",
    "acq_rel": "__ATOMIC_ACQ_REL",
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

ORDER_OF_CONST = {v: k for k, v in HIP_ORDER.items()}
SCOPE_OF_CONST = {v: k for k, v in HIP_SCOPE.items()}
SCOPE_OF_FENCE_STR = {v: k for k, v in HIP_FENCE_SCOPE.items()}

# The x86_64 CPU-column vocabulary this lane's corpus is written in, litmus7's
# X86_64 lowering carrying it through unchanged.  Anything outside it hard-fails.
X86_MOV = {"mov", "movb", "movw", "movl", "movq"}
X86_FENCE = {"mfence", "sfence", "lfence"}
X86_CONSUMED = {"nop"}
# litmus7 names an x86_64 register by its 64-bit name whatever width the column
# spells, and the emitted asm operand carries that name.
X86_REG_64 = {"eax": "rax", "ebx": "rbx", "ecx": "rcx", "edx": "rdx",
              "esi": "rsi", "edi": "rdi", "ebp": "rbp", "esp": "rsp",
              "rax": "rax", "rbx": "rbx", "rcx": "rcx", "rdx": "rdx",
              "rsi": "rsi", "rdi": "rdi", "rbp": "rbp", "rsp": "rsp"}

# Device helpers a het kernel may carry (litmus/het-runtime/het_stress.h and
# het_cpu_stress.h); one outside this set hard-fails as an unmodelled primitive.
DEVICE_HELPERS = {
    "het_draw",
    "het_scratch_read", "het_scratch_bump", "het_scratch_max",
    "het_do_stress",
    "het_rdv_device", "het_rdv_jitter",
    "het_idle",
}

# Every memory-construct-shaped token, `asm' included: a source-level read
# stands for the whole memory behaviour ONLY over a path with no inline asm.
_SHAPED = (r'__hip_atomic_\w+|__builtin_\w+|__threadfence\w*|__atomic_\w+'
           r'|__sync_\w+|\batomic[A-Za-z_]\w*|\bhet_[a-z]\w*'
           r'|\basm\b|__asm__')
ATOMIC_SHAPED = re.compile(r'(%s)' % _SHAPED)
# Inside a lane every access is accounted for by an anchor, so a volatile one
# is an access no anchor carries; the modelled volatile reader is outside them.
LANE_SHAPED = re.compile(r'(%s|\bvolatile\b)' % _SHAPED)


# ===========================================================================
# 2. .litmus PARSING -- the expected side
# ===========================================================================

# The operand tail of a GPU cell, which ptxcheck's gpu_ops_of_column drops:
#   w[o,s] <var> <value>     r[o,s] <dst> <var>     f[o,s]
CELL_TAIL = {
    "w": re.compile(r'^(?P<var>[A-Za-z_]\w*)\s+(?P<val>\S+)$'),
    "r": re.compile(r'^(?P<dst>[A-Za-z_]\w*)\s+(?P<var>[A-Za-z_]\w*)$'),
    "f": re.compile(r'^$'),
}


def gpu_cells_of_column(cells):
    """Ordered (kind, order, scope, opnd1, opnd2) for a GPU column's cells.
    A tail outside the three shapes above hard-fails."""
    out = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        m = ptx.GPU_CELL.match(c)
        if not m:
            raise CompletenessError("unrecognized GPU cell %r" % c)
        kind, order, scope = m.group(1), m.group(2), m.group(3)
        if order not in HIP_ORDER:
            raise CompletenessError("unknown memory order %r in %r" % (order, c))
        if scope not in HIP_SCOPE:
            raise CompletenessError("unknown scope %r in %r" % (scope, c))
        t = CELL_TAIL[kind].match(c[m.end():].strip())
        if not t:
            raise CompletenessError(
                "GPU cell %r has an operand tail the comment check cannot bind "
                "(want `w[o,s] var value', `r[o,s] dst var' or `f[o,s]')" % c)
        g = t.groupdict()
        if kind == 'w':
            out.append((kind, order, scope, g['var'], g['val']))
        elif kind == 'r':
            out.append((kind, order, scope, g['dst'], g['var']))
        else:
            out.append((kind, order, scope, None, None))
    return out


# An x86_64 memory operand as this lane's corpus spells it: a bare global.  A
# register deref names an address this file cannot resolve, so it is refused.
X86_MEM = re.compile(r'^\(([A-Za-z_]\w*)\)$')
X86_IMM = re.compile(r'^\$-?\d+$')
X86_REG = re.compile(r'^%\w+$')


def x86_reg(name, where):
    r = X86_REG_64.get(name.lstrip('%').lower())
    if r is None:
        raise CompletenessError(
            "x86_64 register %r in %r is outside the modelled set -- the "
            "emitted asm names a register by its 64-bit name and this one has "
            "no mapping" % (name, where))
    return r


def x86_ops_of_column(cells):
    """Ordered (kind, mnemonic, global, operand) for an x86_64 CPU column's
    cells; the operand is a store's value or a load's destination register."""
    ops = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        toks = c.split(None, 1)
        mn = toks[0].lower()
        rest = toks[1].strip() if len(toks) > 1 else ''
        if mn in X86_FENCE:
            if rest:
                raise CompletenessError(
                    "x86_64 fence %r carries operands in %r" % (mn, c))
            ops.append(('fence', mn, None, None))
            continue
        if mn in X86_CONSUMED and not rest:
            continue
        if mn not in X86_MOV:
            raise CompletenessError(
                "unknown x86_64 CPU mnemonic %r in %r -- the het vocabulary is "
                "MOV load/store + MFENCE|SFENCE|LFENCE" % (mn, c))
        parts = [p.strip() for p in rest.split(',')]
        if len(parts) != 2:
            raise CompletenessError("x86_64 MOV %r is not `src,dst'" % c)
        src, dst = parts
        if X86_REG.match(dst) and X86_MEM.match(src):
            ops.append(('load', mn, X86_MEM.match(src).group(1),
                        x86_reg(dst, c)))
        elif X86_MEM.match(dst) and X86_IMM.match(src):
            ops.append(('store', mn, X86_MEM.match(dst).group(1),
                        src.lstrip('$')))
        else:
            raise CompletenessError(
                "x86_64 MOV %r has an operand shape outside the het vocabulary "
                "(a bare global `(x)' on one side, an immediate store value or "
                "a load destination register on the other)" % c)
    return ops


def instance_of(litmus_path):
    """One .litmus parsed into the profile the checker compares against; the
    CPU columns go through this file's x86_64 parser, not ptxcheck's."""
    text = ptx.read_litmus(litmus_path)
    procs, rows = ptx.parse_body(text)
    ncol = len(procs)
    cols = [[] for _ in range(ncol)]
    for row in rows:
        for c in range(ncol):
            cols[c].append(row[c] if c < len(row) else '')
    gpu, cpu, cells = [], [], []
    for col, (pidx, dev) in enumerate(procs):
        if ptx.device_class(dev) == 'gpu':
            ops = ptx.gpu_ops_of_column(cols[col])
            raw = gpu_cells_of_column(cols[col])
            # The two parsers walk the same cells; a disagreement means this
            # file's operand parser has drifted from ptxcheck's mapping table.
            if [(ptx.GPU_KIND[k], o, s) for k, o, s, _, _ in raw] != ops:
                raise GateError(
                    "operand parser disagrees with ptxcheck.gpu_ops_of_column on "
                    "proc P%d of %s" % (pidx, litmus_path))
            gpu.append((pidx, ops))
            cells.append((pidx, raw))
        else:
            cpu.append((pidx, x86_ops_of_column(cols[col])))
    return dict(name=ptx.litmus_name(text), kind=ptx.litmus_kind(text),
                gpu=gpu, cpu=cpu, cells=dict(cells))


# ===========================================================================
# 3. EMIT  (.litmus -> .hip [+ _cpu.c])
# ===========================================================================

def emit_harness(litmus_path, outdir):
    """litmus7 -gpu-target hip; returns (hip_path, cpu_c_path_or_None)."""
    name = ptx.litmus_name(ptx.read_litmus(litmus_path))
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
    raise GateError("litmus7 emitted no .hip for %s\n%s" % (litmus_path, r.stdout))


# ===========================================================================
# 4. .hip READING -- the observed side
# ===========================================================================

KERNEL_OPEN = re.compile(r'^__global__ void litmus_(\w+)\(')
# The one guard shape the emitters write (litmus/gpuLang.ml dump_test,
# litmus/hetGpuFile.ml); another one is a geometry the lane plan cannot match.
LANE_GUARD = re.compile(r'^if \(blockIdx\.x == (\d+) && threadIdx\.x == (\d+)\) \{$')
STRESS_GUARD = re.compile(r'^if \(blockIdx\.x >= HET_TEST_BLOCKS\) \{$')
PROC_BANNER = re.compile(r'^// ---- P(\d+)\s+\(workgroup (\d+), lane (\d+)\) ----$')


def kernel_lines(hip_text, path):
    """The kernel's lines, from its __global__ header to the closing brace in
    column 0.  What follows is host code and is not this gate's subject."""
    lines = hip_text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if KERNEL_OPEN.match(ln):
            start = i
            break
    if start is None:
        raise GateError("%s carries no `__global__ void litmus_...' kernel" % path)
    for j in range(start + 1, len(lines)):
        if lines[j] == '}':
            return lines[start:j + 1]
    raise GateError("%s: kernel has no closing brace in column 0" % path)


def split_lanes(klines):
    """(lanes, other): one (blk, lane, header_index, [body]) per guarded block,
    plus every other kernel line -- the stress region among them."""
    lanes, other, i, n = [], [], 0, len(klines)
    while i < n:
        s = klines[i].strip()
        m = LANE_GUARD.match(s)
        if m:
            depth, body, j = 1, [], i + 1
            while j < n and depth > 0:
                t = klines[j].strip()
                depth += t.count('{') - t.count('}')
                if depth > 0:
                    body.append(klines[j])
                j += 1
            lanes.append((int(m.group(1)), int(m.group(2)), i, body))
            i = j
            continue
        if STRESS_GUARD.match(s):
            depth, j = 1, i + 1
            while j < n and depth > 0:
                t = klines[j].strip()
                depth += t.count('{') - t.count('}')
                other.append(klines[j])
                j += 1
            i = j
            continue
        if s.startswith('if (blockIdx.x'):
            raise CompletenessError(
                "kernel guard %r is not a shape the lane plan can be matched "
                "against" % s)
        other.append(klines[i])
        i += 1
    return lanes, other


def split_args(s):
    """Split a call's argument list on commas at paren depth 0."""
    args, depth, cur = [], 0, ''
    for ch in s:
        if ch == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
            continue
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        cur += ch
    args.append(cur.strip())
    return args


def _order(const, where):
    if const not in ORDER_OF_CONST:
        raise CompletenessError("unknown memory-order constant %r in %s"
                                % (const, where))
    return ORDER_OF_CONST[const]


def _scope(const, where):
    if const not in SCOPE_OF_CONST:
        raise CompletenessError("unknown memory-scope constant %r in %s"
                                % (const, where))
    return SCOPE_OF_CONST[const]


def _args(m, n, name, where, group=1):
    """The [n] arguments of a matched call, or a completeness hard-fail: an
    extra argument the anchor does not read would otherwise pass unseen."""
    args = split_args(m.group(group))
    if len(args) != n:
        raise CompletenessError("%s takes %d arguments; %s has %d in %r"
                                % (name, n, where, len(args), m.group(0)))
    return args


C_STORE = re.compile(r'^__hip_atomic_store\((.*)\);$')
C_LOAD = re.compile(r'^(?P<dst>[^=<>!]+?)\s*=\s*__hip_atomic_load\((.*)\);$')
C_FENCE = re.compile(r'^__builtin_amdgcn_fence\((.*)\);\s*// f\[(\w+),(\w+)\]$')
# The rendezvous, as litmus/hetGpuFile.ml writes it: arrival for iteration _n,
# then the release delay.  Their bodies are verify/rdvcheck.py's subject.
C_RDV = re.compile(r'^(_rdvG_P\d+)\[_n\] = het_rdv_device\((.*)\);$')
C_JITTER = re.compile(r'^het_rdv_jitter\((.*)\);$')
C_BUMP = re.compile(r'^het_scratch_bump\((.*)\);$')
C_COMMENT = re.compile(r'^// ([wrf])\[(\w+),(\w+)\](?:\s+(.*))?$')
C_RESULT = re.compile(r'^(\w+)\[_n\] = (\w+);$')
C_OUT = re.compile(r'^__out\[(\d+) \* (\d+) \+ (\d+)\] = (\w+);$')
# The pointer a het lane hands every tested access: iteration _n's own slot of
# that location (litmus/het-runtime/het_rdv.h).
SLOT_PTR = re.compile(r'^\((\w+) \+ \(_n\)\*HET_SLOT_STRIDE_WORDS\)$')
# litmus/gpuLang.ml nregs_layout: the result slots one proc owns in __out.
GPU_OUT_STRIDE = 4
GPU_REG = re.compile(r'^r(\d+)$')

# The two lines litmus/hetGpuFile.ml opens every het lane's iteration loop with,
# in this order, and the bound it counts to.
LOOP_PRAGMA = "#pragma unroll 1"
LOOP_HEAD = re.compile(r'^for \(int _n=0; _n<(\S+); \+\+_n\) \{$')
LOOP_BOUND = "SIZE_OF_TEST"
# What one iteration owns, the rendezvous and its jitter included; the bump is
# the iteration clock the stress population polls, and only one lane carries it.
PER_ITERATION = ('st', 'ld', 'fence', 'res', 'rdv', 'jitter', 'bump')
# A statement that can guard the line under it without a brace of its own, and
# a jump that can skip the rest of an iteration.
CTRL_HEAD = re.compile(r'^(if|for|while|else)\b')
LOOP_JUMP = re.compile(r'\b(break|continue|goto|return)\b')


class Anchor:
    """One recognized construct in a lane, with the tokens it accounts for."""

    def __init__(self, sig, tokens, **kw):
        self.sig = sig
        self.tokens = set(tokens)
        self.__dict__.update(kw)


def parse_lane(body, helpers, where):
    """The ordered anchors of one guarded block, each carrying the body line it
    was read from.  An unmodelled memory construct on any line is refused."""
    anchors, pending, pos = [], None, 0

    def add(a):
        a.idx = pos
        anchors.append(a)

    def flush():
        nonlocal pending
        if pending is not None:
            add(Anchor(('orphan-comment',) + pending[:3], []))
            pending = None

    for pos, raw in enumerate(body):
        s = raw.strip()
        a = None
        m = C_COMMENT.match(s)
        if m:
            kind, order, scope, tail = m.group(1), m.group(2), m.group(3), m.group(4)
            if kind == 'f':
                # A fence's annotation trails its own call on the same line, so a
                # LEADING one is a store/load comment whose call went missing.
                flush()
                add(Anchor(('orphan-comment', 'f', order, scope), []))
                continue
            flush()
            pending = (kind, order, scope, (tail or '').split(None, 1))
            continue
        m = C_STORE.match(s)
        if m:
            args = _args(m, 4, '__hip_atomic_store', where)
            a = Anchor(('st', _order(args[2], where), _scope(args[3], where)),
                       ['__hip_atomic_store'], ptr=args[0], val=args[1],
                       comment=pending)
            pending = None
        if a is None:
            m = C_RDV.match(s)
            if m:
                args = _args(m, 3, 'het_rdv_device', where, group=2)
                flush()
                a = Anchor(('rdv',), ['het_rdv_device'], flag=m.group(1),
                           ptr=args[0], target=args[1], cap=args[2])
        if a is None:
            m = C_JITTER.match(s)
            if m:
                args = _args(m, 2, 'het_rdv_jitter', where)
                flush()
                a = Anchor(('jitter',), ['het_rdv_jitter'],
                           draw=args[0], span=args[1])
        if a is None:
            m = C_LOAD.match(s)
            if m:
                args = _args(m, 3, '__hip_atomic_load', where, group=2)
                dst = m.group('dst').strip()
                o, sc = _order(args[1], where), _scope(args[2], where)
                a = Anchor(('ld', o, sc), ['__hip_atomic_load'],
                           dst=dst, ptr=args[0], comment=pending)
                pending = None
        if a is None:
            m = C_FENCE.match(s)
            if m:
                args = _args(m, 2, '__builtin_amdgcn_fence', where)
                if not (args[1].startswith('"') and args[1].endswith('"')):
                    raise CompletenessError(
                        "__builtin_amdgcn_fence's sync scope is not a string "
                        "literal in %r (%s)" % (s, where))
                sstr = args[1][1:-1]
                if sstr not in SCOPE_OF_FENCE_STR:
                    raise CompletenessError(
                        "unknown AMDHSA sync-scope string %r in %s" % (sstr, where))
                order = _order(args[0], where)
                if order == 'relaxed':
                    raise CompletenessError(
                        "%s emits __builtin_amdgcn_fence with a relaxed order, "
                        "which HipLang.dump_instr never writes and hipcc "
                        "rejects: %r" % (where, s))
                flush()
                a = Anchor(('fence', order, SCOPE_OF_FENCE_STR[sstr]),
                           ['__builtin_amdgcn_fence'],
                           c_order=m.group(2), c_scope=m.group(3))
        if a is None:
            m = C_BUMP.match(s)
            if m:
                flush()
                a = Anchor(('bump',), ['het_scratch_bump'], arg=m.group(1))
        if a is None:
            m = C_RESULT.match(s)
            if m:
                flush()
                a = Anchor(('res', m.group(1), m.group(2)), [])
        if a is None:
            m = C_OUT.match(s)
            if m:
                flush()
                a = Anchor(('out', int(m.group(1)), int(m.group(2)),
                            int(m.group(3)), m.group(4)), [])
        if a is not None:
            allowed = helpers | a.tokens
            stray = [t for t in LANE_SHAPED.findall(s) if t not in allowed]
            if stray:
                raise CompletenessError(
                    "%s carries %s outside the construct it renders: %r"
                    % (where, ", ".join(sorted(set(stray))), s))
            add(a)
            continue
        flush()
        stray = [t for t in LANE_SHAPED.findall(s) if t not in helpers]
        if stray:
            raise CompletenessError(
                "%s carries a memory construct the gate has no model for (%s): "
                "%r" % (where, ", ".join(sorted(set(stray))), s))
    flush()
    return anchors


# ===========================================================================
# 5. _cpu.c READING  (the real x86_64 asm block only)
# ===========================================================================

X86_BLOCK = re.compile(r'#if defined\(__x86_64__\)(.*?)(?:^#else|^#endif)',
                       re.S | re.M)
# litmus7's own body, printed by ASMLang.dump_fun: `static void code<n>(...)'.
# The het_run_P<n> wrapper that calls it stands outside this block.
X86_BODY = re.compile(r'^\s*(?:__attribute__\(\(noinline\)\)\s*)?static void '
                      r'code(\d+)\(', re.M)
X86_ASM = re.compile(r'asm __volatile__ ?\((.*?)\n\s*:', re.S)
ASM_STR = re.compile(r'"([^"\n]*)"')
# ASMLang interleaves its instructions with `#START' / `#_litmus_P<n>_<i>' /
# `#END' marker literals, which carry no memory op.
A_MARKER = re.compile(r'^#(START |END |_litmus_)')
# The operand shapes litmus7's X86_64 lowering writes: an immediate into the
# location's `=m' operand, and that operand into a register's, `%k' its 32 bits.
A_STORE = re.compile(r'^(\w+)\s+\$(-?\d+),%\[(\w+)\]$')
A_LOAD = re.compile(r'^(\w+)\s+%\[(\w+)\],%k?\[(\w+)\]$')


def asm_instrs(template, path, who):
    """The instructions of one asm template, in order.  EVERY literal is read
    and each must be one instruction closed by the newline escape."""
    lits = ASM_STR.findall(template)
    if template.count('"') != 2 * len(lits):
        raise CompletenessError(
            "%s: body %s has an unpaired quote in its asm template" % (path, who))
    out = []
    for lit in lits:
        ins = lit
        if ins.endswith('\\t'):
            ins = ins[:-2]
        if not ins.endswith('\\n'):
            raise CompletenessError(
                "%s: body %s carries the asm literal %r, which no newline escape "
                "closes -- it concatenates with its neighbour" % (path, who, lit))
        ins = ins[:-2]
        if '\\n' in ins:
            raise CompletenessError(
                "%s: body %s carries %d instructions in one asm literal (%r)"
                % (path, who, ins.count('\\n') + 1, lit))
        out.append(ins.strip())
    return out


def x86_bodies(cpu_c_text, path):
    """Every compiled body in the real x86_64 block, as (proc, [ops]): the
    block holds one per CPU proc and each of them is a tested path."""
    out = []
    blocks = X86_BLOCK.findall(cpu_c_text)
    if not blocks:
        raise CompletenessError(
            "%s carries no `#if defined(__x86_64__)' block, so it holds no "
            "compiled x86 body to read" % path)
    for blk in blocks:
        heads = list(X86_BODY.finditer(blk))
        for k, h in enumerate(heads):
            end = heads[k + 1].start() if k + 1 < len(heads) else len(blk)
            body = blk[h.start():end]
            asms = X86_ASM.findall(body)
            if not asms:
                raise CompletenessError(
                    "%s: body code%s carries no asm __volatile__ block"
                    % (path, h.group(1)))
            ops = []
            who = "code%s" % h.group(1)
            for ins in [i for a in asms for i in asm_instrs(a, path, who)]:
                if ins == '' or A_MARKER.match(ins):
                    continue
                mn = ins.split()[0].lower() if ins else ''
                if mn in X86_FENCE:
                    if ins.lower() != mn:
                        raise CompletenessError(
                            "%s: fence %r carries operands" % (path, ins))
                    ops.append(('fence', mn, None, None))
                    continue
                m = A_STORE.match(ins)
                if m:
                    ops.append(('store', m.group(1).lower(), m.group(3),
                                m.group(2)))
                    continue
                m = A_LOAD.match(ins)
                if m:
                    ops.append(('load', m.group(1).lower(), m.group(2),
                                x86_reg(m.group(3), ins)))
                    continue
                raise CompletenessError(
                    "%s: asm %r is outside the emitted vocabulary (an immediate "
                    "MOV store, a MOV load into a register, "
                    "MFENCE|SFENCE|LFENCE)" % (path, ins))
            out.append((int(h.group(1)), ops))
    return out


# ===========================================================================
# 6. CHECK
# ===========================================================================

def fmt(sig):
    k = sig[0]
    if k in ('st', 'ld', 'fence'):
        return "%s[%s,%s]" % ({'st': 'w', 'ld': 'r', 'fence': 'f'}[k], sig[1], sig[2])
    if k == 'rdv':
        return "rendezvous(_n)"
    if k == 'jitter':
        return "release jitter"
    if k == 'res':
        return "result_store %s=%s" % (sig[1], sig[2])
    if k == 'out':
        return "__out[%d * %d + %d]=%s" % (sig[1], sig[2], sig[3], sig[4])
    if k == 'orphan-comment':
        return "comment %s[%s,%s] with no call" % (sig[1], sig[2], sig[3])
    return {'bump': 'het_scratch_bump'}[k]


def diff_sequences(expected, actual):
    out = []
    for i in range(max(len(expected), len(actual))):
        e = fmt(expected[i]) if i < len(expected) else "<none>"
        a = fmt(actual[i]) if i < len(actual) else "<none>"
        if e != a:
            out.append("  [%d] expected %-28s observed %-28s   <<< MISMATCH"
                       % (i, e, a))
    return out


class Result:
    def __init__(self):
        self.ok = True
        self.lines = []

    def fail(self, msg):
        self.ok = False
        self.lines.append("FAIL: " + msg)

    def note(self, msg):
        self.lines.append(msg)


def check_stream(result, expected, anchors, who):
    """Ordered compare of one lane; the multiset below is a post-failure
    localizer ONLY."""
    got = [a.sig for a in anchors]
    if got == expected:
        result.note("  %s stream OK (%d anchors)" % (who, len(expected)))
        return True
    result.fail("%s anchor stream differs" % who)
    for d in diff_sequences(expected, got):
        result.note(d)
    ce, ca = Counter(expected), Counter(got)
    if ce != ca:
        result.note("  localized: %s multiset expected %s observed %s"
                    % (who, sorted(ce - ca), sorted(ca - ce)))
    else:
        result.note("  localized: %s carries the right anchors in the wrong ORDER"
                    % who)
    return False


def guard_chains(body):
    """Per line of a lane, the statements guarding it: the brace openers it
    sits inside, innermost last, plus a braceless control head above it."""
    chains, stack, dangling = [], [], ()
    for i, ln in enumerate(body):
        t = ln.strip()
        if not t:
            chains.append(tuple(stack) + dangling)
            continue
        n_open, n_close = t.count('{'), t.count('}')
        if t.startswith('}'):
            for _ in range(min(n_close, len(stack))):
                stack.pop()
            n_close, dangling = 0, ()
        chains.append(tuple(stack) + dangling)
        dangling = (i,) if (CTRL_HEAD.match(t) and not n_open and not n_close
                            and not t.endswith(';')) else ()
        for _ in range(n_open):
            stack.append(i)
        for _ in range(n_close):
            if stack:
                stack.pop()
    return chains


def check_lane_loop(result, body, anchors, who):
    """Every het lane's ops sit unguarded in the body of one loop over
    SIZE_OF_TEST, unrolled by one, with no jump able to skip them."""
    chains = guard_chains(body)
    heads = [i for i, ln in enumerate(body) if LOOP_HEAD.match(ln.strip())]
    if len(heads) != 1:
        result.fail("%s carries %d per-iteration loop(s), not one -- the lane's "
                    "ops are not run once per iteration of anything the gate can "
                    "find" % (who, len(heads)))
        return
    h = heads[0]
    bad = False
    bound = LOOP_HEAD.match(body[h].strip()).group(1)
    if bound != LOOP_BOUND:
        bad = True
        result.fail("%s: the iteration loop counts to %s, not to %s -- its trip "
                    "count is no longer the harness's" % (who, bound, LOOP_BOUND))
    before = [ln.strip() for ln in body[:h] if ln.strip()]
    if not before or before[-1] != LOOP_PRAGMA:
        bad = True
        result.fail("%s: the iteration loop is not opened by `%s', so a "
                    "compile-time trip count may unroll the tested ops into many "
                    "textual copies" % (who, LOOP_PRAGMA))
    if chains[h]:
        bad = True
        result.fail("%s: the iteration loop is itself guarded by `%s', so the "
                    "lane iterates only when that guard holds"
                    % (who, body[chains[h][-1]].strip()))
    depth, close = 1, None
    for j in range(h + 1, len(body)):
        t = body[j].strip()
        depth += t.count('{') - t.count('}')
        if depth <= 0:
            close = j
            break
    for j in range(h + 1, close):
        t = body[j].strip()
        if LOOP_JUMP.search(t):
            bad = True
            result.fail("%s: `%s' inside the iteration loop can skip the rest of "
                        "an iteration, so what follows it is not per-iteration"
                        % (who, t))
    for a in anchors:
        chain = chains[a.idx]
        inside = bool(chain) and chain[0] == h
        if a.sig[0] in PER_ITERATION:
            if not inside:
                bad = True
                result.fail("%s: %s sits OUTSIDE the per-iteration loop -- it "
                            "runs once per launch, not once per iteration"
                            % (who, fmt(a.sig)))
            elif chain != (h,):
                bad = True
                result.fail("%s: %s is guarded by `%s' inside the loop, so it "
                            "does not run on every iteration"
                            % (who, fmt(a.sig), body[chain[-1]].strip()))
    if not bad:
        result.note("  %s loop structure OK (%s over %s, %d anchor(s) inside)"
                    % (who, LOOP_PRAGMA, LOOP_BOUND,
                       sum(1 for a in anchors
                           if chains[a.idx] and chains[a.idx][0] == h)))


def out_anchors(cells, pidx):
    """The result stores a gpu-only proc ends on: one per read register, into
    the slot litmus/gpuLang.ml dump_test reserves for it."""
    out, seen = [], []
    for kind, _o, _s, dst, _v in cells:
        if kind != 'r' or dst in seen:
            continue
        seen.append(dst)
        m = GPU_REG.match(dst)
        if not m:
            raise CompletenessError(
                "gpu-only P%d loads into %r, which names no __out slot -- that "
                "buffer is indexed by the register number" % (pidx, dst))
        out.append(('out', pidx, GPU_OUT_STRIDE, int(m.group(1)), dst))
    return out


def check_operands(result, anchors, cells, who, slotted):
    """Comment, constants and operands must agree with each other and with the
    .litmus cell.  [slotted]: a het lane addresses iteration _n's own slot."""
    model = [a for a in anchors if a.sig[0] in ('st', 'ld', 'fence')]
    if len(model) != len(cells):
        result.fail("%s carries %d model op(s) for %d .litmus cell(s)"
                    % (who, len(model), len(cells)))
        return

    def loc_of(a):
        """The location an access names, out of the pointer it was handed."""
        if not slotted:
            return a.ptr
        m = SLOT_PTR.match(a.ptr)
        if m is None:
            result.fail("%s: %s is handed %s, not iteration _n's own slot of a "
                        "location -- the whole run would race on one word"
                        % (who, fmt(a.sig), a.ptr))
            return None
        return m.group(1)

    for a, cell in zip(model, cells):
        kind, order, scope, o1, o2 = cell
        if a.sig[0] == 'fence':
            if (a.c_order, a.c_scope) != (order, scope):
                result.fail("%s: fence comment says f[%s,%s], its call says "
                            "f[%s,%s]" % (who, a.c_order, a.c_scope, order, scope))
            continue
        c = a.comment
        if c is None:
            result.fail("%s: %s carries no traceability comment"
                        % (who, fmt(a.sig)))
            continue
        ck, co, cs, tail = c
        if (ck, co, cs) != ({'st': 'w', 'ld': 'r'}[a.sig[0]], order, scope):
            result.fail("%s: comment says %s[%s,%s], the .litmus cell and the "
                        "emitted constants say %s[%s,%s]"
                        % (who, ck, co, cs,
                           {'st': 'w', 'ld': 'r'}[a.sig[0]], order, scope))
        if len(tail) != 2:
            result.fail("%s: comment for %s names %d operand(s), not 2"
                        % (who, fmt(a.sig), len(tail)))
            continue
        loc = loc_of(a)
        if a.sig[0] == 'st':
            if tail[0] != o1 or (loc is not None and loc != o1):
                result.fail("%s: store names %r/%r, the .litmus cell stores to %r"
                            % (who, tail[0], loc, o1))
            if tail[1] != a.val:
                result.fail("%s: store comment values %r, the call stores %r"
                            % (who, tail[1], a.val))
            elif a.val != o2:
                result.fail("%s: store writes %r, the .litmus cell writes %r"
                            % (who, a.val, o2))
        else:
            if tail[0] != o1 or a.dst != o1:
                result.fail("%s: load lands in %r/%r, the .litmus cell loads "
                            "into %r" % (who, tail[0], a.dst, o1))
            if tail[1] != o2 or (loc is not None and loc != o2):
                result.fail("%s: load reads %r/%r, the .litmus cell reads %r"
                            % (who, tail[1], loc, o2))


def check_gpu_only(result, inst, lanes, klines):
    """One guarded block per proc, in column order, holding that column's model
    ops and nothing else."""
    procs = [p for p, _ in inst['gpu']]
    if len(lanes) != len(procs):
        result.fail("gpu-only kernel has %d guarded block(s) for %d proc(s) (%s)"
                    % (len(lanes), len(procs),
                       ", ".join("P%d" % p for p in procs)))
        return
    seen = set()
    for (blk, lane, hdr, body), (pidx, ops) in zip(lanes, inst['gpu']):
        who = "P%d" % pidx
        if (blk, lane) in seen:
            result.fail("%s reuses the launch slot (workgroup %d, lane %d) of an "
                        "earlier proc" % (who, blk, lane))
        seen.add((blk, lane))
        b = PROC_BANNER.match(klines[hdr - 1].strip()) if hdr > 0 else None
        if not b:
            result.fail("%s: the guarded block carries no `// ---- P<n> "
                        "(workgroup B, lane L) ----' banner" % who)
        elif (int(b.group(1)), int(b.group(2)), int(b.group(3))) != (pidx, blk, lane):
            result.fail("%s: banner names P%s (workgroup %s, lane %s), the guard "
                        "selects (workgroup %d, lane %d)"
                        % (who, b.group(1), b.group(2), b.group(3), blk, lane))
        anchors = parse_lane(body, set(), "gpu-only %s" % who)
        cells = inst['cells'][pidx]
        expected = list(ops) + out_anchors(cells, pidx)
        if check_stream(result, expected, anchors, who):
            check_operands(result, anchors, cells, who, slotted=False)


def check_het(result, inst, lanes):
    """One guarded block per rendezvous-joining lane, in emission order: the GPU
    test lanes, in proc order."""
    # het_lane_plan reads only gpu/name.
    plan = ptx.het_lane_plan(dict(gpu=inst['gpu'], name=inst['name']))
    names = ", ".join("%s:P%d" % (l[2], l[0]) for l in plan)
    if len(lanes) != len(plan):
        result.fail("kernel has %d rendezvous-joining lane(s), the lane plan has "
                    "%d (%s)" % (len(lanes), len(plan), names))
        return
    result.note("  lane plan (x86_64 het): %d lane(s) -- %s" % (len(plan), names))
    for idx, ((blk, lane, _hdr, body), (pidx, payload, iname)) in \
            enumerate(zip(lanes, plan)):
        who = "%s:P%d" % (iname, pidx)
        if (blk, lane) != (idx, 0):
            result.fail("%s runs in (workgroup %d, lane %d); the lane plan puts "
                        "it in (workgroup %d, lane 0)" % (who, blk, lane, idx))
        anchors = parse_lane(body, DEVICE_HELPERS, who)
        check_lane_loop(result, body, anchors, who)
        rdv = [('rdv',), ('jitter',)]
        cells = inst['cells'][pidx]
        regs = []
        for ck, _o, _s, o1, _o2 in cells:
            if ck == 'r' and o1 not in regs:
                regs.append(o1)
        expected = rdv + list(payload) \
            + [('res', "bufP%d_%d" % (pidx, i), r)
               for i, r in enumerate(regs)]
        if (blk, lane) == (0, 0):
            expected += [('bump',)]
        if check_stream(result, expected, anchors, who):
            check_operands(result, anchors, cells, who, slotted=True)
        # The two scaffolding operands the anchor stream does not carry and
        # verify/rdvcheck.py does not pin either.
        for a in anchors:
            if a.sig[0] == 'rdv' and a.flag != "_rdvG_P%d" % pidx:
                result.fail("%s: the lane records its arrival in %s, not in its "
                            "own flag buffer -- the readout would read the wrong "
                            "lane's rendezvous" % (who, a.flag))
            if a.sig[0] == 'bump' and a.arg != '_gpu_iter':
                result.fail("%s: the iteration-clock bump names %s, not "
                            "_gpu_iter" % (who, a.arg))


def check_stress_region(result, other, helpers):
    """Outside the lanes a het kernel may carry only the whitelisted device
    helpers, and a gpu-only kernel nothing at all."""
    bad = []
    for ln in other:
        for t in ATOMIC_SHAPED.findall(ln):
            if t not in helpers:
                bad.append((t, ln.strip()))
    if bad:
        result.fail("%d atomic-or-fence construct(s) outside every lane" % len(bad))
        for t, ln in bad[:8]:
            result.note("  stray %s: %s" % (t, ln))
    else:
        result.note("  no atomic-or-fence construct outside the lanes")


def check_cpu(result, inst, cpu_c_text, cpu_c_path):
    """The x86_64 CPU columns, in proc order, against the compiled bodies of the
    real asm block."""
    expected = [("%s:P%d" % (inst['name'], p), p, ops) for p, ops in inst['cpu']]
    bodies = x86_bodies(cpu_c_text, cpu_c_path)
    if len(bodies) != len(expected):
        result.fail("_cpu.c carries %d compiled body/bodies, the test has "
                    "%d CPU column(s) (%s)"
                    % (len(bodies), len(expected),
                       ", ".join(w for w, _, _ in expected)))
        return
    for (bproc, got), (who, proc, ops) in zip(bodies, expected):
        if bproc != proc:
            result.fail("_cpu.c body code%d stands where %s's code%d belongs"
                        % (bproc, who, proc))
            continue
        if got != ops:
            result.fail("%s CPU memory-op stream differs (.litmus column vs "
                        "_cpu.c asm block)" % who)
            for i in range(max(len(ops), len(got))):
                e = " ".join(str(x) for x in ops[i]) if i < len(ops) else "<none>"
                a = " ".join(str(x) for x in got[i]) if i < len(got) else "<none>"
                if e != a:
                    result.note("  [%d] expected %-26s observed %-26s   <<< MISMATCH"
                                % (i, e, a))
        else:
            result.note("  %s CPU stream OK (%d mem op(s))" % (who, len(ops)))


# ===========================================================================
# 7. DRIVER
# ===========================================================================

def check_test(litmus_path, hip_override=None, cpu_c_override=None, verbose=True):
    inst = instance_of(litmus_path)
    kind, name = inst['kind'], inst['name']
    corpus = "x86_64 het" if kind == 'Het' else "gpu-only"
    result = Result()
    result.note("=== %s [%s, %s corpus] ===" % (name, kind, corpus))

    tmp = tempfile.mkdtemp(prefix="hipsrccheck_")
    try:
        if hip_override is not None:
            hip_path = hip_override
            cpu_c_path = cpu_c_override
            if cpu_c_path is None:
                sib = os.path.join(os.path.dirname(os.path.abspath(hip_path)),
                                   name + "_cpu.c")
                cpu_c_path = sib if os.path.exists(sib) else None
        else:
            hip_path, cpu_c_path = emit_harness(litmus_path, tmp)
            if cpu_c_override is not None:
                cpu_c_path = cpu_c_override
        result.note("  .hip %s" % hip_path)
        klines = kernel_lines(open(hip_path).read(), hip_path)
        lanes, other = split_lanes(klines)

        if kind == 'Het':
            check_het(result, inst, lanes)
            check_stress_region(result, other, DEVICE_HELPERS)
            if cpu_c_path is None:
                result.fail("het test has CPU columns but no _cpu.c to read")
            else:
                result.note("  _cpu.c %s" % cpu_c_path)
                check_cpu(result, inst, open(cpu_c_path).read(), cpu_c_path)
        else:
            check_gpu_only(result, inst, lanes, klines)
            check_stress_region(result, other, set())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in result.lines:
            print(ln)
    return result.ok


def run_check(litmus_path, hip=None, cpu_c=None, verbose=True):
    """(exit code, printed output) of one check: the sweep reads the same exit
    contract the command line does."""
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            ok = check_test(litmus_path, hip_override=hip, cpu_c_override=cpu_c,
                            verbose=verbose)
            print("RESULT:", "PASS" if ok else "FAIL")
        rc = 0 if ok else 1
    except CompletenessError as e:
        buf.write("COMPLETENESS HARD-FAIL: %s\n" % e)
        rc = 2
    except Exception as e:
        buf.write("ERROR: %s\n" % e)
        rc = 3
    return rc, buf.getvalue()
# ===========================================================================
# 8. CORPUS SWEEP
# ===========================================================================

# `nproc' honours this process's affinity mask but not a cgroup CPU quota, so
# an uncapped default can oversubscribe a container several times over.
JOBS_CAP = 12


def default_jobs():
    return min(len(os.sched_getaffinity(0)), JOBS_CAP)


def corpus_files(d, label, expect):
    """The .litmus files of one corpus, its census asserted BEFORE the sweep:
    `pass == total' is vacuously true over a corpus that is not there."""
    if not os.path.isdir(d):
        raise GateError("the %s corpus directory %s does not exist" % (label, d))
    files = sorted(f for f in os.listdir(d) if f.endswith(".litmus"))
    if len(files) != expect:
        raise GateError(
            "the %s corpus %s holds %d .litmus, expected %d -- a short corpus "
            "is refused, never swept as if it were the whole one"
            % (label, d, len(files), expect))
    return [os.path.join(d, f) for f in files]


def regen_x86(dst):
    """The x86_64 het corpus, regenerated into [dst]: it is generated on demand
    rather than committed (hetlitmus/tests/het/generate-x86.sh says why)."""
    r = subprocess.run(["bash", GEN_X86, dst],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        raise GateError("generate-x86.sh failed:\n%s" % r.stdout)
    return dst


def _sweep_one(litmus_path):
    """One test, as (verdict, name, output).  A worker that raises is reported as
    that test's error verdict; nothing here can turn an exception into a pass."""
    name = os.path.basename(litmus_path)[:-len(".litmus")]
    try:
        rc, out = run_check(litmus_path)
    except Exception as e:
        return "ERROR", name, "ERROR: %s: %s\n" % (type(e).__name__, e)
    return {0: "PASS", 1: "FAIL", 2: "GUARD-FAIL"}.get(rc, "ERROR"), name, out


def sweep_dir(files, label, jobs, diffs):
    """Check one corpus in a worker pool; print its table and TALLY line and
    return (pass, total).  Every non-PASS test's output is echoed and saved."""
    print("\n===== HIP source faithfulness: %s =====" % label)
    print("%-42s | %s" % ("test", "verdict"))
    print("-" * 43 + "+---------")
    rows = []
    with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as pool:
        for verdict, name, out in pool.map(_sweep_one, files):
            rows.append((name, verdict, out))
    rows.sort()
    for name, verdict, _out in rows:
        print("%-42s | %s" % (name, verdict))
    print("-" * 43 + "+---------")
    n = {v: sum(1 for _, w, _ in rows if w == v)
         for v in ("PASS", "FAIL", "GUARD-FAIL", "ERROR")}
    print("TALLY %s: %d/%d PASS  (FAIL=%d  GUARD-FAIL=%d  ERROR=%d)"
          % (label, n["PASS"], len(rows), n["FAIL"], n["GUARD-FAIL"], n["ERROR"]))
    if n["PASS"] != len(rows):
        print("\n--- output for every non-PASS %s test (saved in %s) ---"
              % (label, diffs))
        for name, verdict, out in rows:
            if verdict == "PASS":
                continue
            with open(os.path.join(diffs, "diff." + name), "w") as fh:
                fh.write(out)
            print(">>> %s %s" % (verdict, name))
            print(out.rstrip())
    return n["PASS"], len(rows)


# The fence annotation no corpus test carries: only a synthetic carrier reads
# litmus/HipLang.ml's f[acq_rel,*] row.
SYNTH = {
    "F-acqrel-sys": "f[acq_rel,sys]",
}
SYNTH_BODY = """LISA %s
{
}
 P0                 | P1                  ;
 w[relaxed,sys] x 1 | r[relaxed,sys] r0 y ;
 %-18s | %-19s;
 w[relaxed,sys] y 1 | r[relaxed,sys] r1 x ;
scopes: (sys (gpu (cta 0) (cta 1)))
exists (1:r0=1 /\\ 1:r1=0)
"""


def synth_carrier(d, name):
    """A .litmus carrying [name]'s annotation, written into [d]."""
    p = os.path.join(d, name + ".litmus")
    with open(p, "w") as fh:
        fh.write(SYNTH_BODY % (name, SYNTH[name], SYNTH[name]))
    return p


def sweep_synth(work, diffs):
    """The synthetic carriers, written out and then swept like a corpus: a
    carrier missing from the table is refused the way a short corpus is."""
    os.makedirs(work)
    for name in SYNTH:
        synth_carrier(work, name)
    files = corpus_files(work, "synthetic carriers", census.SYNTHETIC)
    return sweep_dir(files, "synthetic carriers", 1, diffs)


def sweep(gpu_dir, x86_dir, jobs):
    """Both corpora against their pinned censuses, then the synthetic carriers.
    X86_HET_N counts this lane's x86_64 rendering, NOT ptxcheck's AArch64 one."""
    tmp = tempfile.mkdtemp(prefix="hipsrccheck.")
    try:
        # Both censuses are asserted before a single test runs: a corpus that is
        # not there cannot be reported as a corpus that passed.
        gpu_files = corpus_files(gpu_dir, "gpu-only", GPU_ONLY_N)
        generated = x86_dir is None
        if generated:
            x86_dir = regen_x86(os.path.join(tmp, "corpus"))
        x86_files = corpus_files(x86_dir, "x86_64 het", X86_HET_N)
        print("===== HIP SOURCE GATE: %d gpu-only + %d x86_64 het renders + %d "
              "synthetic carriers =====" % (GPU_ONLY_N, X86_HET_N, census.SYNTHETIC))
        print("  gpu-only    %s" % gpu_dir)
        print("  x86_64 het  %s%s" % (x86_dir, " (generated)" if generated else ""))
        print("  workers     %d" % jobs)
        diffs = tempfile.mkdtemp(prefix="hipsrccheck-diffs.")
        gp, gt = sweep_dir(gpu_files, "gpu-only", jobs, diffs)
        xp, xt = sweep_dir(x86_files, "x86_64 het", jobs, diffs)
        sp, st = sweep_synth(os.path.join(tmp, "synth"), diffs)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    ok = ((gp, gt) == (GPU_ONLY_N, GPU_ONLY_N)
          and (xp, xt) == (X86_HET_N, X86_HET_N)
          and (sp, st) == (census.SYNTHETIC, census.SYNTHETIC))
    print("HIP SOURCE GATE: %s -- gpu-only %d/%d, x86_64 het %d/%d "
          "(the x86_64 rendering of the het corpus, not the AArch64 one) + "
          "%d/%d synthetic carriers"
          % ("PASS" if ok else "FAILED", gp, gt, xp, xt, sp, st))
    if ok:
        shutil.rmtree(diffs, ignore_errors=True)
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus HIP source gate: .litmus annotation vs emitted HIP")
    ap.add_argument("litmus", nargs="?", help=".litmus test path")
    ap.add_argument("--hip-src", help="read this .hip instead of emitting one")
    ap.add_argument("--cpu-c", help="read this _cpu.c instead of emitting one")
    ap.add_argument("--all", action="store_true",
                    help="sweep both corpora (%d gpu-only + %d x86_64 het) and "
                         "the %d synthetic carriers"
                         % (GPU_ONLY_N, X86_HET_N, census.SYNTHETIC))
    ap.add_argument("--gpu-dir", default=GPU_ONLY_DIR,
                    help="the gpu-only corpus to sweep")
    ap.add_argument("--x86-dir",
                    help="an x86_64 het corpus to sweep (default: regenerate one)")
    ap.add_argument("--jobs", type=int, default=default_jobs(),
                    help="sweep workers (default: CPUs, capped at %d)" % JOBS_CAP)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    try:
        if args.all:
            sys.exit(sweep(args.gpu_dir, args.x86_dir, max(1, args.jobs)))
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        sys.exit(2)
    except GateError as e:
        print("ERROR: %s" % e)
        sys.exit(3)
    if not args.litmus:
        print("ERROR: no .litmus given (and --all not asked for)")
        sys.exit(3)
    rc, out = run_check(args.litmus, hip=args.hip_src, cpu_c=args.cpu_c,
                        verbose=not args.quiet)
    sys.stdout.write(out)
    sys.exit(rc)


if __name__ == "__main__":
    main()
