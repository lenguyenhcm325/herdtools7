#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ptxcheck.py  --  HetLitmus L0 static faithfulness checker
# ---------------------------------------------------------------------------
# Proves that the GPU (and, for het tests, CPU) harness litmus7 emits carries
# EXACTLY the memory order + scope its .litmus annotation specifies -- catching
# any weakening, strengthening, miscount, misplacement, missing qualifier, or
# wrong op-kind in the lowering chain.
#
#   .litmus annotation  --(CudaLang)-->  .cu  --(nvcc --ptx)-->  PTX  --(this)-->
#       expected (kind,order,scope) profile  ==  observed PTX instructions ?
#
# STATIC + HARDWARE-FREE: emits, compiles to PTX, and inspects the text.  It
# NEVER launches a kernel.  This is *not* a herd re-check, a mutation, or a
# differential test -- it is one thing: token-level lowering faithfulness.
#
# The bug this guards (see hetlitmus/docs/cuda-emitter.md "Fence lowering"):
# libcu++'s cuda::atomic_thread_fence COLLAPSES acquire/release -> fence.acq_rel,
# losing the order.  CudaLang therefore emits faithful inline PTX; this checker
# proves it stays faithful, and would FAIL the day a collapse/weakening returns.
#
# Why inspecting nvcc --ptx is sound (not luck):
#   * libcu++ scoped atomics ARE implemented as `asm volatile(... : : : "memory")`
#     -- they appear in the PTX wrapped in `// begin/end inline asm` markers.  An
#     asm-volatile with a memory clobber is a HARD compiler-ordering barrier, so
#     nvcc cannot reorder model ops relative to one another even when relaxed.
#     => the textual order of inline-asm ops == source program order (a theorem,
#        not an empirical accident).  Scaffolding (ld.param / st.global / cvta)
#        sits OUTSIDE the inline-asm markers and is ignored.
#   * nvcc emits procs in column order, cells in row order (CudaLang dump loop).
#     => the flattened PTX op stream == flattened expected stream.
#
# Grounding of the mapping table is in hetlitmus/docs/verify-l0.md.  The single
# strongest primary source is nvcc itself: every token below was emitted AND
# assembled (exit 0) by `nvcc -std=c++17 -arch=sm_86/90 --ptx`.
#
# Exit code 0 = PASS, nonzero = FAIL (with an exact diff on stderr/stdout).
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
# 1. THE MAPPING TABLE  (annotation  ->  expected PTX / ARM profile)
#    Grounded in hetlitmus/docs/verify-l0.md.  Used to build the expected
#    profile AND as the COMPLETENESS GUARD: any annotation token NOT a key
#    here is unrecognized and HARD-FAILS -- nothing is ever silently skipped.
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
    "cluster": "cluster",
}

# Op kind: LISA mnemonic  ->  expected PTX opcode class.
#   load  -> ld         store -> st         fence -> fence
#   RMW   -> atom (returns old value) or red (no-return reduction)
# The corpus (ptx.bell declares only R/W/F) contains NO RMW; the mapping is
# kept so the completeness guard *recognizes* one rather than skipping it.
GPU_KIND = {
    "w": "st",
    "r": "ld",
    "f": "fence",
    "rmw": ("atom", "red"),
}

# CPU (AArch64) ordering mnemonics.  ARM ARM + Bagchi ISMM'26 Fig 1:
#   STLR  = store-release        LDAR  = load-acquire (RCsc)
#   LDAPR = load-acquire (RCpc)  DMB SY = full system barrier
# `mov` is folded into an asm input operand by ASMLang and is therefore NOT a
# memory op; it is recognized (so the guard does not fail) but not compared.
CPU_MNEMONIC = {
    "mov":   ("move",          False),  # folded; not a memory/ordering op
    "str":   ("plain-store",   True),
    "ldr":   ("plain-load",    True),
    "stlr":  ("release-store", True),
    "ldar":  ("acquire-load-rcsc", True),
    "ldapr": ("acquire-load-rcpc", True),
    "dmb":   ("fence",         True),
}

PTX_ORDERS = set(GPU_ORDER.values())          # {relaxed,acquire,release,acq_rel,sc}
PTX_SCOPES = set(GPU_SCOPE.values())          # {cta,gpu,sys,cluster}


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
    """
    lines = text.splitlines()
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
        dev = (m.group(2) or "gpu")   # gpu-only LISA tests omit the tag => gpu
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


# Coherence-final atom in a condition:  `[x]=2`  (as opposed to a register atom
# `1:r0=1`).  Each one observes a ws/co edge.
COND_LOC = re.compile(r'\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*\]\s*=')


def condition_locations(text):
    """Shared LOCATIONS named by coherence-final atoms (`[x]=v`) in the condition,
    de-duplicated in source order.

    Mirrors HetCond.condition_locations in the emitter (litmus/hetCond.ml).  A
    ws/co edge has no read node, so the het emitter answers each such atom by
    launching ONE extra OBSERVER lane that snoops EVERY one of these locations
    (relaxed, system scope) once per iteration.  That lane joins the rendezvous
    barrier, so it contributes one extra fetch_add AND exactly |locs| extra
    `ld.relaxed.sys` to the kernel's op stream.  ptxcheck must MODEL that lane, or
    the 72 observer tests (S/R/2+2W) look like they carry stray memory ops.
    Register atoms (`1:r0=1`) are recovered from read buffers and need no
    observer, so they are ignored here."""
    locs = []
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith('exists') or s.startswith('forall') or s.startswith('filter'):
            for m in COND_LOC.finditer(s):
                if m.group(1) not in locs:
                    locs.append(m.group(1))
    return locs


def device_class(dev):
    """Map a column device tag to 'gpu' or 'cpu'."""
    d = dev.lower()
    if d == 'gpu':
        return 'gpu'
    if d in ('cpu', 'aarch64', 'arm', 'x86_64', 'amd64'):
        return 'cpu'
    raise CompletenessError("unrecognized device tag %r (not gpu/cpu/...)" % dev)


# ----- per-column op extraction --------------------------------------------

def gpu_ops_of_column(cells):
    """Parse a GPU column's non-empty cells into ordered (kind,order,scope).

    COMPLETENESS GUARD: every w/r/f cell's order & scope must be in the mapping
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
        op, order, scope = m.group(1), m.group(2), m.group(3)
        if op not in GPU_KIND:
            raise CompletenessError("unknown GPU op kind %r in %r" % (op, c))
        if order not in GPU_ORDER:
            raise CompletenessError("unknown memory order %r in %r" % (order, c))
        if scope not in GPU_SCOPE:
            raise CompletenessError("unknown scope %r in %r" % (scope, c))
        ops.append((GPU_KIND[op], GPU_ORDER[order], GPU_SCOPE[scope]))
    return ops


def cpu_ops_of_column(cells):
    """Parse a CPU column's cells into ordered memory-op descriptors.

    Returns a list of (mnemonic, qualifier) for MEMORY/ordering ops only
    (mov is folded by ASMLang and excluded).  COMPLETENESS GUARD: any
    mnemonic not in CPU_MNEMONIC hard-fails."""
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
        qual = ''
        if mn == 'dmb':
            qual = toks[1].lower() if len(toks) > 1 else ''
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
    r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", outdir, litmus_path])
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
    (between `#if defined(__aarch64__)` and `#else`).  mov is excluded."""
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
        m = ASM_STR.search(ln)
        if not m:
            continue
        mn = m.group(1).lower()
        rest = m.group(2).strip().lower()
        if mn not in CPU_MNEMONIC:
            # asm we didn't expect in the real block -> surface, don't skip
            raise CompletenessError("unexpected asm mnemonic %r in _cpu.c" % mn)
        _sem, is_mem = CPU_MNEMONIC[mn]
        if not is_mem:
            continue
        qual = ''
        if mn == 'dmb':
            qual = rest.replace(',', ' ').split()[0] if rest else ''
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
    """expected_per_proc: list of (proc_idx, [ops]).  observed: flat PTX ops.
    Runs the ORDERED check (placement+order) and the PER-PROC MULTISET check
    (multiplicity, equality not subset)."""
    expected_flat = [op for _, ops in expected_per_proc for op in ops]

    # ----- ORDERED check (subsumes placement; the multiset is order-blind) ---
    if observed != expected_flat:
        result.fail("%s ordered model-op stream differs" % label)
        for d in diff_sequences(expected_flat, observed):
            result.note(d)
    else:
        result.note("  %s ordered stream OK (%d ops)" % (label, len(expected_flat)))

    # ----- GLOBAL multiset equality (cheap independent corroboration) --------
    if Counter(observed) != Counter(expected_flat):
        result.fail("%s global multiset differs: expected %s observed %s"
                    % (label, dict(Counter(expected_flat)), dict(Counter(observed))))

    # ----- PER-PROC multiset equality (slice observed by expected counts) ----
    pos = 0
    for pidx, ops in expected_per_proc:
        seg = observed[pos:pos + len(ops)]
        pos += len(ops)
        ce, ca = Counter(ops), Counter(seg)
        if ce != ca:
            result.fail("%s P%d per-proc multiset differs: expected %s observed %s"
                        % (label, pidx, dict(ce), dict(ca)))
    return expected_flat


def split_het_segments(observed, n_gpu_procs):
    """Separate barrier ops from GPU model ops in a het kernel.

    Each GPU proc is emitted as its OWN guarded block `{ barrier; model... }`
    (every GPU thread must rendezvous), so the barrier is NOT a single prologue
    -- there is one barrier instance per GPU proc.  The barrier's fetch_add is
    the anchor.  We segment the op stream at each fetch_add and strip the fixed
    barrier template [leading fence.sc][atom.sys][spin fence.sc][spin ld.sys]
    from each segment's front; what remains is that proc's model ops (plus, for a
    test lane, the window-opener stripped by check_spin), in proc order.

    ANCHOR = a SYSTEM-SCOPE atom/red.  The corpus model (ptx.bell declares R/W/F
    only) has no RMW, so every atom/red in the kernel is scaffolding -- but there
    are now two KINDS of it, and only one is a barrier: the rendezvous fetch_add
    is system-scoped, while the B4 window-opener (het_stress.cuh het_spin) is
    DEVICE-scoped.  Anchoring on scope keeps the two apart.  It is also the
    check, not a bypass: a spin that ever became system-scoped would be counted
    as a barrier fetch_add here and blow the per-lane count in
    check_barrier_whitelist -- which is exactly the alarm we want, because a
    system-scope spin IS a per-iteration cross-device barrier.

    Returns (barrier_ops, model_per_segment).  model_per_segment is one list per
    barrier-joining GPU lane, in emission order (test lanes, then the observer)."""
    atom_idx = [i for i, op in enumerate(observed)
                if op[0] in ('atom', 'red') and op[2] == 'sys']
    if not atom_idx:
        return [], [observed]   # no fetch_add -> barrier check fails separately
    # segment start = the atom's leading seq_cst fence if present, else the atom.
    starts = []
    for i in atom_idx:
        if i - 1 >= 0 and observed[i - 1][0] == 'fence' and observed[i - 1][1] == 'sc':
            starts.append(i - 1)
        else:
            starts.append(i)
    barrier_ops, model_per_segment = [], []
    for k, ai in enumerate(atom_idx):
        s = starts[k]
        end = starts[k + 1] if k + 1 < len(starts) else len(observed)
        seg = observed[s:end]
        bi = 0
        if bi < len(seg) and seg[bi][0] == 'fence':              # leading fence.sc
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] in ('atom', 'red'):      # the fetch_add
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] == 'fence':              # spin leading fence.sc
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] == 'ld':                 # spin seq_cst load
            barrier_ops.append(seg[bi]); bi += 1
        model_per_segment.append(seg[bi:])
    return barrier_ops, model_per_segment


def check_barrier_whitelist(result, barrier_ops, n_lanes):
    """The het sys-scope rendezvous barrier(s) must stay STRONG: every barrier op
    system-scoped (not narrowed), one fetch_add (atom/red) PER BARRIER-JOINING GPU
    LANE, and a seq_cst fence present.

    n_lanes = (#GPU procs) + (1 if the test has an observer lane).  The observer
    lane rendezvouses too (it must not start snooping before the test threads run),
    so it contributes its own fetch_add."""
    if not barrier_ops:
        result.fail("het kernel has NO barrier (expected sys-scope rendezvous)")
        return
    for op in barrier_ops:
        if op[2] != 'sys':
            result.fail("barrier op %s is NOT system scope (weakened/narrowed)" % fmt(op))
    fences = [o for o in barrier_ops if o[0] == 'fence']
    atoms = [o for o in barrier_ops if o[0] in ('atom', 'red')]
    if not any(o[1] == 'sc' for o in fences):
        result.fail("barrier has no seq_cst fence (fence.sc.sys) -- weakened")
    if len(atoms) != n_lanes:
        result.fail("expected one barrier fetch_add per barrier-joining GPU lane (%d); found %d"
                    % (n_lanes, len(atoms)))
    for a in atoms:
        if a[2] != 'sys':
            result.fail("barrier fetch_add %s not system scope" % fmt(a))
    result.note("  barrier whitelist OK (%d ops, %d fetch_add for %d lane(s), all sys, seq_cst fence)"
                % (len(barrier_ops), len(atoms), n_lanes))


# The observer's snoop: `atomic_ref<uint64_t, thread_scope_system>(*l).load(relaxed)`
# (litmus/top_litmus.ml gd_sys_load_u64) -> ld.relaxed.sys.
OBS_OP = ('ld', 'relaxed', 'sys')

# The B4 device-scope window-opener (het_stress.cuh het_spin, ported from
# cuda-litmus `spin'): a relaxed fetch_add on a device-only scratch word, then
# the relaxed load of its bounded busy-wait.  Emitted once per GPU TEST lane, at
# the top of the perpetual loop (the `#pragma unroll 1' pins it to exactly one
# textual copy, as it does for the tested ops).
SPIN_OPS = [('atom', 'relaxed', 'gpu'), ('ld', 'relaxed', 'gpu')]


def check_spin(result, seg, pidx):
    """A GPU TEST lane must open its window with EXACTLY the device-scope spin,
    and the spin must be DEVICE-scoped.  Returns the segment with the spin
    stripped, so what remains is the lane's model ops.

    This is a load-bearing scientific check, not bookkeeping.  The spin aligns
    the GPU test lanes of an instance; the CPU-GPU rendezvous is the SEPARATE
    system-scope gd_bar, which fires once, OUTSIDE the perpetual loop.  If the
    spin were ever widened to system scope it would become a per-iteration
    CROSS-DEVICE barrier -- which masks the very order under test and stalls the
    run (Srivastava 4.1).  Pinning the scope to `gpu' here makes that regression
    impossible to land silently.  It equally fails if the window-opener is
    dropped, duplicated, strengthened (relaxed -> acquire), or moved after the
    tested ops."""
    got = seg[:len(SPIN_OPS)]
    if got != SPIN_OPS:
        result.fail("P%d window-opener (het_spin) op stream differs -- expected the "
                    "device-scope spin before the tested ops" % pidx)
        for d in diff_sequences(SPIN_OPS, got):
            result.note(d)
        return seg          # strip nothing: let the model-op check report the rest
    result.note("  P%d window-opener OK (device-scope spin: %s)"
                % (pidx, ", ".join(fmt(o) for o in SPIN_OPS)))
    return seg[len(SPIN_OPS):]


def stray_sys_ops(ptx_text):
    """SYSTEM-scope memory ops emitted OUTSIDE the inline-asm markers.

    extract_ptx_ops only sees inline-asm ops -- which is sound for the MODEL ops,
    because libcu++'s scoped atomics and CudaLang's inline PTX both compile to
    asm-volatile.  But it means a system-scope op emitted by a compiler BUILTIN
    (__threadfence_system, atomicAdd_system, ...) would sit outside the markers
    and never be compared against anything.

    B4 is where such an op could hide: the stress layer deliberately uses
    builtins and plain accesses so that its scaffolding stays OUT of the model-op
    stream (correctly -- unordered, device-scope traffic on a disjoint scratchpad
    is not a tested op).  So close the blind spot rather than widen it: no
    SYSTEM-scope memory op may appear outside the inline-asm stream at all.
    Scaffolding is allowed to be invisible precisely because it is device-scope
    and unordered; a system-scope op is never scaffolding -- on this hardware it
    is, by definition, traffic that crosses the CPU-GPU boundary."""
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


def check_observer(result, seg, obs_locs):
    """The observer lane must contribute EXACTLY one relaxed/system-scope load per
    observed location, and nothing else.

    This is NOT a relaxation of the gate.  The observer's loads are real memory ops
    on the tested locations -- a deliberate, documented perturbation, and the only
    way a ws/co edge (which has no read node) is recoverable at all (B3-decision
    5; Srivastava 3.3).  Modelling them makes the EXPECTATION complete; the check
    itself stays exact.  It still fails if the observer is narrowed (sys -> cta),
    strengthened (relaxed -> acquire), or gains/loses a load -- e.g. if someone
    drops the `#pragma unroll 1` that pins its trip count."""
    expected = [OBS_OP] * len(obs_locs)
    if seg != expected:
        result.fail("observer lane op stream differs (observes %s)"
                    % ", ".join(obs_locs))
        for d in diff_sequences(expected, seg):
            result.note(d)
    else:
        result.note("  observer lane OK (%d relaxed/sys load(s): %s)"
                    % (len(expected), ", ".join(obs_locs)))


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
               keep=False, arch=None, verbose=True):
    text = read_litmus(litmus_path)
    kind = litmus_kind(text)
    name = litmus_name(text)
    procs, rows = parse_body(text)

    # transpose rows -> per-column cell lists
    ncol = len(procs)
    cols = [[] for _ in range(ncol)]
    for row in rows:
        for c in range(ncol):
            cols[c].append(row[c] if c < len(row) else '')

    # classify columns; build expected GPU/CPU profiles (completeness guard fires here)
    gpu_expected = []   # list of (proc_idx, [ (kind,order,scope) ])
    cpu_expected = []   # list of (proc_idx, [ (mnemonic,qual) ])
    for col, (pidx, dev) in enumerate(procs):
        dc = device_class(dev)
        if dc == 'gpu':
            gpu_expected.append((pidx, gpu_ops_of_column(cols[col])))
        else:
            cpu_expected.append((pidx, cpu_ops_of_column(cols[col])))

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
            # Default to sm_90 to MATCH the run harness, whose emitted Makefile/
            # run.sh compile the SAME .cu with `CUDA_ARCH ?= sm_90' (GH200) --
            # see litmus/top_litmus.ml.  Checking a different arch than the one
            # that runs would leave a soundness gap; sm_90 is also a superset
            # (it covers cluster scope, Hopper-only).  --arch overrides.
            use_arch = arch or "sm_90"
            ptx_path = os.path.join(tmp, name + ".ptx")
            compile_ptx(cu_path, ptx_path, use_arch)
            with open(ptx_path) as f:
                ptx_text = f.read()
            cpu_c_text = open(cpu_c_path).read() if cpu_c_path else None
            if keep:
                result.note("  artifacts kept in %s" % tmp)

        observed = extract_ptx_ops(ptx_text)

        if kind == 'Het':
            # One barrier instance per barrier-joining GPU lane; segment on the
            # fetch_add anchor and strip the barrier template, leaving each lane's
            # model ops.  A test whose condition names a coherence-final location
            # (`[x]=2`) also gets an OBSERVER lane, emitted LAST (after every GPU
            # proc -- see top_litmus.ml dump_gpu_file, the `blockIdx.x == n_blocks`
            # block).  It joins the barrier and snoops each observed location once.
            n_gpu = len(gpu_expected)
            obs_locs = condition_locations(text)
            n_lanes = n_gpu + (1 if obs_locs else 0)
            barrier_ops, model_per_seg = split_het_segments(observed, n_lanes)
            check_barrier_whitelist(result, barrier_ops, n_lanes)
            if len(model_per_seg) != n_lanes:
                result.fail("expected %d barrier-joining GPU lane(s) (%d proc(s)%s); found %d"
                            % (n_lanes, n_gpu,
                               " + 1 observer" if obs_locs else "",
                               len(model_per_seg)))
            if obs_locs and len(model_per_seg) == n_lanes:
                # The observer snoops; it does NOT stress and does NOT spin (its
                # job is to sample densely, and gating it on the test lanes would
                # couple two lanes that run at different rates).  So it is the one
                # barrier-joining lane with no window-opener: strip it first, then
                # every remaining segment is a test lane and must carry the spin.
                check_observer(result, model_per_seg[-1], obs_locs)
                model_per_seg = model_per_seg[:-1]
            # B4: each GPU TEST lane opens its window with the device-scope spin.
            # Model it (so the expectation is COMPLETE) and check it exactly (so
            # the gate does not go blind to it).
            if len(model_per_seg) == len(gpu_expected):
                model_per_seg = [check_spin(result, seg, gpu_expected[i][0])
                                 for i, seg in enumerate(model_per_seg)]
            model_ops = [op for seg in model_per_seg for op in seg]
            check_gpu(result, gpu_expected, model_ops, "GPU")
            check_no_stray_sys(result, ptx_text)
            if cpu_expected:
                if cpu_c_text is None:
                    result.fail("het test has CPU columns but no _cpu.c emitted")
                else:
                    check_cpu(result, cpu_expected, cpu_c_text)
        else:
            # gpu-only: ALL inline-asm ops are model ops (no barrier, no stress).
            check_gpu(result, gpu_expected, observed, "GPU")
            check_no_stray_sys(result, ptx_text)
    finally:
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in result.lines:
            print(ln)
    return result.ok


def main():
    ap = argparse.ArgumentParser(description="HetLitmus L0 PTX faithfulness checker")
    ap.add_argument("litmus", help=".litmus test path")
    ap.add_argument("--ptx", help="use this PTX file instead of emitting+nvcc (self-test)")
    ap.add_argument("--cpu-c", help="use this _cpu.c instead of emitting (self-test)")
    ap.add_argument("--arch", help="override nvcc -arch (default sm_90, matching the litmus7 run harness CUDA_ARCH)")
    ap.add_argument("--keep", action="store_true", help="keep emitted artifacts")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    try:
        ok = check_test(args.litmus, ptx_override=args.ptx, cpu_c_override=args.cpu_c,
                        keep=args.keep, arch=args.arch, verbose=not args.quiet)
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
