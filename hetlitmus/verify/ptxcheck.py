#!/usr/bin/env python3
# ptxcheck.py -- one emitted CUDA harness carries exactly the memory ops its
# .litmus annotates, read off `nvcc --ptx' with no GPU and no kernel launch
# (hetlitmus/docs/faithfulness.md).  Per test:
#   1. the ordered PTX model-op stream == the .litmus (kind, order, scope)
#   2. (het) the rendezvous is sys-scope, relaxed and fence-free, one arrival
#      per GPU lane, and no model op is emitted ahead of the first arrival
#   3. no system-scope op outside the inline-asm stream
#   4. (het) the CPU column's mnemonics == the emitted _cpu.c asm block
# A miss means the harness does not run the program its .litmus names.
# Exit 0 PASS, 1 FAIL (per-position diff), 2 completeness hard-fail, 3 error.

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ---- repo layout ----------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
NVCC = shutil.which("nvcc") or "/usr/local/cuda/bin/nvcc"

# ---- 1. the mapping table: annotation -> expected PTX / AArch64 profile ----
# It is also the completeness guard: a token that is not a key here hard-fails.

# GPU memory order: LISA/Bell tag -> PTX token, the same spelling either side.
GPU_ORDER = {
    "relaxed": "relaxed",
    "acquire": "acquire",
    "release": "release",
    "acq_rel": "acq_rel",
    "sc":      "sc",
}

# GPU scope: LISA/Bell tag -> PTX scope token, the same spelling either side.
GPU_SCOPE = {
    "cta":     "cta",
    "gpu":     "gpu",
    "sys":     "sys",
}

# Op kind: LISA mnemonic -> expected PTX opcode class.  The corpus has NO RMW,
# and GPU_CELL below, not this table, is what rejects a mnemonic outside {w,r,f}.
GPU_KIND = {
    "w": "st",
    "r": "ld",
    "f": "fence",
}

# CPU (AArch64) mnemonic -> (semantics, is-a-memory-op).  `mov' materialises a
# store's value in a register: recognized, so the guard passes, but NOT compared.
CPU_MNEMONIC = {
    "mov":   ("move",          False),  # folded; not a memory/ordering op
    "str":   ("plain-store",   True),
    "ldr":   ("plain-load",    True),
    "stlr":  ("release-store", True),
    "ldar":  ("acquire-load-rcsc", True),
    "ldapr": ("acquire-load-rcpc", True),
    "dmb":   ("fence",         True),   # SPLIT by option -- see below
}

# A barrier's ordered-pair set lives in its OPTION, not its mnemonic, so the
# compared op tuple is (mnemonic, option) and an unmodelled option hard-fails.
CPU_BARRIER_OPTION = {
    "sy": "fence-full",     # DMB SY : orders {WW,RR,WR,RW}  (full system barrier)
    "st": "fence-store",    # DMB ST : orders {WW}           (the `rel' half only)
    "ld": "fence-load",     # DMB LD : orders {RR,RW}        (the `acq' half only)
}


def barrier_option(mn, tokens, where):
    """The modelled option of a `dmb' (or '' for a non-barrier mnemonic); an
    unmodelled or missing option hard-fails."""
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


# ---- 2. .litmus parsing (hipsrccheck.py imports this section) --------------

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
    """Return ([(proc_index, device_tag)] in column order, the grid rows).  A
    missing device tag is gpu on a LISA test and a hard fail on a `Het' one."""
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
            dev = "gpu"               # a gpu-only LISA test omits the tag
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
    if d in ('cpu', 'x86_64'):
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
    """The rendezvous-joining GPU lanes as (proc, ops, name) in the lane order
    of dump_kernel (litmus/hetGpuFile.ml): the harness's GPU procs in program
    order.  hipsrccheck.check_het unpacks the tuple positionally."""
    return [(pidx, ops, inst['name']) for pidx, ops in inst['gpu']]


# ----- per-column op extraction --------------------------------------------

def gpu_ops_of_column(cells):
    """A GPU column's non-empty cells as ordered (kind, order, scope); an order
    or scope outside the mapping table raises CompletenessError."""
    ops = []
    for c in cells:
        c = c.strip()
        if c == '':
            continue
        m = GPU_CELL.match(c)
        if not m:
            # An RMW or an unknown form, never silently skipped.
            raise CompletenessError("unrecognized GPU cell %r" % c)
        # [wrf] makes op a GPU_KIND key; order and scope are free tokens.
        op, order, scope = m.group(1), m.group(2), m.group(3)
        if order not in GPU_ORDER:
            raise CompletenessError("unknown memory order %r in %r" % (order, c))
        if scope not in GPU_SCOPE:
            raise CompletenessError("unknown scope %r in %r" % (scope, c))
        ops.append((GPU_KIND[op], GPU_ORDER[order], GPU_SCOPE[scope]))
    return ops


def cpu_ops_of_column(cells):
    """A CPU column's cells as ordered (mnemonic, qualifier), memory/ordering
    ops only; a mnemonic outside CPU_MNEMONIC hard-fails."""
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


# ---- 3. emit (.litmus -> .cu [+ _cpu.c]) and compile (.cu -> PTX) ---------

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


# ---- 4. PTX extraction: the observed model ops, in textual order ----------

OPLINE = re.compile(r'^\s*(ld|st|atom|red|fence|membar)\.([a-z0-9_.]+)')


def classify_ptx_op(line):
    """One PTX instruction line as (kind, order, scope), or None for a line
    carrying no order token, which is scaffolding rather than a model op."""
    m = OPLINE.match(line)
    if not m:
        return None
    kind = m.group(1)
    quals = m.group(2).split('.')
    order = next((q for q in quals if q in PTX_ORDERS), None)
    scope = next((q for q in quals if q in PTX_SCOPES), None)
    if kind in ('fence', 'membar'):
        # The qualifiers are read order-agnostically: CudaLang emits
        # fence.<order>.<scope>, libcu++'s barrier fence.<scope>.<order>.
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


# ---- 5. _cpu.c extraction: the real AArch64 asm block only ----------------

ASM_STR = re.compile(r'"\s*([a-zA-Z][a-zA-Z0-9.]*)([^"]*)\\n"')


def extract_cpu_ops(cpu_c_text):
    """Ordered (mnemonic, qualifier) memory ops of the real aarch64 asm block,
    mov excluded; ASM_STR's leading [a-zA-Z] skips litmus7's marker literals."""
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
        # finditer, NOT search: C concatenates adjacent string literals, so one
        # source line can carry two instructions and search would read one.
        for m in ASM_STR.finditer(ln):
            mn = m.group(1).lower()
            rest = m.group(2).strip().lower()
            if mn not in CPU_MNEMONIC:
                raise CompletenessError("unexpected asm mnemonic %r in _cpu.c" % mn)
            _sem, is_mem = CPU_MNEMONIC[mn]
            if not is_mem:
                continue
            qual = barrier_option(mn, rest.replace(',', ' ').split(),
                                  "the emitted _cpu.c asm block (%r)"
                                  % (mn + " " + rest).strip())
            ops.append((mn, qual))
    return ops


# ---- 6. the checks --------------------------------------------------------

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
    """Element-wise equality of the expected and observed model-op streams;
    expected_per_proc is [(proc_label, ops)], observed is the flat PTX stream."""
    expected_flat = [op for _, ops in expected_per_proc for op in ops]
    if observed != expected_flat:
        result.fail("%s ordered model-op stream differs" % label)
        for d in diff_sequences(expected_flat, observed):
            result.note(d)
    else:
        result.note("  %s ordered stream OK (%d ops)" % (label, len(expected_flat)))
    return expected_flat


def split_het_segments(observed):
    """(pre_ops, barrier_ops, model_per_lane) of a het kernel's stream, one model-op
    list per joining lane (faithfulness.md, "Het rendezvous/model separation")."""
    atom_idx = [i for i, op in enumerate(observed)
                if op[0] in ('atom', 'red') and op[2] == 'sys']
    if not atom_idx:
        return [], [], [observed]   # no fetch_add -> barrier check fails separately
    barrier_ops, model_per_segment = [], []
    for k, ai in enumerate(atom_idx):
        end = atom_idx[k + 1] if k + 1 < len(atom_idx) else len(observed)
        seg = observed[ai:end]
        barrier_ops.append(seg[0])                               # the arrival
        bi = 1
        # A fence between arrival and poll belongs to the template, so it reaches
        # check_barrier_whitelist and is named there, not scored as a model op.
        if bi < len(seg) and seg[bi][0] == 'fence':
            barrier_ops.append(seg[bi]); bi += 1
        if bi < len(seg) and seg[bi][0] == 'ld':                 # the poll
            barrier_ops.append(seg[bi]); bi += 1
        model_per_segment.append(seg[bi:])
    return observed[:atom_idx[0]], barrier_ops, model_per_segment


def check_no_pre_barrier_ops(result, pre_ops):
    """NO model op may precede the first rendezvous: an op ahead of it falls
    outside every segment, so it is compared against nothing."""
    if pre_ops:
        result.fail("%d model op(s) emitted BEFORE the first rendezvous barrier -- "
                    "they sit outside every lane segment and are compared against "
                    "nothing" % len(pre_ops))
        for o in pre_ops[:8]:
            result.note("  pre-barrier: %s" % fmt(o))
    else:
        result.note("  no model ops before the first rendezvous barrier")


def check_barrier_whitelist(result, barrier_ops, n_lanes):
    """The het rendezvous spans both devices and orders NOTHING: every op
    system-scoped and relaxed, no fence, one arrival per joining GPU lane."""
    if not barrier_ops:
        result.fail("het kernel has NO rendezvous (expected a sys-scope relaxed atom)")
        return
    # The only scope test the poll gets: a narrowed arrival never enters
    # barrier_ops at all, and the lane count below is what fires on it.
    for op in barrier_ops:
        if op[2] != 'sys':
            result.fail("rendezvous op %s is NOT system scope (weakened/narrowed)"
                        % fmt(op))
    fences = [o for o in barrier_ops if o[0] == 'fence']
    atoms = [o for o in barrier_ops if o[0] in ('atom', 'red')]
    for op in fences:
        result.fail("the rendezvous carries a FENCE (%s) -- it must order nothing "
                    "[Bagchi26 sec 5.3]" % fmt(op))
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
    """System-scope memory ops emitted OUTSIDE the inline-asm markers, where
    extract_ptx_ops cannot see them."""
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
    """The CPU column's ordered mnemonics == the emitted _cpu.c real-asm block:
    catches STLR->STR, LDAPR->LDR, and a DMB dropped or narrowed."""
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


# ---- 7. driver ------------------------------------------------------------

def check_test(litmus_path, ptx_override=None, verbose=True):
    # The Het branch below rebuilds the GPU profile lane by lane; only the
    # gpu-only branch consumes gpu_expected as computed here.
    inst = instance_of(litmus_path)
    kind, name = inst['kind'], inst['name']
    gpu_expected = inst['gpu']   # list of (proc_idx, [ (kind,order,scope) ])

    result = Result()
    result.note("=== %s [%s] ===" % (name, kind))

    # ---- emit + compile, unless --ptx supplies the PTX text ------------------
    tmp = tempfile.mkdtemp(prefix="ptxcheck_")
    try:
        if ptx_override is not None:
            with open(ptx_override) as f:
                ptx_text = f.read()
            cpu_c_text = None
        else:
            cu_path, cpu_c_path = emit_harness(litmus_path, tmp)
            # sm_90: the arch the emitted Makefile/comp.sh build the same .cu
            # with (litmus/hetDialect.ml, gd_arch_default).
            ptx_path = os.path.join(tmp, name + ".ptx")
            compile_ptx(cu_path, ptx_path, "sm_90")
            with open(ptx_path) as f:
                ptx_text = f.read()
            cpu_c_text = open(cpu_c_path).read() if cpu_c_path else None

        observed = extract_ptx_ops(ptx_text)

        if kind == 'Het':
            lanes = het_lane_plan(inst)
            n_lanes = len(lanes)
            pre_ops, barrier_ops, model_per_seg = split_het_segments(observed)
            check_no_pre_barrier_ops(result, pre_ops)
            check_barrier_whitelist(result, barrier_ops, n_lanes)
            if len(model_per_seg) != n_lanes:
                result.fail("expected %d rendezvous-joining GPU lane(s) (%s); found %d"
                            % (n_lanes,
                               ", ".join("%s:P%d" % (l[2], l[0]) for l in lanes),
                               len(model_per_seg)))
            else:
                gpu_expected = []
                model_ops = []
                for (pidx, payload, iname), seg in zip(lanes, model_per_seg):
                    gpu_expected.append(("%s:P%d" % (iname, pidx), payload))
                    model_ops.extend(seg)
                check_gpu(result, gpu_expected, model_ops, "GPU")
            check_no_stray_sys(result, ptx_text)
            cpu_expected = [("%s:P%d" % (name, p), ops) for p, ops in inst['cpu']]
            if cpu_expected:
                if cpu_c_text is None:
                    result.fail("het test has CPU columns but no _cpu.c emitted")
                else:
                    check_cpu(result, cpu_expected, cpu_c_text)
        else:
            # gpu-only: every inline-asm op is a model op, no rendezvous.
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
    ap.add_argument("--ptx", help="read this PTX instead of emitting+nvcc "
                                  "(hetlitmus/tests/cram/ptx-negatives.t)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    try:
        ok = check_test(args.litmus, ptx_override=args.ptx,
                        verbose=not args.quiet)
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
