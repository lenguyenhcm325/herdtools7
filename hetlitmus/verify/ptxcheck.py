#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ptxcheck.py -- static faithfulness: an emitted harness carries exactly the
# memory ops its .litmus annotates, with the annotated kind, order and scope.
# The mapping table below, its grounding and what each check asserts are in
# hetlitmus/docs/faithfulness.md.
#
#   .litmus annotation --(CudaLang)--> .cu --(nvcc --ptx)--> PTX --(this)-->
#       expected (kind,order,scope) profile == observed PTX instructions ?
#
# Hardware-free: it emits, compiles to PTX and reads the text, never launching a
# kernel.  The lowering it guards: libcu++'s cuda::atomic_thread_fence collapses
# acquire/release to fence.acq_rel, losing the order, so CudaLang emits faithful
# inline PTX instead (cuda-emitter.md, "Fence lowering").
#
# Reading nvcc --ptx is sound.  libcu++ scoped atomics and CudaLang's inline PTX
# are both asm volatile with a "memory" clobber, so nvcc may NOT reorder model
# ops against one another even when they are relaxed, and the textual order
# between the `// begin/end inline asm' markers is source program order.
# Scaffolding (ld.param / st.global / cvta) sits outside those markers; procs are
# emitted in column order and cells in row order, so the streams line up flat.
#
# Exit 0 = PASS, 1 = FAIL (exact diff), 2 = completeness hard-fail, 3 = error.
# ---------------------------------------------------------------------------

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
NVCC = shutil.which("nvcc") or "/usr/local/cuda/bin/nvcc"

# ===========================================================================
# 1. The mapping table  (annotation -> expected PTX / ARM profile), grounded in
#    hetlitmus/docs/faithfulness.md.  It builds the expected profile and doubles as
#    the completeness guard: an annotation token that is not a key here
#    hard-fails, so nothing is ever silently skipped.
# ===========================================================================

# GPU memory orders: LISA/Bell tag  ->  PTX semantics token.
# (ld accepts relaxed/acquire; st accepts relaxed/release; fence accepts
#  sc/acq_rel/acquire/release.  PTX uses the SAME spelling as the LISA tag.)
GPU_ORDER = {
    "relaxed": "relaxed",
    "acquire": "acquire",
    "release": "release",
    "acq_rel": "acq_rel",
    "sc":      "sc",
}

# GPU scopes: LISA/Bell tag  ->  PTX scope token (identical spelling).
GPU_SCOPE = {
    "cta":     "cta",
    "gpu":     "gpu",
    "sys":     "sys",
}

# Op kind: LISA mnemonic  ->  expected PTX opcode class.
#   load  -> ld         store -> st         fence -> fence
# The corpus (ptx.bell declares only R/W/F) contains NO RMW, and the RMW guard is
# the GPU_CELL regex below, not this table: a cell whose mnemonic is outside
# {w,r,f} never reaches a lookup here, it fails to match and is hard-failed as an
# "unrecognized GPU cell".  Adding an `rmw' row would therefore buy nothing --
# supporting RMW means extending GPU_CELL first (and `atom'/`red' are two opcodes,
# so the compared tuple would need a shape this table cannot express).
GPU_KIND = {
    "w": "st",
    "r": "ld",
    "f": "fence",
}

# CPU (AArch64) ordering mnemonics:
#   STLR  = store-release        LDAR  = load-acquire (RCsc)
#   LDAPR = load-acquire (RCpc)  DMB <option> = data memory barrier
# `mov' materialises a store's value in a register and is therefore NOT a memory
# op; it is recognized (so the guard does not fail) but not compared.
CPU_MNEMONIC = {
    "mov":   ("move",          False),  # folded; not a memory/ordering op
    "str":   ("plain-store",   True),
    "ldr":   ("plain-load",    True),
    "stlr":  ("release-store", True),
    "ldar":  ("acquire-load-rcsc", True),
    "ldapr": ("acquire-load-rcpc", True),
    "dmb":   ("fence",         True),   # SPLIT by option -- see below
}

# A barrier's ordered-pair set lives in its OPTION, not its mnemonic: `DMB SY'
# orders {WW,RR,WR,RW}, `DMB ST' only {WW}, `DMB LD' only {RR,RW}, and they are
# three distinct instructions -- d5033fbf / d5033ebf / d5033dbf.  The compared op
# tuple is (mnemonic, option), so a `DMB SY' lowered to `DMB ST' already reads as a
# mismatch; what this table adds is the completeness guard on the option, so an
# unmodelled one (`DMB ISH', `DMB OSHST', a bare `DMB') hard-fails rather than
# being compared as an opaque string.
CPU_BARRIER_OPTION = {
    "sy": "fence-full",     # DMB SY : orders {WW,RR,WR,RW}  (full system barrier)
    "st": "fence-store",    # DMB ST : orders {WW}           (the `rel' half only)
    "ld": "fence-load",     # DMB LD : orders {RR,RW}        (the `acq' half only)
}


def barrier_option(mn, tokens, where):
    """The modelled option of a `dmb' (or '' for a non-barrier mnemonic).

    Completeness guard: an unmodelled or missing option hard-fails."""
    if mn != "dmb":
        return ""
    opt = tokens[0].lower() if tokens else ""
    if opt not in CPU_BARRIER_OPTION:
        raise CompletenessError(
            "unmodelled AArch64 barrier option %r on %r in %s -- its ordered-pair "
            "set is not in CPU_BARRIER_OPTION" % (opt, mn, where))
    return opt

PTX_ORDERS = set(GPU_ORDER.values())          # {relaxed,acquire,release,acq_rel,sc}
PTX_SCOPES = set(GPU_SCOPE.values())          # {cta,gpu,sys}


class CompletenessError(Exception):
    """Raised when an annotation token is not in the mapping table."""


# ===========================================================================
# 2. .litmus PARSING
# ===========================================================================

GPU_CELL = re.compile(r'^([wrf])\[([a-z_]+)\s*,\s*([a-z]+)\]')


def read_litmus(path):
    with open(path) as f:
        return f.read()


def litmus_kind(text):
    """'LISA' (gpu-only) or 'Het' (heterogeneous), from the first header word."""
    first = text.strip().splitlines()[0].split()
    return first[0]


def litmus_name(text):
    return text.strip().splitlines()[0].split()[1]


def parse_body(text):
    """Return (procs, body_rows).

    procs    : list of (proc_index, device_tag)  in column order
    body_rows: list of rows, each a list of raw cell strings (one per column)

    The body is the grid between the `{...}` init block header row `P0:.. | ..;`
    and the `scopes:`/`exists` lines.

    A MISSING device tag is legal only on a gpu-only LISA test, which has one
    device by construction.  On a `Het' test it is fatal: silently defaulting an
    untagged column to "gpu" would send a CPU column through gpu_ops_of_column
    and compare AArch64 mnemonics against PTX -- a wrong answer rather than a
    refusal.  So the kind decides, and an untagged het column hard-fails.
    """
    lines = text.splitlines()
    kind = litmus_kind(text)
    # find the header row: starts (after strip) with 'P<digit>'
    hdr_i = None
    for i, ln in enumerate(lines):
        if re.match(r'^\s*P\d+\b', ln):
            hdr_i = i
            break
    if hdr_i is None:
        raise ValueError("no 'P0..' program header row found")

    def split_row(ln):
        ln = ln.strip()
        if ln.endswith(';'):
            ln = ln[:-1]
        return [c.strip() for c in ln.split('|')]

    hdr = split_row(lines[hdr_i])
    procs = []
    for col, tok in enumerate(hdr):
        m = re.match(r'^P(\d+)(?::(\w+))?$', tok.strip())
        if not m:
            raise ValueError("bad proc header column: %r" % tok)
        idx = int(m.group(1))
        dev = m.group(2)
        if dev is None:
            if kind == 'Het':
                raise CompletenessError(
                    "het proc header column %r carries NO device tag (want `P%d:cpu' "
                    "or `P%d:gpu') -- an untagged column cannot be defaulted, the "
                    "device is what decides which ISA it is compared against"
                    % (tok.strip(), idx, idx))
            dev = "gpu"               # gpu-only LISA tests omit the tag => gpu
        procs.append((idx, dev))

    rows = []
    for ln in lines[hdr_i + 1:]:
        s = ln.strip()
        if s.startswith('scopes:') or s.startswith('exists') or \
           s.startswith('forall') or s.startswith('locations') or s == '':
            if s == '':
                continue
            break
        rows.append(split_row(ln))
    return procs, rows


def device_class(dev):
    """Map a column device tag to 'gpu' or 'cpu'."""
    d = dev.lower()
    if d == 'gpu':
        return 'gpu'
    if d in ('cpu', 'aarch64', 'arm', 'x86_64', 'amd64'):
        return 'cpu'
    raise CompletenessError("unrecognized device tag %r (not gpu/cpu/...)" % dev)


def instance_of(litmus_path):
    """Parse one .litmus into the profile the checker compares against."""
    text = read_litmus(litmus_path)
    procs, rows = parse_body(text)
    ncol = len(procs)
    cols = [[] for _ in range(ncol)]
    for row in rows:
        for c in range(ncol):
            cols[c].append(row[c] if c < len(row) else '')
    gpu, cpu = [], []
    for col, (pidx, dev) in enumerate(procs):
        if device_class(dev) == 'gpu':
            gpu.append((pidx, gpu_ops_of_column(cols[col])))
        else:
            cpu.append((pidx, cpu_ops_of_column(cols[col])))
    return dict(name=litmus_name(text), kind=litmus_kind(text),
                gpu=gpu, cpu=cpu)


def het_lane_plan(inst):
    """The rendezvous-joining GPU lanes, in the order dump_gpu_file emits them:
    the GPU test lanes, in proc order.

    Returns a list of ('test', proc, ops, name)."""
    return [('test', pidx, ops, inst['name']) for pidx, ops in inst['gpu']]


# ----- per-column op extraction --------------------------------------------

def gpu_ops_of_column(cells):
    """Parse a GPU column's non-empty cells into ordered (kind,order,scope).

    Completeness guard: every w/r/f cell's order & scope must be in the mapping
    table; an unknown token raises CompletenessError (hard fail upstream)."""
    ops = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        m = GPU_CELL.match(c)
        if not m:
            # A GPU column cell that is neither w[..]/r[..]/f[..] nor empty:
            # could be an RMW or an unknown form -> do not silently skip.
            raise CompletenessError("unrecognized GPU cell %r" % c)
        # op is drawn from GPU_CELL's [wrf], so it is a GPU_KIND key by
        # construction; order and scope are free tokens and must be checked.
        op, order, scope = m.group(1), m.group(2), m.group(3)
        if order not in GPU_ORDER:
            raise CompletenessError("unknown memory order %r in %r" % (order, c))
        if scope not in GPU_SCOPE:
            raise CompletenessError("unknown scope %r in %r" % (scope, c))
        ops.append((GPU_KIND[op], GPU_ORDER[order], GPU_SCOPE[scope]))
    return ops


def cpu_ops_of_column(cells):
    """Parse a CPU column's cells into ordered memory-op descriptors.

    Returns a list of (mnemonic, qualifier) for memory/ordering ops only
    (mov materialises a value and is excluded).
    Completeness guard: any mnemonic not in CPU_MNEMONIC hard-fails."""
    ops = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        toks = c.replace(',', ' ').split()
        mn = toks[0].lower()
        if mn not in CPU_MNEMONIC:
            raise CompletenessError("unknown CPU mnemonic %r in %r" % (mn, c))
        _sem, is_mem = CPU_MNEMONIC[mn]
        if not is_mem:
            continue  # mov: folded, not emitted as an asm memory op
        qual = barrier_option(mn, toks[1:], "the .litmus CPU column (%r)" % c)
        ops.append((mn, qual))
    return ops


# ===========================================================================
# 3. EMIT  (.litmus -> .cu [+ _cpu.c])  and COMPILE (.cu -> PTX)
# ===========================================================================

def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, **kw)


def emit_harness(litmus_path, outdir):
    """Run litmus7 to emit the harness. Returns (cu_path, cpu_c_path_or_None)."""
    name = litmus_name(read_litmus(litmus_path))
    r = run([LITMUS7, "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", outdir, litmus_path])
    # gpu-only: <outdir>/<name>.cu ; het: <outdir>/<name>/<name>.cu
    flat_cu = os.path.join(outdir, name + ".cu")
    het_cu = os.path.join(outdir, name, name + ".cu")
    if os.path.exists(het_cu):
        cpu_c = os.path.join(outdir, name, name + "_cpu.c")
        return het_cu, (cpu_c if os.path.exists(cpu_c) else None)
    if os.path.exists(flat_cu):
        return flat_cu, None
    raise RuntimeError("litmus7 emitted no .cu for %s\n%s" % (litmus_path, r.stdout))


def compile_ptx(cu_path, ptx_path, arch):
    r = run([NVCC, "-std=c++17", "-arch=" + arch, "--ptx", "-o", ptx_path, cu_path])
    if r.returncode != 0 or not os.path.exists(ptx_path):
        raise RuntimeError("nvcc --ptx failed for %s (arch=%s):\n%s"
                           % (cu_path, arch, r.stdout))
    return r.stdout


# ===========================================================================
# 4. PTX EXTRACTION  (observed model ops, in textual order)
# ===========================================================================

OPLINE = re.compile(r'^\s*(ld|st|atom|red|fence|membar)\.([a-z0-9_.]+)')


def classify_ptx_op(line):
    """Parse a PTX memory-instruction line into (kind, order, scope) or None.

    None  => the line is scaffolding (ld.param / st.global / ld.global / membar
             with no memory-model order token) and is not a synchronizing op.
    For ld/st/atom/red the order token must be present (relaxed/acquire/release/
    acq_rel/sc) else it is plain addressing and returns None.
    For fence/membar the two qualifier tokens are classified order-agnostically
    (CudaLang emits `fence.<order>.<scope>`, libcu++'s barrier emits the scope
    first as `fence.<scope>.<order>` -- we accept either ordering)."""
    m = OPLINE.match(line)
    if not m:
        return None
    kind = m.group(1)
    quals = m.group(2).split('.')
    order = next((q for q in quals if q in PTX_ORDERS), None)
    scope = next((q for q in quals if q in PTX_SCOPES), None)
    if kind in ('fence', 'membar'):
        # a fence MUST carry an order (sc/acq_rel/acquire/release); scope may be
        # implicit only for legacy membar (not used here).
        if order is None:
            return None
        return ('fence', order, scope)
    # ld/st/atom/red: only a model op if it carries an order qualifier.
    if order is None:
        return None
    return (kind, order, scope)


def extract_ptx_ops(ptx_text):
    """Ordered list of (kind,order,scope) for every inline-asm model op."""
    ops = []
    in_asm = False
    for line in ptx_text.splitlines():
        s = line.strip()
        if s.startswith('// begin inline asm'):
            in_asm = True
            continue
        if s.startswith('// end inline asm'):
            in_asm = False
            continue
        if not in_asm:
            continue
        op = classify_ptx_op(s)
        if op is not None:
            ops.append(op)
    return ops


# ===========================================================================
# 5. CPU _cpu.c EXTRACTION  (real AArch64 asm block only)
# ===========================================================================

ASM_STR = re.compile(r'"\s*([a-zA-Z][a-zA-Z0-9.]*)([^"]*)\\n"')


def extract_cpu_ops(cpu_c_text):
    """Ordered (mnemonic,qualifier) memory ops from the REAL aarch64 asm block
    (between `#if defined(__aarch64__)` and `#else`).  mov is excluded.

    The block is litmus7's own (ASMLang.dump_fun), so its instruction lines carry
    `%w[x0]' / `%[x1]' operands and are interleaved with `#START _litmus_P<n>' /
    `#_litmus_P<n>_<i>' / `#END _litmus_P<n>' marker literals.  A marker begins
    with `#', which ASM_STR's leading [a-zA-Z] rejects, so only instructions are
    read."""
    lines = cpu_c_text.splitlines()
    start = end = None
    for i, ln in enumerate(lines):
        if '__aarch64__' in ln and start is None:
            start = i
        elif start is not None and ln.strip().startswith('#else'):
            end = i
            break
    block = lines[start:end] if start is not None else lines
    ops = []
    for ln in block:
        # finditer, not search: C concatenates adjacent string literals, so
        #     "str %x[_v1],[%[y]]\n"    "dmb sy\n"
        # is ONE asm line carrying two instructions.  search would read only the
        # first, hiding an instruction appended to a body -- a body that no
        # longer runs the program the .litmus names.  The emitter does emit one
        # per line, but a gate that works only because of how its input happens
        # to be formatted is not a gate.
        for m in ASM_STR.finditer(ln):
            mn = m.group(1).lower()
            rest = m.group(2).strip().lower()
            if mn not in CPU_MNEMONIC:
                # asm we didn't expect in the real block -> surface, don't skip
                raise CompletenessError("unexpected asm mnemonic %r in _cpu.c" % mn)
            _sem, is_mem = CPU_MNEMONIC[mn]
            if not is_mem:
                continue
            qual = barrier_option(mn, rest.replace(',', ' ').split(),
                                  "the emitted _cpu.c asm block (%r)"
                                  % (mn + " " + rest).strip())
            ops.append((mn, qual))
    return ops


# ===========================================================================
# 6. CHECK
# ===========================================================================

def fmt(op):
    if op[0] == 'fence':
        return "fence.%s.%s" % (op[1], op[2])
    return "%s.%s.%s" % (op[0], op[1], op[2])


def diff_sequences(expected, actual):
    """Return a list of human diff lines (empty == identical)."""
    out = []
    n = max(len(expected), len(actual))
    for i in range(n):
        e = fmt(expected[i]) if i < len(expected) else "<none>"
        a = fmt(actual[i]) if i < len(actual) else "<none>"
        mark = "" if e == a else "   <<< MISMATCH"
        if e != a:
            out.append("  [%d] expected %-22s observed %-22s%s" % (i, e, a, mark))
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


def check_gpu(result, expected_per_proc, observed, label):
    """expected_per_proc: list of (proc_label, [ops]).  observed: flat PTX ops.
    Runs the ordered check (placement+order) and the per-proc multiset check
    (multiplicity, equality not subset).

    proc_label is a plain string so a mismatch is reported against a named proc
    ("MP-cg-sys-fence:P1") rather than a bare index."""
    expected_flat = [op for _, ops in expected_per_proc for op in ops]

    # ----- ORDERED check (subsumes placement; the multiset is order-blind) ---
    if observed != expected_flat:
        result.fail("%s ordered model-op stream differs" % label)
        for d in diff_sequences(expected_flat, observed):
            result.note(d)
    else:
        result.note("  %s ordered stream OK (%d ops)" % (label, len(expected_flat)))

    # ----- PER-PROC LOCALIZER (diagnostic, NOT a detector) -------------------
    # An order-blind multiset test is strictly weaker than the order-sensitive
    # one above: if the ordered check passed, the two lists are identical, so
    # every slice matches element-wise and no multiset comparison can differ.  A
    # GLOBAL multiset would therefore detect nothing at all.  What the per-proc
    # slicing adds is localization -- it names the instance and proc a mismatch
    # is in, which the flat index diff cannot -- so it runs only once something
    # has already failed, and only reports.
    if not result.ok:
        pos = 0
        for plabel, ops in expected_per_proc:
            seg = observed[pos:pos + len(ops)]
            pos += len(ops)
            ce, ca = Counter(ops), Counter(seg)
            if ce != ca:
                result.note("  localized: %s %s multiset expected %s observed %s"
                            % (label, plabel, dict(ce), dict(ca)))
    return expected_flat


def split_het_segments(observed, n_gpu_procs):
    """Separate rendezvous ops from GPU model ops in a het kernel.

    One rendezvous instance per GPU proc, not a single prologue: each proc is
    emitted as its own guarded block whose iteration loop opens with the
    rendezvous and then runs the model ops (faithfulness.md, "Het barrier/model
    separation").  Segment the stream at each arrival and strip the template
    [atom.relaxed.sys arrive][ld.relaxed.sys poll] from the front of each
    segment; what remains is that proc's model ops.  A fence adjacent to either
    op is absorbed as well -- there is none to absorb, and
    check_barrier_whitelist is what says so by name.

    The anchor is a SYSTEM-SCOPE atom/red.  The corpus model (ptx.bell declares
    R/W/F only) has no RMW, so every atom/red is scaffolding, and the rendezvous
    fetch_add is the system-scoped one.  Anchoring on scope is the check, not a
    bypass -- a device-scope scaffolding atom that became system-scoped would be
    counted here as a rendezvous arrival and blow the per-lane count in
    check_barrier_whitelist.

    Returns (pre_ops, barrier_ops, model_per_segment): the model ops emitted
    BEFORE the first rendezvous (see check_no_pre_barrier_ops), then one list per
    rendezvous-joining GPU lane in emission order."""
    atom_idx = [i for i, op in enumerate(observed)
                if op[0] in ('atom', 'red') and op[2] == 'sys']
    if not atom_idx:
        return [], [], [observed]   # no fetch_add -> barrier check fails separately
    # segment start = a fence immediately ahead of the arrival if there is one,
    # so that fence reaches the whitelist and is named there rather than silently
    # counted as a model op of the lane before.
    starts = []
    for i in atom_idx:
        if i - 1 >= 0 and observed[i - 1][0] == 'fence':
            starts.append(i - 1)
        else:
            starts.append(i)
    barrier_ops, model_per_segment = [], []
    for k, ai in enumerate(atom_idx):
        s = starts[k]
        end = starts[k + 1] if k + 1 < len(starts) else len(observed)
        seg = observed[s:end]
        bi = 0
        if bi < len(seg) and seg[bi][0] == 'fence':              # a fence ahead of it
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] in ('atom', 'red'):      # the arrival
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] == 'fence':              # a fence behind it
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] == 'ld':                 # the poll
            barrier_ops.append(seg[bi]); bi += 1
        model_per_segment.append(seg[bi:])
    return observed[:starts[0]], barrier_ops, model_per_segment


def check_no_pre_barrier_ops(result, pre_ops):
    """Nothing may be emitted before the FIRST rendezvous.

    The segmentation above is anchored on the rendezvous arrivals, so everything
    ahead of the first one falls outside every segment: it reaches neither
    barrier_ops nor model_per_segment, and so is compared against nothing.  The
    hole is one-sided -- an op BETWEEN two rendezvous lands in the previous
    segment and breaks the ordered check, and a MISSING op breaks it too -- but an
    EXTRA model op at the top of the kernel would be invisible, and
    check_no_stray_sys cannot see it either (it inspects only text OUTSIDE the
    inline-asm markers, and this op is inside them).

    The shipped emitter opens each proc's iteration loop with the rendezvous and
    runs the model ops after it, and the stress/noise layers use builtins or plain
    volatile accesses that carry no order qualifier, so nothing enters `observed'
    ahead of lane 0's arrival: the assertion costs nothing, closes the hole, and
    is what fires when a rendezvous is moved BEHIND a tested access."""
    if pre_ops:
        result.fail("%d model op(s) emitted BEFORE the first rendezvous barrier -- "
                    "they sit outside every lane segment and are compared against "
                    "nothing" % len(pre_ops))
        for o in pre_ops[:8]:
            result.note("  pre-barrier: %s" % fmt(o))
    else:
        result.note("  no model ops before the first rendezvous barrier")


def check_barrier_whitelist(result, barrier_ops, n_lanes):
    """The het sys-scope rendezvous must span both devices and ORDER NOTHING:
    every op system-scoped (not narrowed), every op RELAXED, NO fence anywhere in
    it, and one arrival (atom/red) per rendezvous-joining GPU lane.

    Relaxed and fence-free is a correctness property, not a preference: an
    acquire poll self-invalidates the GPU L1 [Bagchi26 sec 5.3] and a fence.sc.sys
    flushes it, so a strengthened rendezvous erases the cache state the tested
    iteration is about to race on -- while every model op still matches.

    n_lanes = the number of GPU procs: each one rendezvouses once per iteration,
    and the loop is emitted once, so one arrival per lane is what the text
    carries."""
    if not barrier_ops:
        result.fail("het kernel has NO rendezvous (expected a sys-scope relaxed atom)")
        return
    # The only scope test the poll gets.  The arrivals pass it by construction:
    # split_het_segments anchors a segment on a SYSTEM-SCOPE atom/red, so a
    # narrowed arrival never enters barrier_ops at all -- its segment disappears
    # and the lane count below is what fires.
    for op in barrier_ops:
        if op[2] != 'sys':
            result.fail("rendezvous op %s is NOT system scope (weakened/narrowed)"
                        % fmt(op))
    fences = [o for o in barrier_ops if o[0] == 'fence']
    atoms = [o for o in barrier_ops if o[0] in ('atom', 'red')]
    for op in fences:
        result.fail("the rendezvous carries a FENCE (%s) -- it must order nothing, "
                    "and a system-scope fence flushes the cache state the tested "
                    "iteration races on" % fmt(op))
    for op in barrier_ops:
        if op[0] != 'fence' and op[1] != 'relaxed':
            result.fail("rendezvous op %s is NOT relaxed -- an acquire or seq_cst "
                        "arrival/poll orders the tested accesses behind it" % fmt(op))
    if len(atoms) != n_lanes:
        result.fail("expected one rendezvous arrival per rendezvous-joining GPU lane "
                    "(%d); found %d" % (n_lanes, len(atoms)))
    result.note("  rendezvous whitelist OK (%d ops, %d arrival(s) for %d lane(s), "
                "all sys, all relaxed, no fence)"
                % (len(barrier_ops), len(atoms), n_lanes))


def stray_sys_ops(ptx_text):
    """System-scope memory ops emitted OUTSIDE the inline-asm markers.

    extract_ptx_ops sees only inline-asm ops, which is sound for the model ops
    (file header) but leaves a blind spot: a system-scope op from a compiler
    builtin (__threadfence_system, atomicAdd_system, ...) sits outside the
    markers and would be compared against nothing.  The stress layer is where one
    could hide, since it deliberately uses builtins and plain accesses to stay
    out of the model-op stream.  Hence the rule: scaffolding may be invisible
    only because it is device-scope and unordered, and a system-scope op is by
    definition traffic crossing the CPU-GPU boundary, so none may appear outside
    the inline-asm stream at all."""
    stray = []
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
        m = OPLINE.match(s)
        if m and 'sys' in m.group(2).split('.'):
            stray.append(s)
    return stray


def check_no_stray_sys(result, ptx_text):
    stray = stray_sys_ops(ptx_text)
    if stray:
        result.fail("%d system-scope op(s) emitted OUTSIDE the inline-asm stream "
                    "(a builtin sys-scope op is invisible to the model-op check)"
                    % len(stray))
        for s in stray[:8]:
            result.note("  stray: %s" % s)
    else:
        result.note("  no stray system-scope ops outside the model-op stream")


def check_cpu(result, expected_per_proc, cpu_c_text):
    """Compare the CPU column's memory/ordering mnemonics (ordered) against the
    emitted _cpu.c real-asm block.  Catches STLR->STR, LDAPR->LDR, DMB SY drop/
    narrowing, etc."""
    expected_flat = [op for _, ops in expected_per_proc for op in ops]
    observed = extract_cpu_ops(cpu_c_text)
    if observed != expected_flat:
        result.fail("CPU memory-op stream differs (litmus column vs _cpu.c)")
        n = max(len(expected_flat), len(observed))
        for i in range(n):
            e = ("%s %s" % expected_flat[i]).strip() if i < len(expected_flat) else "<none>"
            a = ("%s %s" % observed[i]).strip() if i < len(observed) else "<none>"
            if e != a:
                result.note("  [%d] expected %-14s observed %-14s   <<< MISMATCH" % (i, e, a))
    else:
        result.note("  CPU ordered stream OK (%d mem ops)" % len(expected_flat))


# ===========================================================================
# 7. DRIVER
# ===========================================================================

def check_test(litmus_path, ptx_override=None, cpu_c_override=None,
               arch=None, verbose=True):
    # instance_of parses, transposes and classifies the columns, so the
    # completeness guard fires here too, on the same two column parsers.  The Het
    # branch below rebuilds the GPU profile lane by lane; ONLY the gpu-only branch
    # consumes gpu_expected as computed here, and no path reads a CPU profile
    # from it.
    inst = instance_of(litmus_path)
    kind, name = inst['kind'], inst['name']
    gpu_expected = inst['gpu']   # list of (proc_idx, [ (kind,order,scope) ])

    result = Result()
    result.note("=== %s [%s] ===" % (name, kind))

    # ---- emit + compile (unless a PTX override is supplied for self-test) ----
    tmp = tempfile.mkdtemp(prefix="ptxcheck_")
    try:
        if ptx_override is not None:
            with open(ptx_override) as f:
                ptx_text = f.read()
            cpu_c_text = open(cpu_c_override).read() if cpu_c_override else None
        else:
            cu_path, cpu_c_path = emit_harness(litmus_path, tmp)
            # sm_90 matches the run harness: the emitted Makefile/comp.sh compile
            # the same .cu with `CUDA_ARCH ?= sm_90' (litmus/hetDialect.ml,
            # gd_arch_default).  Checking a different arch than the one that runs
            # would leave a soundness gap, and sm_90 is also the floor for the
            # corpus's fence.acquire/fence.release [CCCL].  --arch overrides.
            use_arch = arch or "sm_90"
            ptx_path = os.path.join(tmp, name + ".ptx")
            compile_ptx(cu_path, ptx_path, use_arch)
            with open(ptx_path) as f:
                ptx_text = f.read()
            cpu_c_text = open(cpu_c_path).read() if cpu_c_path else None

        observed = extract_ptx_ops(ptx_text)

        if kind == 'Het':
            lanes = het_lane_plan(inst)
            n_lanes = len(lanes)
            # One rendezvous per rendezvous-joining GPU lane; segment on the
            # fetch_add anchor and strip the barrier template, leaving each lane's
            # model ops.
            pre_ops, barrier_ops, model_per_seg = split_het_segments(observed, n_lanes)
            check_no_pre_barrier_ops(result, pre_ops)
            check_barrier_whitelist(result, barrier_ops, n_lanes)
            if len(model_per_seg) != n_lanes:
                result.fail("expected %d rendezvous-joining GPU lane(s) (%s); found %d"
                            % (n_lanes,
                               ", ".join("%s:P%d" % (l[3], l[1]) for l in lanes),
                               len(model_per_seg)))
            else:
                # Walk lanes and PTX segments in lockstep.
                gpu_expected = []
                model_ops = []
                for (_kindl, pidx, payload, iname), seg in zip(lanes, model_per_seg):
                    gpu_expected.append(("%s:P%d" % (iname, pidx), payload))
                    model_ops.extend(seg)
                check_gpu(result, gpu_expected, model_ops, "GPU")
            check_no_stray_sys(result, ptx_text)
            # The CPU side: _cpu.c carries litmus7's own asm blocks inside ONE
            # `#if defined(__aarch64__)' region.
            cpu_expected = [("%s:P%d" % (name, p), ops) for p, ops in inst['cpu']]
            if cpu_expected:
                if cpu_c_text is None:
                    result.fail("het test has CPU columns but no _cpu.c emitted")
                else:
                    check_cpu(result, cpu_expected, cpu_c_text)
        else:
            # gpu-only: every inline-asm op is a model op (no barrier, no stress).
            check_gpu(result, gpu_expected, observed, "GPU")
            check_no_stray_sys(result, ptx_text)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in result.lines:
            print(ln)
    return result.ok


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus static token check: PTX/asm faithfulness")
    ap.add_argument("litmus", help=".litmus test path")
    ap.add_argument("--ptx", help="use this PTX file instead of emitting+nvcc (self-test)")
    ap.add_argument("--cpu-c", help="use this _cpu.c instead of emitting (self-test)")
    ap.add_argument("--arch", help="override nvcc -arch (default sm_90, matching the litmus7 run harness CUDA_ARCH)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    try:
        ok = check_test(args.litmus, ptx_override=args.ptx, cpu_c_override=args.cpu_c,
                        arch=args.arch, verbose=not args.quiet)
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
