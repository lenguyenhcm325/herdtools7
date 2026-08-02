#!/usr/bin/env python3
"""
x86bodycheck.py -- the P2b gate: is the x86-64 CPU thread of a het harness REAL?

Until 2026-08-03 `hetCpuFront.ml' wired `HetCpuBody.empty_plan' + `emit_stub' for
X86_64, so an x86 CPU proc emitted

    void het_run_P0(uint64_t *x, uint64_t *y, int _n) { (void)_n; (void)x; (void)y; }

-- a body that tests nothing.  Measured consequence, over the 412 x86 renderings
of the corpus: litmus7 emitted a harness for 39 and REFUSED 373, because with no
tagged store and no bound load the condition could resolve neither a read buffer
(308 rows) nor a mu (65 rows).  And it refused while EXITING 0.

Six phases, each of which must be seen to fail:

  P1 emission coverage   every x86 rendering emits a complete harness
  P2 body fidelity       the emitted body is the test's own program, not a stub
  P3 tag liveness        every store carries K*(_n+1)+mu, every load reaches a
                         buffer (the B4 lesson: emitting is not testing)
  P4 machine code        the tested instructions survive gcc to the .o
  P5 AArch64 unchanged   the aarch64 lane still emits str/ldr/dmb, no x86 leak
  P6 fail-closed         a refusal exits 3, prints HetLitmus REFUSED, leaves no
                         harness -- and emit-all.sh's two detectors both fire

`--bite' injects into each phase, on CORRUPTION and on OMISSION, and requires the
phase that owns the injected object to redden naming it.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")
GEN_X86 = os.path.join(HET_DIR, "generate-x86.sh")
EMIT_ALL = os.path.join(HERE, "emit-all.sh")
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

# The census generate-x86.sh must produce: (A) 2 + (B) 246 + (D) 52 + (E) 112.
# It is 412 rather than the corpus' 411 because IRIW-gcgc-sys-fence-2s has no
# AArch64 twin in tests/het (the cg/gc de-duplication of 2026-08-01 removed it
# there, where it was byte-identical to its sibling; on the x86 lattice the
# rendering is still generated).  Pinned so the set cannot silently shrink.
N_X86 = 412

# Representative harness for the machine-code phase: its x86 CPU proc carries a
# store, a fence AND a load, so one objdump covers the whole vocabulary.
MC_TEST = "SB-cg-sys-fence-2s-x86_64"

# AArch64 tests P5 re-emits (a store proc, a load proc, a two-sided proc).
AARCH64_TESTS = ["2+2W-cg-sys-relaxed", "MP-gc-sys-relaxed", "MP-cg-sys-fence-2s"]

fails = []


def fail(phase, msg):
    fails.append((phase, msg))
    print("  FAIL [%s] %s" % (phase, msg))


def env():
    e = dict(os.environ)
    e["PATH"] = os.path.join(ROOT, "_build", "install", "default", "bin") + os.pathsep + e["PATH"]
    return e


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, env=env(), **kw)


# ---------------------------------------------------------------- test parsing

def parse_litmus(path):
    """Return (name, {proc: [cells]}, {proc: isa}) for one het .litmus."""
    lines = open(path).read().splitlines()
    body = [l for l in lines if "|" in l and l.rstrip().endswith(";")]
    if not body:
        raise SystemExit("x86bodycheck: %s has no program section" % path)
    hdr = [c.strip() for c in body[0].rstrip().rstrip(";").split("|")]
    isa = {}
    for i, c in enumerate(hdr):
        m = re.match(r"P(\d+):(\S+)", c)
        if m:
            isa[i] = m.group(2)
    cells = {i: [] for i in isa}
    for l in body[1:]:
        cs = [c.strip() for c in l.rstrip().rstrip(";").split("|")]
        for i in isa:
            if i < len(cs) and cs[i]:
                cells[i].append(cs[i])
    return os.path.basename(path)[:-len(".litmus")], cells, isa


# x86 het vocabulary, as _grid_lib.sh renders it
RE_ST_IMM = re.compile(r"^mov[bwlq]?\s+\$(\d+),\((\w+)\)$")
RE_ST_REG = re.compile(r"^mov[bwlq]?\s+%(\w+),\((\w+)\)$")
RE_LD = re.compile(r"^mov[bwlq]?\s+\((\w+)\),%(\w+)$")
RE_FENCE = re.compile(r"^([ms]fence|lfence)$")


def expected_nodes(cells):
    """The (kind, global) sequence one x86 column must produce."""
    out = []
    for c in cells:
        m = RE_ST_IMM.match(c) or RE_ST_REG.match(c)
        if m:
            out.append(("store", m.group(2)))
            continue
        m = RE_LD.match(c)
        if m:
            out.append(("load", m.group(1)))
            continue
        m = RE_FENCE.match(c)
        if m:
            out.append(("fence", m.group(1)))
            continue
        raise SystemExit("x86bodycheck: unmodelled x86 cell %r" % c)
    return out


# ------------------------------------------------------------- body extraction

RE_FUNC = re.compile(r"^void (het_run_\w*P(\d+))\(([^)]*)\) \{$")


def host_region(cpu_c):
    """The `#if defined(__x86_64__)' / `#if defined(__aarch64__)' arm only."""
    txt = open(cpu_c).read()
    m = re.search(r"^#if defined\(__\w+__\)\n(.*?)^#else$", txt, re.S | re.M)
    if not m:
        raise SystemExit("x86bodycheck: no host arm in %s" % cpu_c)
    return m.group(1)


def split_bodies(region):
    """{proc: (fname, [lines])} for each het_run_*P<n> in the host arm."""
    bodies, cur, name, proc = {}, None, None, None
    for l in region.splitlines():
        m = RE_FUNC.match(l)
        if m:
            name, proc, cur = m.group(1), int(m.group(2)), []
            continue
        if cur is not None:
            if l == "}":
                bodies[proc] = (name, cur)
                cur = None
            else:
                cur.append(l)
    return bodies


RE_ASM_ST = re.compile(r'^\s*"movq %\[_v(\d+)\],\(%\[(\w+)\]\)\\n"$')
RE_ASM_LD = re.compile(r'^\s*"movq \(%\[(\w+)\]\),%\[_t(\d+)\]\\n"$')
RE_ASM_FEN = re.compile(r'^\s*"([ms]fence|lfence)\\n"$')
RE_TAG = re.compile(r"^\s*uint64_t _v(\d+) = \(uint64_t\)(\d+) \* \(_n \+ 1\) \+ (\d+);$")
RE_TMP = re.compile(r"^\s*uint64_t _t(\d+) = 0;$")
RE_BUF = re.compile(r"^\s*(\w+)\[_n\] = _t(\d+);$")


def body_nodes(lines):
    """The (kind, global) sequence the emitted asm block actually performs."""
    out = []
    for l in lines:
        m = RE_ASM_ST.match(l)
        if m:
            out.append(("store", m.group(2)))
            continue
        m = RE_ASM_LD.match(l)
        if m:
            out.append(("load", m.group(1)))
            continue
        m = RE_ASM_FEN.match(l)
        if m:
            out.append(("fence", m.group(1)))
            continue
    return out


# ------------------------------------------------------------------- P1 + P2/3

def emit_corpus(tmp, corpus):
    """Emit every rendering in [corpus]; return {name: harness dir}, refusals."""
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    good, bad = {}, []
    for f in sorted(os.listdir(corpus)):
        if not f.endswith(".litmus"):
            continue
        n = f[:-len(".litmus")]
        r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", out, os.path.join(corpus, f)])
        blob = r.stdout + r.stderr
        d = os.path.join(out, n)
        parts = [os.path.join(d, n + s) for s in ("_cpu.c", ".cu", ".hip")]
        if r.returncode != 0:
            bad.append((n, "litmus7 exited %d: %s" % (r.returncode, blob.strip().splitlines()[-1:])))
        elif "HetLitmus REFUSED" in blob:
            bad.append((n, "REFUSED marker on stderr"))
        elif not all(os.path.exists(p) and os.path.getsize(p) for p in parts):
            missing = [os.path.basename(p) for p in parts
                       if not (os.path.exists(p) and os.path.getsize(p))]
            bad.append((n, "harness incomplete: missing %s" % ", ".join(missing)))
        else:
            good[n] = d
    return good, bad


def phase1(corpus, good, bad):
    print("== P1  emission coverage (was 39/412 with the stub) ==")
    n = len([f for f in os.listdir(corpus) if f.endswith(".litmus")])
    if n != N_X86:
        fail("P1", "generate-x86.sh produced %d renderings, expected %d" % (n, N_X86))
    for name, why in bad:
        fail("P1", "%s did not emit a complete harness (%s)" % (name, why))
    print("  emitted %d / %d x86 renderings" % (len(good), n))


def phase2(corpus, good):
    print("== P2  body fidelity: the emitted body IS the test's x86 column ==")
    checked = 0
    for name, d in sorted(good.items()):
        _, cells, isa = parse_litmus(os.path.join(corpus, name + ".litmus"))
        cpu_c = os.path.join(d, name + "_cpu.c")
        region = host_region(cpu_c)
        if "(void)_n;" in region:
            fail("P2", "%s: the host arm still carries a STUB body ((void)_n)" % name)
            continue
        bodies = split_bodies(region)
        for p, tag in isa.items():
            if tag != "x86_64":
                continue
            want = expected_nodes(cells[p])
            hit = [b for pp, b in bodies.items() if pp == p]
            if not hit:
                fail("P2", "%s: no het_run_*P%d in the host arm" % (name, p))
                continue
            for (_fname, lines) in hit:
                got = body_nodes(lines)
                if got != want:
                    fail("P2", "%s P%d: emitted %r but the test says %r" % (name, p, got, want))
                checked += 1
    print("  %d x86 proc body/column comparisons made" % checked)


def phase3(good):
    print("== P3  tag liveness: stores tag, loads reach a buffer ==")
    nst = nld = 0
    for name, d in sorted(good.items()):
        region = host_region(os.path.join(d, name + "_cpu.c"))
        for p, (fname, lines) in sorted(split_bodies(region).items()):
            tags = {int(m.group(1)): (int(m.group(2)), int(m.group(3)))
                    for m in (RE_TAG.match(l) for l in lines) if m}
            tmps = {int(m.group(1)) for m in (RE_TMP.match(l) for l in lines) if m}
            bufs = {int(m.group(2)): m.group(1)
                    for m in (RE_BUF.match(l) for l in lines) if m}
            st = [int(m.group(1)) for m in (RE_ASM_ST.match(l) for l in lines) if m]
            ld = [int(m.group(2)) for m in (RE_ASM_LD.match(l) for l in lines) if m]
            if '  asm __volatile__(' not in lines:
                fail("P3", "%s %s: the block is not asm __volatile__" % (name, fname))
            if '    : "memory","cc");' not in lines:
                fail("P3", "%s %s: the block does not clobber memory" % (name, fname))
            for i in st:
                if i not in tags:
                    fail("P3", "%s %s: store operand _v%d has no K*(_n+1)+mu tag" % (name, fname, i))
                    continue
                k, mu = tags[i]
                if k < 1 or mu < 1:
                    fail("P3", "%s %s: _v%d tag is K=%d mu=%d (a constant store)"
                         % (name, fname, i, k, mu))
                nst += 1
            mus = [tags[i][1] for i in st if i in tags]
            if len(set(mus)) != len(mus):
                fail("P3", "%s %s: two stores share a mu %r -- recovery cannot tell them apart"
                     % (name, fname, mus))
            for i in ld:
                if i not in tmps:
                    fail("P3", "%s %s: load into _t%d that is never declared" % (name, fname, i))
                if i not in bufs:
                    fail("P3", "%s %s: load _t%d is never recorded into a buffer" % (name, fname, i))
                nld += 1
    print("  %d tagged stores, %d buffered loads" % (nst, nld))


def phase4(tmp, good):
    print("== P4  machine code: the tested instructions survive gcc ==")
    if MC_TEST not in good:
        fail("P4", "%s did not emit, so no object could be built" % MC_TEST)
        return
    cpu_c = os.path.join(good[MC_TEST], MC_TEST + "_cpu.c")
    ok, why = objdump_ok(tmp, cpu_c, "P4")
    if ok:
        print("  %s: het_run_P0 contains store + mfence + load in program order" % MC_TEST)
    else:
        fail("P4", "%s: %s" % (MC_TEST, why))


def objdump_ok(tmp, cpu_c, phase):
    obj = os.path.join(tmp, "mc.o")
    r = run(["gcc", "-O2", "-c", cpu_c, "-I", os.path.dirname(cpu_c), "-o", obj])
    if r.returncode != 0:
        return False, "gcc refused it: %s" % r.stderr.strip()[:400]
    r = run(["objdump", "-d", obj])
    if r.returncode != 0:
        return False, "objdump failed: %s" % r.stderr.strip()[:200]
    # Slice from the symbol header to the next one.  Not `(.*?)\n\n': at -O2
    # het_run_P0 can be the LAST function in .text, and then no blank line
    # follows it -- which is how this extraction first went (wrongly) red.
    parts = re.split(r"^[0-9a-f]+ <[^>]+>:$", r.stdout, flags=re.M)
    names = re.findall(r"^[0-9a-f]+ <([^>]+)>:$", r.stdout, flags=re.M)
    if "het_run_P0" not in names:
        return False, "no het_run_P0 in the object (symbols: %r)" % names
    txt = parts[names.index("het_run_P0") + 1]
    seq = []
    for l in txt.splitlines():
        ins = l.split("\t")[-1].strip()
        if re.match(r"^mov\s+%r\w+,\(%r\w+\)$", ins):
            seq.append("store")
        elif re.match(r"^mov\s+\(%r\w+\),%r\w+$", ins):
            seq.append("load")
        elif ins.startswith("mfence"):
            seq.append("mfence")
    # store ; mfence ; load, with the buffer write (another store) after
    if seq[:3] != ["store", "mfence", "load"]:
        return False, "het_run_P0 machine code is %r, expected store,mfence,load first" % seq[:4]
    return True, ""


def emit_aarch64(out):
    os.makedirs(out, exist_ok=True)
    for t in AARCH64_TESTS:
        run([LITMUS7, "-set-libdir", LIBDIR, "-o", out, t + ".litmus"], cwd=HET_DIR)
    return out


def phase5(tmp, out=None):
    print("== P5  the AArch64 lane is byte-unchanged in kind ==")
    if out is None:
        out = emit_aarch64(os.path.join(tmp, "aarch64"))
    for t in AARCH64_TESTS:
        cpu_c = os.path.join(out, t, t + "_cpu.c")
        if not os.path.exists(cpu_c):
            fail("P5", "%s did not emit an aarch64 CPU file" % t)
            continue
        txt = open(cpu_c).read()
        if "hetCpuBodyX86" in txt:
            fail("P5", "%s: the aarch64 harness names the x86 body emitter" % t)
        if "movq " in txt:
            fail("P5", "%s: x86 mnemonics leaked into the aarch64 harness" % t)
        region = host_region(cpu_c)
        if not re.search(r'"(str|stlr|ldr|ldar|ldapr) %x\[', region):
            fail("P5", "%s: the aarch64 body carries no str/ldr %%x operand" % t)
    print("  %d aarch64 harnesses checked for str/ldr %%x and for x86 leakage"
          % len(AARCH64_TESTS))


def phase6(tmp, corpus):
    print("== P6  fail-closed: a refusal exits 3 and emits nothing ==")
    src = os.path.join(corpus, "MP-gc-sys-relaxed-x86_64.litmus")
    bad = os.path.join(tmp, "REFUSEME.litmus")
    txt = open(src).read()
    # name a register no proc loads into: the condition can bind no read buffer
    bent = txt.replace("1:rax=", "1:rcx=")
    if bent == txt:
        fail("P6", "could not build a refusable test from %s" % src)
        return
    open(bad, "w").write(bent)
    out = os.path.join(tmp, "refuse")
    os.makedirs(out, exist_ok=True)
    r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", out, bad])
    if r.returncode != 3:
        fail("P6", "litmus7 exited %d on a test it cannot emit, expected 3" % r.returncode)
    if "HetLitmus REFUSED" not in r.stderr:
        fail("P6", "no `HetLitmus REFUSED' marker on stderr; got %r" % r.stderr.strip()[-200:])
    left = [d for d in os.listdir(out) if os.path.isdir(os.path.join(out, d))]
    if left:
        fail("P6", "a refused test left harness directories behind: %r" % left)
    print("  litmus7 exit=%d, marker printed, %d directories left behind"
          % (r.returncode, len(left)))


# ------------------------------------------------------------------------ bite

STUB_OMIT = r"""#!/usr/bin/env bash
# BITE stand-in: real litmus7, then delete one test's _cpu.c.  Exits 0 and
# prints nothing unusual, so ONLY emit-all.sh's omission detector can see it.
REAL=%s
VICTIM=%s
"$REAL" "$@" ; st=$?
outdir=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && outdir="$a"; prev="$a"; done
[ -n "$outdir" ] && rm -f "$outdir/$VICTIM/${VICTIM}_cpu.c"
exit $st
"""

STUB_REFUSE = r"""#!/usr/bin/env bash
# BITE stand-in: real litmus7, then print the refusal marker while EXITING 0.
# ONLY emit-all.sh's marker grep can see this.
REAL=%s
"$REAL" "$@" ; st=$?
case "$*" in *%s*) echo "HetLitmus REFUSED (het) injected: bite" >&2 ;; esac
exit $st
"""


def emit_all_bite(tmp, label, script, want):
    path = os.path.join(tmp, "litmus7-" + label)
    open(path, "w").write(script)
    os.chmod(path, 0o755)
    e = dict(os.environ)
    e["HET_LITMUS7"] = path
    out = os.path.join(tmp, "ea-" + label)
    shutil.rmtree(out, ignore_errors=True)
    r = subprocess.run(["bash", EMIT_ALL, out], capture_output=True, text=True, env=e)
    blob = r.stdout + r.stderr
    if r.returncode == 0:
        print("  *** DID NOT BITE [%s]: emit-all.sh reported success" % label)
        return False
    if want not in blob:
        print("  *** WRONG REASON [%s]: expected %r, got:\n%s" % (label, want, blob[-500:]))
        return False
    line = [l for l in blob.splitlines() if l.startswith("FAIL:")]
    print("  bite %-8s -> %s" % (label, line[0] if line else blob.strip()[-160:]))
    return True


def bite(tmp, corpus, good):
    print("===== X86BODYCHECK BITE =====")
    ok = True

    # --- P1: CORRUPTION of a rendering -> that test must stop emitting -------
    scratch = os.path.join(tmp, "bite-corpus")
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.copytree(corpus, scratch)
    victim = "MP-gc-sys-relaxed-x86_64"
    p = os.path.join(scratch, victim + ".litmus")
    t = open(p).read()
    open(p, "w").write(t.replace("1:rax=", "1:rcx="))
    g2, b2 = emit_corpus(os.path.join(tmp, "b1"), scratch)
    fails.clear()
    phase1(scratch, g2, b2)
    if not any(ph == "P1" and victim in m for ph, m in fails):
        print("  *** DID NOT BITE [P1/corrupt]: %s still passed P1" % victim)
        ok = False
    else:
        print("  bite P1/corrupt  -> %s" % fails[0][1])
    fails.clear()

    # --- P1: OMISSION of a rendering -> the census pin must fire -------------
    os.remove(os.path.join(scratch, victim + ".litmus"))
    g3, b3 = emit_corpus(os.path.join(tmp, "b1b"), scratch)
    phase1(scratch, g3, b3)
    if not fails:
        print("  *** DID NOT BITE [P1/omit]: a corpus short one rendering passed P1")
        ok = False
    else:
        print("  bite P1/omit     -> %s" % fails[0][1])
    fails.clear()

    # --- P2: the STUB body itself -- the exact regression this gate exists for
    d = good[victim]
    src = os.path.join(d, victim + "_cpu.c")
    stubbed = os.path.join(tmp, "stub")
    shutil.rmtree(stubbed, ignore_errors=True)
    shutil.copytree(d, os.path.join(stubbed, victim))
    txt = open(src).read()
    # replay emit_stub's output verbatim into the host arm
    stub = ("void het_run_P1(uint64_t *x, uint64_t *y, uint64_t *bufP1_0, "
            "uint64_t *bufP1_1, int _n) {\n"
            "  /* x86_64 het CPU body: compile-only stub */\n"
            "  (void)_n;\n  (void)x;\n  (void)y;\n"
            "  (void)bufP1_0;\n  (void)bufP1_1;\n}\n")
    host = host_region(src)
    open(os.path.join(stubbed, victim, victim + "_cpu.c"), "w").write(
        txt.replace(host, stub))
    saved = list(fails)
    fails.clear()
    phase2(corpus, {victim: os.path.join(stubbed, victim)})
    if not fails:
        print("  *** DID NOT BITE [P2/stub]: the old stub body passed P2")
        ok = False
    else:
        print("  bite P2/stub     -> %s" % fails[0][1])
    fails.clear()

    # --- P2: OMISSION of one instruction from the emitted body ---------------
    dropped = os.path.join(tmp, "drop")
    shutil.rmtree(dropped, ignore_errors=True)
    shutil.copytree(d, os.path.join(dropped, victim))
    f = os.path.join(dropped, victim, victim + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r'^\s*"movq \(%\[\w+\]\),%\[_t1\]\\n"\n', "", t, count=1, flags=re.M)
    if t2 == t:
        print("  *** VACUOUS BITE [P2/drop]: no load line to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        phase2(corpus, {victim: os.path.join(dropped, victim)})
        if not fails:
            print("  *** DID NOT BITE [P2/drop]: a body missing one tested load passed P2")
            ok = False
        else:
            print("  bite P2/drop     -> %s" % fails[0][1])
        fails.clear()

    # --- P3: CORRUPTION of the tag -> a constant store ------------------------
    const = os.path.join(tmp, "const")
    shutil.rmtree(const, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(const, MC_TEST))
    f = os.path.join(const, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r"uint64_t _v0 = \(uint64_t\)\d+ \* \(_n \+ 1\) \+ \d+;",
                "uint64_t _v0 = (uint64_t)0 * (_n + 1) + 0;", t, count=1)
    if t2 == t:
        print("  *** VACUOUS BITE [P3/const]: no tag to flatten")
        ok = False
    else:
        open(f, "w").write(t2)
        phase3({MC_TEST: os.path.join(const, MC_TEST)})
        if not fails:
            print("  *** DID NOT BITE [P3/const]: a constant store tag passed P3")
            ok = False
        else:
            print("  bite P3/const    -> %s" % fails[0][1])
        fails.clear()

    # --- P3: OMISSION of the buffer write -------------------------------------
    nobuf = os.path.join(tmp, "nobuf")
    shutil.rmtree(nobuf, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(nobuf, MC_TEST))
    f = os.path.join(nobuf, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = re.sub(r"^\s*\w+\[_n\] = _t0;\n", "", t, count=1, flags=re.M)
    if t2 == t:
        print("  *** VACUOUS BITE [P3/nobuf]: no buffer write to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        phase3({MC_TEST: os.path.join(nobuf, MC_TEST)})
        if not fails:
            print("  *** DID NOT BITE [P3/nobuf]: a load that reaches no buffer passed P3")
            ok = False
        else:
            print("  bite P3/nobuf    -> %s" % fails[0][1])
        fails.clear()

    # --- P4: OMISSION of the fence from the compiled body ---------------------
    nofence = os.path.join(tmp, "nofence")
    shutil.rmtree(nofence, ignore_errors=True)
    shutil.copytree(good[MC_TEST], os.path.join(nofence, MC_TEST))
    f = os.path.join(nofence, MC_TEST, MC_TEST + "_cpu.c")
    t = open(f).read()
    t2 = t.replace('    "mfence\\n"\n', "", 1)
    if t2 == t:
        print("  *** VACUOUS BITE [P4/nofence]: no mfence to remove")
        ok = False
    else:
        open(f, "w").write(t2)
        good2, why = objdump_ok(tmp, f, "P4")
        if good2:
            print("  *** DID NOT BITE [P4/nofence]: a fenceless object passed P4")
            ok = False
        else:
            print("  bite P4/nofence  -> %s" % why)

    # --- P5: CORRUPTION -- an x86 mnemonic inside an aarch64 harness ----------
    a64 = emit_aarch64(os.path.join(tmp, "a64bite"))
    t0 = AARCH64_TESTS[0]
    f = os.path.join(a64, t0, t0 + "_cpu.c")
    t = open(f).read()
    t2 = t.replace('"str %x[', '"movq %x[')
    if t2 == t:
        print("  *** VACUOUS BITE [P5/leak]: no str %x[ to replace")
        ok = False
    else:
        open(f, "w").write(t2)
        fails.clear()
        phase5(tmp, out=a64)
        if not fails:
            print("  *** DID NOT BITE [P5/leak]: an aarch64 harness carrying movq passed P5")
            ok = False
        else:
            print("  bite P5/leak     -> %s" % fails[0][1])
        fails.clear()

    # --- P5: OMISSION -- an aarch64 harness that never emitted ----------------
    a64b = emit_aarch64(os.path.join(tmp, "a64omit"))
    os.remove(os.path.join(a64b, t0, t0 + "_cpu.c"))
    fails.clear()
    phase5(tmp, out=a64b)
    if not fails:
        print("  *** DID NOT BITE [P5/omit]: a missing aarch64 CPU file passed P5")
        ok = False
    else:
        print("  bite P5/omit     -> %s" % fails[0][1])
    fails.clear()

    # --- P6: the two emit-all.sh detectors, each alone ------------------------
    ok &= emit_all_bite(tmp, "omit", STUB_OMIT % (LITMUS7, "MP-gc-cta-fence"),
                        "emitted no MP-gc-cta-fence/MP-gc-cta-fence_cpu.c")
    ok &= emit_all_bite(tmp, "refuse", STUB_REFUSE % (LITMUS7, "MP-cg-cta-acquire"),
                        "litmus7 REFUSED MP-cg-cta-acquire.litmus")

    fails.clear()
    print()
    if ok:
        print("X86BODYCHECK BITE OK (every injection reddened its own phase)")
        return 0
    print("X86BODYCHECK BITE FAILED")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove each phase FAILS on corruption and on omission")
    a = ap.parse_args()

    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("x86bodycheck: %s not built (run 'make all')" % LITMUS7)

    tmp = tempfile.mkdtemp(prefix="x86bodycheck.")
    try:
        corpus = os.path.join(tmp, "corpus")
        r = run(["bash", GEN_X86, corpus])
        if r.returncode != 0:
            raise SystemExit("x86bodycheck: generate-x86.sh failed:\n" + r.stderr)
        print(r.stdout.strip())
        good, bad = emit_corpus(tmp, corpus)

        if a.bite:
            return bite(tmp, corpus, good)

        print("===== X86BODYCHECK: is the x86-64 CPU thread of a het harness REAL? =====")
        phase1(corpus, good, bad)
        phase2(corpus, good)
        phase3(good)
        phase4(tmp, good)
        phase5(tmp)
        phase6(tmp, corpus)
        print("=" * 70)
        if fails:
            print("X86BODYCHECK FAILED: %d assertion(s)" % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            return 1
        print("X86BODYCHECK: PASS (%d/%d x86 renderings emit a real tagged body)"
              % (len(good), N_X86))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
