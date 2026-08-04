#!/usr/bin/env python3
"""amdprovcheck.py -- the citation-PROVENANCE gate behind tests/het/expected-amd.csv.

The fault this gate makes unrepeatable (register D21, closed by D26 2026-08-04):
the source whitelist admitted `[CMCM]' at PAPER granularity, but transferability
is a property of SECTIONS.  The CMCM paper is three artifacts under one tag --
sect 3-4 the generalized LOST-POP framework, sect 5-6 the x86TSO+PTX(NVIDIA)
instantiation, sect 7 the x86+AMD-GCN3 gem5 evaluation -- and sect 5-6 is
EXCLUDED for the AMD oracle (Nguyen 2026-08-04; CLAUDE.md CROSS-ARCH rule).
D18 was this same fault, repaired R-5-style; D21 sat unrepaired until the D26
regeneration demoted the 127 rows sect 5-6 carried.  This file is the mechanism
that keeps the fault out.

Every citation fragment in every Source string is classified into one of FOUR
BUCKETS, each one admissibility rule, not one document region:

  GEN      CMCM sect 3-4 incl 4.6 -- the framework; admissible as-is.
  PTX      CMCM sect 5-6 -- the PTX instantiation (CMM axioms, cmm.als, moral
           strength, gxhb, the memo's X1/X2a labels, Fig 10/11/12);
           INADMISSIBLE for this oracle.  Since the D26 regeneration NO
           shipping Source string carries one; the known strings live in
           FRAGMENTS_STRUCK so a reappearance is recognised, not unknown.
  AMD      CMCM sect 7 -- the GCN3 evaluation; admissible per-mechanism under
           register D3's transfer limits (the gate checks presence, the
           register carries the judgment).
  NONCMCM  everything outside the paper; each TAG carries its own disposition
           from the memo whitelist (LLVM/GFX942/APM/HSA/artifact/herd7 are
           KEYs; amd-gcn3.cat is INSTRUMENT, never a key -- memo 2.1; decision
           references and disclaimers are NOTEs, not keys).

Rules, all fail-closed and direction-aware (a wrongly-Disallowed row
manufactures a false refutation of the compound model on hardware; Allowed and
NO-ORACLE are fail-safe):

  E1  a fragment or bracket block not in the tables / not event-notation.
      An unclassified citation anywhere is an error, so the table cannot
      silently go stale and a Source-string edit forces reclassification.
  E2  a Disallowed row cites ANY PTX-class fragment -- the fault D26 removed,
      asserted absent forever.
  E3  a Disallowed row with no admissible KEY fragment at all.
  E4  a STRUCK fragment reappears anywhere.  Post-D26 every PTX-class string
      was removed from the file, so even a fail-safe-direction reappearance is
      citation rot that must come with a deliberate table update.

POST-STRIKE PINS.  The regenerated CSV is 258 Allowed / 19 Disallowed /
134 NO-ORACLE.  The D26 toggle set -- the 127 rows `X2A_TRANSFERS=1' re-arms
(gate G16 in build-amd-oracle.sh pins the round trip) -- is pinned here
byte-exactly: 119 S_CUT_UNKEYED + 8 S_CUT_MCA_UNKEYED, sha256[:16]
d59475c5ef6bdd5f over the sorted row names, every one NO-ORACLE.  Drift in
either direction -- a row leaving the toggle set without a registered re-key,
or joining it -- reddens the gate.  (History: before the regeneration this file
carried a TEMPORARY fault pin, E2 = 138 / E3 = 8 / at-risk 127 measured on the
pre-strike CSV; the strike landed, the pin flipped to the invariants above.)

Specification: env-research/PORT2-phaseC-rekey-brief.md sect 5 item 3;
PORT2-R2-amd-oracle.md sect 2 as amended by D26.  Sibling of amdordercheck.py
(which pins source-string BYTES against memo 5.2; this file pins their
PROVENANCE).

`--bite' corrupts the CSV, the tables and the pins and requires each injection
to redden the rule it names, for the right reason, on corruption and on
omission both.  The injection COUNT is printed by the run itself, never by
this comment (the amdorder lesson: a comment said 33, the measured value
was 35).
"""

import csv
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSV = ROOT / "hetlitmus" / "tests" / "het" / "expected-amd.csv"

# --------------------------------------------------------------------------
# The fragment tables: exact Source-string fragments -> (bucket, tag, disp).
# Exact-match is the point: any edit to a citation is an unknown fragment (E1)
# until a human reclassifies it here, complementing amdordercheck's byte-pin.
# disp KEY = may carry a verdict; INSTRUMENT = never a key (memo 2.1);
# NOTE = disclosure/register pointer, carries nothing.
#
# Classifications verified blind against the local PDF, 2026-08-04 (one
# Opus-xhigh reader, 8/8 agreement).  Findings that bind future work:
#   - PAGE-BOUNDARY: pages 153:14 (end of 4.6 GEN / start of 5 PTX) and
#     153:20 (end of 6.3 PTX / start of 7 AMD) straddle the partition; a bare
#     page cite to either resolves by PARAGRAPH, never by page number.
#   - Figures float: a figure's class follows its citing section, not the page
#     it is printed on.
#   - "X2a" is the MEMO's register label (memo sect 4 X2), not the paper's:
#     the string occurs nowhere in the PDF.
# --------------------------------------------------------------------------
GEN, PTX, AMD, NONCMCM = "GEN", "PTX", "AMD", "NONCMCM"
KEY, INSTRUMENT, NOTE = "KEY", "INSTRUMENT", "NOTE"

FRAGMENTS = {
    # -- CMCM sect 3-4: the framework.  Admissible (first populated by D26).
    "CMCM 4.1 p153:10-11 LOST-POP operational core (sect 3-4 framework -- architecture-agnostic): a request is ACCEPTED into its own thread before it can PROPAGATE ('the request is just added to the system state and propagated to the thread t that accepted it') and cannot propagate past a previous order constraint ('no previous according to the order constraints request r-prime can be stalling it') and a read is satisfied only by a write that has already propagated to the reader ('In order to respond to a read request r with write w they both have to have propagated to the exact same set of threads ... We also want w to happen before r') so an all-rf external cycle in which every thread orders its own R before its own W is a cycle in the model's OWN accept/propagate order -- NO pred term and NO read-removal step of 4.2 is consulted so the argument needs neither cumulativity nor multi-copy atomicity":
        (GEN, "CMCM-4.1-core", KEY),
    "CMCM 4.6 p153:14 -- admissible sect 3-4 framework naming the open slot":
        (GEN, "CMCM-4.6-slot", KEY),
    # -- CMCM sect 7: the AMD-GCN3 evaluation.  Per-mechanism under D3.
    "CMCM 7.2 p153:21 'when the scopes of the operations are not morally strong then the litmus tests are allowed -- for example when the MP litmus test is run with a CTA-scoped fence on two different CTAs'":
        (AMD, "CMCM-7.2-scope", KEY),
    # -- non-CMCM, admissible keys per the memo sect 2 whitelist.
    "LLVM AMDGPUUsage L1428-1439 agent-scope row -- an agent-scope operation joins modification and seq_cst total orderings only with operations whose scope is system or agent AND executed by a thread on the same agent -- and L1386-1388 'Concurrent atomic operations only operate atomically with respect to each other if they are included in each other's sync scope' so a Zen-4 core is not a thread on the same agent as the CDNA3 XCDs":
        (NONCMCM, "LLVM", KEY),
    "LLVM AMDGPUUsage optimization-constraints acquire L7463-7467 / release L7468-7473":
        (NONCMCM, "LLVM", KEY),
    "LLVM AMDGPUUsage optimization-constraints acquire L7463-7467":
        (NONCMCM, "LLVM", KEY),
    "LLVM AMDGPUUsage single-thread optimization constraints monotonic=none L7462":
        (NONCMCM, "LLVM", KEY),
    "LLVM AMDGPUUsage optimization-constraints monotonic=none L7462":
        (NONCMCM, "LLVM", KEY),
    "LLVM seq_cst total orderings":
        (NONCMCM, "LLVM", KEY),
    "GFX942 fence acq_rel agent lowers to buffer_wbl2 sc1=1 / buffer_inv sc1=1 with sc0=0 throughout L13038-13049 L13126-13140 -- strictly narrower than the sc0=1 sc1=1 system-scope sequence so the Allowed is a statement about code AMD actually generates":
        (NONCMCM, "GFX942", KEY),
    "GFX942 load/store atomic monotonic system L11324/L11332":
        (NONCMCM, "GFX942", KEY),
    "GFX942 rows L11454 L12058 L11880 L12386":
        (NONCMCM, "GFX942", KEY),
    "GFX942 rows L11454 L11880 carry the GPU-side R->W":
        (NONCMCM, "GFX942", KEY),
    "GFX942 store atomic monotonic emits no buffer_wbl2 L11332":
        (NONCMCM, "GFX942", KEY),
    "g3probe2-gfx942.s lb_relaxed":
        (NONCMCM, "g3probe", KEY),
    "cf artifact Compound MP1-sys + MP2-sys Allowed":
        (NONCMCM, "ART", KEY),
    "artifact Compound SB-sys Allowed and SB-sys-HF Allowed":
        (NONCMCM, "ART", KEY),
    "DECIDED IN THE SOUND DIRECTION by herd7 -cat x86tso.cat: the all-x86 rendering of every one of these 46 rows is Sometimes":
        (NONCMCM, "x86tso-herd7", KEY),
    "APM 7.2 'Non-overlapping Loads may pass stores'":
        (NONCMCM, "APM", KEY),
    "APM Rev 3.45 7.2 p190 'A store by a processor cannot be committed to memory before a read appearing earlier in the program has captured its targeted data from memory' and 'Stores do not pass loads' -- a COMMIT-TIME statement about whether the store exists in memory at all NOT about what a class of observer sees so it is not exposed to the 7.2/7.3 device-widening question the demoted cross-location classes turn on":
        (NONCMCM, "APM", KEY),
    "HSA PRM 6.2.1":
        (NONCMCM, "HSA", KEY),
    # -- non-CMCM, instrument-only: cited as explanation, NEVER a key (memo 2.1).
    "amd-gcn3.cat axiom 3":
        (NONCMCM, "gcn3", INSTRUMENT),
    # -- notes: disclosures and register pointers, not sources.
    "the artifact cta rows are protocol-configured not annotated so they are NOT cited here -- see decision D15":
        (NONCMCM, "note-D15", NOTE),
    "decision D26":
        (NONCMCM, "note-reg", NOTE),
    "decision D26 and D2":
        (NONCMCM, "note-reg", NOTE),
    "decision D7 D21 and D26":
        (NONCMCM, "note-reg", NOTE),
    "decision D1 D7 and D26":
        (NONCMCM, "note-reg", NOTE),
    "PORT2-phaseC-rekey-brief.md":
        (NONCMCM, "note-brief", NOTE),
}

# The struck PTX-class strings, kept so a reappearance is RECOGNISED (E2/E4)
# rather than merely unknown (E1).  Expected use in the shipping CSV: zero.
FRAGMENTS_STRUCK = {
    "CMCM 6.2 p153:18 x86 write/read are at least a sys-scoped release/acquire + rfe-g-x as strong as x86TSO rfe":
        (PTX, "CMCM-6.2-X2a", KEY),
    "CMCM 6.2 p153:18 morally-strong":
        (PTX, "CMCM-6.2-ms", KEY),
    "CMCM Fig10 p153:15 worked compound WRC -- a genuine scope-ANNOTATION example":
        (PTX, "CMCM-Fig10", KEY),
    "CMCM 5 p153:14 'unless r is a write and r-prime a read'":
        (PTX, "CMCM-5-ppo", KEY),
    "CMCM p153:19 CMM-No-Thin-Air acyclic(rf u dep u ppo) -- and that ppo is x86TSO's: Fig12 p153:17 defines ppo = (WW u RW u RR) n po in the x86TSO column ONLY and p153:19 states 'we augment the PTX (No-Thin-Air) axiom with ppo ordering in x86TSO' so the axiom carries the CPU half of the cut and NOT the GPU half":
        (PTX, "CMCM-NTA", KEY),
    "CMCM 5.1+Fig11 p153:15-16":
        (PTX, "CMCM-5.1-ws", KEY),
}

# A bracket block is a CITATION block iff its first token opens with one of
# these; the only other bracket in any Source string is comma-free event
# notation like `release;sys' (memo 5.2), matched separately below.
CITATION_OPENERS = ("CMCM", "LLVM", "GFX942", "g3probe2-gfx942.s",
                    "cf artifact", "artifact", "DECIDED", "APM", "HSA",
                    "amd-gcn3.cat", "decision", "the artifact", "PORT2-")
EVENT_NOTATION = re.compile(r"[a-z]+;[a-z]+\Z")

# ---- pins: the shape of the committed CSV (post-D26) ----------------------
EXPECT_ROWS = 411
EXPECT_CENSUS = {"Allowed": 258, "Disallowed": 19, "NO-ORACLE": 134}
UNKEYED_MARK = "UNKEYED -- decision"          # both UNKEYED class strings carry it
EXPECT_TOGGLE = 127                            # 119 S_CUT_UNKEYED + 8 MCA
EXPECT_TOGGLE_MCA = 8
EXPECT_TOGGLE_SHA = "d59475c5ef6bdd5f"         # sha256[:16] of sorted row names


class Fail(Exception):
    pass


def read_rows(path=CSV, text=None):
    raw = text if text is not None else Path(path).read_text()
    lines = [l for l in raw.splitlines() if l and not l.startswith("#")]
    rows = list(csv.reader(lines))[1:]
    for r in rows:
        if len(r) != 4:
            raise Fail("E1 structure: row does not have 4 fields: %r" % r[:1])
    return rows


def fragments_of(source):
    """All citation fragments of one Source string, or Fail on E1 structure."""
    frags = []
    for block in re.findall(r"\[([^\]]*)\]", source):
        if block.startswith(CITATION_OPENERS):
            frags.extend(f.strip() for f in block.split(";"))
        elif EVENT_NOTATION.fullmatch(block):
            continue                        # prose event notation, not a citation
        else:
            raise Fail("E1 structure: unclassifiable bracket block [%s]" % block)
    return frags


def audit(rows, table=None, struck=None):
    """Classify every fragment; return (findings, used, census, unkeyed)."""
    table = FRAGMENTS if table is None else table
    struck = FRAGMENTS_STRUCK if struck is None else struck
    findings = {"E1": [], "E2": [], "E3": [], "E4": []}
    used = {}
    census = {}
    unkeyed = []
    for name, verdict, _model, source in rows:
        census[verdict] = census.get(verdict, 0) + 1
        if UNKEYED_MARK in source:
            unkeyed.append((name, verdict, "GPU observer" in source))
        frags = fragments_of(source)
        buckets, disps = set(), set()
        for f in frags:
            if f in struck:
                bucket, tag, disp = struck[f]
                findings["E4"].append((name, tag))
            elif f in table:
                bucket, tag, disp = table[f]
                used[f] = used.get(f, 0) + 1
            else:
                raise Fail("E1 unknown fragment (reclassify in FRAGMENTS): "
                           "row %s: %r" % (name, f))
            buckets.add(bucket)
            disps.add((bucket, disp))
        if verdict == "Disallowed":
            if PTX in buckets:
                findings["E2"].append(name)
            if not any(d == KEY for b, d in disps):
                findings["E3"].append(name)
    return findings, used, census, unkeyed


def check(rows, table=None, struck=None):
    """Assert every pin; Fail on the first violation.  Returns the audit."""
    if len(rows) != EXPECT_ROWS:
        raise Fail("PIN rows: %d != %d" % (len(rows), EXPECT_ROWS))
    findings, used, census, unkeyed = audit(rows, table, struck)
    if census != EXPECT_CENSUS:
        raise Fail("PIN census: %r != %r" % (census, EXPECT_CENSUS))
    stale = set(FRAGMENTS if table is None else table) - set(used)
    if stale:
        raise Fail("PIN stale table entries (unused, re-measure): %r"
                   % sorted(stale))
    if findings["E2"]:
        raise Fail("E2: Disallowed rows citing PTX-class fragments: %r"
                   % findings["E2"])
    if findings["E3"]:
        raise Fail("E3: Disallowed rows with no admissible key: %r"
                   % findings["E3"])
    if findings["E4"]:
        raise Fail("E4: struck PTX-class fragment reappeared: %r"
                   % findings["E4"][:4])
    # the D26 toggle set, byte-exact
    names = sorted(n for n, _v, _m in unkeyed)
    sha = hashlib.sha256("\n".join(names).encode()).hexdigest()[:16]
    nmca = sum(1 for _n, _v, m in unkeyed if m)
    if (len(names) != EXPECT_TOGGLE or sha != EXPECT_TOGGLE_SHA
            or nmca != EXPECT_TOGGLE_MCA):
        raise Fail("PIN toggle-set drift: %d rows (%d MCA) sha %s != pinned "
                   "%d/%d/%s -- a row left or joined the D26 toggle set "
                   "without this pin being re-measured"
                   % (len(names), nmca, sha,
                      EXPECT_TOGGLE, EXPECT_TOGGLE_MCA, EXPECT_TOGGLE_SHA))
    bad = [n for n, v, _m in unkeyed if v != "NO-ORACLE"]
    if bad:
        raise Fail("PIN toggle-set verdict: UNKEYED row(s) not NO-ORACLE: %r"
                   % bad)
    return findings, used, census, unkeyed


def report(rows):
    _f, used, census, unkeyed = audit(rows)
    by_bucket = {}
    for f, n in used.items():
        b = FRAGMENTS[f][0]
        by_bucket[b] = by_bucket.get(b, 0) + n
    print("amdprovcheck: %d rows %r; fragment uses by bucket: %s"
          % (len(rows), census,
             " ".join("%s=%d" % kv for kv in sorted(by_bucket.items()))))
    print("D26 toggle set: %d rows (%d MCA), all NO-ORACLE, sha %s"
          % (len(unkeyed), sum(1 for u in unkeyed if u[2]), EXPECT_TOGGLE_SHA))
    print("PTX-class fragments in the file: 0 (E2/E4 enforce)")


# --------------------------------------------------------------------------
# --bite: each injection must redden the rule it names, for the right reason.
# --------------------------------------------------------------------------

def _expect_fail(what, marker, fn):
    try:
        fn()
    except Fail as e:
        if marker not in str(e):
            raise Fail("BITE %s: failed for the WRONG reason: %s" % (what, e))
        print("  bite %-28s OK (%s)" % (what, marker))
        return
    raise Fail("BITE %s: did not fire" % what)


def _clone(rows):
    return [list(r) for r in rows]


def bite(rows):
    n = 0
    x2a_frag = next(f for f, (b, t, d) in FRAGMENTS_STRUCK.items()
                    if t == "CMCM-6.2-X2a")

    # 1 unknown fragment inside an existing citation block
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad) if r[1] == "Disallowed" and "[" in r[3])
    bad[i][3] = bad[i][3].replace("]", "; Bogus Source 9.9]", 1)
    _expect_fail("unknown-fragment", "E1 unknown fragment", lambda: check(bad))
    n += 1

    # 2 unclassifiable bracket block
    bad = _clone(rows)
    bad[0][3] += " see also [not a citation]"
    _expect_fail("unknown-block", "E1 structure", lambda: check(bad))
    n += 1

    # 3 the D26 fault itself: a struck PTX fragment re-keyed onto a Disallowed
    #   row must fire the dangerous-direction rule (E2), not just rot (E4)
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad) if r[1] == "Disallowed" and "[" in r[3])
    bad[i][3] = bad[i][3].replace("]", "; %s]" % x2a_frag, 1)
    _expect_fail("ptx-into-disallowed", "E2", lambda: check(bad))
    n += 1

    # 4 the same struck fragment in an ALLOWED row is rot, not danger: E4
    #   fires (before D26 this direction was tolerated; post-strike the file
    #   is PTX-clean and any reappearance must be deliberate)
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad)
             if r[1] == "Allowed" and "[LLVM" in r[3])
    bad[i][3] = bad[i][3].replace("]", "; %s]" % x2a_frag, 1)
    _expect_fail("ptx-into-allowed", "E4", lambda: check(bad))
    n += 1

    # 5 omission: an UNKEYED row silently leaves the toggle set (its class
    #   string swapped for another NO-ORACLE class) -- census and E-rules all
    #   pass, only the toggle pin can see it
    ws_src = next(r[3] for r in rows if "release sub-shape" in r[3])
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad) if "UNKEYED" in r[3])
    bad[i][3] = ws_src
    _expect_fail("toggle-omission", "PIN toggle-set drift", lambda: check(bad))
    n += 1

    # 6 an UNKEYED row whose verdict is edited back to Disallowed: census pin
    #   fires first (it is the outer ledger), which is the right failure --
    #   a re-key must re-measure BOTH pins in one edit
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad) if "UNKEYED" in r[3])
    bad[i][1] = "Disallowed"
    _expect_fail("unkeyed-rearmed", "PIN census", lambda: check(bad))
    n += 1

    # 7 verdict flip on an ordinary row reddens the census pin
    bad = _clone(rows)
    i = next(i for i, r in enumerate(bad) if r[1] == "Allowed")
    bad[i][1] = "Disallowed"
    _expect_fail("verdict-flip", "PIN census", lambda: check(bad))
    n += 1

    # 8 a hole in the active table is E1 for every row that cites the entry
    holed = dict(FRAGMENTS)
    del holed["HSA PRM 6.2.1"]
    _expect_fail("table-hole", "E1 unknown fragment",
                 lambda: check(_clone(rows), table=holed))
    n += 1

    # 9 a stale active-table entry (never cited) reddens the used-set pin
    padded = dict(FRAGMENTS)
    padded["CMCM 3.1 p153:7 never actually cited"] = (GEN, "pad", KEY)
    _expect_fail("stale-entry", "PIN stale table entries",
                 lambda: check(_clone(rows), table=padded))
    n += 1

    # 10 row drop reddens the row-count pin
    _expect_fail("row-drop", "PIN rows", lambda: check(_clone(rows)[:-1]))
    n += 1

    print("amdprovcheck: BITE OK (%d injections)" % n)


def main():
    rows = read_rows()
    if "--bite" in sys.argv[1:]:
        bite(rows)
        return
    check(rows)
    report(rows)
    print("amdprovcheck: OK (post-D26 invariant: PTX-clean, toggle set pinned)")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print("amdprovcheck: FAIL -- %s" % e, file=sys.stderr)
        sys.exit(1)
