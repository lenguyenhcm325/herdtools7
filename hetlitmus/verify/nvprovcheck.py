#!/usr/bin/env python3
"""nvprovcheck.py -- the citation-PROVENANCE gate behind tests/het/expected-nvidia.csv.

NVOR Phase A.  The NVIDIA-lane mirror of amdprovcheck.py, which mechanized the
same fault for expected-amd.csv: the source whitelist admitted `[CMCM]' at
PAPER granularity, but transferability is a property of SECTIONS.  The AMD
regeneration (D26) demoted the 127 rows CMCM sect 5-6 carried.  The regen
handover's Step 4 pointed the same fault at the NVIDIA lane and was DROPPED
from that pass's scope, not resolved.  This file resurrects it.

GH200 is ARMv9 Grace + Hopper/PTX.  It inherits the PTX half of CMCM sect 5-6
and NOT its x86TSO half -- so the partition here is finer than the AMD one,
which could strike sect 5-6 wholesale:

  GEN          CMCM sect 3-4 incl 4.6 (the generalized LOST-POP framework,
               architecture-agnostic).  Admissible.
  PTX5         CMCM sect 5-6 PURE-PTX content.  Admissible in substance for
               GPU-side claims only -- but a NATIVE source exists (Lustig'19 /
               PTX ISA), so disposition is REPOINT, never KEY: the oracle must
               not rest on a non-native citation of the section the AMD lane
               struck.  Phase D re-points these.
  X86C         CMCM's x86TSO half and the compound COUPLING axioms (X1/X2a,
               gxhb, cmm.als, sect 6.2, Fig 2a, Fig 3).  INADMISSIBLE: those
               claims are about an x86TSO+PTX machine.  Fig 2a and Fig 3 are
               PRINTED in sect 1.1 but depict `T1 (PTX)'/`T5 (x86)' threads and
               the paper's own footnote 3 settles them "in our x86TSO/PTX
               compound memory model" -- the AMD figure-float gotcha extended:
               a figure's ADMISSIBILITY follows the machine it depicts, not the
               page it is printed on.  (Verified in the local PDF this session:
               sect 3.2.3 Scoped Operations, 4.3 Fences, 4.4 Scoped Requests,
               4.6 Composing LOST-POP Models, 5.1 Testing Our Models, 6.2
               Compound Model: Axiomatic Specification.)
  CMCM-BARE    `[CMCM]' with no section or figure number.  Unclassifiable at
               section granularity, therefore admissible for NOTHING -- this is
               literally the diagnosed D26 disease, and E5 names it.
  BAGCHI       Bagchi et al. ISMM'26, GH200-native.  Admissible.  Fragments
               that are non-observations ON THEIR FACE (a future-work pointer,
               a quoted "no test exhibited weak") are NOTE, never KEY: a
               non-observation never proves Disallowed.  The substantive
               observation-vs-non-observation audit is Phase C/A2.
  ARM          ARM ARM / ARMv9 RC facts, and herd7 under Arm's own validated
               aarch64.cat.  Admissible, CPU-native.
  PTX-L19      PTX content covered by Lustig'19's formal analysis (PTX 6.0-era
               forms: rel/acq ld/st, fence.acq_rel/sc, cta/gpu/sys).
               Admissible, GPU-native, formally analyzed.
  PTX-ISA-8.6  The same PTX fragments when they land on a `.rel-2s'/`.acq-2s'
               row.  `fence.{acquire,release}' is PTX ISA 8.6 / SM_90 and
               POSTDATES Lustig'19 (no unidirectional fences in its Fig 3c), so
               those rows key their GPU-side ord facts to vendor spec prose
               plus .cat extrapolation, not to the formalization.  Admissible
               as spec prose; the point of the class is that the exposure is
               COUNTED instead of hiding inside a uniform `PTX 3.3+Fig4+Fig6'
               citation.  Split is ROW-AWARE and applies to PTX-L19 fragments
               only -- a CMCM sect 5 citation is already REPOINT, so promoting
               it would silently upgrade it to key-grade.
  NONCMCM      everything else, per-tag: project-authored transcriptions
               (nvidia-ptx.cat, ordercheck) are INSTRUMENT and never a key
               (assume >=1 transcription error exists); `cf AMD ...' analogies
               are NOTE and never a key.

Rules, all direction-aware (a wrongly-Disallowed row manufactures a FALSE
REFUTATION of the compound model on hardware; Allowed and NO-ORACLE are
fail-safe -- except that under the Q0 ladder an Allowed row is an affirmative
claim too, which is what E6 is for):

  E1  a fragment or bracket block not in the table / not event notation.
      Hard failure: an unclassified citation anywhere means the table has gone
      stale, and a Source-string edit forces reclassification.
  E2  a Disallowed row citing an X86C-class fragment.  The dangerous direction
      of the D26 fault.
  E3  a Disallowed row with no admissible KEY fragment at all.
  E4  a STRUCK fragment reappears anywhere.  Hard failure.  The strike list is
      EMPTY in Phase A and arms in Phase D; the rule still executes on every
      fragment of every row (checked: see PIN strike-rule dead) so it cannot be
      dead code that quietly starts working.
  E5  a Disallowed row citing bare paper-granularity `[CMCM]'.
  E6  an Allowed row whose only support is a project-authored INSTRUMENT --
      no admissible KEY fragment at all.  Q0 consequence: a doubted Allowed
      can mis-score a real violation as ALLOWED-OBSERVED confirmation.

TEMPORARY FAULT PIN -- READ THIS BEFORE PHASE D.
Phase A is REPORT-ONLY (verdict-neutrality, P2e): nothing in the CSV moves
before Nguyen adjudicates the Phase C brief.  So E2/E3/E5/E6 do not redden the
gate today; instead their measured extent is PINNED, counts AND a sha256[:16]
over the sorted `<rule> <row>' offender set, exactly as amdprovcheck did
pre-D26.  Drift in EITHER direction reddens: a new fault appears, or a fault
quietly disappears without a registered re-key.

  measured 2026-08-05 on 411 rows (319 Allowed / 50 Disallowed / 42 NO-ORACLE):
    E2 = 2   MP-{cg,gc}-sys-acqrel-2s, keyed to CMCM Fig 2a
    E3 = 0
    E5 = 11  the diagonal classes S_MP_F/S_LB_RA/S_LB_F/S_S_RA/S_S_F/S_SBR_F
    E6 = 21  the ORDPAIR-ALLOWED-GPU rows (nvidia-ptx.cat + CMCM sect 5)
    fault-set sha 57298d22a8c3a260 over 34 labelled offender rows

  The campaign plan predicted "13 bare-CMCM Disallowed rows".  Measured E5 is
  11: class S_MP_RA (2 rows) cites `CMCM Fig2a', not bare `[CMCM]', so those
  two are E2 (inadmissible) rather than E5 (unclassifiable).  11 + 2 = the
  predicted 13; the split between the two diseases is what the mechanization
  adds.  E3 = 0 is measured, not assumed.

  PHASE D MUST FLIP THIS PIN to the clean invariant -- EXPECT_FAULTS all zero
  and the sha of the empty set -- in the SAME COMMIT as the regeneration, the
  way amdprovcheck's pre-D26 pin (E2 = 138 / E3 = 8 / at-risk 127) was flipped.
  A green gate here today means "the fault is exactly this big", NOT "there is
  no fault".

Also pinned: the census and row count; the 17 Disallowed rows in PTX-ISA-8.6
territory with their shape-cut histogram (LB-cg 5, MP-cg 3, MP-gc 3, S-cg 3,
S-gc 3) and sha, making the Lustig'19 version-drift arithmetic explicit;
freshness of the table (no unused entry); the bare-CMCM classification rule in
BOTH directions (a section-precise cite cannot be filed as bare, and a bare one
cannot be filed under a benign class); and the cheap confirmation invariant that
tests/gpu-only/expected-nvidia.csv -- machine-checked 137/137 by the
Lustig'19-native nvidia-ptx.cat -- stays CMCM-free.

Specification: the NVOR campaign plan, Phase A.  Sibling of amdprovcheck.py.

`--bite' corrupts the CSV, the tables and every pin and requires each injection
to redden the rule it names, for the right reason, on corruption and on
omission both, plus OVERFIRE guards that must leave the gate green.  The
injection COUNT is printed by the run itself, never by this comment (the
amdorder lesson: a comment said 33, the measured value was 35).
"""

import csv
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSV = ROOT / "hetlitmus" / "tests" / "het" / "expected-nvidia.csv"
GPU_ONLY_CSV = ROOT / "hetlitmus" / "tests" / "gpu-only" / "expected-nvidia.csv"

GEN, PTX5, X86C, CMCMBARE = "GEN", "PTX5", "X86C", "CMCM-BARE"
BAGCHI, ARM, PTXL19, PTX86, NONCMCM = (
    "BAGCHI", "ARM", "PTX-L19", "PTX-ISA-8.6", "NONCMCM")
KEY, INSTRUMENT, NOTE, REPOINT = "KEY", "INSTRUMENT", "NOTE", "REPOINT"

# A class is ADMISSIBLE if a claim of that provenance may stand behind a GH200
# verdict at all; a fragment is KEY-grade only if it is ALSO dispositioned KEY.
# PTX5 is deliberately in neither set: admissible in substance, REPOINT by
# disposition, so it can never silently carry a row (that is E6's 21 rows).
ADMISSIBLE = {GEN, BAGCHI, ARM, PTXL19, PTX86}
INADMISSIBLE = {X86C}

# --------------------------------------------------------------------------
# The fragment table: exact Source-string fragment -> (class, tag, disposition).
# Exact match is the point -- any edit to a citation is an unknown fragment
# (E1) until a human reclassifies it here.  Measured inventory, not invented:
# 34 distinct citation fragments across the 411 rows (plus two event-notation
# bracket blocks, `release.sys'/`acquire.sys', handled below).
# --------------------------------------------------------------------------
FRAGMENTS = {
    # -- CMCM at paper granularity: the D26 disease itself.
    "CMCM": (CMCMBARE, "CMCM-bare", NOTE),
    # -- CMCM sect 3-4: the architecture-agnostic framework.  Admissible.
    "CMCM 3.2.3+4.4+4.6": (GEN, "CMCM-3.2.3/4.4/4.6", KEY),
    "CMCM 4.3 fence orderings": (GEN, "CMCM-4.3", KEY),
    # -- CMCM sect 5-6, pure PTX: admissible GPU-side, but re-point (Phase D).
    "CMCM 5 PTX sem>=rel/acq": (PTX5, "CMCM-5-ord", REPOINT),
    # -- CMCM x86TSO half / compound coupling: INADMISSIBLE on this machine.
    #    5.1+Fig11+6.2 is a MIXED fragment (5.1 is PTX-side, 6.2 is the
    #    compound axiomatic spec); fail-closed, it takes the class of its most
    #    restrictive component.
    "CMCM 5.1+Fig11+6.2": (X86C, "CMCM-5.1/Fig11/6.2", KEY),
    "CMCM Fig2a": (X86C, "CMCM-Fig2a", KEY),
    "CMCM Fig3": (X86C, "CMCM-Fig3", KEY),
    # -- Bagchi ISMM'26, GH200-native.  KEY except where the fragment is a
    #    non-observation on its face (never proves Disallowed).
    "Bagchi 3.2+4.2": (BAGCHI, "Bagchi-3.2/4.2", KEY),
    "Bagchi 4.1 Tab3 DMB": (BAGCHI, "Bagchi-Tab3", KEY),
    "Bagchi 4.1 Tab3 both-sided fence + 4.2 Tab4":
        (BAGCHI, "Bagchi-Tab3/Tab4", KEY),
    "Bagchi 4.2 Tab4 'no correctly synchronized system-scope test exhibited weak'":
        (BAGCHI, "Bagchi-Tab4-nonobs", NOTE),
    "Bagchi 4.2 future-work": (BAGCHI, "Bagchi-futurework", NOTE),
    "Bagchi 5 CPU-GPU coherence": (BAGCHI, "Bagchi-5-coh", KEY),
    "Bagchi 5 coherence": (BAGCHI, "Bagchi-5-coh", KEY),
    "Bagchi Fig2a": (BAGCHI, "Bagchi-Fig2a", KEY),
    "Bagchi Fig4e/r21-22": (BAGCHI, "Bagchi-Fig4e", KEY),
    "Bagchi Tab4": (BAGCHI, "Bagchi-Tab4", KEY),
    "Bagchi r3-5": (BAGCHI, "Bagchi-r3-5", KEY),
    # -- CPU-native.  herd7 here runs Arm's own validated aarch64.cat, which is
    #    key-grade for AArch64 per-device facts -- unlike the project-authored
    #    nvidia-ptx.cat transcription below.
    "ARM RCpc": (ARM, "ARM-RCpc", KEY),
    "ARMv9": (ARM, "ARMv9", KEY),
    "ARMv9 LDAPR": (ARM, "ARMv9-LDAPR", KEY),
    "ARMv9 RC": (ARM, "ARMv9-RC", KEY),
    "machine-checked herd7 AArch64 via verify/ordercheck.py":
        (ARM, "herd7-aarch64", KEY),
    # -- GPU-native (Lustig'19).  Row-aware promotion to PTX-ISA-8.6 below.
    "PTX 3.3": (PTXL19, "PTX-3.3", KEY),
    "PTX 3.3 RC": (PTXL19, "PTX-3.3-RC", KEY),
    "PTX 3.3+Fig4+Fig6": (PTXL19, "PTX-3.3/Fig4/Fig6", KEY),
    "PTX Fig4/Fig7": (PTXL19, "PTX-Fig4/Fig7", KEY),
    "PTX non-MCA": (PTXL19, "PTX-nonMCA", KEY),
    "PTX sc-fence": (PTXL19, "PTX-scfence", KEY),
    "PTX-relaxed": (PTXL19, "PTX-relaxed", KEY),
    # -- project-authored instruments: consistency evidence, never truth.
    "machine-checked nvidia-ptx.cat via verify/ordercheck.py":
        (NONCMCM, "nvidia-ptx.cat", INSTRUMENT),
    "machine-checked verify/ordercheck.py": (NONCMCM, "ordercheck", INSTRUMENT),
    # -- cross-vendor analogies: NOTE, never a key.
    "cf AMD LB-sys": (NONCMCM, "cf-AMD", NOTE),
    "cf AMD SB-sys": (NONCMCM, "cf-AMD", NOTE),
}

# Struck fragments: EMPTY in Phase A, armed in Phase D when the regeneration
# removes strings.  E4 recognises a reappearance instead of merely reporting it
# unknown.  Keeping it empty is itself pinned (PIN strike-list).
FRAGMENTS_STRUCK = {}

# A bracket block is a CITATION block iff its first token opens with one of
# these; the only other bracket in any Source string is comma-free event
# notation like `release.sys' from `w[release.sys]/r[acquire.sys]'.
CITATION_OPENERS = ("CMCM", "Bagchi", "ARM", "PTX", "cf AMD", "machine-checked")
EVENT_NOTATION = re.compile(r"[a-z]+\.[a-z]+\Z")

# A CMCM fragment is section- or figure-precise iff it names a number right
# after the tag.  Anything else claiming to be CMCM is paper-granularity and
# MUST be filed CMCM-BARE -- enforced in both directions so neither a bare cite
# can hide under a benign class nor a precise one be filed away as bare.
CMCM_PRECISE = re.compile(r"^CMCM (\d|Fig\d)")

# `fence.{acquire,release}' is PTX ISA 8.6 / SM_90 and postdates Lustig'19.
# The corpus spells those cells `.rel-2s' / `.acq-2s' in the test name.
SPEC86_ROW = re.compile(r"\.(rel|acq)-2s")

# ---- pins: the shape of the committed CSV -------------------------------
EXPECT_ROWS = 411
EXPECT_CENSUS = {"Allowed": 319, "Disallowed": 50, "NO-ORACLE": 42}

# TEMPORARY fault pin -- see the module docstring.  Phase D flips this to zeros.
EXPECT_FAULTS = {"E2": 2, "E3": 0, "E5": 11, "E6": 21}
EXPECT_FAULT_SHA = "57298d22a8c3a260"   # sha256[:16] of sorted "<rule> <row>"

# The Lustig'19 version-drift exposure, made arithmetic.
EXPECT_86_ROWS = 17
EXPECT_86_SHA = "7214d368f5078129"      # sha256[:16] of the sorted 17 names
EXPECT_86_HIST = {"LB-cg": 5, "MP-cg": 3, "MP-gc": 3, "S-cg": 3, "S-gc": 3}

# The gpu-only corpus is a CONFIRMATION invariant only: Lustig'19-native,
# machine-checked 137/137, never regenerated.  The row-count pin is what makes
# "zero CMCM citations" mean something -- an emptied file greps clean too.
EXPECT_GPU_ONLY_ROWS = 137


class Fail(Exception):
    pass


def read_rows(path=CSV, text=None):
    """Rows as (name, verdict, model, source).

    38 Source strings carry a comma (advisory prose, byte-stable on purpose),
    which splits them across CSV fields 4..n; fields 4+ are rejoined so the
    fragment parser sees the whole citation.
    """
    raw = text if text is not None else Path(path).read_text()
    lines = [l for l in raw.splitlines() if l and not l.startswith("#")]
    rows = list(csv.reader(lines))[1:]
    out = []
    for r in rows:
        if len(r) < 4:
            raise Fail("E1 structure: row has fewer than 4 fields: %r" % r[:1])
        out.append((r[0], r[1], r[2], ",".join(r[3:])))
    return out


def fragments_of(name, source):
    """All citation fragments of one Source string, or Fail on E1 structure."""
    frags = []
    for block in re.findall(r"\[([^\]]*)\]", source):
        if block.startswith(CITATION_OPENERS):
            frags.extend(f.strip() for f in block.split(";"))
        elif EVENT_NOTATION.fullmatch(block):
            continue                    # prose event notation, not a citation
        else:
            raise Fail("E1 structure: unclassifiable bracket block [%s] "
                       "on row %s" % (block, name))
    return frags


def audit(rows, table=None, struck=None):
    """Classify every fragment of every row.

    Returns (findings, used, census, rows86, probes, byclass).  E1 and E4 raise
    at once (fail-closed); E2/E3/E5/E6 are collected for the temporary fault
    pin.  `byclass' counts EFFECTIVE classes -- i.e. after the row-aware
    PTX-L19 -> PTX-ISA-8.6 promotion -- so the report cannot claim the
    version-drift class is empty while 22 uses sit inside PTX-L19.
    """
    table = FRAGMENTS if table is None else table
    struck = FRAGMENTS_STRUCK if struck is None else struck
    findings = {"E2": [], "E3": [], "E5": [], "E6": []}
    used, census, rows86 = {}, {}, []
    byclass = {}
    probes = 0
    for name, verdict, _model, source in rows:
        census[verdict] = census.get(verdict, 0) + 1
        eff = []
        for f in fragments_of(name, source):
            probes += 1                 # the E4 rule executes on every fragment
            if f in struck:
                raise Fail("E4 struck fragment reappeared: row %s cites %r "
                           "(struck tag %s) -- citation rot must come with a "
                           "deliberate table update" % (name, f, struck[f][1]))
            if f not in table:
                raise Fail("E1 unknown fragment (reclassify in FRAGMENTS): "
                           "row %s: %r" % (name, f))
            cls, tag, disp = table[f]
            used[f] = used.get(f, 0) + 1
            # ROW-AWARE split: a Lustig'19-class PTX citation standing on a
            # unidirectional-fence row is de facto PTX ISA 8.6 territory.
            if cls == PTXL19 and SPEC86_ROW.search(name):
                cls = PTX86
            nfr, nus = byclass.get(cls, (set(), 0))
            byclass[cls] = (nfr | {f}, nus + 1)
            eff.append((cls, tag, disp))
        haskey = any(c in ADMISSIBLE and d == KEY for c, _t, d in eff)
        if verdict == "Disallowed":
            if any(c in INADMISSIBLE for c, _t, _d in eff):
                findings["E2"].append(name)
            if not haskey:
                findings["E3"].append(name)
            if any(c == CMCMBARE for c, _t, _d in eff):
                findings["E5"].append(name)
            if any(c == PTX86 for c, _t, _d in eff):
                rows86.append(name)
        elif verdict == "Allowed":
            if not haskey and any(d == INSTRUMENT for _c, _t, d in eff):
                findings["E6"].append(name)
    return findings, used, census, sorted(rows86), probes, byclass


def fault_sha(findings):
    lab = sorted("%s %s" % (rule, n) for rule, ns in findings.items() for n in ns)
    return hashlib.sha256("\n".join(lab).encode()).hexdigest()[:16], len(lab)


def check_gpu_only(text=None):
    """Confirmation invariant: the Lustig'19-native gpu-only oracle is CMCM-free."""
    raw = text if text is not None else GPU_ONLY_CSV.read_text()
    data = [l for l in raw.splitlines()
            if l and not l.startswith("#") and not l.startswith("Litmus,")]
    if len(data) != EXPECT_GPU_ONLY_ROWS:
        raise Fail("PIN gpu-only rows: %d != %d -- the CMCM-free grep is only "
                   "meaningful over the whole 137-row corpus"
                   % (len(data), EXPECT_GPU_ONLY_ROWS))
    hits = [l.split(",")[0] for l in data if "cmcm" in l.lower()]
    if hits:
        raise Fail("PIN gpu-only CMCM: the pure-PTX corpus must cite no CMCM "
                   "at all (it is machine-checked by Lustig'19-native "
                   "nvidia-ptx.cat); offending row(s): %r" % hits[:4])
    return len(data)


def check(rows, table=None, struck=None, gpu_only_text=None):
    """Assert every pin; Fail on the first violation.  Returns the audit."""
    tbl = FRAGMENTS if table is None else table
    strk = FRAGMENTS_STRUCK if struck is None else struck
    if len(rows) != EXPECT_ROWS:
        raise Fail("PIN rows: %d != %d" % (len(rows), EXPECT_ROWS))

    # the bare-CMCM classification rule, both directions
    for f, (cls, _tag, _disp) in sorted(tbl.items()):
        if not f.startswith("CMCM"):
            continue
        precise = bool(CMCM_PRECISE.match(f))
        if precise and cls == CMCMBARE:
            raise Fail("PIN bare-CMCM classification: %r names a section or "
                       "figure yet is filed CMCM-BARE" % f)
        if not precise and cls != CMCMBARE:
            raise Fail("PIN bare-CMCM classification: %r is paper-granularity "
                       "and must be filed %s -- it is filed %s, which would "
                       "hide the D26 disease from E5" % (f, CMCMBARE, cls))

    findings, used, census, rows86, probes, byclass = audit(rows, tbl, strk)

    # the E4 rule must be LIVE, not dead code waiting for Phase D
    if probes == 0:
        raise Fail("PIN strike-rule dead: not one fragment was classified, so "
                   "the E4 strike lookup never executed")
    if strk:
        raise Fail("PIN strike-list: the Phase-A strike list must be EMPTY "
                   "(it arms in Phase D); found %r" % sorted(strk))

    if census != EXPECT_CENSUS:
        raise Fail("PIN census: %r != %r" % (census, EXPECT_CENSUS))
    stale = set(tbl) - set(used)
    if stale:
        raise Fail("PIN stale table entries (unused, re-measure): %r"
                   % sorted(stale))

    # the Lustig'19 version-drift exposure
    hist = {}
    for n in rows86:
        k = "-".join(n.split("-")[:2])
        hist[k] = hist.get(k, 0) + 1
    sha86 = hashlib.sha256("\n".join(rows86).encode()).hexdigest()[:16]
    if (len(rows86) != EXPECT_86_ROWS or sha86 != EXPECT_86_SHA
            or hist != EXPECT_86_HIST):
        raise Fail("PIN 8.6-split: %d Disallowed rows in PTX-ISA-8.6 territory "
                   "(sha %s hist %r) != pinned %d (sha %s hist %r) -- the "
                   "Lustig'19 version-drift exposure changed"
                   % (len(rows86), sha86, hist,
                      EXPECT_86_ROWS, EXPECT_86_SHA, EXPECT_86_HIST))

    # the TEMPORARY fault pin (Phase D flips it to zeros)
    counts = {k: len(v) for k, v in findings.items()}
    sha, nfault = fault_sha(findings)
    drift = [k for k in sorted(EXPECT_FAULTS) if counts[k] != EXPECT_FAULTS[k]]
    if not drift and sha != EXPECT_FAULT_SHA:
        drift = ["sha"]
    if drift:
        raise Fail("PIN fault-set drift %s: measured %r sha %s (%d offenders) "
                   "!= pinned %r sha %s -- a provenance fault appeared or "
                   "disappeared without the pin being re-measured; Phase D "
                   "flips this pin to zeros"
                   % ("".join("[%s]" % d for d in drift), counts, sha, nfault,
                      EXPECT_FAULTS, EXPECT_FAULT_SHA))

    ngpu = check_gpu_only(gpu_only_text)
    return findings, used, census, rows86, byclass, hist, ngpu


def report(rows):
    findings, _used, census, rows86, byclass, hist, ngpu = check(rows)
    print("nvprovcheck: %d rows %r" % (len(rows), census))
    print("fragment inventory: %d distinct citation fragments; effective "
          "classes (after the row-aware 8.6 promotion):" % len(FRAGMENTS))
    for c in sorted(byclass):
        frags, uses = byclass[c]
        print("  %-12s %2d fragments %4d uses" % (c, len(frags), uses))
    # every number below is MEASURED by this run, never a pinned constant
    # read back at the reader (the amdorder lesson, applied to the report too)
    print("PTX-ISA-8.6 territory: %d of %d Disallowed rows key their GPU-side "
          "ord facts to spec prose postdating Lustig'19 %r"
          % (len(rows86), census["Disallowed"], dict(sorted(hist.items()))))
    sha, nfault = fault_sha(findings)
    print("TEMPORARY fault pin (Phase D must flip this to zeros): %r sha %s "
          "over %d offender rows"
          % ({k: len(v) for k, v in findings.items()}, sha, nfault))
    print("  E2 %r" % sorted(findings["E2"]))
    print("  E5 %r" % sorted(findings["E5"]))
    print("  E6 %d rows: %r ..." % (len(findings["E6"]),
                                    sorted(findings["E6"])[:3]))
    print("strike list: %d entries (arms in Phase D; E4 still executes)"
          % len(FRAGMENTS_STRUCK))
    print("gpu-only corpus: %d rows CMCM-free" % ngpu)


# --------------------------------------------------------------------------
# --bite: each injection must redden the rule it NAMES, for the right reason;
# the overfire guards must leave the gate GREEN.
# --------------------------------------------------------------------------

def _expect_fail(what, marker, fn):
    try:
        fn()
    except Fail as e:
        if marker not in str(e):
            raise Fail("BITE %s: failed for the WRONG reason (wanted %r): %s"
                       % (what, marker, e))
        print("  bite %-26s FAILS   (%s)" % (what, marker))
        return
    raise Fail("BITE %s: did not fire" % what)


def _expect_pass(what, why, base, mutated, fn):
    """An overfire guard: the injection must be REAL and must leave the gate
    green.  Without the vacuity assertion an injection that silently changed
    nothing would `prove' the rule does not overfire, which is the same trap as
    a gate that never bites."""
    if [list(r) for r in base] == [list(r) for r in mutated]:
        raise Fail("BITE %s: VACUOUS -- the injection changed nothing, so the "
                   "overfire guard proves nothing" % what)
    try:
        fn()
    except Fail as e:
        raise Fail("BITE %s: OVERFIRE -- %s, yet the gate reddened: %s"
                   % (what, why, e))
    print("  bite %-26s green   (overfire guard: %s)" % (what, why))


def _clone(rows):
    return [list(r) for r in rows]


def _find(rows, pred):
    return next(i for i, r in enumerate(rows) if pred(r))


def _append_frag(src, frag):
    """Splice a fragment into the LAST bracket block.

    Not `replace("]", ...)': the order-pair Source strings name the GPU
    primitive `w[release.sys]/r[acquire.sys]', so the first `]' belongs to
    event notation and an injection aimed there would fire E1-structure --
    the right rule for the wrong reason.
    """
    m = list(re.finditer(r"\[[^\]]*\]", src))[-1]
    return src[:m.end() - 1] + "; " + frag + src[m.end() - 1:]


def bite(rows):
    n = 0
    ORD_D = "CMCM 3.2.3+4.4+4.6"           # an ORDPAIR-DISALLOWED row's key
    INSTR = "machine-checked verify/ordercheck.py"
    GPUCAT = "machine-checked nvidia-ptx.cat via verify/ordercheck.py"

    # 1 unknown fragment inside an existing citation block
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = _append_frag(bad[i][3], "Bogus Source 9.9")
    _expect_fail("unknown-fragment", "E1 unknown fragment", lambda: check(bad))
    n += 1

    # 2 unclassifiable bracket block
    bad = _clone(rows)
    bad[0][3] += " see also [not a citation]"
    _expect_fail("unknown-block", "E1 structure", lambda: check(bad))
    n += 1

    # 3 a hole in the active table is E1 for every row that cites the entry
    holed = dict(FRAGMENTS)
    del holed["PTX sc-fence"]
    _expect_fail("table-hole", "E1 unknown fragment",
                 lambda: check(_clone(rows), table=holed))
    n += 1

    # 4 E2 up: an X86C fragment lands on a Disallowed row that had none
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM Fig3")
    _expect_fail("e2-x86c-into-disallowed", "[E2]", lambda: check(bad))
    n += 1

    # 5 E2 down: the two Fig2a rows re-keyed away without a registered re-key
    bad = _clone(rows)
    for r in bad:
        if r[1] == "Disallowed":
            r[3] = r[3].replace("CMCM Fig2a", "CMCM 3.2.3+4.4+4.6")
    _expect_fail("e2-silent-disappear", "[E2]", lambda: check(bad))
    n += 1

    # 6 E2 OVERFIRE GUARD: the same X86C fragment on an ALLOWED row must not
    #   fire -- E2 is direction-aware (24 Allowed rows already cite CMCM Fig2a)
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "ARMv9 RC" in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM Fig3")
    _expect_pass("e2-overfire-allowed",
                 "an inadmissible cite on an Allowed row is the fail-safe "
                 "direction", rows, bad, lambda: check(bad))
    n += 1

    # 7 E3: a Disallowed row stripped down to an instrument-only citation
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[%s]" % INSTR, bad[i][3])
    _expect_fail("e3-keyless-disallowed", "[E3]", lambda: check(bad))
    n += 1

    # 8 E4: a struck fragment that IS cited must be recognised as rot, not
    #   merely counted -- the Phase-D mechanism proved live in Phase A
    armed = {"PTX sc-fence": (PTXL19, "fake-strike", KEY)}
    _expect_fail("e4-strike-reappearance", "E4 struck fragment reappeared",
                 lambda: check(_clone(rows), struck=armed))
    n += 1

    # 9 the strike list itself must stay empty until Phase D arms it
    idle = {"CMCM 6.2 x86 write/read are sys-scoped rel/acq": (X86C, "x", KEY)}
    _expect_fail("e4-strike-list-armed", "PIN strike-list",
                 lambda: check(_clone(rows), struck=idle))
    n += 1

    # 10 E5 up: bare [CMCM] added to a Disallowed row that cited sections
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM")
    _expect_fail("e5-bare-cmcm-added", "[E5]", lambda: check(bad))
    n += 1

    # 11 E5 down: one diagonal row silently re-keyed section-precise
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and "; Bagchi 4.1 Tab3 DMB;" in r[3])
    bad[i][3] = bad[i][3].replace("[CMCM;", "[CMCM 3.2.3+4.4+4.6;", 1)
    _expect_fail("e5-silent-disappear", "[E5]", lambda: check(bad))
    n += 1

    # 12 E5 OVERFIRE GUARD: bare [CMCM] on an Allowed row is not E5 (228 rows
    #    already do it) -- E5 is the Disallowed-only, dangerous direction
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "machine-checked herd7" in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM")
    _expect_pass("e5-overfire-allowed",
                 "paper-granularity cites on Allowed rows are fail-safe",
                 rows, bad, lambda: check(bad))
    n += 1

    # 13 E6 up: an Allowed row's admissible keys replaced by an instrument
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "machine-checked herd7" in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[%s]" % GPUCAT, bad[i][3])
    _expect_fail("e6-instrument-only", "[E6]", lambda: check(bad))
    n += 1

    # 14 E6 down: one instrument-keyed Allowed row quietly given a real key
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "CMCM 5 PTX sem>=rel/acq" in r[3])
    bad[i][3] = _append_frag(bad[i][3], "PTX 3.3")
    _expect_fail("e6-silent-disappear", "[E6]", lambda: check(bad))
    n += 1

    # 15 E6 OVERFIRE GUARD: citing an instrument is not itself the fault --
    #    the 46 herd7-AArch64 Allowed rows keep their admissible keys
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "machine-checked herd7" in r[3])
    bad[i][3] = _append_frag(bad[i][3], GPUCAT)
    _expect_pass("e6-overfire-instrument",
                 "an Allowed row that also has admissible keys is not E6",
                 rows, bad, lambda: check(bad))
    n += 1

    # 16 fault-set sha: counts held equal while the offenders move rows
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and "; Bagchi 4.1 Tab3 DMB;" in r[3])
    bad[i][3] = bad[i][3].replace("[CMCM;", "[CMCM 3.2.3+4.4+4.6;", 1)
    j = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[j][3] = _append_frag(bad[j][3], "CMCM")
    _expect_fail("fault-sha-swap", "PIN fault-set drift [sha]",
                 lambda: check(bad))
    n += 1

    # 17 the 8.6 split: one unidirectional-fence row renamed out of territory
    bad = _clone(rows)
    i = _find(bad, lambda r: r[0] == "LB-cg-sys-ld.rel-2s")
    bad[i][0] = "LB-cg-sys-ld.ra-2s"
    _expect_fail("split86-shrink", "PIN 8.6-split", lambda: check(bad))
    n += 1

    # 18 census drift
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed")
    bad[i][1] = "Disallowed"
    _expect_fail("verdict-flip", "PIN census", lambda: check(bad))
    n += 1

    # 19 row drop
    _expect_fail("row-drop", "PIN rows", lambda: check(_clone(rows)[:-1]))
    n += 1

    # 20 a stale table entry (never cited) reddens the freshness pin
    padded = dict(FRAGMENTS)
    padded["CMCM 3.1 never actually cited"] = (GEN, "pad", KEY)
    _expect_fail("stale-entry", "PIN stale table entries",
                 lambda: check(_clone(rows), table=padded))
    n += 1

    # 21 bare [CMCM] refiled under a benign class -- the way this gate could be
    #    silently defeated without touching a single Source string
    laundered = dict(FRAGMENTS)
    laundered["CMCM"] = (GEN, "CMCM-laundered", KEY)
    _expect_fail("bare-cmcm-laundered", "PIN bare-CMCM classification",
                 lambda: check(_clone(rows), table=laundered))
    n += 1

    # 22 ... and the converse: a section-precise cite filed away as bare
    misfiled = dict(FRAGMENTS)
    misfiled["CMCM 4.3 fence orderings"] = (CMCMBARE, "x", NOTE)
    _expect_fail("precise-cmcm-misfiled", "PIN bare-CMCM classification",
                 lambda: check(_clone(rows), table=misfiled))
    n += 1

    # 23 the E4 lookup proved live: strip every citation and the liveness pin
    #    fires before any downstream pin can mask it
    bad = [[r[0], r[1], r[2], re.sub(r"\[[^\]]*\]", "", r[3])] for r in rows]
    _expect_fail("strike-rule-dead", "PIN strike-rule dead", lambda: check(bad))
    n += 1

    # 24 the gpu-only confirmation corpus grows a CMCM citation
    poisoned = ("Litmus,Expected,Model,Source\n"
                + "\n".join("t%d,Allowed,PTX,ok" % k
                            for k in range(EXPECT_GPU_ONLY_ROWS - 1))
                + "\ntBAD,Allowed,PTX,derived from [CMCM 6.2]\n")
    _expect_fail("gpu-only-cmcm", "PIN gpu-only CMCM",
                 lambda: check(_clone(rows), gpu_only_text=poisoned))
    n += 1

    # 25 ... and an emptied gpu-only corpus, which would grep CMCM-free
    _expect_fail("gpu-only-emptied", "PIN gpu-only rows",
                 lambda: check(_clone(rows),
                               gpu_only_text="Litmus,Expected,Model,Source\n"))
    n += 1

    print("nvprovcheck: BITE OK (%d injections)" % n)


def main():
    rows = read_rows()
    if "--bite" in sys.argv[1:]:
        bite(rows)
        return
    report(rows)
    print("nvprovcheck: OK (TEMPORARY fault pin holds -- the fault is exactly "
          "this big, and Phase D must flip the pin to zeros)")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print("nvprovcheck: FAIL -- %s" % e, file=sys.stderr)
        sys.exit(1)
