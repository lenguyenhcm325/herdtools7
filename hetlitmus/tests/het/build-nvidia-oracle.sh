#!/usr/bin/env bash
# Regenerate the NVIDIA GH200 het oracle  tests/het/expected-nvidia.csv  from the
# het corpus (the .litmus names produced by generate.sh).  Verdicts are derived,
# not measured (running on a GH200 is Task 9), and grounded in three primary
# sources -- docs/het-oracle.md carries the provenance, the per-shape proofs and
# the quotations behind every row below:
#   [CMCM]   Goens et al., Compound Memory Models, PLDI'23.
#   [PTX]    Lustig et al., A Formal Analysis of the NVIDIA PTX MCM, ASPLOS'19,
#            and NVIDIA's own PTX ISA (version-qualified at every citation).
#   [Bagchi] Bagchi et al., Consistency & Coherence of the Grace-Hopper
#            Superchip, ISMM'26 (empirical GH200).
#
# NVOR REGENERATION (Nguyen 2026-08-06; env-research/NVOR-register.md,
# NVOR-phaseC-brief.md).  The NVIDIA lane's provenance audit found that the whole
# Disallowed surface rested on premises that were correct-looking, uncited and
# never registered as decisions.  Seven were put to Nguyen; the adjudication is:
#
#   Q1  cg coupling (ARM producer -> GPU consumer)          ACCEPT  -> registered
#   Q2  gc coupling (symmetric meet: GPU producer)          DECLINE -> 23 rows
#   Q3  ARM DMB SY is a PTX fence.sc for Fence-SC order     DECLINE ->  3 rows
#   Q4  fence.{acquire,release}.sys semantics               DECLINE ->  8 rows
#   Q4b the 18 unidirectional-fence ALLOWED rows            LENIENT -> stay Allowed
#   Q5  fence.sc heads/completes a sect 8.8 pattern         ACCEPT  (Lustig-keyed)
#   Q6  CMCM Fig2a struck as a key                          ACCEPT  (mechanical)
#   Q7  Srivastava Jetson corroboration                     DECLINE (no citation)
#
# (Those three counts partition the demoted set by its PRIMARY slot; 9 of the 23
# gc rows also need Q4, so 17 rows NAME Q4 in their Source.)
#
# Census 319/50/42 -> 319/16/76.  The 34 demoted rows are NO-ORACLE, never
# Allowed: silence is not permission.  OBSERVING ONE OF THEM ON HARDWARE IS DATA,
# NEVER A REFUTATION of the compound model.  Each demoted row's Source names its
# own open slot; the per-row list is  build-nvidia-oracle.sh --declined-list.
#
# NVOR PHASE D3 (2026-08-06).  Phase E's BLIND re-derivation -- an analyst given
# the .litmus sources and a herd7 toolchain and NOTHING else -- confirmed 16 of
# the then-18 Disallowed rows and CHALLENGED two, sustained on re-examination
# (env-research/NVOR-DR-nvidia-oracle.md).  The GC slot was keyed to the test's
# NAME TAG rather than to the DIRECTION of the rf that carries the sw, and on LB
# (two Rfe edges) those differ, so LB-cg-sys-ld.ra-2s and LB-cg-sys-ld.sc-2s
# shipped Disallowed on the DECLINED Q2 meet -- a live false-refutation risk.
# Both slot-gate implementations were wrong the same way, so the count and sha
# pins were stable at the wrong value; only the blind pass could find it.  The
# repair keys the slot on the direction, demotes those 2, re-slots 3 latent LB
# rows so a future Q4 registration cannot silently re-arm them on the same
# declined meet, and drops a (gc) that R-gc-sys-fence-2s never needed.
# Census 319/18/74 -> 319/16/76; demoted 32 -> 34.
#
# Decision table (read alongside classify() below).  A CPU proc is ordered iff
# its column carries STLR/LDAPR/DMB, which only the two-sided `-2s' tests do.
#
#  one-sided (GPU annotated, CPU plain ARMv9):
#    relaxed, any scope             Allowed     no synchronizing op
#    cta or gpu scope, any order    Allowed     scope cannot reach the CPU
#    sys + acquire/release/fence    Allowed     paired CPU proc is plain, so the
#                                               morally-strong pair never closes
#    IRIW-gcgc sys acquire|fence    NO-ORACLE   reader half present, but IRIW
#                                               needs multi-copy atomicity
#
#  two-sided `-2s', matched order (both devices annotated, always sys scope):
#                                   acqrel      fence
#    MP, LB, S                      Disallowed  Disallowed  (cg-DIRECTION sw
#                                               only -- a gc-direction sw is
#                                               NO-ORACLE under Q2, and on LB
#                                               that can happen inside a
#                                               cg-NAMED test: see (2) below)
#    SB, R                          Allowed     NO-ORACLE   (RCpc rel/acq never
#                                               orders store->load; the SC-fence
#                                               route needs Q3, which is declined)
#    RWC                            Allowed     NO-ORACLE
#    2+2W, IRIW                     NO-ORACLE   NO-ORACLE   (multi-copy
#                                               atomicity)
#    WRC, ISA2, WRC3                NO-ORACLE   NO-ORACLE   (cross-device
#                                               A-cumulativity)
#
#  two-sided order-pair `-2s' with order `<cpu>.<gpu>' (2-proc shapes minus
#  2+2W; the two diagonal cells are the matched rows -- `ra.ra' is -acqrel-2s,
#  `sy.sc' is -fence-2s):
#      cpu in {ra = STLR/LDAPR , sy = DMB SY , st = DMB ST , ld = DMB LD}
#      gpu in {ra = w[release]/r[acquire] , sc = fence.sc.sys ,
#              rel = fence.release.sys , acq = fence.acquire.sys}
#  Not tabulated by hand: two_sided_order_pair() below composes two
#  per-primitive facts, ord(p) and role(p), tabulated in PRIM.  Its
#  outcomes are Allowed (a side's own ISA leaves its own program-order pair
#  unordered), Disallowed (both sides order their pair, the [PTX] pattern
#  completes AND every registration the row needs is REGISTERED) and NO-ORACLE
#  (both order their pair but the pattern does not complete -- the cells where
#  CMCM's operational model forbids and its own axiomatic model permits -- or the
#  pattern completes but the row needs a DECLINED registration).
#  hetlitmus/verify/ordercheck.py proves the ordering rule is the function herd7
#  computes: 96 CPU-only cells under the native AArch64 model, 96 GPU-only cells
#  under nvidia-ptx.cat, and all 128 two-sided 2-proc CSV rows including the
#  NVOR slot gate.
#
# The one step no solver decides -- that a CPU DMB and a sys-scope GPU fence are
# morally strong at all, i.e. that the two sides compose across the C2C boundary
# -- is now a REGISTERED DECISION (Q1) in the CPU-producer direction and an OPEN
# SLOT in the GPU-producer direction (Q2), not a silent assumption either way.
#
# An observed weak outcome makes a verdict Allowed and is robust; a
# non-observation NEVER proves Disallowed.  Every Disallowed row is a model
# derivation, not a measurement, and carries its grounding in the Source column.
#
# Usage:  build-nvidia-oracle.sh                  write the CSV (gates first)
#         build-nvidia-oracle.sh --declined-list  the 34-row contingency printout
#         build-nvidia-oracle.sh --roundtrip      the NVOR toggle round trip alone
#         build-nvidia-oracle.sh --bite           corrupt the D3 direction
#                                                 predicate and require the pins
#                                                 above to redden, by name
# Any other argument is REFUSED (fail-closed on an unrecognised mode).
set -euo pipefail
cd "$(dirname "$0")"
SELF="$PWD/$(basename "$0")"    # --bite re-runs a corrupted copy of this file
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh          # for SHAPE_NPROCS (2-proc vs transitive split)

MODEL="NVIDIA-PTX-AArch64"
die() { echo "build-nvidia-oracle: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# THE NVOR SLOT TOGGLE  (the X2A_TRANSFERS analog; register NVOR-register.md).
#
# ONE variable.  It gates the declined SLOTS, never a verdict: with
# NVOR_ACCEPT_DECLINED=0 (the shipping default) a row whose derivation needs Q2,
# Q3 or Q4 is marked UNKEYED and classify falls through to NO-ORACLE, so a future
# arch-native key removes rows from the toggle set BY CONSTRUCTION rather than by
# a post-hoc verdict rewrite.  =1 is the counterfactual "suppose Nguyen had
# accepted all three" and reproduces the PRE-regeneration verdicts (319/50/42).
#
# The ablation branch writes a DIFFERENT FILE.  A counterfactual run in the tree
# must never be able to overwrite the shipping oracle -- which is exactly what a
# single $OUT would have allowed.
NVOR_ACCEPT_DECLINED="${NVOR_ACCEPT_DECLINED:-0}"
case "$NVOR_ACCEPT_DECLINED" in 0|1) ;; *) die "NVOR_ACCEPT_DECLINED must be 0 or 1";; esac
if [ "$NVOR_ACCEPT_DECLINED" = 0 ]; then OUT=expected-nvidia.csv
else                                     OUT=expected-nvidia-declined.csv; fi

# The demotion set, pinned.  34 = 23 gc (Q2) + 3 Fence-SC (Q3) + 8 cg
# unidirectional-fence (Q4).  Both the count and the sha of the sorted names are
# asserted at generation time: a slot gated too wide or too narrow cannot ship.
# It was 32 = 19 + 2 + 11 until NVOR Phase D3 (2026-08-06) re-keyed the GC slot
# from the name tag to the rf DIRECTION: +2 LB-cg rows that had shipped
# Disallowed on the declined gc meet, +3 LB-cg rows that gain the (gc) slot
# beside the (unifence) one they already had, and R-gc-sys-fence-2s losing a
# (gc) it never needed (its cycle is rf-free).
EXPECT_DEMOTED=34
EXPECT_DEMOTED_SHA="31df21956128093d"      # sha256[:16] of the sorted 34 names
EXPECT_PRE_A=319 EXPECT_PRE_D=50 EXPECT_PRE_N=42     # pre-regeneration census
EXPECT_A=319     EXPECT_D=16     EXPECT_N=76         # shipping census

# ---------------------------------------------------------------------------
# SHARED CITATION FRAGMENTS.  Bracket blocks are ';'-separated fragment lists and
# must contain NO comma (this file is a CSV).  Every fragment is exact-match
# material for hetlitmus/verify/nvprovcheck.py's FRAGMENTS table.
# ---------------------------------------------------------------------------

# Q1, the registered CPU-producer coupling.  Three sub-registrations travel with
# it and are named in the prose of every row that uses it: the ARM->PTX ROLE map
# (the PRIM table below -- hand-written, no solver checks it, WIDER IS THE
# DANGEROUS DIRECTION), the strength/proxy claim (a plain ARM access is a PTX
# STRONG operation on the generic proxy -- needed TWICE per row, at the sect
# 8.9.4 pattern boundary and again in sect 8.9.2 observation order) and the meet
# (unscoped ARM ops promote to system scope).
F_Q1="decision NVOR-Q1 cg-coupling REGISTERED; CMCM 3.2.3+4.4+4.6; PTX ISA 9.3 8.5 Tab21 sys-includes-host; PTX ISA 9.3 8.7 morally-strong; Bagchi 3.2+4.2; Bagchi 4.2 disclosure MP-shaped cg-direction only; NVOR-register.md"
# The same block on the counterfactual branch, where Q2/Q3/Q4 are ACCEPTED.
F_CF="decision NVOR counterfactual branch NVOR_ACCEPT_DECLINED=1 -- Q2 and Q3 and Q4 accepted for ablation only"

# CPU-side S1.  herd7 Phase 1 runs Arm Ltd's OWN validated aarch64.cat (empty
# `extra' in herd(p,[])), which the NVOR admissibility partition grades key-grade
# for AArch64 PER-DEVICE facts -- and only for those: it never sees the coupling.
F_ARM="machine-checked herd7 AArch64 (Arm Ltd aarch64.cat) via verify/ordercheck.py Phase 1 -- PER-DEVICE ordering only; ARM bob in herd/libdir/aarch64hwreqs.cat:128 included from aarch64.cat:49; ARM Armed Cats TOPLAS'21 Fig12/Fig41 model-family lineage"

# GPU-side S2, per primitive, version-qualified (never a bare table number).
F_G_ra="PTX 3.3; PTX ISA 9.3 8.8 release/acquire patterns"
F_G_sc="decision NVOR-Q5 sc-pattern-lattice REGISTERED; PTX Lustig'19 3.4.1 modelled fence set is sc and acq_rel so fence.sc is both FREL and FACQ; PTX Lustig'19 Fig4 patternrel/patternacq; PTX sc-fence; PTX ISA 9.3 8.8 DISCLOSURE -- the >=8.8 clause text names neither fence.sc nor membar and the lattice reading is ours not the spec's"
F_G_rel="PTX ISA 9.3 8.8 release/acquire patterns; PTX ISA 9.3 8.9.4 pattern synchronization; PTX ISA 9.3 8.11.1 normative forbidden outcome; PTX Lustig'19 Fig4 FREL/FACQ predicates"
F_G_acq="$F_G_rel"

# S5, the axiom that cuts each cycle, and S6, the second cross-device edge.
declare -A F_AX=(
  [MP]="PTX Lustig'19 Fig7 Ax6 Causality"
  [LB]="PTX Lustig'19 Fig7 Ax6 Causality"
  [S]="PTX Lustig'19 Fig7 Ax1 Coherence"
  [SB]="PTX Lustig'19 Fig7 Ax2 Fence-SC"
  [R]="PTX Lustig'19 Fig7 Ax1 Coherence; PTX Lustig'19 Fig7 Ax2 Fence-SC"
)
declare -A F_S6=(
  [MP]="PTX ISA 9.3 8.10.6 worked MP -- in the absence of any other writes R2 must read from W1"
  [LB]="PTX ISA 9.3 8.9.7 -- a second rf edge needs no moral strength"
  [S]="PTX ISA 9.3 8.9.6 coherence-order; Bagchi 5 CPU-GPU coherence; Bagchi 5.4 QUALIFIER -- the paper's invalidations do not appear to directly propagate to the GPU L1 caches which is measured at cta scope and this row carries none"
  [SB]="PTX ISA 9.3 8.10.6 worked MP -- in the absence of any other writes R2 must read from W1"
  [R]="PTX ISA 9.3 8.9.6 DISCLOSURE -- the final-value condition presupposes co between two RACY writes which 8.9.6 leaves unrelated; PTX ISA 9.3 8.10.6 worked MP -- in the absence of any other writes R2 must read from W1"
)
# Per-shape statement of what the cut buys, kept from the pre-NVOR hand-written
# rows so the derivation reads as prose and not only as a fragment list.
declare -A CUTWHY=(
  [MP]="single-hop release/acquire hb from the producer's flag write to the consumer's flag read closes the MP cycle at the Fre edge"
  [LB]="both communication edges are rf and a 2-proc LB cycle needs no multi-copy atomicity"
  [S]="one global coherence order on the contended write plus the single-hop hb closes the 2-proc S cycle with no MCA needed"
  [SB]="both procs must order store->load which only a pair of SC fences reaches"
  [R]="the write-write pair on one proc and the store->load pair on the other are both ordered and the cycle is rf-free"
)

# ---------------------------------------------------------------------------
# ONE-SIDED Source strings.
#
# Anchor strings corrected 2026-08-06 (NVOR mechanical fixes 5 and 8): the
# `Bagchi Fig2a' cite pointed at Bagchi's DATA-FREE background MP diagram, and
# `Bagchi r3-5' at three Table-4 rows of which two are off-class (r4 and r5 both
# have Y=gpu).  Bare `[CMCM]' on the Allowed rows is a KNOWN OPEN ITEM, out of
# scope for this commit and recorded in NVOR-register.md.
# ---------------------------------------------------------------------------
S_RELAXED="ARMv9/PTX relaxed: no synchronizing op; weak outcome permitted [Bagchi 4.1 Tab3 r1 rlx/rlx weak OBSERVED 225M runs; Bagchi 4.2 Tab4 r5+r6+r14 relaxed weak OBSERVED; PTX-relaxed; CMCM]"
S_CTA="cta scope: too narrow to encompass CPU thread; not morally strong [Bagchi 4.2 Tab4 r3 cta/cta weak OBSERVED; Bagchi Fig4c cta-scope RC weak OBSERVED; PTX 3.3; CMCM]"
S_GPU="gpu scope: excludes CPU thread; not morally strong [Bagchi Fig4b gpu-scope RC weak OBSERVED cg; Bagchi Fig4e/r21-22; PTX 3.3; CMCM]"
# 2-proc one-sided sys (the one ordering-critical CPU proc of the cut is plain).
# CMCM Fig2a struck here too (Q6): it is the x86TSO+PTX example and its forbidden
# verdict is attributed by CMCM 3.1 to the x86TSO consumer's acquire semantics --
# a property no ARMv9 load has.  Verified non-load-bearing at class level.
S_SYS1="sys sync one-sided: paired CPU proc is plain ARMv9 (RC); morally-strong pair incomplete [Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row exists in the paper; ARMv9 RC; CMCM]"
# 3/4-proc one-sided sys (>=1 ordering-critical proc on a plain ARMv9 CPU):
S_SYSN="sys sync incomplete: ordering-critical proc(s) on plain ARMv9 CPU; sync chain not closed [Bagchi Tab4 GAP -- no sys-scope GPU-acquire consumer row exists in the paper; ARMv9 RC; CMCM]"
S_IRIW1="IRIW forbid needs system MCA; PTX non-MCA & ARM-MCA x PTX-non-MCA interaction unestablished [Bagchi 2.1 MCA-future-work p68; CMCM 4.2 non-MCA p153:11; PTX non-MCA; PTX Lustig'19 3.4 non-MCA]"

# Two-sided Source strings that are NOT produced by the order-pair rule.
S_SBR_RA="two-sided sys release/acquire: RCpc STLR->LDAPR (and PTX rel/acq) do NOT order store->load on the proc whose pair is W->R -> the pair is present but insufficient (an SC fence is needed) [PTX 3.3; ARM RCpc; CMCM; cf AMD gpu-only AMD-GCN3 SB-sys is Disallowed while NVIDIA-PTX Allows it -- NOTE never a key]"
S_RWC_RA="two-sided sys release/acquire: the W->R (store->load) proc is unfenced so the weak outcome survives without invoking MCA [PTX 3.3; ARM RCpc; CMCM; cf AMD gpu-only AMD-GCN3 SB-sys is Disallowed while NVIDIA-PTX Allows it -- NOTE never a key]"
S_2P2W="two-sided complete pair, but 2+2W needs a global write-write order (multi-copy atomicity); ARM-MCA x PTX-non-MCA unestablished [Bagchi 2.1 MCA-future-work p68; PTX non-MCA; PTX Lustig'19 3.4 non-MCA; CMCM 4.2 non-MCA p153:11]"
S_TRANS="two-sided complete pair, but this transitive shape needs cross-device A-cumulativity through a GPU intermediary; ARM-oMCA x PTX-non-MCA unestablished [Bagchi 2.1 MCA-future-work p68; PTX non-MCA; PTX Lustig'19 3.4 non-MCA; CMCM 4.2 non-MCA p153:11]"
S_IRIW2="two-sided reader ordering present, but IRIW needs multi-copy atomicity; ARM-MCA x PTX-non-MCA unestablished [Bagchi 2.1 MCA-future-work p68; PTX non-MCA; PTX Lustig'19 3.4 non-MCA; CMCM 4.2 non-MCA p153:11]"

# ---------------------------------------------------------------------------
# THE NVOR DEMOTION CLASSES.  Four, because a demoted row must name EVERY slot
# its own derivation needs and 9 of the 23 gc rows need a second one.  The
# S_CUT_UNKEYED precedent (build-amd-oracle.sh): no blanket punting.  There were
# five until NVOR Phase D3 struck `GC SC': keying GC to the rf DIRECTION rather
# than the name tag makes that combination impossible rather than merely unused
# (GC needs a producer -> consumer rf; SC fires only when there is none).
# ---------------------------------------------------------------------------
D_GC="cycle cut UNKEYED in the GPU-PRODUCER direction -- decision NVOR-Q2 (Nguyen 2026-08-06) DECLINED to register the SYMMETRIC MEET. THE SLOT IS KEYED TO THE DIRECTION OF THE SYNCHRONIZING rf AND NOT TO THE TEST NAME (NVOR Phase D3 2026-08-06): on the LB shape BOTH communication edges are rf so a cg-NAMED test synchronizes gc-wards whenever its CPU primitive carries only the ACQUIRE role -- a DMB LD does not order prior stores so it cannot head a release pattern and the ONLY route that cuts the cycle is GPU-release -> CPU-acquire which is exactly the declined meet. The cg direction is registered (Q1) but the meet CMCM 4.6 leaves open is architecture-specific and CMCM footnote 7 p153:13 warns it CAN BE ASYMMETRICAL. Every scrap of GH200 system-scope het evidence is cg-direction: Bagchi Table 4 has GPU_rlx in the Consumer column of all 13 CPU-producer rows and GPU_acq nowhere at all and its only GPU_rel rows (21-22) are Y=gpu never Y=system; Fig 4a is CPU-producer; the sect 3.2 derivation is CPU-producer. These rows rest on framework text alone. NO-ORACLE not Allowed -- silence is not permission. THIS IS A PRE-REGISTERED FALSIFIABLE PREDICTION: observing the listed outcome on GH200 is DATA never a refutation of the compound model. NVOR_ACCEPT_DECLINED=1 restores the pre-regeneration Disallowed (contingency: build-nvidia-oracle.sh --declined-list) [decision NVOR-Q2 gc-meet DECLINED; CMCM 4.6 p153:13-14 -- admissible sect 3-4 framework naming the open slot; CMCM fn7 p153:13 the meet can be asymmetrical; Bagchi 4.2 Tab4 GAP -- no correctly sys-annotated GPU producer row exists; NVOR-register.md]"
D_GC_UNIDIR="cycle cut UNKEYED TWICE -- decisions NVOR-Q2 and NVOR-Q4 (Nguyen 2026-08-06). (i) Q2 DECLINED the symmetric meet so the GPU-producer direction has no registered coupling: CMCM footnote 7 p153:13 warns the meet can be asymmetrical and all GH200 sys-scope het evidence is cg-direction. (ii) Q4 DECLINED the unidirectional-fence semantics: fence.acquire and fence.release are PTX ISA 8.6/SM_90 and POSTDATES Lustig'19 so the row's GPU-side ord fact rests on spec prose plus a .cat extrapolation with ZERO exercised coverage anywhere -- Lustig'19 never instantiated a FREL-not-FACQ fence and Bagchi tested none and the spec's only worked unidirectional thread fences are the sync_restrict cluster forms. NO-ORACLE not Allowed. Observing the listed outcome on GH200 is DATA never a refutation. NVOR_ACCEPT_DECLINED=1 restores the pre-regeneration Disallowed [decision NVOR-Q2 gc-meet DECLINED; decision NVOR-Q4 unidirectional-fence DECLINED; CMCM 4.6 p153:13-14 -- admissible sect 3-4 framework naming the open slot; CMCM fn7 p153:13 the meet can be asymmetrical; PTX ISA 9.3 8.8 release/acquire patterns; PTX ISA 9.3 8.9.4 pattern synchronization; PTX Lustig'19 Fig4 FREL/FACQ predicates; NVOR-register.md]"
D_SC="cycle cut UNKEYED -- decision NVOR-Q3 (Nguyen 2026-08-06) DECLINED to register that an ARM DMB SY IS a PTX fence.sc. This cycle carries no rf edge at all so the only route that cuts it is PTX's FENCE-SC ORDER which PTX ISA 9.3 8.9.3 defines as relating every pair of MORALLY STRONG fence.sc OPERATIONS -- strictly stronger than the sys-scoped-fence premise Q1 registers and a cross-ISA identification for which PTX offers no route (its sect 8.9.4 pairs a fence.sc only with another fence.sc). CMCM's operational LOST-POP has no Fence-SC object so the CMCM route sidesteps the question rather than answering it. A SECOND unregistered premise rides on this same route and is named here rather than left implicit (NVOR Phase D3 2026-08-06 -- NVOR-register.md open item O8): the Fence-SC order relates the two fence.sc operations only if they are MORALLY STRONG WITH EACH OTHER and that is a cross-device determination on a FENCE-FENCE pair which has no producer and no consumer -- so it falls under neither Q1 (registered in the CPU-producer direction only) nor Q2 (a producer -> consumer meet) and granting Q3 alone would still not carry these rows. It is latent while Q3 is declined and load-bearing the moment Q3 is registered. The gc meet is NOT among the missing premises here: with no rf in the cycle there is no cross-device producer -> consumer communication for a meet to apply to. On the R shape a second independent reason stands: the final-value condition presupposes a co edge between two RACY writes which PTX ISA 9.3 8.9.6 says are UNRELATED in coherence order. The GPU half of these rows is the BEST-supported in the corpus -- the weakness is entirely ARM-side. NO-ORACLE not Allowed. Observing the listed outcome on GH200 is DATA never a refutation. NVOR_ACCEPT_DECLINED=1 restores the pre-regeneration Disallowed [decision NVOR-Q3 sc-identification DECLINED; PTX ISA 9.3 8.9.3 Fence-SC order; PTX ISA 9.3 8.9.6 coherence-order; CMCM 4.6 p153:13-14 -- admissible sect 3-4 framework naming the open slot; NVOR-register.md]"
D_UNIDIR="cycle cut UNKEYED -- decision NVOR-Q4 (Nguyen 2026-08-06) DECLINED to register the unidirectional-fence semantics. fence.acquire and fence.release are PTX ISA 8.6/SM_90 and POSTDATES Lustig'19 (no unidirectional fence in its Fig 3c grammar) so this row's GPU-side ord fact is not covered by the formalization: it rests on PTX ISA >=8.8 clause prose read as normative over the un-updated Table-20 enumeration plus a project .cat extrapolation. The reach clauses do match this table's own gpu:rel and gpu:acq ord sets clause for clause and the spec carries a normative forbidden outcome at 8.11.1 that needs such a fence to be strong and scoped and pattern-completing -- but what NO source supplies is COVERAGE: Lustig'19 never instantiated a FREL-not-FACQ fence and Bagchi tested none and Srivastava used CUDA intrinsics and the spec's only worked unidirectional THREAD fences are the sync_restrict::shared cluster forms which are a materially different configuration. NO-ORACLE not Allowed. Observing the listed outcome on GH200 is DATA never a refutation. NVOR_ACCEPT_DECLINED=1 restores the pre-regeneration Disallowed [decision NVOR-Q4 unidirectional-fence DECLINED; PTX ISA 9.3 8.8 release/acquire patterns; PTX ISA 9.3 8.9.4 pattern synchronization; PTX ISA 9.3 8.11.1 normative forbidden outcome; PTX Lustig'19 Fig4 FREL/FACQ predicates; NVOR-register.md]"

# ---------------------------------------------------------------------------
# The two-sided order-pair grid  <cpu>.<gpu>  (header decision table).
# The Source strings built here must contain NO comma -- this file is a CSV --
# so primitives are named by their real mnemonics: `DMB SY', `fence.acquire.sys'.
# ---------------------------------------------------------------------------

# The order-pair alphabet: <side>:<tok> -> "<ord>|<role>|<name>".
#   ord   the program-order pairs of {WW RR WR RW} the primitive orders inside
#         its own thread.  ARM rows are herd7's own answer under Arm Ltd's
#         aarch64.cat; GPU rows are Lustig'19 / PTX ISA 9.3 sect 8.8 (quoted in
#         docs/het-oracle.md).  Note that release/acquire lacks WR -- that is
#         RCpc, and it is why SB/R stay Allowed under everything but a pair of
#         SC fences.
#   role  which half of a morally-strong pair the primitive can supply.  THE CPU
#         ROWS OF THIS COLUMN ARE THE ARM->PTX REQUEST-TYPE MAP: hand-written,
#         checked by no solver, and the object of registration NVOR-Q1.  A WIDER
#         map manufactures Disallowed verdicts, so wide is the DANGEROUS
#         direction; it is stated here so it can be attacked.
#   name  the mnemonic printed in the Source column; no commas (this is a CSV).
declare -A PRIM=(
  [cpu:ra]="WW RR RW|rel acq|STLR/LDAPR"
  [cpu:sy]="WW RR WR RW|rel acq sc|DMB SY"
  [cpu:st]="WW|rel|DMB ST"
  [cpu:ld]="RR RW|acq|DMB LD"
  [gpu:ra]="WW RR RW|rel acq|w[release.sys]/r[acquire.sys]"
  [gpu:sc]="WW RR WR RW|rel acq sc|fence.sc.sys"
  [gpu:rel]="WW RW|rel|fence.release.sys"
  [gpu:acq]="RR RW|acq|fence.acquire.sys"
)
# prim <cpu|gpu> <tok> -> sets PRIM_ORD, PRIM_ROLE, PRIM_NAME; fails closed on a
# token that side does not have.  MUST NOT be called in a command substitution:
# an `exit 1' inside `$(...)' kills only the subshell, turning a fail-closed
# guard into a silent fail-open.  It sets globals, called as a plain statement.
prim() {
  local e="${PRIM[$1:$2]:-}"
  if [ -z "$e" ]; then
    echo "build-nvidia-oracle: unknown order-pair primitive '$1:$2'" >&2; exit 1
  fi
  PRIM_ORD="${e%%|*}"; PRIM_NAME="${e##*|}"; e="${e#*|}"; PRIM_ROLE="${e%%|*}"
}
has_tok() { local n="$1"; shift; case " $* " in (*" $n "*) return 0;; (*) return 1;; esac; }

# two_sided_order_pair <shape> <cuttag> <cpu-tok> <gpu-tok>
#   -> VERDICT, SOURCE, CLASS, NVOR_SLOTS (space-separated open-slot tags)
two_sided_order_pair() {
  local shape="$1" tag="$2" c="$3" g="$4"
  local -a CY; read -ra CY <<< "${SHAPE_CYCLE[$shape]}"
  local p0="${CY[0]#Pod}" p1="${CY[2]#Pod}"
  local d0="${tag:0:1}" pc pg r0 r1 oc og nc ng rolec roleg prod0 prod1
  NVOR_SLOTS=""
  if [ "$d0" = c ]; then pc="$p0"; pg="$p1"; else pc="$p1"; pg="$p0"; fi
  prim cpu "$c"; nc="$PRIM_NAME"; oc="$PRIM_ORD"; rolec="$PRIM_ROLE"
  prim gpu "$g"; ng="$PRIM_NAME"; og="$PRIM_ORD"; roleg="$PRIM_ROLE"

  # (1) each thread's own model must order its own program-order pair
  if ! has_tok "$pc" $oc; then
    VERDICT=Allowed; CLASS=ORDPAIR-ALLOWED-CPU
    SOURCE="two-sided sys order pair ($nc | $ng): the CPU thread's own ISA leaves its $pc program-order pair unordered so no reading of the compound model cuts the cycle [machine-checked herd7 AArch64 via verify/ordercheck.py; CMCM 4.3 fence orderings]"
    return
  fi
  if ! has_tok "$pg" $og; then
    VERDICT=Allowed
    # Q4b (Nguyen 2026-08-06, LENIENT): the 18 rows whose GPU primitive is a
    # unidirectional fence make a NEGATIVE ord claim about an instruction that
    # postdates Lustig'19.  They keep Allowed on the a-fortiori transfer -- CMCM
    # sect 5's operational PTX is by its own sect 5.1 STRICTLY STRONGER than
    # axiomatic PTX, and a strictly stronger model leaving a pair unordered
    # implies the true model does too -- with the extrapolation DISCLOSED, since
    # a doubted Allowed row can absorb a real violation as a false confirmation.
    case "$g" in
      rel|acq)
        CLASS=ORDPAIR-ALLOWED-GPU-UNIDIR
        SOURCE="two-sided sys order pair ($nc | $ng): the GPU thread's own model leaves its $pg program-order pair unordered so no reading of the compound model cuts the cycle. DISCLOSED (decision NVOR-Q4b lenient): $ng is PTX ISA 8.6/SM_90 and postdates Lustig'19 so this NEGATIVE ord claim is keyed to Lustig'19's FREL/FACQ pattern predicates plus PTX ISA >=8.8 clause prose read as an extrapolation -- not to an exercised formal instance. The transfer is a-fortiori: CMCM 5.1 states its operational PTX is STRICTLY STRONGER than the axiomatic model so a pair left unordered there is unordered in the true model [PTX Lustig'19 Fig4 FREL/FACQ predicates; PTX ISA 9.3 8.8 release/acquire patterns; CMCM 5 PTX sem>=rel/acq; decision NVOR-Q4b lenient; machine-checked nvidia-ptx.cat via verify/ordercheck.py; NVOR-register.md]"
        ;;
      *)
        CLASS=ORDPAIR-ALLOWED-GPU
        SOURCE="two-sided sys order pair ($nc | $ng): the GPU thread's own model leaves its $pg program-order pair unordered so no reading of the compound model cuts the cycle -- PTX release/acquire alone never orders store->load and only the Fence-SC order reaches it [PTX Lustig'19 3.4.3 Fence-SC prevents what acquire/release alone cannot such as the SB pattern of Figure 6; PTX Lustig'19 Fig6 SB fence.sc; PTX ISA 9.3 8.10.6 corroboration -- stated about replacing a standalone fence.sc by fence.acq_rel not about annotated ops; machine-checked nvidia-ptx.cat via verify/ordercheck.py]"
        ;;
    esac
    return
  fi

  # (2) the [PTX] Fig4/Fig6 pattern requirement on top of per-side ordering.
  #
  # THE DIRECTION OF THE SYNCHRONIZING rf, NOT THE NAME TAG (NVOR Phase D3,
  # 2026-08-06).  What the premise register asks is `does this derivation need a
  # GPU-PRODUCER -> CPU-CONSUMER communication to be morally strong?'.  The
  # cuttag answers a DIFFERENT question -- `which device sits on P0?' -- and the
  # two coincide only where the cycle has a single Rfe edge.  MP (PodWW Rfe
  # PodRR Fre) and S (PodWW Rfe PodRW Coe) have one; R (PodWW Coe PodWR Fre) and
  # SB have none; LB (PodRW Rfe PodRW Rfe) has TWO, so a cg-NAMED LB test
  # synchronizes gc-wards whenever its CPU primitive carries only the acquire
  # role -- DMB LD does not order prior stores so it cannot head a release
  # pattern.  Phase E's BLIND re-derivation found two such rows shipping as
  # Disallowed on the DECLINED Q2 meet, invisible to both slot-gate
  # implementations and to the count-and-sha pin because both were wrong by the
  # same rows (env-research/NVOR-DR-nvidia-oracle.md).  So the producing DEVICE
  # is measured per firing branch below and the slot gate keys on THAT.
  if [ "$d0" = c ]; then r0="$rolec"; r1="$roleg"; prod0=cpu; prod1=gpu
  else                   r0="$roleg"; r1="$rolec"; prod0=gpu; prod1=cpu; fi
  local sync=0 why="" rffree=0 swprod="" cgwhy="" gcwhy=""
  # branch 1: P0 releases and P1 acquires across CY[1] -- the producer is P0.
  if [ "${CY[1]}" = Rfe ] && has_tok rel $r0 && has_tok acq $r1; then
    sync=1
    if [ "$prod0" = cpu ]; then cgwhy="the CPU releases and the GPU acquires across the cg-direction rf"
    else                        gcwhy="the GPU releases and the CPU acquires across the gc-direction rf"; fi
  fi
  # branch 2: P1 releases and P0 acquires across CY[3] -- the producer is P1.
  if [ "${CY[3]}" = Rfe ] && has_tok rel $r1 && has_tok acq $r0; then
    sync=1
    if [ "$prod1" = cpu ]; then cgwhy="the CPU releases and the GPU acquires across the cg-direction rf"
    else                        gcwhy="the GPU releases and the CPU acquires across the gc-direction rf"; fi
  fi
  # When BOTH edges carry a completing pattern the row is keyed to the cg one:
  # that is the REGISTERED direction (Q1) and `why' must name the route the
  # verdict actually rests on -- not whichever branch happened to run last,
  # which is what made four sound LB rows advertise the declined gc route.
  if [ -n "$cgwhy" ]; then
    swprod=cpu; why="$cgwhy"
    [ -n "$gcwhy" ] && why="both sides carry the release and the acquire role so the pattern completes in BOTH directions and this row is keyed to the REGISTERED cg one: $cgwhy while the second rf is a bare cycle edge that needs no moral strength"
  elif [ -n "$gcwhy" ]; then
    swprod=gpu; why="$gcwhy"
  fi
  if [ "${CY[1]}" != Rfe ] && [ "${CY[3]}" != Rfe ]; then
    if has_tok sc $r0 && has_tok sc $r1; then
      sync=1; rffree=1; why="the cycle carries no rf so both threads supply an SC fence"
    fi
  fi

  if [ "$sync" != 1 ]; then
    # N3: both threads order their own pair but the pattern does not complete.
    # HONESTY REWORD (NVOR mechanical fix 4): the old string quoted CMCM 5.1's
    # write-serialization / cumulative-chains gap, which is off-point on all 8
    # rows -- none turns on write serialization and all 8 are 2-proc so
    # cumulative chains cannot apply -- and it stated the divergence about the
    # x86TSO+PTX machine's two models, not about the ARM+PTX one.
    VERDICT=NO-ORACLE; CLASS=ORDPAIR-NOORACLE
    SOURCE="two-sided sys order pair ($nc | $ng): both threads order their own program-order pair but NO PTX synchronization pattern completes on the ARM+PTX machine -- the row is missing a pattern half (no release to match the acquire or no sc on both sides of an rf-free cycle) so nothing establishes a cross-device happens-before. CMCM's OPERATIONAL compound model would forbid this outcome and its own AXIOMATIC model permits it; the operational reading is the one that has no PTX-native support here. Characterization not a falsification claim [CMCM 4.3 fence orderings; PTX Lustig'19 Fig4 patternrel/patternacq; PTX Lustig'19 Fig6 SB fence.sc; PTX ISA 9.3 8.9.3 Fence-SC order; PTX ISA 9.3 8.9.4 pattern synchronization; machine-checked nvidia-ptx.cat via verify/ordercheck.py]"
    return
  fi

  # (3) THE NVOR SLOT GATE.  The pattern completes -- now which registrations
  # does the row need, and are they registered?  GC keys on the DEVICE that
  # produces the value the sw rides on (see (2)), never on the cuttag.
  local slots=""
  [ "$swprod" = gpu ] && slots="$slots GC"
  [ "$rffree" = 1 ] && slots="$slots SC"
  case "$g" in rel|acq) slots="$slots UNIDIR";; esac
  NVOR_SLOTS="${slots# }"

  if [ -n "$NVOR_SLOTS" ] && [ "$NVOR_ACCEPT_DECLINED" = 0 ]; then
    VERDICT=NO-ORACLE
    # `GC SC' is absent BY CONSTRUCTION since D3 and not merely absent from this
    # corpus: GC needs a producer -> consumer rf to be morally strong and SC
    # fires only when the cycle carries NO rf at all.  A dead arm that can never
    # be reached is worse than none -- it reads to an auditor as coverage.
    case "$NVOR_SLOTS" in
      "GC")         CLASS=S_GC_MEET_UNKEYED;     SOURCE="$D_GC";;
      "GC UNIDIR")  CLASS=S_GC_UNIDIR_UNKEYED;   SOURCE="$D_GC_UNIDIR";;
      "SC")         CLASS=S_SC_IDENT_UNKEYED;    SOURCE="$D_SC";;
      "UNIDIR")     CLASS=S_UNIDIR_UNKEYED;      SOURCE="$D_UNIDIR";;
      *) die "unhandled NVOR slot set '$NVOR_SLOTS' on $shape-$tag $c.$g";;
    esac
    return
  fi

  # (4) Disallowed: every step keyed, every registration the row needs made.
  local gsrc; eval "gsrc=\"\$F_G_$g\""
  local cf=""
  [ -n "$NVOR_SLOTS" ] && cf="; $F_CF"
  VERDICT=Disallowed; CLASS=ORDPAIR-DISALLOWED
  SOURCE="two-sided sys order pair ($nc | $ng): CPU orders its $pc pair and GPU orders its $pg pair and $why; unscoped ARM ops are system-scoped and the ARM->PTX role map sends this CPU primitive to the half its pattern needs and a plain ARM access is a PTX STRONG operation on the generic proxy -- all three by REGISTERED decision NVOR-Q1 (no vendor document supplies them and no solver checks them; a WIDER role map is the dangerous direction). ${CUTWHY[$shape]} [$F_ARM; $gsrc; ${F_AX[$shape]}; ${F_S6[$shape]}; $F_Q1; machine-checked nvidia-ptx.cat via verify/ordercheck.py$cf]"
}

# classify <name> -> sets globals VERDICT, SOURCE, CLASS, NVOR_SLOTS
classify() {
  local name="$1" base shape cuttag scope order two=0
  CLASS=""; NVOR_SLOTS=""
  case "$name" in
    # The two hand-checked reference tests are one-sided 2-proc (CPU plain).
    MP-het|SB-het) VERDICT=Allowed; CLASS=S_SYS1; SOURCE="$S_SYS1"; return;;
  esac
  base="$name"; case "$name" in *-2s) base="${name%-2s}"; two=1;; esac
  local -a F; IFS='-' read -ra F <<< "$base"
  local n=${#F[@]}
  order="${F[n-1]}"; scope="${F[n-2]}"; cuttag="${F[n-3]}"; shape="${F[0]}"

  if [ "$two" = 0 ]; then
    if [ "$order" = relaxed ]; then VERDICT=Allowed; CLASS=S_RELAXED; SOURCE="$S_RELAXED"; return; fi
    case "$scope" in
      cta) VERDICT=Allowed; CLASS=S_CTA; SOURCE="$S_CTA"; return;;
      gpu) VERDICT=Allowed; CLASS=S_GPU; SOURCE="$S_GPU"; return;;
    esac
    # sys + acquire/release/fence
    if [ "$shape" = IRIW ] && [ "$cuttag" = gcgc ] \
       && { [ "$order" = acquire ] || [ "$order" = fence ]; }; then
      VERDICT=NO-ORACLE; CLASS=S_IRIW1; SOURCE="$S_IRIW1"; return
    fi
    # 2-proc cut -> one critical CPU proc (S_SYS1); 3/4-proc -> chain (S_SYSN).
    VERDICT=Allowed
    if [ "${SHAPE_NPROCS[$shape]}" = 2 ]; then CLASS=S_SYS1; SOURCE="$S_SYS1"
    else CLASS=S_SYSN; SOURCE="$S_SYSN"; fi
    return
  fi

  # two-sided.  First the order-pair grid `<cpu>.<gpu>' (2-proc shapes only;
  # anything else is a generation bug -> fail closed).
  case "$order" in
    *.*)
      case "$shape" in
        MP|SB|LB|R|S)
          two_sided_order_pair "$shape" "$cuttag" "${order%%.*}" "${order##*.}"
          return;;
        *) echo "build-nvidia-oracle: order-pair '$order' on unsupported shape '$shape' ($name)" >&2; exit 1;;
      esac;;
  esac

  # then the matched {acqrel,fence} pairings (scope is always sys)
  case "$shape" in
    # On the 2-proc shapes these are the diagonal of the order-pair grid --
    # acqrel is its (ra,ra) cell and fence its (sy,sc) one -- so BOTH the verdict
    # and (since the NVOR regeneration) the grounding text come from the grid.
    # The pre-NVOR per-shape strings were the 13 rows that cited bare `[CMCM]';
    # unifying them removes that class and stops the two string families
    # drifting apart.  Only the Allowed diagonal keeps a bespoke string.
    MP|LB|S|SB|R)
      case "$order" in
        acqrel) two_sided_order_pair "$shape" "$cuttag" ra ra;;
        fence)  two_sided_order_pair "$shape" "$cuttag" sy sc;;
        *) echo "build-nvidia-oracle: unhandled two-sided order '$order' ($name)" >&2; exit 1;;
      esac
      if [ "$VERDICT" = Allowed ]; then CLASS=S_SBR_RA; SOURCE="$S_SBR_RA"; fi;;
    RWC) if [ "$order" = fence ]; then VERDICT=NO-ORACLE; CLASS=S_TRANS; SOURCE="$S_TRANS"
         else VERDICT=Allowed; CLASS=S_RWC_RA; SOURCE="$S_RWC_RA"; fi;;
    2+2W) VERDICT=NO-ORACLE; CLASS=S_2P2W; SOURCE="$S_2P2W";;
    WRC|ISA2|WRC3) VERDICT=NO-ORACLE; CLASS=S_TRANS; SOURCE="$S_TRANS";;
    IRIW) VERDICT=NO-ORACLE; CLASS=S_IRIW2; SOURCE="$S_IRIW2";;
    *) echo "build-nvidia-oracle: unhandled two-sided shape '$shape' ($name)" >&2; exit 1;;
  esac
}

corpus() { ls ./*.litmus | LC_ALL=C sort; }

# --- the NVOR toggle round trip (the G16 analog) -----------------------------
# Re-classify every row at NVOR_ACCEPT_DECLINED=1 and assert the flip touches
# EXACTLY the 34 demoted rows and NOTHING else: every toggled row goes
# NO-ORACLE -> Disallowed out of one of the five UNKEYED classes, every other
# row keeps its verdict AND its class, and the resulting census is the
# pre-regeneration 319/50/42.  It is a verdict/class round trip, not a byte
# comparison -- the re-keyed citation strings travel to both branches by design.
# This is the slot gate's own bite and it runs on EVERY generation, before the
# CSV is renamed into place: a slot gated wrongly (too wide, too narrow, or
# rewriting verdicts post-hoc) cannot ship.
roundtrip() {
  local n_tog=0 bad=0 name v0 c0
  declare -A RT=()
  for f in $(corpus); do
    name="$(basename "$f" .litmus)"
    # Both sides are FORCED, never inherited: `--roundtrip' invoked with the
    # flag already at 1 would otherwise compare the ablation branch with itself
    # and report 0 toggled rows -- a round trip that passes by doing nothing.
    NVOR_ACCEPT_DECLINED=0 classify "$name"; v0="$VERDICT" c0="$CLASS"
    NVOR_ACCEPT_DECLINED=1 classify "$name"
    RT[$VERDICT]=$(( ${RT[$VERDICT]:-0} + 1 ))
    if [ "$v0" = "$VERDICT" ] && [ "$c0" = "$CLASS" ]; then continue; fi
    n_tog=$((n_tog+1))
    case "$c0" in
      S_GC_MEET_UNKEYED|S_GC_UNIDIR_UNKEYED|S_SC_IDENT_UNKEYED|S_UNIDIR_UNKEYED)
        if [ "$v0" != NO-ORACLE ] || [ "$VERDICT" != Disallowed ] \
           || [ "$CLASS" != ORDPAIR-DISALLOWED ]; then
          echo "ROUNDTRIP FAIL: $name flips $v0/$c0 -> $VERDICT/$CLASS" >&2; bad=$((bad+1))
        fi;;
      *) echo "ROUNDTRIP FAIL: $name moves $c0 -> $CLASS (outside the NVOR toggle set)" >&2
         bad=$((bad+1));;
    esac
  done
  echo "== NVOR round trip: $n_tog rows toggle; census at NVOR_ACCEPT_DECLINED=1 is ${RT[Allowed]:-0}/${RT[Disallowed]:-0}/${RT[NO-ORACLE]:-0} ==" >&2
  [ "$bad" = 0 ] || die "ROUNDTRIP FAILED: $bad row(s) move outside the NVOR toggle set"
  [ "$n_tog" = "$EXPECT_DEMOTED" ] ||
    die "ROUNDTRIP FAILED: the toggle moves $n_tog rows but the adjudication demotes exactly $EXPECT_DEMOTED"
  { [ "${RT[Allowed]:-0}" = "$EXPECT_PRE_A" ] && [ "${RT[Disallowed]:-0}" = "$EXPECT_PRE_D" ] \
    && [ "${RT[NO-ORACLE]:-0}" = "$EXPECT_PRE_N" ]; } ||
    die "ROUNDTRIP FAILED: NVOR_ACCEPT_DECLINED=1 census is ${RT[Allowed]:-0}/${RT[Disallowed]:-0}/${RT[NO-ORACLE]:-0} not the pre-regeneration $EXPECT_PRE_A/$EXPECT_PRE_D/$EXPECT_PRE_N"
}

# --- the demoted-set sha, measured (used by the pin and by --declined-list) ---
demoted_names() {
  local name
  for f in $(corpus); do
    name="$(basename "$f" .litmus)"
    NVOR_ACCEPT_DECLINED=0 classify "$name"
    case "$CLASS" in
      S_GC_MEET_UNKEYED|S_GC_UNIDIR_UNKEYED|S_SC_IDENT_UNKEYED|S_UNIDIR_UNKEYED)
        printf '%s\t%s\t%s\n' "$name" "$CLASS" "$NVOR_SLOTS";;
    esac
  done
}

# --- the DIRECTION-PREDICATE bite (NVOR Phase D3, 2026-08-06) ----------------
# Keying the GC slot to the DIRECTION of the sw-carrying rf rather than to the
# test's name tag is the repair Phase E's blind re-derivation forced, and a
# predicate never seen to FAIL is not evidence that it does anything.  So
# `--bite' rewrites this file into a scratch tree three ways and requires each
# corruption to redden one of THIS SCRIPT'S OWN pins, by name:
#
#   A  the exact pre-D3 shortcut  [ "$d0" = g ].  Name and direction disagree on
#      R-gc too -- its cycle is rf-free, so no meet is even reachable -- and the
#      slot set `GC SC' that D3 made impossible reappears.
#   B  the same shortcut but restricted to rf-carrying cycles, which isolates
#      the LB reading alone: LB-cg-sys-ld.ra-2s and LB-cg-sys-ld.sc-2s re-arm to
#      Disallowed on the DECLINED Q2 meet and the census pin reddens at 18.
#      THIS PAIR IS THE FALSE-REFUTATION RISK the blind pass found.
#   C  the tie-break inverted (prefer gc when BOTH edges carry a pattern), which
#      strips the four sound LB-cg rows of the REGISTERED cg route they rest on.
#
# Each injection is proved NON-VACUOUS with cmp before it is run, and each must
# fail for ITS OWN reason: a corruption that reddens some other pin is not
# evidence about the predicate.  The corrupted copies write their CSV into the
# scratch tree; the shipping oracle is never touched.
BITE_A='s/\[ "\$swprod" = gpu \]/[ "\$d0" = g ]/'
BITE_B='s/\[ "\$swprod" = gpu \]/[ "\$d0" = g ] \&\& [ -n "\$swprod" ]/'
BITE_C='s/if \[ -n "\$cgwhy" \]; then/if [ -n "\$cgwhy" ] \&\& [ -z "\$gcwhy" ]; then/'

bite_one() {                    # <label> <sed-expr> <expected marker> <why>
  local label="$1" expr="$2" want="$3" why="$4" dir out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/het"
  cp ../_grid_lib.sh "$dir/"
  cp ./*.litmus "$dir/het/"
  sed "$expr" "$SELF" > "$dir/het/build-nvidia-oracle.sh"
  if cmp -s "$SELF" "$dir/het/build-nvidia-oracle.sh"; then
    rm -rf "$dir"
    die "BITE $label: VACUOUS -- the injection changed nothing so it proves nothing"
  fi
  out="$(bash "$dir/het/build-nvidia-oracle.sh" 2>&1)" && rc=0 || rc=$?
  rm -rf "$dir"
  [ "$rc" != 0 ] || die "BITE $label: the corrupted generator SUCCEEDED ($why)"
  case "$out" in
    *"$want"*) printf '  bite %-3s FAILS  %s\n' "$label" "$want" >&2;;
    *) printf '%s\n' "$out" >&2
       die "BITE $label: failed for the WRONG reason -- wanted '$want'";;
  esac
}

bite() {
  echo "== NVOR D3 direction-predicate bite: is the rf DIRECTION load-bearing? ==" >&2
  bite_one A "$BITE_A" "unhandled NVOR slot set 'GC SC' on R-gc sy.sc" \
    "the name tag claims a gc meet on an rf-free cycle"
  bite_one B "$BITE_B" "census FAILED: Disallowed = 18 but the register pins 16" \
    "the two LB-cg rows that rest on the declined Q2 meet re-armed silently"
  bite_one C "$BITE_C" "census FAILED: Disallowed = 12 but the register pins 16" \
    "four sound LB-cg rows lost their REGISTERED cg route"
  echo "build-nvidia-oracle: BITE OK (3 injections; the name-tag shortcut is dead)" >&2
}

# ===========================================================================
MODE="${1:---generate}"
case "$MODE" in
  --declined-list)
    echo "NVOR_ACCEPT_DECLINED = 0 (default).  The rows below are NO-ORACLE, not Disallowed."
    echo "Nguyen's adjudication of the NVOR Phase-C brief (2026-08-06) DECLINED three"
    echo "registrations the compound-model prediction for these rows depended on:"
    echo "  GC     Q2 -- the SYMMETRIC MEET.  CMCM 4.6's scope-intersection slot is"
    echo "         architecture-specific and its footnote 7 warns the meet can be"
    echo "         ASYMMETRICAL; every scrap of GH200 system-scope het evidence is"
    echo "         CPU-producer.  The GPU-producer direction rests on framework text."
    echo "         The slot keys on the DIRECTION of the synchronizing rf and not on"
    echo "         the test's name tag -- on LB both edges are rf so a cg-NAMED test"
    echo "         can synchronize gc-wards (NVOR Phase D3 2026-08-06)."
    echo "  SC     Q3 -- an ARM DMB SY IS a PTX fence.sc for the Fence-SC order"
    echo "         (PTX ISA 9.3 8.9.3 relates pairs of morally strong fence.sc"
    echo "         OPERATIONS; PTX offers no route from a non-PTX barrier)."
    echo "  UNIDIR Q4 -- fence.{acquire release}.sys semantics: PTX ISA 8.6/SM_90"
    echo "         forms postdating Lustig'19 with ZERO exercised coverage anywhere."
    echo
    echo "OBSERVING THE LISTED OUTCOME ON ANY OF THESE ROWS IS DATA, NOT A REFUTATION"
    echo "of the compound memory model.  They remain in the corpus and remain worth"
    echo "running -- the 23 GC rows in particular are a PRE-REGISTERED, hardware-"
    echo "falsifiable prediction that the meet is symmetric.  Setting"
    echo "NVOR_ACCEPT_DECLINED=1 restores the pre-regeneration verdicts (319/50/42)"
    echo "into expected-nvidia-declined.csv -- NEVER into the shipping oracle -- and"
    echo "may be used only for ablation, or with a recorded proof of the registration."
    echo
    n=0
    while IFS=$'\t' read -r nm cl sl; do
      printf '%-26s %-24s %s\n' "$nm" "$cl" "$sl"
      n=$((n+1))
    done < <(demoted_names)
    echo
    echo "total: $n rows" >&2
    [ "$n" = "$EXPECT_DEMOTED" ] || die "--declined-list: $n toggle rows not $EXPECT_DEMOTED"
    exit 0;;
  --roundtrip)
    roundtrip
    echo "build-nvidia-oracle: NVOR round trip OK" >&2
    exit 0;;
  --bite)
    bite
    exit 0;;
  --generate|"") ;;
  *) die "unknown mode '$MODE' (expected --generate | --declined-list | --roundtrip | --bite)";;
esac

# --- generate into a TEMP file; every guard runs BEFORE the mv ---------------
TMPOUT="$(mktemp "$PWD/.expected-nvidia.csv.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$TMPOUT'" EXIT
declare -A NVERD=() NCLASS=()
{
  echo "Litmus,Expected,Model,Source"
  echo "# NVIDIA GH200 het oracle (ARMv9 Grace + Hopper PTX = $MODEL).  Verdicts"
  echo "# are DERIVED, grounded in [CMCM] PLDI'23, [PTX] Lustig ASPLOS'19 + the"
  echo "# version-qualified PTX ISA, and [Bagchi] ISMM'26.  Generated by"
  echo "# build-nvidia-oracle.sh; see docs/het-oracle.md for the full decision"
  echo "# procedure + per-shape proofs.  Tally is printed to stderr at generation."
  echo "# NVOR (Nguyen 2026-08-06; env-research/NVOR-register.md): the census is"
  echo "# 319/16/76.  34 rows that used to be Disallowed are NO-ORACLE because the"
  echo "# adjudication DECLINED to register the gc-direction meet (23 rows), the"
  echo "# ARM-DMB-SY-is-a-PTX-fence.sc identification (3) and the unidirectional-"
  echo "# fence semantics (8).  OBSERVING ONE OF THOSE OUTCOMES ON HARDWARE IS"
  echo "# DATA, NEVER A REFUTATION of the compound model; the 23 gc rows are a"
  echo "# PRE-REGISTERED falsifiable prediction.  NVOR Phase D3 (2026-08-06) re-"
  echo "# keyed the gc slot from the test NAME TAG to the DIRECTION of the rf that"
  echo "# carries the synchronization -- they differ on LB -- which demoted 2 more"
  echo "# rows that had rested on the declined meet.  Per-row slots:"
  echo "#   build-nvidia-oracle.sh --declined-list"
  echo "# NVOR_ACCEPT_DECLINED=1 regenerates the pre-regeneration VERDICTS"
  echo "# (319/50/42) into a SEPARATE file expected-nvidia-declined.csv -- verdicts"
  echo "# row-for-row not bytes, since the re-keyed strings travel to both"
  echo "# branches; the round-trip gate pins it and runs on every generation."
  for f in $(corpus); do
    name="$(basename "$f" .litmus)"
    classify "$name"
    NVERD[$VERDICT]=$(( ${NVERD[$VERDICT]:-0} + 1 ))
    NCLASS[$CLASS]=$(( ${NCLASS[$CLASS]:-0} + 1 ))
    echo "$name,$VERDICT,$MODEL,$SOURCE"
  done
} > "$TMPOUT"

# ===========================================================================
# INVARIANTS.  All fatal, all re-measured FROM $TMPOUT -- the file that was just
# written -- before it is renamed over $OUT.  The loop counters above are kept as
# a SECOND, INDEPENDENT measurement and asserted to agree with the file, which is
# what catches an emit-line bug: a row printed with a value the counters never
# saw (demonstrated on the AMD generator 2026-08-02).
# ===========================================================================
csvrows() { grep -vE '^#|^Litmus,' "$TMPOUT"; }
csvcount() { csvrows | awk -F, -v f="$1" -v v="$2" '$f==v' | wc -l; }
ndata=$(csvrows | wc -l)
nlit=$(corpus | wc -l)
echo "wrote $OUT: $ndata rows for $nlit .litmus files" >&2
csvrows | cut -d, -f2 | LC_ALL=C sort | uniq -c >&2
[ "$ndata" = "$nlit" ] || die "row count $ndata != .litmus count $nlit"
[ "$ndata" = 411 ] || die "expected 411 corpus rows got $ndata"

# Column sanity.  Consumers read field 2 as the verdict and field 3 as the model
# (controlmap.py load_oracle, campaign.py, oracle-compare.sh); a malformed row
# there is silent corruption, so it is fatal.
badcols=$(csvrows | awk -F, -v m="$MODEL" '
  NF<4 || ($2!="Allowed" && $2!="Disallowed" && $2!="NO-ORACLE") || $3!=m {print NR": "$0}')
if [ -n "$badcols" ]; then
  echo "ERROR: malformed row(s) -- field 2 must be a verdict and field 3 the model:" >&2
  printf '%s\n' "$badcols" >&2; exit 1
fi

# Census pins.  BOTH branches are pinned: if the ablation branch stops
# reproducing the pre-regeneration verdicts the round trip is meaningless and the
# demotion stops being reversible.
if [ "$NVOR_ACCEPT_DECLINED" = 0 ]; then _A=$EXPECT_A _D=$EXPECT_D _N=$EXPECT_N
else                                     _A=$EXPECT_PRE_A _D=$EXPECT_PRE_D _N=$EXPECT_PRE_N; fi
chk() { [ "$2" = "$3" ] || die "census FAILED: $1 = $2 but the register pins $3"; }
chk Allowed    "$(csvcount 2 Allowed)"    "$_A"
chk Disallowed "$(csvcount 2 Disallowed)" "$_D"
chk NO-ORACLE  "$(csvcount 2 NO-ORACLE)"  "$_N"
for _v in Allowed Disallowed NO-ORACLE; do
  [ "${NVERD[$_v]:-0}" = "$(csvcount 2 "$_v")" ] ||
    die "EMIT DIVERGENCE: the loop counted ${NVERD[$_v]:-0} $_v row(s) but the file carries $(csvcount 2 "$_v") -- the emitted line is not what was classified"
done
unset _v

# The demotion set itself, counted and sha-pinned FROM THE FILE by the class
# strings it carries.  A count alone would survive demoting the wrong 34 rows.
if [ "$NVOR_ACCEPT_DECLINED" = 0 ]; then
  ndem=0
  for _s in "$D_GC" "$D_GC_UNIDIR" "$D_SC" "$D_UNIDIR"; do
    _k=$(csvrows | awk -F, -v s="$_s" '$0 ~ /,NO-ORACLE,/ && index($0, s)' | wc -l)
    ndem=$((ndem+_k))
    _bad=$(csvrows | awk -F, -v s="$_s" 'index($0, s) && $2!="NO-ORACLE" {print $1" carries "$2}')
    [ -z "$_bad" ] || die "CLASS/VERDICT DISAGREEMENT: $_bad"
  done
  [ "$ndem" = "$EXPECT_DEMOTED" ] ||
    die "the CSV carries $ndem demoted row(s) but the adjudication demotes exactly $EXPECT_DEMOTED"
  dsha=$(demoted_names | cut -f1 | LC_ALL=C sort | sha256sum | cut -c1-16)
  [ "$dsha" = "$EXPECT_DEMOTED_SHA" ] ||
    die "the demoted row SET has sha $dsha but the register pins $EXPECT_DEMOTED_SHA -- the gate moved a DIFFERENT $EXPECT_DEMOTED rows"
  echo "  NVOR demotion set: $ndem rows sha $dsha (per-row slots: --declined-list)" >&2
  unset _s _k _bad
fi

# Advisory (not fatal): a comma inside a free-text Source string splits it
# across CSV fields 4..n.  Fields 1-3 stay correct, but anything reading a
# single column sees a truncated Source.  Legacy strings do this and are kept
# byte-stable on purpose; every string the NVOR regeneration authored is
# comma-free BY CONSTRUCTION, and printing the count makes any growth visible.
ncomma=$(csvrows | awk -F, 'NF>4' | wc -l)
echo "note: $ncomma row(s) have a comma inside the Source string (advisory)" >&2

# The round trip runs LAST and BEFORE the mv.
if [ "$NVOR_ACCEPT_DECLINED" = 0 ]; then roundtrip
else echo "== NVOR round trip skipped: already on the NVOR_ACCEPT_DECLINED=1 branch ==" >&2; fi

mv -f "$TMPOUT" "$OUT"
trap - EXIT
echo "build-nvidia-oracle: OK" >&2
