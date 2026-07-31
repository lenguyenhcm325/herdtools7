#!/usr/bin/env python3
"""ordercheck.py -- Q10 -- the ORDERING RULE behind the two-sided het oracle,
machine-checked against BOTH constituent solvers.

WHY THIS GATE EXISTS.  The two-sided (`-2s') het tests are the only rows that
can be `Disallowed', i.e. the only rows that can refute the compound model.  Q10
widens that family from one fence pairing (DMB.SY x fence.sc.sys) to the full
3 x 3 grid  CPU {DMB.SY, DMB.ST, DMB.LD}  x  GPU {f[sc,sys], f[release,sys],
f[acquire,sys]}.  Whether a given pairing forbids a given shape is NOT a matter
of "both sides have a fence": DMB.LD on a store;store producer orders nothing,
and a PTX release fence on a load;load consumer orders nothing.  Writing 8 x 9
verdicts by hand is exactly how an oracle acquires a silent error, and an oracle
error is a FALSE REFUTATION of the compound memory model.

So build-nvidia-oracle.sh implements a COMPOSITIONAL rule, and this gate proves
the rule is the same function that herd7 computes -- twice, from two independent
models, over every cell:

  PHASE 1  ARM.  All six 2-proc shapes x DMB(P0) x DMB(P1) = 54 CPU-only AArch64
           tests, generated with diyone7 and decided by herd7's NATIVE AArch64
           model.  The rule's ARM half must reproduce all 54.
  PHASE 2  PTX.  The same 54 cells as LISA/Bell sys-scope tests with
           f[{sc,release,acquire},sys], decided by herd7 + hetlitmus/bells/
           ptx.bell + hetlitmus/cats/nvidia-ptx.cat (the repo's Lustig'19
           encoding).  The rule's PTX half must reproduce all 54.
  PHASE 3  ORACLE.  Every two-sided fence-pair row of tests/het/
           expected-nvidia.csv must equal the rule's het verdict -- including
           the pre-existing `-fence-2s' rows, which are the (DMB.SY, f[sc,sys])
           cell of the same grid.  This is what stops the bash oracle and this
           rule drifting apart.

THE RULE (and where each piece comes from).

  ord(p)  = the set of program-order pairs {WW,RR,WR,RW} the primitive orders
            WITHIN its own thread.
              DMB.SY {WW,RR,WR,RW}   DMB.ST {WW}       DMB.LD {RR,RW}
              f[sc]  {WW,RR,WR,RW}   f[rel] {WW,RW}    f[acq] {RR,RW}
            The ARM row is Phase 1's own output (it is exactly the isolation
            column "this DMB, DMB.SY on the other proc").  The PTX row is CMCM
            PLDI'23 sect 5 verbatim: "a request that is marked with sem >= rel
            enforces R + pred -> W and W -> W.  A request with sem >= acq
            enforces R -> R and R -> W, and an sc fence additionally enforces
            W -> R."
  role(p) = which half of a morally-strong synchronisation the primitive can
            supply: DMB.SY/f[sc] {rel,acq,sc};  DMB.ST/f[rel] {rel};
            DMB.LD/f[acq] {acq}.
  sync(shape, roles) = the EXTRA requirement Lustig'19's axiomatic PTX imposes
            on top of per-side ordering (Fig 4: sw = ms & (pattern_rel ; obs ;
            pattern_acq), plus sc): if the cycle carries a cross-device rf edge
            the rf SOURCE proc must supply `rel' and the rf TARGET proc `acq';
            if it carries no rf at all (SB, R, 2+2W) both procs must supply
            `sc' (Lustig Fig 6: preventing SB needs a fence.sc on EACH thread).

  ARM verdict  = ord(D0) >= pair0  and  ord(D1) >= pair1        (no sync clause:
                 ARM barriers are cumulative and need no partner -- Phase 1 is
                 the proof, e.g. LB is Forbidden with DMB.LD on BOTH procs)
  PTX verdict  = ord(F0) >= pair0  and  ord(F1) >= pair1  and  sync
  HET verdict  = Disallowed  if  ord(cpu) >= cpuPair and ord(gpu) >= gpuPair
                              and sync
                 NO-ORACLE   if  ord(cpu) >= cpuPair and ord(gpu) >= gpuPair
                              but NOT sync
                 Allowed     otherwise

  The het split is deliberate and is the honest reading of two primary sources
  that DISAGREE on those cells.  CMCM's operational model composes by union of
  per-thread stalling ("a compound LOST-POP model is simply a LOST-POP model
  where different threads have different architectures", sect 4.6; "There is no
  need to define synchronization between the two", sect 5) and so forbids
  whenever both sides order their own pair.  Lustig'19's axiomatic PTX has no
  intra-thread fence order at all -- ordering exists only through a completed
  pattern_rel;obs;pattern_acq chain -- and so forbids strictly less.  Where they
  agree the row is a real prediction; where only CMCM forbids, the row is
  NO-ORACLE (characterisation), never a falsification claim.

  The cross-device step -- that a CPU DMB and a sys-scope GPU fence are MORALLY
  STRONG and therefore compose at all -- is the one part no solver here can
  decide.  It is CMCM sect 3.2.3 / 4.4 ("every non-scoped order constraint
  coming from a non-scoped memory model [is treated] as system scoped"),
  Bagchi ISMM'26 sect 3.2/4.2 ("CPU unscoped operations are treated as
  system-scoped when synchronizing with a GPU that employs a scoped model") and
  PTX Table 1 (`.sys' includes "all threads constituting the host program
  itself").  See hetlitmus/docs/het-oracle.md.

Usage:  ordercheck.py [-q]     run the gate
        ordercheck.py --bite   prove the gate FAILS when the rule is corrupted
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HETL = os.path.dirname(HERE)
REPO = os.path.dirname(HETL)
BIN = os.path.join(REPO, "_build", "install", "default", "bin")
LIBDIR = os.path.join(REPO, "herd", "libdir")
BELL = os.path.join(HETL, "bells", "ptx.bell")
CAT = os.path.join(HETL, "cats", "nvidia-ptx.cat")
HETDIR = os.path.join(HETL, "tests", "het")

# --- shape catalogue (must mirror tests/_grid_lib.sh SHAPE_CYCLE) ------------
CYCLE = {
    "MP":   ["PodWW", "Rfe", "PodRR", "Fre"],
    "SB":   ["PodWR", "Fre", "PodWR", "Fre"],
    "LB":   ["PodRW", "Rfe", "PodRW", "Rfe"],
    "2+2W": ["PodWW", "Coe", "PodWW", "Coe"],
    "R":    ["PodWW", "Coe", "PodWR", "Fre"],
    "S":    ["PodWW", "Rfe", "PodRW", "Coe"],
}
SHAPES = ["MP", "SB", "LB", "2+2W", "R", "S"]

# --- the rule ---------------------------------------------------------------
ALL4 = frozenset(("WW", "RR", "WR", "RW"))
ORD = {
    "SY": ALL4,               "ST": frozenset(("WW",)),
    "LD": frozenset(("RR", "RW")),
    "Sc": ALL4,               "Release": frozenset(("WW", "RW")),
    "Acquire": frozenset(("RR", "RW")),
}
ROLE = {
    "SY": frozenset(("rel", "acq", "sc")), "ST": frozenset(("rel",)),
    "LD": frozenset(("acq",)),
    "Sc": frozenset(("rel", "acq", "sc")), "Release": frozenset(("rel",)),
    "Acquire": frozenset(("acq",)),
}
CPU_FENCE = {"sy": "SY", "st": "ST", "ld": "LD"}        # name token -> DMB
GPU_FENCE = {"sc": "Sc", "rel": "Release", "acq": "Acquire"}


def pairs(shape):
    c = CYCLE[shape]
    return c[0][3:], c[2][3:]


def rf_dirs(shape):
    """{(src proc, dst proc)} for each cross-proc rf edge of the cycle."""
    c = CYCLE[shape]
    d = set()
    if c[1] == "Rfe":
        d.add((0, 1))
    if c[3] == "Rfe":
        d.add((1, 0))
    return d


def sync_ok(shape, r0, r1):
    """The Lustig'19 pattern requirement, per proc role set."""
    r = (r0, r1)
    dirs = rf_dirs(shape)
    if not dirs:                       # no rf to observe -> fence.sc on BOTH
        return "sc" in r0 and "sc" in r1
    return any("rel" in r[s] and "acq" in r[d] for (s, d) in dirs)


def arm_verdict(shape, d0, d1):
    p0, p1 = pairs(shape)
    return "Forbidden" if (p0 in ORD[d0] and p1 in ORD[d1]) else "Allowed"


def ptx_verdict(shape, f0, f1):
    p0, p1 = pairs(shape)
    ok = p0 in ORD[f0] and p1 in ORD[f1] and sync_ok(shape, ROLE[f0], ROLE[f1])
    return "Forbidden" if ok else "Allowed"


def het_verdict(shape, cut, cpu_tok, gpu_tok):
    """cut = 'cg' or 'gc' (device of P0, P1).  -> Disallowed/NO-ORACLE/Allowed"""
    p = pairs(shape)
    C, G = CPU_FENCE[cpu_tok], GPU_FENCE[gpu_tok]
    icpu = cut.index("c")
    igpu = cut.index("g")
    if p[icpu] not in ORD[C] or p[igpu] not in ORD[G]:
        return "Allowed"
    role = [None, None]
    role[icpu], role[igpu] = ROLE[C], ROLE[G]
    return "Disallowed" if sync_ok(shape, role[0], role[1]) else "NO-ORACLE"


# --- solvers ----------------------------------------------------------------
def _run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


OBS = re.compile(r"^Observation \S+ (Never|Sometimes|Always)", re.M)


def herd(path, extra):
    r = _run([os.path.join(BIN, "herd7"), "-set-libdir", LIBDIR] + extra + [path])
    m = OBS.search(r.stdout)
    if not m:
        return "ERROR"
    return "Forbidden" if m.group(1) == "Never" else "Allowed"


def gen_arm(tmp, shape, d0, d1):
    c = CYCLE[shape]
    e0 = "DMB.%sd%s" % (d0, c[0][3:])
    e1 = "DMB.%sd%s" % (d1, c[2][3:])
    name = "arm-%s-%s-%s" % (shape, d0, d1)
    r = _run([os.path.join(BIN, "diyone7"), "-arch", "AArch64", "-name", name,
              e0, c[1], e1, c[3]], cwd=tmp)
    return os.path.join(tmp, name + ".litmus") if r.returncode == 0 else None


R_ANN = "RelaxedSysRelaxedSys"


def gen_ptx(tmp, shape, f0, f1):
    c = CYCLE[shape]
    e0 = "Fence%sSysd%s%s" % (f0, c[0][3:], R_ANN)
    e1 = "Fence%sSysd%s%s" % (f1, c[2][3:], R_ANN)
    name = "ptx-%s-%s-%s" % (shape, f0, f1)
    r = _run([os.path.join(BIN, "diyone7"), "-set-libdir", LIBDIR, "-bell", BELL,
              "-arch", "LISA", "-name", name,
              "-scopes", "(sys (gpu (cta P0) (cta P1)))",
              e0, c[1] + R_ANN, e1, c[3] + R_ANN], cwd=tmp)
    return os.path.join(tmp, name + ".litmus") if r.returncode == 0 else None


# --- phases -----------------------------------------------------------------
DMBS = ["SY", "ST", "LD"]
FENCES = ["Sc", "Release", "Acquire"]


def phase_arm(tmp, quiet):
    bad = []
    if not quiet:
        print("===== PHASE 1: ARM -- herd7 native AArch64 vs the rule (54 cells) =====")
    for sh in SHAPES:
        row = []
        for d0 in DMBS:
            for d1 in DMBS:
                p = gen_arm(tmp, sh, d0, d1)
                got = herd(p, []) if p else "GEN-FAIL"
                want = arm_verdict(sh, d0, d1)
                row.append("F" if got == "Forbidden" else
                           ("A" if got == "Allowed" else "?"))
                if got != want:
                    bad.append("ARM %s DMB.%s x DMB.%s: herd7=%s rule=%s"
                               % (sh, d0, d1, got, want))
        if not quiet:
            print("  %-5s %s   (SY|ST|LD x SY|ST|LD)" % (sh, " ".join(row)))
    return bad


def phase_ptx(tmp, quiet):
    bad = []
    if not quiet:
        print("\n===== PHASE 2: PTX -- herd7 + nvidia-ptx.cat vs the rule (54 cells) =====")
    for sh in SHAPES:
        row = []
        for f0 in FENCES:
            for f1 in FENCES:
                p = gen_ptx(tmp, sh, f0, f1)
                got = herd(p, ["-bell", BELL, "-cat", CAT]) if p else "GEN-FAIL"
                want = ptx_verdict(sh, f0, f1)
                row.append("F" if got == "Forbidden" else
                           ("A" if got == "Allowed" else "?"))
                if got != want:
                    bad.append("PTX %s f[%s] x f[%s]: herd7=%s rule=%s"
                               % (sh, f0, f1, got, want))
        if not quiet:
            print("  %-5s %s   (sc|rel|acq x sc|rel|acq)" % (sh, " ".join(row)))
    return bad


# `<shape>-<cut>-sys-<cpu>.<gpu>-2s'  and the (SY,sc) cell `<...>-sys-fence-2s'.
# The shape alternation is EXPLICIT (not `.+?') so a 3/4-proc name can never be
# mis-split into a 2-proc one.
TWOS = re.compile(r"^(?P<shape>MP|SB|LB|R|S)-(?P<cut>cg|gc)-sys-"
                  r"(?:(?P<c>sy|st|ld)\.(?P<g>sc|rel|acq)|(?P<f>fence))-2s$")


def phase_oracle(quiet):
    bad = []
    csv = os.path.join(HETDIR, "expected-nvidia.csv")
    n = 0
    with open(csv) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("Litmus,"):
                continue
            name, verdict = line.split(",")[0], line.split(",")[1]
            m = TWOS.match(name)
            if not m:
                continue    # 2+2W and the 3/4-proc shapes are decided by the
                            # cross-device MCA question, not by this rule
            c = m.group("c") or "sy"
            g = m.group("g") or "sc"
            want = het_verdict(m.group("shape"), m.group("cut"), c, g)
            n += 1
            if verdict != want:
                bad.append("ORACLE %s: csv=%s rule=%s" % (name, verdict, want))
    if not quiet:
        print("\n===== PHASE 3: expected-nvidia.csv two-sided fence-pair rows "
              "vs the rule =====")
        print("  %d rows checked (the 3x3 grid on MP/SB/LB/R/S, including the "
              "pre-existing\n  `-fence-2s' rows as the (DMB.SY, f[sc,sys]) cell)"
              % n)
    if n == 0:
        bad.append("ORACLE: no two-sided fence-pair rows found -- the gate is "
                   "checking nothing")
    return bad


def run(quiet=False):
    for b in ("herd7", "diyone7"):
        if not os.path.exists(os.path.join(BIN, b)):
            print("FATAL: %s/%s not built -- run 'make all'" % (BIN, b))
            return 2
    tmp = tempfile.mkdtemp(prefix="ordercheck.")
    try:
        bad = phase_arm(tmp, quiet) + phase_ptx(tmp, quiet) + phase_oracle(quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print()
        for b in bad:
            print("  *** %s" % b)
        print("\nORDERCHECK FAILED: %d mismatch(es).  The oracle's ordering rule "
              "is not what the model solvers compute." % len(bad))
        return 1
    if not quiet:
        print("\nORDERCHECK OK  (108 solver cells + the oracle's two-sided "
              "fence-pair rows all agree with the rule)")
    return 0


# --- bite -------------------------------------------------------------------
# Each injection names the phase it MUST redden; a bite that only reddens some
# other phase is not evidence for that phase.
INJECTIONS = [
    ("ORD[DMB.ST] gains RR -- a store barrier that orders load;load",
     "D.ORD['ST'] = frozenset(('WW','RR'))", "ARM "),
    ("ORD[f[acquire]] loses RW -- an acquire fence that leaves load;store free",
     "D.ORD['Acquire'] = frozenset(('RR',))", "PTX "),
    ("the sync clause is dropped -- per-side ordering alone would forbid",
     "D.sync_ok = lambda *a: True", "PTX "),
    ("ROLE[f[acquire]] gains rel -- an acquire fence that also releases",
     "D.ROLE['Acquire'] = frozenset(('acq','rel'))", "PTX "),
    ("GPU_FENCE reads the corpus token `sc' as a release fence",
     "D.GPU_FENCE = {'sc':'Release','rel':'Release','acq':'Acquire'}", "ORACLE"),
]


def bite():
    print("===== ORDERCHECK BITE: does the gate fail when the rule is wrong? =====")
    rc = 0
    for desc, inj, where in INJECTIONS:
        drv = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
        drv.write("import sys\nsys.path.insert(0, %r)\nimport ordercheck as D\n"
                  "def snap():\n"
                  "    return (frozenset(D.ORD['ST']), frozenset(D.ORD['Acquire']),"
                  " frozenset(D.ROLE['Acquire']), D.sync_ok, dict(D.GPU_FENCE))\n"
                  "before = snap()\n"
                  "%s\n"
                  "assert before != snap(), 'injection was vacuous'\n"
                  "sys.exit(D.run(quiet=True))\n" % (HERE, inj))
        drv.close()
        r = _run([sys.executable, drv.name])
        os.unlink(drv.name)
        out = r.stdout + r.stderr
        hits = [l for l in out.splitlines() if l.startswith("  *** ")]
        named = [l for l in hits if l.startswith("  *** " + where.strip())]
        ok = r.returncode == 1 and "ORDERCHECK FAILED" in out and named
        print("  [%s] %-66s rc=%d %s (%d/%d)"
              % (where, desc, r.returncode,
                 "BITES" if ok else "*** DID NOT BITE", len(named), len(hits)))
        if named:
            print("        | " + named[0].strip())
        elif out.strip():
            print("        | " + out.strip().splitlines()[-1])
        rc |= 0 if ok else 1
    print()
    if rc:
        print("BITE FAILED: a corrupted rule still passed, or reddened the wrong phase.")
        return 1
    print("BITE OK: every corruption of the rule is caught, in the phase that names it")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true")
    a = ap.parse_args()
    return bite() if a.bite else run(a.quiet)


if __name__ == "__main__":
    sys.exit(main())
