#!/usr/bin/env python3
"""
hipsrccheck.py -- the HIP source gate: an emitted HIP harness carries exactly
the memory ops its .litmus annotates, with the annotated kind, order and scope.

    .litmus annotation --(litmus/HipLang.ml)--> .hip source --(this)-->
        expected (kind,order,scope) == the emitted builtin's constants, its
        traceability comment and its operands, all three agreeing.

WHAT IT PROVES.  The HIP path carries no inline assembly: every memory
primitive is a compiler-owned source construct, so the annotation survives into
the source as a constant that can be read back without naming a GPU generation.
Per proc (gpu-only) or per barrier-joining lane (het) the model ops appear in
.litmus column order, each as its mapped builtin with the mapped __ATOMIC_* and
__HIP_MEMORY_SCOPE_* constants; the het scaffolding around them -- system-scope
rendezvous, window-opener spin, observer snoop, result stores -- is exactly what
the lane plan predicts; the x86_64 CPU column is rendered into the _cpu.c asm
block mnemonic for mnemonic; and no other atomic-or-fence construct appears
anywhere in the kernel.

WHAT IT DOES NOT PROVE.  Nothing about what a compiler makes of those
constructs: no ISA is read, no code is generated, no kernel runs.  It is also
a parser of the .litmus CPU column's rendering only -- the per-iteration
clflush/prefetcht0 preload and the CPU observer's plain volatile read touch the
same locations and are outside its vocabulary by design
(litmus/het-runtime/het_cpu_stress.h).

CORPUS.  gpu-only tests plus the x86_64 het rendering that
hetlitmus/tests/het/generate-x86.sh writes -- NOT the AArch64 het corpus, whose
CPU column this lane never emits.  Every printed count names which.

ptxcheck.py is the NVIDIA twin (hetlitmus/docs/faithfulness.md).  It is
imported, never modified: its .litmus parsers, its GPU mapping table and its
lane plan are the expected side here too.  Two of its halves cannot be reused
and are re-supplied below -- cpu_ops_of_column reads AArch64 mnemonics, and
load_control_map resolves control-map.csv, which a generated x86 corpus does
not carry (it carries control-map-amd.csv, the map litmus/hetCpuFront.ml's
X86_64 arm reads).

Usage:
  hipsrccheck.py TEST.litmus [--hip-src F] [--cpu-c F] [-q]
  hipsrccheck.py --guard

--hip-src/--cpu-c read a pre-existing render instead of emitting one; with
--hip-src alone the sibling <name>_cpu.c beside it is used when present.

Exit 0 = PASS, 1 = FAIL (ordered diff), 2 = completeness hard-fail, 3 = error.
"""

import argparse
import importlib.util
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

# The x86_64 het lane reads this map, not control-map.csv (litmus/hetCpuFront.ml).
CONTROL_MAP = "control-map-amd.csv"
# Asserted verbatim, as litmus/hetControlMap.ml asserts it: the retired 8-column
# schema binds Mu to a verdict string, so a file that does not open with this
# line is refused rather than read.
CONTROL_MAP_HEADER = "Test,Mu,MuRule,MuAlt,MuRelaxed,Canary"


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

# The x86-64 CPU-column table, matching litmus/hetCpuBodyX86.ml nodes_of arm
# for arm, so an instruction the emitter would refuse also hard-fails here.  A
# MOV is classified by its operand shape, in AT&T order (source first).  The
# emitted mnemonic is `movq' whatever width the column names: an aligned
# 8-byte access is one access [IntelSDM 9.1.1].
X86_MOV = {"mov", "movb", "movw", "movl", "movq"}
X86_FENCE = {"mfence", "sfence", "lfence"}
X86_CONSUMED = {"nop"}
X86_EMITTED_MOV = "movq"

# Device helpers a het kernel may carry (litmus/het-runtime/het_stress.h).  A
# helper outside this set hard-fails: an unlisted one is an unmodelled memory
# primitive.
DEVICE_HELPERS = {
    "het_rng_t", "het_rng_init", "het_rng_next", "het_rng_pct",
    "het_scratch_read", "het_scratch_bump", "het_scratch_max",
    "het_do_stress", "het_spin",
}

# Every atomic-or-fence-shaped token, so one appearing outside the modelled
# anchors is surfaced rather than skipped.  Scaffolding may be invisible only
# because it is unordered device-scope traffic; an ordered or scoped construct
# the gate has no model for is not scaffolding.
ATOMIC_SHAPED = re.compile(
    r'(__hip_atomic_\w+|__builtin_amdgcn_\w+|__threadfence\w*|__atomic_\w+'
    r'|__sync_\w+|\batomic[A-Za-z_]\w*|\bhet_[a-z]\w*)')


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


# An x86-64 memory operand as the het vocabulary spells it: a bare global.  A
# register deref is what hetCpuBodyX86 resolves through reg_env, which this has
# no access to, so it is refused rather than guessed at -- narrower than the
# emitter, which fails closed on a legal test rather than open on an illegal one.
X86_MEM = re.compile(r'^\(([A-Za-z_]\w*)\)$')
X86_IMM = re.compile(r'^\$-?\d+$')
X86_REG = re.compile(r'^%\w+$')


def x86_ops_of_column(cells):
    """Ordered (kind, mnemonic, global) for an x86_64 CPU column's cells.

    kind is 'store' | 'load' | 'fence'; the mnemonic is the one the emitted asm
    block carries, so a MOV widens to movq and a fence keeps its own spelling.
    An immediate MOV into a register is Consumed -- the tag replaces the value
    it set, which reaches the asm block as an input operand -- so it is
    recognized and not compared.  Completeness guard: anything else hard-fails,
    exactly where hetCpuBodyX86 would refuse to classify it."""
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
            ops.append(('fence', mn, None))
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
        if X86_REG.match(dst) and X86_IMM.match(src):
            continue                      # folded: the tag replaces this value
        if X86_REG.match(dst) and X86_MEM.match(src):
            ops.append(('load', X86_EMITTED_MOV, X86_MEM.match(src).group(1)))
        elif X86_MEM.match(dst) and (X86_IMM.match(src) or X86_REG.match(src)):
            ops.append(('store', X86_EMITTED_MOV, X86_MEM.match(dst).group(1)))
        else:
            raise CompletenessError(
                "x86_64 MOV %r has an operand shape outside the het vocabulary "
                "(a bare global `(x)' on one side, an immediate or a register "
                "on the other)" % c)
    return ops


def load_control_map_amd(litmus_path):
    """(mu, canary) for this test from CONTROL_MAP beside it.

    A missing file is exit 2, NEVER a quiet (None, None): a generated x86
    corpus that lost its map would otherwise hand every test a single-instance
    lane plan, and no lane of the positive control would be checked.  A row
    that names no mu and is its own canary is legal and stays legal, which is
    why "no row" and "no file" are two different refusals."""
    d = os.path.dirname(os.path.abspath(litmus_path))
    f = os.path.join(d, CONTROL_MAP)
    if not os.path.exists(f):
        raise CompletenessError(
            "no %s beside %s -- the AMD lane reads that map, and without it the "
            "lane plan would silently collapse to a single instance" % (CONTROL_MAP, d))
    name = ptx.litmus_name(ptx.read_litmus(litmus_path))
    rows, header = [], None
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if header is None:
                header = line
                continue
            rows.append(line.split(','))
    if header != CONTROL_MAP_HEADER:
        raise CompletenessError(
            "%s header is %r, expected %r" % (f, header, CONTROL_MAP_HEADER))
    for c in rows:
        if len(c) == 6 and c[0] == name:
            return (c[1] if c[1] != 'none' else None,
                    c[5] if c[5] != 'self' else None)
    raise CompletenessError(
        "%s has no row for %s -- a test the map does not name has no lane plan "
        "the gate can check" % (f, name))


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
                gpu=gpu, cpu=cpu, cells=dict(cells),
                obs=ptx.condition_locations(text))


def het_instances(litmus_path):
    """The instances this harness co-runs, in emission order, each with the C
    identifier prefix litmus/hetEmit.ml gives it.

      mu and canary  ->  [T, mu(T), canary]   a test off the lattice floor
      canary only    ->  [T, canary]          a test at the floor
      neither        ->  [T]                  a test that IS the canary, which
                                              cannot co-run itself and is
                                              emitted with no prefix at all"""
    d = os.path.dirname(os.path.abspath(litmus_path))
    t = instance_of(litmus_path)
    t['role'], t['pre'] = 'T', 't_'
    insts = [t]
    mu, can = load_control_map_amd(litmus_path)
    for n, role, pre in ((mu, "mu(T)", "mu_"), (can, "canary", "can_")):
        if not n:
            continue
        p = os.path.join(d, n + ".litmus")
        if not os.path.exists(p):
            raise CompletenessError(
                "%s names %r as a control of %s but %s does not exist -- the "
                "harness cannot be co-running it" % (CONTROL_MAP, n, t['name'], p))
        i = instance_of(p)
        i['role'], i['pre'] = role, pre
        insts.append(i)
    if len(insts) == 1:
        insts[0]['pre'] = ''
    # A test whose mu(T) IS the canary co-runs that sibling twice, under two
    # prefixes, so an instance name is not a key.  The label carries the role
    # wherever the name repeats, and every lane is addressed by it.
    dup = Counter(i['name'] for i in insts)
    for i in insts:
        i['label'] = (i['name'] if dup[i['name']] == 1
                      else "%s(%s)" % (i['name'], i['role']))
    return insts


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
C_SPIN = re.compile(r'^het_spin\((.*)\);$')
C_BUMP = re.compile(r'^het_scratch_bump\((.*)\);$')
C_COMMENT = re.compile(r'^// ([wrf])\[(\w+),(\w+)\](?:\s+(.*))?$')
C_RESULT = re.compile(r'^(\w+)\[_n\] = \(uint64_t\)(\w+);$')
C_OBSDST = re.compile(r'^(\w+)\[_n\]$')
C_ALIAS = re.compile(
    r'^uint64_t\* (\w+) = (\w+);\s*/\* this instance\'s (\w+) \*/$')
C_OUT = re.compile(r'^__out\[\d+ \* \d+ \+ \d+\] = \w+;$')


class Anchor:
    """One recognized construct in a lane, with the tokens it accounts for."""

    def __init__(self, sig, tokens, **kw):
        self.sig = sig
        self.tokens = set(tokens)
        self.__dict__.update(kw)


def parse_lane(body, helpers, where):
    """The ordered anchors of one guarded block.

    An unrecognized line is legal only when every atomic-shaped or het_ token
    on it is a whitelisted device helper; otherwise the gate has no model for
    what that line does to memory and refuses."""
    anchors, pending = [], None

    def flush():
        nonlocal pending
        if pending is not None:
            anchors.append(Anchor(('orphan-comment',) + pending[:3], []))
            pending = None

    for raw in body:
        s = raw.strip()
        a = None
        m = C_COMMENT.match(s)
        if m and C_RELAXED_FENCE.match(s) is None:
            kind, order, scope, tail = m.group(1), m.group(2), m.group(3), m.group(4)
            if kind == 'f':
                # A fence's annotation trails its own call on the same line, so a
                # LEADING one is a store/load comment whose call went missing.
                flush()
                anchors.append(Anchor(('orphan-comment', 'f', order, scope), []))
                continue
            flush()
            # split(None, 1): on the tagged path the value field is an
            # expression carrying spaces, so only the first field is a token.
            pending = (kind, order, scope, (tail or '').split(None, 1))
            continue
        m = C_RELAXED_FENCE.match(s)
        if m:
            flush()
            anchors.append(Anchor(('fence', m.group(1), m.group(2)),
                                  [], emitted=False))
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
                ob = C_OBSDST.match(dst)
                if ob:
                    flush()
                    a = Anchor(('obs-ld', o, sc), ['__hip_atomic_load'],
                               buf=ob.group(1), ptr=args[0])
                else:
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
            m = C_SPIN.match(s)
            if m:
                flush()
                a = Anchor(('spin',), ['het_spin'],
                           bar=split_args(m.group(1))[0])
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
        if a is not None:
            allowed = helpers | a.tokens
            stray = [t for t in ATOMIC_SHAPED.findall(s) if t not in allowed]
            if stray:
                raise CompletenessError(
                    "%s carries %s outside the construct it renders: %r"
                    % (where, ", ".join(sorted(set(stray))), s))
            anchors.append(a)
            continue
        flush()
        m = C_ALIAS.match(s)
        if m:
            anchors.append(Anchor(('alias', m.group(1), m.group(2)), []))
            continue
        if C_OUT.match(s):
            continue
        stray = [t for t in ATOMIC_SHAPED.findall(s) if t not in helpers]
        if stray:
            raise CompletenessError(
                "%s carries an atomic-or-fence construct the gate has no model "
                "for (%s): %r" % (where, ", ".join(sorted(set(stray))), s))
    flush()
    return anchors


# ===========================================================================
# 5. _cpu.c READING  (the real x86_64 asm block only)
# ===========================================================================

X86_BLOCK = re.compile(r'#if defined\(__x86_64__\)(.*?)(?:^#else|^#endif)',
                       re.S | re.M)
X86_BODY = re.compile(r'^void het_run_(\w*?)P(\d+)\(', re.M)
X86_ASM = re.compile(r'asm __volatile__\((.*?)\n\s*:', re.S)
ASM_STR = re.compile(r'"([^"\n]*)\\n"')
A_STORE = re.compile(r'^(\w+)\s+%\[_v(\d+)\],\(%\[(\w+)\]\)$')
A_LOAD = re.compile(r'^(\w+)\s+\(%\[(\w+)\]\),%\[_t(\d+)\]$')


def x86_bodies(cpu_c_text, path):
    """Every tagged body in the real x86_64 block, as (prefix, proc, [ops]).

    finditer over the blocks AND over the asm string literals: C concatenates
    adjacent literals, so two instructions can share one source line, and a
    `search' would read only the first -- hiding an instruction appended to a
    body, i.e. a silently strengthened mutant."""
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
                    "%s: body het_run_%sP%s carries no asm __volatile__ block"
                    % (path, h.group(1), h.group(2)))
            ops, si, li = [], 0, 0
            for line in [l for blk_asm in asms for l in ASM_STR.findall(blk_asm)]:
                ins = line.strip()
                mn = ins.split()[0].lower() if ins else ''
                if mn in X86_FENCE:
                    if ins.lower() != mn:
                        raise CompletenessError(
                            "%s: fence %r carries operands" % (path, ins))
                    ops.append(('fence', mn, None))
                    continue
                m = A_STORE.match(ins)
                if m:
                    if int(m.group(2)) != si:
                        raise CompletenessError(
                            "%s: store %r is bound to _v%s, not to its ordinal "
                            "_v%d" % (path, ins, m.group(2), si))
                    si += 1
                    ops.append(('store', m.group(1).lower(), m.group(3)))
                    continue
                m = A_LOAD.match(ins)
                if m:
                    if int(m.group(3)) != li:
                        raise CompletenessError(
                            "%s: load %r is bound to _t%s, not to its ordinal "
                            "_t%d" % (path, ins, m.group(3), li))
                    li += 1
                    ops.append(('load', m.group(1).lower(), m.group(2)))
                    continue
                raise CompletenessError(
                    "%s: asm %r is outside the emitted vocabulary (movq store, "
                    "movq load, MFENCE|SFENCE|LFENCE)" % (path, ins))
            out.append((h.group(1), int(h.group(2)), ops))
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
    if k == 'obs-ld':
        return "observer.load[%s,%s]" % (sig[1], sig[2])
    if k == 'res':
        return "result_store %s=%s" % (sig[1], sig[2])
    if k == 'orphan-comment':
        return "comment %s[%s,%s] with no call" % (sig[1], sig[2], sig[3])
    if k == 'alias':
        return "alias %s=%s" % (sig[1], sig[2])
    return {'spin': 'het_spin', 'bump': 'het_scratch_bump'}[k]


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


TAG_VALUE = re.compile(r'^\(\(uint64_t\)\d+ \* \(_n \+ 1\) \+ \d+\)$')


def check_operands(result, anchors, cells, who, tagged):
    """Comment, constants and operands must agree with each other and with the
    .litmus cell that produced them.  The constants alone are what the stream
    compare sees, so a comment edited on its own would otherwise be invisible --
    and the comment is the only thing tying an emitted call back to its column."""
    model = [a for a in anchors if a.sig[0] in ('st', 'ld', 'fence')]
    if len(model) != len(cells):
        return                                   # the stream compare said so
    for a, cell in zip(model, cells):
        kind, order, scope, o1, o2 = cell
        if a.sig[0] == 'fence':
            if not getattr(a, 'emitted', True):
                continue                         # a relaxed fence is a comment
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
        if a.sig[0] == 'st':
            if tail[0] != o1 or a.ptr != o1:
                result.fail("%s: store names %r/%r, the .litmus cell stores to %r"
                            % (who, tail[0], a.ptr, o1))
            if tail[1] != a.val:
                result.fail("%s: store comment values %r, the call stores %r"
                            % (who, tail[1], a.val))
            elif tagged:
                if not TAG_VALUE.match(a.val):
                    result.fail("%s: store value %r is not the per-iteration tag"
                                % (who, a.val))
            elif a.val != o2:
                result.fail("%s: store writes %r, the .litmus cell writes %r"
                            % (who, a.val, o2))
        else:
            if tail[0] != o1 or a.dst != o1:
                result.fail("%s: load lands in %r/%r, the .litmus cell loads "
                            "into %r" % (who, tail[0], a.dst, o1))
            if tail[1] != o2 or a.ptr != o2:
                result.fail("%s: load reads %r/%r, the .litmus cell reads %r"
                            % (who, tail[1], a.ptr, o2))


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
        if check_stream(result, list(ops), anchors, who):
            check_operands(result, anchors, inst['cells'][pidx], who, tagged=False)


def check_het(result, insts, lanes):
    """One guarded block per barrier-joining lane, in emission order: for each
    instance its GPU test lanes in proc order, then its observer lane."""
    # het_lane_plan reads only gpu/obs/name, so it is fed the label as the
    # instance tag and every lane resolves back through it.
    plan = ptx.het_lane_plan([dict(gpu=i['gpu'], obs=i['obs'], name=i['label'])
                              for i in insts])
    pre_of = {i['label']: i['pre'] for i in insts}
    cells_of = {i['label']: i['cells'] for i in insts}
    names = ", ".join("%s:%s" % (l[3], "P%d" % l[1] if l[0] == 'test' else "obs")
                      for l in plan)
    if len(lanes) != len(plan):
        result.fail("kernel has %d barrier-joining lane(s), the lane plan has "
                    "%d (%s).  A MISSING lane on a control instance means the "
                    "harness reports a positive control it is not running."
                    % (len(lanes), len(plan), names))
        return
    result.note("  lane plan (x86_64 het): %d lane(s) -- %s" % (len(plan), names))
    for idx, ((blk, lane, _hdr, body), (kindl, pidx, payload, iname)) in \
            enumerate(zip(lanes, plan)):
        pre = pre_of[iname]
        who = ("%s:P%d" % (iname, pidx)) if kindl == 'test' else ("%s:obs" % iname)
        if (blk, lane) != (idx, 0):
            result.fail("%s runs in (workgroup %d, lane %d); the lane plan puts "
                        "it in (workgroup %d, lane 0)" % (who, blk, lane, idx))
        anchors = parse_lane(body, DEVICE_HELPERS, who)
        rdv = [('rdv-add', 'sc', 'sys'), ('rdv-spin', 'sc', 'sys')]
        if kindl == 'obs':
            expected = rdv + [('obs-ld', 'relaxed', 'sys')] * len(payload) + [('bump',)]
            if check_stream(result, expected, anchors, who):
                for loc, a in zip(payload, [a for a in anchors if a.sig[0] == 'obs-ld']):
                    if (a.buf, a.ptr) != (pre + "obsG_" + loc, pre + loc):
                        result.fail("%s: snoop records %s from %s; the observed "
                                    "location is %s, recorded into %s"
                                    % (who, a.buf, a.ptr, pre + loc,
                                       pre + "obsG_" + loc))
        else:
            cells = cells_of[iname][pidx]
            regs = []
            for k, _o, _s, o1, _o2 in cells:
                if k == 'r' and o1 not in regs:
                    regs.append(o1)
            expected = rdv + [('spin',)] + list(payload) \
                + [('res', "%sbufP%d_%d" % (pre, pidx, i), r)
                   for i, r in enumerate(regs)] + [('bump',)]
            for a in anchors:
                if a.sig[0] == 'alias' and a.sig[2] != pre + a.sig[1]:
                    result.fail("%s: alias binds %s to %s, not to this "
                                "instance's %s" % (who, a.sig[1], a.sig[2],
                                                   pre + a.sig[1]))
            model = [a for a in anchors if a.sig[0] != 'alias']
            if check_stream(result, expected, model, who):
                check_operands(result, model, cells, who, tagged=True)
        # The scaffolding's operands, which the anchor stream does not carry.
        # The window-opener aligns the test lanes of one instance and the
        # rendezvous joins the two devices; a spin handed the rendezvous word
        # would put a cross-device barrier around every tested access.
        for a in anchors:
            if a.sig[0] in ('rdv-add', 'rdv-spin') and a.ptr != '(barrier)':
                result.fail("%s: the rendezvous counts on %s, not on the shared "
                            "barrier" % (who, a.ptr))
            if a.sig[0] == 'rdv-add' and a.inc != '1':
                result.fail("%s: the rendezvous arrives by %s, so the lane count "
                            "NPART names no lane population" % (who, a.inc))
            if a.sig[0] == 'spin' and a.bar != '_spin_bar':
                result.fail("%s: the window-opener spins on %s, not on the "
                            "device-scope spin word" % (who, a.bar))
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


def check_cpu(result, insts, cpu_c_text, cpu_c_path):
    """The x86_64 CPU columns, ordered over instances, against the tagged bodies
    of the real asm block.  A co-run harness holds every instance's bodies in
    ONE such block, so a dropped MFENCE in the mutant reads exactly as one in T."""
    expected = [("%s:P%d" % (i['label'], p), i['pre'], p, ops)
                for i in insts for p, ops in i['cpu']]
    bodies = x86_bodies(cpu_c_text, cpu_c_path)
    if len(bodies) != len(expected):
        result.fail("_cpu.c carries %d tagged body/bodies, the instances have "
                    "%d CPU column(s) (%s)"
                    % (len(bodies), len(expected),
                       ", ".join(w for w, _, _, _ in expected)))
        return
    for (bpre, bproc, got), (who, pre, proc, ops) in zip(bodies, expected):
        if (bpre, bproc) != (pre, proc):
            result.fail("_cpu.c body het_run_%sP%d stands where %s's "
                        "het_run_%sP%d belongs" % (bpre, bproc, who, pre, proc))
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

    # The expected side is built BEFORE anything is emitted, so a control map
    # the gate cannot read is its own refusal on every path -- including
    # --hip-src, where litmus7 never runs and its refusals never fire.
    insts = het_instances(litmus_path) if kind == 'Het' else None

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
            if len(insts) > 1:
                result.note("  CO-RUN harness: %s"
                            % " + ".join("%s (%s)" % (i['name'], i['role'])
                                         for i in insts))
            check_het(result, insts, lanes)
            check_stress_region(result, other, DEVICE_HELPERS)
            if any(i['cpu'] for i in insts):
                if cpu_c_path is None:
                    result.fail("het test has CPU columns but no _cpu.c to read")
                else:
                    result.note("  _cpu.c %s" % cpu_c_path)
                    check_cpu(result, insts, open(cpu_c_path).read(), cpu_c_path)
        else:
            check_gpu_only(result, inst, lanes, klines)
            check_stress_region(result, other, set())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in result.lines:
            print(ln)
    return result.ok


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
    print("  %-38s %s, beside the .litmus (x86_64 het)"
          % ("positive-control map", CONTROL_MAP))
    print("  %-38s %r" % ("its header, asserted verbatim", CONTROL_MAP_HEADER))

    print("\n-- GPU annotation -> emitted HIP construct (litmus/HipLang.ml) --")
    print("  w[o,s] <var> <value>   __hip_atomic_store(<var>, <value>, <ORDER>, <SCOPE>)")
    print("  r[o,s] <dst> <var>     <dst> = __hip_atomic_load(<var>, <ORDER>, <SCOPE>)")
    print("  f[o,s]                 __builtin_amdgcn_fence(<ORDER>, \"<scope>\"); // f[o,s]")
    print("  f[relaxed,s]           a comment only; nothing executable")
    for label, table in (("memory orders", HIP_ORDER), ("access scopes", HIP_SCOPE),
                         ("fence sync scopes", HIP_FENCE_SCOPE)):
        print("\n-- %s --" % label)
        if not table:
            print("  *** empty table ***")
            bad += 1
        for k, v in table.items():
            print("  %-8s -> %s" % (k, ('""' if v == "" else v)))
    print("  (the unnamed fence scope IS system scope; naming one narrows it)")

    print("\n-- x86_64 CPU column -> emitted _cpu.c asm (litmus/hetCpuBodyX86.ml) --")
    print("  MOV $k,%reg      folded: the per-iteration tag replaces the value")
    print("  MOV (g),%reg     load    movq (%[g]),%[_t<i>]")
    print("  MOV $k,(g)       store   movq %[_v<i>],(%[g])")
    print("  MOV %reg,(g)     store   movq %[_v<i>],(%[g])")
    print("  %s   fence   the bare mnemonic"
          % "|".join(sorted(X86_FENCE)))
    print("  accepted MOV spellings: %s" % ", ".join(sorted(X86_MOV)))
    if not (X86_MOV and X86_FENCE):
        bad += 1

    print("\n-- het lane anchors --")
    for s in (("rdv-add", "sc", "sys"), ("rdv-spin", "sc", "sys"), ("spin",),
              ("obs-ld", "relaxed", "sys"), ("res", "<buf>", "<reg>"), ("bump",)):
        print("  %s" % fmt(s))
    print("\n-- device helpers a het kernel may carry (litmus/het-runtime/het_stress.h) --")
    if not DEVICE_HELPERS:
        bad += 1
    print("  %s" % " ".join(sorted(DEVICE_HELPERS)))

    print("\n-- exit contract --")
    print("  0 PASS   1 FAIL   2 completeness hard-fail   3 error")
    if bad:
        print("\nGUARD FAILED: %d unresolved path(s) or empty table(s)" % bad)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus HIP source gate: .litmus annotation vs emitted HIP")
    ap.add_argument("litmus", nargs="?", help=".litmus test path")
    ap.add_argument("--hip-src", help="read this .hip instead of emitting one")
    ap.add_argument("--cpu-c", help="read this _cpu.c instead of emitting one")
    ap.add_argument("--guard", action="store_true",
                    help="print the vocabulary and paths, then exit")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    if args.guard:
        sys.exit(guard_report())
    if not args.litmus:
        print("ERROR: no .litmus given (and --guard not asked for)")
        sys.exit(3)
    try:
        ok = check_test(args.litmus, hip_override=args.hip_src,
                        cpu_c_override=args.cpu_c, verbose=not args.quiet)
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        sys.exit(2)
    except Exception as e:
        print("ERROR: %s" % e)
        sys.exit(3)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
