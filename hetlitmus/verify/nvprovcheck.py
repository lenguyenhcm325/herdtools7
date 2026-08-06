#!/usr/bin/env python3
"""nvprovcheck.py -- the citation-PROVENANCE gate behind tests/het/expected-nvidia.csv.

NVOR Phases A (mechanize) and D2 (repair + flip).  The NVIDIA-lane mirror of
amdprovcheck.py, which mechanized the same fault for expected-amd.csv: the
source whitelist admitted `[CMCM]' at PAPER granularity, but transferability is
a property of SECTIONS.  The AMD regeneration (D26) demoted the 127 rows CMCM
sect 5-6 carried; the NVOR regeneration (Phase D1, 2026-08-06) demoted 32 more
here.  This file is the mechanism that keeps the fault out.

POST-REGENERATION POSTURE -- READ THIS FIRST.
Phase A pinned the fault NUMERICALLY (E2 = 2 / E3 = 0 / E5 = 11 / E6 = 21, sha
57298d22a8c3a260 over 34 offender rows) because the CSV could not move before
Nguyen adjudicated.  It has now moved.  This file therefore documents the
ABSENCE of the fault, exactly as amdprovcheck's pre-D26 pin (E2 = 138 / E3 = 8 /
at-risk 127) was flipped to post-strike invariants: EVERY rule pins at ZERO and
drift in either direction reddens.

That flip is only honest over a parser that can SEE a re-introduced fault, and
Phase C's counter-probe (R2 sect 5, `env-research/nvor/phaseC/R2-counterprobe.md')
measured that the Phase-A parser could not.  Its four scenarios -- bare CMCM
re-added as `[cmcm.paper]', Fig 2a re-added as inline prose, Fig 2a re-added as
`[cmcm.figtwoa]', the gxhb coupling axiom re-added as `[gxhb.cmm]' -- ALL passed
GATE GREEN against a zeroed pin.  So the pin flip and the parser repairs land in
ONE commit (R2's B5 rule), each bitten:

  B1  `EVENT_NOTATION' was a regex (`[a-z]+\\.[a-z]+') that was fullmatched and
      `continue'd with NO error, so ANY lowercase-dotted block parsed to zero
      fragments in silence.  It is now an EXACT whitelist of the only two event
      strings the corpus emits, and anything else is E1.
  B2  a citation in inline prose was invisible.  The whole Source string is now
      scanned OUTSIDE the brackets too (E2/E4/E7).
  B3  a citation appended after the last `]' was invisible.  Same scan.
  B4  E6 fired only on an INSTRUMENT-carrying keyless Allowed row; strip the
      instrument and it reported 0.  E6 is now KEYLESS-Allowed, which is the
      condition the Q0 ladder actually cares about.
  B6  E2/E5 were Disallowed-only and no rule looked at NO-ORACLE rows at all.
      E2 is now corpus-wide, and E8 checks that every NVOR-demoted row names
      its own registration ID.

Admissibility partition.  GH200 is ARMv9 Grace + Hopper/PTX.  It inherits the
PTX half of CMCM sect 5-6 and NOT its x86TSO half -- a finer partition than the
AMD lane's wholesale strike:

  GEN          CMCM sect 3-4 incl 4.2/4.3/4.6 and footnote 7 (the generalized
               LOST-POP framework, architecture-agnostic).  Admissible.
  PTX5         CMCM sect 5-6 PURE-PTX content.  Admissible in substance for
               GPU-side claims only -- but a NATIVE source exists (Lustig'19 /
               PTX ISA), so disposition is REPOINT, never KEY.
  X86C         CMCM's x86TSO half and the compound COUPLING axioms (X1/X2a,
               gxhb, cmm.als, sect 6.2, Fig 2a, Fig 3).  INADMISSIBLE: those
               claims are about an x86TSO+PTX machine.  Fig 2a and Fig 3 are
               PRINTED in sect 1.1 but depict `T1 (PTX)'/`T5 (x86)' threads --
               a figure's ADMISSIBILITY follows the machine it depicts, not the
               page it is printed on.  Every X86C string is now STRUCK: the
               regeneration removed all three from the CSV (register NVOR-Q6),
               so E2 is an asserted absence and E4 recognises a reappearance
               instead of merely reporting it unknown.
  CMCM-BARE    `[CMCM]' with no section or figure number.  Unclassifiable at
               section granularity, therefore admissible for NOTHING.  E5 names
               it on Disallowed rows.  It survives on 252 ALLOWED rows (register
               open item O1) -- a class-level sweep deferred out of D1's scope,
               fail-safe because every one of those rows is a NEGATIVE class
               rule that already carries a real key beside the bare fragment.
               The count is PINNED as a disclosure so the debt cannot grow, or
               shrink, unnoticed.
  BAGCHI       Bagchi et al. ISMM'26, GH200-native.  Direction-aware by
               construction: a fragment that reports an OBSERVATION is KEY;
               a GAP, a QUALIFIER, a disclosure or a future-work pointer is a
               non-observation ON ITS FACE and is NOTE, because a
               non-observation never proves Disallowed.  Which corpus row each
               observation actually anchors is a different question, and
               nvprovcheck structurally cannot see it (R2 B7: demote every
               Bagchi fragment to NOTE and not one E-rule moves) -- that is
               verify/nvanchorcheck.py.
  ARM          ARM ARM / ARMv9 RC facts, `bob' in Arm Ltd's own validated
               aarch64.cat, and herd7 run under it.  Admissible, CPU-native.
               The Armed Cats paper is cited as model-family LINEAGE, not as
               the decider, so it is NOTE (register sect 3 item 3c).
  PTX-L19      PTX content covered by Lustig'19's formal analysis (PTX 6.0-era
               forms: rel/acq ld/st, fence.acq_rel/sc, cta/gpu/sys).
               Admissible, GPU-native, formally analyzed.
  PTX-ISA-9.3  NVIDIA's current PTX ISA spec prose, version-qualified in every
               fragment (R2 M5: a bare table number is unverifiable a year
               later).  Admissible, vendor-normative.
  PTX-ISA-8.6  Either of the two PTX classes above WHEN THE ROW IS IN THE
               UNIDIRECTIONAL-FENCE NAMESPACE.  `fence.{acquire,release}' is
               PTX ISA 8.6 / SM_90 and POSTDATES Lustig'19 (no unidirectional
               fence in its Fig 3c grammar), so on those rows the GPU-side ord
               fact rests on spec prose plus a .cat extrapolation, not on the
               formalization.  The class exists so the exposure is COUNTED
               rather than hidden inside a uniform PTX citation.  Row-aware,
               and it applies to PTX-L19/PTX-ISA-9.3 only -- a CMCM sect 5
               citation is already REPOINT, so promoting it would silently
               upgrade it to key-grade.
  REGISTRATION `decision NVOR-*' and `NVOR-register.md'.  A REGISTRATION IS NOT
               A CITATION.  Its disposition can never be KEY and its class is
               not admissible: if a registered decision counted as its own
               support, E3 would be satisfiable by writing down the decision
               that needs support, and the rule would die.  Pinned in the table
               (PIN registration-not-a-key), not merely intended.
  NONCMCM      everything else, per-tag: project-authored transcriptions
               (nvidia-ptx.cat) are INSTRUMENT and never a key (assume >=1
               transcription error exists); `cf AMD ...' analogies are NOTE and
               never a key.

Rules, all fail-closed.  A wrongly-Disallowed row manufactures a FALSE
REFUTATION of the compound model on hardware; Allowed and NO-ORACLE are
fail-safe -- except that under the Q0 ladder an Allowed row is an affirmative
claim too, which is what E6 is for.

  E1  a fragment or bracket block not in the tables / not one of the two event
      strings.  RAISES: an unclassified citation anywhere means the table has
      gone stale, and a Source-string edit forces reclassification.
  E2  an X86C-class fragment on ANY row -- Allowed and NO-ORACLE included (B6).
      The D26 fault, asserted absent corpus-wide.
  E3  a Disallowed row with no admissible KEY fragment at all.
  E4  a STRUCK fragment reappears anywhere, bracketed OR inline.
  E5  a Disallowed row citing bare paper-granularity `[CMCM]'.
  E6  a KEYLESS Allowed row -- no admissible KEY fragment at all, whether or
      not it also cites an instrument (B4).  Q0 consequence: a doubted Allowed
      can absorb a real violation as an ALLOWED-OBSERVED "confirmation".
  E7  a known citation string sitting OUTSIDE every bracket (B2/B3), where no
      rule can grade it.  Registration IDs are exempt: prose names them on
      purpose ("DISCLOSED (decision NVOR-Q4b lenient): ..."), and a
      registration is never a key, so laundering one gains nothing.
  E8  an NVOR-demoted NO-ORACLE row that does not name its own registration ID.
      Second implementation: verify/ordercheck.py's `nvor_slots' derives the
      demotion set from a differently-derived cycle table and asserts the same
      per-row property; the SET pins below are what catch two implementations
      agreeing in the same wrong direction.

Also pinned: the post-regeneration census 319/18/74 and the row count; the
32-row demotion set by count, by per-registration histogram and by sha
71ebe7baba4fbb83 (the builder's own pin -- a count alone survives demoting the
WRONG 32 rows); the unidirectional-fence namespace as a SPEC-LAG measure rather
than a verdict measure (64 rows partitioned 42 Allowed / 22 NO-ORACLE, of which
the 17 whose derivation NEEDED the 8.6 semantics keep their Phase-A name-set sha
7214d368f5078129 and shape histogram even though every one of them is now
NO-ORACLE); the 40 rows on which the row-aware 8.6 promotion actually fires; the
bare-CMCM-on-Allowed disclosure count (O1); the 32 comma-carrying Source
strings; freshness of the table (no unused entry); the strike list armed at 12;
the bare-CMCM classification rule in BOTH directions; and the cheap confirmation
invariant that tests/gpu-only/expected-nvidia.csv -- machine-checked 137/137 by
the Lustig'19-native nvidia-ptx.cat -- stays CMCM-free.

Specification: the NVOR campaign plan (Phases A and D); env-research/
NVOR-phaseC-brief.md; env-research/NVOR-register.md (open item O5).  Siblings:
amdprovcheck.py (same fault, AMD lane) and nvanchorcheck.py (the Bagchi anchor
doctrine, which this file cannot host).

`--bite' corrupts the CSV, the tables and every pin and requires each injection
to redden the rule it names, for the right reason, on corruption and on
omission both, plus OVERFIRE guards that must leave the gate green and a
vacuity guard on each of them.  The injection COUNT is printed by the run
itself, never by this comment (the amdorder lesson: a comment said 33, the
measured value was 35).
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
BAGCHI, ARM, PTXL19, PTXISA, PTX86, REGN, NONCMCM = (
    "BAGCHI", "ARM", "PTX-L19", "PTX-ISA-9.3", "PTX-ISA-8.6",
    "REGISTRATION", "NONCMCM")
KEY, INSTRUMENT, NOTE, REPOINT, REG = (
    "KEY", "INSTRUMENT", "NOTE", "REPOINT", "REGISTRATION")

# A class is ADMISSIBLE if a claim of that provenance may stand behind a GH200
# verdict at all; a fragment is KEY-grade only if it is ALSO dispositioned KEY.
# PTX5 is deliberately in neither set: admissible in substance, REPOINT by
# disposition, so it can never silently carry a row.  REGISTRATION is in
# neither set either, and for a stronger reason -- see PIN registration-not-a-key.
ADMISSIBLE = {GEN, BAGCHI, ARM, PTXL19, PTXISA, PTX86}
INADMISSIBLE = {X86C}

# --------------------------------------------------------------------------
# The fragment table: exact Source-string fragment -> (class, tag, disposition).
# Exact match is the point -- any edit to a citation is an unknown fragment
# (E1) until a human reclassifies it here.  Measured inventory, not invented:
# 58 distinct citation fragments across the 411 rows (plus the two event
# strings `release.sys'/`acquire.sys', whitelisted below).
# --------------------------------------------------------------------------
FRAGMENTS = {
    # -- CMCM at paper granularity: the D26 disease itself.  Register O1.
    "CMCM": (CMCMBARE, "CMCM-bare", NOTE),
    # -- CMCM sect 3-4: the architecture-agnostic framework.  Admissible.
    "CMCM 3.2.3+4.4+4.6": (GEN, "CMCM-3.2.3/4.4/4.6", KEY),
    "CMCM 4.2 non-MCA p153:11": (GEN, "CMCM-4.2-nonMCA", KEY),
    "CMCM 4.3 fence orderings": (GEN, "CMCM-4.3", KEY),
    "CMCM 4.6 p153:13-14 -- admissible sect 3-4 framework naming the open slot":
        (GEN, "CMCM-4.6-slot", KEY),
    # footnote 7 says the meet CAN BE ASYMMETRICAL.  It is the ground of a
    # DECLINE (NVOR-Q2), i.e. support for withholding a verdict -- never a key
    # for asserting one.
    "CMCM fn7 p153:13 the meet can be asymmetrical": (GEN, "CMCM-fn7", NOTE),
    # -- CMCM sect 5-6, pure PTX: admissible GPU-side, but re-point.  The 18
    #    rows that still carry it are NVOR-Q4b's, where it rides beside the
    #    native Lustig'19 key that actually carries the negative ord claim.
    "CMCM 5 PTX sem>=rel/acq": (PTX5, "CMCM-5-ord", REPOINT),
    # -- Bagchi ISMM'26, GH200-native.  OBSERVED => KEY; GAP / QUALIFIER /
    #    disclosure / future-work => NOTE (a non-observation never proves
    #    Disallowed).  Row-level anchoring is nvanchorcheck.py's job.
    "Bagchi 2.1 MCA-future-work p68": (BAGCHI, "Bagchi-2.1-mca", NOTE),
    "Bagchi 3.2+4.2": (BAGCHI, "Bagchi-3.2/4.2", KEY),
    "Bagchi 4.1 Tab3 r1 rlx/rlx weak OBSERVED 225M runs":
        (BAGCHI, "Bagchi-Tab3-r1-OBS", KEY),
    "Bagchi 4.2 Tab4 GAP -- no correctly sys-annotated GPU producer row exists":
        (BAGCHI, "Bagchi-Tab4-GAP-prod", NOTE),
    "Bagchi 4.2 Tab4 r3 cta/cta weak OBSERVED":
        (BAGCHI, "Bagchi-Tab4-r3-OBS", KEY),
    "Bagchi 4.2 Tab4 r5+r6+r14 relaxed weak OBSERVED":
        (BAGCHI, "Bagchi-Tab4-r5r6r14-OBS", KEY),
    "Bagchi 4.2 disclosure MP-shaped cg-direction only":
        (BAGCHI, "Bagchi-4.2-disclosure", NOTE),
    "Bagchi 5 CPU-GPU coherence": (BAGCHI, "Bagchi-5-coh", KEY),
    "Bagchi 5.4 QUALIFIER -- the paper's invalidations do not appear to directly propagate to the GPU L1 caches which is measured at cta scope and this row carries none":
        (BAGCHI, "Bagchi-5.4-qualifier", NOTE),
    "Bagchi Fig4b gpu-scope RC weak OBSERVED cg":
        (BAGCHI, "Bagchi-Fig4b-OBS", KEY),
    "Bagchi Fig4c cta-scope RC weak OBSERVED":
        (BAGCHI, "Bagchi-Fig4c-OBS", KEY),
    "Bagchi Fig4e/r21-22": (BAGCHI, "Bagchi-Fig4e-OBS", KEY),
    "Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row exists in the paper":
        (BAGCHI, "Bagchi-Tab4-GAP-cons", NOTE),
    # -- CPU-native.  herd7 here runs Arm's own validated aarch64.cat, which is
    #    key-grade for AArch64 per-device facts -- unlike the project-authored
    #    nvidia-ptx.cat transcription below.  Armed Cats is cited as lineage.
    "ARM Armed Cats TOPLAS'21 Fig12/Fig41 model-family lineage":
        (ARM, "ARM-armedcats", NOTE),
    "ARM RCpc": (ARM, "ARM-RCpc", KEY),
    "ARM bob in herd/libdir/aarch64hwreqs.cat:128 included from aarch64.cat:49":
        (ARM, "ARM-bob", KEY),
    "ARMv9 RC": (ARM, "ARMv9-RC", KEY),
    "machine-checked herd7 AArch64 via verify/ordercheck.py":
        (ARM, "herd7-aarch64", KEY),
    "machine-checked herd7 AArch64 (Arm Ltd aarch64.cat) via verify/ordercheck.py Phase 1 -- PER-DEVICE ordering only":
        (ARM, "herd7-aarch64-perdev", KEY),
    # -- GPU-native (Lustig'19).  Row-aware promotion to PTX-ISA-8.6 below.
    "PTX 3.3": (PTXL19, "PTX-3.3", KEY),
    "PTX non-MCA": (PTXL19, "PTX-nonMCA", KEY),
    "PTX sc-fence": (PTXL19, "PTX-scfence", KEY),
    "PTX-relaxed": (PTXL19, "PTX-relaxed", KEY),
    "PTX Lustig'19 3.4 non-MCA": (PTXL19, "L19-3.4-nonMCA", KEY),
    "PTX Lustig'19 3.4.1 modelled fence set is sc and acq_rel so fence.sc is both FREL and FACQ":
        (PTXL19, "L19-3.4.1-fenceset", KEY),
    "PTX Lustig'19 3.4.3 Fence-SC prevents what acquire/release alone cannot such as the SB pattern of Figure 6":
        (PTXL19, "L19-3.4.3", KEY),
    "PTX Lustig'19 Fig4 FREL/FACQ predicates": (PTXL19, "L19-Fig4-FREL", KEY),
    "PTX Lustig'19 Fig4 patternrel/patternacq":
        (PTXL19, "L19-Fig4-pattern", KEY),
    "PTX Lustig'19 Fig6 SB fence.sc": (PTXL19, "L19-Fig6", KEY),
    "PTX Lustig'19 Fig7 Ax1 Coherence": (PTXL19, "L19-Fig7-Ax1", KEY),
    "PTX Lustig'19 Fig7 Ax6 Causality": (PTXL19, "L19-Fig7-Ax6", KEY),
    # -- GPU-native, vendor-normative spec prose.  Version-qualified (R2 M5).
    "PTX ISA 9.3 8.5 Tab21 sys-includes-host": (PTXISA, "PTXISA-8.5-Tab21", KEY),
    "PTX ISA 9.3 8.7 morally-strong": (PTXISA, "PTXISA-8.7", KEY),
    "PTX ISA 9.3 8.8 release/acquire patterns":
        (PTXISA, "PTXISA-8.8-patterns", KEY),
    # the disclosure that the >=8.8 rewrite dropped fence.sc from both clauses
    # is a statement ABOUT a source's silence -- NOTE, and NVOR-Q5 keys those
    # rows to Lustig'19 instead.
    "PTX ISA 9.3 8.8 DISCLOSURE -- the >=8.8 clause text names neither fence.sc nor membar and the lattice reading is ours not the spec's":
        (PTXISA, "PTXISA-8.8-disclosure", NOTE),
    "PTX ISA 9.3 8.9.3 Fence-SC order": (PTXISA, "PTXISA-8.9.3", KEY),
    "PTX ISA 9.3 8.9.4 pattern synchronization": (PTXISA, "PTXISA-8.9.4", KEY),
    "PTX ISA 9.3 8.9.6 coherence-order": (PTXISA, "PTXISA-8.9.6", KEY),
    "PTX ISA 9.3 8.9.7 -- a second rf edge needs no moral strength":
        (PTXISA, "PTXISA-8.9.7", KEY),
    "PTX ISA 9.3 8.10.6 worked MP -- in the absence of any other writes R2 must read from W1":
        (PTXISA, "PTXISA-8.10.6-MP", KEY),
    "PTX ISA 9.3 8.10.6 corroboration -- stated about replacing a standalone fence.sc by fence.acq_rel not about annotated ops":
        (PTXISA, "PTXISA-8.10.6-corr", NOTE),
    "PTX ISA 9.3 8.11.1 normative forbidden outcome":
        (PTXISA, "PTXISA-8.11.1", KEY),
    # -- project-authored instruments: consistency evidence, never truth.
    "machine-checked nvidia-ptx.cat via verify/ordercheck.py":
        (NONCMCM, "nvidia-ptx.cat", INSTRUMENT),
    # -- cross-vendor analogies: NOTE, never a key.  The five Disallowed-row
    #    analogies were DROPPED by the regeneration (all five were
    #    counter-directional, R2 M4); the six survivors state their referent.
    "cf AMD gpu-only AMD-GCN3 SB-sys is Disallowed while NVIDIA-PTX Allows it -- NOTE never a key":
        (NONCMCM, "cf-AMD", NOTE),
    # -- registrations.  NEVER a key: see PIN registration-not-a-key.
    "NVOR-register.md": (REGN, "reg-file", REG),
    "decision NVOR-Q1 cg-coupling REGISTERED": (REGN, "reg-Q1", REG),
    "decision NVOR-Q2 gc-meet DECLINED": (REGN, "reg-Q2", REG),
    "decision NVOR-Q3 sc-identification DECLINED": (REGN, "reg-Q3", REG),
    "decision NVOR-Q4 unidirectional-fence DECLINED": (REGN, "reg-Q4", REG),
    "decision NVOR-Q4b lenient": (REGN, "reg-Q4b", REG),
    "decision NVOR-Q5 sc-pattern-lattice REGISTERED": (REGN, "reg-Q5", REG),
}

# Struck FOR CAUSE by the NVOR regeneration, kept so a reappearance is
# RECOGNISED (E4, and E2 for the three X86C ones) rather than merely unknown.
# Expected use in the shipping CSV: zero, bracketed or inline.
#
# Distinguish these from the SEVEN fragments the regeneration SUPERSEDED --
# `ARMv9', `ARMv9 LDAPR', `Bagchi 5 coherence', `PTX 3.3 RC',
# `PTX 3.3+Fig4+Fig6', `PTX Fig4/Fig7', `machine-checked verify/ordercheck.py'.
# Those were replaced by more precise strings, not disqualified, so they are
# simply GONE from both tables: a reappearance is E1 (reclassify), not E4
# (rot).  Striking them would misreport a citation upgrade as a fault.
FRAGMENTS_STRUCK = {
    # the x86TSO half -- inadmissible on an ARMv9+PTX machine (register NVOR-Q6)
    "CMCM Fig2a": (X86C, "CMCM-Fig2a", KEY),
    "CMCM Fig3": (X86C, "CMCM-Fig3", KEY),
    "CMCM 5.1+Fig11+6.2": (X86C, "CMCM-5.1/Fig11/6.2", KEY),
    # Bagchi mis-anchors and non-observations cited as if they were keys
    "Bagchi Fig2a": (BAGCHI, "Bagchi-Fig2a", KEY),
    "Bagchi r3-5": (BAGCHI, "Bagchi-r3-5", KEY),
    "Bagchi Tab4": (BAGCHI, "Bagchi-Tab4", KEY),
    "Bagchi 4.1 Tab3 DMB": (BAGCHI, "Bagchi-Tab3-DMB", KEY),
    "Bagchi 4.1 Tab3 both-sided fence + 4.2 Tab4":
        (BAGCHI, "Bagchi-Tab3/Tab4", KEY),
    "Bagchi 4.2 Tab4 'no correctly synchronized system-scope test exhibited weak'":
        (BAGCHI, "Bagchi-Tab4-nonobs", NOTE),
    "Bagchi 4.2 future-work": (BAGCHI, "Bagchi-futurework", NOTE),
    # counter-directional cross-vendor analogies (R2 M4)
    "cf AMD LB-sys": (NONCMCM, "cf-AMD-LB", NOTE),
    "cf AMD SB-sys": (NONCMCM, "cf-AMD-SB", NOTE),
}

# A bracket block is a CITATION block iff its first token opens with one of
# these.  EVENT_WHITELIST is B1's repair: the ONLY non-citation brackets the
# corpus emits are the GPU primitive's event notation `w[release.sys]' /
# `r[acquire.sys]', and they are matched EXACTLY.  The regex this replaces
# (`[a-z]+\.[a-z]+' fullmatched, then `continue') swallowed `[cmcm.paper]',
# `[gxhb.cmm]' and `[cmcm.figtwoa]' in total silence (R2 B1).
CITATION_OPENERS = ("CMCM", "Bagchi", "ARM", "PTX", "cf AMD",
                    "machine-checked", "decision")
EVENT_WHITELIST = frozenset(("release.sys", "acquire.sys"))

# A CMCM fragment is section-, figure- or footnote-precise iff it names a
# number right after the tag.  Anything else claiming to be CMCM is
# paper-granularity and MUST be filed CMCM-BARE -- enforced in both directions
# so neither a bare cite can hide under a benign class nor a precise one be
# filed away as bare.
CMCM_PRECISE = re.compile(r"^CMCM (\d|Fig\d|fn\d)")

# `fence.{acquire,release}' is PTX ISA 8.6 / SM_90 and postdates Lustig'19.
# The corpus spells those cells `.rel-2s' / `.acq-2s' in the test name, so the
# namespace is a NAME property -- a spec-lag measure, independent of verdict.
SPEC86_ROW = re.compile(r"\.(rel|acq)-2s")

# The inline scan (B2/B3) looks for known citation strings outside every
# bracket.  Two deliberate exclusions, both stated so they cannot drift into
# habit: REGISTRATION strings, because prose names them on purpose
# ("DISCLOSED (decision NVOR-Q4b lenient): ...") and a registration can never
# be a key; and FRAGMENTS entries shorter than this, because `CMCM',
# `PTX 3.3', `ARM RCpc', `ARMv9 RC', `PTX non-MCA' and `PTX-relaxed' are
# ordinary tokens of the surrounding explanation and scanning for them would
# fire on nearly every row.  STRUCK strings are scanned at ANY length -- they
# are the ones an edit must never re-introduce.
INLINE_MIN = 12


def inline_scan_set(table, struck):
    """The strings the outside-bracket scan looks for.  Pinned by size."""
    out = dict(struck)
    for f, v in table.items():
        if v[0] != REGN and len(f) >= INLINE_MIN and f not in out:
            out[f] = v
    return out


# ---- pins: the shape of the committed CSV (post-NVOR-D1) ------------------
EXPECT_ROWS = 411
EXPECT_CENSUS = {"Allowed": 319, "Disallowed": 18, "NO-ORACLE": 74}
EXPECT_COMMA_ROWS = 32              # Source strings split across CSV fields 4+

# THE CLEAN INVARIANT.  Phase A pinned the fault; this pins its ABSENCE.
EXPECT_FAULTS = {"E2": 0, "E3": 0, "E4": 0, "E5": 0,
                 "E6": 0, "E7": 0, "E8": 0}
EXPECT_STRUCK = 12                  # armed; Phase A pinned this list EMPTY

# The NVOR demotion set (build-nvidia-oracle.sh EXPECT_DEMOTED/_SHA, and
# ordercheck.py EXPECT_NVOR_DEMOTED -- three implementations, one number).
DEMOTED_MARK = "cycle cut UNKEYED"
REG_ID = "decision NVOR-"
EXPECT_DEMOTED = 32
EXPECT_DEMOTED_SHA = "71ebe7baba4fbb83"     # sha256[:16], builder convention
EXPECT_DEMOTED_IDS = {"NVOR-Q2": 19, "NVOR-Q3": 3, "NVOR-Q4": 17}

# The unidirectional-fence (PTX ISA 8.6 / SM_90) exposure, made arithmetic.
# EXPECT_86_ROWS and its sha are Phase A's, UNCHANGED: the same 17 row names,
# now every one of them NO-ORACLE rather than Disallowed.  Pinning the NAME set
# keeps this a spec-lag measure -- a verdict-keyed pin would have evaporated
# the moment NVOR-Q4 was declined, which is exactly when it matters most.
EXPECT_86_SWEEP = 64
EXPECT_86_SWEEP_CENSUS = {"Allowed": 42, "NO-ORACLE": 22}
EXPECT_86_TERRITORY = {"Allowed": 18, "NO-ORACLE": 22}   # promotion fires here
EXPECT_86_ROWS = 17                 # ... and of those, the ones Q4 declined
EXPECT_86_SHA = "7214d368f5078129"  # sha256[:16] of the sorted 17 names
EXPECT_86_HIST = {"LB-cg": 5, "MP-cg": 3, "MP-gc": 3, "S-cg": 3, "S-gc": 3}
NVOR_Q4 = "decision NVOR-Q4 unidirectional-fence DECLINED"

# Register open item O1: bare `[CMCM]' survives on this many ALLOWED rows.  Not
# a fault the gate can close (the fix is a class-level sweep), so it is pinned
# as a DISCLOSURE COUNT -- the debt is visible and cannot drift in either
# direction without a deliberate re-measure.
EXPECT_BARE_CMCM_ALLOWED = 252

# The gpu-only corpus is a CONFIRMATION invariant only: Lustig'19-native,
# machine-checked 137/137, never regenerated.  The row-count pin is what makes
# "zero CMCM citations" mean something -- an emptied file greps clean too.
EXPECT_GPU_ONLY_ROWS = 137


class Fail(Exception):
    pass


def read_rows(path=CSV, text=None):
    """Rows as (name, verdict, model, source).

    32 Source strings carry a comma (advisory prose, byte-stable on purpose),
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


def count_comma_rows(path=CSV, text=None):
    raw = text if text is not None else Path(path).read_text()
    lines = [l for l in raw.splitlines() if l and not l.startswith("#")]
    return sum(1 for r in list(csv.reader(lines))[1:] if len(r) > 4)


def fragments_of(name, source):
    """Bracketed citation fragments of one Source string, or Fail on E1."""
    frags = []
    for block in re.findall(r"\[([^\]]*)\]", source):
        if block.startswith(CITATION_OPENERS):
            frags.extend(f.strip() for f in block.split(";"))
        elif block in EVENT_WHITELIST:
            continue                    # the GPU primitive's event notation
        else:
            raise Fail("E1 structure: unclassifiable bracket block [%s] "
                       "on row %s -- a citation block must open with one of "
                       "%r and the only non-citation brackets are %r"
                       % (block, name, CITATION_OPENERS,
                          sorted(EVENT_WHITELIST)))
    return frags


def inline_of(source, scan):
    """Known citation strings sitting OUTSIDE every bracket (R2 B2/B3).

    Longest-first with the match consumed, so a fragment that is a prefix of a
    longer one (`Bagchi Tab4' inside `Bagchi Tab4 GAP -- ...') is not counted
    twice for one occurrence.
    """
    outside = re.sub(r"\[[^\]]*\]", " ", source)
    hits = []
    for f in sorted(scan, key=len, reverse=True):
        if f in outside:
            hits.append(f)
            outside = outside.replace(f, " ")
    return hits


def audit(rows, table=None, struck=None):
    """Classify every fragment of every row, bracketed and inline.

    Returns (findings, used, census, rows86, probes, byclass, demoted).  E1
    raises at once (fail-closed); E2..E8 are collected and pinned at zero.
    `byclass' counts EFFECTIVE classes -- i.e. after the row-aware
    PTX-L19/PTX-ISA-9.3 -> PTX-ISA-8.6 promotion -- so the report cannot claim
    the version-drift class is empty while its uses sit inside PTX-L19.
    """
    table = FRAGMENTS if table is None else table
    struck = FRAGMENTS_STRUCK if struck is None else struck
    scan = inline_scan_set(table, struck)
    findings = {k: [] for k in EXPECT_FAULTS}
    used, census, rows86, demoted = {}, {}, [], []
    byclass = {}
    probes = 0
    for name, verdict, _model, source in rows:
        census[verdict] = census.get(verdict, 0) + 1
        eff = []
        for f in fragments_of(name, source):
            probes += 1                 # the E4 strike lookup runs on every one
            if f in struck:
                cls, tag, disp = struck[f]
                findings["E4"].append("%s cites struck %s" % (name, tag))
            elif f in table:
                cls, tag, disp = table[f]
                used[f] = used.get(f, 0) + 1
            else:
                raise Fail("E1 unknown fragment (reclassify in FRAGMENTS): "
                           "row %s: %r" % (name, f))
            # ROW-AWARE split: a PTX citation standing on a
            # unidirectional-fence row is de facto PTX ISA 8.6 territory.
            if cls in (PTXL19, PTXISA) and SPEC86_ROW.search(name):
                cls = PTX86
            nfr, nus = byclass.get(cls, (set(), 0))
            byclass[cls] = (nfr | {f}, nus + 1)
            eff.append((cls, disp))
        for f in inline_of(source, scan):
            probes += 1
            cls, tag, _disp = scan[f]
            if f in struck:
                findings["E4"].append("%s cites struck %s OUTSIDE a bracket"
                                      % (name, tag))
            if cls in INADMISSIBLE:
                findings["E2"].append("%s inline %s" % (name, tag))
            elif f not in struck:
                findings["E7"].append("%s inline %s" % (name, tag))

        haskey = any(c in ADMISSIBLE and d == KEY for c, d in eff)
        if any(c in INADMISSIBLE for c, _d in eff):
            findings["E2"].append(name)             # corpus-wide (R2 B6)
        if DEMOTED_MARK in source:
            demoted.append((name, verdict))
            # the registration ID must be BRACKETED, i.e. gradeable.  A pointer
            # to the register file is not an ID, and prose is not a citation:
            # ordercheck.py accepts the ID anywhere on the line, so requiring
            # it inside a block is what makes the two implementations differ.
            if not any(f.startswith(REG_ID)
                       for f in fragments_of(name, source)):
                findings["E8"].append(name)
        if verdict == "Disallowed":
            if not haskey:
                findings["E3"].append(name)
            if any(c == CMCMBARE for c, _d in eff):
                findings["E5"].append(name)
        elif verdict == "Allowed":
            if not haskey:                          # KEYLESS, not merely
                findings["E6"].append(name)         # instrument-only (R2 B4)
        if any(c == PTX86 for c, _d in eff):
            rows86.append((name, verdict))
    return findings, used, census, rows86, probes, byclass, demoted


def sha16(names):
    return hashlib.sha256("\n".join(names).encode()).hexdigest()[:16]


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


def check(rows, table=None, struck=None, gpu_only_text=None, ncomma=None):
    """Assert every pin; Fail on the first violation.  Returns the audit."""
    tbl = FRAGMENTS if table is None else table
    strk = FRAGMENTS_STRUCK if struck is None else struck
    if len(rows) != EXPECT_ROWS:
        raise Fail("PIN rows: %d != %d" % (len(rows), EXPECT_ROWS))

    # a registration is not a citation: if one could be a KEY, E3 would be
    # satisfiable by naming the decision that needs support, and the rule dies
    bad = sorted(f for f, (cls, _t, disp) in tbl.items()
                 if cls == REGN and disp != REG)
    if bad or REGN in ADMISSIBLE:
        raise Fail("PIN registration-not-a-key: %r dispositioned as support "
                   "(REGISTRATION in ADMISSIBLE: %s) -- a registered decision "
                   "is not evidence for itself"
                   % (bad, REGN in ADMISSIBLE))

    # the bare-CMCM classification rule, both directions
    for f, (cls, _tag, _disp) in sorted(tbl.items()):
        if not f.startswith("CMCM"):
            continue
        precise = bool(CMCM_PRECISE.match(f))
        if precise and cls == CMCMBARE:
            raise Fail("PIN bare-CMCM classification: %r names a section, "
                       "figure or footnote yet is filed CMCM-BARE" % f)
        if not precise and cls != CMCMBARE:
            raise Fail("PIN bare-CMCM classification: %r is paper-granularity "
                       "and must be filed %s -- it is filed %s, which would "
                       "hide the D26 disease from E5" % (f, CMCMBARE, cls))

    # the two table-shape pins that must hold BEFORE anything is classified:
    # a disarmed strike list or a narrowed inline scan makes the audit below
    # report clean for the wrong reason
    if len(strk) != EXPECT_STRUCK:
        raise Fail("PIN strike-list: the NVOR strike list is armed at %d "
                   "fragments; found %d -- a fragment struck FOR CAUSE cannot "
                   "leave the list without a registered decision"
                   % (EXPECT_STRUCK, len(strk)))
    nscan = len(inline_scan_set(tbl, strk))
    if nscan <= len(strk):
        raise Fail("PIN inline-scan: the outside-bracket scan covers only %d "
                   "strings (<= the %d struck ones), so B2/B3 laundering of a "
                   "LIVE citation would be invisible" % (nscan, len(strk)))

    findings, used, census, rows86, probes, byclass, demoted = audit(
        rows, tbl, strk)

    # the E4 lookup and the inline scan must be LIVE, not dead code
    if probes == 0:
        raise Fail("PIN strike-rule dead: not one fragment was classified, so "
                   "neither the E4 strike lookup nor the inline scan ran")

    if census != EXPECT_CENSUS:
        raise Fail("PIN census: %r != %r" % (census, EXPECT_CENSUS))
    ncomma = count_comma_rows() if ncomma is None else ncomma
    if ncomma != EXPECT_COMMA_ROWS:
        raise Fail("PIN comma rows: %d Source strings split across CSV fields "
                   "4+, pinned %d -- the fragment parser rejoins them and the "
                   "count is how we know it still has to"
                   % (ncomma, EXPECT_COMMA_ROWS))
    stale = set(tbl) - set(used)
    if stale:
        raise Fail("PIN stale table entries (unused, re-measure): %r"
                   % sorted(stale))

    # the NVOR demotion set: count, verdict, per-registration histogram, sha
    dnames = sorted(n for n, _v in demoted)
    dsha = sha16(dnames + [""])         # the builder hashes a trailing newline
    src = {n: s for n, _v, _m, s in rows}
    ids = {k: sum(1 for n, _v in demoted if k in src[n])
           for k in EXPECT_DEMOTED_IDS}
    if len(dnames) != EXPECT_DEMOTED or dsha != EXPECT_DEMOTED_SHA:
        raise Fail("PIN demotion-set drift: %d rows sha %s != pinned %d sha %s "
                   "-- a row left or joined the NVOR demotion set without this "
                   "pin being re-measured (a count alone survives demoting a "
                   "DIFFERENT %d rows)"
                   % (len(dnames), dsha, EXPECT_DEMOTED, EXPECT_DEMOTED_SHA,
                      EXPECT_DEMOTED))
    if ids != EXPECT_DEMOTED_IDS:
        raise Fail("PIN demotion-set registrations: %r != pinned %r -- rows "
                   "moved between declined registrations" % (ids,
                                                             EXPECT_DEMOTED_IDS))
    notno = [n for n, v in demoted if v != "NO-ORACLE"]
    if notno:
        raise Fail("PIN demotion-set verdict: demoted row(s) not NO-ORACLE: %r "
                   "-- a row cannot name an UNKEYED cycle cut and carry a "
                   "verdict" % notno)

    # the unidirectional-fence exposure: namespace, promotion, Q4 subset
    sweep = {}
    for name, verdict, _m, _s in rows:
        if SPEC86_ROW.search(name):
            sweep[verdict] = sweep.get(verdict, 0) + 1
    if sum(sweep.values()) != EXPECT_86_SWEEP or sweep != EXPECT_86_SWEEP_CENSUS:
        raise Fail("PIN 8.6-namespace: %d `.rel-2s'/`.acq-2s' rows %r != "
                   "pinned %d %r -- the PTX ISA 8.6 / SM_90 exposure is a NAME "
                   "property and it moved"
                   % (sum(sweep.values()), sweep, EXPECT_86_SWEEP,
                      EXPECT_86_SWEEP_CENSUS))
    terr = {}
    for _n, v in rows86:
        terr[v] = terr.get(v, 0) + 1
    if terr != EXPECT_86_TERRITORY:
        raise Fail("PIN 8.6-territory: the row-aware promotion fires on %r "
                   "rows != pinned %r -- either a GPU-side citation left the "
                   "unidirectional-fence namespace or the promotion stopped "
                   "firing" % (terr, EXPECT_86_TERRITORY))
    q4 = sorted(n for n, _v, _m, s in rows if NVOR_Q4 in s)
    hist = {}
    for n in q4:
        k = "-".join(n.split("-")[:2])
        hist[k] = hist.get(k, 0) + 1
    if (len(q4) != EXPECT_86_ROWS or sha16(q4) != EXPECT_86_SHA
            or hist != EXPECT_86_HIST):
        raise Fail("PIN 8.6-split: %d rows whose derivation NEEDED the PTX ISA "
                   "8.6 semantics (sha %s hist %r) != pinned %d (sha %s hist "
                   "%r) -- the Lustig'19 version-drift exposure changed"
                   % (len(q4), sha16(q4), hist,
                      EXPECT_86_ROWS, EXPECT_86_SHA, EXPECT_86_HIST))

    # register O1: the bare-CMCM debt on Allowed rows, pinned as a disclosure
    bare = [n for n, v, _m, s in rows
            if v == "Allowed" and "CMCM" in fragments_of(n, s)]
    if len(bare) != EXPECT_BARE_CMCM_ALLOWED:
        raise Fail("PIN bare-CMCM disclosure: %d Allowed rows cite bare "
                   "paper-granularity [CMCM], pinned %d (register open item "
                   "O1) -- the debt moved without being re-measured"
                   % (len(bare), EXPECT_BARE_CMCM_ALLOWED))

    # THE CLEAN INVARIANT: every rule at zero, drift in either direction red
    counts = {k: len(v) for k, v in findings.items()}
    drift = [k for k in sorted(EXPECT_FAULTS) if counts[k] != EXPECT_FAULTS[k]]
    if drift:
        sample = {k: sorted(findings[k])[:3] for k in drift}
        raise Fail("PIN fault-set drift %s: measured %r != pinned %r; %r -- "
                   "the NVOR regeneration left this corpus provenance-clean "
                   "and this pin documents the ABSENCE of the fault, so any "
                   "movement is a regression or an unrecorded re-key"
                   % ("".join("[%s]" % d for d in drift), counts,
                      EXPECT_FAULTS, sample))

    ngpu = check_gpu_only(gpu_only_text)
    return findings, used, census, rows86, byclass, hist, ngpu, demoted


def report(rows):
    (findings, _used, census, rows86, byclass, hist, ngpu,
     demoted) = check(rows)
    print("nvprovcheck: %d rows %r" % (len(rows), census))
    print("fragment inventory: %d citation fragments + %d struck; effective "
          "classes (after the row-aware 8.6 promotion):"
          % (len(FRAGMENTS), len(FRAGMENTS_STRUCK)))
    for c in sorted(byclass):
        frags, uses = byclass[c]
        print("  %-14s %2d fragments %4d uses" % (c, len(frags), uses))
    # every number below is MEASURED by this run, never a pinned constant read
    # back at the reader (the amdorder lesson, applied to the report too)
    terr = {}
    for _n, v in rows86:
        terr[v] = terr.get(v, 0) + 1
    print("PTX ISA 8.6 / SM_90 exposure: %d rows in the unidirectional-fence "
          "namespace, %d of them carrying a GPU-side citation %r; %d needed "
          "the 8.6 semantics as a positive key %r -- all NO-ORACLE since "
          "NVOR-Q4 was declined"
          % (sum(1 for n, _v, _m, _s in rows if SPEC86_ROW.search(n)),
             len(rows86), dict(sorted(terr.items())), sum(hist.values()),
             dict(sorted(hist.items()))))
    print("NVOR demotion set: %d rows, all NO-ORACLE, each naming its own "
          "registration ID (sha %s)"
          % (len(demoted), sha16(sorted(n for n, _v in demoted) + [""])))
    print("disclosure (register O1): %d Allowed rows still cite bare [CMCM]"
          % EXPECT_BARE_CMCM_ALLOWED)
    print("clean invariant: %r"
          % {k: len(v) for k, v in sorted(findings.items())})
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
        print("  bite %-28s FAILS   (%s)" % (what, marker))
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
    print("  bite %-28s green   (overfire guard: %s)" % (what, why))


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
    ORD_D = "CMCM 3.2.3+4.4+4.6"           # every surviving Disallowed row
    GPUCAT = "machine-checked nvidia-ptx.cat via verify/ordercheck.py"
    ARMKEY = "machine-checked herd7 AArch64 via verify/ordercheck.py"

    # ---- E1: the parser sees everything it is handed --------------------
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

    # 3 B1: a lowercase-dotted block is what the Phase-A regex SWALLOWED in
    #   silence -- `[cmcm.paper]' parsed to zero fragments and no error, which
    #   defeated E1, E2, E5 and E4 at once.  The exact whitelist must reject it.
    for probe in ("cmcm.paper", "gxhb.cmm", "fake.frag"):
        bad = _clone(rows)
        i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
        bad[i][3] += " derived from [%s]" % probe
        _expect_fail("b1-event-whitelist[%s]" % probe, "E1 structure",
                     lambda: check(bad))
        n += 1

    # 4 B1 overfire guard: the two REAL event strings must still pass
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "release.sys" not in r[3])
    bad[i][3] += " (GPU primitive w[release.sys]/r[acquire.sys])"
    _expect_pass("b1-event-overfire",
                 "release.sys/acquire.sys are the corpus's real event notation",
                 rows, bad, lambda: check(bad))
    n += 1

    # 5 a hole in the active table is E1 for every row that cites the entry
    holed = dict(FRAGMENTS)
    del holed["PTX sc-fence"]
    _expect_fail("table-hole", "E1 unknown fragment",
                 lambda: check(_clone(rows), table=holed))
    n += 1

    # ---- E2: no inadmissible (x86TSO-half) fragment ANYWHERE (B6) --------
    # 6 E2 on a Disallowed row -- the dangerous direction
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM Fig3")
    _expect_fail("e2-x86c-into-disallowed", "[E2]", lambda: check(bad))
    n += 1

    # 7 B6: ... and on an ALLOWED row, which Phase A tolerated by design.  The
    #   regeneration struck all three X86C strings corpus-wide, so under the
    #   Q0 ladder (an Allowed row is an affirmative claim) this is now a fault.
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "ARMv9 RC" in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM Fig2a")
    _expect_fail("b6-e2-x86c-on-allowed", "[E2]", lambda: check(bad))
    n += 1

    # 8 B6: ... and on a NO-ORACLE row, which no Phase-A rule looked at at all
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "NO-ORACLE")
    bad[i][3] = _append_frag(bad[i][3], "CMCM 5.1+Fig11+6.2")
    _expect_fail("b6-e2-x86c-on-nooracle", "[E2]", lambda: check(bad))
    n += 1

    # ---- E3 / E6: a verdict with no admissible key ----------------------
    # 9 E3: a Disallowed row stripped down to an instrument-only citation
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[%s]" % GPUCAT, bad[i][3])
    _expect_fail("e3-keyless-disallowed", "[E3]", lambda: check(bad))
    n += 1

    # 10 E6 as Phase A had it: an Allowed row's keys replaced by an instrument
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$", "[%s]" % GPUCAT, bad[i][3])
    _expect_fail("e6-instrument-only", "[E6]", lambda: check(bad))
    n += 1

    # 11 B4: ... and the case Phase A's rule MISSED -- strip the instrument too
    #    and the row is still a keyless Allowed, the exact Q0 condition, which
    #    the old `not haskey and any(INSTRUMENT)' reported as 0.
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = re.sub(
        r"\[[^\]]*\]$",
        "[Bagchi 4.2 disclosure MP-shaped cg-direction only; "
        "decision NVOR-Q4b lenient]", bad[i][3])
    _expect_fail("b4-keyless-allowed-no-instrument", "[E6]", lambda: check(bad))
    n += 1

    # 12 B4 corollary: a REGISTRATION alone is not a key either.  If it were,
    #    E3 would be satisfiable by naming the decision that needs support.
    keyed = dict(FRAGMENTS)
    keyed["decision NVOR-Q1 cg-coupling REGISTERED"] = (REGN, "reg-Q1", KEY)
    _expect_fail("registration-as-key", "PIN registration-not-a-key",
                 lambda: check(_clone(rows), table=keyed))
    n += 1

    # 13 E6 OVERFIRE GUARD: citing an instrument is not itself the fault --
    #    the Allowed rows that also carry admissible keys stay green
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = _append_frag(bad[i][3], GPUCAT)
    _expect_pass("e6-overfire-instrument",
                 "an Allowed row that also has admissible keys is not E6",
                 rows, bad, lambda: check(bad))
    n += 1

    # ---- E4: struck fragments, bracketed and inline (B2/B3) --------------
    # 14 bracketed reappearance of a fragment struck FOR CAUSE
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "Bagchi" in r[3])
    bad[i][3] = _append_frag(bad[i][3], "Bagchi 4.1 Tab3 DMB")
    _expect_fail("e4-strike-bracketed", "[E4]", lambda: check(bad))
    n += 1

    # 15 B2: the same strike laundered into inline prose -- the scenario that
    #    passed GATE GREEN against a zeroed Phase-A pin
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = bad[i][3].replace(
        "two-sided", "as in CMCM Fig2a, two-sided", 1)
    _expect_fail("b2-inline-strike", "[E4]", lambda: check(bad))
    n += 1

    # 16 B2 again, on the E2 axis: an inline X86C strike is inadmissible
    #    provenance no matter which side of the bracket it sits on
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "ARMv9 RC" in r[3])
    bad[i][3] += " (cf CMCM Fig3)"
    _expect_fail("b2-inline-x86c", "[E2]", lambda: check(bad))
    n += 1

    # 17 B3: a citation appended AFTER the last `]' -- invisible to Phase A
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] += " and also PTX ISA 9.3 8.9.3 Fence-SC order"
    _expect_fail("b3-post-bracket", "[E7]", lambda: check(bad))
    n += 1

    # 18 B3 OVERFIRE GUARD: prose that names a REGISTRATION is exactly what the
    #    shipping Q4b rows do ("DISCLOSED (decision NVOR-Q4b lenient): ...")
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "NO-ORACLE"
              and "decision NVOR-Q2 gc-meet DECLINED" in r[3])
    bad[i][3] += " DISCLOSED (decision NVOR-Q2 gc-meet DECLINED)."
    _expect_pass("b3-inline-registration",
                 "prose names registration IDs on purpose and a registration "
                 "is never a key", rows, bad, lambda: check(bad))
    n += 1

    # 19 the strike list must stay armed: a fragment struck FOR CAUSE cannot
    #    quietly leave it (which would silently demote E4 to E1, or to nothing)
    disarmed = {k: v for k, v in list(FRAGMENTS_STRUCK.items())[1:]}
    _expect_fail("e4-strike-list-disarmed", "PIN strike-list",
                 lambda: check(_clone(rows), struck=disarmed))
    n += 1

    # 20 the inline scan must cover LIVE citations, not just struck ones --
    #    otherwise B3 laundering of an admissible-but-ungraded cite is invisible
    _expect_fail("inline-scan-narrowed", "PIN inline-scan",
                 lambda: check(_clone(rows), table={}, struck=FRAGMENTS_STRUCK))
    n += 1

    # ---- E5: bare paper-granularity CMCM --------------------------------
    # 21 E5 up: bare [CMCM] added to a Disallowed row that cites sections
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Disallowed" and ORD_D in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM")
    _expect_fail("e5-bare-cmcm-added", "[E5]", lambda: check(bad))
    n += 1

    # 22 E5 OVERFIRE GUARD: bare [CMCM] on an Allowed row is register item O1,
    #    not E5 -- 252 rows already do it and the sweep is deferred, not denied.
    #    The injection SWAPS which Allowed row carries it, so the O1 count is
    #    held constant and E5 is the only rule that could speak.
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM")
    j = _find(bad, lambda r: r[1] == "Allowed" and "; CMCM]" in r[3])
    bad[j][3] = bad[j][3].replace("; CMCM]", "]", 1)
    _expect_pass("e5-overfire-allowed",
                 "paper-granularity cites on Allowed rows are O1, fail-safe, "
                 "and separately pinned", rows, bad, lambda: check(bad))
    n += 1

    # 23 ... but the O1 DEBT itself is pinned, so the same edit UNPAIRED moves
    #    the disclosure count -- growth and silent repayment both redden
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = _append_frag(bad[i][3], "CMCM")
    _expect_fail("o1-debt-grows", "PIN bare-CMCM disclosure",
                 lambda: check(bad))
    n += 1

    # 24 ... and the other direction: a row quietly re-keyed off bare [CMCM]
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and "; CMCM]" in r[3])
    bad[i][3] = bad[i][3].replace("; CMCM]", "; CMCM 3.2.3+4.4+4.6]", 1)
    _expect_fail("o1-debt-shrinks", "PIN bare-CMCM disclosure",
                 lambda: check(bad))
    n += 1

    # ---- E8: every demoted row names its own registration ---------------
    # 25 B6: a demoted row whose registration ID sits in PROSE instead of in a
    #    citation block.  ordercheck.py's per-row check greps the whole line and
    #    would still pass; here the ID has to be gradeable, so E8 fires while
    #    the per-registration histogram (which reads the raw string) does not
    #    move -- the two implementations disagree on purpose.
    UNIDIR = "[decision NVOR-Q4 unidirectional-fence DECLINED; "
    bad = _clone(rows)
    i = _find(bad, lambda r: UNIDIR in r[3])
    bad[i][3] = bad[i][3].replace(
        UNIDIR, "-- decision NVOR-Q4 unidirectional-fence DECLINED -- [", 1)
    _expect_fail("b6-demoted-unregistered", "[E8]", lambda: check(bad))
    n += 1

    # 26 the demotion SET, by sha: hold the count while the members move
    bad = _clone(rows)
    i = _find(bad, lambda r: "cycle cut UNKEYED" in r[3])
    j = _find(bad, lambda r: r[1] == "NO-ORACLE"
              and "cycle cut UNKEYED" not in r[3])
    bad[i][3] = bad[i][3].replace("cycle cut UNKEYED", "cycle cut unkeyed", 1)
    bad[j][3] = "cycle cut UNKEYED -- " + bad[j][3] + \
        " [decision NVOR-Q2 gc-meet DECLINED]"
    _expect_fail("demoted-sha-swap", "PIN demotion-set drift",
                 lambda: check(bad))
    n += 1

    # 27 ... and by per-registration histogram: a row moving from one declined
    #    registration to another keeps both the count and the membership
    bad = _clone(rows)
    i = _find(bad, lambda r: "decision NVOR-Q3 sc-identification DECLINED"
              in r[3])
    bad[i][3] = bad[i][3].replace(
        "decision NVOR-Q3 sc-identification DECLINED",
        "decision NVOR-Q2 gc-meet DECLINED", 1)
    _expect_fail("demoted-id-histogram", "PIN demotion-set registrations",
                 lambda: check(bad))
    n += 1

    # 28 a demoted row that quietly acquires a verdict
    bad = _clone(rows)
    i = _find(bad, lambda r: "cycle cut UNKEYED" in r[3])
    bad[i][1] = "Disallowed"
    _expect_fail("demoted-verdict", "PIN census", lambda: check(bad))
    n += 1

    # ---- the shape pins -------------------------------------------------
    # 29 the 8.6 namespace: one row renamed out of `.rel-2s'/`.acq-2s'.  The
    #    exposure is a NAME property, so this is how it would silently shrink.
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and SPEC86_ROW.search(r[0]))
    bad[i][0] = bad[i][0].replace(".rel-2s", ".rl-2s").replace(
        ".acq-2s", ".aq-2s")
    _expect_fail("split86-namespace", "PIN 8.6-namespace", lambda: check(bad))
    n += 1

    # 30 ... the Q4-declined subset alone, with the namespace and the demotion
    #    set both untouched: the registration lands on a row that is neither
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and ARMKEY in r[3])
    bad[i][3] = _append_frag(bad[i][3], NVOR_Q4)
    _expect_fail("split86-subset", "PIN 8.6-split", lambda: check(bad))
    n += 1

    # 31 ... and the row-aware promotion itself, which is what makes the class
    #    more than a name filter: strip a namespace row's GPU-side citations
    #    and it leaves the territory while staying in the namespace
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed" and SPEC86_ROW.search(r[0])
              and "PTX Lustig'19 Fig4 FREL/FACQ predicates" in r[3])
    bad[i][3] = re.sub(r"\[[^\]]*\]$",
                       "[Bagchi 4.2 Tab4 r3 cta/cta weak OBSERVED]", bad[i][3])
    _expect_fail("split86-territory", "PIN 8.6-territory", lambda: check(bad))
    n += 1

    # 32 census drift
    bad = _clone(rows)
    i = _find(bad, lambda r: r[1] == "Allowed")
    bad[i][1] = "Disallowed"
    _expect_fail("verdict-flip", "PIN census", lambda: check(bad))
    n += 1

    # 33 row drop
    _expect_fail("row-drop", "PIN rows", lambda: check(_clone(rows)[:-1]))
    n += 1

    # 34 the comma-rejoin count: the parser rejoins CSV fields 4+, and this is
    #    how we know it still has to
    _expect_fail("comma-rows", "PIN comma rows",
                 lambda: check(_clone(rows), ncomma=38))
    n += 1

    # 35 a stale table entry (never cited) reddens the freshness pin
    padded = dict(FRAGMENTS)
    padded["CMCM 3.1 never actually cited"] = (GEN, "pad", KEY)
    _expect_fail("stale-entry", "PIN stale table entries",
                 lambda: check(_clone(rows), table=padded))
    n += 1

    # 36 bare [CMCM] refiled under a benign class -- the way this gate could be
    #    silently defeated without touching a single Source string
    laundered = dict(FRAGMENTS)
    laundered["CMCM"] = (GEN, "CMCM-laundered", KEY)
    _expect_fail("bare-cmcm-laundered", "PIN bare-CMCM classification",
                 lambda: check(_clone(rows), table=laundered))
    n += 1

    # 37 ... and the converse: a precise cite filed away as bare
    misfiled = dict(FRAGMENTS)
    misfiled["CMCM 4.3 fence orderings"] = (CMCMBARE, "x", NOTE)
    _expect_fail("precise-cmcm-misfiled", "PIN bare-CMCM classification",
                 lambda: check(_clone(rows), table=misfiled))
    n += 1

    # 38 VACUITY GUARD: strip every citation and the liveness pin fires before
    #    any downstream pin can mask it -- a gate whose rules never execute
    #    reports the same zeros as a clean corpus
    bad = [[r[0], r[1], r[2], re.sub(r"\[[^\]]*\]", "", r[3])] for r in rows]
    _expect_fail("strike-rule-dead", "PIN strike-rule dead", lambda: check(bad))
    n += 1

    # 39 the gpu-only confirmation corpus grows a CMCM citation
    poisoned = ("Litmus,Expected,Model,Source\n"
                + "\n".join("t%d,Allowed,PTX,ok" % k
                            for k in range(EXPECT_GPU_ONLY_ROWS - 1))
                + "\ntBAD,Allowed,PTX,derived from [CMCM 6.2]\n")
    _expect_fail("gpu-only-cmcm", "PIN gpu-only CMCM",
                 lambda: check(_clone(rows), gpu_only_text=poisoned))
    n += 1

    # 40 ... and an emptied gpu-only corpus, which would grep CMCM-free
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
    print("nvprovcheck: OK (the clean invariant holds -- every rule at zero "
          "over a parser that reads inside AND outside the brackets)")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print("nvprovcheck: FAIL -- %s" % e, file=sys.stderr)
        sys.exit(1)
