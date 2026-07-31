#!/usr/bin/env python3
"""HetLitmus B6 -- the positive-control map (Layer A mutant + Layer B canary).

Q4-positive-control.md 2.3/2.4.  For each should-be-FORBIDDEN het test T we
co-run its nearest ALLOWED grid neighbour mu(T) -- an MC-Mutants "Weakening sw"
mutant that already exists in the corpus -- so that a `target_count = 0' on T is
promoted from an uninterpretable empty histogram to a credible non-observation.

    "When testing, it is impossible to tell if an unobserved illegal execution
     is not allowed or if it is simply rare and was not exposed by the tests."
        -- MC Mutants (Levine et al., ASPLOS'23) 1.1, p.474.

WHY THIS FILE EXISTS AT ALL (read before "simplifying" it).
mu(T) CANNOT be computed by rewriting T's name.  The one-sided grid variants are
named for the op THE GPU PERFORMS, and the GPU's role flips with the device cut:
`acquire' annotates only reads and `release' only writes (tests/_grid_lib.sh
ord_for), so a variant whose GPU proc has no access of that kind is DEGENERATE
(byte-identical to its `relaxed' sibling) and generate.sh content-dedups it away.
Consequently

    MP-gc-sys-acquire   DOES NOT EXIST        (MP-gc's GPU proc is write-only)
    S-gc-sys-acquire    DOES NOT EXIST        (S-gc's  GPU proc is write-only)
    R-gc-sys-acquire    DOES NOT EXIST        (R-gc's  GPU proc is write-only)

and a naive `acqrel-2s -> acquire' rewrite silently names a NONEXISTENT test for
2 of the 16.  A silently-missing control is the worst failure available here: the
null still prints, still looks green, and is now unfalsifiably wrong.  So the map
is DERIVED from the corpus sources + the oracle and GATED (--check), and the gate
FAILS CLOSED: a missing or non-Allowed mutant breaks the build, it never skips
the control.

Usage:
    controlmap.py --emit  [--dir D] [--oracle F]   > control-map.csv
    controlmap.py --check [--dir D] [--oracle F] [--map F]     (the gate)
"""

import argparse
import csv
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "tests", "het")

# The Disallowed census the gate ASSERTS (it is not merely reported).
#   Q10 : 16 -> 38 = the 16 pre-existing `-{acqrel,fence}-2s' rows + 22 of the
#         48 two-sided order-pair cells the off-diagonal sweep added.
#   Q10b: 38 -> 53 = + 15 of the 64 cells the unblocked CPU fence axis
#         (DMB.ST/DMB.LD) added -- MP-cg/S-cg st.{ra,sc,acq} and
#         MP-gc/S-gc/LB-cg ld.{ra,sc,rel}, i.e. exactly the cells where a
#         PARTIAL CPU barrier is the half its role needs.
# Derivations in env-research/impl-briefs/Q10-REPORT.md and Q10b-REPORT.md.
N_DISALLOWED = 53

# ---------------------------------------------------------------------------
# THE PER-SIDE ORDERING-STRENGTH LATTICE.  mu(T) must be strictly weaker
# COMPONENTWISE (cpu,gpu) and structurally identical to T (same procs, same
# devices, same ordered (kind,location) access list) -- a pure ordering
# weakening, not a different program.
#
# NOT a count of primitives -- `acqrel' carries MORE primitives than `fence'
# (STLR+LDAPR / acquire+release vs one DMB.SY / one fence.sc.sys) yet is strictly
# WEAKER, because RCpc release/acquire does not order store->load where an SC
# fence does (that is exactly why SB/R-*-acqrel-2s are Allowed while their
# fence-2s siblings are Disallowed).
#
# Q10 REFINEMENT.  A bare "is it a fence?" tier stopped working the moment the
# two-sided family grew past one fence pairing: `f[release,sys]' is a fence but
# is strictly WEAKER than the `w[release]/r[acquire]' annotation pair, and
# DMB.ST / DMB.LD are incomparable with each other.  So a side's strength is the
# PAIR (tier, ord):
#
#   tier  2 SC-capable   DMB SY / DSB SY ; f[sc,..] ; an `sc'-tagged access
#         1 partial      anything that orders SOMETHING but cannot stand in for
#                        an SC fence: STLR / LDAPR / LDAR ; w[release] /
#                        r[acquire] ; f[release,..] / f[acquire,..] ; DMB ST/LD
#         0 plain        STR / LDR ; [relaxed,..]
#   ord   the union, over that device's ops, of the program-order pairs
#         {WW,RR,WR,RW} they order INSIDE their own thread -- machine-checked in
#         hetlitmus/verify/ordercheck.py against herd7's native AArch64 model
#         and nvidia-ptx.cat (192 solver cells):
#             DMB SY / f[sc]        {WW RR WR RW}
#             STLR   / w[release]   {WW RW}        (orders * -> W)
#             LDAPR  / r[acquire]   {RR RW}        (orders R -> *)
#             f[release,sys]        {WW RW}        f[acquire,sys]  {RR RW}
#             DMB ST {WW}           DMB LD {RR RW}
#
# `weaker-or-equal' is  (t1,o1) <= (t2,o2)  iff  t1 < t2, or t1 == t2 and
# o1 subset-of o2.  This keeps DMB.ST and DMB.LD INCOMPARABLE, and it keeps
# f[release] and r[acquire]-annotated reads incomparable -- neither is a
# weakening of the other, and a control that is not a weakening vouches for
# nothing.
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

# Q10 two-sided ORDER-PAIR grid `<cpu>.<gpu>'.  Candidate weakenings, tried in
# this order: weaken the GPU axis, then the CPU axis, then fall back to the
# ONE-SIDED grid cell named for the role the GPU half played (which drops the CPU
# half of the pair AND demotes the GPU primitive to an annotated access).  Every
# candidate is still put through the SAME structural + strictly-weaker check as
# the final mu, so a candidate that is not actually a weakening ON THIS SHAPE is
# skipped rather than crowned: e.g. on MP-cg the GPU proc is read;read, so
# f[release,sys] orders {WW,RW} and the r[acquire] annotation orders {RR,RW} --
# incomparable, not a weakening.
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
        """The two properties the vouch rests on, applied at CANDIDATE-selection
        time so a non-weakening is skipped instead of becoming a hard error."""
        T, M = tests[tname], tests[cand]
        if T.structure() != M.structure():
            return False
        ts, ms = T.strength(), M.strength()
        return side_le(ms[0], ts[0]) and side_le(ms[1], ts[1]) and ms != ts

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
                # Q10 fence-pair cell.  Weaken ONE axis and keep everything else,
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
                have = [x for x in cands if allowed(x) and usable(name, x)]
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
                # Weaken the primitive UNDER TEST: SC fence -> RCpc release/acquire,
                # keeping the two-sided cross-device pair intact.  Where that is
                # itself still Disallowed (MP/S/LB), fall back to dropping the CPU
                # half of the pair.
                cand = base + "-acqrel-2s"
                if allowed(cand):
                    mu, rule = cand, "fence-2s->acqrel-2s (SC fence -> RCpc rel/acq; pair kept)"
                else:
                    mu, rule = base + "-fence", "fence-2s->fence (drop CPU DMB.SY; GPU fence kept)"
            elif parts["order"] == "acqrel" and parts["two"]:
                # Drop the CPU half of the morally-strong pair.  The surviving
                # one-sided cell is named for the op the GPU still performs, and
                # the grid has NO one-sided `acqrel' cell -- so where the GPU proc
                # performs both a read and a write (LB/SB, and the -cg cuts of
                # R/S) BOTH -acquire and -release exist and are valid minimal
                # mutants.  Q4 2.3 names -acquire for the cases it lists; we take
                # -acquire when it exists and record the other as MuAlt.
                acq, rel = base + "-acquire", base + "-release"
                have = [c for c in (acq, rel) if allowed(c)]
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
            if mu == "-":
                errors.append("%s: NO mu(T) -- the control would be silently "
                              "MISSING (Q4 2.3)" % name)
            elif mu not in tests:
                errors.append("%s: mu(T)=%s does not exist as a .litmus"
                              % (name, mu))
            elif oracle.get(mu) != "Allowed":
                errors.append("%s: mu(T)=%s is %r, not Allowed -- a control whose "
                              "weak outcome is itself forbidden vouches for nothing"
                              % (name, mu, oracle.get(mu)))
            else:
                T, M = tests[name], tests[mu]
                if T.structure() != M.structure():
                    errors.append("%s: mu(T)=%s is not a pure ORDERING weakening "
                                  "(access structure differs)" % (name, mu))
                ts, ms = T.strength(), M.strength()
                if not (side_le(ms[0], ts[0]) and side_le(ms[1], ts[1])
                        and ms != ts):
                    errors.append("%s: mu(T)=%s is not strictly weaker "
                                  "(cpu,gpu strength %s vs %s)"
                                  % (name, mu, _pp(ms), _pp(ts)))
                if not T.two_sided():
                    errors.append("%s: Disallowed row is not two-sided" % name)
                mu_exp = oracle.get(mu)

            if relaxed != "-" and not allowed(relaxed):
                errors.append("%s: relaxed companion %s missing/not Allowed"
                              % (name, relaxed))

        rows.append((name, exp, mu, mu_exp, rule, alt, relaxed, canary))

    return rows, errors


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--oracle", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    d = os.path.abspath(a.dir)
    oracle_f = a.oracle or os.path.join(d, "expected-nvidia.csv")
    map_f = a.map or os.path.join(d, "control-map.csv")

    tests = {}
    for f in sorted(os.listdir(d)):
        if f.endswith(".litmus"):
            t = parse_litmus(os.path.join(d, f))
            tests[t.name] = t
    oracle = load_oracle(oracle_f)

    rows, errors = derive(tests, oracle)

    buf = io.StringIO()
    for l in HEADER:
        buf.write(l + "\n")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["Test", "Expected", "Mu", "MuExpected", "MuRule",
                "MuAlt", "MuRelaxed", "Canary"])
    for r in rows:
        w.writerow(r)
    text = buf.getvalue()

    if a.emit:
        sys.stdout.write(text)
        return 0 if not errors else 1

    if a.check:
        print("===== B6 CONTROL MAP: does every Disallowed test have a real control? =====")
        dis = [r for r in rows if r[1] == "Disallowed"]
        print("  corpus         : %d tests in %s" % (len(tests), d))
        print("  oracle         : %d Allowed / %d Disallowed / %d NO-ORACLE"
              % (sum(1 for r in rows if r[1] == "Allowed"),
                 len(dis),
                 sum(1 for r in rows if r[1] == "NO-ORACLE")))
        print("  canaries       : %d rows carry a Layer-B canary"
              % sum(1 for r in rows if r[7] != "-"))
        print()
        for r in sorted(dis):
            print("  %-22s mu = %-22s [%s]  %s"
                  % (r[0], r[2], r[3], r[4]))
        print()

        # the committed table must match what we just re-derived from source
        if not os.path.exists(map_f):
            errors.append("committed map %s is MISSING" % map_f)
        else:
            with open(map_f) as fh:
                on_disk = fh.read()
            if on_disk != text:
                errors.append("committed map %s is STALE -- re-run "
                              "`controlmap.py --emit > %s'" % (map_f, map_f))

        # fail closed: the count is asserted, not merely reported
        if len(dis) != N_DISALLOWED:
            errors.append("expected %d Disallowed rows, found %d"
                          % (N_DISALLOWED, len(dis)))
        ok = sum(1 for r in dis if r[2] != "-" and r[3] == "Allowed")
        print("  MU MAP: %d/%d Disallowed tests have an existing, Allowed mu(T)"
              % (ok, len(dis)))
        if ok != len(dis):
            errors.append("only %d/%d Disallowed tests have a usable mu(T)"
                          % (ok, len(dis)))

        if errors:
            print()
            for e in errors:
                print("  *** %s" % e)
            print("\nCONTROLMAP FAILED: %d error(s).  A missing control is not a "
                  "skipped control -- it is an unfalsifiable null." % len(errors))
            return 1
        print("\nCONTROLMAP OK")
        return 0

    ap.error("one of --emit / --check is required")


if __name__ == "__main__":
    sys.exit(main())
