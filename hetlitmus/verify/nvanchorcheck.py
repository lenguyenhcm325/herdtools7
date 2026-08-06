#!/usr/bin/env python3
"""nvanchorcheck.py -- the Bagchi ANCHOR gate behind tests/het/expected-nvidia.csv.

NVOR Phase D2, register open item O4.  Bagchi et al. ISMM'26 is the main and
SOLE published compound anchor source for the GH200 lane: the PLDI'23 artifact
has no x86+PTX or ARM+PTX compound rows, so the AMD lane's artifact-anchor gate
has no NVIDIA equivalent and this file had to be written from the paper.

THE DIRECTION RULE, which is the whole point of the file:

    AN OBSERVATION BINDS HARD.  A NON-OBSERVATION NEVER PROVES `Disallowed'.

Bagchi reporting that a weak behaviour WAS SEEN on GH200 silicon is positive
evidence about the machine: the corpus row of that shape and direction must be
`Allowed', and a `Disallowed' there is a false-refutation-in-waiting -- our
harness would report a violation of the compound model that the paper already
recorded as normal hardware behaviour.  That is HARD and this gate enforces it.
Bagchi NOT seeing a behaviour is a statement about a suite, a stress
configuration and a run budget.  It corroborates; it can never carry a
`Disallowed' verdict, and it can never be a row's only key.  The third category
is the one no reader supplies for themselves: what the paper CANNOT anchor at
all, pinned here as GAPs so a later citation edit cannot quietly invent an
anchor for a shape Bagchi never ran.

COVERAGE STATEMENT (printed by every run; the thesis must repeat it).
Bagchi's suite is 100 % MP-shaped, 2-thread, with the non-flag variable `X' at
`cta' or `gpu' -- NEVER at `system'.  There is no LB, S, SB, R, IRIW, 2+2W,
WRC, ISA2, RWC or WRC3 test in the paper, and no unidirectional fence anywhere
in it (triple-confirmed in Phase C: Table 2b's fence column is
"rlx, acq-rel, sc, none"; sect 4.1's 3 types x 3 scopes + 1 = 10; every
populated Table-4 fence cell).  Our corpus is 11 shapes wide, so most of it is
outside Bagchi's reach BY CONSTRUCTION -- which is a fact about the evidence,
not a defect of the corpus, and it is why so many entries below are GAPs.

WHY THIS IS A SEPARATE GATE, not a rule inside nvprovcheck.py.  R2 measured it
(Phase C counter-probe, B7): demote EVERY Bagchi fragment to NOTE and
nvprovcheck's E-rules do not move by one row, because every row citing Bagchi
also carries a PTX, ARM or CMCM key.  So Bagchi is load-bearing on ZERO rows at
citation grade -- simultaneously reassuring (a Bagchi mis-anchor cannot move a
verdict) and damning (a provenance gate structurally cannot see the anchor
question).  Wiring anchors into nvprovcheck would have been inert.  This file
imports nvprovcheck's FRAGMENTS table rather than restating it, so the two
gates cannot drift apart about what a fragment IS while disagreeing about what
it may DO.

The table below is the Phase-C brief sect 5 proposal, verified row by row
against the register and the committed CSV.  Two adjustments, both stated:

  * The brief's sizing line reads "5 HARD, 8 CORR/NOTE, 9 GAP" but its own
    table grades entry 13 (`ORDPAIR-ALLOWED-CPU', Tab 3 r6.1/6.2/7.1/7.2) CORR
    in the kind column -- "CPU-only, composite; key-grade support is
    ARM-native" -- and the parenthetical concedes it ("#13's CPU half as
    CORR").  Counting the table itself gives 4 HARD / 8 CORR / 1 NOTE / 9 GAP.
    The 4 is used here.  Promoting 13 would bind 46 rows to a CPU-only
    observation, which is exactly the over-reach the direction rule exists to
    prevent.
  * The brief predates Nguyen's adjudication, so its entries 17-20 speak of 50
    `Disallowed' rows.  The regeneration left 18, and NVOR Phase D3 left 16.
    Entry 20 is restated over the surviving surface, and entry 19's datum was
    STRUCK from the corpus
    entirely by the regeneration (R2's disposition flip: Table 3 r5.1/5.2 is a
    CPU-only absence and Table 4 "lists only the scenarios where weak
    behaviors were detected", so neither half contains a het both-sided-fence
    forbidden row).  It is kept as an entry with an ASSERTED-ABSENT datum, so
    the strike cannot be quietly undone.

Entry 14 is a HARD anchor with nothing to bind: Fig 4d observes the weak
outcome with a correctly-released, correctly-`sys`-scoped producer and a
RELAXED consumer, and the corpus's one-sided variant vocabulary annotates the
GPU side only, so no such row exists.  It is carried as UNEXERCISED with a live
guard -- every `*-relaxed' row must still be in the both-sides-plain class -- so
that if the variant vocabulary ever grows the configuration, this gate reddens
and the anchor gets bound instead of being forgotten.

Rules:

  A1  a HARD anchor's mapped rows must exist and be `Allowed'.
  A2  ... and must actually CITE the anchor's fragment, so the mapping is a
      property of the corpus and not a claim about the paper floating free.
  A3  no fragment reporting an OBSERVED weak behaviour may sit on a
      `Disallowed' row.  The direction rule, corpus-wide.
  A4  no row is keyed by Bagchi ALONE (R2 B7 turned from a measurement into an
      invariant): drop every BAGCHI-class fragment and every row still has an
      admissible key.  This is "never as the sole key" for the CORR entries.
  A5  a fragment that names a non-observation on its face -- GAP, QUALIFIER,
      disclosure, future-work -- must be dispositioned NOTE in nvprovcheck's
      table, as must every fragment of a NOTE- or GAP-graded entry.
  A6  the table itself: per-grade counts, the GAP id set by name, and a sha
      over the serialized entries.
  A7  the two class-level over-citation DISCLOSURES, pinned as counts: how many
      rows carry a Bagchi observation on a shape Bagchi never ran, and how many
      carry a direction-tagged observation in the other direction.  Neither is
      a fault the gate can fix without editing the CSV (the strings are
      class-level by construction), and neither can move a verdict -- but an
      unpinned disclosure is a number nobody re-reads.
  A8  entry 14's guard: the `*-relaxed' family is exactly the both-sides-plain
      class, so a CPU-annotated/GPU-relaxed row cannot hide inside it.
  A9  every fragment the table names exists in nvprovcheck.FRAGMENTS, and
  A10 every BAGCHI-class fragment in nvprovcheck.FRAGMENTS is named by the
      table -- so the anchor doctrine covers the whole Bagchi citation surface
      rather than the part someone remembered.
  A11 an entry's ASSERTED-ABSENT datum appears nowhere in the corpus, so a
      mis-anchor the regeneration struck cannot return through a citation edit
      while the entry that records the reason sits unread beside it.

Specification: env-research/NVOR-phaseC-brief.md sect 5; env-research/
NVOR-register.md (O4, and the anchor-string fixes in sect 3 item 9).  Sibling
of nvprovcheck.py.

`--bite' corrupts the CSV and the table and requires each injection to redden
the rule it names, plus an OVERFIRE guard that must stay green and a VACUITY
guard, because a table of anchors that binds no row would pass every rule
above.  The injection COUNT is printed by the run, never by this comment.
"""

import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nvprovcheck as P                                     # noqa: E402

OBS, NONOBS, NONE, SCOPE = "OBS", "NON-OBS", "NONE", "scope stmt"
HARD, CORR, NOTE, GAP = "HARD", "CORR", "NOTE", "GAP"

# ---------------------------------------------------------------------------
# THE ANCHOR TABLE.  (id, corpus group, verdict, Bagchi datum, kind, grade,
#                     mapped rows, fragments, absent fragments, note)
# `rows' is non-empty only where the anchor BINDS -- i.e. HARD.  `frags' names
# the Source-string fragments the entry corresponds to; `absent' names strings
# that must appear NOWHERE in the corpus.
# ---------------------------------------------------------------------------
ANCHORS = (
    (1, "S_RELAXED MP at sys", "Allowed", "Tab 4 r6", OBS, CORR, (),
     ("Bagchi 4.2 Tab4 r5+r6+r14 relaxed weak OBSERVED",), (),
     "r6 has X=cta and ours is sys, so the transfer is REASON-level (relaxed "
     "=> the sw relation is empty => scope is irrelevant), not row-level"),
    (2, "S_RELAXED MP at cta/gpu", "Allowed", "Tab 4 r5, r14", OBS, CORR, (),
     ("Bagchi 4.2 Tab4 r5+r6+r14 relaxed weak OBSERVED",), (),
     "r14 is the gc direction"),
    (3, "S_RELAXED CPU-side", "Allowed", "Tab 3 r1 rlx/rlx, 225M runs",
     OBS, CORR, (),
     ("Bagchi 4.1 Tab3 r1 rlx/rlx weak OBSERVED 225M runs",), (),
     "the actual observation behind what used to be cited as `Bagchi Fig2a', "
     "which is a data-free background diagram"),
    (4, "S_RELAXED non-MP shapes", "Allowed", "--", NONE, GAP, (), (), (),
     "most of the 78 relaxed rows; see the A7 disclosure"),
    (5, "S_CTA MP-cg", "Allowed", "Fig 4c cta-scope RC + Tab 4 r3",
     OBS, HARD, ("MP-cg-cta-acquire", "MP-cg-cta-fence"),
     ("Bagchi Fig4c cta-scope RC weak OBSERVED",
      "Bagchi 4.2 Tab4 r3 cta/cta weak OBSERVED"), (),
     "disclose the X-scope difference: Bagchi's X is cta, ours is sys"),
    (6, "S_CTA MP-gc", "Allowed", "--", NONE, GAP, (), (), (),
     "A2's proposed r22 anchor was REFUTED (R1 P26: r22's Y is gpu, and it "
     "double-counts entry 9)"),
    (7, "S_CTA non-MP", "Allowed", "--", NONE, GAP, (), (), (),
     "Srivastava's blockfence would apply only if NVOR-Q7 were accepted, and "
     "it was declined"),
    (8, "S_GPU MP-cg", "Allowed", "Fig 4b gpu-scope RC", OBS, HARD,
     ("MP-cg-gpu-acquire", "MP-cg-gpu-fence"),
     ("Bagchi Fig4b gpu-scope RC weak OBSERVED cg",), (),
     "A2's best find; it was uncited anywhere before the regeneration"),
    (9, "S_GPU MP-gc", "Allowed", "Fig 4e + Tab 4 r21-22", OBS, HARD,
     ("MP-gc-gpu-fence", "MP-gc-gpu-release"),
     ("Bagchi Fig4e/r21-22",), (),
     "the paper's cleanest positive heterogeneous observation"),
    (10, "S_GPU non-MP", "Allowed", "--", NONE, GAP, (), (), (), ""),
    (11, "S_SYS1 (24 rows)", "Allowed", "--", NONE, GAP, (),
     ("Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row exists in the paper",),
     ("Bagchi Tab4",),
     "verified at source: Table 4 rows 1-13 have GPU_rlx in EVERY Consumer "
     "cell and GPU_acq appears nowhere, so the old bare `Bagchi Tab4' cite "
     "was mis-anchored and the regeneration replaced it with this GAP note"),
    (12, "S_SYSN (32 rows)", "Allowed", "--", NONE, GAP, (),
     ("Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row exists in the paper",),
     (),
     "same, plus these are 3/4-proc and every Bagchi test is 2-thread"),
    (13, "ORDPAIR-ALLOWED-CPU (46 rows)", "Allowed",
     "Tab 3 r6.1/6.2/7.1/7.2", OBS, CORR, (), (), (),
     "CPU-only and composite; the key-grade support on these rows is "
     "ARM-native (Arm Ltd's own aarch64.cat), so the Bagchi datum corroborates "
     "and does not bind -- this is the entry the brief's sizing line "
     "miscounted as HARD"),
    (14, "one-sided CPU-annotated / GPU-relaxed", "Allowed",
     "Fig 4d system-scope, no RC", OBS, HARD, (), (), (),
     "UNEXERCISED: a correctly-released, correctly-sys-scoped producer with a "
     "RELAXED consumer still shows the weak outcome, but the corpus's "
     "one-sided vocabulary annotates the GPU side only, so no such row "
     "exists.  Guarded by A8 rather than left as prose"),
    (15, "ORDPAIR-ALLOWED-GPU (21 rows)", "Allowed", "--", NONE, GAP, (), (),
     (), "Bagchi tested no unidirectional fence anywhere in the suite"),
    (16, "S_SBR_RA (3) + S_RWC_RA (3)", "Allowed", "--", NONE, GAP, (), (), (),
     "no SB, R or RWC test exists in the paper"),
    (17, "D MP-cg-sys-acqrel-2s", "Disallowed", "Fig 4a, weak NOT seen",
     NONOBS, CORR, (),
     ("Bagchi 4.2 disclosure MP-shaped cg-direction only",), (),
     "the best substitute for the struck CMCM Fig2a, and worded per R2 M3 as "
     "SAME SHAPE AND ORIENTATION, STRICTLY WEAKER ANNOTATION SET, X AT A "
     "NARROWER SCOPE -- never `exactly', because the annotation gap falls on "
     "X, the variable carrying the uncited Fre edge"),
    (18, "D MP-gc-sys-acqrel-2s", "NO-ORACLE", "sect 4.2 aggregate only",
     NONOBS, CORR, (),
     ("Bagchi 4.2 disclosure MP-shaped cg-direction only",), (),
     "no panel and no Table-4 row; the row demoted under NVOR-Q2 anyway, "
     "which is the fail-safe outcome this entry predicted"),
    (19, "D MP-{cg,gc}-sys-fence-2s", "Disallowed", "Tab 3 r5.1/5.2",
     NONOBS, NOTE, (), (),
     ("Bagchi 4.1 Tab3 both-sided fence + 4.2 Tab4",),
     "CPU-ONLY: het both-sided-fence forbidden evidence does not exist in the "
     "paper.  The regeneration STRUCK the composite fragment, so the datum is "
     "asserted absent rather than graded"),
    (20, "the surviving Disallowed surface", "Disallowed", "--", NONE, GAP, (),
     ("Bagchi 4.2 Tab4 GAP -- no correctly sys-annotated GPU producer row exists",
      "Bagchi 5.4 QUALIFIER -- the paper's invalidations do not appear to directly propagate to the GPU L1 caches which is measured at cta scope and this row carries none"),
     (),
     "restated over the post-adjudication census: Bagchi anchors NONE of the "
     "16 surviving Disallowed rows at row level, and the two explicit "
     "absence/qualifier notes are how that is said in the CSV"),
    (21, "NO-ORACLE MCA frontier (34 rows)", "NO-ORACLE",
     "sect 2.1 p68 deferral", SCOPE, CORR, (),
     ("Bagchi 2.1 MCA-future-work p68",), (),
     "sect 2.1, NOT sect 4.2 -- the regeneration fixed this locus on 34 rows "
     "and in docs/het-oracle.md"),
    (22, "the coupling premise", "Disallowed",
     "sect 3.2 doctrine + sect 4.2 aggregate", NONOBS, CORR, (),
     ("Bagchi 3.2+4.2", "Bagchi 5 CPU-GPU coherence"), (),
     "cg-ONLY (R1 P14).  It must never be read as covering the GPU-producer "
     "direction, which is why NVOR-Q2 was declined and 19 rows demoted; A4 is "
     "what keeps it from ever standing alone"),
)

# a non-observation on its face, whatever the rest of the string says
NONOBS_MARKS = ("GAP", "QUALIFIER", "disclosure", "future-work")
OBSERVED_MARK = "OBSERVED"

# ---- pins ----------------------------------------------------------------
EXPECT_ROWS = 411
EXPECT_GRADES = {HARD: 4, CORR: 8, NOTE: 1, GAP: 9}
EXPECT_GAP_IDS = (4, 6, 7, 10, 11, 12, 15, 16, 20)
EXPECT_TABLE_SHA = "55d669cfbb3f484f"   # sha256[:16] of the serialized entries
EXPECT_HARD_ROWS = 6                    # rows bound by a HARD anchor

# A7, the class-level over-citation disclosures.  The one-sided Source strings
# are per CLASS, so a Bagchi observation printed on `S_CTA' rides along onto
# every shape and both directions in that class.  Neither number can move a
# verdict (A3/A4 hold regardless) and neither is fixable without editing the
# CSV, so both are pinned as disclosures.
EXPECT_NONMP_OBS_ROWS = 176             # a Bagchi observation on a shape
EXPECT_CROSSED_DIR_ROWS = 22            # ... and in the other direction
EXPECT_RELAXED_FAMILY = 78              # entry 14's guard
RELAXED_CLASS_MARK = "ARMv9/PTX relaxed:"


class Fail(Exception):
    pass


def table_sha(anchors):
    blob = "\n".join(
        "%d|%s|%s|%s|%s|%s|%s|%s|%s" % (a[0], a[1], a[2], a[3], a[4], a[5],
                                        ",".join(a[6]), ",".join(a[7]),
                                        ",".join(a[8]))
        for a in anchors)
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def shape_of(name):
    return name.split("-")[0]


def cut_of(name):
    m = re.search(r"-(cg|gc)-", name)
    return m.group(1) if m else None


def check(rows, anchors=None, table=None):
    """Assert every anchor rule and pin.  Returns the measured report."""
    anchors = ANCHORS if anchors is None else anchors
    frag_table = P.FRAGMENTS if table is None else table
    if len(rows) != EXPECT_ROWS:
        raise Fail("PIN rows: %d != %d" % (len(rows), EXPECT_ROWS))

    # A6 first: a table that binds nothing passes every rule below
    grades = {}
    for a in anchors:
        grades[a[5]] = grades.get(a[5], 0) + 1
    if grades != EXPECT_GRADES:
        raise Fail("PIN anchor-table grades: %r != pinned %r -- an anchor "
                   "changed grade, or the table gained or lost an entry"
                   % (grades, EXPECT_GRADES))
    gaps = tuple(a[0] for a in anchors if a[5] == GAP)
    if gaps != EXPECT_GAP_IDS:
        raise Fail("PIN anchor-table GAPs: %r != pinned %r -- a GAP documents "
                   "what Bagchi CANNOT anchor, so one leaving the table needs "
                   "a registered source, not an edit" % (gaps,
                                                         EXPECT_GAP_IDS))
    nbound = sum(len(a[6]) for a in anchors)
    if nbound != EXPECT_HARD_ROWS:
        raise Fail("PIN anchor-bound rows: %d != pinned %d -- a HARD anchor "
                   "that binds no row enforces nothing, so the count is the "
                   "vacuity guard" % (nbound, EXPECT_HARD_ROWS))
    if table_sha(anchors) != EXPECT_TABLE_SHA:
        raise Fail("PIN anchor-table sha: %s != pinned %s -- an entry's "
                   "mapping, datum or fragments moved"
                   % (table_sha(anchors), EXPECT_TABLE_SHA))

    verdict = {n: v for n, v, _m, _s in rows}
    source = {n: s for n, v, _m, s in rows}

    # A9 / A10: the table and nvprovcheck's fragment table cover each other
    named = set()
    for a in anchors:
        named |= set(a[7])
    unknown = sorted(f for f in named if f not in frag_table)
    if unknown:
        raise Fail("A9 stale anchor fragment (not in nvprovcheck.FRAGMENTS): "
                   "%r -- the anchor table is describing a citation the corpus "
                   "no longer has" % unknown)
    bagchi = {f for f, (cls, _t, _d) in frag_table.items() if cls == P.BAGCHI}
    unanchored = sorted(bagchi - named)
    if unanchored:
        raise Fail("A10 unanchored Bagchi fragment: %r -- every Bagchi "
                   "citation must be graded by an anchor entry, or the "
                   "doctrine covers only the part someone remembered"
                   % unanchored)

    # A11: an entry's ASSERTED-ABSENT datum must appear nowhere.  Entry 19's
    # composite fragment and entry 11's bare `Bagchi Tab4' were struck by the
    # regeneration as mis-anchors; nvprovcheck's E4 catches a bracketed or
    # inline reappearance, and this catches the anchor doctrine forgetting WHY.
    # Exact fragment match, not substring: `Bagchi Tab4' is a PREFIX of the
    # live `Bagchi Tab4 GAP -- ...' note that replaced it, so a raw `in'
    # would report the replacement as the thing it replaced.
    scan = dict(P.FRAGMENTS_STRUCK)
    scan.update({f: None for f in frag_table})
    for a in anchors:
        scan.update({f: None for f in a[8]})
    for a in anchors:
        for f in a[8]:
            hit = [n for n, _v, _m, s in rows
                   if f in P.fragments_of(n, s) or f in P.inline_of(s, scan)]
            if hit:
                raise Fail("A11 asserted-absent datum: anchor %d records %r as "
                           "struck, yet %d row(s) carry it (%r) -- the strike "
                           "cannot be undone by a citation edit"
                           % (a[0], f, len(hit), hit[:3]))

    # A5: a non-observation may never be dispositioned KEY
    notes = set()
    for a in anchors:
        if a[5] in (NOTE, GAP):
            notes |= set(a[7])
    for f in sorted(bagchi):
        marked = any(m in f for m in NONOBS_MARKS)
        if (marked or f in notes) and frag_table[f][2] != P.NOTE:
            raise Fail("A5 non-observation graded %s: %r -- a Bagchi "
                       "non-observation (%s) can corroborate but never prove "
                       "a verdict, so it must be dispositioned NOTE"
                       % (frag_table[f][2], f,
                          "explicit marker" if marked else "NOTE/GAP entry"))

    # A1 / A2: HARD anchors bind, and bind to something real
    for a in anchors:
        if a[5] != HARD:
            continue
        for n in a[6]:
            if n not in verdict:
                raise Fail("A1 anchor %d names row %r, which is not in the "
                           "corpus" % (a[0], n))
            if verdict[n] != "Allowed":
                raise Fail("A1 HARD anchor %d (%s) maps to row %s, which is "
                           "%s.  Bagchi OBSERVED the weak behaviour on this "
                           "shape and direction, so a non-Allowed verdict here "
                           "is a FALSE REFUTATION IN WAITING: the harness would "
                           "report a compound-model violation the paper already "
                           "recorded as normal GH200 behaviour"
                           % (a[0], a[3], n, verdict[n]))
            for f in a[7]:
                if f not in P.fragments_of(n, source[n]):
                    raise Fail("A2 HARD anchor %d maps row %s but that row "
                               "does not cite %r -- the mapping must be a "
                               "property of the corpus, not a claim about the "
                               "paper floating free" % (a[0], n, f))

    # A3: the direction rule, corpus-wide
    bad = [(n, f) for n, v, _m, s in rows if v == "Disallowed"
           for f in P.fragments_of(n, s) if OBSERVED_MARK in f]
    if bad:
        raise Fail("A3 OBSERVED-on-Disallowed: %r -- a report that the weak "
                   "behaviour WAS SEEN cannot support forbidding it" % bad[:4])

    # A4: never the sole key
    sole = []
    for n, v, _m, s in rows:
        keyed = False
        for f in P.fragments_of(n, s):
            if f not in frag_table:
                continue
            cls, _t, disp = frag_table[f]
            if cls in (P.PTXL19, P.PTXISA) and P.SPEC86_ROW.search(n):
                cls = P.PTX86
            if cls in P.ADMISSIBLE and disp == P.KEY and cls != P.BAGCHI:
                keyed = True
        if not keyed and any(frag_table.get(f, (None,))[0] == P.BAGCHI
                             for f in P.fragments_of(n, s)):
            sole.append((n, v))
    if sole:
        raise Fail("A4 Bagchi as the sole key on %d row(s): %r -- the paper's "
                   "suite is MP-only, 2-thread, X never at system scope, so no "
                   "verdict may rest on it alone" % (len(sole), sole[:4]))

    # A7: the class-level over-citation disclosures
    nonmp = [n for n, _v, _m, s in rows
             if shape_of(n) != "MP"
             and any(OBSERVED_MARK in f for f in P.fragments_of(n, s))]
    crossed = [n for n, _v, _m, s in rows
               if (("Bagchi Fig4b gpu-scope RC weak OBSERVED cg" in s
                    and cut_of(n) == "gc")
                   or ("Bagchi Fig4e/r21-22" in s and cut_of(n) == "cg"))]
    if len(nonmp) != EXPECT_NONMP_OBS_ROWS:
        raise Fail("PIN shape-coverage disclosure: %d rows of a shape Bagchi "
                   "never ran carry one of its observations (class-level "
                   "strings ride along), pinned %d"
                   % (len(nonmp), EXPECT_NONMP_OBS_ROWS))
    if len(crossed) != EXPECT_CROSSED_DIR_ROWS:
        raise Fail("PIN direction-coverage disclosure: %d rows carry a "
                   "direction-tagged Bagchi observation in the OTHER "
                   "direction, pinned %d"
                   % (len(crossed), EXPECT_CROSSED_DIR_ROWS))

    # A8: entry 14's guard
    fam = [n for n, _v, _m, _s in rows if n.endswith("-relaxed")]
    plain = [n for n, _v, _m, s in rows if s.startswith(RELAXED_CLASS_MARK)]
    if (len(fam) != EXPECT_RELAXED_FAMILY or set(fam) != set(plain)):
        raise Fail("A8 relaxed-family guard: %d `*-relaxed' rows vs %d "
                   "both-sides-plain rows (pinned %d, sets equal) -- entry 14 "
                   "is UNEXERCISED only while no row annotates the CPU side "
                   "and leaves the GPU relaxed; if the variant vocabulary grew "
                   "one, Bagchi Fig 4d now BINDS it"
                   % (len(fam), len(plain), EXPECT_RELAXED_FAMILY))

    return {"grades": grades, "bound": nbound, "nonmp": len(nonmp),
            "crossed": len(crossed), "bagchi": len(bagchi),
            "sha": table_sha(anchors)}


def report(rows):
    r = check(rows)
    print("nvanchorcheck: %d rows; anchor table %r, sha %s"
          % (len(rows), r["grades"], r["sha"]))
    print("direction rule: an OBSERVATION binds hard (the mapped row must be "
          "Allowed); a NON-OBSERVATION never proves Disallowed")
    for a in ANCHORS:
        if a[5] == HARD:
            print("  HARD %2d  %-34s -> %s"
                  % (a[0], a[3], ", ".join(a[6]) or "UNEXERCISED (see A8)"))
    print("  %d rows bound by a HARD anchor, every one Allowed; %d Bagchi "
          "fragments graded, none of them ever a row's sole key"
          % (r["bound"], r["bagchi"]))
    print("GAPs pinned: %r -- what Bagchi CANNOT anchor" % (EXPECT_GAP_IDS,))
    print("coverage: Bagchi's suite is 100% MP-shaped, 2-thread, X at cta or "
          "gpu and NEVER at system; no LB/S/SB/R/IRIW/2+2W/WRC/ISA2/RWC/WRC3 "
          "test and no unidirectional fence appears in the paper")
    print("disclosure: %d rows of an unrun shape and %d rows of the opposite "
          "direction carry an observation via a class-level string (neither "
          "can move a verdict; A3 and A4 hold regardless)"
          % (r["nonmp"], r["crossed"]))


# --------------------------------------------------------------------------
# --bite
# --------------------------------------------------------------------------

def _expect_fail(what, marker, fn):
    try:
        fn()
    except Fail as e:
        if marker not in str(e):
            raise Fail("BITE %s: failed for the WRONG reason (wanted %r): %s"
                       % (what, marker, e))
        print("  bite %-28s FAILS   (%s)" % (what, marker))
        return
    raise Fail("BITE %s: did not fire" % what)


def _expect_pass(what, why, base, mutated, fn):
    if [list(r) for r in base] == [list(r) for r in mutated]:
        raise Fail("BITE %s: VACUOUS -- the injection changed nothing" % what)
    try:
        fn()
    except Fail as e:
        raise Fail("BITE %s: OVERFIRE -- %s, yet the gate reddened: %s"
                   % (what, why, e))
    print("  bite %-28s green   (overfire guard: %s)" % (what, why))


def _clone(rows):
    return [list(r) for r in rows]


def _find(rows, pred):
    return next(i for i, r in enumerate(rows) if pred(r))


def bite(rows):
    n = 0
    FIG4C = "Bagchi Fig4c cta-scope RC weak OBSERVED"

    # 1 THE rule this file exists for: a HARD anchor pointed at a Disallowed row
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0] == "MP-cg-cta-acquire")
    bad[i][1] = "Disallowed"
    _expect_fail("hard-anchor-disallowed", "A1 HARD anchor",
                 lambda: check(bad))
    n += 1

    # 2 ... and the same row demoted, which is fail-safe for the oracle but
    #   still breaks the anchor: Bagchi SAW this behaviour
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0] == "MP-gc-gpu-release")
    bad[i][1] = "NO-ORACLE"
    _expect_fail("hard-anchor-demoted", "A1 HARD anchor", lambda: check(bad))
    n += 1

    # 3 the mapping must be a corpus property: strip the anchor's own citation
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0] == "MP-cg-cta-fence")
    bad[i][3] = bad[i][3].replace("; " + FIG4C, "", 1)
    _expect_fail("hard-anchor-uncited", "A2 HARD anchor", lambda: check(bad))
    n += 1

    # 4 OVERFIRE GUARD: a correct HARD anchor on an Allowed row stays green,
    #   and so does the same observation cited on another Allowed MP-cg row
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0] == "MP-cg-sys-acquire")
    bad[i][3] = P._append_frag(bad[i][3], FIG4C)
    _expect_pass("hard-anchor-overfire",
                 "an observation on an Allowed row of the same shape and "
                 "direction is what the rule is FOR", rows, bad,
                 lambda: check(bad))
    n += 1

    # 5 the direction rule, corpus-wide: an observation on a Disallowed row
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed")
    bad[i][3] = P._append_frag(bad[i][3], FIG4C)
    _expect_fail("observed-on-disallowed", "A3 OBSERVED-on-Disallowed",
                 lambda: check(bad))
    n += 1

    # 6 a CORR fragment promoted to SOLE key: strip a row's non-Bagchi keys
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed")
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[Bagchi 3.2+4.2]", bad[i][3])
    _expect_fail("corr-as-sole-key", "A4 Bagchi as the sole key",
                 lambda: check(bad))
    n += 1

    # 7 ... and the same for an OBSERVED fragment on an Allowed row, because
    #   "never the sole key" is not a Disallowed-only rule
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "PTX-relaxed" in r[3])
    bad[i][3] = re.sub(
        r"\[[^\]]*\]$",
        "[Bagchi 4.1 Tab3 r1 rlx/rlx weak OBSERVED 225M runs]", bad[i][3])
    _expect_fail("obs-as-sole-key", "A4 Bagchi as the sole key",
                 lambda: check(bad))
    n += 1

    # 8 a non-observation promoted to KEY in the fragment table
    promoted = dict(P.FRAGMENTS)
    gapfrag = ("Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row "
               "exists in the paper")
    promoted[gapfrag] = (P.BAGCHI, "x", P.KEY)
    _expect_fail("gap-fragment-as-key", "A5 non-observation graded",
                 lambda: check(_clone(rows), table=promoted))
    n += 1

    # 9 a GAP entry quietly leaving the table
    trimmed = tuple(a for a in ANCHORS if a[0] != 15)
    _expect_fail("gap-unpinned", "PIN anchor-table grades",
                 lambda: check(_clone(rows), anchors=trimmed))
    n += 1

    # 10 ... and one leaving while the per-grade counts are held equal
    swapped = tuple(a[:5] + (GAP,) + a[6:] if a[0] == 13 else
                    a[:5] + (CORR,) + a[6:] if a[0] == 15 else a
                    for a in ANCHORS)
    _expect_fail("gap-id-set", "PIN anchor-table GAPs",
                 lambda: check(_clone(rows), anchors=swapped))
    n += 1

    # 11 table-count drift: an entry appended
    grown = ANCHORS + ((23, "invented", "Allowed", "--", NONE, GAP, (), (), (),
                        ""),)
    _expect_fail("table-count-drift", "PIN anchor-table grades",
                 lambda: check(_clone(rows), anchors=grown))
    n += 1

    # 12 VACUITY GUARD: HARD anchors that bind nothing pass A1 and A2
    #    trivially, so the bound-row count is pinned
    unbound = tuple(a[:6] + ((),) + a[7:] if a[5] == HARD else a
                    for a in ANCHORS)
    _expect_fail("vacuous-hard-anchors", "PIN anchor-bound rows",
                 lambda: check(_clone(rows), anchors=unbound))
    n += 1

    # 13 the table sha, with every count held equal: an entry's mapping edited
    reordered = tuple(a[:6] + (tuple(reversed(a[6])),) + a[7:]
                      if a[0] == 5 else a for a in ANCHORS)
    _expect_fail("anchor-table-sha", "PIN anchor-table sha",
                 lambda: check(_clone(rows), anchors=reordered))
    n += 1

    # 14 an anchor naming a fragment the corpus no longer has
    holed = dict(P.FRAGMENTS)
    del holed["Bagchi Fig4e/r21-22"]
    _expect_fail("stale-anchor-fragment", "A9 stale anchor fragment",
                 lambda: check(_clone(rows), table=holed))
    n += 1

    # 15 ... and a Bagchi fragment the anchor table does not grade
    extra = dict(P.FRAGMENTS)
    extra["Bagchi 9.9 invented"] = (P.BAGCHI, "x", P.KEY)
    _expect_fail("unanchored-bagchi-fragment", "A10 unanchored Bagchi",
                 lambda: check(_clone(rows), table=extra))
    n += 1

    # 16 entry 14's guard: a `*-relaxed' row that is no longer both-sides-plain
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0].endswith("-relaxed"))
    bad[i][3] = "sys sync one-sided: " + bad[i][3]
    _expect_fail("relaxed-family-guard", "A8 relaxed-family guard",
                 lambda: check(bad))
    n += 1

    # 17 the shape-coverage disclosure
    bad = _clone(rows)
    i = _find(bad, lambda r: shape_of(r[0]) != "MP" and "OBSERVED" in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[PTX 3.3; CMCM]", bad[i][3])
    _expect_fail("shape-disclosure-drift", "PIN shape-coverage disclosure",
                 lambda: check(bad))
    n += 1

    # 18 the direction-coverage disclosure
    bad = _clone(rows)
    i = _find(bad, lambda r: cut_of(r[0]) == "gc"
              and "Bagchi Fig4b gpu-scope RC weak OBSERVED cg" in r[3])
    bad[i][3] = bad[i][3].replace(
        "Bagchi Fig4b gpu-scope RC weak OBSERVED cg; ", "", 1)
    _expect_fail("direction-disclosure-drift",
                 "PIN direction-coverage disclosure", lambda: check(bad))
    n += 1

    # 19 a struck mis-anchor returning: entry 11 records that bare
    #    `Bagchi Tab4' was replaced by an explicit GAP note because Table 4's
    #    Consumer column has GPU_rlx in every one of rows 1-13
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "Bagchi Tab4" not in r[3])
    bad[i][3] += " see Bagchi Tab4"
    _expect_fail("struck-datum-returns", "A11 asserted-absent datum",
                 lambda: check(bad))
    n += 1

    # 20 row drop
    _expect_fail("row-drop", "PIN rows", lambda: check(_clone(rows)[:-1]))
    n += 1

    print("nvanchorcheck: BITE OK (%d injections)" % n)


def main():
    rows = P.read_rows()
    if "--bite" in sys.argv[1:]:
        bite(rows)
        return
    report(rows)
    print("nvanchorcheck: OK (and no non-observation carries a verdict)")


if __name__ == "__main__":
    try:
        main()
    except (Fail, P.Fail) as e:
        print("nvanchorcheck: FAIL -- %s" % e, file=sys.stderr)
        sys.exit(1)
