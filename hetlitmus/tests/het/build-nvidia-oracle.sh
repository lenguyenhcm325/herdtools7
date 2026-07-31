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
#  Two-sided FENCE-PAIR tests (`-2s' with order `<cpu>.<gpu>', Q10 steps 1-4):
#  the 3 x 3 grid  CPU {DMB.SY, DMB.ST, DMB.LD} x GPU {fence.sc.sys,
#  fence.release.sys, fence.acquire.sys} on the six 2-proc shapes, minus the
#  (DMB.SY, fence.sc.sys) cell which IS the pre-existing `-fence-2s' row.
#  These are NOT hand verdicts: two_sided_fence_pair() below is a COMPOSITIONAL
#  rule over two per-primitive facts, and hetlitmus/verify/ordercheck.py proves
#  the rule is the same function herd7 computes -- 54 CPU-only cells under the
#  native AArch64 model and 54 GPU-only cells under nvidia-ptx.cat -- and that
#  it reproduces the pre-existing `-fence-2s' rows as the (DMB.SY, sc) cell.
#
#    ord(p)  = the program-order pairs {WW,RR,WR,RW} p orders inside its thread
#              DMB.SY {WW RR WR RW}  DMB.ST {WW}      DMB.LD {RR RW}
#              sc     {WW RR WR RW}  release {WW RW}  acquire {RR RW}
#              (ARM row = herd7's own answer; GPU row = [CMCM] 5 verbatim:
#               "a request that is marked with sem >= rel enforces R + pred -> W
#               and W -> W.  A request with sem >= acq enforces R -> R and
#               R -> W and an sc fence additionally enforces W -> R.")
#    role(p) = which half of a morally-strong pair p can supply
#              DMB.SY/sc {rel acq sc}   DMB.ST/release {rel}   DMB.LD/acquire {acq}
#
#    Disallowed  ord(cpu) covers the CPU proc's pair AND ord(gpu) covers the GPU
#                proc's pair AND the [PTX] pattern completes (rf-source proc
#                supplies `rel' and rf-target proc `acq'; or -- for a cycle with
#                NO rf at all: SB R 2+2W -- BOTH supply `sc'  [PTX Fig 6])
#    NO-ORACLE   both sides order their own pair but the PTX pattern does not
#                complete.  [CMCM] ships TWO compound models and says which way
#                they differ, verbatim (5.1): "There are two ways in which our
#                operational model is stronger than the axiomatic PTX model:
#                (1) Write serialization is enforced within the causality
#                constraints by our operational model, but not by the axiomatic
#                PTX model.  (2) Release and acquire fences are slightly
#                stronger in cumulative chains of events ... events can be
#                transitively ordered using either release or acquire fences,
#                though the axiomatic PTX model would only order if the fence
#                is at least acqrel." (Fig 11: 2+2W and ISA2 are the
#                witnesses.)  Every cell here is an instance of (1) or (2): the
#                operational model forbids, the axiomatic CMM (6.2, whose PTX
#                component IS [PTX] Fig4/Fig7) permits, and CMCM does not say
#                which the hardware follows.  Characterization only.
#    Allowed     one side's own ISA leaves its own program-order pair unordered
#
#  The cross-device step (a CPU DMB and a sys-scope GPU fence ARE morally strong
#  and therefore compose) is the part no solver decides: [CMCM] 3.2.3/4.4 treat
#  every unscoped request as system-scoped; [Bagchi] 3.2/4.2 state the same rule
#  for ARM+PTX on GH200; [PTX] Table 1 has `.sys' include "all threads
#  constituting the host program itself".
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

# ---------------------------------------------------------------------------
# Q10: the two-sided FENCE-PAIR grid  <cpu>.<gpu>.  Compositional -- see the
# header block and hetlitmus/verify/ordercheck.py (which machine-checks every
# clause below against herd7's AArch64 model and nvidia-ptx.cat).
# NB: Source strings must contain NO comma (this file is a CSV), so the
# primitives are named by their real mnemonics: `DMB SY' / `fence.acquire.sys'.
# ---------------------------------------------------------------------------

# prim_ord <tok> -> the program-order pairs the primitive orders (fail closed)
prim_ord() {
  case "$1" in
    sy|sc)  echo "WW RR WR RW";;
    st)     echo "WW";;
    ld|acq) echo "RR RW";;
    rel)    echo "WW RW";;
    *) echo "build-nvidia-oracle: unknown fence-pair primitive '$1'" >&2; exit 1;;
  esac
}
# prim_role <tok> -> which half of a morally-strong pair it can supply
prim_role() {
  case "$1" in
    sy|sc)  echo "rel acq sc";;
    st|rel) echo "rel";;
    ld|acq) echo "acq";;
    *) echo "build-nvidia-oracle: unknown fence-pair primitive '$1'" >&2; exit 1;;
  esac
}
prim_name() {   # human name for the Source string (no commas)
  case "$1" in
    sy) echo "DMB SY";; st) echo "DMB ST";; ld) echo "DMB LD";;
    sc) echo "fence.sc.sys";; rel) echo "fence.release.sys";;
    acq) echo "fence.acquire.sys";;
  esac
}
has_tok() { local n="$1"; shift; case " $* " in (*" $n "*) return 0;; (*) return 1;; esac; }

# two_sided_fence_pair <shape> <cuttag> <cpu-tok> <gpu-tok> -> VERDICT, SOURCE
two_sided_fence_pair() {
  local shape="$1" tag="$2" c="$3" g="$4"
  local -a CY; read -ra CY <<< "${SHAPE_CYCLE[$shape]}"
  local p0="${CY[0]#Pod}" p1="${CY[2]#Pod}"
  local d0="${tag:0:1}" pc pg r0 r1 pair_c pair_g
  if [ "$d0" = c ]; then pc="$p0"; pg="$p1"; else pc="$p1"; pg="$p0"; fi
  local nc ng; nc=$(prim_name "$c"); ng=$(prim_name "$g")

  # (1) each thread's OWN model must order its OWN program-order pair
  if ! has_tok "$pc" $(prim_ord "$c"); then
    VERDICT=Allowed
    SOURCE="two-sided sys fence pair ($nc | $ng): the CPU thread's own ISA leaves its $pc program-order pair unordered so no reading of the compound model cuts the cycle [machine-checked herd7 AArch64 via verify/ordercheck.py; CMCM 4.3 fence orderings]"
    return
  fi
  if ! has_tok "$pg" $(prim_ord "$g"); then
    VERDICT=Allowed
    SOURCE="two-sided sys fence pair ($nc | $ng): the GPU thread's own model leaves its $pg program-order pair unordered so no reading of the compound model cuts the cycle [machine-checked nvidia-ptx.cat via verify/ordercheck.py; CMCM 5 PTX sem>=rel/acq]"
    return
  fi

  # (2) the [PTX] Fig4/Fig6 pattern requirement on top of per-side ordering
  if [ "$d0" = c ]; then r0=$(prim_role "$c"); r1=$(prim_role "$g")
  else                  r0=$(prim_role "$g"); r1=$(prim_role "$c"); fi
  local sync=0 why=""
  if [ "${CY[1]}" = Rfe ] && has_tok rel $r0 && has_tok acq $r1; then
    sync=1; why="P0 releases and P1 acquires across the rf"
  fi
  if [ "${CY[3]}" = Rfe ] && has_tok rel $r1 && has_tok acq $r0; then
    sync=1; why="P1 releases and P0 acquires across the rf"
  fi
  if [ "${CY[1]}" != Rfe ] && [ "${CY[3]}" != Rfe ]; then
    if has_tok sc $r0 && has_tok sc $r1; then
      sync=1; why="the cycle carries no rf so both threads supply an SC fence"
    fi
  fi

  if [ "$sync" = 1 ]; then
    VERDICT=Disallowed
    SOURCE="two-sided sys fence pair ($nc | $ng): CPU orders its $pc pair and GPU orders its $pg pair and $why; unscoped ARM ops are system-scoped so the pair is morally strong; 2-proc cycle cut with no MCA needed [CMCM 3.2.3+4.4+4.6; Bagchi 3.2+4.2; PTX 3.3+Fig4+Fig6; machine-checked verify/ordercheck.py]"
  else
    VERDICT=NO-ORACLE
    SOURCE="two-sided sys fence pair ($nc | $ng): both threads order their own pair so CMCM's OPERATIONAL model forbids -- but its own AXIOMATIC compound model CMM (a sound abstraction; PTX component = Lustig Fig4/Fig7) permits it. CMCM 5.1 names exactly this gap: 'There are two ways in which our operational model is stronger than the axiomatic PTX model: (1) Write serialization ... (2) Release and acquire fences are slightly stronger in cumulative chains ... events can be transitively ordered using either release or acquire fences though the axiomatic PTX model would only order if the fence is at least acqrel' (Fig 11 witnesses: 2+2W and ISA2). Characterization not a falsification claim [CMCM 5.1+Fig11+6.2; PTX Fig4/Fig7; machine-checked nvidia-ptx.cat via verify/ordercheck.py]"
  fi
}

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

  # two-sided.  First the Q10 fence-pair grid `<cpu>.<gpu>' (2-proc shapes
  # only; anything else is a generation bug -> fail closed).
  case "$order" in
    *.*)
      case "$shape" in
        MP|SB|LB|R|S)
          two_sided_fence_pair "$shape" "$cuttag" "${order%%.*}" "${order##*.}"
          return;;
        *) echo "build-nvidia-oracle: fence-pair order '$order' on unsupported shape '$shape' ($name)" >&2; exit 1;;
      esac;;
  esac

  # then the original {acqrel,fence} pairings (scope is always sys)
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
# Column sanity.  Consumers read field 2 as the verdict and field 3 as the model
# (controlmap.py load_oracle, campaign.py, oracle-compare.sh); a malformed row
# there is silent corruption, so it is fatal.
badcols=$(grep -vE '^#|^Litmus,' "$OUT" \
  | awk -F, -v m="$MODEL" 'NF<4 || ($2!="Allowed" && $2!="Disallowed" && $2!="NO-ORACLE") || $3!=m {print NR": "$0}')
if [ -n "$badcols" ]; then
  echo "ERROR: malformed row(s) -- field 2 must be a verdict and field 3 the model:" >&2
  printf '%s\n' "$badcols" >&2; exit 1
fi
# ADVISORY: a comma inside a free-text Source string splits it across CSV fields
# 4..n.  Harmless for fields 1-3 (hence not fatal) but it truncates the Source
# for anything that reads a single column.  41 of the Task-2/3 baseline strings
# already do this and are kept byte-stable on purpose; the Q10 fence-pair
# strings are comma-free and this line makes any growth visible.
ncomma=$(grep -vE '^#|^Litmus,' "$OUT" | awk -F, 'NF>4' | wc -l)
echo "note: $ncomma row(s) have a comma inside the Source string (advisory)" >&2
