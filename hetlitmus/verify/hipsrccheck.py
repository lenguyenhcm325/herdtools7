#!/usr/bin/env python3
"""
hipsrccheck.py -- the HIP source gate: an emitted HIP harness carries exactly
the memory ops its .litmus annotates, with the annotated kind, order and scope.

    .litmus annotation --(litmus/HipLang.ml)--> .hip source --(this)-->
        expected (kind,order,scope) == the emitted builtin's constants, its
        traceability comment and its operands, all three agreeing.

What it proves.  The HIP path carries no inline assembly: every memory
primitive is a compiler-owned source construct, so the annotation survives into
the source as a constant that can be read back without naming a GPU generation.
Per proc (gpu-only) or per barrier-joining lane (het) the model ops appear in
.litmus column order, each as its mapped builtin with the mapped __ATOMIC_* and
__HIP_MEMORY_SCOPE_* constants, addressed at this iteration's own slot, its
result store included; the het scaffolding around them -- system-scope
rendezvous, result stores -- is exactly what the lane plan predicts; the x86_64
CPU column is rendered into the _cpu.c asm block mnemonic for mnemonic, operand
for operand; and a lane carries
no further memory construct -- atomic, fence, inline asm or volatile.  A het
lane's ops also sit unguarded in the body of one `#pragma unroll 1' loop over
SIZE_OF_TEST, which is placement the anchor stream cannot see; the gpu-only
path has no such loop, its procs running once (litmus/gpuLang.ml dump_test).

What it does not prove.  Nothing about what a compiler makes of those
constructs: no ISA is read, no code is generated, no kernel runs.  It is also
a parser of the .litmus CPU column's rendering only -- the per-iteration
clflush/prefetcht0 preload and the CPU observer's plain volatile read touch the
same locations and are outside its vocabulary by design
(litmus/het-runtime/het_cpu_stress.h).

Corpus.  gpu-only tests plus the x86_64 het rendering that
hetlitmus/tests/het/generate-x86.sh writes -- NOT the AArch64 het corpus, whose
CPU column this lane never emits.  Every printed count names which.

ptxcheck.py is the NVIDIA twin (hetlitmus/docs/faithfulness.md).  It is
imported, never modified: its .litmus parsers, its GPU mapping table and its
lane plan are the expected side here too.  One half of it cannot be reused and
is re-supplied below: cpu_ops_of_column reads AArch64 mnemonics, and this lane's
CPU column is x86_64.

Usage:
  hipsrccheck.py TEST.litmus [--hip-src F] [--cpu-c F] [-q]
  hipsrccheck.py --all [--gpu-dir D] [--x86-dir D] [--jobs N]
  hipsrccheck.py --bite
  hipsrccheck.py --guard

--hip-src/--cpu-c read a pre-existing render instead of emitting one; with
--hip-src alone the sibling <name>_cpu.c beside it is used when present.
--all sweeps both corpora against their pinned censuses; --bite injects into a
fresh render per check and requires each one to redden its own assertion.

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
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
PTXCHECK = os.path.join(HERE, "ptxcheck.py")

# The corpus, pinned.  ptxcheck.py reads these same gpu-only tests with the
# AArch64 het rendering; the AMD lane's het half is the x86_64 rendering of the
# same shapes, which hetlitmus/tests/het/generate-x86.sh writes on demand, and
# every count this file prints says which.
GPU_ONLY_DIR = os.path.join(REPO, "hetlitmus", "tests", "gpu-only")
GPU_ONLY_N = 173
GEN_X86 = os.path.join(REPO, "hetlitmus", "tests", "het", "generate-x86.sh")
X86_HET_N = 471


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
# 1. The mapping table -- HipLang.ml's own (litmus/HipLang.ml), which is the
#    expected side rather than a re-derivation.  It doubles as the completeness
#    guard: a constant that is not a value here hard-fails, so no emitted op is
#    ever silently accepted.
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

# HipLang.hip_fence_scope: __builtin_amdgcn_fence's second argument is an
# AMDHSA sync-scope string [D75917], and system scope is the absence of a
# name -- the empty string -- so naming one there NARROWS the fence
# [AMDGPUUsage "Memory Scopes"].
HIP_FENCE_SCOPE = {
    "cta": "workgroup",
    "gpu": "agent",
    "sys": "",
}

ORDER_OF_CONST = {v: k for k, v in HIP_ORDER.items()}
SCOPE_OF_CONST = {v: k for k, v in HIP_SCOPE.items()}
SCOPE_OF_FENCE_STR = {v: k for k, v in HIP_FENCE_SCOPE.items()}

# The x86-64 CPU-column vocabulary this lane's corpus is written in
# (hetlitmus/tests/het/generate-x86.sh).  A MOV is classified by its operand
# shape, in AT&T order (source first); litmus7's own X86_64 lowering carries the
# column's mnemonic through unchanged, so the expected mnemonic is the one the
# column names.  Anything outside this set hard-fails rather than being compared
# as an opaque string.
X86_MOV = {"mov", "movb", "movw", "movl", "movq"}
X86_FENCE = {"mfence", "sfence", "lfence"}
X86_CONSUMED = {"nop"}
# litmus7 names an x86_64 register by its 64-bit name whatever width the column
# spells (its condition atoms read `0:rax'), and the emitted asm operand carries
# that name.  The 32-bit views the corpus uses map onto it here.
X86_REG_64 = {"eax": "rax", "ebx": "rbx", "ecx": "rcx", "edx": "rdx",
              "esi": "rsi", "edi": "rdi", "ebp": "rbp", "esp": "rsp",
              "rax": "rax", "rbx": "rbx", "rcx": "rcx", "rdx": "rdx",
              "rsi": "rsi", "rdi": "rdi", "rbp": "rbp", "rsp": "rsp"}

# Device helpers a het kernel may carry (litmus/het-runtime/het_stress.h).  A
# helper outside this set hard-fails: an unlisted one is an unmodelled memory
# primitive.
DEVICE_HELPERS = {
    "het_rng_t", "het_rng_init", "het_rng_next", "het_rng_pct",
    "het_scratch_read", "het_scratch_bump", "het_scratch_max",
    "het_do_stress",
}

# Every memory-construct-shaped token, so one appearing outside the modelled
# anchors is surfaced rather than skipped.  Scaffolding may be invisible only
# because it is unordered device-scope traffic; an ordered or scoped construct
# the gate has no model for is not scaffolding.  `asm' is in the list because
# a source-level read stands for the whole memory behaviour ONLY while the HIP
# path carries no inline assembly.
_SHAPED = (r'__hip_atomic_\w+|__builtin_\w+|__threadfence\w*|__atomic_\w+'
           r'|__sync_\w+|\batomic[A-Za-z_]\w*|\bhet_[a-z]\w*'
           r'|\basm\b|__asm__')
ATOMIC_SHAPED = re.compile(r'(%s)' % _SHAPED)
# Inside a lane every access is accounted for by an anchor, so a volatile one
# is an access no anchor carries.  The interconnect-noise reader is the
# modelled volatile access and lives outside every lane.
LANE_SHAPED = re.compile(r'(%s|\bvolatile\b)' % _SHAPED)


# ===========================================================================
# 2. .litmus PARSING -- the expected side
# ===========================================================================

# The operand tail of a GPU cell, which ptxcheck's gpu_ops_of_column drops:
#   w[o,s] <var> <value>     r[o,s] <dst> <var>     f[o,s]
# HipLang emits the same two operands into the traceability comment, in the
# same order, so this is what binds a comment to the column that produced it.
CELL_TAIL = {
    "w": re.compile(r'^(?P<var>[A-Za-z_]\w*)\s+(?P<val>\S+)$'),
    "r": re.compile(r'^(?P<dst>[A-Za-z_]\w*)\s+(?P<var>[A-Za-z_]\w*)$'),
    "f": re.compile(r'^$'),
}


def gpu_cells_of_column(cells):
    """Ordered (kind, order, scope, opnd1, opnd2) for a GPU column's cells.

    Completeness guard: a cell whose tail is not one of the three shapes above
    hard-fails, so an operand form the comment check cannot bind is refused
    rather than compared against nothing."""
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


# An x86-64 memory operand as this lane's corpus spells it: a bare global.  A
# register deref would name an address this file cannot resolve, so it is refused
# rather than guessed at.
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
    cells.

    kind is 'store' | 'load' | 'fence'; the mnemonic is the column's own, which
    is what litmus7's X86_64 lowering emits.  The fourth field is the operand the
    access carries: the VALUE a store writes and the destination register a load
    lands in, both taken from the .litmus.  Completeness guard: anything outside
    the vocabulary hard-fails rather than being compared as an opaque string."""
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
    """One .litmus parsed into the profile the checker compares against.

    ptxcheck's own instance_of routes CPU columns through cpu_ops_of_column,
    whose mnemonic table is AArch64's, so it raises on every x86_64 column."""
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
# litmus/hetEmit.ml); anything else that opens on blockIdx.x is a geometry the
# lane plan cannot be matched against.
LANE_GUARD = re.compile(r'^if \(blockIdx\.x == (\d+) && threadIdx\.x == (\d+)\) \{$')
STRESS_GUARD = re.compile(r'^if \(blockIdx\.x >= HET_TEST_BLOCKS\) \{$')
PROC_BANNER = re.compile(r'^// ---- P(\d+)\s+\(workgroup (\d+), lane (\d+)\) ----$')


def kernel_lines(hip_text, path):
    """The kernel's lines, from its __global__ header to the closing brace in
    column 0.  Everything after it is host code, whose own rendezvous uses the
    same builtins on the same barrier and is not this gate's subject."""
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
    """(lanes, other): one entry per guarded block, plus every kernel line that
    is not inside one.

    A lane is (blk, lane, header_index, [body lines]).  The stress/noise region
    (`blockIdx.x >= HET_TEST_BLOCKS') is not a lane and lands in `other'."""
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


C_STORE = re.compile(r'^__hip_atomic_store\((.*)\);$')
C_LOAD = re.compile(r'^(?P<dst>[^=<>!]+?)\s*=\s*__hip_atomic_load\((.*)\);$')
C_FENCE = re.compile(r'^__builtin_amdgcn_fence\((.*)\);\s*// f\[(\w+),(\w+)\]$')
C_RELAXED_FENCE = re.compile(
    r'^// f\[(\w+),(\w+)\] \(relaxed fence = no-op; nothing emitted\)$')
C_RDV_ADD = re.compile(r'^\(void\)__hip_atomic_fetch_add\((.*)\);$')
C_RDV_SPIN = re.compile(r'^while \(__hip_atomic_load\((.*)\) < NPART\) \{ \}$')
C_BUMP = re.compile(r'^het_scratch_bump\((.*)\);$')
C_COMMENT = re.compile(r'^// ([wrf])\[(\w+),(\w+)\](?:\s+(.*))?$')
C_RESULT = re.compile(r'^(\w+)\[_n\] = (\w+);$')
C_OUT = re.compile(r'^__out\[(\d+) \* (\d+) \+ (\d+)\] = (\w+);$')
# The pointer a het lane hands every tested access: iteration _n's own slot of
# that location (litmus/het-runtime/het_rdv.h).  A bare pointer here is a lane
# racing on one word for the whole run, which no readout could pair.
SLOT_PTR = re.compile(r'^\((\w+) \+ \(_n\)\*HET_SLOT_STRIDE_WORDS\)$')
# litmus/gpuLang.ml nregs_layout: the result slots one proc owns in __out.
GPU_OUT_STRIDE = 4
GPU_REG = re.compile(r'^r(\d+)$')

# The two lines litmus/hetEmit.ml opens every het lane's iteration loop with,
# in this order.  SIZE_OF_TEST is a compile-time constant, so without the
# pragma the loop is unrolled and the kernel carries many copies of the tested
# ops -- a different program from the one the .litmus names -- and a literal
# bound is a trip count the harness never asked for.
LOOP_PRAGMA = "#pragma unroll 1"
LOOP_HEAD = re.compile(r'^for \(int _n=0; _n<(\S+); \+\+_n\) \{$')
LOOP_BOUND = "SIZE_OF_TEST"
# What one iteration owns.  An op hoisted out of the loop runs once per launch
# rather than once per iteration, so the window the test needs closes after the
# first one.
PER_ITERATION = ('st', 'ld', 'fence', 'res')
# ...and what the lane owns once.  The rendezvous joins the two devices before
# the loop opens; a copy inside it is a per-iteration cross-device barrier
# around every tested access, and the anchor stream alone cannot see the move.
ONCE_PER_LANE = ('rdv-add', 'rdv-spin', 'bump')
# A statement that can guard the line under it without a brace of its own, and
# a jump that can skip the rest of an iteration: both leave an op's order, its
# constants and its comment untouched while it stops running per iteration.
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
    was read from (check_lane_loop compares those against the loop's span).

    An unrecognized line is legal only when every atomic-shaped or het_ token
    on it is a whitelisted device helper; otherwise the gate has no model for
    what that line does to memory and refuses."""
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
        if m and C_RELAXED_FENCE.match(s) is None:
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
        m = C_RELAXED_FENCE.match(s)
        if m:
            order, scope = m.group(1), m.group(2)
            if scope not in HIP_SCOPE:
                raise CompletenessError(
                    "%s: the no-op fence comment names scope %r: %r"
                    % (where, scope, s))
            # Nothing executable is emitted here, so the annotation is both the
            # claim and the whole evidence.  HipLang.dump_instr writes this form
            # for a relaxed fence and for no other, so any other order means a
            # fence that is NOT there.
            if order != 'relaxed':
                raise CompletenessError(
                    "%s renders f[%s,%s] as a comment and emits nothing, and "
                    "HipLang.dump_instr writes that form only for a relaxed "
                    "fence: %r" % (where, order, scope, s))
            flush()
            add(Anchor(('fence', order, scope), [], emitted=False))
            continue
        m = C_STORE.match(s)
        if m:
            args = split_args(m.group(1))
            if len(args) != 4:
                raise CompletenessError(
                    "__hip_atomic_store takes 4 arguments; %s has %d in %r"
                    % (where, len(args), s))
            a = Anchor(('st', _order(args[2], where), _scope(args[3], where)),
                       ['__hip_atomic_store'], ptr=args[0], val=args[1],
                       comment=pending)
            pending = None
        if a is None:
            m = C_RDV_SPIN.match(s)
            if m:
                args = split_args(m.group(1))
                if len(args) != 3:
                    raise CompletenessError(
                        "the rendezvous spin load takes 3 arguments; %s has %d in %r"
                        % (where, len(args), s))
                flush()
                a = Anchor(('rdv-spin', _order(args[1], where), _scope(args[2], where)),
                           ['__hip_atomic_load'], ptr=args[0])
        if a is None:
            m = C_LOAD.match(s)
            if m:
                args = split_args(m.group(2))
                if len(args) != 3:
                    raise CompletenessError(
                        "__hip_atomic_load takes 3 arguments; %s has %d in %r"
                        % (where, len(args), s))
                dst = m.group('dst').strip()
                o, sc = _order(args[1], where), _scope(args[2], where)
                a = Anchor(('ld', o, sc), ['__hip_atomic_load'],
                           dst=dst, ptr=args[0], comment=pending)
                pending = None
        if a is None:
            m = C_FENCE.match(s)
            if m:
                args = split_args(m.group(1))
                if len(args) != 2:
                    raise CompletenessError(
                        "__builtin_amdgcn_fence takes 2 arguments; %s has %d in %r"
                        % (where, len(args), s))
                if not (args[1].startswith('"') and args[1].endswith('"')):
                    raise CompletenessError(
                        "__builtin_amdgcn_fence's sync scope is not a string "
                        "literal in %r (%s)" % (s, where))
                sstr = args[1][1:-1]
                if sstr not in SCOPE_OF_FENCE_STR:
                    raise CompletenessError(
                        "unknown AMDHSA sync-scope string %r in %s" % (sstr, where))
                flush()
                a = Anchor(('fence', _order(args[0], where), SCOPE_OF_FENCE_STR[sstr]),
                           ['__builtin_amdgcn_fence'], emitted=True,
                           c_order=m.group(2), c_scope=m.group(3))
        if a is None:
            m = C_RDV_ADD.match(s)
            if m:
                args = split_args(m.group(1))
                if len(args) != 4:
                    raise CompletenessError(
                        "the rendezvous fetch_add takes 4 arguments; %s has %d in %r"
                        % (where, len(args), s))
                flush()
                a = Anchor(('rdv-add', _order(args[2], where), _scope(args[3], where)),
                           ['__hip_atomic_fetch_add'], ptr=args[0], inc=args[1])
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
# The non-static het_run_P<n> wrapper that calls it stands OUTSIDE this block,
# because the portable shim needs the same entry point.
X86_BODY = re.compile(r'^\s*(?:__attribute__\(\(noinline\)\)\s*)?static void '
                      r'code(\d+)\(', re.M)
X86_ASM = re.compile(r'asm __volatile__ ?\((.*?)\n\s*:', re.S)
ASM_STR = re.compile(r'"([^"\n]*)"')
# ASMLang interleaves its instructions with `#START _litmus_P<n>' /
# `#_litmus_P<n>_<i>' / `#END _litmus_P<n>' marker literals; a marker is not an
# instruction and carries no memory op.
A_MARKER = re.compile(r'^#(START |END |_litmus_)')
# The operand shapes litmus7's X86_64 lowering writes: a store's value is an
# immediate into the location's `=m' operand, a load reads that operand into the
# destination register's, `%k' selecting its 32-bit view.
A_STORE = re.compile(r'^(\w+)\s+\$(-?\d+),%\[(\w+)\]$')
A_LOAD = re.compile(r'^(\w+)\s+%\[(\w+)\],%k?\[(\w+)\]$')


def asm_instrs(template, path, who):
    """The instructions of one asm template, in order, one per string literal.

    EVERY literal is read, and each must be one line closed by the newline
    escape, as ASMLang.dump_fun writes them (a marker literal may close with a
    trailing tab as well).  C concatenates adjacent literals, so a literal the
    parse skipped -- an unterminated one, or a second instruction sharing a
    line -- is an instruction spliced into a tested body that the op stream
    never shows: a body that no longer runs the program the .litmus names."""
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
    """Every compiled body in the real x86_64 block, as (proc, [ops]).

    finditer over the bodies, not `search': the block holds one per CPU proc
    and every one of them is the tested path."""
    out = []
    blocks = X86_BLOCK.findall(cpu_c_text)
    if not blocks:
        raise CompletenessError(
            "%s carries no `#if defined(__x86_64__)' block -- the portable shim "
            "is not the tested path" % path)
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
    if k == 'rdv-add':
        return "rendezvous.fetch_add[%s,%s]" % (sig[1], sig[2])
    if k == 'rdv-spin':
        return "rendezvous.spin[%s,%s]" % (sig[1], sig[2])
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
    """Ordered compare of one lane, with an order-blind multiset as a
    post-failure localizer ONLY: it is strictly weaker than the ordered test,
    so on a green lane it can detect nothing at all."""
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
    """Per line of a lane, the statements guarding it: the brace openers it sits
    inside, innermost last, plus a braceless control head it is the body of.

    Brace depth alone reads `if (_n == 0) __hip_atomic_store(...)' as ordinary
    lane code, so the braceless form counts as a guard too -- litmus/hetEmit.ml
    writes one itself, over the pre-stress roll."""
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
    SIZE_OF_TEST, unrolled by one, with no jump able to skip them.

    The gpu-only path has no such loop by design -- litmus/gpuLang.ml dump_test
    emits each proc's ops once -- so this is asked of het lanes ONLY.  It reads
    placement, which no anchor stream can see: an op keeps its order, constants
    and comment whether it is hoisted out of the loop, guarded inside it or
    jumped over, and a rendezvous dragged in becomes a barrier around every
    tested access."""
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
    if close is None:
        result.fail("%s: the iteration loop has no closing brace inside the lane"
                    % who)
        return
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
        elif a.sig[0] in ONCE_PER_LANE:
            if inside:
                bad = True
                result.fail("%s: %s sits INSIDE the per-iteration loop -- it is "
                            "the lane's once-per-launch scaffolding"
                            % (who, fmt(a.sig)))
            elif chain:
                bad = True
                result.fail("%s: %s is guarded by `%s', so the lane's "
                            "once-per-launch scaffolding may not run at all"
                            % (who, fmt(a.sig), body[chain[-1]].strip()))
    if not bad:
        result.note("  %s loop structure OK (%s over %s, %d anchor(s) inside)"
                    % (who, LOOP_PRAGMA, LOOP_BOUND,
                       sum(1 for a in anchors
                           if chains[a.idx] and chains[a.idx][0] == h)))


def out_anchors(cells, pidx):
    """The result stores a gpu-only proc ends on: one per read register, into
    the slot litmus/gpuLang.ml dump_test reserves for it.  They are the only
    channel by which a gpu-only read reaches an outcome, so a dropped or
    misindexed one loses a read with nothing else to notice."""
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
    .litmus cell that produced them.  The constants alone are what the stream
    compare sees, so a comment edited on its own would otherwise be invisible --
    and the comment is the only thing tying an emitted call back to its column.

    [slotted]: a het lane addresses iteration _n's own slot of the location, a
    gpu-only proc the bare pointer."""
    model = [a for a in anchors if a.sig[0] in ('st', 'ld', 'fence')]
    if len(model) != len(cells):
        return                                   # the stream compare said so

    def loc_of(a):
        """The location an access names, read out of the pointer it was handed."""
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
            if not getattr(a, 'emitted', True):
                # A relaxed fence emits nothing, so its annotation is the whole
                # construct; parse_lane refuses that form for any other order,
                # and the stream compare has already bound this one to the cell.
                continue
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
    """One guarded block per barrier-joining lane, in emission order: the GPU
    test lanes, in proc order."""
    # het_lane_plan reads only gpu/name.
    plan = ptx.het_lane_plan(dict(gpu=inst['gpu'], name=inst['name']))
    names = ", ".join("%s:P%d" % (l[3], l[1]) for l in plan)
    if len(lanes) != len(plan):
        result.fail("kernel has %d barrier-joining lane(s), the lane plan has "
                    "%d (%s)" % (len(lanes), len(plan), names))
        return
    result.note("  lane plan (x86_64 het): %d lane(s) -- %s" % (len(plan), names))
    for idx, ((blk, lane, _hdr, body), (_kindl, pidx, payload, iname)) in \
            enumerate(zip(lanes, plan)):
        who = "%s:P%d" % (iname, pidx)
        if (blk, lane) != (idx, 0):
            result.fail("%s runs in (workgroup %d, lane %d); the lane plan puts "
                        "it in (workgroup %d, lane 0)" % (who, blk, lane, idx))
        anchors = parse_lane(body, DEVICE_HELPERS, who)
        check_lane_loop(result, body, anchors, who)
        rdv = [('rdv-add', 'sc', 'sys'), ('rdv-spin', 'sc', 'sys')]
        cells = inst['cells'][pidx]
        regs = []
        for ck, _o, _s, o1, _o2 in cells:
            if ck == 'r' and o1 not in regs:
                regs.append(o1)
        expected = rdv + list(payload) \
            + [('res', "bufP%d_%d" % (pidx, i), r)
               for i, r in enumerate(regs)] + [('bump',)]
        if check_stream(result, expected, anchors, who):
            check_operands(result, anchors, cells, who, slotted=True)
        # The scaffolding's operands, which the anchor stream does not carry.
        for a in anchors:
            if a.sig[0] in ('rdv-add', 'rdv-spin') and a.ptr != '(barrier)':
                result.fail("%s: the rendezvous counts on %s, not on the shared "
                            "barrier" % (who, a.ptr))
            if a.sig[0] == 'rdv-add' and a.inc != '1':
                result.fail("%s: the rendezvous arrives by %s, so the lane count "
                            "NPART names no lane population" % (who, a.inc))
            if a.sig[0] == 'bump' and a.arg != '_gpu_done':
                result.fail("%s: the lane's completion bump names %s, not "
                            "_gpu_done" % (who, a.arg))


def check_stress_region(result, other, helpers):
    """Outside the lanes a het kernel may carry only the whitelisted device
    helpers, and a gpu-only kernel nothing at all: an ordered or scoped
    construct there is traffic no lane accounts for, and the model-op compare
    would never see it."""
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
            if inst['cpu']:
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
    """(exit code, printed output) of one check.

    The exit contract is the return value, so a caller inside this process --
    the corpus sweep, an injection under --bite -- reads exactly what the
    command line would."""
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


def capture(fn, **override):
    """(exit code, printed output) of an in-process call, with module globals
    temporarily replaced.

    The guard reads its tables and its paths through those globals, so an
    emptied table and an unresolvable litmus7 are injections like any other."""
    g = globals()
    saved = {k: g[k] for k in override}
    g.update(override)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = fn()
    except CompletenessError as e:
        buf.write("COMPLETENESS HARD-FAIL: %s\n" % e)
        rc = 2
    except Exception as e:
        buf.write("ERROR: %s\n" % e)
        rc = 3
    finally:
        g.update(saved)
    return rc, buf.getvalue()


def guard_report():
    """The vocabulary this checker understands and the paths it resolves.  An
    empty table or an unresolvable path is itself a failure: a guard that
    reports nothing is a guard that checks nothing."""
    bad = 0
    print("===== HIP SOURCE GATE: vocabulary and paths =====")
    print("\n-- paths --")
    for what, p, must in (("litmus7", LITMUS7, True), ("libdir", LIBDIR, True),
                          ("ptxcheck.py (imported, not modified)", PTXCHECK, True)):
        ok = os.path.exists(p)
        print("  %-38s %s  %s" % (what, p, "" if ok else "*** MISSING ***"))
        if must and not ok:
            bad += 1

    print("\n-- GPU annotation -> emitted HIP construct (litmus/HipLang.ml) --")
    print("  w[o,s] <var> <value>   __hip_atomic_store(<var>, <value>, <ORDER>, <SCOPE>)")
    print("  r[o,s] <dst> <var>     <dst> = __hip_atomic_load(<var>, <ORDER>, <SCOPE>)")
    print("  f[o,s]                 __builtin_amdgcn_fence(<ORDER>, \"<scope>\"); // f[o,s]")
    print("  f[relaxed,s]           a comment only; nothing executable, and no")
    print("                         other order may be rendered that way")
    print("  gpu-only result store  __out[<proc> * %d + <n>] = r<n>, one per read"
          % GPU_OUT_STRIDE)
    print("  het slot address       %s" % SLOT_PTR.pattern)
    for label, table in (("memory orders", HIP_ORDER), ("access scopes", HIP_SCOPE),
                         ("fence sync scopes", HIP_FENCE_SCOPE)):
        print("\n-- %s --" % label)
        if not table:
            print("  *** empty table ***")
            bad += 1
        for k, v in table.items():
            print("  %-8s -> %s" % (k, ('""' if v == "" else v)))
    print("  (the unnamed fence scope IS system scope; naming one narrows it)")

    print("\n-- x86_64 CPU column -> emitted _cpu.c asm (litmus7 ASMLang.dump_fun) --")
    print("  MOV (g),%reg     load    <mn> %[g],%k[<reg64>]")
    print("  MOV $k,(g)       store   <mn> $k,%[g]")
    print("  %s   fence   the bare mnemonic"
          % "|".join(sorted(X86_FENCE)))
    print("  accepted MOV spellings: %s" % ", ".join(sorted(X86_MOV)))
    print("  register names:         %s"
          % ", ".join("%s->%s" % (k, v) for k, v in sorted(X86_REG_64.items())
                      if k != v))
    if not (X86_MOV and X86_FENCE and X86_REG_64):
        bad += 1

    print("\n-- het lane anchors --")
    for s in (("rdv-add", "sc", "sys"), ("rdv-spin", "sc", "sys"),
              ("res", "<buf>", "<reg>"), ("bump",)):
        print("  %s" % fmt(s))
    print("\n-- the het lane's iteration loop (litmus/hetEmit.ml) --")
    print("  %s" % LOOP_PRAGMA)
    print("  for (int _n=0; _n<%s; ++_n) {   %s inside, %s outside"
          % (LOOP_BOUND, "/".join(PER_ITERATION), "/".join(ONCE_PER_LANE)))
    print("  no anchor sits under a guard, and no %s reaches into the loop"
          % LOOP_JUMP.pattern)
    if 'continue' not in LOOP_JUMP.pattern:
        bad += 1
    print("  (the gpu-only path has no loop: its procs run once)")

    print("\n-- device helpers a het kernel may carry (litmus/het-runtime/het_stress.h) --")
    if not DEVICE_HELPERS:
        bad += 1
    print("  %s" % " ".join(sorted(DEVICE_HELPERS)))

    print("\n-- memory constructs surfaced as unmodelled, by region --")
    print("  in a lane            %s" % LANE_SHAPED.pattern)
    print("  outside every lane   %s" % ATOMIC_SHAPED.pattern)
    if not (_SHAPED and 'asm' in LANE_SHAPED.pattern):
        bad += 1

    print("\n-- exit contract --")
    print("  0 PASS   1 FAIL   2 completeness hard-fail   3 error")
    if bad:
        print("\nGUARD FAILED: %d unresolved path(s) or empty table(s)" % bad)
    return 1 if bad else 0


# ===========================================================================
# 8. CORPUS SWEEP
# ===========================================================================

# `nproc' honours this process's affinity mask but not a cgroup CPU quota, so
# an uncapped default can oversubscribe a container several times over.
JOBS_CAP = 12


def default_jobs():
    return min(len(os.sched_getaffinity(0)), JOBS_CAP)


def corpus_files(d, label, expect):
    """The .litmus files of one corpus, with its census asserted BEFORE the sweep.

    `pass == total' is vacuously true over zero tests, so a directory that is
    missing, empty or short is a refusal here rather than a smaller sweep that
    still passes."""
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
    """The x86_64 het corpus, regenerated into [dst].

    It is generated on demand rather than committed (hetlitmus/tests/het/
    generate-x86.sh says why), so every run rebuilds it."""
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
    """Check one corpus in a worker pool; print its table and TALLY line.

    Returns (pass, total).  Every non-PASS test's own output is written into
    [diffs] and echoed, so a failure is never reduced to a count."""
    print("\n===== HIP source faithfulness: %s =====" % label)
    print("%-42s | %s" % ("test", "verdict"))
    print("-" * 43 + "+---------")
    rows = []
    try:
        with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as pool:
            for verdict, name, out in pool.map(_sweep_one, files):
                rows.append((name, verdict, out))
    except concurrent.futures.BrokenExecutor as e:
        # _sweep_one turns a raising worker into that test's error verdict; a
        # worker killed outright never reaches it, and the tests it held have no
        # verdict at all, so the corpus is refused rather than tallied short.
        raise GateError("a sweep worker died without raising, breaking the pool "
                        "after %d of %d %s test(s): %s"
                        % (len(rows), len(files), label, e))
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


def sweep(gpu_dir, x86_dir, jobs):
    """Both corpora, each against its pinned census.

    X86_HET_N counts the x86_64 het rendering this lane emits, NOT the AArch64
    corpus ptxcheck.py reads: the same shapes, a different CPU column, and every
    count printed here says which."""
    tmp = None
    try:
        # Both censuses are asserted before a single test runs: a corpus that is
        # not there cannot be reported as a corpus that passed.
        gpu_files = corpus_files(gpu_dir, "gpu-only", GPU_ONLY_N)
        if x86_dir is None:
            tmp = tempfile.mkdtemp(prefix="hipsrccheck-x86.")
            x86_dir = regen_x86(os.path.join(tmp, "corpus"))
        x86_files = corpus_files(x86_dir, "x86_64 het", X86_HET_N)
        print("===== HIP SOURCE GATE: %d gpu-only + %d x86_64 het renders ====="
              % (GPU_ONLY_N, X86_HET_N))
        print("  gpu-only    %s" % gpu_dir)
        print("  x86_64 het  %s%s" % (x86_dir, " (generated)" if tmp else ""))
        print("  workers     %d" % jobs)
        diffs = tempfile.mkdtemp(prefix="hipsrccheck-diffs.")
        gp, gt = sweep_dir(gpu_files, "gpu-only", jobs, diffs)
        xp, xt = sweep_dir(x86_files, "x86_64 het", jobs, diffs)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    ok = (gp, gt) == (GPU_ONLY_N, GPU_ONLY_N) and (xp, xt) == (X86_HET_N, X86_HET_N)
    print("HIP SOURCE GATE: %s -- gpu-only %d/%d, x86_64 het %d/%d "
          "(the x86_64 rendering of the het corpus, not the AArch64 one)"
          % ("PASS" if ok else "FAILED", gp, gt, xp, xt))
    if ok:
        shutil.rmtree(diffs, ignore_errors=True)
    return 0 if ok else 1


# ===========================================================================
# 9. BITE  (every check reddened on a fresh render)
# ===========================================================================

# The two renders the injections are made from.  MP-sys-fence is the gpu-only
# shape carrying both fences, both kinds of model op and two __out slots;
# 2+2W-cg-sys-fence-2s-x86_64 is the het shape with two observer lanes, a GPU
# test lane carrying two tagged stores across a fence, and a tagged CPU column
# with an MFENCE between its stores.
BITE_GPU = "MP-sys-fence"
BITE_HET = "2+2W-cg-sys-fence-2s-x86_64"
# The annotations no corpus test carries (litmus/HipLang.ml maps them, so an
# injection into a corpus render can never reach their rows).
SYNTH = {
    "F-acqrel-sys": "f[acq_rel,sys]",
    "F-relaxed-sys": "f[relaxed,sys]",
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


def sub(path, old, new, count=1):
    """Replace [old] in [path].  An absent anchor is a hard exit: an injection
    that changes nothing would report a pass for a corruption the gate never
    saw."""
    s = open(path).read()
    if old not in s:
        raise GateError("--bite: anchor %r absent from %s -- the injection would "
                        "have been a no-op" % (old, path))
    open(path, "w").write(s.replace(old, new, count))


def lane_span(src, blk):
    """(start, end) of the guarded block `blockIdx.x == blk' in a kernel."""
    head = "if (blockIdx.x == %d && threadIdx.x == 0) {" % blk
    i = src.find(head)
    if i < 0:
        raise GateError("--bite: no lane %d in the render" % blk)
    j = src.find("\n  if (blockIdx.x", i + 1)
    return i, (j if j > 0 else len(src))


def sub_lane(path, blk, old, new, count=1):
    """Replace [old] inside lane [blk] only, so an injection lands on the lane
    it is meant for and the failure has to name that one."""
    src = open(path).read()
    i, j = lane_span(src, blk)
    body = src[i:j]
    if old not in body:
        raise GateError("--bite: anchor %r absent from lane %d of %s"
                        % (old, blk, path))
    open(path, "w").write(src[:i] + body.replace(old, new, count) + src[j:])


class Bites:
    """The tally of one --bite run: an injection that does not redden its own
    assertion, and one that reddens something else, are counted apart."""

    def __init__(self):
        self.n = self.k = self.bad = self.wrong = self.green = self.red = 0
        self.work = None

    def fresh(self, tag, src):
        """A pristine copy of [src] in its own directory, so a bite never reads
        the previous bite's still-corrupt artifact."""
        self.k += 1
        d = os.path.join(self.work, "bite%02d-%s" % (self.k, tag))
        os.makedirs(d)
        dst = os.path.join(d, os.path.basename(src))
        shutil.copyfile(src, dst)
        return dst

    def record(self, label, want_rc, want, rc, out, orig=None, cur=None):
        self.n += 1
        if orig is not None and open(orig, "rb").read() == open(cur, "rb").read():
            print("  *** VACUOUS BITE: the injection changed nothing    [%s]" % label)
            self.bad += 1
            return False
        if rc != want_rc:
            print("  *** WRONG EXIT [%s] exit=%d (expect %d)" % (label, rc, want_rc))
            for l in out.splitlines()[:6]:
                print("      %s" % l)
            self.bad += 1
            return False
        hit = [l for l in out.splitlines() if want in l]
        if not hit:
            print("  *** WRONG REASON [%s] exit=%d, but no line named %r"
                  % (label, rc, want))
            for l in out.splitlines():
                if l.startswith("FAIL") or l.startswith("COMPLETENESS") \
                        or l.startswith("ERROR"):
                    print("      %s" % l)
            self.wrong += 1
            self.bad += 1
            return False
        print("  OK exit=%d  [%s]" % (rc, label))
        print("     matched: %s" % hit[0].strip()[:140])
        if want_rc == 0:
            self.green += 1
        else:
            self.red += 1
        return True

    def check(self, label, want_rc, want, litmus, hip=None, cpu_c=None,
              orig=None, cur=None):
        rc, out = run_check(litmus, hip=hip, cpu_c=cpu_c)
        return self.record(label, want_rc, want, rc, out, orig=orig,
                           cur=cur if cur is not None else hip)


def _worker_dies(_litmus_path):
    """A sweep worker that dies without raising, which --bite puts in the pool:
    _sweep_one's handler never sees it, and the pool breaks instead."""
    os._exit(1)


def mkdir(d):
    """litmus7 refuses an output directory that does not exist."""
    os.makedirs(d, exist_ok=True)
    return d


def synth_carrier(d, name):
    """A .litmus for an annotation the corpus does not carry, so the rows that
    map it cannot rot unbitten."""
    p = os.path.join(d, name + ".litmus")
    with open(p, "w") as fh:
        fh.write(SYNTH_BODY % (name, SYNTH[name], SYNTH[name]))
    return p


def corpus_slice(src_dir, dst, names):
    """A corpus directory holding only [names], which is what a census injection
    needs: the sweep asserts the census before it reads a single test."""
    os.makedirs(dst)
    for n in names:
        shutil.copyfile(os.path.join(src_dir, n + ".litmus"),
                        os.path.join(dst, n + ".litmus"))
    return dst


def bite(tmp):
    """Every check on a fresh render, on the corruption it exists to catch.

    Exit codes are the contract, so each injection names the code it owes as
    well as the assertion: 1 is a render that differs from its .litmus, 2 is a
    construct the gate has no model for and must refuse rather than compare."""
    b = Bites()
    b.work = os.path.join(tmp, "bites")
    os.makedirs(b.work)
    corpus = regen_x86(os.path.join(tmp, "x86"))
    het_l = os.path.join(corpus, BITE_HET + ".litmus")
    gpu_l = os.path.join(GPU_ONLY_DIR, BITE_GPU + ".litmus")
    g_hip, _ = emit_harness(gpu_l, mkdir(os.path.join(tmp, "gpu")))
    h_hip, h_cpu = emit_harness(het_l, mkdir(os.path.join(tmp, "het")))
    if h_cpu is None:
        raise GateError("--bite: %s emitted no _cpu.c" % BITE_HET)

    print("===== HIP SOURCE GATE BITE: the clean controls, then every check =====")
    print("  gpu-only render %s" % g_hip)
    print("  het render      %s" % h_hip)

    print("\n-- clean controls (an injection is only evidence against a green base) --")
    b.record("gpu-only control (unmodified render)", 0, "RESULT: PASS",
             *run_check(gpu_l, hip=g_hip))
    b.record("het control (unmodified render)", 0, "RESULT: PASS",
             *run_check(het_l, hip=h_hip, cpu_c=h_cpu))

    # ---- the gpu-only render: constants, comment, operands, __out -----------
    print("\n-- gpu-only: the annotation, the comment and the result slot --")
    w = b.fresh("scope", g_hip)
    sub(w, "__hip_atomic_store(x, 1, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM)",
        "__hip_atomic_store(x, 1, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_WORKGROUP)")
    b.check("store scope NARROWED sys -> cta", 1, "observed w[relaxed,cta]",
            gpu_l, hip=w, orig=g_hip)

    w = b.fresh("order", g_hip)
    sub(w, "r1 = __hip_atomic_load(x, __ATOMIC_RELAXED,",
        "r1 = __hip_atomic_load(x, __ATOMIC_ACQUIRE,")
    b.check("load order STRENGTHENED, its comment left intact", 1,
            "observed r[acquire,sys]", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("comment-order", g_hip)
    sub(w, "// w[relaxed,sys] x 1", "// w[release,sys] x 1")
    b.check("the traceability comment's ORDER edited, nothing else", 1,
            "comment says w[release,sys]", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("comment-operand", g_hip)
    sub(w, "// r[relaxed,sys] r0 y", "// r[relaxed,sys] r0 x")
    b.check("the traceability comment's OPERAND edited, nothing else", 1,
            "load reads 'x'", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("fence-gone", g_hip)
    sub(w, '    __builtin_amdgcn_fence(__ATOMIC_SEQ_CST, ""); // f[sc,sys]\n', "")
    b.check("the fence line DELETED", 1, "expected f[sc,sys]", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("fence-noop", g_hip)
    sub(w, '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, ""); // f[sc,sys]',
        "// f[sc,sys] (relaxed fence = no-op; nothing emitted)")
    b.check("the fence replaced by the relaxed no-op comment (nothing emitted)",
            2, "renders f[sc,sys] as a comment and emits nothing",
            gpu_l, hip=w, orig=g_hip)

    w = b.fresh("store-gone", g_hip)
    sub(w, "    __hip_atomic_store(y, 1, __ATOMIC_RELAXED, "
           "__HIP_MEMORY_SCOPE_SYSTEM);\n", "")
    b.check("a model store DELETED, its comment left behind", 1,
            "observed comment w[relaxed,sys] with no call", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("out-gone", g_hip)
    sub(w, "    __out[1 * 4 + 1] = r1;\n", "")
    b.check("a gpu-only __out result slot DELETED", 1,
            "expected __out[1 * 4 + 1]=r1", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("out-dup", g_hip)
    sub(w, "    __out[1 * 4 + 1] = r1;\n",
        "    __out[1 * 4 + 1] = r1;\n    __out[1 * 4 + 1] = r1;\n")
    b.check("a gpu-only __out result slot DUPLICATED", 1,
            "multiset expected [] observed [('out', 1, 4, 1, 'r1')]",
            gpu_l, hip=w, orig=g_hip)

    w = b.fresh("out-reindex", g_hip)
    sub(w, "__out[1 * 4 + 1] = r1;", "__out[1 * 4 + 2] = r1;")
    b.check("a gpu-only __out result slot RE-INDEXED (the read reaches another "
            "slot of the same proc)", 1, "observed __out[1 * 4 + 2]=r1",
            gpu_l, hip=w, orig=g_hip)

    print("\n-- constants no mapping row accounts for (a refusal, not a compare) --")
    w = b.fresh("order-const", g_hip)
    sub(w, "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM)",
        "__ATOMIC_CONSUME, __HIP_MEMORY_SCOPE_SYSTEM)")
    b.check("a memory-order constant HipLang.ml never writes (__ATOMIC_CONSUME)",
            2, "unknown memory-order constant", gpu_l, hip=w, orig=g_hip)

    w = b.fresh("fence-scope", g_hip)
    sub(w, '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "")',
        '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "system")')
    b.check("the fence's sync scope NAMED (an unnamed one is system scope, so a "
            "name narrows the fence)", 2, "unknown AMDHSA sync-scope string "
            "'system'", gpu_l, hip=w, orig=g_hip)

    # ---- constructs the gate has no model for -------------------------------
    print("\n-- constructs no anchor accounts for (each a refusal, not a compare) --")
    for tag, line, want, label in (
            ("threadfence", "    __threadfence();\n", "__threadfence",
             "a stray __threadfence() in a lane"),
            ("inline-asm", '    asm volatile("" ::: "memory");\n', "asm, volatile",
             "inline asm in a lane (the premise the source-level read rests on)"),
            ("volatile-st", "    *(volatile int*)x = 7;\n", "volatile",
             "a stray volatile store in a lane"),
            ("builtin", "    __builtin_nontemporal_store(1, x);\n",
             "__builtin_nontemporal_store", "an unknown builtin in a lane")):
        w = b.fresh(tag, g_hip)
        sub(w, "    // w[relaxed,sys] x 1\n", line + "    // w[relaxed,sys] x 1\n")
        b.check(label, 2, want, gpu_l, hip=w, orig=g_hip)

    # ---- het: lanes, scaffolding, slot addressing, loop structure -----------
    print("\n-- het: the lane plan and the scaffolding --")
    w = b.fresh("lane-gone", h_hip)
    src = open(w).read()
    i, j = lane_span(src, 0)
    open(w, "w").write(src[:i] + src[j:])
    b.check("a whole TEST lane DELETED", 1,
            "kernel has 0 barrier-joining lane(s), the lane plan has 1",
            het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("rdv-narrow", h_hip)
    sub_lane(w, 0, "(void)__hip_atomic_fetch_add((barrier), 1, __ATOMIC_SEQ_CST, "
                   "__HIP_MEMORY_SCOPE_SYSTEM)",
             "(void)__hip_atomic_fetch_add((barrier), 1, __ATOMIC_SEQ_CST, "
             "__HIP_MEMORY_SCOPE_AGENT)")
    b.check("the rendezvous arrival NARROWED sys -> gpu", 1,
            "observed rendezvous.fetch_add[sc,gpu]", het_l, hip=w, cpu_c=h_cpu,
            orig=h_hip)

    w = b.fresh("rdv-by-2", h_hip)
    sub_lane(w, 0, "__hip_atomic_fetch_add((barrier), 1,",
             "__hip_atomic_fetch_add((barrier), 2,")
    b.check("the rendezvous arriving by 2 (NPART then names no lane population)",
            1, "the rendezvous arrives by 2", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("rdv-ptr", h_hip)
    sub_lane(w, 0, "__hip_atomic_fetch_add((barrier), 1,",
             "__hip_atomic_fetch_add((_spin_bar), 1,")
    b.check("the rendezvous counting on the spin word instead of the barrier", 1,
            "the rendezvous counts on", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("bump-name", h_hip)
    sub_lane(w, 0, "het_scratch_bump(_gpu_done);", "het_scratch_bump(_scratch_loc);")
    b.check("the lane's completion bump RENAMED off _gpu_done (the stress "
            "workgroups stop learning the lane finished)", 1,
            "completion bump names _scratch_loc", het_l, hip=w, cpu_c=h_cpu,
            orig=h_hip)

    w = b.fresh("stress-store", h_hip)
    sub(w, "  if (blockIdx.x >= HET_TEST_BLOCKS) {\n",
        "  if (blockIdx.x >= HET_TEST_BLOCKS) {\n    __hip_atomic_store(x, 9, "
        "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);\n")
    b.check("an atomic store hidden in the stress region, outside every lane", 1,
            "atomic-or-fence construct(s) outside every lane", het_l, hip=w,
            cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("store-gone", h_hip)
    sub_lane(w, 0, "      __hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1, "
                   "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);\n", "")
    b.check("a store deleted from the test lane (the failure must name it)",
            1, "2+2W-cg-sys-fence-2s-x86_64:P1 anchor stream differs",
            het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("store-value", h_hip)
    sub_lane(w, 0, "__hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1,",
             "__hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 7,")
    b.check("a store writing a value the .litmus does not name", 1,
            "the call stores '7'", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    # The slot address is what pairs the two sides' iteration n; drop it and the
    # whole run races on one word, which no readout could take apart.
    w = b.fresh("slot-gone", h_hip)
    sub_lane(w, 0, "__hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1,",
             "__hip_atomic_store(x, 1,")
    b.check("a tested access DE-SLOTTED (the run races on one word)", 1,
            "not iteration _n's own slot", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("slot-frozen", h_hip)
    sub_lane(w, 0, "__hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1,",
             "__hip_atomic_store((x + (0)*HET_SLOT_STRIDE_WORDS), 1,")
    b.check("a tested access pinned to slot 0 on every iteration", 1,
            "not iteration _n's own slot", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    print("\n-- het: the per-iteration loop structure --")
    w = b.fresh("loop-test", h_hip)
    sub_lane(w, 0, "_n<SIZE_OF_TEST", "_n<1")
    b.check("a TEST lane's loop bound made a literal", 1,
            "the iteration loop counts to 1", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-pragma", h_hip)
    sub_lane(w, 0, "    #pragma unroll 1\n", "")
    b.check("`#pragma unroll 1' deleted (the tested ops may unroll)", 1,
            "is not opened by `#pragma unroll 1'", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-hoist", h_hip)
    st = ("      __hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1, "
          "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);\n")
    sub_lane(w, 0, st, "")
    sub_lane(w, 0, "    #pragma unroll 1\n", st + "    #pragma unroll 1\n")
    b.check("a tested store HOISTED out of the loop (it runs once per launch)", 1,
            "sits OUTSIDE the per-iteration loop", het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-rdv", h_hip)
    rdv = ("    (void)__hip_atomic_fetch_add((barrier), 1, __ATOMIC_SEQ_CST, "
           "__HIP_MEMORY_SCOPE_SYSTEM);\n")
    sub_lane(w, 0, rdv, "")
    sub_lane(w, 0, "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n",
             rdv + "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n")
    b.check("the rendezvous dragged INSIDE the loop (a barrier per tested access)",
            1, "sits INSIDE the per-iteration loop", het_l, hip=w,
            cpu_c=h_cpu, orig=h_hip)

    ops = ("      // w[relaxed,sys] x 1\n"
           "      __hip_atomic_store((x + (_n)*HET_SLOT_STRIDE_WORDS), 1, "
           "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);\n")
    w = b.fresh("loop-guard", h_hip)
    sub_lane(w, 0, ops, "      if (_n == 0) {\n" + ops + "      }\n")
    b.check("a test lane's store GUARDED inside the loop (its order, constants "
            "and comment all kept)", 1,
            "is guarded by `if (_n == 0) {' inside the loop", het_l, hip=w,
            cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-braceless", h_hip)
    sub_lane(w, 0, ops, ops.split("\n")[0] + "\n      if (_n == 0)\n"
             + ops.split("\n")[1] + "\n")
    b.check("the same guard written WITHOUT braces (brace depth alone reads it "
            "as ordinary lane code)", 1,
            "is guarded by `if (_n == 0)' inside the loop", het_l, hip=w,
            cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-nest", h_hip)
    st2 = ("      __hip_atomic_store((y + (_n)*HET_SLOT_STRIDE_WORDS), 2, "
           "__ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);\n")
    sub_lane(w, 0, st2, "      for (int _m=0; _m<1; ++_m) {\n" + st2
             + "      }\n")
    b.check("a tested store NESTED in a one-trip loop inside the loop", 1,
            "is guarded by `for (int _m=0; _m<1; ++_m) {' inside the loop",
            het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-wrapped", h_hip)
    sub_lane(w, 0, "    #pragma unroll 1\n",
             "    if (_seed < 99) {\n    #pragma unroll 1\n")
    sub_lane(w, 0, "    }\n    het_scratch_bump(_gpu_done);\n",
             "    }\n    }\n    het_scratch_bump(_gpu_done);\n")
    b.check("the whole iteration loop WRAPPED in a conditional", 1,
            "the iteration loop is itself guarded by `if (_seed < 99) {'",
            het_l, hip=w, cpu_c=h_cpu, orig=h_hip)

    w = b.fresh("loop-jump", h_hip)
    sub_lane(w, 0, "      // w[relaxed,sys] y 2\n",
             "      if (_n == 3) continue;\n      // w[relaxed,sys] y 2\n")
    b.check("a `continue' inside the loop (the ops keep their place and stop "
            "running on every iteration)", 1,
            "can skip the rest of an iteration", het_l, hip=w, cpu_c=h_cpu,
            orig=h_hip)

    w = b.fresh("loop-bump-guard", h_hip)
    sub_lane(w, 0, "    het_scratch_bump(_gpu_done);\n",
             "    if (_seed > 0) {\n      het_scratch_bump(_gpu_done);\n    }\n")
    b.check("the completion bump GUARDED outside the loop", 1,
            "once-per-launch scaffolding may not run at all", het_l, hip=w,
            cpu_c=h_cpu, orig=h_hip)

    # ---- the x86_64 CPU column ---------------------------------------------
    print("\n-- het: the x86_64 CPU column against its _cpu.c asm block --")
    w = b.fresh("mfence", h_cpu)
    sub(w, '"mfence\\n"\n', "")
    b.check("the MFENCE deleted from the compiled body", 1,
            "expected fence mfence", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("cpu-store", h_cpu)
    sub(w, '"movl $1,%[y]\\n"\n', "")
    b.check("a CPU store deleted from the compiled body", 1,
            "expected store movl y 1", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("cpu-store-value", h_cpu)
    sub(w, '"movl $1,%[y]\\n"', '"movl $9,%[y]\\n"')
    b.check("a CPU store writing a value the .litmus does not name", 1,
            "observed store movl y 9", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("cpu-store-loc", h_cpu)
    sub(w, '"movl $1,%[y]\\n"', '"movl $1,%[x]\\n"')
    b.check("a CPU store re-pointed at another location", 1,
            "observed store movl x 1", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("lock-incl", h_cpu)
    sub(w, '"mfence\\n"', '"lock incl %[x]\\n"')
    b.check("a `lock incl' spliced into a compiled body", 2,
            "outside the emitted vocabulary", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("asm-two-ins", h_cpu)
    sub(w, '"mfence\\n"\n', '"mfence\\nsfence\\n"\n')
    b.check("two instructions in ONE asm literal", 2,
            "carries 2 instructions in one asm literal", het_l, hip=h_hip,
            cpu_c=w, orig=h_cpu, cur=w)

    w = b.fresh("asm-quote", h_cpu)
    sub(w, '"mfence\\n"\n', '"mfence\\n\n')
    b.check("an asm template with an UNPAIRED quote", 2,
            "unpaired quote in its asm template", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    w = b.fresh("asm-unterminated", h_cpu)
    sub(w, '"mfence\\n"\n', '"mfence\\n"\n"sfence"\n')
    b.check("an asm literal no newline escape closes (it concatenates)", 2,
            "no newline escape closes", het_l, hip=h_hip, cpu_c=w,
            orig=h_cpu, cur=w)

    # ---- the .litmus side ---------------------------------------------------
    print("\n-- an annotation the mapping tables have no row for --")
    bad_l = os.path.join(b.work, "consume.litmus")
    open(bad_l, "w").write(SYNTH_BODY % ("UNKNOWN-anno", "w[consume,sys] x 1",
                                         "r[acquire,sys] r0 y"))
    b.record("an annotation order nothing maps (w[consume,sys])", 2,
             "unknown memory order 'consume'", *run_check(bad_l))

    # ---- the two rows no corpus test carries --------------------------------
    print("\n-- the fence rows no corpus test carries, green then bitten --")
    sdir = os.path.join(b.work, "synth")
    os.makedirs(sdir)
    for name in sorted(SYNTH):
        sl = synth_carrier(sdir, name)
        shp, _ = emit_harness(sl, mkdir(os.path.join(sdir, "out-" + name)))
        b.record("%s carrier (control)" % SYNTH[name], 0, "RESULT: PASS",
                 *run_check(sl, hip=shp))
        if name == "F-acqrel-sys":
            w = b.fresh("acqrel", shp)
            sub(w, "__ATOMIC_ACQ_REL", "__ATOMIC_ACQUIRE")
            b.check("f[acq_rel,sys] weakened to an acquire fence", 1,
                    "observed f[acquire,sys]", sl, hip=w, orig=shp)
        else:
            w = b.fresh("relaxed-order", shp)
            sub(w, "// f[relaxed,sys] (relaxed", "// f[sc,sys] (relaxed")
            b.check("the no-op fence comment's ORDER edited (nothing is emitted "
                    "there, so the comment is the whole evidence)", 2,
                    "renders f[sc,sys] as a comment and emits nothing", sl,
                    hip=w, orig=shp)
            w = b.fresh("relaxed-scope", shp)
            sub(w, "// f[relaxed,sys] (relaxed", "// f[relaxed,bogus] (relaxed")
            b.check("the no-op fence comment's SCOPE edited", 2,
                    "the no-op fence comment names scope", sl, hip=w, orig=shp)

    # ---- the sweep's own census, and the guard ------------------------------
    print("\n-- the census the sweep asserts before it runs a single test --")
    empty = os.path.join(b.work, "empty")
    os.makedirs(empty)
    b.record("an EMPTY gpu-only directory swept as if it were the corpus", 3,
             "holds 0 .litmus, expected %d" % GPU_ONLY_N,
             *capture(lambda: sweep(empty, corpus, 2)))

    trio = [BITE_HET, "2+2W-cg-sys-relaxed-x86_64", "MP-cg-sys-relaxed-x86_64"]
    short = corpus_slice(corpus, os.path.join(b.work, "short"), trio)
    b.record("an x86_64 het corpus SHORT of its census", 3,
             "holds 3 .litmus, expected %d" % X86_HET_N,
             *capture(lambda: sweep(GPU_ONLY_DIR, short, 2)))

    b.record("a sweep worker KILLED, which breaks the pool without raising", 3,
             "a sweep worker died without raising",
             *capture(lambda: sweep(GPU_ONLY_DIR, corpus, 2),
                      _sweep_one=_worker_dies))

    print("\n-- the guard report, which vouches for the tables --")
    b.record("the memory-order table EMPTIED", 1, "*** empty table ***",
             *capture(guard_report, HIP_ORDER={}))
    b.record("litmus7 UNRESOLVABLE (the guard resolves it)", 1, "*** MISSING ***",
             *capture(guard_report, LITMUS7=os.path.join(REPO, "no", "such", "litmus7")))

    print()
    if b.n == 0:
        print("HIP SOURCE GATE BITE FAILED: no injection ran")
        return 1
    if b.bad:
        print("HIP SOURCE GATE BITE FAILED: %d of %d assertion(s) did not hold "
              "(%d reddened for the wrong reason)" % (b.bad, b.n, b.wrong))
        return 1
    print("HIP SOURCE GATE BITE OK: %d injections, each reddening its own "
          "assertion, 0 for a wrong reason; %d clean control(s) green"
          % (b.red, b.green))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus HIP source gate: .litmus annotation vs emitted HIP")
    ap.add_argument("litmus", nargs="?", help=".litmus test path")
    ap.add_argument("--hip-src", help="read this .hip instead of emitting one")
    ap.add_argument("--cpu-c", help="read this _cpu.c instead of emitting one")
    ap.add_argument("--all", action="store_true",
                    help="sweep both corpora (%d gpu-only + %d x86_64 het)"
                         % (GPU_ONLY_N, X86_HET_N))
    ap.add_argument("--gpu-dir", default=GPU_ONLY_DIR,
                    help="the gpu-only corpus to sweep")
    ap.add_argument("--x86-dir",
                    help="an x86_64 het corpus to sweep (default: regenerate one)")
    ap.add_argument("--jobs", type=int, default=default_jobs(),
                    help="sweep workers (default: CPUs, capped at %d)" % JOBS_CAP)
    ap.add_argument("--bite", action="store_true",
                    help="prove every check FAILS on the corruption it is for")
    ap.add_argument("--guard", action="store_true",
                    help="print the vocabulary and paths, then exit")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    if args.guard:
        sys.exit(guard_report())
    try:
        if args.bite:
            tmp = tempfile.mkdtemp(prefix="hipsrccheck-bite.")
            try:
                sys.exit(bite(tmp))
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        if args.all:
            sys.exit(sweep(args.gpu_dir, args.x86_dir, max(1, args.jobs)))
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        sys.exit(2)
    except GateError as e:
        print("ERROR: %s" % e)
        sys.exit(3)
    if not args.litmus:
        print("ERROR: no .litmus given (and none of --all/--bite/--guard asked for)")
        sys.exit(3)
    rc, out = run_check(args.litmus, hip=args.hip_src, cpu_c=args.cpu_c,
                        verbose=not args.quiet)
    sys.stdout.write(out)
    sys.exit(rc)


if __name__ == "__main__":
    main()
