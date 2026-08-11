#!/usr/bin/env python3
"""
hipbuildcheck.py -- the P2c gate: can an AMD harness actually be BUILT AND RUN?

Until 2026-08-03 `hetEmit.ml' contained zero occurrences of hip-link / hip-bin.
comp.sh's `hip' arm was COMPILE-ONLY (`hipcc -c'), so nothing this suite emits
could be turned into an AMD executable at all: the CUDA lane had `cuda-link' and
`make cuda-bin', the HIP lane had no counterpart.  Emitting a .hip that no target
links is the same defect class as the .hip that, until B5, no gate compiled.

Seven phases, each of which must be seen to fail:

  P1 build-script arms   the emitted comp.sh / Makefile CARRY hip-link + hip-bin,
                         advertise them in their usage/help text, and hip-bin is
                         .PHONY.  AND `make <test>' REFUSES -- checked by RUNNING
                         it: making both link targets phony removed the only rule
                         naming ./<test>, so make fell through to its built-in
                         `%: %.o' rule and linked it with $(CC), guard and device
                         code both gone
  P2 compile             hipcc --offload-arch=gfx942 compiles the emitted .hip
  P3 link                comp.sh hip-link AND make hip-bin each produce an ELF
                         that carries a real amdgcn gfx942 code object -- not
                         merely an exit status
  P4 fail-closed on the wrong host: a pair in no row of litmus/hetMachine.ml is
                         WARNED about, not refused -- (AArch64, hip) emits, the
                         warning names the pair, and the render it writes stamps
                         not one machine define; a registered pair's link arms
                         do refuse an AArch64 rendering on an x86_64 host,
                         naming the ISA and leaving no binary (the CPU object
                         here is the portable shim, so the binary would test
                         nothing); and the HIP render carries that same guard,
                         keyed to its own host ISA
  P5 no silent stale     every vendor writes ./<test> on purpose (run-one.sh and
                         campaign.py exec ./<test> and are vendor-agnostic), so
                         each link target must ALWAYS relink.  MEASURED before
                         the fix: `make cuda-bin' after `make hip-bin' printed
                         "Nothing to be done for 'cuda-bin'", exited 0 and left
                         the gfx942 binary in place
  P6 allocator           the HIP shared allocator resolves ONE mode and REFUSES
                         every other spelling and every unmet precondition
                         (rule 8), classifies APU vs discrete, IS ACTUALLY CALLED
                         by gd_alloc_shared and called BEFORE the allocation, and
                         refuses the CUDA-only HET_PLACE lever at compile time
  P7 CUDA non-regression the cuda / cuda-link / cuda-bin arms still carry their
                         guard and still build

NO FENCE IS COMPILED HERE.  The test this gate builds carries none, and neither
does the other AMD compile path (smoke.sh rep 8), so the emitter's
__builtin_amdgcn_fence lowering is compiled by no target at all; litmus/HipLang.ml
(hip_fence_scope) is the one home for what that leaves unchecked.

CORRECTNESS IN ISOLATION IS NOT THE MECHANISM BEING LIVE.  P6 drives the resolver
out-of-line, so on its own it would pass a harness that never calls it -- and on
2026-08-03 it did: deleting gd_alloc_shared's one `(void)_het_alloc_mode();' left
this gate at 69/69 PASS, cram green and `make hetlitmus-test' green, while the
binary ignored HET_ALLOC and both device preconditions until teardown.  P6(e)
therefore pins the CALL SITE, scoped to gd_alloc_shared's body and to its order
against the allocation.  The same shape, one layer up, is why P1 RUNS `make
<test>' instead of grepping for it: the defect there was an ABSENT rule.

P6 IS A RUNTIME PHASE WITHOUT AN AMD GPU.  There is no AMD device on this box
(`rocminfo' reports 0 gfx agents), so the linked harness cannot be run: it exits
2 at its cooperative-launch capability check.  Rather than assert nothing, P6
lifts the resolver OUT of the emitted .hip verbatim and drives it against a stub
`hipDeviceGetAttribute' whose answers this gate chooses, so every refusal path is
genuinely EXECUTED and its message observed.  What stays deferred to Phase 3a
(MI300X) is the real hipMallocManaged / coherence behaviour, which no shim can
stand in for.

NON-VACUITY.  Every phase counts its own assertions and FAILS if it made none --
a phase that silently stopped checking is this project's recurring failure (B4's
inert stress, B6a's constant-0 `exhaustive_valid', the faithfulness gate reading
0/338 while reporting success).

`--bite' injects into each phase, on CORRUPTION and on OMISSION, and requires the
phase that owns the injected object to redden naming it.

ONE VENDOR PER HARNESS DIRECTORY.  litmus7 renders the dialect `-gpu-target'
names and no other (litmus/hetDialect.ml), so the AMD arms and the CUDA arms no
longer live in one directory: this gate emits the same x86 test twice, and P7
reads the cuda render while P1-P3/P5/P6 read the hip one.  P5's cross-vendor
stale-link trap needs both, so it plants one vendor's linked binary in the other
vendor's directory -- the state the trap needs (a ./<test> NEWER than the
objects, carrying the wrong device image), reached the way a reused results tree
reaches it.

AND ONE PAIR PER HARNESS.  A harness is a (CPU ISA x GPU dialect) pair, and
litmus/hetMachine.ml says which of them may name a machine.  The AMD phases
therefore run on the x86 rendering -- (x86_64, hip) is the pair with the MI300A
row -- and the AArch64 half of P4 runs on (AArch64, cuda), which is the AArch64
pair that names a machine; that (AArch64, hip) emits and names none is itself one
of P4's assertions.
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
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

# The x86_64 rendering is the one that can be LINKED here: its CPU thread is real
# x86-64 asm (P2b) and this gate's host is x86_64, so the uname guard admits it.
# MP-cg-sys-acqrel-2s is the co-run shape -- three instances, a shared arena --
# so it exercises gd_alloc_shared on the arena path rather than the per-variable
# one.  Its AArch64 twin is P4's refusal probe, on this same x86_64 host.
X86_TEST = "MP-cg-sys-acqrel-2s-x86_64"
AARCH64_TEST = "MP-cg-sys-acqrel-2s"

# MI300A / MI300X.  Both parts report gfx942; hipDeviceAttributeIntegrated is
# what separates them, and P6 checks the harness reads it.
HIP_ARCH = "gfx942"
# The offload triple hipcc stamps into the executable's .hip_fatbin.  P3 greps
# for THIS, not for the exit status: a link that produced a host-only binary
# would exit 0 and carry no device code.
OFFLOAD_TRIPLE = "amdgcn-amd-amdhsa--" + HIP_ARCH

# The HIP render implements ONE shared-memory mode.  Every other spelling, and
# every unmet device precondition, must exit(2).
HIP_ACCEPTED_MODES = ["", "auto", "managed"]
HIP_REFUSED_MODES = ["malloc", "pinned", "bogus", "AUTO", "Managed", " auto"]

fails = []
counts = {}


def fail(phase, msg):
    fails.append((phase, msg))
    print("  FAIL [%s] %s" % (phase, msg))


def tick(phase, n=1):
    counts[phase] = counts.get(phase, 0) + n


def run(cmd, cwd=None, shell=False):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, shell=shell)


def have(tool):
    return shutil.which(tool) is not None


# --------------------------------------------------------------- emission

def emit(tmp, src, outroot, label, target):
    """litmus7 -gpu-target target -o outroot src; return the harness dir it wrote."""
    os.makedirs(outroot, exist_ok=True)
    r = run([LITMUS7, "-gpu-target", target, "-set-libdir", LIBDIR, "-o", outroot, src])
    name = os.path.basename(src)[: -len(".litmus")]
    d = os.path.join(outroot, name)
    if not os.path.isdir(d):
        raise SystemExit("hipbuildcheck: litmus7 emitted no %s harness for %s (%s)\n%s%s"
                         % (target, label, name, r.stdout, r.stderr))
    return d


def emit_unregistered(src, outroot, target):
    """A pair in no row of the machine table.  Returns (exit, output, harness dir)."""
    os.makedirs(outroot, exist_ok=True)
    r = run([LITMUS7, "-gpu-target", target, "-set-libdir", LIBDIR, "-o", outroot, src])
    name = os.path.basename(src)[: -len(".litmus")]
    return r.returncode, r.stdout + r.stderr, os.path.join(outroot, name)


def fresh(tmp, d, tag):
    """A pristine copy of harness dir [d], so bites never contaminate a later phase.
       The copy KEEPS the harness's own basename: test_of() reads it, and a copy
       called `w-p2' would silently make every <test>_hip.o assertion look for a
       file named after the scratch directory instead of the test."""
    w = os.path.join(tmp, "w-" + tag, os.path.basename(d))
    shutil.rmtree(os.path.dirname(w), ignore_errors=True)
    os.makedirs(os.path.dirname(w))
    shutil.copytree(d, w)
    return w


def test_of(d):
    return os.path.basename(d)


def fn_body(src, name):
    """The text of top-level function [name], from its `static ... name(' line to
       the closing brace in column 0.  Scoped on purpose: a whole-file grep for
       `_het_alloc_mode()' passes on a harness that defines the resolver, calls it
       in gd_free_shared, and never calls it where it has to run -- which is
       exactly the hole this exists to close."""
    m = re.search(r"^static [^\n]*\b%s\(" % re.escape(name), src, re.M)
    if not m:
        return None
    e = re.compile(r"^\}", re.M).search(src, m.end())
    return src[m.start():e.end()] if e else None


def has_gfx(binpath):
    """Does this ELF carry a real gfx942 device image?  Read the bytes, do not
       trust the linker's exit status."""
    if not os.path.isfile(binpath):
        return False
    with open(binpath, "rb") as f:
        return OFFLOAD_TRIPLE.encode() in f.read()


# ------------------------------------------------------------------ phases

def phase1(tmp, d):
    print("[P1] build-script arms: comp.sh hip-link + Makefile hip-bin")
    t = test_of(d)
    comp = open(os.path.join(d, "comp.sh")).read()
    mk = open(os.path.join(d, "Makefile")).read()
    # comp.sh: the arm, the usage banner, the unknown-target refusal and the
    # success line must all know it.  The refusal quotes the rejected argument
    # back and names the accepted set, so it is pinned as one string.
    for what, pat, blob, where in [
        ("hip-link case arm", r"^\s*hip\|hip-link\)", comp, "comp.sh"),
        ("hip-link usage banner", r"Usage: sh comp\.sh \[hip\|hip-link\]", comp, "comp.sh"),
        ("unknown-target refusal", r'comp\.sh: unknown target .*this directory is '
                                   r'hip-only \(accepted: hip\|hip-link\)', comp, "comp.sh"),
        ("hip-link success line", r'^if \[ "\$TARGET" = hip-link \]; then$', comp, "comp.sh"),
        ("hip-bin rule", r"^hip-bin: %s_hip\.o outs\.o %s_cpu_host\.o$" % (re.escape(t), re.escape(t)), mk, "Makefile"),
        ("hip-bin .PHONY", r"^\.PHONY:.*\bhip-bin\b", mk, "Makefile"),
        # Making both link targets phony removed the only rule naming ./<test>,
        # so make fell through to its BUILT-IN `%: %.o' -- see the behavioural
        # check below, which is the one that actually matters.
        ("./<test> refusal rule", r"^%s:$" % re.escape(t), mk, "Makefile"),
        ("built-in rules disabled", r"^\.SUFFIXES:$", mk, "Makefile"),
        ("./<test> .PHONY", r"^\.PHONY:.*\b%s\b" % re.escape(t), mk, "Makefile"),
    ]:
        tick("P1")
        if not re.search(pat, blob, re.M):
            fail("P1", "%s missing from emitted %s (/%s/)" % (what, where, pat))
    # The link line must name the HIP objects and the HIP compiler, not the CUDA
    # ones: a hip-bin recipe that linked <t>.o would build the CUDA harness under
    # the AMD target's name.
    tick("P1")
    if not re.search(r"\$\(HIPCC\) --offload-arch=\$\(HIP_ARCH\) \$\^ -o %s " % re.escape(t), mk):
        fail("P1", "Makefile hip-bin does not link with $(HIPCC) --offload-arch=$(HIP_ARCH) into ./%s" % t)
    tick("P1")
    if not re.search(r"HIP_ARCH \?= %s" % HIP_ARCH, mk):
        fail("P1", "Makefile does not default HIP_ARCH to %s (MI300A)" % HIP_ARCH)
    # This directory is the HIP render (-gpu-target hip), so the CUDA arms must
    # be ABSENT -- P7 reads them in the cuda render's own directory.  A dir that
    # still carried both would mean the target filter stopped filtering.
    for where, blob in [("comp.sh", comp), ("Makefile", mk)]:
        tick("P1")
        if re.search(r"\bcuda\b|\bCUDA\b|\bNVCC\b", blob):
            fail("P1", "the HIP render's %s still carries CUDA arms -- `-gpu-target "
                       "hip' must emit one vendor's build targets only" % where)

    make_test_refuses(tmp, d, "P1", "hip-bin")
    print("      %d assertions" % counts.get("P1", 0))
    if not counts.get("P1"):
        fail("P1", "phase made no assertions")


def make_test_refuses(tmp, d, phase, link_target):
    """`make <test>' MUST REFUSE -- checked by RUNNING it, because the defect it
       guards was invisible to every grep.  MEASURED 2026-08-03: with the link
       targets phony and no rule naming ./<test>, `make <test>' on an emitted x86
       harness ran `cc <test>.o -o <test>' under `[<builtin>]' -- GNU make's
       built-in `%: %.o' link rule, which never consults the uname -m guard.  It
       failed there only because those objects carry CUDA/C++ symbols; the guard
       is not what stopped it.  The hole was the ABSENCE of a rule, so no grep of
       the Makefile would have shown it.
       Run on EVERY render: the built-in rule can only fire where the GPU object
       is <test>.o, i.e. on the CUDA render, so checking the HIP one alone would
       leave the reachable case unchecked."""
    t = test_of(d)
    for label, pre_touch in [("./%s absent" % t, False), ("./%s already present" % t, True)]:
        w = fresh(tmp, d, "%smake-%d" % (phase.lower(), int(pre_touch)))
        b = os.path.join(w, t)
        if pre_touch:
            # A plain (non-phony) rule whose target exists is "up to date": make
            # would exit 0 printing nothing and hand back whatever binary was
            # lying there.  That is the stale-link failure again, so the refusal
            # has to survive the file existing.
            open(b, "w").write("stale")
        r = run(["make", t], cwd=w)
        blob = r.stdout + r.stderr
        tick(phase)
        if r.returncode == 0:
            fail(phase, "`make %s' (%s) EXITED 0 -- it must refuse: linking ./%s "
                        "directly bypasses the uname -m guard the real link "
                        "target applies (make said: %r)" % (t, label, t, blob.strip()[-300:]))
            continue
        tick(phase)
        if "is not a build target" not in blob:
            fail(phase, "`make %s' (%s) failed without refusing by name -- if this is "
                        "make's built-in `%%: %%.o' rule firing, the guard is bypassed "
                        "and the failure is incidental:\n%s" % (t, label, blob[-800:]))
        tick(phase)
        if link_target not in blob:
            fail(phase, "`make %s' (%s) refused without naming this render's link target "
                        "(%s) to use instead:\n%s" % (t, label, link_target, blob[-800:]))
        tick(phase)
        if "<builtin>" in blob:
            fail(phase, "`make %s' (%s) reached make's BUILT-IN rule (`[<builtin>]' in "
                        "the output) -- the refusal rule is not being consulted:\n%s"
                 % (t, label, blob[-800:]))
        if not pre_touch:
            tick(phase)
            if os.path.exists(b):
                fail(phase, "`make %s' refused but produced ./%s anyway" % (t, t))


def phase2(d):
    print("[P2] compile: hipcc --offload-arch=%s -c the emitted .hip" % HIP_ARCH)
    if not have("hipcc"):
        fail("P2", "hipcc not on PATH -- this gate cannot verify the AMD lane here; "
                   "run it where ROCm exists before trusting the .hip")
        return
    w = d
    r = run(["sh", "comp.sh", "hip"], cwd=w)
    tick("P2")
    if r.returncode != 0:
        fail("P2", "comp.sh hip failed (exit %d):\n%s%s" % (r.returncode, r.stdout[-2000:], r.stderr[-2000:]))
        return
    tick("P2")
    if "+ hipcc --offload-arch=%s" % HIP_ARCH not in r.stdout:
        fail("P2", "comp.sh hip did not report the hipcc --offload-arch=%s step:\n%s" % (HIP_ARCH, r.stdout))
    obj = os.path.join(w, test_of(w) + "_hip.o")
    tick("P2")
    if not os.path.isfile(obj):
        fail("P2", "comp.sh hip left no %s_hip.o" % test_of(w))
    print("      %d assertions" % counts.get("P2", 0))
    if not counts.get("P2"):
        fail("P2", "phase made no assertions")


def phase3(tmp, d):
    print("[P3] link: comp.sh hip-link and make hip-bin each produce a %s ELF" % HIP_ARCH)
    if not have("hipcc"):
        fail("P3", "hipcc not on PATH -- the HIP link arms cannot be verified here")
        return
    t = test_of(d)
    for arm, cmd in [("comp.sh hip-link", ["sh", "comp.sh", "hip-link"]),
                     ("make hip-bin", ["make", "hip-bin"])]:
        w = fresh(tmp, d, "p3-" + arm.split()[0].replace(".", ""))
        r = run(cmd, cwd=w)
        tick("P3")
        if r.returncode != 0:
            fail("P3", "%s failed (exit %d):\n%s%s" % (arm, r.returncode, r.stdout[-2000:], r.stderr[-2000:]))
            continue
        b = os.path.join(w, t)
        tick("P3")
        if not os.path.isfile(b) or not os.access(b, os.X_OK):
            fail("P3", "%s exited 0 but left no executable ./%s" % (arm, t))
            continue
        tick("P3")
        if not has_gfx(b):
            fail("P3", "%s produced ./%s with NO %s device image -- a host-only "
                       "binary that would run and test nothing" % (arm, t, OFFLOAD_TRIPLE))
    print("      %d assertions" % counts.get("P3", 0))
    if not counts.get("P3"):
        fail("P3", "phase made no assertions")


def phase4(tmp, d_aarch64_cuda, d_x86_hip):
    """Fail-closed on the WRONG HOST, at both stages that can catch it.

    Three assertions, which fail closed for different reasons and could regress
    alone:
      (a) an UNREGISTERED pair emits, warns, and stamps not one machine define --
          (AArch64, hip) is in no row of litmus/hetMachine.ml, and what it loses
          is the right to name a machine, not the right to be built;
      (b) a link arm refuses a foreign host -- driven on the (AArch64, cuda)
          render, whose guard is emitted by the same fold as the HIP one;
      (c) the x86 HIP render carries that guard too, keyed to its own host ISA
          (it cannot be RUN into refusal here: this host is x86_64, which is
          exactly the ISA that render is for).
    """
    print("[P4] fail-closed on the wrong host, at emission and at link, on %s"
          % os.uname().machine)
    if os.uname().machine == "aarch64":
        fail("P4", "this host IS aarch64, so the AArch64 refusal cannot be observed here; "
                   "run this gate on a foreign host too")
        return

    # --- (a) the UNREGISTERED pair emits, and names no machine ----------------
    outroot = os.path.join(tmp, "p4-unregistered")
    st, blob, d_unreg = emit_unregistered(
        os.path.join(HET_DIR, AARCH64_TEST + ".litmus"), outroot, "hip")
    tick("P4")
    if st != 0:
        fail("P4", "litmus7 -gpu-target hip on an AArch64 test exited %d, expected 0 "
                   "-- an unregistered pair is warned about, never refused:\n%s"
             % (st, blob[-800:]))
    tick("P4")
    if "is in no row of litmus/hetMachine.ml" not in blob or "(AArch64, hip)" not in blob:
        fail("P4", "the unregistered-pair emission does not warn and name the pair:"
                   "\n%s" % blob[-800:])
    render = os.path.join(d_unreg, AARCH64_TEST + ".hip")
    tick("P4")
    if not os.path.isfile(render):
        fail("P4", "the unregistered pair wrote no .hip render under %r" % d_unreg)
    else:
        stamped = re.findall(
            r"^#define HET_(?:LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|"
            r"ALGLAVE_ZERO_MEASURED)\b", open(render).read(), re.M)
        tick("P4")
        if stamped:
            fail("P4", "the unregistered pair's render stamps %d machine define(s) "
                       "-- it is entitled to none, and a harness that names the "
                       "wrong machine runs and reports like one that names the "
                       "right one" % len(stamped))

    # --- (b) a link arm refuses a foreign host --------------------------------
    for arm, cmd, want in [("comp.sh cuda-link", ["sh", "comp.sh", "cuda-link"], 3),
                           ("make cuda-bin", ["make", "cuda-bin"], 2)]:
        r = run(cmd, cwd=d_aarch64_cuda)
        blob = r.stdout + r.stderr
        tick("P4")
        if r.returncode != want:
            fail("P4", "%s on an AArch64 render exited %d, expected %d -- a link that "
                       "succeeds here links the PORTABLE SHIM"
                 % (arm, r.returncode, want))
        tick("P4")
        if "refuses on" not in blob or "PORTABLE SHIM" not in blob:
            fail("P4", "%s refused without saying why (no 'refuses on'/'PORTABLE SHIM'):\n%s"
                 % (arm, blob[-800:]))
        tick("P4")
        if "AArch64 asm" not in blob:
            fail("P4", "%s refusal does not name the CPU ISA it was rendered for:\n%s"
                 % (arm, blob[-800:]))
        tick("P4")
        if os.path.isfile(os.path.join(d_aarch64_cuda, test_of(d_aarch64_cuda))):
            fail("P4", "%s refused but a binary exists anyway" % arm)

    # --- (c) the HIP render carries the same guard ---------------------------
    comp = open(os.path.join(d_x86_hip, "comp.sh")).read()
    mk = open(os.path.join(d_x86_hip, "Makefile")).read()
    for what, txt in [("comp.sh", comp), ("Makefile", mk)]:
        tick("P4")
        if 'HET_HOST_ISA="x86_64"' not in txt and "HET_HOST_ISA ?= x86_64" not in txt:
            fail("P4", "the HIP render's %s does not record its host ISA, so its link "
                       "arm has nothing to guard on:\n%s" % (what, txt[:400]))
        tick("P4")
        if "PORTABLE SHIM" not in txt:
            fail("P4", "the HIP render's %s carries no uname guard on its link arm "
                       "-- linking it on a foreign host would test nothing" % what)

    print("      %d assertions" % counts.get("P4", 0))
    if not counts.get("P4"):
        fail("P4", "phase made no assertions")


def plant(src_bin, dst_bin):
    """Put one vendor's linked binary where the other vendor's target writes, and
       make it NEWER than everything around it.  That is the state the stale-link
       trap needs, and a results tree reused across boxes reaches it for real."""
    shutil.copyfile(src_bin, dst_bin)
    os.chmod(dst_bin, 0o755)
    os.utime(dst_bin, None)


def phase5(tmp, d_cuda, d_hip):
    print("[P5] no silent stale link: each vendor's target always relinks ./<test>")
    if not (have("hipcc") and have("nvcc")):
        fail("P5", "P5 needs BOTH hipcc and nvcc to prove the cross-vendor relink "
                   "(have hipcc=%s nvcc=%s)" % (have("hipcc"), have("nvcc")))
        return
    t = test_of(d_cuda)
    wc = fresh(tmp, d_cuda, "p5-cuda")
    wh = fresh(tmp, d_hip, "p5-hip")
    bc = os.path.join(wc, t)
    bh = os.path.join(wh, t)
    # sm_86 so this phase builds on the dev box's RTX 3060 as well as on GH200.
    cuda = ["make", "cuda-bin", "CUDA_ARCH=sm_86"]
    hip = ["make", "hip-bin"]
    # FOUR builds, and the order is the whole point.  A stale-link trap needs a
    # ./<test> that already exists and is NEWER than the objects the target
    # links; rounds 1-2 create each vendor's binary, rounds 3-4 PLANT the other
    # vendor's binary and are the ones that discriminate -- a round that had to
    # rebuild its object anyway runs the recipe for a reason that has nothing to
    # do with .PHONY, and passes against a broken Makefile.
    for label, cmd, w, b, plant_from, want_gfx in [
            ("cuda-bin (round 1: creates %s.o and ./%s)" % (t, t), cuda, wc, bc, None, False),
            ("hip-bin (round 2: creates %s_hip.o and ./%s)" % (t, t), hip, wh, bh, None, True),
            ("cuda-bin (round 3: the AMD binary planted as ./%s, newer than %s.o)"
             % (t, t), cuda, wc, bc, bh, False),
            ("hip-bin (round 4: the CUDA binary planted as ./%s, newer than %s_hip.o)"
             % (t, t), hip, wh, bh, bc, True)]:
        discriminating = plant_from is not None
        if discriminating:
            if not os.path.isfile(plant_from):
                # An earlier round linked nothing, so the trap cannot be set at
                # all -- say so instead of dying on the missing file.
                tick("P5")
                fail("P5", "%s cannot run: the earlier round left no ./%s to plant"
                     % (label, t))
                break
            plant(plant_from, b)
        r = run(cmd, cwd=w)
        tick("P5")
        if r.returncode != 0:
            fail("P5", "make %s failed:\n%s%s" % (label, r.stdout[-1500:], r.stderr[-1500:]))
            return
        got = has_gfx(b)
        tick("P5")
        if got != want_gfx:
            vendor = "AMD" if want_gfx else "CUDA"
            other = "CUDA" if want_gfx else "AMD"
            if want_gfx:
                fail("P5", "%s left ./%s without a %s device image -- the %s target "
                           "reported success and handed back the %s harness%s (make said: %r)"
                     % (label, t, OFFLOAD_TRIPLE, vendor, other,
                        " [THE DISCRIMINATING ROUND]" if discriminating else "",
                        r.stdout.strip()[-200:]))
            else:
                fail("P5", "%s left the %s device image in ./%s -- the %s target "
                           "reported success and handed back the %s harness%s (make said: %r)"
                     % (label, OFFLOAD_TRIPLE, t, vendor, other,
                        " [THE DISCRIMINATING ROUND]" if discriminating else "",
                        r.stdout.strip()[-200:]))
    print("      %d assertions" % counts.get("P5", 0))
    if not counts.get("P5"):
        fail("P5", "phase made no assertions")


# --- P6: the allocator, executed under a stub HIP -------------------------

SHIM_H = r"""
#include <cstdio>
#include <cstdlib>
#include <cstring>
typedef enum { hipDeviceAttributeIntegrated = 1,
               hipDeviceAttributeManagedMemory,
               hipDeviceAttributeConcurrentManagedAccess,
               hipDeviceAttributePageableMemoryAccess } hipDeviceAttribute_t;
static int SHIM_INT = 1, SHIM_MAN = 1, SHIM_CMA = 1, SHIM_PG = 1;
static int hipDeviceGetAttribute(int *p, hipDeviceAttribute_t a, int) {
  switch (a) {
    case hipDeviceAttributeIntegrated: *p = SHIM_INT; break;
    case hipDeviceAttributeManagedMemory: *p = SHIM_MAN; break;
    case hipDeviceAttributeConcurrentManagedAccess: *p = SHIM_CMA; break;
    default: *p = SHIM_PG;
  }
  return 0;
}
"""

SHIM_MAIN = r"""
#include "shim.h"
#include "resolver.inc"
int main(int argc, char **argv) {
  if (argc > 4) { SHIM_INT = atoi(argv[1]); SHIM_MAN = atoi(argv[2]);
                  SHIM_CMA = atoi(argv[3]); SHIM_PG = atoi(argv[4]); }
  printf("RESOLVED mode=%d\n", _het_alloc_mode());
  return 0;
}
"""

# The resolver is lifted verbatim between these two anchors, so the code this
# phase executes is the code the harness ships -- not a paraphrase of it.
RES_BEGIN = re.compile(r"^#define HET_HIP_ALLOC_MANAGED\b", re.M)
RES_END = re.compile(r"^  return _mode;$", re.M)


def build_resolver(tmp, d):
    """Lift _het_alloc_mode out of the emitted .hip and build it against SHIM_H.
       Returns the driver path, or None with a reason."""
    hip = os.path.join(d, test_of(d) + ".hip")
    src = open(hip).read()
    b = RES_BEGIN.search(src)
    if not b:
        return None, "no `#define HET_HIP_ALLOC_MANAGED' in %s.hip -- the HIP render " \
                     "carries no shared-memory mode resolver at all" % test_of(d)
    e = RES_END.search(src, b.end())
    if not e:
        return None, "no `return _mode;' after the resolver in %s.hip" % test_of(d)
    body = src[b.start():e.end()] + "\n}\n"
    w = os.path.join(tmp, "shim-" + test_of(d))
    shutil.rmtree(w, ignore_errors=True)
    os.makedirs(w)
    open(os.path.join(w, "shim.h"), "w").write(SHIM_H)
    open(os.path.join(w, "resolver.inc"), "w").write(body)
    open(os.path.join(w, "drv.cpp"), "w").write(SHIM_MAIN)
    r = run(["g++", "-std=c++17", "-o", "drv", "drv.cpp"], cwd=w)
    if r.returncode != 0:
        return None, "the lifted resolver does not compile:\n%s" % r.stderr[-2000:]
    return os.path.join(w, "drv"), None


def drv(path, mode=None, integrated=1, managed=1, cma=1, pg=1):
    e = dict(os.environ)
    e.pop("HET_ALLOC", None)
    if mode is not None:
        e["HET_ALLOC"] = mode
    return subprocess.run([path, str(integrated), str(managed), str(cma), str(pg)],
                          capture_output=True, text=True, env=e)


def phase6(tmp, d):
    print("[P6] allocator fail-closed: HET_ALLOC modes + device preconditions (no AMD GPU)")
    path, why = build_resolver(tmp, d)
    if path is None:
        tick("P6")
        fail("P6", why)
        return
    # (a) the accepted spellings resolve, print the banner, and do not exit.
    for m in HIP_ACCEPTED_MODES:
        r = drv(path, mode=(None if m == "" else m))
        tick("P6")
        if r.returncode != 0:
            fail("P6", "HET_ALLOC=%r was REFUSED (exit %d) but this render implements it:\n%s"
                 % (m or "<unset>", r.returncode, (r.stdout + r.stderr)[-600:]))
            continue
        tick("P6")
        if "RESOLVED mode=1" not in r.stdout:
            fail("P6", "HET_ALLOC=%r did not resolve to the managed mode:\n%s" % (m or "<unset>", r.stdout))
        tick("P6")
        if "shared-mem mode=managed" not in r.stdout:
            fail("P6", "HET_ALLOC=%r printed no shared-mem banner -- the run would leave no "
                       "record of which allocator it used:\n%s" % (m or "<unset>", r.stdout))
    # (b) every other spelling is FATAL.  Rule 8: unrecognised mode refuses.
    for m in HIP_REFUSED_MODES:
        r = drv(path, mode=m)
        tick("P6")
        if r.returncode != 2:
            fail("P6", "HET_ALLOC=%r exited %d, expected 2 -- an unimplemented mode that "
                       "silently allocates managed memory runs a DIFFERENT experiment under "
                       "the requested name" % (m, r.returncode))
            continue
        tick("P6")
        if "FATAL" not in r.stderr or "not a shared-memory mode" not in r.stderr:
            fail("P6", "HET_ALLOC=%r refused without naming the reason:\n%s" % (m, r.stderr[-600:]))
    # (c) device preconditions.  hipMallocManaged degrades to hipMallocHost when
    #     HMM is absent (hip_runtime_api.h), and the CPU may not touch managed
    #     memory mid-kernel without concurrent managed access.  Both fatal.
    for label, kw, needle in [
        ("managedMemory=0", dict(managed=0), "hipDeviceAttributeManagedMemory=0"),
        ("concurrentManagedAccess=0", dict(cma=0), "hipDeviceAttributeConcurrentManagedAccess=0"),
    ]:
        r = drv(path, **kw)
        tick("P6")
        if r.returncode != 2:
            fail("P6", "%s exited %d, expected 2 -- the harness would run with the shared "
                       "vars off the coherent path" % (label, r.returncode))
            continue
        tick("P6")
        if needle not in r.stderr:
            fail("P6", "%s refused without naming the attribute:\n%s" % (label, r.stderr[-600:]))
    # (d) MI300A vs MI300X.  Both report gfx942; only `integrated' separates them,
    #     and a discrete-part histogram must never be read as an MI300A result.
    r = drv(path, integrated=1)
    tick("P6")
    if "amd_part_class=APU(MI300A-class)" not in r.stdout:
        fail("P6", "integrated=1 was not classified as the MI300A-class APU in the banner:\n%s" % r.stdout)
    r = drv(path, integrated=0)
    tick("P6")
    if r.returncode != 0:
        fail("P6", "integrated=0 (MI300X) exited %d -- the discrete part is the Phase-3a "
                   "bring-up target and must be able to run" % r.returncode)
    tick("P6")
    if "amd_part_class=DISCRETE(MI300X-class)" not in r.stdout:
        fail("P6", "integrated=0 was not classified as a discrete part in the banner -- a log "
                   "reader could not tell an MI300X run from an MI300A one:\n%s" % r.stdout)
    tick("P6")
    if "WARNING" not in r.stderr or "NOT be reported as an MI300A result" not in r.stderr:
        fail("P6", "integrated=0 produced no warning that this is not an MI300A result:\n%s"
             % r.stderr[-600:])

    # (e) ...AND THE HARNESS MUST ACTUALLY CALL IT.
    # Everything above drives the resolver in ISOLATION.  It proves the resolver
    # is right; it says NOTHING about whether the harness ever runs it, and that
    # gap is this project's signature failure (B4's stress read its knobs and
    # applied none; B6a's exhaustive_valid was constant-0 so the rule was cold).
    # MEASURED 2026-08-03: deleting the single statement
    #     (void)_het_alloc_mode();   /* resolve + guard once, before the ... */
    # from gd_alloc_shared in het_alloc_hip.inc -- leaving the resolver defined
    # and gd_free_shared's call intact -- left this gate at 69/69 PASS, `dune
    # runtest hetlitmus/tests/cram' green and `make hetlitmus-test' green, while
    # the shipped binary ignored HET_ALLOC and BOTH device preconditions at
    # allocation time.  The guard would then fire only in gd_free_shared, i.e.
    # after the whole experiment and after the histogram, the HetVerdict and the
    # HetStats lines had been printed.
    # The CUDA render needs no such assertion: its gd_alloc_shared DISPATCHES on
    # the returned mode (`int _m = _het_alloc_mode(); if (_m == HET_ALLOC_MALLOC)
    # ...'), so dropping the call does not compile.  The HIP call's only effect
    # is the guard, so nothing anchors it but this.
    hip_src = open(os.path.join(d, test_of(d) + ".hip")).read()
    alloc_body = fn_body(hip_src, "gd_alloc_shared")
    tick("P6")
    if alloc_body is None:
        fail("P6", "no gd_alloc_shared in the emitted %s.hip -- the shared allocator "
                   "the resolver exists to guard is not there" % test_of(d))
    else:
        tick("P6")
        n = alloc_body.count("_het_alloc_mode()")
        if n != 1:
            fail("P6", "gd_alloc_shared calls _het_alloc_mode() %d time(s), expected 1 -- "
                       "with no call the harness ALLOCATES WITHOUT EVER RESOLVING THE "
                       "MODE: HET_ALLOC is ignored and the managedMemory / "
                       "concurrentManagedAccess guards do not run until gd_free_shared, "
                       "after the histogram has been printed. Body:\n%s" % (n, alloc_body))
        else:
            # Order matters as much as presence: the contract is "resolve + guard
            # ONCE, BEFORE the first alloc".  A call moved below the allocation
            # still exits(2), but only after the memory it was meant to vet has
            # been handed out.
            tick("P6")
            i_res = alloc_body.index("_het_alloc_mode()")
            i_all = alloc_body.find("hipMallocManaged")
            if i_all < 0:
                fail("P6", "gd_alloc_shared does not call hipMallocManaged -- the "
                           "fine-grained allocation this render is built on is gone")
            elif i_res > i_all:
                fail("P6", "gd_alloc_shared resolves the mode AFTER hipMallocManaged -- "
                           "the guard must run BEFORE the first allocation, or the "
                           "memory it exists to vet has already been handed out. Body:\n%s"
                     % alloc_body)
    free_body = fn_body(hip_src, "gd_free_shared")
    tick("P6")
    if free_body is None or "_het_alloc_mode()" not in free_body:
        fail("P6", "gd_free_shared does not call _het_alloc_mode() -- the free must stay "
                   "keyed on the resolver so a second mode cannot leave a mismatched "
                   "free behind")

    # (f) HET_PLACE is CUDA-only and must be REFUSED here, not silently reported.
    # Both renders print `place=%d' in the cpu-stress banner and carry place_mode
    # in the statistics record (one emitter, two dialects), but placement is
    # cudaMemAdvise/cudaMemPrefetchAsync and lives only in het_alloc_cuda.inc.
    # _het_place_failures has TWO READERS and ZERO WRITERS on this lane, so a
    # `-DHET_PLACE=1' AMD build would log `place=1 ... place_fail=0' -- placement
    # requested, no refusals -- with nothing placed and nothing placeable.
    tick("P6")
    if "#if (HET_PLACE) != 0" not in hip_src or "# error" not in hip_src:
        fail("P6", "the emitted .hip does not REFUSE a non-zero HET_PLACE at compile "
                   "time -- a -DHET_PLACE=1 AMD build would report place=1 with "
                   "place_fail=0 while placing nothing")
    if have("hipcc"):
        w = fresh(tmp, d, "p6place")
        r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=1"], cwd=w)
        tick("P6")
        if r.returncode == 0:
            fail("P6", "`make hip HIPCC=\"hipcc -DHET_PLACE=1\"' SUCCEEDED -- the AMD "
                       "render accepted a placement lever it does not implement")
        tick("P6")
        if "HET_PLACE is a CUDA-only lever" not in (r.stdout + r.stderr):
            fail("P6", "a -DHET_PLACE=1 AMD build failed without saying why:\n%s"
                 % (r.stdout + r.stderr)[-800:])
        # ...and HET_PLACE=0, the default and the only honourable value, still builds.
        w = fresh(tmp, d, "p6place0")
        r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=0"], cwd=w)
        tick("P6")
        if r.returncode != 0:
            fail("P6", "-DHET_PLACE=0 (the DEFAULT) no longer compiles -- the refusal "
                       "is over-broad and blocks every ordinary AMD build:\n%s"
                 % (r.stdout + r.stderr)[-800:])
    print("      %d assertions" % counts.get("P6", 0))
    if not counts.get("P6"):
        fail("P6", "phase made no assertions")


def phase7(tmp, d):
    print("[P7] CUDA non-regression: the cuda / cuda-link / cuda-bin arms")
    t = test_of(d)
    comp = open(os.path.join(d, "comp.sh")).read()
    mk = open(os.path.join(d, "Makefile")).read()
    for what, pat, blob in [
        ("cuda-link case arm", r"^\s*cuda\|cuda-link\)", comp),
        ("cuda-link uname guard", r'TARGET" = cuda-link \] && \[ "\$\(uname -m\)" != "\$HET_HOST_ISA" \]', comp),
        ("cuda-bin rule", r"^cuda-bin: %s\.o outs\.o %s_cpu_host\.o$" % (re.escape(t), re.escape(t)), mk),
        ("cuda-bin uname guard", r"cuda-bin refuses on \$\$\(uname -m\)", mk),
        ("cuda-bin links with NVCC", r"\$\(NVCC\) -arch=\$\(CUDA_ARCH\) \$\^ -o %s " % re.escape(t), mk),
        ("cuda-bin .PHONY", r"^\.PHONY:.*\bcuda-bin\b", mk),
    ]:
        tick("P7")
        if not re.search(pat, blob, re.M):
            fail("P7", "%s missing or altered in the emitted build scripts (/%s/)" % (what, pat))
    # ...and this render is CUDA-only, the mirror of P1's check on the HIP one.
    for where, blob in [("comp.sh", comp), ("Makefile", mk)]:
        tick("P7")
        if re.search(r"\bhip\b|\bHIP\b|\bHIPCC\b", blob):
            fail("P7", "the CUDA render's %s still carries HIP arms -- `-gpu-target "
                       "cuda' must emit one vendor's build targets only" % where)
    # The CUDA render is where make's built-in `%: %.o' rule is REACHABLE (its
    # GPU object is <test>.o), so the behavioural refusal check has to run here
    # as well as on the HIP render.
    make_test_refuses(tmp, d, "P7", "cuda-bin")
    if not have("nvcc"):
        fail("P7", "nvcc not on PATH -- the CUDA lane cannot be re-verified here")
    else:
        w = fresh(tmp, d, "p7")
        r = run(["sh", "comp.sh", "cuda"], cwd=w)
        tick("P7")
        if r.returncode != 0:
            fail("P7", "comp.sh cuda regressed (exit %d):\n%s%s"
                 % (r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    print("      %d assertions" % counts.get("P7", 0))
    if not counts.get("P7"):
        fail("P7", "phase made no assertions")


# -------------------------------------------------------------------- bite

def sub(path, old, new, count=0):
    s = open(path).read()
    if old not in s:
        raise SystemExit("hipbuildcheck --bite: anchor %r absent from %s -- the "
                         "injection would have been a no-op, which is exactly the "
                         "silent-bite failure this gate exists to prevent" % (old, path))
    open(path, "w").write(s.replace(old, new) if count == 0 else s.replace(old, new, count))


def phony_line(d):
    """This render's .PHONY line, READ rather than reconstructed: a single-vendor
       harness lists its own vendor's targets and no others."""
    for l in open(os.path.join(d, "Makefile")):
        if l.startswith(".PHONY:"):
            return l.rstrip("\n")
    raise SystemExit("hipbuildcheck --bite: no .PHONY line in %s/Makefile -- the "
                     "injections below would have been no-ops" % d)


def strip_refusal_rule(d):
    """Put the Makefile back into its pre-2026-08-03 shape: no `.SUFFIXES:', no
       rule naming ./<test>, and ./<test> not phony.  That is the state in which
       `make <test>' reached GNU make's built-in `%: %.o' link rule -- and it is
       also the state P5's stale-link trap needs, because a PHONY ./<test> is
       never "up to date" and the trap could not spring."""
    p = os.path.join(d, "Makefile")
    t = test_of(d)
    s = open(p).read()
    for pat, rep in [(r"^\.SUFFIXES:\n\n", ""),
                     (r"^%s:\n\t@ echo .*\n\n" % re.escape(t), ""),
                     (r"^(\.PHONY: .*?) %s$" % re.escape(t), r"\1")]:
        s2 = re.sub(pat, rep, s, flags=re.M)
        if s2 == s:
            raise SystemExit("hipbuildcheck --bite: strip_refusal_rule found no /%s/ in "
                             "%s -- the injection would have been a no-op" % (pat, p))
        s = s2
    open(p, "w").write(s)


def bite_one(label, phase, runner, expect):
    """Run [runner]; require [phase] to redden with [expect] in the message."""
    fails.clear()
    counts.clear()
    print("  -- bite [%s] %s" % (phase, label))
    try:
        runner()
    except SystemExit as e:
        print("     (phase aborted: %s)" % e)
    mine = [m for ph, m in fails if ph == phase]
    if not mine:
        print("     NOT REDDENED by %s -- injection was INERT" % phase)
        return False
    hit = [m for m in mine if expect in m]
    if not hit:
        print("     %s reddened but named the wrong object (wanted %r):\n       %s"
              % (phase, expect, "\n       ".join(mine)))
        return False
    # Print the assertion that MATCHED, not merely the first one that fired: a
    # phase can redden for several reasons at once, and "it went red" is not the
    # same claim as "the assertion this injection targets went red".
    print("     OK: %s" % hit[0].splitlines()[0][:150])
    return True


def bite(tmp, d_x86, d_x86_cuda, d_aa_cuda):
    print("===== HIPBUILDCHECK BITE: every phase, on corruption AND on omission =====")
    ok = True
    n = [0]

    def W(tag, base=None):
        n[0] += 1
        return fresh(tmp, base or d_x86, "bite%d-%s" % (n[0], tag))

    # --- P1 -----------------------------------------------------------------
    w = W("p1c")
    # Anchored on the whole case-arm LINE: the unknown-target refusal quotes
    # `(accepted: hip|hip-link)' too, and a bare substring would corrupt both.
    sub(os.path.join(w, "comp.sh"), "\n  hip|hip-link)\n", "\n  hip|hip-lonk)\n")
    ok &= bite_one("comp.sh hip-link arm misspelt", "P1", lambda: phase1(tmp, w), "hip-link case arm")
    w = W("p1r")
    sub(os.path.join(w, "comp.sh"),
        r'comp.sh: unknown target \"$TARGET\" -- this directory is hip-only ',
        "usage: sh comp.sh ")
    ok &= bite_one("comp.sh unknown-target refusal cut back to a bare usage line "
                   "(it no longer quotes the rejected argument)", "P1",
                   lambda: phase1(tmp, w), "unknown-target refusal")
    w = W("p1o")
    mk = os.path.join(w, "Makefile")
    s = open(mk).read()
    s = re.sub(r"^hip-bin: .*\n(?:\t.*\n)*", "", s, flags=re.M)
    open(mk, "w").write(s)
    ok &= bite_one("Makefile hip-bin rule DELETED", "P1", lambda: phase1(tmp, w), "hip-bin rule")
    w = W("p1p")
    # Surgical: hip-bin ONLY.  ./<test> stays phony, so this bite isolates the
    # one object it names instead of also tripping the ./<test> assertions.
    sub(os.path.join(w, "Makefile"), phony_line(w),
        phony_line(w).replace(" hip-bin", "", 1))
    ok &= bite_one("hip-bin dropped from .PHONY", "P1", lambda: phase1(tmp, w), "hip-bin .PHONY")
    # OMISSION, and the one that bit for real: with the link targets phony there
    # is no rule naming ./<test>, so make falls through to its BUILT-IN `%: %.o'
    # and links it with $(CC), guard and device code both gone.  Deleting the
    # refusal rule restores exactly that state -- P1 must catch it by RUNNING
    # make, not by grepping, because the defect is an absent rule.
    # ...on the CUDA render, the only one where the fall-through is REACHABLE:
    # the built-in rule is `%: %.o', and the HIP render's GPU object is
    # <test>_hip.o, so there make simply reports no rule at all.  P7 owns the
    # behavioural check on that render.
    w = W("p7b", d_x86_cuda)
    strip_refusal_rule(w)
    # The expected object is the BEHAVIOURAL assertion, not the grep for the rule:
    # the grep also reddens here, and a bite satisfied by the grep would not show
    # that the check can still detect this if someone leaves a rule in place that
    # does not actually refuse.
    ok &= bite_one("./<test> refusal rule + .SUFFIXES DELETED (make falls back to "
                   "its built-in link rule)", "P7", lambda: phase7(tmp, w),
                   "reached make's BUILT-IN rule")
    # CORRUPTION: the rule survives but ./<test> is no longer .PHONY, so a run
    # that already has a binary gets "up to date", exit 0, and whatever the other
    # vendor left behind.
    w = W("p1q")
    sub(os.path.join(w, "Makefile"), phony_line(w),
        phony_line(w)[: -(len(test_of(w)) + 1)])
    ok &= bite_one("./<test> dropped from .PHONY (a present binary is 'up to date')",
                   "P1", lambda: phase1(tmp, w), "EXITED 0")
    # CORRUPTION with EVERY GREP STILL GREEN: the rule is there, .SUFFIXES is
    # there, ./<test> is phony -- and the recipe does nothing and exits 0.  Only
    # the behavioural check can see this, which is the point of running make.
    w = W("p1r")
    mk = os.path.join(w, "Makefile")
    s = open(mk).read()
    s = re.sub(r"^(%s:\n)\t@ echo .*\n" % re.escape(test_of(w)), r"\1\t@ true\n", s, flags=re.M)
    open(mk, "w").write(s)
    ok &= bite_one("./<test> rule kept but made a no-op that exits 0 (all P1 greps "
                   "still pass)", "P1", lambda: phase1(tmp, w), "EXITED 0")

    # --- P2 -----------------------------------------------------------------
    w = W("p2c")
    hp = os.path.join(w, test_of(w) + ".hip")
    open(hp, "a").write("\nthis is not c++;\n")
    ok &= bite_one(".hip made uncompilable", "P2", lambda: phase2(w), "comp.sh hip failed")
    w = W("p2o")
    os.remove(os.path.join(w, test_of(w) + ".hip"))
    ok &= bite_one(".hip DELETED", "P2", lambda: phase2(w), "comp.sh hip failed")

    # --- P3 -----------------------------------------------------------------
    w = W("p3c")
    # The build runs and EXITS 0 -- for the wrong hardware.  A gfx90a (MI200)
    # image links cleanly and would never run on MI300A/MI300X.  Exit status
    # alone calls this a pass, so P3 has to read the ELF and insist on the
    # gfx942 triple rather than on "some device image".
    sub(os.path.join(w, "Makefile"), "HIP_ARCH ?= %s" % HIP_ARCH, "HIP_ARCH ?= gfx90a")
    sub(os.path.join(w, "comp.sh"), 'HIP_ARCH="${HIP_ARCH:-%s}"' % HIP_ARCH,
        'HIP_ARCH="${HIP_ARCH:-gfx90a}"')
    ok &= bite_one("both HIP arms build for gfx90a (MI200), exit 0", "P3",
                   lambda: phase3(tmp, w), "NO amdgcn")
    w = W("p3o")
    s = open(os.path.join(w, "comp.sh")).read()
    s = s.replace('    if [ "$TARGET" = hip-link ]; then', '    if false; then')
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh hip-link LINK STEP removed (still exits 0)", "P3",
                   lambda: phase3(tmp, w), "left no executable")

    # --- P4 -----------------------------------------------------------------
    # (b), the link-arm half, driven on the (AArch64, cuda) render: the
    # unregistered-pair half (a) is a property of litmus7 and has no file to
    # corrupt, so it is bitten from the emitter side by machine-pairs.t (d).
    w = W("p4c", d_aa_cuda)
    sub(os.path.join(w, "comp.sh"), '"$(uname -m)" != "$HET_HOST_ISA"',
        '"$(uname -m)" = "$HET_HOST_ISA"')
    sub(os.path.join(w, "Makefile"), 'test "$$(uname -m)" = "$(HET_HOST_ISA)"',
        'test "$$(uname -m)" != "$(HET_HOST_ISA)"')
    ok &= bite_one("uname guard INVERTED on an AArch64 render", "P4",
                   lambda: phase4(tmp, w, d_x86), "expected 3")
    w = W("p4o", d_aa_cuda)
    s = open(os.path.join(w, "comp.sh")).read()
    s = re.sub(r'    if \[ "\$TARGET" = cuda-link \] && \[ "\$\(uname -m\)".*?\n    fi\n',
               "", s, flags=re.S)
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh cuda-link uname guard DELETED", "P4",
                   lambda: phase4(tmp, w, d_x86), "expected 3")
    # (c): the HIP render loses its guard, which no RUN on this x86_64 host can
    # observe -- the guard is keyed to the ISA this host already is.
    w = W("p4h", d_x86)
    sub(os.path.join(w, "comp.sh"), "PORTABLE SHIM", "portable stand-in")
    sub(os.path.join(w, "Makefile"), "PORTABLE SHIM", "portable stand-in")
    ok &= bite_one("the HIP render\'s uname guard TEXT gone", "P4",
                   lambda: phase4(tmp, d_aa_cuda, w), "carries no uname guard")

    # --- P5 -----------------------------------------------------------------
    # P5 drives two directories, so each injection goes into ONE of them and the
    # other stays pristine -- otherwise a bite could redden for the wrong render.
    w = W("p5c", d_x86_cuda)
    # Restore the pre-fix shape: cuda-bin as a phony with a FILE prerequisite.
    # This is the measured regression, replayed.  The refusal rule has to come
    # out FIRST: it makes ./<test> phony, and a phony target is never "up to
    # date", so with it in place make would rerun the recipe for a reason that
    # has nothing to do with the trap and this bite would go inert.
    strip_refusal_rule(w)
    s = open(os.path.join(w, "Makefile")).read()
    t = test_of(w)
    s = s.replace("cuda-bin: %s.o outs.o %s_cpu_host.o\n" % (t, t),
                  "cuda-bin: %s\n\n%s: %s.o outs.o %s_cpu_host.o\n" % (t, t, t, t))
    s = s.replace("$(NVCC) -arch=$(CUDA_ARCH) $^ -o %s -lpthread -lm" % t,
                  "$(NVCC) -arch=$(CUDA_ARCH) $^ -o $@ -lpthread -lm")
    open(os.path.join(w, "Makefile"), "w").write(s)
    wh = W("p5c-hip")
    ok &= bite_one("cuda-bin reverted to a FILE rule (the measured stale trap)", "P5",
                   lambda: phase5(tmp, w, wh), "left the amdgcn")
    w = W("p5o")
    # OMISSION: the target and its guard survive, only the LINK COMMAND is gone.
    # `make hip-bin' then builds the objects, passes the uname guard and exits 0
    # having linked nothing -- the exact shape of a target that reports success
    # while doing no work.
    s = open(os.path.join(w, "Makefile")).read()
    s = s.replace("\t$(HIPCC) --offload-arch=$(HIP_ARCH) $^ -o %s -lpthread -lm\n" % test_of(w), "")
    open(os.path.join(w, "Makefile"), "w").write(s)
    wc = W("p5o-cuda", d_x86_cuda)
    ok &= bite_one("hip-bin LINK COMMAND deleted (target still exits 0)", "P5",
                   lambda: phase5(tmp, wc, w), "without a amdgcn")

    # --- P6 -----------------------------------------------------------------
    w = W("p6c")
    hp = os.path.join(w, test_of(w) + ".hip")
    s = open(hp).read()
    # The classic fail-OPEN: an unknown mode silently becomes the default.
    s = s.replace('''            "malloc would run a different experiment under the requested name.\\n",
            _v);
    exit(2);''',
                  '''            "malloc would run a different experiment under the requested name.\\n",
            _v);
    _mode = HET_HIP_ALLOC_MANAGED;''')
    open(hp, "w").write(s)
    ok &= bite_one("unknown HET_ALLOC falls back to managed instead of exit(2)", "P6",
                   lambda: phase6(tmp, w), "expected 2")
    w = W("p6o")
    hp = os.path.join(w, test_of(w) + ".hip")
    s = open(hp).read()
    s = re.sub(r"  if \(!_managed\) \{.*?\n    exit\(2\);\n  \}\n", "", s, flags=re.S)
    open(hp, "w").write(s)
    ok &= bite_one("the managedMemory precondition DELETED", "P6",
                   lambda: phase6(tmp, w), "managedMemory=0 exited")
    w = W("p6x")
    hp = os.path.join(w, test_of(w) + ".hip")
    s = open(hp).read()
    s = s.replace('return _integrated ? "APU(MI300A-class)" : "DISCRETE(MI300X-class)";',
                  'return "APU(MI300A-class)";')
    open(hp, "w").write(s)
    ok &= bite_one("MI300X classified as an MI300A APU", "P6",
                   lambda: phase6(tmp, w), "not classified as a discrete part")
    # THE INERT-MECHANISM OMISSION.  Everything P6 does above still passes with
    # this deleted -- the resolver is still defined, still correct, and still
    # called by gd_free_shared.  It is simply never called where it has to run.
    # This is the injection that left the gate at 69/69 on 2026-08-03.
    w = W("p6call")
    hp = os.path.join(w, test_of(w) + ".hip")
    sub(hp, "  (void)_het_alloc_mode();               "
            "/* resolve + guard once, before the first alloc */\n", "")
    ok &= bite_one("gd_alloc_shared's _het_alloc_mode() CALL deleted (resolver still "
                   "defined and still called by gd_free_shared)", "P6",
                   lambda: phase6(tmp, w), "gd_alloc_shared calls _het_alloc_mode() 0 time")
    # CORRUPTION of the same site: the call is there, but after the allocation it
    # was supposed to vet.
    w = W("p6ord")
    hp = os.path.join(w, test_of(w) + ".hip")
    sub(hp,
        "  (void)_het_alloc_mode();               "
        "/* resolve + guard once, before the first alloc */\n"
        "  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */\n",
        "  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */\n"
        "  (void)_het_alloc_mode();               "
        "/* resolve + guard once, before the first alloc */\n")
    ok &= bite_one("the guard moved BELOW hipMallocManaged", "P6",
                   lambda: phase6(tmp, w), "AFTER hipMallocManaged")
    # HET_PLACE: the CUDA-only lever both renders PRINT.
    w = W("p6place")
    hp = os.path.join(w, test_of(w) + ".hip")
    sub(hp, "#if (HET_PLACE) != 0", "#if 0")
    ok &= bite_one("the HET_PLACE compile-time refusal disabled (a -DHET_PLACE=1 AMD "
                   "build would log place=1 place_fail=0 having placed nothing)", "P6",
                   lambda: phase6(tmp, w), "does not REFUSE a non-zero HET_PLACE")

    # --- P7 -----------------------------------------------------------------
    w = W("p7c", d_x86_cuda)
    sub(os.path.join(w, "Makefile"), "$(NVCC) -arch=$(CUDA_ARCH) $^ -o",
        "$(HIPCC) --offload-arch=$(HIP_ARCH) $^ -o")
    ok &= bite_one("cuda-bin links with HIPCC", "P7", lambda: phase7(tmp, w),
                   "cuda-bin links with NVCC")
    w = W("p7o", d_x86_cuda)
    s = open(os.path.join(w, "comp.sh")).read()
    s = s.replace("  cuda|cuda-link)", "  cuda)")
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh cuda-link arm DELETED", "P7", lambda: phase7(tmp, w),
                   "cuda-link case arm")

    fails.clear()
    print()
    if ok:
        print("HIPBUILDCHECK BITE OK (every injection reddened its own phase)")
        return 0
    print("HIPBUILDCHECK BITE FAILED")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove each phase FAILS on corruption and on omission")
    a = ap.parse_args()

    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("hipbuildcheck: %s not built (run 'make all')" % LITMUS7)

    tmp = tempfile.mkdtemp(prefix="hipbuildcheck.")
    try:
        # The x86 renderings are generated on demand -- they are deliberately not
        # committed (generate-x86.sh explains why).
        corpus = os.path.join(tmp, "x86")
        r = run(["bash", GEN_X86, corpus])
        if r.returncode != 0:
            raise SystemExit("hipbuildcheck: generate-x86.sh failed:\n" + r.stderr)
        src = os.path.join(corpus, X86_TEST + ".litmus")
        if not os.path.isfile(src):
            raise SystemExit("hipbuildcheck: generate-x86.sh emitted no %s" % X86_TEST)
        # The same x86 test, rendered once per vendor: one directory carries one
        # vendor's arms, so the AMD phases and the CUDA non-regression phase read
        # different directories now.
        d_x86 = emit(tmp, src, os.path.join(tmp, "out-x86-hip"), "x86 render", "hip")
        d_x86_cuda = emit(tmp, src, os.path.join(tmp, "out-x86-cuda"),
                          "x86 render", "cuda")
        # The AArch64 render P4 drives is the CUDA one: it is the AArch64 pair
        # that names a machine, and P4(a) covers the hip one on its own terms.
        # The uname guard is emitted by the same per-dialect fold on both, which
        # is what makes the substitution sound.
        d_aa_cuda = emit(tmp, os.path.join(HET_DIR, AARCH64_TEST + ".litmus"),
                         os.path.join(tmp, "out-aa"), "AArch64 render", "cuda")

        if a.bite:
            return bite(tmp, d_x86, d_x86_cuda, d_aa_cuda)

        print("===== HIPBUILDCHECK: can an AMD harness be built and run? =====")
        print("  host %s, hipcc=%s nvcc=%s"
              % (os.uname().machine, have("hipcc"), have("nvcc")))
        phase1(tmp, d_x86)
        phase2(fresh(tmp, d_x86, "p2"))
        phase3(tmp, d_x86)
        phase4(tmp, d_aa_cuda, d_x86)
        phase5(tmp, d_x86_cuda, d_x86)
        phase6(tmp, d_x86)
        phase7(tmp, d_x86_cuda)
        print("=" * 70)
        if fails:
            print("HIPBUILDCHECK FAILED: %d assertion(s)" % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            return 1
        print("HIPBUILDCHECK: PASS (%d assertions over 7 phases)" % sum(counts.values()))
        print("  DEFERRED to Phase 3a (MI300X): there is no AMD GPU here, so the "
              "linked harness was never EXECUTED on a device.  P6 executed the "
              "allocator resolver under a stub hipDeviceGetAttribute; the real "
              "hipMallocManaged coherence behaviour remains unverified.")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
