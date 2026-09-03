#!/usr/bin/env python3
"""
hipbuildcheck.py -- can an AMD harness be built, linked and refused correctly?

Phases, each counting its assertions and failing if it made none:
build-arms (`make <test>' refuses by name), hip-compile (hipcc compiles the
emitted .hip, and comp.sh reports a failure), device-image (both link arms leave
gfx942 code in the ELF), foreign-host (on a host of the other CPU ISA every make
path stops at the CPU file's #error and no link arm writes ./<test>, while
comp.sh cross-assembles that file into an object of the rendered ISA),
stale-binary (each link target relinks ./<test>), hip-allocator (the shared-mem
resolver, executed under a stub hipDeviceGetAttribute), place-refusal (HET_PLACE
refused at compile time) and cuda-nonregression.  A miss is a harness that builds
into something other than the test, or accepts what it has to refuse.
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
GEN_HET = os.path.join(HET_DIR, "generate.sh")
GEN_X86_ARGS = ["--cpu-arch", "x86_64"]
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

# The x86_64 rendering is the one an x86_64 host can LINK, and its GPU column
# annotates f[sc,sys], so every phase that compiles builds a fence render.
X86_TEST = "MP-cg-sys-fence-x86_64"
# The other CPU ISA: foreign-host drives whichever of the two renders is
# foreign to the host it runs on.
AARCH64_TEST = "MP-cg-sys-acqrel-2s"

# ELF e_machine (bytes 18-19, little-endian) per `uname -m' word: what a
# cross-assembled CPU object must report.
E_MACHINE = {"aarch64": 183, "x86_64": 62}

# MI300A / MI300X.  Both parts report gfx942; hipDeviceAttributeIntegrated is
# what separates them, and hip-allocator checks the harness reads it.
HIP_ARCH = "gfx942"
# The offload triple hipcc stamps into the executable's .hip_fatbin: a link that
# produced a host-only binary exits 0 and carries no device code.
OFFLOAD_TRIPLE = "amdgcn-amd-amdhsa--" + HIP_ARCH

# The HIP render implements ONE shared-memory mode.  Every other spelling, and
# every unmet device precondition, must exit(2).
HIP_ACCEPTED_MODES = ["", "auto", "managed"]
HIP_REFUSED_MODES = ["malloc"]

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
    """A pristine copy of harness dir [d], KEEPING its basename: test_of()
       reads it, and every <test>_hip.o assertion is named from it."""
    w = os.path.join(tmp, "w-" + tag, os.path.basename(d))
    shutil.rmtree(os.path.dirname(w), ignore_errors=True)
    os.makedirs(os.path.dirname(w))
    shutil.copytree(d, w)
    return w


def test_of(d):
    return os.path.basename(d)


def has_gfx(binpath):
    """Does this ELF carry a real gfx942 device image?  Read the bytes, do not
       trust the linker's exit status."""
    if not os.path.isfile(binpath):
        return False
    with open(binpath, "rb") as f:
        return OFFLOAD_TRIPLE.encode() in f.read()


# ------------------------------------------------------------------ phases

def phase1(tmp, d):
    print("[build-arms] `make <test>' refuses on the HIP render")
    make_test_refuses(tmp, d, "build-arms", "hip-bin")
    print("      %d assertions" % counts.get("build-arms", 0))
    if not counts.get("build-arms"):
        fail("build-arms", "phase made no assertions")


def make_test_refuses(tmp, d, phase, link_target):
    """`make <test>' must refuse, checked by RUNNING it: the hole is the absence
       of a rule, which no grep of the Makefile can show."""
    t = test_of(d)
    for label, pre_touch in [("./%s absent" % t, False), ("./%s already present" % t, True)]:
        w = fresh(tmp, d, "%smake-%d" % (phase.lower(), int(pre_touch)))
        b = os.path.join(w, t)
        if pre_touch:
            # A plain rule whose target exists is "up to date", so the refusal
            # has to survive the file already existing.
            open(b, "w").write("stale")
        r = run(["make", t], cwd=w)
        blob = r.stdout + r.stderr
        tick(phase)
        if r.returncode == 0:
            fail(phase, "`make %s' (%s) EXITED 0 -- it must refuse: with no rule "
                        "of its own ./%s is relinked by make's built-in rule, or "
                        "reported up to date when it already exists "
                        "(make said: %r)" % (t, label, t, blob.strip()[-300:]))
            continue
        tick(phase)
        if "is not a build target" not in blob:
            fail(phase, "`make %s' (%s) failed without refusing by name -- if this is "
                        "make's built-in `%%: %%.o' rule firing, the refusal never ran "
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


def phase2(tmp, d):
    print("[hip-compile] compile: hipcc --offload-arch=%s -c the emitted .hip" % HIP_ARCH)
    if not have("hipcc"):
        fail("hip-compile", "hipcc not on PATH -- this gate cannot verify the AMD lane here; "
                   "run it where ROCm exists before trusting the .hip")
        return
    w = fresh(tmp, d, "p2")
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
    # comp.sh ends in an unconditional `HetLitmus: compile OK' echo, so only its
    # `set -e' keeps a failed compile from reporting success.
    c = fresh(tmp, d, "p2-uncompilable")
    inj = "this is not c++;"
    with open(os.path.join(c, test_of(c) + ".hip"), "a") as f:
        f.write("\n%s\n" % inj)
    r = run(["sh", "comp.sh", "hip"], cwd=c)
    print("      counterfactual: comp.sh hip on an uncompilable .hip -> rc=%d "
          "(want nonzero)" % r.returncode)
    tick("hip-compile")
    if r.returncode == 0 or "HetLitmus: compile OK" in r.stdout:
        fail("hip-compile", "comp.sh hip reported success (exit %d) on a .hip that does not "
             "compile -- the `compile OK' echo is unguarded, so every hip compile "
             "in this suite would be vacuous:\n%s%s"
             % (r.returncode, r.stdout[-1000:], r.stderr[-1000:]))
    # A nonzero rc is also what a harness broken for its own reasons earns, so
    # hipcc has to echo the injected line back.
    tick("hip-compile")
    if inj not in r.stdout + r.stderr:
        fail("hip-compile", "comp.sh hip failed (exit %d) without hipcc naming the "
             "injected %r, so the failure is not attributable to the injection:\n%s%s"
             % (r.returncode, inj, r.stdout[-1000:], r.stderr[-1000:]))
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


def e_machine_of(path):
    """The ELF e_machine an object reports, or None if it is not an ELF."""
    with open(path, "rb") as f:
        head = f.read(20)
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    return head[18] | (head[19] << 8)


# What comp.sh reaches for besides clang.  /usr/bin carries clang too, so the
# counterfactual PATH is built up from these rather than filtered down.
NO_CLANG_TOOLS = ["sh", "uname", "gcc", "as", "ld", "nvcc", "hipcc"]


def path_without_clang(tmp):
    """A PATH holding every tool comp.sh needs EXCEPT clang, as a directory of
       symlinks.  Returns it, or None with a reason if it lost a needed tool."""
    w = os.path.join(tmp, "no-clang-bin")
    shutil.rmtree(w, ignore_errors=True)
    os.makedirs(w)
    for t in NO_CLANG_TOOLS:
        real = shutil.which(t)
        if real:
            os.symlink(real, os.path.join(w, t))
    if shutil.which("clang", path=w) is not None:
        return None, "the counterfactual PATH still resolves clang"
    for t in ["sh", "gcc"]:
        if shutil.which(t, path=w) is None:
            return None, "the counterfactual PATH lost %s, so a failure under it " \
                         "would not be attributable to clang" % t
    return w, None


def phase4(tmp, d_aa_cuda, d_x86_cuda):
    """The CPU file compiles for its own ISA ONLY: on a host of the other ISA
    every make path stops at its #error and no link arm writes ./<test>, while
    comp.sh cross-assembles it into an object of the rendered ISA."""
    m = os.uname().machine
    print("[foreign-host] the foreign render stops at its #error and "
          "cross-assembles instead, on %s" % m)
    renders = {"x86_64": (d_aa_cuda, d_x86_cuda),
               "aarch64": (d_x86_cuda, d_aa_cuda)}.get(m)
    if renders is None:
        fail("foreign-host", "no render here is foreign to a %s host: this gate "
                             "emits an AArch64 and an x86_64 one, so the #error "
                             "cannot be reached.  Run it on x86_64 or aarch64" % m)
        return
    if not have("nvcc"):
        fail("foreign-host", "nvcc not on PATH -- both make arms and comp.sh build "
                             "the CUDA object on the way to the CPU file, so the "
                             "#error cannot be observed here")
        return
    d_foreign, d_native = renders
    t = test_of(d_foreign)
    tn = test_of(d_native)
    # The host word decides which render is foreign, which ISA label its file
    # must name and which triple assembles it; each is then asserted, not assumed.
    label = {"aarch64": "AArch64", "x86_64": "X86_64"}
    foreign_uname = {"x86_64": "aarch64", "aarch64": "x86_64"}[m]
    isa, native_isa = label[foreign_uname], label[m]
    triple = foreign_uname + "-linux-gnu"
    want_machine = E_MACHINE[foreign_uname]

    # --- (a),(b) every make path stops at the #error ------------------------
    for arm in ["cuda-bin", "cuda"]:
        w = fresh(tmp, d_foreign, "p4-make-" + arm)
        r = run(["make", arm], cwd=w)
        blob = r.stdout + r.stderr
        tick("foreign-host")
        if r.returncode == 0:
            fail("foreign-host", "`make %s' on the %s render SUCCEEDED on this %s "
                 "host -- the CPU object it built is not %s asm"
                 % (arm, isa, m, isa))
            continue
        tick("foreign-host")
        if "#error" not in blob:
            fail("foreign-host", "`make %s' on the %s render failed without reaching "
                 "the CPU file's #error, so the failure is incidental:\n%s"
                 % (arm, isa, blob[-800:]))
        tick("foreign-host")
        if isa not in blob:
            fail("foreign-host", "`make %s' on the %s render failed without naming "
                 "the ISA the file was rendered for:\n%s" % (arm, isa, blob[-800:]))
        tick("foreign-host")
        if os.path.isfile(os.path.join(w, t + "_cpu_host.o")):
            fail("foreign-host", "`make %s' on the %s render left a %s_cpu_host.o -- "
                 "the host gcc compiled the CPU file after all" % (arm, isa, t))
        tick("foreign-host")
        if os.path.isfile(os.path.join(w, t)):
            fail("foreign-host", "`make %s' on the %s render failed but produced "
                 "./%s anyway" % (arm, isa, t))

    # --- (c) comp.sh cross-assembles the real asm instead -------------------
    w = fresh(tmp, d_foreign, "p4-comp")
    r = run(["sh", "comp.sh", "cuda"], cwd=w)
    tick("foreign-host")
    if r.returncode != 0:
        fail("foreign-host", "comp.sh cuda on the %s render failed (exit %d) -- a "
             "foreign host must still be able to compile it:\n%s%s"
             % (isa, r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    else:
        tick("foreign-host")
        if "+ clang --target=%s" % triple not in r.stdout:
            fail("foreign-host", "comp.sh cuda on the %s render did not report a "
                 "clang --target=%s step:\n%s" % (isa, triple, r.stdout))
        obj = os.path.join(w, t + "_cpu.o")
        tick("foreign-host")
        if not os.path.isfile(obj):
            fail("foreign-host", "comp.sh cuda on the %s render left no %s_cpu.o"
                 % (isa, t))
        else:
            tick("foreign-host")
            got = e_machine_of(obj)
            if got != want_machine:
                fail("foreign-host", "%s_cpu.o reports e_machine %r, expected %d -- "
                     "the cross-assembly did not produce %s code"
                     % (t, got, want_machine, isa))
        tick("foreign-host")
        if os.path.isfile(os.path.join(w, t + "_cpu_host.o")):
            fail("foreign-host", "comp.sh cuda on the %s render also wrote a "
                 "%s_cpu_host.o, which a link arm here would happily take"
                 % (isa, t))

    # --- (d) and the link arm therefore produces nothing --------------------
    w = fresh(tmp, d_foreign, "p4-link")
    r = run(["sh", "comp.sh", "cuda-link"], cwd=w)
    tick("foreign-host")
    if r.returncode == 0:
        fail("foreign-host", "comp.sh cuda-link on the %s render exited 0 on this %s "
             "host -- it linked something that is not %s asm" % (isa, m, isa))
    tick("foreign-host")
    if os.path.isfile(os.path.join(w, t)):
        fail("foreign-host", "comp.sh cuda-link on the %s render left ./%s behind"
             % (isa, t))

    # --- (e) counterfactual: no clang is an error exit, never a skip --------
    nc, why = path_without_clang(tmp)
    if nc is None:
        tick("foreign-host")
        fail("foreign-host", why)
    else:
        w = fresh(tmp, d_foreign, "p4-noclang")
        e = dict(os.environ)
        e["PATH"] = nc
        r = subprocess.run(["sh", "comp.sh", "cuda"], capture_output=True, text=True,
                           cwd=w, env=e)
        blob = r.stdout + r.stderr
        tick("foreign-host")
        if r.returncode == 0:
            fail("foreign-host", "comp.sh cuda on the %s render exited 0 with no "
                 "clang on PATH -- the cross-assembly was skipped instead of "
                 "refused:\n%s" % (isa, blob[-800:]))
        tick("foreign-host")
        if "clang" not in blob:
            fail("foreign-host", "comp.sh cuda failed without naming clang, so the "
                 "user is not told what is missing:\n%s" % blob[-800:])
        tick("foreign-host")
        if not os.path.isfile(os.path.join(w, "outs.o")):
            fail("foreign-host", "comp.sh cuda got no further than outs.c under the "
                 "counterfactual PATH, so its failure is not clang's:\n%s"
                 % blob[-800:])
        tick("foreign-host")
        if os.path.isfile(os.path.join(w, t + "_cpu.o")):
            fail("foreign-host", "comp.sh cuda wrote %s_cpu.o with no clang on PATH"
                 % t)

    # --- (f) the OTHER ISA's render carries the same error ------------------
    w = fresh(tmp, d_native, "p4-native")
    r = run(["clang", "--target=" + triple, "-c", tn + "_cpu.c", "-o", "cross.o"],
            cwd=w)
    blob = r.stdout + r.stderr
    tick("foreign-host")
    if r.returncode == 0:
        fail("foreign-host", "the %s render's %s_cpu.c compiled for %s -- only one "
             "of the two ISAs stops a compiler aimed at the other"
             % (native_isa, tn, triple))
    tick("foreign-host")
    if "#error" not in blob or native_isa not in blob:
        fail("foreign-host", "the %s render's %s_cpu.c failed for %s without its "
             "#error naming %s:\n%s"
             % (native_isa, tn, triple, native_isa, blob[-800:]))

    print("      %d assertions" % counts.get("foreign-host", 0))
    if not counts.get("foreign-host"):
        fail("foreign-host", "phase made no assertions")


def plant(src_bin, dst_bin):
    """Put one vendor's linked binary where the other vendor's target writes,
       NEWER than everything around it: the state the stale-link trap needs."""
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
    # A fixed sm_ target: this phase links and never launches.
    cuda = ["make", "cuda-bin", "CUDA_ARCH=sm_86"]
    hip = ["make", "hip-bin"]
    # FOUR builds, and the order is the whole point: rounds 1-2 create each
    # vendor's binary, rounds 3-4 plant the other's and are the discriminating ones.
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
    # (c) device preconditions, both fatal
    #     [HipRuntimeApi "hipMallocManaged"].
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
    # (d) MI300A vs MI300X: both report gfx942 and only `integrated' separates
    #     them, so a discrete-part histogram must not read as an MI300A result.
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
            or "not an integrated-APU result" not in r.stderr:
        fail("hip-allocator",
             "integrated=0 produced no warning that this is not an integrated-APU "
             "result:\n%s" % r.stderr[-600:])

    print("      %d assertions" % counts.get("hip-allocator", 0))
    if not counts.get("hip-allocator"):
        fail("hip-allocator", "phase made no assertions")


def phase6b(tmp, d):
    """HET_PLACE is CUDA-only and is REFUSED at compile time here, while
    HET_PLACE=0 still builds."""
    print("[place-refusal] HET_PLACE: the CUDA-only lever the AMD render must refuse")
    if not have("hipcc"):
        fail("place-refusal", "hipcc not on PATH -- the compile-time refusal cannot "
                              "be verified here")
        return
    w = fresh(tmp, d, "p6place")
    r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=1"], cwd=w)
    tick("place-refusal")
    if r.returncode == 0:
        fail("place-refusal", "`make hip HIPCC=\"hipcc -DHET_PLACE=1\"' SUCCEEDED -- the "
                    "AMD render accepted a placement lever it does not implement")
    tick("place-refusal")
    if "HET_PLACE is a CUDA-only lever" not in (r.stdout + r.stderr):
        fail("place-refusal", "a -DHET_PLACE=1 AMD build failed without saying why:\n%s"
             % (r.stdout + r.stderr)[-800:])
    # ...and HET_PLACE=0, the default and the only honourable value, still builds.
    w = fresh(tmp, d, "p6place0")
    r = run(["make", "hip", "HIPCC=hipcc -DHET_PLACE=0"], cwd=w)
    tick("place-refusal")
    if r.returncode != 0:
        fail("place-refusal", "-DHET_PLACE=0 (the DEFAULT) no longer compiles -- the "
                    "refusal is over-broad and blocks every ordinary AMD build:\n%s"
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
        ("cuda-bin rule", r"^cuda-bin: %s\.o outs\.o %s_cpu_host\.o$" % (re.escape(t), re.escape(t)), mk),
        ("cuda-bin links with NVCC", r"\$\(NVCC\) -arch=\$\(CUDA_ARCH\) \$\^ -o %s " % re.escape(t), mk),
        ("cuda-bin .PHONY", r"^\.PHONY:.*\bcuda-bin\b", mk),
    ]:
        tick("cuda-nonregression")
        if not re.search(pat, blob, re.M):
            fail("cuda-nonregression", "%s missing or altered in the emitted build "
                                       "scripts (/%s/)" % (what, pat))
    # The CUDA render is where make's built-in `%: %.o' rule is REACHABLE, its
    # GPU object being <test>.o, so the refusal is checked on this render too.
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



def main():
    # No options: an unrecognised flag must error out rather than be ignored.
    argparse.ArgumentParser().parse_args()

    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("hipbuildcheck: %s not built (run 'make all')" % LITMUS7)

    tmp = tempfile.mkdtemp(prefix="hipbuildcheck.")
    try:
        # The x86_64 rendering is generated on demand, not committed
        # (hetlitmus/docs/corpus-grid.md, "The CPU ISA of a rendering").
        corpus = os.path.join(tmp, "x86")
        r = run(["bash", GEN_HET] + GEN_X86_ARGS + [corpus])
        if r.returncode != 0:
            raise SystemExit("hipbuildcheck: generate.sh --cpu-arch x86_64 failed:\n" + r.stderr)
        src = os.path.join(corpus, X86_TEST + ".litmus")
        if not os.path.isfile(src):
            raise SystemExit("hipbuildcheck: generate.sh --cpu-arch x86_64 emitted no %s" % X86_TEST)
        # The same x86 test, rendered once per vendor: one directory carries
        # one vendor's arms (litmus/hetDialect.ml).
        d_x86 = emit(tmp, src, os.path.join(tmp, "out-x86-hip"), "x86 render", "hip")
        d_x86_cuda = emit(tmp, src, os.path.join(tmp, "out-x86-cuda"),
                          "x86 render", "cuda")
        # The AArch64 render, emitted CUDA so foreign-host has one render per
        # CPU ISA in the same dialect.
        d_aa_cuda = emit(tmp, os.path.join(HET_DIR, AARCH64_TEST + ".litmus"),
                         os.path.join(tmp, "out-aa"), "AArch64 render", "cuda")

        print("===== HIPBUILDCHECK: can an AMD harness be built and run? =====")
        print("  host %s, hipcc=%s nvcc=%s"
              % (os.uname().machine, have("hipcc"), have("nvcc")))
        phase1(tmp, d_x86)
        phase2(tmp, d_x86)
        phase3(tmp, d_x86)
        phase4(tmp, d_aa_cuda, d_x86_cuda)
        phase5(tmp, d_x86_cuda, d_x86)
        phase6(tmp, d_x86)
        phase6b(tmp, d_x86)
        phase7(tmp, d_x86_cuda)
        print("=" * 70)
        if fails:
            print("HIPBUILDCHECK FAILED: %d assertion(s)" % len(fails))
            for ph, m in fails:
                print("  [%s] %s" % (ph, m))
            return 1
        print("HIPBUILDCHECK: PASS (%d assertions over %d phases)"
              % (sum(counts.values()), len(counts)))
        print("  DEFERRED to the MI300X bring-up: no AMD GPU here, so no linked "
              "harness ran.  hip-allocator drove the resolver under a stub "
              "hipDeviceGetAttribute; hipMallocManaged coherence is unverified.")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
