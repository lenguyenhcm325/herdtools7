#!/usr/bin/env python3
"""
hipbuildcheck.py -- can an AMD harness be built, linked and refused correctly?

Phases: build-arms (`make <test>' refuses by name, hip-bin is phony),
hip-compile (comp.sh reports a failure on a .hip that does not compile),
device-image (comp.sh hip-link compiles with hipcc and leaves gfx942 code in
the ELF), foreign-host (a _cpu.c compiles for its own CPU ISA only: the host
compiler stops at the foreign render's #error, clang aimed at that ISA
assembles it, and stops at the native render's), hip-allocator (the shared-mem
resolver executed under a stub hipDeviceGetAttribute).  A miss is a harness
that builds into something other than the test, or accepts what it has to
refuse.  Needs hipcc, clang and gcc, no device.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")

# The x86_64 render is the one an x86_64 host can LINK, and its GPU column
# annotates f[sc,sys], so every phase that compiles builds a fence render.
X86_TEST = "MP-cg-sys-plain.fsc-x86_64"
AARCH64_TEST = "MP-cg-sys-ra.acq"       # the other CPU ISA's _cpu.c

# Per `uname -m' word: the ISA word its _cpu.c names, the clang triple that
# assembles it, and the ELF e_machine (bytes 18-19) its object must report.
ISA_WORD = {"aarch64": "AArch64", "x86_64": "X86_64"}
TRIPLE = {"aarch64": "aarch64-linux-gnu", "x86_64": "x86_64-linux-gnu"}
E_MACHINE = {"aarch64": 183, "x86_64": 62}

# MI300A / MI300X.  Both parts report gfx942; hipDeviceAttributeIntegrated is
# what separates them, and hip-allocator checks the harness reads it.
HIP_ARCH = "gfx942"
# The offload triple hipcc stamps into the executable's .hip_fatbin: a link
# that produced a host-only binary exits 0 and carries no device code.
OFFLOAD_TRIPLE = "amdgcn-amd-amdhsa--" + HIP_ARCH

PHASES = ["build-arms", "hip-compile", "device-image", "foreign-host",
          "hip-allocator"]
fails = []
counts = dict.fromkeys(PHASES, 0)


def check(phase, ok, msg):
    """One assertion, counted whether or not it holds."""
    counts[phase] += 1
    if not ok:
        fails.append((phase, msg))
        print("  FAIL [%s] %s" % (phase, msg))
    return ok


def run(cmd, cwd=None):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)


def have(tool):
    return shutil.which(tool) is not None


def emit(tmp, src, sub):
    """litmus7 -gpu-target hip into <tmp>/<sub>; returns the harness dir."""
    outroot = os.path.join(tmp, sub)
    os.makedirs(outroot, exist_ok=True)
    r = run([LITMUS7, "-gpu-target", "hip", "-set-libdir", LIBDIR, "-o", outroot, src])
    d = os.path.join(outroot, os.path.basename(src)[:-len(".litmus")])
    if not os.path.isdir(d):
        raise SystemExit("hipbuildcheck: litmus7 emitted no hip harness for %s\n%s%s"
                         % (src, r.stdout, r.stderr))
    return d


def fresh(tmp, d, tag):
    """A pristine copy of harness dir [d] keeping its basename, which names
    the test and every object."""
    w = os.path.join(tmp, "w-" + tag, os.path.basename(d))
    shutil.rmtree(os.path.dirname(w), ignore_errors=True)
    os.makedirs(os.path.dirname(w))
    shutil.copytree(d, w)
    return w


def has_gfx(binpath):
    """Does this ELF carry a real gfx942 device image?  Read the bytes, do not
    trust the linker's exit status."""
    if not os.path.isfile(binpath):
        return False
    with open(binpath, "rb") as f:
        return OFFLOAD_TRIPLE.encode() in f.read()


def e_machine_of(path):
    """The ELF e_machine an object reports, or None if it is not an ELF."""
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        head = f.read(20)
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    return head[18] | (head[19] << 8)


# ------------------------------------------------------------------ phases

def build_arms(tmp, d):
    ph = "build-arms"
    print("[%s] `make <test>' refuses on the HIP render; hip-bin is phony" % ph)
    t = os.path.basename(d)
    # Run, not grep: the hole is the absence of a rule.  The refusal has to
    # survive ./<test> already existing, when a plain rule is "up to date".
    for present in (False, True):
        w = fresh(tmp, d, "make-%d" % present)
        if present:
            open(os.path.join(w, t), "w").write("stale")
        r = run(["make", t], cwd=w)
        blob = r.stdout + r.stderr
        who = "`make %s' (./%s %s)" % (t, t, "present" if present else "absent")
        if not check(ph, r.returncode != 0,
                     "%s EXITED 0 -- it must refuse (make said: %r)"
                     % (who, blob.strip()[-300:])):
            continue
        check(ph, "is not a build target" in blob,
              "%s failed without refusing by name:\n%s" % (who, blob[-800:]))
        check(ph, "hip-bin" in blob,
              "%s refused without naming hip-bin to use instead:\n%s"
              % (who, blob[-800:]))
        check(ph, "<builtin>" not in blob,
              "%s reached make's built-in rule:\n%s" % (who, blob[-800:]))
        if not present:
            check(ph, not os.path.exists(os.path.join(w, t)),
                  "%s refused but produced ./%s anyway" % (who, t))
    mk = open(os.path.join(d, "Makefile")).read()
    check(ph, re.search(r"^\.PHONY:.*\bhip-bin\b", mk, re.M),
          "hip-bin is not .PHONY in the emitted Makefile, so a file of that "
          "name would report the link target up to date")


def hip_compile(tmp, d):
    ph = "hip-compile"
    print("[%s] comp.sh reports a failure on a .hip that does not compile" % ph)
    if not check(ph, have("hipcc"), "hipcc not on PATH -- the AMD lane cannot be "
                 "verified here; run it where ROCm exists before trusting the .hip"):
        return
    # comp.sh ends in an unconditional `compile OK' echo, so only its `set -e'
    # keeps a failed compile from reporting success.
    w = fresh(tmp, d, "uncompilable")
    inj = "this is not c++;"
    with open(os.path.join(w, os.path.basename(w) + ".hip"), "a") as f:
        f.write("\n%s\n" % inj)
    r = run(["sh", "comp.sh", "hip"], cwd=w)
    blob = r.stdout + r.stderr
    check(ph, r.returncode != 0 and "HetLitmus: compile OK" not in r.stdout,
          "comp.sh hip reported success (exit %d) on a .hip that does not "
          "compile:\n%s" % (r.returncode, blob[-1000:]))
    # A harness broken for its own reasons earns a nonzero rc too, so hipcc
    # has to echo the injected line back.
    check(ph, inj in blob, "comp.sh hip failed (exit %d) without hipcc naming "
          "the injected %r:\n%s" % (r.returncode, inj, blob[-1000:]))


def device_image(tmp, d):
    ph = "device-image"
    print("[%s] comp.sh hip-link compiles with hipcc and produces a %s ELF"
          % (ph, HIP_ARCH))
    if not check(ph, have("hipcc"), "hipcc not on PATH -- the HIP link arm "
                 "cannot be verified here"):
        return
    t = os.path.basename(d)
    w = fresh(tmp, d, "link")
    r = run(["sh", "comp.sh", "hip-link"], cwd=w)
    if not check(ph, r.returncode == 0, "comp.sh hip-link failed (exit %d):\n%s%s"
                 % (r.returncode, r.stdout[-2000:], r.stderr[-2000:])):
        return
    check(ph, "+ hipcc --offload-arch=%s" % HIP_ARCH in r.stdout,
          "comp.sh hip-link did not report the hipcc --offload-arch=%s step:\n%s"
          % (HIP_ARCH, r.stdout))
    b = os.path.join(w, t)
    if check(ph, os.path.isfile(b) and os.access(b, os.X_OK),
             "comp.sh hip-link exited 0 but left no executable ./%s" % t):
        check(ph, has_gfx(b), "./%s carries NO %s device image -- a host-only "
              "binary that would run and test nothing" % (t, OFFLOAD_TRIPLE))


def foreign_host(tmp, dirs):
    """[dirs]: uname word -> the harness dir whose _cpu.c is that ISA's."""
    ph = "foreign-host"
    m = os.uname().machine
    print("[%s] a _cpu.c compiles for its own CPU ISA only, on %s" % (ph, m))
    if not check(ph, m in dirs, "no render here is foreign to a %s host: this "
                 "gate emits an AArch64 and an x86_64 one" % m):
        return
    if not check(ph, have("clang"), "clang not on PATH -- the cross-assembly "
                 "cannot be observed here"):
        return
    foreign = next(u for u in dirs if u != m)
    cross = ["clang", "--target=" + TRIPLE[foreign], "-std=gnu11", "-c"]
    df, dn = fresh(tmp, dirs[foreign], "foreign"), fresh(tmp, dirs[m], "native")
    fcpu = os.path.basename(df) + "_cpu.c"
    ncpu = os.path.basename(dn) + "_cpu.c"

    # (a) the host compiler stops at the foreign render's #error
    r = run(["gcc", "-c", fcpu, "-o", "host.o"], cwd=df)
    blob = r.stdout + r.stderr
    if check(ph, r.returncode != 0, "gcc compiled %s on this %s host -- the CPU "
             "object it built is not %s asm" % (fcpu, m, ISA_WORD[foreign])):
        check(ph, "#error" in blob and ISA_WORD[foreign] in blob,
              "gcc failed on %s without its #error naming %s:\n%s"
              % (fcpu, ISA_WORD[foreign], blob[-800:]))
    check(ph, not os.path.exists(os.path.join(df, "host.o")),
          "gcc left a host.o for %s after all" % fcpu)
    # (b) clang aimed at the foreign ISA assembles it into an object of that ISA
    r = run(cross + [fcpu, "-o", "cross.o"], cwd=df)
    if check(ph, r.returncode == 0, "clang --target=%s failed on %s (exit %d):\n%s%s"
             % (TRIPLE[foreign], fcpu, r.returncode, r.stdout[-1500:],
                r.stderr[-1500:])):
        got = e_machine_of(os.path.join(df, "cross.o"))
        check(ph, got == E_MACHINE[foreign], "cross.o reports e_machine %r, "
              "expected %d -- the cross-assembly did not produce %s code"
              % (got, E_MACHINE[foreign], ISA_WORD[foreign]))
    # (c) the native render stops the same compiler aimed at the other ISA
    r = run(cross + [ncpu, "-o", "cross.o"], cwd=dn)
    blob = r.stdout + r.stderr
    if check(ph, r.returncode != 0, "%s compiled for %s -- only one of the two "
             "ISAs stops a compiler aimed at the other" % (ncpu, TRIPLE[foreign])):
        check(ph, "#error" in blob and ISA_WORD[m] in blob,
              "%s failed for %s without its #error naming %s:\n%s"
              % (ncpu, TRIPLE[foreign], ISA_WORD[m], blob[-800:]))


# --- hip-allocator: the resolver, executed under a stub HIP ----------------

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
    t = os.path.basename(d)
    src = open(os.path.join(d, t + ".hip")).read()
    b = RES_BEGIN.search(src)
    if not b:
        return None, "no `#define HET_HIP_ALLOC_MANAGED' in %s.hip -- the HIP render " \
                     "carries no shared-memory mode resolver at all" % t
    e = RES_END.search(src, b.end())
    if not e:
        return None, "no `return _mode;' after the resolver in %s.hip" % t
    body = src[b.start():e.end()] + "\n}\n"
    w = os.path.join(tmp, "shim-" + t)
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


def hip_allocator(tmp, d):
    ph = "hip-allocator"
    print("[%s] fail-closed: HET_ALLOC modes + device preconditions (no AMD GPU)" % ph)
    path, why = build_resolver(tmp, d)
    if not check(ph, path is not None, why):
        return
    managed = ("RESOLVED mode=1", "shared-mem mode=managed")
    # (HET_ALLOC, attribute overrides, exit code, stdout needles, stderr needles)
    rows = [
        (None, {}, 0, managed + ("amd_part_class=APU(integrated)",), ()),
        ("", {}, 0, managed, ()),
        ("auto", {}, 0, managed, ()),
        ("managed", {}, 0, managed, ()),
        # An unimplemented mode that silently allocated managed memory would
        # run a DIFFERENT experiment under the requested name.
        ("malloc", {}, 2, (), ("FATAL", "not a shared-memory mode")),
        # Both device preconditions are fatal [HipRuntimeApi "hipMallocManaged"].
        (None, dict(managed=0), 2, (), ("hipDeviceAttributeManagedMemory=0",)),
        (None, dict(cma=0), 2, (), ("hipDeviceAttributeConcurrentManagedAccess=0",)),
        # The discrete part runs, stamped and warned: its histogram must not
        # read as an MI300A result.
        (None, dict(integrated=0), 0, ("amd_part_class=DISCRETE(not-integrated)",),
         ("WARNING", "not an integrated-APU result")),
    ]
    for mode, attrs, rc, outs, errs in rows:
        r = drv(path, mode, **attrs)
        who = "HET_ALLOC=%s%s" % ("<unset>" if mode is None else repr(mode),
                                  "".join(" %s=%d" % kv for kv in attrs.items()))
        if not check(ph, r.returncode == rc, "%s exited %d, expected %d:\n%s"
                     % (who, r.returncode, rc, (r.stdout + r.stderr)[-600:])):
            continue
        for needle in outs:
            check(ph, needle in r.stdout, "%s printed no %r:\n%s"
                  % (who, needle, r.stdout))
        for needle in errs:
            check(ph, needle in r.stderr, "%s said nothing of %r:\n%s"
                  % (who, needle, r.stderr[-600:]))


def main():
    argparse.ArgumentParser().parse_args()   # an unrecognised flag errors out
    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("hipbuildcheck: %s not built (run 'make all')" % LITMUS7)
    tmp = tempfile.mkdtemp(prefix="hipbuildcheck.")
    try:
        src = os.path.join(census.X86_DIR, X86_TEST + ".litmus")
        if not os.path.isfile(src):
            raise SystemExit("hipbuildcheck: no %s (run 'make hetlitmus-corpus-gen')"
                             % src)
        d_x86 = emit(tmp, src, "out-x86")
        d_aa = emit(tmp, os.path.join(census.HET_DIR, AARCH64_TEST + ".litmus"),
                    "out-aa")
        print("===== HIPBUILDCHECK: can an AMD harness be built and run? =====")
        print("  host %s, hipcc=%s clang=%s"
              % (os.uname().machine, have("hipcc"), have("clang")))
        build_arms(tmp, d_x86)
        hip_compile(tmp, d_x86)
        device_image(tmp, d_x86)
        foreign_host(tmp, {"x86_64": d_x86, "aarch64": d_aa})
        hip_allocator(tmp, d_x86)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("  assertions: " + ", ".join("%s %d" % (ph, counts[ph]) for ph in PHASES))
    print("=" * 70)
    if fails:
        print("HIPBUILDCHECK FAILED: %d assertion(s)" % len(fails))
        for ph, m in fails:
            print("  [%s] %s" % (ph, m))
        return 1
    print("HIPBUILDCHECK: PASS (%d assertions over %d phases)"
          % (sum(counts.values()), len(PHASES)))
    print("  DEFERRED to the MI300X bring-up: no AMD GPU here, so no linked "
          "harness ran.  hip-allocator drove the resolver under a stub "
          "hipDeviceGetAttribute; hipMallocManaged coherence is unverified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
