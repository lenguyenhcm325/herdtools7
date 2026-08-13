#!/usr/bin/env python3
"""ordercheck.py -- the per-primitive ordering table behind the control-map
lattice, machine-checked against both constituent solvers.

`ORD' records, for each CPU primitive (STLR/LDAPR, DMB.SY, DMB.ST, DMB.LD) and
each GPU primitive (w[release]/r[acquire], f[sc,sys], f[release,sys],
f[acquire,sys]), which pairs of {WW,RR,WR,RW} it orders inside its own thread.
Those sets are the `ord' half of the (tier, ord) strength lattice defined in
verify/controlmap.py -- restated there per instruction, not imported -- and that
lattice picks each test's positive-control sibling, so a wrong entry on either
side silently certifies a sibling that is not weaker.  Hence the table meets the
model solvers here rather than being asserted:

  PHASE 1  ARM  6 shapes x prim(P0) x prim(P1) = 96 CPU-only AArch64 tests from
                diyone7, decided by herd7's native AArch64 model.
  PHASE 2  PTX  the same 96 cells as sys-scope LISA/Bell tests, decided by
                herd7 + bells/ptx.bell + cats/nvidia-ptx.cat (Lustig'19).
  PHASE 3  AGREE  no solver: the join with controlmap.py, keyed primitive by
                primitive, since agreeing with herd7 does not make two restated
                copies of the same table agree with each other.

Usage:  ordercheck.py [-q]     run the gate
        ordercheck.py --bite   prove the gate fails when the table is corrupted
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

import controlmap

HERE = os.path.dirname(os.path.abspath(__file__))
HETL = os.path.dirname(HERE)
REPO = os.path.dirname(HETL)
BIN = os.path.join(REPO, "_build", "install", "default", "bin")
# HERD_LIBDIR, not LIBDIR: every other gate's LIBDIR is litmus7's (litmus/libdir).
HERD_LIBDIR = os.path.join(REPO, "herd", "libdir")
BELL = os.path.join(HETL, "bells", "ptx.bell")
CAT = os.path.join(HETL, "cats", "nvidia-ptx.cat")

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

# --- the ordering table -----------------------------------------------------
ALL4 = frozenset(("WW", "RR", "WR", "RW"))
RELACQ_ORD = frozenset(("WW", "RR", "RW"))   # rel/acq atoms: everything but W->R
ORD = {
    # CPU (AArch64)
    "RA": RELACQ_ORD,         "SY": ALL4,
    "ST": frozenset(("WW",)), "LD": frozenset(("RR", "RW")),
    # GPU (LISA/Bell -> PTX)
    "Ra": RELACQ_ORD,         "Sc": ALL4,
    "Release": frozenset(("WW", "RW")),
    "Acquire": frozenset(("RR", "RW")),
}
# The PTX side also needs a pattern to complete, so each GPU primitive carries
# the synchronization roles it can play.
RELACQ_ROLE = frozenset(("rel", "acq"))
ROLE = {
    "Ra": RELACQ_ROLE, "Sc": frozenset(("rel", "acq", "sc")),
    "Release": frozenset(("rel",)), "Acquire": frozenset(("acq",)),
}


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
    """Per-side ordering only, with NO sync clause: ARM barriers are cumulative
    and need no partner.  Phase 1 is the proof -- e.g. LB comes out Forbidden
    with DMB.LD on both procs."""
    p0, p1 = pairs(shape)
    return "Forbidden" if (p0 in ORD[d0] and p1 in ORD[d1]) else "Allowed"


def ptx_verdict(shape, f0, f1):
    """Per-side ordering plus a completing release/acquire pattern: a PTX fence
    orders nothing across threads on its own (Lustig'19 Fig 4)."""
    p0, p1 = pairs(shape)
    ok = p0 in ORD[f0] and p1 in ORD[f1] and sync_ok(shape, ROLE[f0], ROLE[f1])
    return "Forbidden" if ok else "Allowed"


# --- solvers ----------------------------------------------------------------
def _run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


OBS = re.compile(r"^Observation \S+ (Never|Sometimes|Always)", re.M)


def herd(path, extra):
    r = _run([os.path.join(BIN, "herd7"), "-set-libdir", HERD_LIBDIR] + extra + [path])
    m = OBS.search(r.stdout)
    if not m:
        return "ERROR"
    return "Forbidden" if m.group(1) == "Never" else "Allowed"


def _edges(shape, q0, q1, po_edge, atom):
    """Render the 4 edge tokens of a 2-proc cycle whose P0 carries primitive q0
    and P1 carries q1.  `po_edge(q, XY)' names a program-order edge and
    `atom(q, dir)' the per-event annotation; every edge token is
    <base><atom(src)><atom(dst)>, so a mixed cell (atoms on one proc, a fence on
    the other) is expressed exactly as diy wants it."""
    c = CYCLE[shape]
    xy0, xy1 = c[0][3:], c[2][3:]
    # events, in cycle order: (proc primitive, direction)
    ev = [(q0, xy0[0]), (q0, xy0[1]), (q1, xy1[0]), (q1, xy1[1])]
    a = [atom(q, d) for (q, d) in ev]
    return [po_edge(q0, xy0) + a[0] + a[1],
            c[1] + a[1] + a[2],
            po_edge(q1, xy1) + a[2] + a[3],
            c[3] + a[3] + a[0]]


def _arm_po(q, xy):
    return "Pod" + xy if q == "RA" else "DMB.%sd%s" % (q, xy)


def _arm_atom(q, d):
    if q != "RA":
        return "P"                       # plain STR / LDR
    return "L" if d == "W" else "Q"      # STLR / LDAPR (RCpc)


def _ptx_po(q, xy):
    return "Pod" + xy if q == "Ra" else "Fence%sSysd%s" % (q, xy)


def _ptx_atom(q, d):
    if q != "Ra":
        return "RelaxedSys"
    return "ReleaseSys" if d == "W" else "AcquireSys"


def gen_arm(tmp, shape, d0, d1):
    name = "arm-%s-%s-%s" % (shape, d0, d1)
    e = _edges(shape, d0, d1, _arm_po, _arm_atom)
    r = _run([os.path.join(BIN, "diyone7"), "-arch", "AArch64", "-name", name]
             + e, cwd=tmp)
    return os.path.join(tmp, name + ".litmus") if r.returncode == 0 else None


def gen_ptx(tmp, shape, f0, f1):
    name = "ptx-%s-%s-%s" % (shape, f0, f1)
    e = _edges(shape, f0, f1, _ptx_po, _ptx_atom)
    r = _run([os.path.join(BIN, "diyone7"), "-set-libdir", HERD_LIBDIR, "-bell", BELL,
              "-arch", "LISA", "-name", name,
              "-scopes", "(sys (gpu (cta P0) (cta P1)))"] + e, cwd=tmp)
    return os.path.join(tmp, name + ".litmus") if r.returncode == 0 else None


# --- phases -----------------------------------------------------------------
DMBS = ["RA", "SY", "ST", "LD"]
FENCES = ["Ra", "Sc", "Release", "Acquire"]


def phase_arm(tmp, quiet):
    bad = []
    if not quiet:
        print("===== PHASE 1: ARM -- herd7 native AArch64 vs the table (%d cells) =====" % (len(SHAPES)*len(DMBS)**2))
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
                    bad.append("ARM %s P0=%s P1=%s: herd7=%s table=%s"
                               % (sh, d0, d1, got, want))
        if not quiet:
            print("  %-5s %s" % (sh, " ".join(row)))
    if not quiet:
        print("        rows = P0 in %s ; within a row P1 in the same order"
              % "/".join(DMBS))
    return bad


def phase_ptx(tmp, quiet):
    bad = []
    if not quiet:
        print("\n===== PHASE 2: PTX -- herd7 + nvidia-ptx.cat vs the table (%d cells) =====" % (len(SHAPES)*len(FENCES)**2))
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
                    bad.append("PTX %s P0=%s P1=%s: herd7=%s table=%s"
                               % (sh, f0, f1, got, want))
        if not quiet:
            print("  %-5s %s" % (sh, " ".join(row)))
    if not quiet:
        print("        rows = P0 in %s ; within a row P1 in the same order"
              % "/".join(FENCES))
    return bad


# --- phase 3: agreement with the control-map lattice ------------------------
# ORD is the `ord' half of controlmap.py's (tier, ord) strength lattice, which
# is restated there rather than imported.  Agreeing with herd7 does not make the
# two copies agree with each other -- one of them can be edited alone -- so this
# phase is the join, and it names the controlmap expression each ORD key has to
# equal instead of comparing two anonymous dicts.
#
# The `tier' half is NOT covered.  controlmap's side_le compares tier first, so
# promoting a primitive from `partial' to `SC-capable' changes which siblings
# count as weakenings while every ord set stays put, and nothing here would see
# it.
#
#   ordercheck key, controlmap table, key in it
KEY_MAP = [
    ("SY",      "DMB",   "SY"),
    ("ST",      "DMB",   "ST"),
    ("LD",      "DMB",   "LD"),
    # STLR + LDAPR on one proc: controlmap raises the side once per access, so
    # its image of the atom pair is the union of the two contributions.
    ("RA",      "ATOMS", "REL_ORD | ACQ_ORD"),
    ("Sc",      "GPU",   "sc"),
    ("Release", "GPU",   "release"),
    ("Acquire", "GPU",   "acquire"),
    # w[release] + r[acquire] on one proc, which is what f[acq_rel] names.
    ("Ra",      "GPU",   "acq_rel"),
]


def _cm_ord(tbl, key):
    """The ord set controlmap gives that primitive."""
    if tbl == "DMB":
        return controlmap.DMB_STRENGTH[key][1]
    if tbl == "GPU":
        return controlmap.GPU_FENCE_STRENGTH[key][1]
    return controlmap.REL_ORD | controlmap.ACQ_ORD


def _cm_name(tbl, key):
    return key if tbl == "ATOMS" else "%s_STRENGTH[%r]" % (
        "DMB" if tbl == "DMB" else "GPU_FENCE", key)


def phase_agree(_tmp, quiet):
    bad = []
    if not quiet:
        print("\n===== PHASE 3: AGREE -- controlmap.py's lattice vs the table "
              "(%d primitives) =====" % len(KEY_MAP))
    mapped = {k for k, _, _ in KEY_MAP}
    if mapped != set(ORD):
        bad.append("AGREE the key map covers %s but ORD holds %s -- a primitive "
                   "with no counterpart is unchecked"
                   % (sorted(mapped), sorted(ORD)))
    for tbl, table in (("DMB", controlmap.DMB_STRENGTH),
                       ("GPU", controlmap.GPU_FENCE_STRENGTH)):
        named = {k for _, t, k in KEY_MAP if t == tbl}
        if named != set(table):
            bad.append("AGREE the key map names %s of controlmap's %s table, "
                       "which holds %s" % (sorted(named), tbl, sorted(table)))
    for k, tbl, ck in KEY_MAP:
        mine, theirs = frozenset(ORD[k]), frozenset(_cm_ord(tbl, ck))
        if not quiet:
            print("  %-8s %-30s %s" % (k, _cm_name(tbl, ck),
                                       "".join(sorted(mine)) or "-"))
        if mine != theirs:
            bad.append("AGREE %s: ORD=%s but controlmap %s=%s"
                       % (k, sorted(mine), _cm_name(tbl, ck), sorted(theirs)))
    return bad


# The phases, by the prefix their mismatches carry.  A caller may run one of
# them alone; each entry carries the per-shape cell count the census multiplies
# len(SHAPES) by, so the printed census is of the cells actually decided.  AGREE
# decides no cell -- it runs no solver -- and is counted separately.
PHASES = {"ARM": (phase_arm, len(DMBS) ** 2),
          "PTX": (phase_ptx, len(FENCES) ** 2),
          "AGREE": (phase_agree, 0)}


def run(quiet=False, phases=("ARM", "PTX", "AGREE")):
    for b in ("herd7", "diyone7"):
        if not os.path.exists(os.path.join(BIN, b)):
            print("FATAL: %s/%s not built -- run 'make all'" % (BIN, b))
            return 2
    tmp = tempfile.mkdtemp(prefix="ordercheck.")
    bad = []
    try:
        for p in phases:
            bad += PHASES[p][0](tmp, quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print()
        for b in bad:
            print("  *** %s" % b)
        print("\nORDERCHECK FAILED: %d mismatch(es).  The ordering table is not "
              "what the model solvers compute, or not what controlmap.py holds."
              % len(bad))
        return 1
    if not quiet:
        joined = (", and %d primitives agree with controlmap.py"
                  % len(KEY_MAP)) if "AGREE" in phases else ""
        print("\nORDERCHECK OK  (%d solver cells all agree with the table%s)"
              % (len(SHAPES) * sum(PHASES[p][1] for p in phases), joined))
    return 0


# --- bite -------------------------------------------------------------------
# Each injection names the phase it MUST redden, which is also the prefix that
# phase's mismatches carry, and only that phase is run: a red anywhere else would
# be evidence for some other injection.  The DMB names index no fence cell and
# ROLE/sync_ok have no ARM reader (an ARM barrier is cumulative and needs no
# partner), so no solver phase can stand in for another.  ORD is read by its
# solver phase and by AGREE, so which of the two a corruption of it is charged to
# is a choice this list makes; controlmap's own tables have no solver-phase
# reader, so the AGREE injection could redden nothing else.
INJECTIONS = [
    ("ORD[DMB.ST] gains RR -- a store barrier that orders load;load",
     "D.ORD['ST'] = frozenset(('WW','RR'))", "ARM "),
    ("ORD[f[acquire]] loses RW -- an acquire fence that leaves load;store free",
     "D.ORD['Acquire'] = frozenset(('RR',))", "PTX "),
    ("the sync clause is dropped -- per-side ordering alone would forbid",
     "D.sync_ok = lambda *a: True", "PTX "),
    ("ROLE[f[acquire]] gains rel -- an acquire fence that also releases",
     "D.ROLE['Acquire'] = frozenset(('acq','rel'))", "PTX "),
    ("controlmap's DMB_STRENGTH[ST] gains RR -- the two copies part company",
     "C.DMB_STRENGTH['ST'] = (C.PART_TIER, frozenset(('WW','RR')))", "AGREE"),
]


def bite():
    print("===== ORDERCHECK BITE: does the gate fail when the table is wrong? =====")
    rc = 0
    for desc, inj, where in INJECTIONS:
        drv = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
        drv.write("import sys\nsys.path.insert(0, %r)\nimport ordercheck as D\n"
                  "import controlmap as C\n"
                  "def snap():\n"
                  "    return (frozenset(D.ORD['ST']), frozenset(D.ORD['Acquire']),"
                  " frozenset(D.ROLE['Acquire']), D.sync_ok,"
                  " C.DMB_STRENGTH['ST'], C.GPU_FENCE_STRENGTH['acquire'])\n"
                  "before = snap()\n"
                  "%s\n"
                  "assert before != snap(), 'injection was vacuous'\n"
                  "sys.exit(D.run(quiet=True, phases=(%r,)))\n"
                  % (HERE, inj, where.strip()))
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
        print("BITE FAILED: a corrupted table still passed, or reddened the wrong phase.")
        return 1
    print("BITE OK: every corruption of the table is caught, in the phase that names it")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true")
    a = ap.parse_args()
    return bite() if a.bite else run(a.quiet)


if __name__ == "__main__":
    sys.exit(main())
