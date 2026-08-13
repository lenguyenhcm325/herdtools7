#!/usr/bin/env python3
"""The positive-control map: the Layer-A mutant and Layer-B canary each het test
co-runs.  mu(T) is T's LATTICE-FLOOR sibling -- the same program with every
ordering annotation dropped -- so a `target_count = 0' on T is a non-observation
on a harness that demonstrably produced an interleaving of T's own shape rather
than an uninterpretable empty histogram.  The map carries no verdict: what mu
buys is a REPORTED count, and hetlitmus/docs/positive-control.md says how a null
is read against it.

WHY THIS FILE EXISTS (read before "simplifying" it): mu(T) is DERIVED from the
corpus, not rewritten from T's name, and the corpus is what decides.  On the grid
rows the floor sibling does happen to be `<shape>-<cut>-<scope>-relaxed'; on the
two non-grid reference tests it is not -- mu(MP-het) is MP-cg-sys-relaxed and
mu(SB-het) is SB-cg-sys-relaxed, names no rewrite of `MP-het' produces.  MuAlt is
where a rewrite fails outright: the one-sided variants are named for the op the
GPU performs, `acquire' annotates only reads and `release' only writes
(tests/_grid_lib.sh ord_for), and the GPU's role flips with the device cut, so a
variant whose GPU proc has no access of that kind is degenerate (byte-identical
to its `relaxed' sibling) and generate.sh dedups it away -- MP-gc-sys-acquire,
S-gc-sys-acquire and R-gc-sys-acquire do not exist at all.  The gate therefore
checks the PROPERTY rather than the spelling, and fails closed: a missing or
non-weaker mutant breaks the build rather than skipping the control, because a
silently absent control does not weaken a null -- it makes it unfalsifiable,
while the null still prints and still looks green.

Usage:
    controlmap.py --emit  [--dir D] [--lattice L]        > control-map.csv
    controlmap.py --check [--dir D] [--lattice L] [--map F]     (the gate)
    controlmap.py --bite  [--dir D] [--lattice L]   (the gate's negative control)
"""

import argparse
import csv
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "tests", "het")
# The committed (x86_64, hip) pair fixture.  litmus7 resolves the map name from
# the CPU column, so only an x86 rendering asks for the AMD map by name; the het
# corpus is rendered for AArch64 whatever lattice the audit runs under.
X86_FIXTURE = os.path.join(HERE, "..", "tests", "het-x86")
LITMUS7 = os.path.join(HERE, "..", "..", "_build", "install", "default", "bin",
                       "litmus7")
LIBDIR = os.path.join(HERE, "..", "..", "litmus", "libdir")

# ---------------------------------------------------------------------------
# THE ASSERTED CENSUS.  Every corpus row either names a mu or sits at the floor,
# so these three numbers partition the corpus and the gate fails if they stop
# doing so.  They are the same on BOTH lattices, and that is a corpus fact rather
# than an identity: no row's only ordering op comes from the rung the x86 lattice
# drops (STLR / LDAPR / DMB.ST / DMB.LD), so nothing that holds a row off the
# AArch64 floor stops holding it off the x86 one.  check() re-measures both floor
# sets and reddens if they part company, so these constants cannot outlive the
# fact they rest on.
N_TESTS = 411
N_WITH_MU = 333
N_FLOOR = 78

# ---------------------------------------------------------------------------
# THE LATTICE PARAMETER (memo PORT2-R2 7.D11, landed by P2a 2026-08-02).
#
# The AMD map is REGENERATED, never translated: the CPU strength lattice LOSES
# ITS MIDDLE RUNG.  On AArch64 STLR / LDAPR / DMB.ST / DMB.LD are `partial'
# (tier 1); their x86 images are all a plain MOV (memo 3.1's collapse table), so
# on x86 the only CPU op that orders anything across a pair is MFENCE.  A
# candidate that merely moves within {ra, st, ld} is therefore NOT a weakening on
# MI300A -- the harness would run the IDENTICAL program and the "control" would
# vouch for nothing.  `weakening_of' rejects it as "identical ordering strength",
# which is the fail-closed behaviour D11 asks for.
#
# LATTICE is module state read by _parse_instr and audit_map.  The default is
# `aarch64', so the NVIDIA path is byte-for-byte what it was.
LATTICE = "aarch64"
LATTICES = ("aarch64", "x86")


def set_lattice(name):
    global LATTICE
    if name not in LATTICES:
        raise SystemExit("controlmap: unknown lattice %r (expected %s)"
                         % (name, " | ".join(LATTICES)))
    LATTICE = name


def map_basename(lattice=None):
    """Which map file a lattice's artifact is: the two are separate files, and
    litmus/hetCpuFront.ml names the same two."""
    return ("control-map-amd.csv" if (lattice or LATTICE) == "x86"
            else "control-map.csv")

# ---------------------------------------------------------------------------
# The per-side ordering-strength lattice.  mu(T) must be strictly WEAKER
# componentwise (cpu,gpu) and structurally identical to T -- same procs, same
# devices, same ordered (kind,location) access list: a pure ordering weakening,
# not a different program.
#
# Strength is not a count of primitives: `acqrel' carries more of them than
# `fence' (STLR+LDAPR / acquire+release vs one DMB.SY / one fence.sc.sys) yet is
# strictly weaker, because RCpc release/acquire does not order store->load where
# an SC fence does.  Nor is a bare "is it a fence?" tier enough: f[release,sys]
# is a fence but is weaker than the w[release]/r[acquire] pair, and DMB.ST /
# DMB.LD are incomparable with each other.  So a side's strength is the pair
# (tier, ord):
#
#   tier  2 SC-capable  DMB SY / DSB SY ; f[sc,..] ; an `sc'-tagged access
#         1 partial     orders something but cannot stand in for an SC fence:
#                       STLR / LDAPR / LDAR ; w[release] / r[acquire] ;
#                       f[release,..] / f[acquire,..] ; DMB ST / DMB LD
#         0 plain       STR / LDR ; [relaxed,..]
#   ord   the program-order pairs {WW,RR,WR,RW} that side's ops order inside
#         their own thread -- the ord(p) table of verify/ordercheck.py, which
#         machine-checks it against herd7 and keys these two copies together.
#
# `weaker-or-equal' is (t1,o1) <= (t2,o2) iff t1 < t2, or t1 == t2 and o1 is a
# subset of o2.  That keeps DMB.ST/DMB.LD incomparable, and f[release] and
# r[acquire]-annotated reads incomparable: neither is a weakening of the other,
# and a control that is not a weakening vouches for nothing.  (Q10)
SC_TIER, PART_TIER, PLAIN = 2, 1, 0

ALL4 = frozenset(("WW", "RR", "WR", "RW"))
NONE4 = frozenset()
REL_ORD = frozenset(("WW", "RW"))       # release: orders anything -> a write
ACQ_ORD = frozenset(("RR", "RW"))       # acquire: orders a read -> anything

DMB_STRENGTH = {"SY": (SC_TIER, ALL4),
                "ST": (PART_TIER, frozenset(("WW",))),
                "LD": (PART_TIER, ACQ_ORD)}
GPU_FENCE_STRENGTH = {"sc": (SC_TIER, ALL4),
                      "acq_rel": (PART_TIER, REL_ORD | ACQ_ORD),
                      "release": (PART_TIER, REL_ORD),
                      "acquire": (PART_TIER, ACQ_ORD)}

# The bottom of the (cpu,gpu) lattice: a program with no ordering op on either
# side.  `mu(T) = the floor sibling' is defined against this, and `T is at the
# floor' -- the one admitted reason for having no mu -- is exactly equality here.
BOTTOM = ((PLAIN, NONE4), (PLAIN, NONE4))


def side_le(a, b):
    """a is weaker-than-or-equal-to b on the (tier, ord) lattice."""
    if a[0] != b[0]:
        return a[0] < b[0]
    return a[1] <= b[1]


def raise_side(cur, tier, ordset):
    """Fold one more op into a side's strength: the tier is the max and the ord
    set the union of everything that op contributes at or above the top tier."""
    if tier > cur[0]:
        return (tier, ordset)
    if tier == cur[0]:
        return (tier, cur[1] | ordset)
    return cur


def _pp(s):
    """Readable (tier, ord) strength pair for an error message."""
    return "(%d %s, %d %s)" % (s[0][0], "".join(sorted(s[0][1])) or "-",
                               s[1][0], "".join(sorted(s[1][1])) or "-")


# The rejection D11 asks for, spelled once: `--bite' injection [2] wants this
# exact string back, so the message and the expectation cannot drift apart.
SAME_STRENGTH = "identical ordering strength -- not a weakening at all"


def weakening_of(T, M):
    """Why M cannot serve as mu(T), or None if it can.  The two properties the
    vouch rests on, in one place: candidate selection asks for None, and the
    audit of the committed map reports the reason."""
    if T.structure() != M.structure():
        return "not a pure ORDERING weakening (access structure differs)"
    ts, ms = T.strength(), M.strength()
    if not (side_le(ms[0], ts[0]) and side_le(ms[1], ts[1])):
        return ("not weaker (cpu,gpu strength %s vs %s)" % (_pp(ms), _pp(ts)))
    if ms == ts:
        return SAME_STRENGTH
    return None


class Test:
    """One parsed .litmus test: device tags + per-proc access structure."""

    def __init__(self, name, path):
        self.name = name
        self.path = path
        self.dev = {}                # proc -> "cpu" | "gpu"
        self.accesses = {}           # proc -> [("R"|"W", location), ...]
        self.cpu_strength = (PLAIN, NONE4)   # (tier, ordered-pair set)
        self.gpu_strength = (PLAIN, NONE4)
        # the SCOPES the GPU ops are annotated with.  Not part of the strength
        # lattice -- a scope change is not an ordering weakening, it is a
        # different experiment -- but the derivation holds it fixed so a
        # cta-scoped sibling cannot be crowned mu of a sys-scoped test.
        self.scopes = set()
        # The rest of the experiment, kept VERBATIM.  Ordering strength and the
        # access structure do not pin the outcome being counted, the initial
        # state it is counted from, or the scope tree the harness is placed in:
        # a sibling that weakens the ordering and also moves any of those counts
        # a different window, so its firing would vouch for something T is not
        # being watched for.  audit_map holds all three fixed between T and mu(T).
        self.init_block = ""
        self.scopes_line = ""
        self.cond_line = ""

    # -- the structural fingerprint mu(T) must match exactly ----------------
    def structure(self):
        return tuple(
            (p, self.dev[p], tuple(self.accesses[p]))
            for p in sorted(self.accesses)
        )

    # -- what must be IDENTICAL, not merely weaker, keyed by what it is -----
    def context(self):
        return (("init block", self.init_block),
                ("`scopes:' tree", self.scopes_line),
                ("condition", self.cond_line))

    def strength(self):
        return (self.cpu_strength, self.gpu_strength)

    def at_floor(self):
        return self.strength() == BOTTOM


def _strip_comment(line):
    return re.sub(r"\(\*.*?\*\)", "", line)


def parse_litmus(path):
    """Parse a Het .litmus: init reg->global map, the P<n>:<dev> header, and the
    per-proc instruction columns.  Deliberately strict -- an unrecognised
    instruction raises, so a corpus change cannot silently degrade the map."""
    name = os.path.basename(path)[: -len(".litmus")]
    t = Test(name, path)

    with open(path) as fh:
        raw = [_strip_comment(l).rstrip("\n") for l in fh]

    # ---- init block: "0:X1=x;"  ->  regmap[(0,"X1")] = "x", plus the block
    # itself, verbatim-modulo-indentation (audit_map holds it fixed).
    regmap = {}
    init_lines = []
    in_init = False
    for l in raw:
        s = l.strip()
        if s.startswith("{"):
            in_init = True
            s = s[1:]
            init_lines.append("{")
        if in_init:
            if "}" in s:
                s = s[: s.index("}")]
                in_init = False
                tail = "}"
            else:
                tail = None
            if s.strip():
                init_lines.append(s.strip())
            if tail:
                init_lines.append(tail)
            for decl in s.split(";"):
                m = re.match(r"^\s*(\d+):(\w+)\s*=\s*(\w+)\s*$", decl)
                if m:
                    regmap[(int(m.group(1)), m.group(2))] = m.group(3)
    t.init_block = "\n".join(init_lines)

    # ---- the outcome being counted and the scope tree it is counted in.  Both
    # sit BELOW the instruction columns, so the body loop below stops at them and
    # nothing else in this file reads them.
    t.scopes_line = "\n".join(l.strip() for l in raw
                              if re.match(r"^\s*scopes\s*:", l))
    t.cond_line = "\n".join(
        l.strip() for l in raw
        if re.match(r"^\s*(exists|forall|~\s*exists|locations)\b", l))

    # ---- the proc header row: " P0:cpu | P1:gpu ;"
    hdr_i = None
    for i, l in enumerate(raw):
        if re.match(r"^\s*P\d+\s*:\s*\w+\s*(\|.*)?;\s*$", l):
            hdr_i = i
            break
    if hdr_i is None:
        raise ValueError("%s: no 'P<n>:<dev>' processor header row" % path)

    cols = [c.strip() for c in raw[hdr_i].rstrip().rstrip(";").split("|")]
    procs = []
    for c in cols:
        m = re.match(r"^P(\d+)\s*:\s*(\w+)$", c)
        if not m:
            raise ValueError("%s: bad proc header cell %r" % (path, c))
        p, dev = int(m.group(1)), m.group(2)
        procs.append(p)
        t.dev[p] = dev
        t.accesses[p] = []

    # ---- body rows, until 'scopes:' / 'exists' / 'forall' / '~exists'
    for l in raw[hdr_i + 1:]:
        s = l.strip()
        if not s:
            continue
        if re.match(r"^(scopes\s*:|exists|forall|~\s*exists|locations)", s):
            break
        cells = [c.strip() for c in s.rstrip().rstrip(";").split("|")]
        if len(cells) != len(procs):
            raise ValueError("%s: body row has %d cells, %d procs: %r"
                             % (path, len(cells), len(procs), s))
        for p, cell in zip(procs, cells):
            if cell:
                _parse_instr(t, p, cell, regmap, path)

    return t


def _parse_instr(t, p, cell, regmap, path):
    """One instruction cell of proc p.  Records real accesses (R/W + location)
    and raises the per-side ordering strength."""
    dev = t.dev[p]

    if dev == "gpu":
        # LISA/Bell:  r[<ord>,<scope>] <reg> <loc>   w[<ord>,<scope>] <loc> <val>
        #             f[<ord>,<scope>]
        m = re.match(r"^([rwf])\[\s*(\w+)\s*,\s*(\w+)\s*\](.*)$", cell)
        if not m:
            raise ValueError("%s: P%d unparsed GPU op %r" % (path, p, cell))
        kind, order, _scope, rest = m.groups()
        t.scopes.add(_scope)
        if kind == "f":
            if order not in GPU_FENCE_STRENGTH:
                raise ValueError("%s: P%d unknown GPU fence order %r"
                                 % (path, p, order))
            t.gpu_strength = raise_side(t.gpu_strength,
                                        *GPU_FENCE_STRENGTH[order])
            return
        rest = rest.split()
        if kind == "r":
            loc = rest[1]                       # r[..] <reg> <loc>
            t.accesses[p].append(("R", loc))
            if order == "acquire":
                t.gpu_strength = raise_side(t.gpu_strength, PART_TIER, ACQ_ORD)
            elif order == "sc":
                t.gpu_strength = raise_side(t.gpu_strength, SC_TIER, ALL4)
        else:
            loc = rest[0]                       # w[..] <loc> <val>
            t.accesses[p].append(("W", loc))
            if order == "release":
                t.gpu_strength = raise_side(t.gpu_strength, PART_TIER, REL_ORD)
            elif order == "sc":
                t.gpu_strength = raise_side(t.gpu_strength, SC_TIER, ALL4)
        if order not in ("relaxed", "acquire", "release", "sc"):
            raise ValueError("%s: P%d unknown GPU order %r" % (path, p, order))
        return

    # ---- CPU: AArch64 (the only het CPU ISA in the corpus)
    up = cell.upper()
    if up.startswith("MOV"):
        return                                   # immediate setup, not an access
    m = re.match(r"^(?:DMB|DSB)[\s.]+(SY|ST|LD)$", up)
    if m:
        # x86 lattice: DMB.ST and DMB.LD have NO x86 image at all (memo 3.1
        # drops them), so they raise nothing; only DMB.SY -> MFENCE survives.
        if LATTICE == "x86" and m.group(1) != "SY":
            return
        t.cpu_strength = raise_side(t.cpu_strength, *DMB_STRENGTH[m.group(1)])
        return
    if re.match(r"^(DMB|DSB|ISB)(\s|\.|$)", up):
        raise ValueError("%s: P%d unsupported barrier %r -- its ordered-pair "
                         "set is not in DMB_STRENGTH" % (path, p, cell))
    m = re.match(r"^(STLR|STR|LDAPR|LDAR|LDR)\s+\w+\s*,\s*\[\s*(\w+)\s*\]", up)
    if not m:
        raise ValueError("%s: P%d unparsed CPU op %r" % (path, p, cell))
    mnem, reg = m.group(1), m.group(2)
    loc = regmap.get((p, reg))
    if loc is None:
        raise ValueError("%s: P%d addr reg %s is not bound in the init block"
                         % (path, p, reg))
    # x86 lattice: STLR and LDAPR/LDAR both collapse to a plain MOV (memo 3.1),
    # so neither raises the CPU side.  This is the middle rung D11 removes.
    x86 = (LATTICE == "x86")
    if mnem in ("STLR", "STR"):
        t.accesses[p].append(("W", loc))
        if mnem == "STLR" and not x86:
            t.cpu_strength = raise_side(t.cpu_strength, PART_TIER, REL_ORD)
    else:
        t.accesses[p].append(("R", loc))
        if mnem in ("LDAPR", "LDAR") and not x86:
            t.cpu_strength = raise_side(t.cpu_strength, PART_TIER, ACQ_ORD)


# ---------------------------------------------------------------------------
NAME_RE = re.compile(r"^(?P<shape>.+?)-(?P<cut>[cg]+)-(?P<scope>cta|gpu|sys)-"
                     r"(?P<order>relaxed|acquire|release|fence|acqrel"
                     r"|(?:ra|sy|st|ld)\.(?:ra|sc|rel|acq))"
                     r"(?P<two>-2s)?$")


def split_name(name):
    m = NAME_RE.match(name)
    return m.groupdict() if m else None


def canary_for(name):
    """Layer B, shared by both lattices: a het MP-*-sys-relaxed instance,
    matching T's cross-device direction where T has one."""
    parts = split_name(name)
    cut = parts["cut"] if parts else None
    return "MP-%s-sys-relaxed" % cut if cut in ("cg", "gc") else "MP-cg-sys-relaxed"


# ---------------------------------------------------------------------------
# THE COLUMNS, and why two of them are not the same thing.
#
#   Mu        the sibling that is CO-RUN.  T's structural twin at the lattice
#             floor: every ordering annotation dropped on both sides, so it is
#             the weakest program of T's own shape the corpus contains and the
#             one most likely to fire in the window T is being watched in.
#   MuAlt     the NEAREST weakening -- a maximal element of the same candidate
#             set.  Documentation only, never compiled in: it is what a
#             minimal-mutant policy would have co-run, and how far it sits from
#             the floor is how far T is from its own floor.  `-' where the floor
#             IS the nearest weakening.
#   MuRelaxed the fully-relaxed companion, i.e. Mu itself on every row.  The
#             column stays because positive-control.md names it and because the
#             gate ASSERTS the identity: a hand-edit that moves one and not the
#             other splits the co-run choice from the documented one, and that
#             is exactly the drift the audit has to catch.
#
# `none' is the single sentinel and means ONE thing: T is at the lattice floor,
# so no strictly weaker structural sibling can exist and the harness carries the
# Layer-B canary alone.
def derive(tests):
    """The map.  Returns rows [(test, mu, rule, alt, relaxed, canary)] and a list
    of hard errors (which make the gate fail)."""
    rows, errors = [], []
    for name in sorted(tests):
        T = tests[name]
        canary = canary_for(name)
        if canary not in tests:
            errors.append("canary %s for %s does not exist" % (canary, name))
        elif not tests[canary].at_floor():
            errors.append("canary %s for %s is not at the lattice floor -- a "
                          "floor that orders something is not a floor"
                          % (canary, name))
        if canary == name:
            canary = "self"          # T IS the canary; it is its own signal

        cands = [m for m in sorted(tests)
                 if m != name and tests[m].scopes == T.scopes
                 and weakening_of(T, tests[m]) is None]
        floor = [c for c in cands if tests[c].at_floor()]

        if not cands:
            # NO weakening.  Admitted only when none CAN exist -- re-derived
            # from T's own strength, never inferred from the empty search --
            # because a silently missing control does not weaken a null, it
            # makes it unfalsifiable while the null still prints and looks green.
            if not T.at_floor():
                errors.append("%s: no structural sibling is a weakening of it, "
                              "yet it is not at the lattice floor (%s) -- the "
                              "corpus is missing its floor row"
                              % (name, _pp(T.strength())))
            mu = relaxed = "none"
            alt = "-"
            rule = ("at the lattice floor -- no strictly weaker structural "
                    "sibling can exist; Layer-B canary only")
        elif T.at_floor():
            errors.append("%s: it is at the lattice floor yet %d sibling(s) "
                          "claim to be weaker than it" % (name, len(cands)))
            mu = relaxed = alt = "-"
            rule = "-"
        elif len(floor) != 1:
            # Exactly one fully-relaxed twin per (structure, scopes) class is
            # what generate.sh's dedup produces.  Zero means the floor row is
            # missing and mu would silently become some middle rung; two means
            # the corpus holds a duplicate and the choice would be arbitrary.
            errors.append("%s: %d fully-relaxed structural sibling(s) %s -- "
                          "want exactly 1" % (name, len(floor), sorted(floor)))
            mu = relaxed = alt = "-"
            rule = "-"
        else:
            mu = relaxed = floor[0]
            # maximal = nothing else usable is strictly stronger than it
            top = sorted(c for c in cands
                         if not any(c2 != c and weakening_of(tests[c2], tests[c]) is None
                                    for c2 in cands))
            alt = top[0] if top and top[0] != mu else "-"
            rule = ("lattice-floor sibling -- fully relaxed on both sides; "
                    "%d usable weakening(s) of which %d maximal"
                    % (len(cands), len(top)))
        rows.append((name, mu, rule, alt, relaxed, canary))
    return rows, errors


# The header the parsers key on.  litmus/hetControlMap.ml asserts this exact line
# and refuses the file otherwise, so the two schemas can never be read into each
# other's field meanings.
COLUMNS = ["Test", "Mu", "MuRule", "MuAlt", "MuRelaxed", "Canary"]
HEADER_LINE = ",".join(COLUMNS)


def audit_map(text, tests):
    """Re-audit the map AS A COMMITTED ARTIFACT, not as something just derived.

    derive() enforces the vouch's properties when it SELECTS mu, so asserting
    them again on its own choice proves nothing.  This reads the CSV back and
    asserts them on the rows it actually holds -- the check that survives a
    hand-edit, a half-applied regeneration, or the exact mistake the module
    docstring warns about (a Mu column rewritten from the test's NAME, naming a
    grid cell that does not exist).  Those trip it by NAME of the broken
    property; the byte-comparison against a fresh derivation can only say
    'STALE'."""
    errors = []
    body = [l for l in text.splitlines() if l and not l.startswith("#")]
    if not body:
        return ["the map holds no rows at all"]
    if body[0] != HEADER_LINE:
        # FAIL-CLOSED ON THE SCHEMA.  The legacy 8-column map put a verdict in
        # field 2 and the canary in field 8; read with these column meanings its
        # Mu column would be a verdict and its canary a scope note.  Refuse the
        # file rather than mis-bind it -- litmus/hetControlMap.ml refuses the
        # same line for the same reason.
        return ["header line is %r, expected %r" % (body[0], HEADER_LINE)]
    n_mu = n_floor = 0
    for row in csv.reader(body[1:]):
        if not row:
            continue
        if len(row) != len(COLUMNS):
            errors.append("%s: %d fields, expected %d"
                          % (row[0] if row else "?", len(row), len(COLUMNS)))
            continue
        name, mu, _rule, alt, relaxed, canary = row
        # The OCaml reader splits on ',' with no quoting, so a comma or a quote
        # anywhere in a field would silently shift every later field by one.
        for f in row:
            if "," in f or '"' in f:
                errors.append("%s: field %r carries a comma or a quote, which "
                              "the emitter's reader cannot parse" % (name, f))
        if name not in tests:
            errors.append("%s: names no .litmus in the corpus" % name)
            continue
        T = tests[name]
        if canary == "self":
            if canary_for(name) != name:
                errors.append("%s: marked its own canary but the canary for it "
                              "is %s" % (name, canary_for(name)))
        elif canary not in tests:
            errors.append("%s: canary %s does not exist as a .litmus"
                          % (name, canary))
        elif not tests[canary].at_floor():
            errors.append("%s: canary %s is not at the lattice floor"
                          % (name, canary))
        if relaxed != mu:
            errors.append("%s: MuRelaxed is %s but Mu is %s -- the co-run "
                          "control and the documented fully-relaxed companion "
                          "are the same row by construction" % (name, relaxed, mu))
        if mu == "none":
            n_floor += 1
            # Admitted only when the CORPUS supports it, re-derived here so a
            # hand-edited `none' on a row that DOES have a mutant is caught.
            if not T.at_floor():
                errors.append("%s: Mu is `none' but the row is not at the "
                              "lattice floor (%s)" % (name, _pp(T.strength())))
            usable_now = sorted(m for m in tests
                                if m != name and tests[m].scopes == T.scopes
                                and weakening_of(T, tests[m]) is None)
            if usable_now:
                errors.append("%s: Mu is `none' but %s is an existing weakening "
                              "-- a missing control is not a skipped one"
                              % (name, usable_now[0]))
            if alt != "-":
                errors.append("%s: Mu is `none' yet MuAlt names %s"
                              % (name, alt))
            continue
        n_mu += 1
        if T.at_floor():
            errors.append("%s: it is at the lattice floor, so no sibling can be "
                          "weaker, yet Mu names %s" % (name, mu))
        if mu not in tests:
            errors.append("%s: mu(T)=%s does not exist as a .litmus" % (name, mu))
            continue
        why = weakening_of(T, tests[mu])
        if why:
            errors.append("%s: mu(T)=%s is %s" % (name, mu, why))
        if not tests[mu].at_floor():
            errors.append("%s: mu(T)=%s is a weakening but not the LATTICE-FLOOR "
                          "one (%s) -- the co-run control is the floor sibling"
                          % (name, mu, _pp(tests[mu].strength())))
        if tests[mu].scopes != T.scopes:
            errors.append("%s: mu(T)=%s changes the GPU scope %s -> %s, which is "
                          "a different experiment and not an ordering weakening"
                          % (name, mu, sorted(T.scopes), sorted(tests[mu].scopes)))
        # The rest of the experiment, held IDENTICAL.  `weakening_of' compares the
        # access structure and the strength, which leaves the outcome counted, the
        # state it is counted from and the scope tree free to move -- and a mu that
        # moved one of them fires in a window T is not being watched in, so its
        # count would vouch for the wrong thing while every check above stayed
        # green.
        for what, mine in T.context():
            theirs = dict(tests[mu].context())[what]
            if not mine:
                errors.append("%s: has no %s to hold mu(T) to" % (name, what))
            elif mine != theirs:
                errors.append("%s: mu(T)=%s has a different %s (%r vs %r) -- a "
                              "weakening may not move the experiment"
                              % (name, mu, what,
                                 theirs.replace("\n", " "), mine.replace("\n", " ")))
        if alt != "-":
            if alt not in tests:
                errors.append("%s: MuAlt=%s does not exist as a .litmus"
                              % (name, alt))
            else:
                why = weakening_of(T, tests[alt])
                if why:
                    errors.append("%s: MuAlt=%s is %s" % (name, alt, why))
    if len(body) - 1 != N_TESTS:
        errors.append("committed map holds %d rows, expected %d"
                      % (len(body) - 1, N_TESTS))
    if n_mu != N_WITH_MU:
        errors.append("committed map names a mu on %d rows, expected %d"
                      % (n_mu, N_WITH_MU))
    if n_floor != N_FLOOR:
        errors.append("committed map marks %d rows `none', expected %d"
                      % (n_floor, N_FLOOR))
    return errors


HEADER = [
    "# HetLitmus positive-control map.  GENERATED -- do not hand-edit;",
    "#   regenerate with  hetlitmus/verify/controlmap.py --emit,",
    "#   gate with        hetlitmus/verify/controlmap.py --check  (make hetlitmus-controlmap).",
    "#",
    "# Mu      = Layer-A control, CO-RUN in T's own harness: T's structural twin at the",
    "#           lattice floor (every ordering annotation dropped on both sides), on the",
    "#           SAME run/stress/C2C path, so a null on T means 'not observed on a harness",
    "#           that demonstrably produced an interleaving of this shape'.  Its count is",
    "#           REPORTED, never compared against a prediction.  `none' = T is itself at",
    "#           the floor, so no weakening can exist and the canary is the only layer.",
    "# MuAlt   = the NEAREST weakening (a maximal element of the same candidate set).",
    "#           Documentation only -- never compiled in.  `-' where the floor is also",
    "#           the nearest weakening.",
    "# MuRelaxed = the fully-relaxed companion, i.e. Mu itself on every row; the gate",
    "#           asserts the identity so the two cannot drift apart.",
    "# Canary  = Layer-B universal floor: a het MP-*-sys-relaxed instance, the only het",
    "#           shape with a published detected-weak result on GH200 (Bagchi ISMM'26 Tab 4).",
    "#           'self' = the test IS the canary.",
    "#",
    "# What --check machine-checks is the property the vouch rests on: mu(T) is",
    "# STRUCTURALLY IDENTICAL to T (same procs, devices and ordered accesses -- a pure",
    "# ordering weakening, not another program), STRICTLY WEAKER componentwise on the",
    "# (cpu,gpu) strength lattice, at the floor of it, annotated with the same scopes,",
    "# and identical to T in the rest of the experiment: same init block, same",
    "# `scopes:' tree and same condition, so it counts T's outcome and not another.",
    "#",
    "# " + HEADER_LINE,
]


def header_for_lattice():
    """The AMD map is a DIFFERENT artifact from the NVIDIA one and says so in
    its first line, so the two can never be confused by a reader or a gate."""
    if LATTICE != "x86":
        return HEADER
    return ([
        "# HetLitmus AMD / MI300A positive-control map (x86 strength lattice).",
        "#   GENERATED -- do not hand-edit;  regenerate with",
        "#     hetlitmus/verify/controlmap.py --lattice x86 --emit > control-map-amd.csv",
        "#   gate with  controlmap.py --lattice x86 --check  (make hetlitmus-amd-controlmap).",
        "#",
        "# REGENERATED not translated (memo PORT2-R2 7.D11): on x86 the CPU lattice",
        "# loses its middle rung -- STLR / LDAPR / DMB.ST / DMB.LD all have a plain",
        "# MOV as their x86 image -- so a candidate that only moves within",
        "# {ra, st, ld} is NOT a weakening on MI300A and is refused here.  The floor",
        "# set is the same 78 rows as the AArch64 map's all the same: only the `-2s'",
        "# and order-pair cells carry a CPU-side ordering op, and each of those",
        "# carries a GPU-side one too, so the lost rung never holds a row off the",
        "# floor by itself.  MuAlt does move, because the NEAREST weakening does.",
        "#",
    ] + HEADER[4:])


_LOADED = {}


def load(d):
    """Every .litmus in `d', parsed under the ACTIVE lattice and memoized on
    (dir, lattice).  Both halves of the key matter: the parse is lattice-dependent
    (DMB.ST has no x86 image), and a Test is written only while it is being
    parsed, so a cache hit hands back the same corpus read the same way.  Callers
    that corrupt a corpus copy it first, into a directory of its own."""
    key = (d, LATTICE)
    if key not in _LOADED:
        tests = {}
        for f in sorted(os.listdir(d)):
            if f.endswith(".litmus"):
                t = parse_litmus(os.path.join(d, f))
                tests[t.name] = t
        _LOADED[key] = tests
    return _LOADED[key]


def floor_set(d, lattice):
    """The names at the lattice floor under `lattice', whatever LATTICE is now."""
    prev = LATTICE
    set_lattice(lattice)
    try:
        return {n for n, t in load(d).items() if t.at_floor()}
    finally:
        set_lattice(prev)


def render(rows):
    buf = io.StringIO()
    for l in header_for_lattice():
        buf.write(l + "\n")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(COLUMNS)
    for r in rows:
        w.writerow(r)
    return buf.getvalue()


def check(d, map_f, quiet=False):
    """The gate.  Returns the list of errors (empty = the map is sound)."""
    tests = load(d)
    rows, errors = derive(tests)
    text = render(rows)
    with_mu = [r for r in rows if r[1] not in ("none", "-")]

    if not quiet:
        print("===== CONTROL MAP: does every test co-run a real positive control? =====")
        print("  corpus         : %d tests in %s" % (len(tests), d))
        print("  lattice        : %s" % LATTICE)
        print("  Layer A        : %d rows co-run a lattice-floor mu(T), %d are at "
              "the floor themselves (canary only)"
              % (len(with_mu), sum(1 for r in rows if r[1] == "none")))
        print("  Layer B        : %d rows carry a canary instance, %d ARE the canary"
              % (sum(1 for r in rows if r[5] not in ("-", "self")),
                 sum(1 for r in rows if r[5] == "self")))
        print()

    # the committed table must match what we just re-derived from source, AND
    # stand on its own under audit_map (which is not a function of `rows')
    if not os.path.exists(map_f):
        errors.append("committed map %s is MISSING" % map_f)
    else:
        with open(map_f) as fh:
            on_disk = fh.read()
        if on_disk != text:
            errors.append("committed map %s is STALE -- re-run "
                          "`controlmap.py --emit > %s'" % (map_f, map_f))
        errors += audit_map(on_disk, tests)

    # fail closed: the census is asserted, not merely reported
    if len(tests) != N_TESTS:
        errors.append("the corpus holds %d tests, expected %d"
                      % (len(tests), N_TESTS))
    if len(with_mu) != N_WITH_MU:
        errors.append("%d rows name a mu, expected %d" % (len(with_mu), N_WITH_MU))
    # ...and the fact the ONE set of constants rests on: both lattices put the
    # same rows at the floor, so N_FLOOR is not silently an AArch64 number.
    fa, fx = floor_set(d, "aarch64"), floor_set(d, "x86")
    if fa != fx:
        errors.append("the lattices disagree about the floor (%d aarch64 / %d "
                      "x86; e.g. %s) -- one N_FLOOR cannot describe both"
                      % (len(fa), len(fx), sorted(fa ^ fx)[0]))
    return errors


# --- the negative control ---------------------------------------------------
# A fail-closed gate nobody has seen fail is a claim, not a check.  Each
# injection gets a FRESH scratch corpus (a stale one turns the next bite into a
# pass for the previous bite's reason), is cmp-verified to have changed the
# artifact it targets, and must produce the NAMED error -- reddening for some
# other reason is not this bite passing.
def _scratch(d, tmp, tag, map_base):
    """A private copy of corpus + map to corrupt.  `map_base' is the lattice's
    own map file, so the x86 arm copies and corrupts the AMD map rather than the
    AArch64 one sitting beside it.  The parse cache is dropped as the belt to the
    fresh directory's braces: a corrupted corpus is never read through an entry
    made before it was corrupted.  The cache key stays (dir, lattice) -- load()
    reads .litmus files and no map, so which CSV check() opens is not part of
    what is memoized."""
    _LOADED.clear()
    dst = os.path.join(tmp, tag)
    os.mkdir(dst)
    for f in os.listdir(d):
        if f.endswith(".litmus") or f == map_base:
            shutil.copy(os.path.join(d, f), dst)
    return dst


def _sub_mu(path, test, new_mu):
    """Repoint ONE row's Mu field.  Anchored on the row's first field rather than
    on a substring: `<test>,<mu>,' also occurs inside the MuAlt/MuRelaxed pair of
    OTHER rows, so a plain replace() silently corrupts a row the bite never named
    and the injection then reddens for the wrong reason."""
    lines = open(path).read().splitlines()
    hit = False
    for i, l in enumerate(lines):
        f = l.split(",")
        if f and f[0] == test and len(f) == len(COLUMNS):
            if f[1] == new_mu:
                return False
            f[1] = new_mu
            lines[i] = ",".join(f)
            hit = True
            break
    if not hit:
        return False
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return True


LEGACY_HEADER = "Test,Expected,Mu,MuExpected,MuRule,MuAlt,MuRelaxed,Canary"


def _make_legacy(path):
    """Rewrite a map into the retired 8-column schema, in place.  False when the
    header was not there to replace, i.e. the injection changed nothing."""
    lines = open(path).read().splitlines()
    if HEADER_LINE not in lines:
        return False
    out = []
    for l in lines:
        if l == HEADER_LINE:
            out.append(LEGACY_HEADER)
        elif l.startswith("#") or not l:
            out.append(l)
        else:
            f = l.split(",")
            out.append(",".join([f[0], "Allowed", f[1], "Allowed"] + f[2:]))
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    return True


def bite(d, map_base):
    print("===== --bite: the control map's OWN negative control (lattice: %s, "
          "map: %s) =====" % (LATTICE, map_base))
    tmp = tempfile.mkdtemp(prefix="controlmap-bite.")
    fails = 0
    try:
        base = _scratch(d, tmp, "clean", map_base)
        errs = check(base, os.path.join(base, map_base), quiet=True)
        print("  [0] control: an untouched scratch copy -> %d error(s) (expect 0)"
              % len(errs))
        if errs:
            for e in errs:
                print("      *** %s" % e)
            fails += 1

        tests = load(base)
        with open(os.path.join(base, map_base)) as fh:
            maptext = fh.read()
        mu_rows = [r for r in csv.reader(l for l in maptext.splitlines()
                                         if not l.startswith("#"))
                   if r and r[0] != "Test" and r[1] != "none"]
        victim, mu = mu_rows[0][0], mu_rows[0][1]
        # For bite 3, pick a row whose NAIVE name-rewrite names a test that does
        # not exist -- the failure mode this module was written to prevent, and
        # the only one where rewriting the Mu column is a lie rather than a
        # coincidence.  Both naive rewrites are tried: which of `acquire' /
        # `release' is the degenerate one flips with the device cut, so keying on
        # one alone lets the search go empty while the gate stays green.
        have = {f[:-len(".litmus")] for f in os.listdir(d) if f.endswith(".litmus")}
        naive_row = None
        for r in mu_rows:
            p = split_name(r[0])
            if not p:
                continue
            for ord_tok in ("acquire", "release"):
                naive = "%s-%s-%s-%s" % (p["shape"], p["cut"], p["scope"], ord_tok)
                if naive not in have:
                    naive_row = (r[0], r[1], naive)
                    break
            if naive_row:
                break
        # For bite 2, a row whose corpus holds a structural sibling of the SAME
        # strength on the active lattice.  Which pairs qualify is what the two
        # lattices disagree about: on x86 the pair is usually one AArch64 would
        # accept as a weakening, because STLR / LDAPR / DMB.ST / DMB.LD collapse
        # to a plain MOV there (memo PORT2-R2 7.D11), so the sibling and the row
        # are then the same program.
        same_row = None
        for r in mu_rows:
            T = tests[r[0]]
            twin = sorted(m for m in tests
                          if m != r[0] and tests[m].scopes == T.scopes
                          and weakening_of(T, tests[m]) == SAME_STRENGTH)
            if twin:
                same_row = (r[0], r[1], twin[0])
                break
        # For bite 5, a row whose corpus holds a STRICTLY STRONGER structural
        # sibling: a real, hot, same-shape test that is not a weakening at all.
        strong_row = None
        for r in mu_rows:
            T = tests[r[0]]
            up = sorted(m for m in tests
                        if m != r[0] and tests[m].scopes == T.scopes
                        and weakening_of(tests[m], T) is None)
            if up:
                strong_row = (r[0], r[1], up[0])
                break

        def run(tag, why, edit, want):
            nonlocal fails
            sd = _scratch(d, tmp, tag, map_base)
            if not edit(sd):
                print("  [%s] *** VACUOUS BITE: the injection changed nothing" % tag)
                fails += 1
                return
            got = check(sd, os.path.join(sd, map_base), quiet=True)
            hit = [e for e in got if want in e]
            print("  [%s] %s\n        -> %d error(s); named error %s"
                  % (tag, why, len(got), "FOUND: " + hit[0] if hit else
                     "*** MISSING (wanted %r)" % want))
            if not hit:
                for e in got:
                    print("      *** %s" % e)
                fails += 1

        # 1. the mutant's own .litmus is gone: the control would be compiled out
        #    of the harness and the null on T would still print, green.
        def del_mu(sd):
            p = os.path.join(sd, mu + ".litmus")
            if not os.path.exists(p):
                return False
            os.remove(p)
            return True
        run("1", "mu(T)'s .litmus DELETED",
            del_mu, "mu(T)=%s does not exist as a .litmus" % mu)

        # 2. mu swapped for a structural sibling of the same ordering strength.
        #    Every other check here stays green: the structure matches, the
        #    scopes match, no side is stronger -- and the "control" is the same
        #    program as T on this lattice, so it fires exactly when T does and
        #    vouches for nothing.  This is the rejection the second lattice
        #    exists for, and nothing else in this gate reaches it.
        if same_row is None:
            print("  [2] *** no row has a structural sibling of identical "
                  "strength: the not-a-weakening-at-all path cannot be bitten "
                  "on this corpus")
            fails += 1
        else:
            t2, m2, same2 = same_row
            run("2", "%s: mu(T) swapped for a sibling of IDENTICAL strength "
                     "(%s -> %s)" % (t2, m2, same2),
                lambda sd: _sub_mu(os.path.join(sd, map_base), t2, same2),
                "mu(T)=%s is %s" % (same2, SAME_STRENGTH))

        # 3. the map row rewritten from the test's NAME instead of derived --
        #    the exact mistake this module exists to prevent (the naive
        #    `acqrel-2s -> acquire' rewrite names a test that does not exist).
        if naive_row is None:
            print("  [3] *** no row with a mu has a nonexistent naive rewrite: "
                  "the name-rewrite path cannot be bitten on this corpus")
            fails += 1
        else:
            t3, m3, naive3 = naive_row
            run("3", "the Mu column rewritten from the test's NAME (%s -> %s)"
                     % (m3, naive3),
                lambda sd: _sub_mu(os.path.join(sd, map_base), t3, naive3),
                "%s does not exist as a .litmus" % naive3)

        # 4. mu swapped for a test of another SHAPE: still a real, hot test --
        #    just not a weakening of THIS program.
        def swap_shape(sd):
            other = "MP-cg-sys-relaxed" if not victim.startswith("MP-") \
                    else "SB-cg-sys-relaxed"
            if not os.path.exists(os.path.join(sd, other + ".litmus")):
                return False
            return _sub_mu(os.path.join(sd, map_base), victim, other)
        run("4", "mu(T) swapped for a test of a DIFFERENT shape",
            swap_shape, "access structure differs")

        # 5. mu swapped for a STRICTLY STRONGER structural sibling: same shape,
        #    same scopes, same locations -- and no weakening at all, so it may
        #    never fire and every null it gates is discarded rather than vouched.
        if strong_row is None:
            print("  [5] *** no row has a strictly stronger structural sibling: "
                  "the not-a-weakening path cannot be bitten on this corpus")
            fails += 1
        else:
            t5, m5, up5 = strong_row
            run("5", "%s: mu(T) swapped for a STRICTLY STRONGER sibling (%s -> %s)"
                     % (t5, m5, up5),
                lambda sd: _sub_mu(os.path.join(sd, map_base), t5, up5),
                "not weaker (cpu,gpu strength")

        # 6. THE LEGACY 8-COLUMN MAP, refused END TO END.  Its field 2 was a
        #    verdict and its canary was field 8; read with this schema's column
        #    meanings the Mu column would be a verdict string.  Both readers must
        #    refuse the header rather than mis-bind it -- this gate, and the
        #    emitter's own reader, which is the one whose silence would ship.
        legacy = _scratch(d, tmp, "6a", map_base)
        lm = os.path.join(legacy, map_base)
        if not _make_legacy(lm):
            print("  [6a] *** VACUOUS BITE: %s carries no %r header to replace"
                  % (map_base, HEADER_LINE))
            fails += 1
        got = check(legacy, lm, quiet=True)
        want = "header line is"
        hit = [e for e in got if want in e]
        print("  [6a] the LEGACY 8-column map fed to --check\n"
              "        -> %d error(s); named error %s"
              % (len(got), "FOUND: " + hit[0] if hit else
                 "*** MISSING (wanted %r)" % want))
        if not hit:
            fails += 1
        # ...and the emitter's reader, on a map of the same schema.  A gate that
        # refuses a schema the harness would happily mis-read protects nothing.
        # Under --lattice x86 the rendering fed to it comes out of X86_FIXTURE,
        # whose definition says which map name that makes litmus7 ask for.
        emit_src = os.path.abspath(X86_FIXTURE) if LATTICE == "x86" else d
        emit_tgt = "hip" if LATTICE == "x86" else "cuda"
        emit = _scratch(emit_src, tmp, "6b", map_base)
        emit_victim = (victim if emit_src == d else
                       sorted(f[: -len(".litmus")] for f in os.listdir(emit_src)
                              if f.endswith(".litmus"))[0])
        l7 = os.path.abspath(LITMUS7)
        if not _make_legacy(os.path.join(emit, map_base)):
            print("  [6b] *** VACUOUS BITE: %s/%s carries no header to replace"
                  % (emit_src, map_base))
            fails += 1
        elif not os.access(l7, os.X_OK):
            print("  [6b] *** litmus7 is not built (%s) -- the end-to-end half of "
                  "this bite cannot run, and a bite that skips is not a bite" % l7)
            fails += 1
        else:
            r = subprocess.run(
                [l7, "-gpu-target", emit_tgt, "-set-libdir", os.path.abspath(LIBDIR),
                 "-o", emit, os.path.join(emit, emit_victim + ".litmus")],
                cwd=emit, capture_output=True, text=True)
            said = r.stdout + r.stderr
            # The refusal has to be the HEADER's.  Three fatal paths in
            # litmus/hetControlMap.ml name this file -- a wrong header, a row of
            # the wrong width, a map with no rows -- and the 8-column file trips
            # the second one on its own once the first is gone, so an exit code
            # plus the file name would report the header gate as alive after it
            # had been deleted.  [6a] asks its own reader for the same property.
            want_e = "header is"
            ok = (r.returncode != 0 and map_base in said and want_e in said)
            last = said.strip().splitlines()[-1][:160] if said.strip() else "(silence)"
            print("  [6b] the same schema fed to the EMITTER's reader (%s, "
                  "-gpu-target %s)\n        -> exit %d; %s"
                  % (emit_victim, emit_tgt, r.returncode,
                     "REFUSED: " + last if ok else
                     "*** NOT REFUSED FOR ITS HEADER (wanted %r): %s"
                     % (want_e, last)))
            if not ok:
                fails += 1

        # 7. mu(T) keeps every access and every annotation and counts a DIFFERENT
        #    OUTCOME.  Nothing else here sees it: the structure matches, the
        #    strength is still the floor and the scopes are still T's -- and the
        #    control now fires in a window T is not being watched in.
        def move_cond(sd):
            p = os.path.join(sd, mu + ".litmus")
            src = open(p).read()
            m = re.search(r"^(\s*exists\b.*)$", src, re.M)
            if not m:
                return False
            new = re.sub(r"=(\d+)", lambda g: "=%d" % (int(g.group(1)) + 7),
                         m.group(1), count=1)
            if new == m.group(1):
                return False
            with open(p, "w") as fh:
                fh.write(src[:m.start(1)] + new + src[m.end(1):])
            return True
        run("7", "%s: mu(T)=%s counts a DIFFERENT outcome (its `exists' moved)"
                 % (victim, mu),
            move_cond, "%s: mu(T)=%s has a different condition" % (victim, mu))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if fails:
        print("\nCONTROLMAP BITE FAILED: %d injection(s) did not redden the gate "
              "for the right reason" % fails)
        return 1
    print("\nCONTROLMAP BITE OK: every injection reddens --check, by name")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--map", default=None)
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--bite", action="store_true")
    ap.add_argument("--lattice", default="aarch64", choices=sorted(LATTICES),
                    help="aarch64 = GH200 (default); x86 = MI300A, memo 7.D11")
    a = ap.parse_args()

    set_lattice(a.lattice)
    d = os.path.abspath(a.dir)
    dflt_map = map_basename(a.lattice)
    map_f = a.map or os.path.join(d, dflt_map)

    if a.emit:
        rows, errors = derive(load(d))
        sys.stdout.write(render(rows))
        for e in errors:
            print("  *** %s" % e, file=sys.stderr)
        return 0 if not errors else 1

    if a.check:
        errors = check(d, map_f)
        if errors:
            print()
            for e in errors:
                print("  *** %s" % e)
            print("\nCONTROLMAP FAILED: %d error(s).  A missing control is not a "
                  "skipped control -- it is an unfalsifiable null." % len(errors))
            return 1
        print("\nCONTROLMAP OK")
        return 0

    if a.bite:
        # --bite corrupts scratch copies of the lattice's own artifact, so it
        # takes the default map name rather than --map's arbitrary path.
        return bite(d, dflt_map)

    ap.error("one of --emit / --check / --bite is required")


if __name__ == "__main__":
    sys.exit(main())
