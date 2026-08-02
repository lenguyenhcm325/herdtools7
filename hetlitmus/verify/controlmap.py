#!/usr/bin/env python3
"""The positive-control map: the Layer-A mutant and Layer-B canary each het test
co-runs.  For a should-be-forbidden test T, mu(T) is its nearest Allowed grid
neighbour, so a `target_count = 0' on T is a non-observation on a demonstrably
hot harness rather than an uninterpretable empty histogram.  What the two layers
buy, and what "minimal" honestly means, is hetlitmus/docs/positive-control.md.

WHY THIS FILE EXISTS (read before "simplifying" it): mu(T) cannot be computed by
rewriting T's name.  The one-sided grid variants are named for the op the GPU
performs, `acquire' annotates only reads and `release' only writes
(tests/_grid_lib.sh ord_for), and the GPU's role flips with the device cut -- so
a variant whose GPU proc has no access of that kind is degenerate (byte-identical
to its `relaxed' sibling) and generate.sh dedups it away.  MP-gc-sys-acquire,
S-gc-sys-acquire and R-gc-sys-acquire therefore do not exist, and a naive
`acqrel-2s -> acquire' rewrite names a nonexistent test.  So the map is derived
from the corpus sources + the oracle and gated (--check), and the gate fails
closed: a missing or non-Allowed mutant breaks the build rather than skipping the
control, because a silently absent control does not weaken a null -- it makes it
unfalsifiable, while the null still prints and still looks green.

Usage:
    controlmap.py --emit  [--dir D] [--oracle F]   > control-map.csv
    controlmap.py --check [--dir D] [--oracle F] [--map F]     (the gate)
    controlmap.py --bite                           (the gate's negative control)
"""

import argparse
import csv
import io
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "tests", "het")

# The Disallowed census the gate asserts (it is not merely reported): the 13
# `-{acqrel,fence}-2s' rows of the matched two-sided family, + 22 of the 48
# off-diagonal order-pair cells, + 15 of the 64 cells the CPU DMB.ST/DMB.LD axis
# added -- those being exactly the cells where a PARTIAL CPU barrier is the half
# its role needs.  Derivations: env-research/impl-briefs/Q10-REPORT.md,
# Q10b-REPORT.md.
N_DISALLOWED = 50

# ---------------------------------------------------------------------------
# The per-side ordering-strength lattice.  mu(T) must be strictly WEAKER
# componentwise (cpu,gpu) and structurally identical to T -- same procs, same
# devices, same ordered (kind,location) access list: a pure ordering weakening,
# not a different program.
#
# Strength is not a count of primitives: `acqrel' carries more of them than
# `fence' (STLR+LDAPR / acquire+release vs one DMB.SY / one fence.sc.sys) yet is
# strictly weaker, because RCpc release/acquire does not order store->load where
# an SC fence does -- which is why SB/R-*-acqrel-2s are Allowed while their
# fence-2s siblings are Disallowed.  Nor is a bare "is it a fence?" tier enough:
# f[release,sys] is a fence but is weaker than the w[release]/r[acquire] pair,
# and DMB.ST / DMB.LD are incomparable with each other.  So a side's strength is
# the pair (tier, ord):
#
#   tier  2 SC-capable  DMB SY / DSB SY ; f[sc,..] ; an `sc'-tagged access
#         1 partial     orders something but cannot stand in for an SC fence:
#                       STLR / LDAPR / LDAR ; w[release] / r[acquire] ;
#                       f[release,..] / f[acquire,..] ; DMB ST / DMB LD
#         0 plain       STR / LDR ; [relaxed,..]
#   ord   the program-order pairs {WW,RR,WR,RW} that side's ops order inside
#         their own thread -- the ord(p) table of hetlitmus/docs/het-oracle.md,
#         machine-checked against herd7 by verify/ordercheck.py.
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
        return "identical ordering strength -- not a weakening at all"
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

    # -- the structural fingerprint mu(T) must match exactly ----------------
    def structure(self):
        return tuple(
            (p, self.dev[p], tuple(self.accesses[p]))
            for p in sorted(self.accesses)
        )

    def strength(self):
        return (self.cpu_strength, self.gpu_strength)

    def two_sided(self):
        return self.cpu_strength[0] > PLAIN


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

    # ---- init block: "0:X1=x;"  ->  regmap[(0,"X1")] = "x"
    regmap = {}
    in_init = False
    for l in raw:
        s = l.strip()
        if s.startswith("{"):
            in_init = True
            s = s[1:]
        if in_init:
            if "}" in s:
                s = s[: s.index("}")]
                in_init = False
            for decl in s.split(";"):
                m = re.match(r"^\s*(\d+):(\w+)\s*=\s*(\w+)\s*$", decl)
                if m:
                    regmap[(int(m.group(1)), m.group(2))] = m.group(3)

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
    if mnem in ("STLR", "STR"):
        t.accesses[p].append(("W", loc))
        if mnem == "STLR":
            t.cpu_strength = raise_side(t.cpu_strength, PART_TIER, REL_ORD)
    else:
        t.accesses[p].append(("R", loc))
        if mnem in ("LDAPR", "LDAR"):
            t.cpu_strength = raise_side(t.cpu_strength, PART_TIER, ACQ_ORD)


# ---------------------------------------------------------------------------
def load_oracle(path):
    exp = {}
    with open(path) as fh:
        for row in csv.reader(l for l in fh if not l.startswith("#")):
            if not row or row[0] == "Litmus":
                continue
            exp[row[0]] = row[1]
    return exp


NAME_RE = re.compile(r"^(?P<shape>.+?)-(?P<cut>[cg]+)-(?P<scope>cta|gpu|sys)-"
                     r"(?P<order>relaxed|acquire|release|fence|acqrel"
                     r"|(?:ra|sy|st|ld)\.(?:ra|sc|rel|acq))"
                     r"(?P<two>-2s)?$")

# Candidate weakenings for a two-sided order-pair cell `<cpu>.<gpu>', tried in
# this order: weaken the GPU axis, then the CPU axis, then fall back to the
# one-sided grid cell named for the role the GPU half played (which drops the CPU
# half of the pair and demotes the GPU primitive to an annotated access).  Every
# candidate goes through the same structural + strictly-weaker check as the final
# mu, so one that is not actually a weakening ON THIS SHAPE is skipped rather
# than crowned: on MP-cg the GPU proc is read;read, so f[release,sys] orders
# {WW,RW} while the r[acquire] annotation orders {RR,RW} -- incomparable.
FP_CPU_WEAKER = {"sy": ("ra", "st", "ld")}
FP_GPU_WEAKER = {"sc": ("ra", "rel", "acq"), "ra": ("rel", "acq")}
FP_ONESIDED = {"ra":  ("acquire", "release"),
               "sc":  ("acquire", "release"),
               "rel": ("release", "acquire"),
               "acq": ("acquire", "release")}


def split_name(name):
    m = NAME_RE.match(name)
    return m.groupdict() if m else None


def derive(tests, oracle):
    """The map.  Returns rows [(test, expected, mu, mu_expected, rule, alt,
    relaxed, canary)] and a list of hard errors (which make the gate fail)."""
    rows, errors = [], []

    def allowed(n):
        return n in tests and oracle.get(n) == "Allowed"

    def usable(tname, cand):
        """The vouch's properties, applied at candidate-selection time so a
        non-weakening is skipped instead of becoming a hard error.  EVERY branch
        below selects through this, so no branch crowns an unchecked mu."""
        return allowed(cand) and weakening_of(tests[tname], tests[cand]) is None

    for name in sorted(tests):
        exp = oracle.get(name, "?")
        parts = split_name(name)

        # ---- Layer B: the universal canary.  MP is the only het shape with a
        # published detected-weak het result (Bagchi ISMM'26 Table 4), so it is
        # the robust floor.  Match T's C2C DIRECTION where T has one, so the
        # canary crosses the interconnect the same way round.
        cut = parts["cut"] if parts else None
        canary = "MP-%s-sys-relaxed" % cut if cut in ("cg", "gc") else "MP-cg-sys-relaxed"
        if not allowed(canary):
            errors.append("canary %s for %s does not exist or is not Allowed"
                          % (canary, name))
        if canary == name:
            canary = "self"          # T IS the canary; it is its own liveness signal

        mu = mu_exp = rule = alt = relaxed = "-"

        if exp == "Disallowed":
            if parts is None:
                errors.append("%s: Disallowed but its name does not fit the grid"
                              % name)
                rows.append((name, exp, "-", "-", "-", "-", "-", canary))
                continue

            base = "%s-%s-%s" % (parts["shape"], parts["cut"], parts["scope"])
            relaxed = base + "-relaxed"

            if "." in parts["order"] and parts["two"]:
                # Order-pair cell.  Weaken ONE axis and keep everything else,
                # preferring the GPU axis (the primitive whose scope reach is the
                # thing under test); fall back to the one-sided cell named for
                # the GPU fence's role.  Candidates that are themselves not
                # Allowed (Disallowed, or NO-ORACLE where the two formalisations
                # disagree) are skipped -- a control whose own weak outcome is
                # forbidden or unmodelled vouches for nothing.
                c, g = parts["order"].split(".")
                cands = ["%s-%s.%s-2s" % (base, c, g2)
                         for g2 in FP_GPU_WEAKER.get(g, ())]
                cands += ["%s-%s.%s-2s" % (base, c2, g)
                          for c2 in FP_CPU_WEAKER.get(c, ())]
                cands += ["%s-%s" % (base, o) for o in FP_ONESIDED[g]]
                have = [x for x in cands if usable(name, x)]
                if have:
                    mu = have[0]
                    if mu.endswith("-2s"):
                        rule = ("%s.%s-2s->%s (weaken ONE axis; pair kept)"
                                % (c, g, mu.rsplit("-", 2)[-2]))
                    else:
                        rule = ("%s.%s-2s->%s (drop the CPU half; keep the GPU "
                                "%s half)" % (c, g, mu.rsplit("-", 1)[-1],
                                              mu.rsplit("-", 1)[-1]))
                    alt = have[1] if len(have) > 1 else "-"
            elif parts["order"] == "fence" and parts["two"]:
                # Weaken the primitive under test: SC fence -> RCpc rel/acq, with
                # the two-sided cross-device pair intact.  Where that is itself
                # still Disallowed (MP/S/LB), fall back to dropping the CPU half
                # of the pair.
                cand = base + "-acqrel-2s"
                if usable(name, cand):
                    mu, rule = cand, "fence-2s->acqrel-2s (SC fence -> RCpc rel/acq; pair kept)"
                elif usable(name, base + "-fence"):
                    mu, rule = base + "-fence", "fence-2s->fence (drop CPU DMB.SY; GPU fence kept)"
            elif parts["order"] == "acqrel" and parts["two"]:
                # Drop the CPU half of the morally-strong pair.  The surviving
                # one-sided cell is named for the op the GPU still performs, and
                # the grid has no one-sided `acqrel' cell -- so where the GPU proc
                # performs both a read and a write (LB/SB, and the -cg cuts of
                # R/S) both -acquire and -release exist and are equally minimal.
                # Q4 2.3 names -acquire for the cases it lists; take -acquire
                # where it exists and record the other as MuAlt.
                acq, rel = base + "-acquire", base + "-release"
                have = [c for c in (acq, rel) if usable(name, c)]
                if acq in have:
                    mu, rule = acq, "acqrel-2s->acquire (drop CPU half; GPU acquire kept)"
                elif rel in have:
                    mu, rule = rel, "acqrel-2s->release (drop CPU half; GPU release kept)"
                others = [c for c in have if c != mu]
                alt = others[0] if others else "-"
            else:
                errors.append("%s: Disallowed but not a *-2s fence/acqrel row"
                              % name)

            # ---- the fail-closed gate proper ------------------------------
            # Every branch above crowns mu only through usable(), so re-testing
            # existence / Allowed / structure / strictly-weaker on what was just
            # selected is constant-False -- an assertion that cannot fire is not
            # a gate.  The one thing selection can still leave broken is that
            # NOTHING survived it, which is what this asserts.  The properties
            # themselves are re-asserted by audit_map() against the COMMITTED
            # map, independently of this derivation, where a hand-edit or a
            # name-rewritten mu row can and does trip them.
            if mu == "-":
                errors.append("%s: NO mu(T) -- the control would be silently "
                              "MISSING (Q4 2.3)" % name)
            else:
                mu_exp = oracle.get(mu)

            if not allowed(relaxed):
                errors.append("%s: relaxed companion %s missing/not Allowed"
                              % (name, relaxed))

        rows.append((name, exp, mu, mu_exp, rule, alt, relaxed, canary))

    return rows, errors


def audit_map(text, tests, oracle):
    """Re-audit the map AS A COMMITTED ARTIFACT, not as something just derived.

    derive() enforces the vouch's properties when it SELECTS mu, so asserting
    them again on its own choice proves nothing.  This reads the CSV back and
    asserts them on the rows it actually holds -- the check that survives a
    hand-edit, a half-applied regeneration, or the exact mistake the module
    docstring warns about (a Mu column rewritten from the test's NAME, naming a
    grid cell that does not exist).  Those trip it by NAME of the broken
    property; the byte-comparison against a fresh derivation can only say
    'STALE'."""
    errors, n_dis = [], 0
    for row in csv.reader(l for l in text.splitlines() if not l.startswith("#")):
        if not row or row[0] == "Test":
            continue
        name, exp, mu, mu_exp, _rule, _alt, relaxed, canary = row[:8]
        if canary != "self" and oracle.get(canary) != "Allowed":
            errors.append("%s: canary %s is not an Allowed test" % (name, canary))
        if exp != "Disallowed":
            continue
        n_dis += 1
        if name not in tests:
            errors.append("%s: Disallowed row names no .litmus" % name)
            continue
        if not tests[name].two_sided():
            errors.append("%s: Disallowed row is not two-sided" % name)
        if oracle.get(relaxed) != "Allowed":
            errors.append("%s: relaxed companion %s missing/not Allowed"
                          % (name, relaxed))
        if mu not in tests:
            errors.append("%s: mu(T)=%s does not exist as a .litmus" % (name, mu))
            continue
        if oracle.get(mu) != "Allowed":
            errors.append("%s: mu(T)=%s is %r, not Allowed -- a control whose weak "
                          "outcome is itself forbidden vouches for nothing"
                          % (name, mu, oracle.get(mu)))
        if mu_exp != oracle.get(mu):
            errors.append("%s: MuExpected column says %r, the oracle says %r"
                          % (name, mu_exp, oracle.get(mu)))
        why = weakening_of(tests[name], tests[mu])
        if why:
            errors.append("%s: mu(T)=%s is %s" % (name, mu, why))
    if n_dis != N_DISALLOWED:
        errors.append("committed map holds %d Disallowed rows, expected %d"
                      % (n_dis, N_DISALLOWED))
    return errors


HEADER = [
    "# HetLitmus B6 positive-control map.  GENERATED -- do not hand-edit;",
    "#   regenerate with  hetlitmus/verify/controlmap.py --emit,",
    "#   gate with        hetlitmus/verify/controlmap.py --check  (make hetlitmus-controlmap).",
    "#",
    "# Mu      = Layer-A minimal-mutant control: the nearest ALLOWED grid neighbour of a",
    "#           Disallowed test, co-run on the SAME run/stress/C2C path so that a null on",
    "#           T means 'not observed on a demonstrably hot harness' rather than nothing",
    "#           at all (Q4 2.3/2.4; MC-Mutants ASPLOS'23 'Weakening sw' mutator, Table 2).",
    "# Canary  = Layer-B universal floor: a het MP-*-sys-relaxed instance, the only het",
    "#           shape with a published detected-weak result on GH200 (Bagchi ISMM'26 Tab 4).",
    "#           'self' = the test IS the canary.",
    "# MuAlt   = the OTHER equally-minimal mutant, where the grid contains two (see below).",
    "# MuRelaxed = the fully-relaxed companion; the documented HW fallback for Layer A if the",
    "#           minimal mutant cannot be driven to tau_hot (Q4 8.3).  Hardware-only choice.",
    "#",
    "# HONEST SCOPE OF 'minimal'.  Q4 calls these single-edge mutants.  At the grid's",
    "# granularity the cell-adjacent neighbour is the smallest weakening AVAILABLE, but it is",
    "# not always literally one edge: 'acqrel-2s -> acquire' drops the CPU half of the pair AND",
    "# the GPU's release (the grid has no one-sided 'acqrel' cell), and 'fence-2s -> acqrel-2s'",
    "# weakens both sides from SC fence to RCpc rel/acq.  What IS machine-checked (--check) is",
    "# the property the vouch actually rests on: mu(T) is STRUCTURALLY IDENTICAL to T (same",
    "# procs, devices and ordered accesses -- a pure ordering weakening, not another program)",
    "# and STRICTLY WEAKER componentwise on the (cpu,gpu) strength lattice.",
    "#",
    "# Test,Expected,Mu,MuExpected,MuRule,MuAlt,MuRelaxed,Canary",
]


def load(d, oracle_f):
    tests = {}
    for f in sorted(os.listdir(d)):
        if f.endswith(".litmus"):
            t = parse_litmus(os.path.join(d, f))
            tests[t.name] = t
    return tests, load_oracle(oracle_f)


def render(rows):
    buf = io.StringIO()
    for l in HEADER:
        buf.write(l + "\n")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["Test", "Expected", "Mu", "MuExpected", "MuRule",
                "MuAlt", "MuRelaxed", "Canary"])
    for r in rows:
        w.writerow(r)
    return buf.getvalue()


def check(d, oracle_f, map_f, quiet=False):
    """The gate.  Returns the list of errors (empty = the map is sound)."""
    tests, oracle = load(d, oracle_f)
    rows, errors = derive(tests, oracle)
    text = render(rows)
    dis = [r for r in rows if r[1] == "Disallowed"]

    if not quiet:
        print("===== B6 CONTROL MAP: does every Disallowed test have a real control? =====")
        print("  corpus         : %d tests in %s" % (len(tests), d))
        print("  oracle         : %d Allowed / %d Disallowed / %d NO-ORACLE"
              % (sum(1 for r in rows if r[1] == "Allowed"),
                 len(dis),
                 sum(1 for r in rows if r[1] == "NO-ORACLE")))
        print("  canaries       : %d rows carry a Layer-B canary"
              % sum(1 for r in rows if r[7] != "-"))
        print()
        for r in sorted(dis):
            print("  %-22s mu = %-22s [%s]  %s" % (r[0], r[2], r[3], r[4]))
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
        errors += audit_map(on_disk, tests, oracle)

    # fail closed: the count is asserted, not merely reported
    if len(dis) != N_DISALLOWED:
        errors.append("expected %d Disallowed rows, found %d"
                      % (N_DISALLOWED, len(dis)))
    if not quiet:
        # summary only: every row that could lower it has already filed its own
        # error above, so this line reports, it does not decide
        ok = sum(1 for r in dis if r[2] != "-" and r[3] == "Allowed")
        print("  MU MAP: %d/%d Disallowed tests have an existing, Allowed mu(T)"
              % (ok, len(dis)))
    return errors


# --- the negative control ---------------------------------------------------
# Until 2026-08-02 this gate had none: no --bite, no selftest section, no cram
# negative.  A fail-closed gate nobody has seen fail is a claim, not a check.
# Each injection gets a FRESH scratch corpus (a stale one turns the next bite
# into a pass for the previous bite's reason), is cmp-verified to have changed
# the artifact it targets, and must produce the NAMED error -- reddening for
# some other reason is not this bite passing.
def _scratch(d, tmp, tag):
    """A private copy of corpus + oracle + map to corrupt."""
    dst = os.path.join(tmp, tag)
    os.mkdir(dst)
    for f in os.listdir(d):
        if f.endswith(".litmus") or f in ("expected-nvidia.csv", "control-map.csv"):
            shutil.copy(os.path.join(d, f), dst)
    return dst


def _sub(path, old, new):
    """Rewrite `path', returning False if the edit was a no-op (vacuous bite)."""
    with open(path) as fh:
        s = fh.read()
    if old not in s or old == new:
        return False
    with open(path, "w") as fh:
        fh.write(s.replace(old, new, 1))
    return True


def bite(d):
    print("===== --bite: the control map's OWN negative control =====")
    tmp = tempfile.mkdtemp(prefix="controlmap-bite.")
    fails = 0
    try:
        base = _scratch(d, tmp, "clean")
        errs = check(base, os.path.join(base, "expected-nvidia.csv"),
                     os.path.join(base, "control-map.csv"), quiet=True)
        print("  [0] control: an untouched scratch copy -> %d error(s) (expect 0)"
              % len(errs))
        if errs:
            for e in errs:
                print("      *** %s" % e)
            fails += 1

        # real Disallowed rows and their derived mutants, read from the map
        with open(os.path.join(base, "control-map.csv")) as fh:
            maptext = fh.read()
        dis_rows = [r for r in csv.reader(l for l in maptext.splitlines()
                                          if not l.startswith("#"))
                    if r and r[1] == "Disallowed"]
        victim, mu = dis_rows[0][0], dis_rows[0][2]
        # For bite 3, pick a row whose NAIVE name-rewrite names a test that does
        # not exist -- the failure mode this module was written to prevent, and
        # the only one where rewriting the Mu column is a lie rather than a
        # coincidence.  Rewriting it on a row where the naive name happens to be
        # the right answer would be a vacuous bite.
        have = {f[:-len(".litmus")] for f in os.listdir(d) if f.endswith(".litmus")}
        naive_row = None
        for r in dis_rows:
            p = split_name(r[0])
            if not p:
                continue
            naive = "%s-%s-%s-acquire" % (p["shape"], p["cut"], p["scope"])
            if naive not in have:
                naive_row = (r[0], r[2], naive)
                break

        def run(tag, why, edit, want):
            nonlocal fails
            sd = _scratch(d, tmp, tag)
            if not edit(sd):
                print("  [%s] *** VACUOUS BITE: the injection changed nothing" % tag)
                fails += 1
                return
            got = check(sd, os.path.join(sd, "expected-nvidia.csv"),
                        os.path.join(sd, "control-map.csv"), quiet=True)
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

        # 2. the mutant relabelled Disallowed: a control whose own weak outcome
        #    is forbidden vouches for nothing.
        run("2", "mu(T) relabelled Disallowed in the oracle",
            lambda sd: _sub(os.path.join(sd, "expected-nvidia.csv"),
                            "%s,Allowed," % mu, "%s,Disallowed," % mu),
            "not Allowed -- a control whose weak")

        # 3. the map row rewritten from the test's NAME instead of derived --
        #    the exact mistake this module exists to prevent (the naive
        #    `acqrel-2s -> acquire' rewrite names a test that does not exist).
        if naive_row is None:
            print("  [3] *** no Disallowed row has a nonexistent naive rewrite: "
                  "the name-rewrite path cannot be bitten on this corpus")
            fails += 1
        else:
            t3, m3, naive3 = naive_row
            run("3", "the Mu column rewritten from the test's NAME (%s -> %s)"
                     % (m3, naive3),
                lambda sd: _sub(os.path.join(sd, "control-map.csv"),
                                "%s,Disallowed,%s," % (t3, m3),
                                "%s,Disallowed,%s," % (t3, naive3)),
                "%s does not exist as a .litmus" % naive3)

        # 4. mu swapped for an Allowed test of another SHAPE: still a real,
        #    Allowed, hot test -- just not a weakening of THIS program.
        def swap_shape(sd):
            other = "MP-cg-sys-relaxed" if not victim.startswith("MP-") \
                    else "SB-cg-sys-relaxed"
            if not os.path.exists(os.path.join(sd, other + ".litmus")):
                return False
            return _sub(os.path.join(sd, "control-map.csv"),
                        "%s,Disallowed,%s," % (victim, mu),
                        "%s,Disallowed,%s," % (victim, other))
        run("4", "mu(T) swapped for an Allowed test of a DIFFERENT shape",
            swap_shape, "access structure differs")
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
    ap.add_argument("--oracle", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--bite", action="store_true")
    a = ap.parse_args()

    d = os.path.abspath(a.dir)
    oracle_f = a.oracle or os.path.join(d, "expected-nvidia.csv")
    map_f = a.map or os.path.join(d, "control-map.csv")

    if a.emit:
        tests, oracle = load(d, oracle_f)
        rows, errors = derive(tests, oracle)
        sys.stdout.write(render(rows))
        return 0 if not errors else 1

    if a.check:
        errors = check(d, oracle_f, map_f)
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
        return bite(d)

    ap.error("one of --emit / --check / --bite is required")


if __name__ == "__main__":
    sys.exit(main())
