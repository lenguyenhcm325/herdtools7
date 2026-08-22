#!/usr/bin/env python3
"""
hipbuildcheck.py -- can an AMD harness be built, linked and refused correctly?

Nine phases, each of which must be seen to fail:

  build-arms          the emitted comp.sh / Makefile carry hip-link + hip-bin,
                      advertise them in their usage text, and hip-bin is
                      .PHONY; and `make <test>' refuses, checked by RUNNING
                      it, because with no rule naming ./<test> make falls
                      through to its built-in `%: %.o' rule and links with
                      $(CC) -- guard and device code both gone, and an absent
                      rule is invisible to a grep
  hip-compile         hipcc --offload-arch=gfx942 compiles the emitted .hip
  device-image        comp.sh hip-link and make hip-bin each produce an ELF
                      carrying a real amdgcn gfx942 code object, read out of
                      the bytes rather than inferred from an exit status
  host-pair-guard     fail-closed on the wrong host: the link arms refuse an
                      AArch64 rendering on an x86_64 host, naming the ISA and
                      leaving no binary (the CPU object there is the portable
                      shim, so the binary would test nothing); and the HIP
                      render carries that same guard, keyed to its own host ISA
  stale-binary        every vendor writes ./<test> (run-one.sh and campaign.py
                      exec it and are vendor-agnostic), so each link target
                      must always relink -- one reporting "nothing to be done"
                      hands back whichever vendor's binary is lying there
  hip-allocator       the HIP shared allocator resolves one mode and refuses
                      every other spelling and every unmet device
                      precondition, classifies APU vs discrete, and is CALLED
                      by gd_alloc_shared before the allocation it must vet
  place-refusal       the CUDA-only HET_PLACE lever is refused at compile
                      time, and HET_PLACE=0 still builds.  Its own phase
                      because it is the hipcc half: hip-allocator's injections
                      all corrupt the lifted resolver, and none of them can move
                      a compile-time refusal
  cuda-nonregression  the cuda / cuda-link / cuda-bin arms still carry their
                      guard and still build
  fence-lowering      the fence-carrying render emits the documented
                      __builtin_amdgcn_fence lowering for every `f[sc,sys]'
                      it annotates, and hipcc compiles it

fence-lowering compiles litmus/HipLang.ml's __builtin_amdgcn_fence as the
harness ships it, host half and all; what the compiler makes of it is
UNVERIFIED (hetlitmus/docs/amd-faithfulness.md).  What that compile settles,
what it leaves open and how much of the corpus carries a fence are in
hetlitmus/docs/hip-emitter.md ("Fences", "Compile status & next steps").

Correctness in isolation is not the mechanism being live.  hip-allocator drives
the resolver out-of-line, so on its own it would pass a harness that never calls
it, and on this lane the call's ONLY effect is the guard, so nothing else anchors
it: its (e) arm pins the call site, scoped to gd_alloc_shared's body and to its
order against the allocation.  (The CUDA render dispatches on the returned mode,
so there dropping the call does not compile.)  The same shape one layer up is why
build-arms runs `make <test>' instead of grepping for it.

hip-allocator is a runtime phase without an AMD GPU.  Where no AMD device is
present the linked harness cannot be run -- it exits 2 at its cooperative-launch
capability check -- so it lifts the resolver out of the emitted .hip verbatim and
drives it against a stub `hipDeviceGetAttribute' whose answers this gate chooses;
every refusal path is then genuinely EXECUTED and its message observed.  The real
hipMallocManaged and coherence behaviour, which no shim stands in for, stays
deferred to an MI300X bring-up run.

Every phase counts its own assertions and fails if it made none.  `--bite'
injects into each phase, on corruption and on omission, and requires the phase
that owns the injected object to redden naming it.

One vendor per harness directory: litmus7 renders the dialect `-gpu-target' names
and no other (litmus/hetDialect.ml), so the AMD arms and the CUDA arms sit in
different directories -- this gate emits the same x86 test twice,
cuda-nonregression reading the cuda render and the four HIP phases the hip one.
stale-binary's cross-vendor stale-link trap needs both: it plants one vendor's
linked binary in the other's directory, a ./<test> newer than the objects and
carrying the wrong device image, which is the state a results tree reused across
boxes reaches for real.

And one pair per harness.  A harness is a (CPU ISA x GPU dialect) pair, so the
AMD phases run on the x86 rendering -- (x86_64, hip) -- while host-pair-guard's
AArch64 half runs on the (AArch64, cuda) one.
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

# The x86_64 rendering is the one an x86_64 host can LINK: its CPU thread is real
# x86-64 asm, so the uname guard admits it.  MP-cg-sys-acqrel-2s carries a CPU
# proc with a store, a fence and a load, so its render exercises the whole CPU
# vocabulary this corpus is written in.  Its AArch64 twin is host-pair-guard's
# refusal probe, on that same x86_64 host.
X86_TEST = "MP-cg-sys-acqrel-2s-x86_64"
AARCH64_TEST = "MP-cg-sys-acqrel-2s"
# The fence-carrying render fence-lowering builds, and the lowering its .hip owes for each
# annotation; why that exact spelling is litmus/HipLang.ml (hip_fence_scope).
X86_FENCE_TEST = "MP-cg-sys-fence-x86_64"
FENCE_ANNOT = "f[sc,sys]"
FENCE_CALL = '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "")'

# MI300A / MI300X.  Both parts report gfx942; hipDeviceAttributeIntegrated is
# what separates them, and hip-allocator checks the harness reads it.
HIP_ARCH = "gfx942"
# The offload triple hipcc stamps into the executable's .hip_fatbin.  device-image greps
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
    print("[build-arms] build-script arms: comp.sh hip-link + Makefile hip-bin")
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
        # With every link target phony and no rule naming ./<test>, make falls
        # through to its BUILT-IN `%: %.o' -- see the behavioural check below,
        # which is the one that can detect that.
        ("./<test> refusal rule", r"^%s:$" % re.escape(t), mk, "Makefile"),
        ("built-in rules disabled", r"^\.SUFFIXES:$", mk, "Makefile"),
        ("./<test> .PHONY", r"^\.PHONY:.*\b%s\b" % re.escape(t), mk, "Makefile"),
    ]:
        tick("build-arms")
        if not re.search(pat, blob, re.M):
            fail("build-arms", "%s missing from emitted %s (/%s/)" % (what, where, pat))
    # The link line must name the HIP objects and the HIP compiler, not the CUDA
    # ones: a hip-bin recipe that linked <t>.o would build the CUDA harness under
    # the AMD target's name.
    tick("build-arms")
    if not re.search(r"\$\(HIPCC\) --offload-arch=\$\(HIP_ARCH\) \$\^ -o %s " % re.escape(t), mk):
        fail("build-arms", "Makefile hip-bin does not link with $(HIPCC) "
             "--offload-arch=$(HIP_ARCH) into ./%s" % t)
    tick("build-arms")
    if not re.search(r"HIP_ARCH \?= %s" % HIP_ARCH, mk):
        fail("build-arms", "Makefile does not default HIP_ARCH to %s" % HIP_ARCH)
    # This directory is the HIP render (-gpu-target hip), so the CUDA arms must
    # be ABSENT -- cuda-nonregression reads them in the cuda render's own directory.  A dir that
    # still carried both would mean the target filter stopped filtering.
    for where, blob in [("comp.sh", comp), ("Makefile", mk)]:
        tick("build-arms")
        if re.search(r"\bcuda\b|\bCUDA\b|\bNVCC\b", blob):
            fail("build-arms", "the HIP render's %s still carries CUDA arms -- `-gpu-target "
                       "hip' must emit one vendor's build targets only" % where)

    make_test_refuses(tmp, d, "build-arms", "hip-bin")
    print("      %d assertions" % counts.get("build-arms", 0))
    if not counts.get("build-arms"):
        fail("build-arms", "phase made no assertions")


def make_test_refuses(tmp, d, phase, link_target):
    """`make <test>' must refuse, checked by RUNNING it: with every link target
       phony and no rule naming ./<test>, `make <test>' reaches GNU make's
       built-in `%: %.o' link rule, which never consults the uname -m guard, and
       whether that link then fails is up to the objects' symbols rather than to
       the guard.  The hole is the absence of a rule, which no grep of the
       Makefile can show.
       Run on every render: the built-in rule can only fire where the GPU object
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
    print("[hip-compile] compile: hipcc --offload-arch=%s -c the emitted .hip" % HIP_ARCH)
    if not have("hipcc"):
        fail("hip-compile", "hipcc not on PATH -- this gate cannot verify the AMD lane here; "
                   "run it where ROCm exists before trusting the .hip")
        return
    w = d
    r = run(["sh", "comp.sh", "hip"], cwd=w)
    tick("hip-compile")
    if r.returncode != 0:
        fail("hip-compile", "comp.sh hip failed (exit %d):\n%s%s"
             % (r.returncode, r.stdout[-2000:], r.stderr[-2000:]))
        return
    tick("hip-compile")
    if "+ hipcc --offload-arch=%s" % HIP_ARCH not in r.stdout:
        fail("hip-compile", "comp.sh hip did not report the hipcc "
             "--offload-arch=%s step:\n%s" % (HIP_ARCH, r.stdout))
    obj = os.path.join(w, test_of(w) + "_hip.o")
    tick("hip-compile")
    if not os.path.isfile(obj):
        fail("hip-compile", "comp.sh hip left no %s_hip.o" % test_of(w))
    print("      %d assertions" % counts.get("hip-compile", 0))
    if not counts.get("hip-compile"):
        fail("hip-compile", "phase made no assertions")


def phase3(tmp, d):
    print("[device-image] comp.sh hip-link and make hip-bin each produce a %s ELF"
          % HIP_ARCH)
    if not have("hipcc"):
        fail("device-image", "hipcc not on PATH -- the HIP link arms cannot be verified here")
        return
    t = test_of(d)
    for arm, cmd in [("comp.sh hip-link", ["sh", "comp.sh", "hip-link"]),
                     ("make hip-bin", ["make", "hip-bin"])]:
        w = fresh(tmp, d, "p3-" + arm.split()[0].replace(".", ""))
        r = run(cmd, cwd=w)
        tick("device-image")
        if r.returncode != 0:
            fail("device-image", "%s failed (exit %d):\n%s%s"
                 % (arm, r.returncode, r.stdout[-2000:], r.stderr[-2000:]))
            continue
        b = os.path.join(w, t)
        tick("device-image")
        if not os.path.isfile(b) or not os.access(b, os.X_OK):
            fail("device-image", "%s exited 0 but left no executable ./%s" % (arm, t))
            continue
        tick("device-image")
        if not has_gfx(b):
            fail("device-image", "%s produced ./%s with NO %s device image -- a host-only "
                       "binary that would run and test nothing" % (arm, t, OFFLOAD_TRIPLE))
    print("      %d assertions" % counts.get("device-image", 0))
    if not counts.get("device-image"):
        fail("device-image", "phase made no assertions")


def phase4(tmp, d_aarch64_cuda, d_x86_hip):
    """Fail-closed on the WRONG HOST, at both stages that can catch it.

    Two assertions, which fail closed for different reasons and could regress
    alone:
      (a) a link arm refuses a foreign host -- driven on the (AArch64, cuda)
          render, whose guard is emitted by the same fold as the HIP one;
      (b) the x86 HIP render carries that guard too, keyed to its own host ISA
          (it cannot be RUN into refusal here: this host is x86_64, which is
          exactly the ISA that render is for).
    """
    print("[host-pair-guard] fail-closed on the wrong host, at emission and at link, on %s"
          % os.uname().machine)
    if os.uname().machine == "aarch64":
        fail("host-pair-guard", "this host IS aarch64, so the AArch64 refusal cannot "
                                "be observed here; "
                   "run this gate on a foreign host too")
        return

    # --- (a) a link arm refuses a foreign host ------------------------------
    for arm, cmd, want in [("comp.sh cuda-link", ["sh", "comp.sh", "cuda-link"], 3),
                           ("make cuda-bin", ["make", "cuda-bin"], 2)]:
        r = run(cmd, cwd=d_aarch64_cuda)
        blob = r.stdout + r.stderr
        tick("host-pair-guard")
        if r.returncode != want:
            fail("host-pair-guard", "%s on an AArch64 render exited %d, expected %d -- a link that "
                       "succeeds here links the PORTABLE SHIM"
                 % (arm, r.returncode, want))
        tick("host-pair-guard")
        if "refuses on" not in blob or "PORTABLE SHIM" not in blob:
            fail("host-pair-guard", "%s refused without saying why (no 'refuses on' / "
                                    "'PORTABLE SHIM'):\n%s"
                 % (arm, blob[-800:]))
        tick("host-pair-guard")
        if "AArch64 asm" not in blob:
            fail("host-pair-guard", "%s refusal does not name the CPU ISA it was rendered for:\n%s"
                 % (arm, blob[-800:]))
        tick("host-pair-guard")
        if os.path.isfile(os.path.join(d_aarch64_cuda, test_of(d_aarch64_cuda))):
            fail("host-pair-guard", "%s refused but a binary exists anyway" % arm)

    # --- (b) the HIP render carries the same guard --------------------------
    comp = open(os.path.join(d_x86_hip, "comp.sh")).read()
    mk = open(os.path.join(d_x86_hip, "Makefile")).read()
    for what, txt in [("comp.sh", comp), ("Makefile", mk)]:
        tick("host-pair-guard")
        if 'HET_HOST_ISA="x86_64"' not in txt and "HET_HOST_ISA ?= x86_64" not in txt:
            fail("host-pair-guard", "the HIP render's %s does not record its host ISA, so its link "
                       "arm has nothing to guard on:\n%s" % (what, txt[:400]))
        tick("host-pair-guard")
        if "PORTABLE SHIM" not in txt:
            fail("host-pair-guard", "the HIP render's %s carries no uname guard on its link arm "
                       "-- linking it on a foreign host would test nothing" % what)

    print("      %d assertions" % counts.get("host-pair-guard", 0))
    if not counts.get("host-pair-guard"):
        fail("host-pair-guard", "phase made no assertions")


def plant(src_bin, dst_bin):
    """Put one vendor's linked binary where the other vendor's target writes, and
       make it NEWER than everything around it.  That is the state the stale-link
       trap needs, and a results tree reused across boxes reaches it for real."""
    shutil.copyfile(src_bin, dst_bin)
    os.chmod(dst_bin, 0o755)
    os.utime(dst_bin, None)


def phase5(tmp, d_cuda, d_hip):
    print("[stale-binary] no silent stale link: each vendor's target always relinks ./<test>")
    if not (have("hipcc") and have("nvcc")):
        fail("stale-binary", "this phase needs BOTH hipcc and nvcc to prove the "
                             "cross-vendor relink "
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
                tick("stale-binary")
                fail("stale-binary", "%s cannot run: the earlier round left no ./%s to plant"
                     % (label, t))
                break
            plant(plant_from, b)
        r = run(cmd, cwd=w)
        tick("stale-binary")
        if r.returncode != 0:
            fail("stale-binary", "make %s failed:\n%s%s"
                 % (label, r.stdout[-1500:], r.stderr[-1500:]))
            return
        got = has_gfx(b)
        tick("stale-binary")
        if got != want_gfx:
            vendor = "AMD" if want_gfx else "CUDA"
            other = "CUDA" if want_gfx else "AMD"
            if want_gfx:
                fail("stale-binary", "%s left ./%s without a %s device image -- the %s target "
                           "reported success and handed back the %s harness%s (make said: %r)"
                     % (label, t, OFFLOAD_TRIPLE, vendor, other,
                        " [THE DISCRIMINATING ROUND]" if discriminating else "",
                        r.stdout.strip()[-200:]))
            else:
                fail("stale-binary", "%s left the %s device image in ./%s -- the %s target "
                           "reported success and handed back the %s harness%s (make said: %r)"
                     % (label, OFFLOAD_TRIPLE, t, vendor, other,
                        " [THE DISCRIMINATING ROUND]" if discriminating else "",
                        r.stdout.strip()[-200:]))
    print("      %d assertions" % counts.get("stale-binary", 0))
    if not counts.get("stale-binary"):
        fail("stale-binary", "phase made no assertions")


# --- hip-allocator: the allocator, executed under a stub HIP ----------------

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
    print("[hip-allocator] fail-closed: HET_ALLOC modes + device preconditions "
          "(no AMD GPU)")
    path, why = build_resolver(tmp, d)
    if path is None:
        tick("hip-allocator")
        fail("hip-allocator", why)
        return
    # (a) the accepted spellings resolve, print the banner, and do not exit.
    for m in HIP_ACCEPTED_MODES:
        r = drv(path, mode=(None if m == "" else m))
        tick("hip-allocator")
        if r.returncode != 0:
            fail("hip-allocator", "HET_ALLOC=%r was REFUSED (exit %d) but this render "
                                  "implements it:\n%s"
                 % (m or "<unset>", r.returncode, (r.stdout + r.stderr)[-600:]))
            continue
        tick("hip-allocator")
        if "RESOLVED mode=1" not in r.stdout:
            fail("hip-allocator", "HET_ALLOC=%r did not resolve to the managed "
                                  "mode:\n%s" % (m or "<unset>", r.stdout))
        tick("hip-allocator")
        if "shared-mem mode=managed" not in r.stdout:
            fail("hip-allocator",
                 "HET_ALLOC=%r printed no shared-mem banner -- the run would leave no "
                       "record of which allocator it used:\n%s" % (m or "<unset>", r.stdout))
    # (b) every other spelling is FATAL.  Rule 8: unrecognised mode refuses.
    for m in HIP_REFUSED_MODES:
        r = drv(path, mode=m)
        tick("hip-allocator")
        if r.returncode != 2:
            fail("hip-allocator",
                 "HET_ALLOC=%r exited %d, expected 2 -- an unimplemented mode that "
                       "silently allocates managed memory runs a DIFFERENT experiment under "
                       "the requested name" % (m, r.returncode))
            continue
        tick("hip-allocator")
        if "FATAL" not in r.stderr or "not a shared-memory mode" not in r.stderr:
            fail("hip-allocator", "HET_ALLOC=%r refused without naming the reason:\n%s"
                 % (m, r.stderr[-600:]))
    # (c) device preconditions.  hipMallocManaged degrades to hipMallocHost when
    #     HMM is absent [HipRuntimeApi "hipMallocManaged"], and the CPU may not
    #     touch managed memory mid-kernel without concurrent managed access.
    #     Both fatal.
    for label, kw, needle in [
        ("managedMemory=0", dict(managed=0), "hipDeviceAttributeManagedMemory=0"),
        ("concurrentManagedAccess=0", dict(cma=0), "hipDeviceAttributeConcurrentManagedAccess=0"),
    ]:
        r = drv(path, **kw)
        tick("hip-allocator")
        if r.returncode != 2:
            fail("hip-allocator",
                 "%s exited %d, expected 2 -- the harness would run with the shared "
                       "vars off the coherent path" % (label, r.returncode))
            continue
        tick("hip-allocator")
        if needle not in r.stderr:
            fail("hip-allocator", "%s refused without naming the attribute:\n%s"
                 % (label, r.stderr[-600:]))
    # (d) MI300A vs MI300X.  Both report gfx942; only `integrated' separates them,
    #     and a discrete-part histogram must never be read as an MI300A result.
    r = drv(path, integrated=1)
    tick("hip-allocator")
    if "amd_part_class=APU(integrated)" not in r.stdout:
        fail("hip-allocator", "integrated=1 was not classified as an integrated APU "
                              "in the banner:\n%s" % r.stdout)
    r = drv(path, integrated=0)
    tick("hip-allocator")
    if r.returncode != 0:
        fail("hip-allocator", "integrated=0 (MI300X) exited %d -- the discrete part "
                   "is the machinery bring-up target and must be able to run"
             % r.returncode)
    tick("hip-allocator")
    if "amd_part_class=DISCRETE(not-integrated)" not in r.stdout:
        fail("hip-allocator", "integrated=0 was not classified as a discrete part in "
                              "the banner -- a log "
                   "reader could not tell an MI300X run from an MI300A one:\n%s" % r.stdout)
    tick("hip-allocator")
    if "WARNING" not in r.stderr \
            or "NOT be reported as an integrated-APU result" not in r.stderr:
        fail("hip-allocator",
             "integrated=0 produced no warning that this is not an integrated-APU "
             "result:\n%s" % r.stderr[-600:])

    # (e) ...and the harness must actually call it.
    # Everything above drives the resolver in isolation: it says NOTHING about
    # whether the harness ever runs it.  Drop gd_alloc_shared's one
    #     (void)_het_alloc_mode();   /* resolve + guard once, before the ... */
    # in het_alloc_hip.inc and the resolver stays defined, gd_free_shared still
    # calls it, and every assertion above still passes -- while the shipped
    # binary ignores HET_ALLOC and both device preconditions at allocation time
    # and the guard fires only at teardown, after the histogram, the HetVerdict
    # and the HetStats lines have been printed.
    # The CUDA render needs no such assertion: its gd_alloc_shared dispatches on
    # the returned mode (`int _m = _het_alloc_mode(); if (_m == HET_ALLOC_MALLOC)
    # ...'), so dropping the call does not compile.  The HIP call's only effect
    # is the guard, so nothing anchors it but this.
    hip_src = open(os.path.join(d, test_of(d) + ".hip")).read()
    alloc_body = fn_body(hip_src, "gd_alloc_shared")
    tick("hip-allocator")
    if alloc_body is None:
        fail("hip-allocator", "no gd_alloc_shared in the emitted %s.hip -- the shared allocator "
                   "the resolver exists to guard is not there" % test_of(d))
    else:
        tick("hip-allocator")
        n = alloc_body.count("_het_alloc_mode()")
        if n != 1:
            fail("hip-allocator",
                 "gd_alloc_shared calls _het_alloc_mode() %d time(s), expected 1 -- "
                       "with no call the harness ALLOCATES WITHOUT EVER RESOLVING THE "
                       "MODE: HET_ALLOC is ignored and the managedMemory / "
                       "concurrentManagedAccess guards do not run until gd_free_shared, "
                       "after the histogram has been printed. Body:\n%s" % (n, alloc_body))
        else:
            # Order matters as much as presence: the contract is "resolve + guard
            # ONCE, BEFORE the first alloc".  A call moved below the allocation
            # still exits(2), but only after the memory it was meant to vet has
            # been handed out.
            tick("hip-allocator")
            i_res = alloc_body.index("_het_alloc_mode()")
            i_all = alloc_body.find("hipMallocManaged")
            if i_all < 0:
                fail("hip-allocator", "gd_alloc_shared does not call hipMallocManaged -- the "
                           "fine-grained allocation this render is built on is gone")
            elif i_res > i_all:
                fail("hip-allocator", "gd_alloc_shared resolves the mode AFTER hipMallocManaged -- "
                           "the guard must run BEFORE the first allocation, or the "
                           "memory it exists to vet has already been handed out. Body:\n%s"
                     % alloc_body)
    free_body = fn_body(hip_src, "gd_free_shared")
    tick("hip-allocator")
    if free_body is None or "_het_alloc_mode()" not in free_body:
        fail("hip-allocator",
             "gd_free_shared does not call _het_alloc_mode() -- the free must stay "
                   "keyed on the resolver so a second mode cannot leave a mismatched "
                   "free behind")

    print("      %d assertions" % counts.get("hip-allocator", 0))
    if not counts.get("hip-allocator"):
        fail("hip-allocator", "phase made no assertions")


def phase6b(tmp, d):
    """HET_PLACE is CUDA-only and must be REFUSED here, not silently reported.

    Its own phase because it is the only part of the allocator story that builds
    with hipcc: the five hip-allocator injections all corrupt the resolver, which is
    lifted
    out and driven under a stub, and none of them can move a compile-time
    refusal.  Splitting the two means each injection pays for the phase it can
    redden.
    """
    print("[place-refusal] HET_PLACE: the CUDA-only lever the AMD render must refuse")
    # Both renders print `place=%d' in the cpu-stress banner and carry place_mode
    # in the statistics record (one emitter, two dialects), but placement is
    # cudaMemAdvise/cudaMemPrefetchAsync and lives only in het_alloc_cuda.inc --
    # why the AMD answer is a compile-time refusal rather than a runtime warning
    # is litmus/het-runtime/het_alloc_hip.inc.
    hip_src = open(os.path.join(d, test_of(d) + ".hip")).read()
    tick("place-refusal")
    if "#if (HET_PLACE) != 0" not in hip_src or "# error" not in hip_src:
        fail("place-refusal", "the emitted .hip does not REFUSE a non-zero HET_PLACE at compile "
                    "time -- a -DHET_PLACE=1 AMD build would report place=1 with "
                    "place_fail=0 while placing nothing")
    if have("hipcc"):
        w = fresh(tmp, d, "p6place")
        r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=1"], cwd=w)
        tick("place-refusal")
        if r.returncode == 0:
            fail("place-refusal", "`make hip HIPCC=\"hipcc -DHET_PLACE=1\"' SUCCEEDED -- the AMD "
                        "render accepted a placement lever it does not implement")
        tick("place-refusal")
        if "HET_PLACE is a CUDA-only lever" not in (r.stdout + r.stderr):
            fail("place-refusal", "a -DHET_PLACE=1 AMD build failed without saying why:\n%s"
                 % (r.stdout + r.stderr)[-800:])
        # ...and HET_PLACE=0, the default and the only honourable value, still builds.
        w = fresh(tmp, d, "p6place0")
        r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=0"], cwd=w)
        tick("place-refusal")
        if r.returncode != 0:
            fail("place-refusal", "-DHET_PLACE=0 (the DEFAULT) no longer compiles -- the refusal "
                        "is over-broad and blocks every ordinary AMD build:\n%s"
                 % (r.stdout + r.stderr)[-800:])
    print("      %d assertions" % counts.get("place-refusal", 0))
    if not counts.get("place-refusal"):
        fail("place-refusal", "phase made no assertions")


def phase7(tmp, d):
    print("[cuda-nonregression] CUDA non-regression: the cuda / cuda-link / cuda-bin arms")
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
        tick("cuda-nonregression")
        if not re.search(pat, blob, re.M):
            fail("cuda-nonregression", "%s missing or altered in the emitted build "
                                       "scripts (/%s/)" % (what, pat))
    # ...and this render is CUDA-only, the mirror of build-arms's check on the HIP one.
    for where, blob in [("comp.sh", comp), ("Makefile", mk)]:
        tick("cuda-nonregression")
        if re.search(r"\bhip\b|\bHIP\b|\bHIPCC\b", blob):
            fail("cuda-nonregression",
                 "the CUDA render's %s still carries HIP arms -- `-gpu-target "
                       "cuda' must emit one vendor's build targets only" % where)
    # The CUDA render is where make's built-in `%: %.o' rule is REACHABLE (its
    # GPU object is <test>.o), so the behavioural refusal check has to run here
    # as well as on the HIP render.
    make_test_refuses(tmp, d, "cuda-nonregression", "cuda-bin")
    if not have("nvcc"):
        fail("cuda-nonregression", "nvcc not on PATH -- the CUDA lane cannot be re-verified here")
    else:
        w = fresh(tmp, d, "p7")
        r = run(["sh", "comp.sh", "cuda"], cwd=w)
        tick("cuda-nonregression")
        if r.returncode != 0:
            fail("cuda-nonregression", "comp.sh cuda regressed (exit %d):\n%s%s"
                 % (r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    print("      %d assertions" % counts.get("cuda-nonregression", 0))
    if not counts.get("cuda-nonregression"):
        fail("cuda-nonregression", "phase made no assertions")


def phase8(tmp, d, src):
    """The AMD fence: compiled as the harness ships it, host half and all.

    Two text assertions keep that compile from being vacuous -- a fence-free
    .hip compiles beautifully and proves nothing -- and the compile is the
    assertion neither of them can make.
    """
    print("[fence-lowering] AMD fence: the emitted %s, compiled by hipcc" % FENCE_CALL)
    t = test_of(d)
    annots = re.findall(r"f\[[^\]]*\]", open(src).read())
    tick("fence-lowering")
    if not annots or set(annots) != {FENCE_ANNOT}:
        fail("fence-lowering", "%s annotates %s, not one or more %s -- this phase would "
                   "compile a different lowering, or none at all"
             % (os.path.basename(src), sorted(set(annots)) or "no GPU fence",
                FENCE_ANNOT))
        return
    hip = open(os.path.join(d, t + ".hip")).read()
    n_any = hip.count("__builtin_amdgcn_fence(")
    n_doc = hip.count(FENCE_CALL)
    tick("fence-lowering")
    if n_any < len(annots):
        fail("fence-lowering", "the emitted .hip carries %d __builtin_amdgcn_fence( for a "
                   "test annotating %d %s -- the fence was dropped on the way out"
             % (n_any, len(annots), FENCE_ANNOT))
    tick("fence-lowering")
    if n_doc != n_any:
        fail("fence-lowering", "%d of the %d emitted fence(s) carry the documented lowering "
                   "%s -- a named sync scope compiles too, and is narrower than "
                   "system" % (n_doc, n_any, FENCE_CALL))
    if not have("hipcc"):
        fail("fence-lowering", "hipcc not on PATH -- the fence lowering cannot be compiled here")
    else:
        w = fresh(tmp, d, "p8")
        r = run(["sh", "comp.sh", "hip"], cwd=w)
        tick("fence-lowering")
        if r.returncode != 0:
            fail("fence-lowering", "comp.sh hip failed on the fence-carrying render (exit %d) "
                       "-- the render must build under the flags the harness "
                       "ships:\n%s%s"
                 % (r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    print("      %d assertions" % counts.get("fence-lowering", 0))
    if not counts.get("fence-lowering"):
        fail("fence-lowering", "phase made no assertions")


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
    """Strip the Makefile to the shape with no `.SUFFIXES:', no rule naming
       ./<test>, and ./<test> not phony.  That is the state in which `make
       <test>' reaches GNU make's built-in `%: %.o' link rule -- and it is also
       the state stale-binary's trap needs, because a PHONY ./<test> is never
       "up to date" and the trap could not spring."""
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


def bite(tmp, d_x86, d_x86_cuda, d_aa_cuda, d_fence, fence_src):
    print("===== HIPBUILDCHECK BITE: every phase, on corruption AND on omission =====")
    ok = True
    n = [0]

    def W(tag, base=None):
        n[0] += 1
        return fresh(tmp, base or d_x86, "bite%d-%s" % (n[0], tag))

    # --- build-arms ---------------------------------------------------------
    w = W("p1c")
    # Anchored on the whole case-arm LINE: the unknown-target refusal quotes
    # `(accepted: hip|hip-link)' too, and a bare substring would corrupt both.
    sub(os.path.join(w, "comp.sh"), "\n  hip|hip-link)\n", "\n  hip|hip-lonk)\n")
    ok &= bite_one("comp.sh hip-link arm misspelt", "build-arms",
                   lambda: phase1(tmp, w), "hip-link case arm")
    w = W("p1r")
    sub(os.path.join(w, "comp.sh"),
        r'comp.sh: unknown target \"$TARGET\" -- this directory is hip-only ',
        "usage: sh comp.sh ")
    ok &= bite_one("comp.sh unknown-target refusal cut back to a bare usage line "
                   "(it no longer quotes the rejected argument)", "build-arms",
                   lambda: phase1(tmp, w), "unknown-target refusal")
    w = W("p1o")
    mk = os.path.join(w, "Makefile")
    s = open(mk).read()
    s = re.sub(r"^hip-bin: .*\n(?:\t.*\n)*", "", s, flags=re.M)
    open(mk, "w").write(s)
    ok &= bite_one("Makefile hip-bin rule DELETED", "build-arms",
                   lambda: phase1(tmp, w), "hip-bin rule")
    w = W("p1p")
    # Surgical: hip-bin ONLY.  ./<test> stays phony, so this bite isolates the
    # one object it names instead of also tripping the ./<test> assertions.
    sub(os.path.join(w, "Makefile"), phony_line(w),
        phony_line(w).replace(" hip-bin", "", 1))
    ok &= bite_one("hip-bin dropped from .PHONY", "build-arms",
                   lambda: phase1(tmp, w), "hip-bin .PHONY")
    # OMISSION: with every link target phony there is no rule naming ./<test>, so
    # make falls through to its BUILT-IN `%: %.o' and links it with $(CC), guard
    # and device code both gone.  Deleting the refusal rule reaches exactly that
    # state, and only RUNNING make can catch it, since the defect is an absent
    # rule.  Driven on the CUDA render, the only one where the fall-through is
    # reachable: the built-in rule is `%: %.o' and the HIP render's GPU object is
    # <test>_hip.o, so there make simply reports no rule at all.  cuda-nonregression owns the
    # behavioural check on that render.
    w = W("p7b", d_x86_cuda)
    strip_refusal_rule(w)
    # The expected object is the BEHAVIOURAL assertion, not the grep for the rule:
    # the grep also reddens here, and a bite satisfied by the grep would not show
    # that the check can still detect this if someone leaves a rule in place that
    # does not actually refuse.
    ok &= bite_one("./<test> refusal rule + .SUFFIXES DELETED (make falls back to "
                   "its built-in link rule)", "cuda-nonregression", lambda: phase7(tmp, w),
                   "reached make's BUILT-IN rule")
    # CORRUPTION: the rule survives but ./<test> is no longer .PHONY, so a run
    # that already has a binary gets "up to date", exit 0, and whatever the other
    # vendor left behind.
    w = W("p1q")
    sub(os.path.join(w, "Makefile"), phony_line(w),
        phony_line(w)[: -(len(test_of(w)) + 1)])
    ok &= bite_one("./<test> dropped from .PHONY (a present binary is 'up to date')",
                   "build-arms", lambda: phase1(tmp, w), "EXITED 0")
    # CORRUPTION with EVERY GREP STILL GREEN: the rule is there, .SUFFIXES is
    # there, ./<test> is phony -- and the recipe does nothing and exits 0.  Only
    # the behavioural check can see this, which is the point of running make.
    w = W("p1r")
    mk = os.path.join(w, "Makefile")
    s = open(mk).read()
    s = re.sub(r"^(%s:\n)\t@ echo .*\n" % re.escape(test_of(w)), r"\1\t@ true\n", s, flags=re.M)
    open(mk, "w").write(s)
    ok &= bite_one("./<test> rule kept but made a no-op that exits 0 (every "
                   "build-arms grep still passes)", "build-arms",
                   lambda: phase1(tmp, w), "EXITED 0")

    # --- hip-compile --------------------------------------------------------
    w = W("p2c")
    hp = os.path.join(w, test_of(w) + ".hip")
    open(hp, "a").write("\nthis is not c++;\n")
    ok &= bite_one(".hip made uncompilable", "hip-compile", lambda: phase2(w),
                   "comp.sh hip failed")
    w = W("p2o")
    os.remove(os.path.join(w, test_of(w) + ".hip"))
    ok &= bite_one(".hip DELETED", "hip-compile", lambda: phase2(w), "comp.sh hip failed")

    # --- device-image -------------------------------------------------------
    w = W("p3c")
    # The build runs and EXITS 0 -- for the wrong hardware.  A gfx90a (MI200)
    # image links cleanly and would never run on MI300A/MI300X.  Exit status
    # alone calls this a pass, so device-image has to read the ELF and insist on the
    # gfx942 triple rather than on "some device image".
    sub(os.path.join(w, "Makefile"), "HIP_ARCH ?= %s" % HIP_ARCH, "HIP_ARCH ?= gfx90a")
    sub(os.path.join(w, "comp.sh"), 'HIP_ARCH="${HIP_ARCH:-%s}"' % HIP_ARCH,
        'HIP_ARCH="${HIP_ARCH:-gfx90a}"')
    ok &= bite_one("both HIP arms build for gfx90a (MI200), exit 0", "device-image",
                   lambda: phase3(tmp, w), "NO amdgcn")
    w = W("p3o")
    s = open(os.path.join(w, "comp.sh")).read()
    s = s.replace('    if [ "$TARGET" = hip-link ]; then', '    if false; then')
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh hip-link LINK STEP removed (still exits 0)", "device-image",
                   lambda: phase3(tmp, w), "left no executable")

    # --- host-pair-guard ----------------------------------------------------
    # The link-arm half, driven on the (AArch64, cuda) render.
    w = W("p4c", d_aa_cuda)
    sub(os.path.join(w, "comp.sh"), '"$(uname -m)" != "$HET_HOST_ISA"',
        '"$(uname -m)" = "$HET_HOST_ISA"')
    sub(os.path.join(w, "Makefile"), 'test "$$(uname -m)" = "$(HET_HOST_ISA)"',
        'test "$$(uname -m)" != "$(HET_HOST_ISA)"')
    ok &= bite_one("uname guard INVERTED on an AArch64 render", "host-pair-guard",
                   lambda: phase4(tmp, w, d_x86), "expected 3")
    w = W("p4o", d_aa_cuda)
    s = open(os.path.join(w, "comp.sh")).read()
    s = re.sub(r'    if \[ "\$TARGET" = cuda-link \] && \[ "\$\(uname -m\)".*?\n    fi\n',
               "", s, flags=re.S)
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh cuda-link uname guard DELETED", "host-pair-guard",
                   lambda: phase4(tmp, w, d_x86), "expected 3")
    # (c): the HIP render loses its guard, which no RUN on this x86_64 host can
    # observe -- the guard is keyed to the ISA this host already is.
    w = W("p4h", d_x86)
    sub(os.path.join(w, "comp.sh"), "PORTABLE SHIM", "portable stand-in")
    sub(os.path.join(w, "Makefile"), "PORTABLE SHIM", "portable stand-in")
    ok &= bite_one("the HIP render\'s uname guard TEXT gone", "host-pair-guard",
                   lambda: phase4(tmp, d_aa_cuda, w), "carries no uname guard")

    # --- stale-binary -------------------------------------------------------
    # stale-binary drives two directories, so each injection goes into ONE of them and the
    # other stays pristine -- otherwise a bite could redden for the wrong render.
    w = W("p5c", d_x86_cuda)
    # cuda-bin as a phony with a FILE prerequisite -- the shape in which make
    # answers "nothing to be done".  The refusal rule has to come out first: it
    # makes ./<test> phony, and a phony target is never "up to date", so with it
    # in place make would rerun the recipe for a reason that has nothing to do
    # with the trap and this bite would go inert.
    strip_refusal_rule(w)
    s = open(os.path.join(w, "Makefile")).read()
    t = test_of(w)
    s = s.replace("cuda-bin: %s.o outs.o %s_cpu_host.o\n" % (t, t),
                  "cuda-bin: %s\n\n%s: %s.o outs.o %s_cpu_host.o\n" % (t, t, t, t))
    s = s.replace("$(NVCC) -arch=$(CUDA_ARCH) $^ -o %s -lpthread -lm" % t,
                  "$(NVCC) -arch=$(CUDA_ARCH) $^ -o $@ -lpthread -lm")
    open(os.path.join(w, "Makefile"), "w").write(s)
    wh = W("p5c-hip")
    ok &= bite_one("cuda-bin reverted to a FILE rule (the measured stale trap)", "stale-binary",
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
    ok &= bite_one("hip-bin LINK COMMAND deleted (target still exits 0)", "stale-binary",
                   lambda: phase5(tmp, wc, w), "without a amdgcn")

    # --- hip-allocator ------------------------------------------------------
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
    ok &= bite_one("unknown HET_ALLOC falls back to managed instead of exit(2)", "hip-allocator",
                   lambda: phase6(tmp, w), "expected 2")
    w = W("p6o")
    hp = os.path.join(w, test_of(w) + ".hip")
    s = open(hp).read()
    s = re.sub(r"  if \(!_managed\) \{.*?\n    exit\(2\);\n  \}\n", "", s, flags=re.S)
    open(hp, "w").write(s)
    ok &= bite_one("the managedMemory precondition DELETED", "hip-allocator",
                   lambda: phase6(tmp, w), "managedMemory=0 exited")
    w = W("p6x")
    hp = os.path.join(w, test_of(w) + ".hip")
    s = open(hp).read()
    s = s.replace('return _integrated ? "APU(integrated)" : "DISCRETE(not-integrated)";',
                  'return "APU(integrated)";')
    open(hp, "w").write(s)
    ok &= bite_one("a discrete part classified as an integrated APU", "hip-allocator",
                   lambda: phase6(tmp, w), "not classified as a discrete part")
    # The inert-mechanism omission.  Everything hip-allocator does above still passes with
    # this deleted -- the resolver is still defined, still correct, and still
    # called by gd_free_shared.  It is simply NEVER called where it has to run.
    w = W("p6call")
    hp = os.path.join(w, test_of(w) + ".hip")
    sub(hp, "  (void)_het_alloc_mode();               "
            "/* resolve + guard once, before the first alloc */\n", "")
    ok &= bite_one("gd_alloc_shared's _het_alloc_mode() CALL deleted (resolver still "
                   "defined and still called by gd_free_shared)", "hip-allocator",
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
    ok &= bite_one("the guard moved BELOW hipMallocManaged", "hip-allocator",
                   lambda: phase6(tmp, w), "AFTER hipMallocManaged")
    # --- place-refusal ------------------------------------------------------
    # HET_PLACE: the CUDA-only lever both renders PRINT.
    w = W("p6place")
    hp = os.path.join(w, test_of(w) + ".hip")
    sub(hp, "#if (HET_PLACE) != 0", "#if 0")
    ok &= bite_one("the HET_PLACE compile-time refusal disabled (a -DHET_PLACE=1 AMD "
                   "build would log place=1 place_fail=0 having placed nothing)", "place-refusal",
                   lambda: phase6b(tmp, w), "does not REFUSE a non-zero HET_PLACE")

    # --- cuda-nonregression -------------------------------------------------
    w = W("p7c", d_x86_cuda)
    sub(os.path.join(w, "Makefile"), "$(NVCC) -arch=$(CUDA_ARCH) $^ -o",
        "$(HIPCC) --offload-arch=$(HIP_ARCH) $^ -o")
    ok &= bite_one("cuda-bin links with HIPCC", "cuda-nonregression", lambda: phase7(tmp, w),
                   "cuda-bin links with NVCC")
    w = W("p7o", d_x86_cuda)
    s = open(os.path.join(w, "comp.sh")).read()
    s = s.replace("  cuda|cuda-link)", "  cuda)")
    open(os.path.join(w, "comp.sh"), "w").write(s)
    ok &= bite_one("comp.sh cuda-link arm DELETED", "cuda-nonregression", lambda: phase7(tmp, w),
                   "cuda-link case arm")

    # --- fence-lowering -----------------------------------------------------
    # OMISSION: the fence gone from the render.  The .hip still compiles, so on
    # this gate the text assertion is ALL that stands between it and a fence-free
    # AMD harness for a fence test: nothing reads the compiled fence back.
    w = W("p8o", d_fence)
    hp = os.path.join(w, test_of(w) + ".hip")
    s = re.sub(r"^.*__builtin_amdgcn_fence\(.*\n", "",
               open(hp).read(), flags=re.M)
    open(hp, "w").write(s)
    ok &= bite_one("the emitted __builtin_amdgcn_fence DELETED", "fence-lowering",
                   lambda: phase8(tmp, w, fence_src),
                   "the fence was dropped on the way out")
    # CORRUPTION THAT COMPILES: system scope is the empty string, so naming a
    # scope narrows the fence to one agent and hipcc says nothing.  This is the
    # half the compile cannot reach.
    w = W("p8n", d_fence)
    sub(os.path.join(w, test_of(w) + ".hip"), FENCE_CALL,
        '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "agent")')
    ok &= bite_one('the fence sync scope narrowed to "agent" (it still builds)',
                   "fence-lowering", lambda: phase8(tmp, w, fence_src),
                   "carry the documented lowering")
    # CORRUPTION THE COMPILE CATCHES: "system" is not an AMDHSA sync-scope name,
    # and it is the exact way to get `sys' wrong.  It trips the text assertion
    # too; the assertion this bite is for is the one bite_one prints.
    w = W("p8c", d_fence)
    sub(os.path.join(w, test_of(w) + ".hip"), FENCE_CALL,
        '__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "system")')
    ok &= bite_one('the fence sync scope spelt "system"', "fence-lowering",
                   lambda: phase8(tmp, w, fence_src),
                   "comp.sh hip failed on the fence-carrying render")

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
        # The AArch64 render host-pair-guard drives is the CUDA one.  The uname
        # guard is emitted by the same per-dialect fold on both, which is what
        # makes the substitution sound.
        d_aa_cuda = emit(tmp, os.path.join(HET_DIR, AARCH64_TEST + ".litmus"),
                         os.path.join(tmp, "out-aa"), "AArch64 render", "cuda")
        # ...and the fence-carrying render, which is a different test: the one
        # every other phase drives annotates no fence at all.
        fence_src = os.path.join(corpus, X86_FENCE_TEST + ".litmus")
        if not os.path.isfile(fence_src):
            raise SystemExit("hipbuildcheck: generate-x86.sh emitted no %s"
                             % X86_FENCE_TEST)
        d_fence = emit(tmp, fence_src, os.path.join(tmp, "out-x86-fence-hip"),
                       "x86 fence render", "hip")

        if a.bite:
            return bite(tmp, d_x86, d_x86_cuda, d_aa_cuda, d_fence, fence_src)

        print("===== HIPBUILDCHECK: can an AMD harness be built and run? =====")
        print("  host %s, hipcc=%s nvcc=%s"
              % (os.uname().machine, have("hipcc"), have("nvcc")))
        phase1(tmp, d_x86)
        phase2(fresh(tmp, d_x86, "p2"))
        phase3(tmp, d_x86)
        phase4(tmp, d_aa_cuda, d_x86)
        phase5(tmp, d_x86_cuda, d_x86)
        phase6(tmp, d_x86)
        phase6b(tmp, d_x86)
        phase7(tmp, d_x86_cuda)
        phase8(tmp, d_fence, fence_src)
        print("=" * 70)
        if fails:
            print("HIPBUILDCHECK FAILED: %d assertion(s)" % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            return 1
        print("HIPBUILDCHECK: PASS (%d assertions over 9 phases)" % sum(counts.values()))
        print("  DEFERRED to the MI300X bring-up: there is no AMD GPU here, so the "
              "linked harness was never EXECUTED on a device.  hip-allocator ran the "
              "allocator resolver under a stub hipDeviceGetAttribute; the real "
              "hipMallocManaged coherence behaviour remains unverified.")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
