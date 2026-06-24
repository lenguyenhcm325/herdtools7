#!/usr/bin/env bash
# Regenerate the NVIDIA GH200 het oracle  tests/het/expected-nvidia.csv  from the
# het corpus (the .litmus names produced by generate.sh).  Verdicts are DERIVED
# (hardware-free; running on a GH200 is Task 9), grounded in three primary
# sources -- see docs/het-oracle.md for the full provenance + per-shape proofs:
#   [CMCM]   Goens et al., Compound Memory Models, PLDI'23.
#   [PTX]    Lustig et al., A Formal Analysis of the NVIDIA PTX MCM, ASPLOS'19.
#   [Bagchi] Bagchi et al., Consistency & Coherence of the Grace-Hopper
#            Superchip, ISMM'26 (empirical GH200).
#
# THE DECISION PROCEDURE (extends Task 2's "CPU is never ordered" to
# "a CPU proc is ordered iff its column carries STLR/LDAPR/DMB.SY", i.e. the
# two-sided `-2s' tests):
#
#  One-sided tests (GPU annotated, CPU plain ARMv9 -- the baseline):
#    relaxed (any scope)        -> Allowed  (no synchronizing op)
#    cta scope (any order)      -> Allowed  (scope too narrow to reach the CPU)
#    gpu scope (any order)      -> Allowed  (scope excludes the CPU thread)
#    sys + acquire/release/fence-> Allowed  (one-sided: the paired CPU proc is
#                                            plain ARMv9 -> pair never completes)
#    EXCEPT IRIW-gcgc sys acquire/fence -> NO-ORACLE (both readers GPU so the
#                                            reader-order half IS present, but
#                                            IRIW needs MCA -- unestablished)
#
#  Two-sided tests (`-2s': BOTH devices annotated -- a complete pair CAN form;
#  always sys scope, order in {acqrel, fence}):
#    MP, LB, S        -> Disallowed   (2-proc; a single sys release/acquire pair
#                                      -- or DMB.SY/fence.sc.sys -- cuts the cycle;
#                                      no cross-device MCA/cumulativity needed.
#                                      MP is additionally EMPIRICALLY forbidden:
#                                      Bagchi Tab4 "no correctly synchronized
#                                      system-scope test exhibited weak behaviors")
#    SB, R            -> fence: Disallowed (DMB.SY/fence.sc.sys order store->load)
#                        acqrel: Allowed   (RCpc STLR->LDAPR and PTX rel/acq do
#                                      NOT order store->load; need an SC fence --
#                                      cf. the AMD oracle SB-sys Allowed/-F Disallowed)
#    RWC              -> fence: NO-ORACLE (store->load fenced, but RWC is a 3-proc
#                                      transitive shape -> cross-device cumulativity
#                                      unestablished)
#                        acqrel: Allowed   (its W->R proc is not fenced -> the weak
#                                      outcome survives without invoking MCA)
#    2+2W             -> NO-ORACLE   (needs a global write-write order = MCA)
#    WRC, ISA2, WRC3  -> NO-ORACLE   (transitive: need cross-device A-cumulativity
#                                      through a GPU intermediary -- unestablished)
#    IRIW             -> NO-ORACLE   (needs multi-copy atomicity)
#
# HONESTY (unchanged from Task 2): an *observed* weak outcome makes a verdict
# Allowed and is robust; a *non-observation* NEVER proves Disallowed.  Every
# Disallowed row below is a model DERIVATION, not a measurement, and carries its
# grounding in the Source column.  NO-ORACLE is a first-class verdict for the
# ARM-MCA x PTX-non-MCA frontier that Bagchi 4.2 explicitly leaves open.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh          # for SHAPE_NPROCS (2-proc vs transitive split)

MODEL="NVIDIA-PTX-AArch64"

# Source strings (kept byte-identical to the Task-2 file for the one-sided rows
# so that regeneration does not gratuitously churn the baseline verdicts).
S_RELAXED="ARMv9/PTX relaxed: no synchronizing op; weak outcome permitted [Bagchi Fig2a; PTX-relaxed; CMCM]"
S_CTA="cta scope: too narrow to encompass CPU thread; not morally strong [Bagchi r3-5; PTX 3.3; CMCM]"
S_GPU="gpu scope: excludes CPU thread; not morally strong [Bagchi Fig4e/r21-22; PTX 3.3; CMCM]"
# 2-proc one-sided sys (the one ordering-critical CPU proc of the cut is plain):
S_SYS1="sys sync one-sided: paired CPU proc is plain ARMv9 (RC); morally-strong pair incomplete [Bagchi Tab4; CMCM Fig2a; ARMv9 RC]"
# 3/4-proc one-sided sys (>=1 ordering-critical proc on a plain ARMv9 CPU):
S_SYSN="sys sync incomplete: ordering-critical proc(s) on plain ARMv9 CPU; sync chain not closed [Bagchi Tab4; ARMv9 RC; CMCM]"
S_IRIW1="IRIW forbid needs system MCA; PTX non-MCA & ARM-MCA x PTX-non-MCA interaction unestablished [Bagchi 4.2 future-work; CMCM Fig3; PTX non-MCA]"

# Two-sided Source strings.
S_MP_RA="two-sided sys release/acquire: CPU STLR + GPU acquire.sys complete the morally-strong pair; het MP empirically forbidden [Bagchi 4.2 Tab4 'no correctly synchronized system-scope test exhibited weak'; CMCM Fig2a; PTX 3.3]"
S_MP_F="two-sided sys fence: DMB.SY (CPU) + fence.sc.sys (GPU) on both procs; het MP forbidden [Bagchi 4.1 Tab3 both-sided fence + 4.2 Tab4; CMCM; PTX sc-fence]"
S_LB_RA="two-sided sys release/acquire: acquire orders load->store on BOTH devices; 2-proc LB cycle cut, no MCA needed [CMCM; PTX 3.3 RC; ARMv9 LDAPR; cf AMD LB-sys]"
S_LB_F="two-sided sys fence: DMB.SY + fence.sc.sys order load->store on both procs; 2-proc LB cycle cut [CMCM; PTX sc-fence; ARMv9; cf AMD LB-sys]"
S_S_RA="two-sided sys release/acquire: single-hop rel/acq hb + one global coherence order on the contended write; 2-proc S forbidden, no MCA needed [CMCM; Bagchi 5 CPU-GPU coherence; PTX 3.3]"
S_S_F="two-sided sys fence: DMB.SY + fence.sc.sys give the intra-proc orderings + one global coherence order; 2-proc S forbidden [CMCM; Bagchi 5 coherence; PTX sc-fence]"
S_SBR_F="two-sided sys fence: DMB.SY + fence.sc.sys order store->load on both procs; 2-proc forbidden (cf AMD SB-sys-F Disallowed) [CMCM; Bagchi 4.1 Tab3 DMB; PTX sc-fence]"
S_SBR_RA="two-sided sys release/acquire: RCpc STLR->LDAPR (and PTX rel/acq) do NOT order store->load -> pair present but insufficient (need SC fence); cf AMD SB-sys Allowed [CMCM; PTX 3.3; ARM RCpc]"
S_RWC_RA="two-sided sys release/acquire: the W->R (store->load) proc is unfenced, so the weak outcome survives without invoking MCA [CMCM; PTX 3.3; ARM RCpc; cf AMD SB-sys]"
S_2P2W="two-sided complete pair, but 2+2W needs a global write-write order (multi-copy atomicity); ARM-MCA x PTX-non-MCA unestablished [Bagchi 4.2 future-work; PTX non-MCA; CMCM Fig3]"
S_TRANS="two-sided complete pair, but this transitive shape needs cross-device A-cumulativity through a GPU intermediary; ARM-oMCA x PTX-non-MCA unestablished [Bagchi 4.2 future-work; PTX non-MCA; CMCM Fig3]"
S_IRIW2="two-sided reader ordering present, but IRIW needs multi-copy atomicity; ARM-MCA x PTX-non-MCA unestablished [Bagchi 4.2 future-work; PTX non-MCA; CMCM Fig3]"

# classify <name> -> sets globals VERDICT, SOURCE
classify() {
  local name="$1" base shape cuttag scope order two=0
  case "$name" in
    # The two hand-checked reference tests are one-sided 2-proc (CPU plain).
    MP-het|SB-het) VERDICT=Allowed; SOURCE="$S_SYS1"; return;;
  esac
  base="$name"; case "$name" in *-2s) base="${name%-2s}"; two=1;; esac
  local -a F; IFS='-' read -ra F <<< "$base"
  local n=${#F[@]}
  order="${F[n-1]}"; scope="${F[n-2]}"; cuttag="${F[n-3]}"; shape="${F[0]}"

  if [ "$two" = 0 ]; then
    if [ "$order" = relaxed ]; then VERDICT=Allowed; SOURCE="$S_RELAXED"; return; fi
    case "$scope" in
      cta) VERDICT=Allowed; SOURCE="$S_CTA"; return;;
      gpu) VERDICT=Allowed; SOURCE="$S_GPU"; return;;
    esac
    # sys + acquire/release/fence
    if [ "$shape" = IRIW ] && [ "$cuttag" = gcgc ] \
       && { [ "$order" = acquire ] || [ "$order" = fence ]; }; then
      VERDICT=NO-ORACLE; SOURCE="$S_IRIW1"; return
    fi
    # 2-proc cut -> one critical CPU proc (S_SYS1); 3/4-proc -> chain (S_SYSN).
    VERDICT=Allowed
    if [ "${SHAPE_NPROCS[$shape]}" = 2 ]; then SOURCE="$S_SYS1"; else SOURCE="$S_SYSN"; fi
    return
  fi

  # two-sided (scope is always sys; order in {acqrel,fence})
  case "$shape" in
    MP)  if [ "$order" = fence ]; then VERDICT=Disallowed; SOURCE="$S_MP_F"
         else VERDICT=Disallowed; SOURCE="$S_MP_RA"; fi;;
    LB)  if [ "$order" = fence ]; then VERDICT=Disallowed; SOURCE="$S_LB_F"
         else VERDICT=Disallowed; SOURCE="$S_LB_RA"; fi;;
    S)   if [ "$order" = fence ]; then VERDICT=Disallowed; SOURCE="$S_S_F"
         else VERDICT=Disallowed; SOURCE="$S_S_RA"; fi;;
    SB|R) if [ "$order" = fence ]; then VERDICT=Disallowed; SOURCE="$S_SBR_F"
         else VERDICT=Allowed; SOURCE="$S_SBR_RA"; fi;;
    RWC) if [ "$order" = fence ]; then VERDICT=NO-ORACLE; SOURCE="$S_TRANS"
         else VERDICT=Allowed; SOURCE="$S_RWC_RA"; fi;;
    2+2W) VERDICT=NO-ORACLE; SOURCE="$S_2P2W";;
    WRC|ISA2|WRC3) VERDICT=NO-ORACLE; SOURCE="$S_TRANS";;
    IRIW) VERDICT=NO-ORACLE; SOURCE="$S_IRIW2";;
    *) echo "build-nvidia-oracle: unhandled two-sided shape '$shape' ($name)" >&2; exit 1;;
  esac
}

OUT=expected-nvidia.csv
{
  echo "Litmus,Expected,Model,Source"
  echo "# NVIDIA GH200 het oracle (ARMv9 Grace + Hopper PTX = $MODEL).  Verdicts"
  echo "# are DERIVED, grounded in [CMCM] PLDI'23, [PTX] Lustig ASPLOS'19, and"
  echo "# [Bagchi] ISMM'26.  Generated by build-nvidia-oracle.sh; see"
  echo "# docs/het-oracle.md for the full decision procedure + per-shape proofs."
  echo "# Tally is printed to stderr at generation time."
  for f in $(ls *.litmus | LC_ALL=C sort); do
    name="${f%.litmus}"
    classify "$name"
    echo "$name,$VERDICT,$MODEL,$SOURCE"
  done
} > "$OUT"

# Tally + invariants to stderr.
ndata=$(grep -vE '^#|^Litmus,' "$OUT" | wc -l)
nlit=$(ls *.litmus | wc -l)
echo "wrote $OUT: $ndata rows for $nlit .litmus files" >&2
grep -vE '^#|^Litmus,' "$OUT" | cut -d, -f2 | sort | uniq -c >&2
if [ "$ndata" -ne "$nlit" ]; then echo "ERROR: row count != .litmus count" >&2; exit 1; fi
