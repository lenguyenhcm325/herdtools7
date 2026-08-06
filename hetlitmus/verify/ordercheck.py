#!/usr/bin/env python3
"""ordercheck.py -- the ordering rule behind the two-sided het oracle, machine-
checked against both constituent solvers.

The two-sided (`-2s') tests are the only rows that can be Disallowed, i.e. the
only rows that can refute the compound model, and they span a 4 x 4 grid of
CPU {STLR/LDAPR, DMB.SY, DMB.ST, DMB.LD} x GPU {w[release]/r[acquire], f[sc,sys],
f[release,sys], f[acquire,sys]}.  Which cells forbid is not "both sides have a
fence": DMB.LD on a store;store producer orders nothing, and a PTX release fence
on a load;load consumer orders nothing.  Hand-written verdicts are how an oracle
acquires a silent error, and an oracle error here is a FALSE REFUTATION of the
compound memory model.  So build-nvidia-oracle.sh implements a compositional rule
over ord(p) / role(p) / sync(shape,roles), and this gate proves the rule is the
same function herd7 computes:

  PHASE 1  ARM     6 shapes x prim(P0) x prim(P1) = 96 CPU-only AArch64 tests
                   from diyone7, decided by herd7's native AArch64 model.
  PHASE 2  PTX     the same 96 cells as LISA/Bell sys-scope tests, decided by
                   herd7 + bells/ptx.bell + cats/nvidia-ptx.cat (Lustig'19).
  PHASE 3  ORACLE  every two-sided 2-proc row of tests/het/expected-nvidia.csv
                   must equal the rule's het verdict AS GATED BY THE NVOR SLOT
                   RULE, so the bash oracle and this rule cannot drift apart.

The slot rule (NVOR, Nguyen 2026-08-06; env-research/NVOR-register.md) is the
provenance layer above the ordering rule: a cell the ordering rule forbids is
Disallowed only if every registration its derivation needs was REGISTERED.  Three
were declined -- the gc-direction meet (Q2), the ARM-DMB-SY-is-a-PTX-fence.sc
identification (Q3) and the unidirectional-fence semantics (Q4) -- so 34 cells
are NO-ORACLE naming their own open slot.  `nvor_slots' here is a SECOND,
independent implementation of build-nvidia-oracle.sh's gate, and the count is
asserted: two implementations agreeing on a gate that is wrong in the same
direction is the one thing neither can catch alone.

That failure then HAPPENED, and neither the second implementation nor the count
pin caught it: both keyed the gc slot to the test's NAME TAG rather than to the
DIRECTION of the rf that carries the sw, so both were wrong by the same 2 rows
and the count and sha were stable at the wrong value.  Phase E's BLIND
re-derivation found it; NVOR Phase D3 (2026-08-06) repaired both predicates
independently and the count moved 32 -> 34.  See `sw_devdir' below and
env-research/NVOR-DR-nvidia-oracle.md.

The rule itself, the source of every table entry, and why a cell on which the two
primary models disagree is NO-ORACLE rather than Disallowed: hetlitmus/docs/
het-oracle.md, "Two-sided order pairs".  The one step no solver here can decide
-- that a CPU DMB and a sys-scope GPU fence are morally strong at all -- is
grounded there too.  (Q10/Q10b)

Usage:  ordercheck.py [-q]     run the gate
        ordercheck.py --bite   prove the gate fails when the rule is corrupted
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
# HERD_LIBDIR, not LIBDIR: every other gate's LIBDIR is litmus7's (litmus/libdir).
HERD_LIBDIR = os.path.join(REPO, "herd", "libdir")
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
RELACQ_ROLE = frozenset(("rel", "acq"))
ROLE = {
    "RA": RELACQ_ROLE, "SY": frozenset(("rel", "acq", "sc")),
    "ST": frozenset(("rel",)), "LD": frozenset(("acq",)),
    "Ra": RELACQ_ROLE, "Sc": frozenset(("rel", "acq", "sc")),
    "Release": frozenset(("rel",)), "Acquire": frozenset(("acq",)),
}
# Corpus name token -> primitive.  All four CPU halves are real corpus cells; the
# `st'/`ld' rows were decided by this rule and machine-checked here before any
# such test could be emitted, and admitting them changed no line of ORD / ROLE /
# CPU_FENCE -- the oracle rows they carry are decided by a rule that predates
# them.  (Q10b)
CPU_FENCE = {"ra": "RA", "sy": "SY", "st": "ST", "ld": "LD"}
GPU_FENCE = {"ra": "Ra", "sc": "Sc", "rel": "Release", "acq": "Acquire"}


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
    p0, p1 = pairs(shape)
    ok = p0 in ORD[f0] and p1 in ORD[f1] and sync_ok(shape, ROLE[f0], ROLE[f1])
    return "Forbidden" if ok else "Allowed"


def cell_roles(cut, cpu_tok, gpu_tok):
    """Role sets of a het cell, indexed by PROC.  cut = 'cg' or 'gc', i.e.
    cut[i] is the device letter of proc i."""
    role = [None, None]
    role[cut.index("c")] = ROLE[CPU_FENCE[cpu_tok]]
    role[cut.index("g")] = ROLE[GPU_FENCE[gpu_tok]]
    return role


def het_verdict(shape, cut, cpu_tok, gpu_tok):
    """cut = 'cg' or 'gc' (device of P0, P1).  -> Disallowed/NO-ORACLE/Allowed

    THE PURE ORDERING RULE.  It knows nothing about the NVOR registrations; the
    slot gate is applied on top, in phase_oracle, so that this function stays
    the thing Phases 1 and 2 machine-check against the two solvers.  Mixing the
    provenance decision in here would contaminate the only statement those
    phases can make.
    """
    p = pairs(shape)
    C, G = CPU_FENCE[cpu_tok], GPU_FENCE[gpu_tok]
    if p[cut.index("c")] not in ORD[C] or p[cut.index("g")] not in ORD[G]:
        return "Allowed"
    role = cell_roles(cut, cpu_tok, gpu_tok)
    return "Disallowed" if sync_ok(shape, role[0], role[1]) else "NO-ORACLE"


# --- the NVOR slot gate (Nguyen 2026-08-06; env-research/NVOR-register.md) ----
# An INDEPENDENT re-implementation of build-nvidia-oracle.sh's slot gate, in a
# different language over a differently-derived cycle table.  A row whose
# Disallowed derivation needs a DECLINED registration is NO-ORACLE in the CSV,
# and this is the second measurement of which rows those are:
#
#   GC      Q2 -- the symmetric meet (GPU-producer direction).  DECLINED.
#   SC      Q3 -- an ARM DMB SY IS a PTX fence.sc for the Fence-SC order, the
#                 only route that cuts an rf-free cycle.  DECLINED.
#   UNIDIR  Q4 -- fence.acquire / fence.release semantics (PTX ISA 8.6/SM_90,
#                 postdating Lustig'19).  DECLINED.
#
# Counted, not merely applied: EXPECT_NVOR_DEMOTED below is asserted, so a gate
# that silently widened or narrowed reddens this phase instead of agreeing with
# a CSV that widened or narrowed the same way.  It was 32 until NVOR Phase D3
# (2026-08-06) -- see sw_devdir.
EXPECT_NVOR_DEMOTED = 34
# The registration ID each slot names.  A demoted row's Source must carry its
# own ID -- naming the SPECIFIC declined question, never a blanket punt.
NVOR_SLOT_ID = {"GC": "NVOR-Q2", "SC": "NVOR-Q3", "UNIDIR": "NVOR-Q4"}


def sw_devdir(shape, cut, role):
    """Which DEVICE PRODUCES the value the synchronization rides on: 'cg', 'gc'
    or None when no rf carries a completing pattern.

    NVOR Phase D3 (2026-08-06).  Until then both this gate and the shell
    generator asked `is this test NAMED gc-?' (`cut[0] == "g"'), which answers
    "which device sits on P0", not "does the derivation need a GPU-producer
    observation to be morally strong".  They coincide when the cycle has a
    single Rfe edge -- MP and S -- and both are vacuous when it has none (R,
    SB).  LB has TWO, so a cg-NAMED LB test synchronizes gc-wards whenever its
    CPU primitive carries only the acquire role.  Phase E's blind re-derivation
    found two rows shipping Disallowed on the DECLINED Q2 meet because of it,
    and neither implementation nor the count pin could see it (both were wrong
    by the same rows).  env-research/NVOR-DR-nvidia-oracle.md.

    Written over `rf_dirs' and the per-proc role sets rather than over the
    generator's branch flags ON PURPOSE: this is the second, independent
    measurement of the same property, and a transliteration of the shell would
    reproduce the shell's mistakes.

    When BOTH edges carry a completing pattern the cell is keyed to `cg': that
    is the direction NVOR-Q1 REGISTERS, and a row must be keyed to the route its
    verdict actually rests on.
    """
    fires = {cut[s] + cut[d] for (s, d) in sorted(rf_dirs(shape))
             if "rel" in role[s] and "acq" in role[d]}
    if not fires:
        return None
    return "cg" if "cg" in fires else "gc"


def nvor_slots(shape, cut, gpu_tok, role):
    """The declined registrations a Disallowed derivation of this cell needs."""
    slots = []
    if sw_devdir(shape, cut, role) == "gc":
        slots.append("GC")
    if not rf_dirs(shape):
        slots.append("SC")
    if gpu_tok in ("rel", "acq"):
        slots.append("UNIDIR")
    return slots


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
        print("===== PHASE 1: ARM -- herd7 native AArch64 vs the rule (%d cells) =====" % (len(SHAPES)*len(DMBS)**2))
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
                    bad.append("ARM %s P0=%s P1=%s: herd7=%s rule=%s"
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
        print("\n===== PHASE 2: PTX -- herd7 + nvidia-ptx.cat vs the rule (%d cells) =====" % (len(SHAPES)*len(FENCES)**2))
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
                    bad.append("PTX %s P0=%s P1=%s: herd7=%s rule=%s"
                               % (sh, f0, f1, got, want))
        if not quiet:
            print("  %-5s %s" % (sh, " ".join(row)))
    if not quiet:
        print("        rows = P0 in %s ; within a row P1 in the same order"
              % "/".join(FENCES))
    return bad


# `<shape>-<cut>-sys-<cpu>.<gpu>-2s'  and the (SY,sc) cell `<...>-sys-fence-2s'.
# The shape alternation is explicit (not `.+?') so a 3/4-proc name can never be
# mis-split into a 2-proc one.
TWOS = re.compile(r"^(?P<shape>MP|SB|LB|R|S)-(?P<cut>cg|gc)-sys-"
                  r"(?:(?P<c>ra|sy|st|ld)\.(?P<g>ra|sc|rel|acq)"
                  r"|(?P<f>fence)|(?P<a>acqrel))-2s$")

# The number of oracle rows Phase 3 must ACTUALLY read, asserted rather than
# merely printed: `n == 0' is too weak a guard, because a regex that stopped
# matching the `st'/`ld' cells would silently drop 64 of the 128 rows and the
# phase would still report OK on the remaining 64.
#
#   112  order-pair cells  = 8 cut classes (MP-cg MP-gc SB-cg LB-cg R-cg R-gc
#                            S-cg S-gc) x (4 cpu x 4 gpu - 2 diagonal)
#    16  the (D) diagonal  = the same 8 cut classes x {-fence-2s, -acqrel-2s},
#                            read as the (sy,sc) and (ra,ra) cells
EXPECT_ORACLE_ROWS = 128


def phase_oracle(quiet):
    bad = []
    csv = os.path.join(HETDIR, "expected-nvidia.csv")
    n = 0
    demoted = []
    with open(csv) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("Litmus,"):
                continue
            name, verdict = line.split(",")[0], line.split(",")[1]
            m = TWOS.match(name)
            if not m:
                continue    # 2+2W and the 3/4-proc shapes are decided by the
                            # cross-device MCA question, not by this rule
            c = m.group("c") or ("ra" if m.group("a") else "sy")
            g = m.group("g") or ("ra" if m.group("a") else "sc")
            want = het_verdict(m.group("shape"), m.group("cut"), c, g)
            slots = nvor_slots(m.group("shape"), m.group("cut"), g,
                               cell_roles(m.group("cut"), c, g))
            if want == "Disallowed" and slots:
                # The ordering rule forbids, but the derivation needs a
                # registration Nguyen declined -> NO-ORACLE, and the CSV row
                # must SAY SO: naming the slot is the Q0 no-blanket-punting
                # guard, and a row that merely went NO-ORACLE without one would
                # be indistinguishable from a pattern that failed to complete.
                want = "NO-ORACLE"
                demoted.append(name)
                if verdict == want:
                    for s in slots:
                        if NVOR_SLOT_ID[s] not in line:
                            bad.append(
                                "ORACLE %s: demoted for slot %s but its Source "
                                "never names %s" % (name, s, NVOR_SLOT_ID[s]))
            n += 1
            if verdict != want:
                bad.append("ORACLE %s: csv=%s rule=%s" % (name, verdict, want))
    if not quiet:
        print("\n===== PHASE 3: expected-nvidia.csv two-sided 2-proc rows "
              "vs the rule =====")
        print("  %d rows checked on MP/SB/LB/R/S -- the emitted fence-pair cells"
              "\n  PLUS the pre-existing `-fence-2s' and `-acqrel-2s' rows read "
              "as the (sy,sc) and (ra,ra) cells" % n)
        print("  %d of them are NVOR-demoted (Q2/Q3/Q4 declined) and each names "
              "its own open slot" % len(demoted))
    if n != EXPECT_ORACLE_ROWS:
        bad.append("ORACLE: read %d two-sided 2-proc rows, expected %d -- the "
                   "phase is checking a DIFFERENT set of rows than it claims "
                   "(a name-regex that stopped matching, or a corpus change "
                   "that was not recounted)" % (n, EXPECT_ORACLE_ROWS))
    if len(demoted) != EXPECT_NVOR_DEMOTED:
        bad.append("ORACLE: the NVOR slot gate demotes %d rows here but the "
                   "adjudication demotes exactly %d -- this gate and the "
                   "generator agreeing on a WIDER or NARROWER gate is the one "
                   "failure two independent implementations cannot catch on "
                   "their own" % (len(demoted), EXPECT_NVOR_DEMOTED))
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
        print("\nORDERCHECK OK  (%d solver cells + the oracle's two-sided "
              "2-proc rows all agree with the rule)"
              % (len(SHAPES) * (len(DMBS) ** 2 + len(FENCES) ** 2)))
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
     "D.GPU_FENCE = dict(D.GPU_FENCE, sc='Release')", "ORACLE"),
    # The row-count pin.  Half-blinding the name regex (drop `st|ld') is the
    # failure it exists for: every row still read agrees with the rule, so
    # without the pin the phase would report OK on 64 of 128.
    ("the name regex stops matching the `st'/`ld' CPU cells (phase half-blind)",
     "D.TWOS = __import__('re').compile(D.TWOS.pattern.replace('ra|sy|st|ld', 'ra|sy'))",
     "ORACLE"),
    # The NVOR slot gate, both directions.  NARROW is the dangerous one: it
    # re-arms 34 Disallowed verdicts that rest on declined registrations, i.e.
    # it manufactures a falsification surface out of unregistered premises.
    ("the NVOR slot gate goes NARROW -- no row needs a declined registration",
     "D.nvor_slots = lambda *a: []", "ORACLE"),
    ("the NVOR slot gate goes WIDE -- every cell claims an open slot",
     "D.nvor_slots = lambda *a: ['GC']", "ORACLE"),
    # THE D3 INJECTION.  The exact pre-D3 predicate, restored: the GC slot keyed
    # to the test's NAME TAG instead of to the direction of the rf that carries
    # the sw.  It is the corruption that shipped -- both implementations had it,
    # so the count and sha pins were stable at the wrong value and only a blind
    # re-derivation could find it.  It must now redden ORACLE by name, which is
    # what makes the name-tag shortcut provably dead in THIS implementation
    # (the generator's own half is bitten separately in tests/cram).
    ("the GC slot reverts to the NAME TAG (`is the test named gc-?') instead of"
     " the sw-carrying rf's direction",
     "D.nvor_slots = lambda shape, cut, gpu_tok, role: "
     "(['GC'] if cut[0] == 'g' else []) "
     "+ ([] if D.rf_dirs(shape) else ['SC']) "
     "+ (['UNIDIR'] if gpu_tok in ('rel', 'acq') else [])", "ORACLE"),
]


def bite():
    print("===== ORDERCHECK BITE: does the gate fail when the rule is wrong? =====")
    rc = 0
    for desc, inj, where in INJECTIONS:
        drv = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
        drv.write("import sys\nsys.path.insert(0, %r)\nimport ordercheck as D\n"
                  "def snap():\n"
                  "    return (frozenset(D.ORD['ST']), frozenset(D.ORD['Acquire']),"
                  " frozenset(D.ROLE['Acquire']), D.sync_ok, dict(D.GPU_FENCE),"
                  " D.TWOS.pattern, D.nvor_slots)\n"
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
