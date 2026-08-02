#!/usr/bin/env bash
# Regenerate the AMD MI300A het oracle  tests/het/expected-amd.csv  from the het
# corpus (the .litmus NAMES produced by generate.sh).  Verdicts are DERIVED, not
# measured -- there is no AMD GPU on this box and none of the numbers below is a
# hardware observation.  The specification this file transcribes is
#
#   env-research/PORT2-R2-amd-oracle.md          (the oracle memo; sect 9 is the contract)
#   env-research/PORT2-P2-0-addendum.md          (BINDING; supersedes the memo where they differ)
#   env-research/r2-grounding/{G1..G5,R4..R7,D22}   (the grounding memos)
#
# Sources, by the memo's tags:
#   [ART]    PLDI23_Compound_Simulation expected.csv + the .cpp bodies (the 34 anchors)
#   [CMCM]   Goens Chakraborty Sarkar Agarwal Oswald Nagarajan, Compound Memory
#            Models, PACMPL 7(PLDI) art. 153, 2023
#   [x86tso] herd/libdir/x86tso.cat + herd7
#   [APM]    AMD64 APM Vol. 2 pub. 24593 Rev. 3.45 July 2026 (sect 7.2, Table 7-4 p.202)
#   [LLVM]   LLVM AMDGPUUsage "AMDHSA Memory Model" @ 8212d301fd86 -- the target-generic
#            Single Thread Optimization Constraints table (L7454-7484) and the GFX942
#            per-target code-sequence table (L11238-13457).  THE `ord' SHAPE IS KEYED
#            HERE (memo 7.D18 resolved by P2-0 item R-5).
#   [ISA]    AMD CDNA3 ISA Reference sect 9.1.10.2 Tables 48/49
#   [HSA]    HSA PRM 1.2 sect 6.2.1 + Alglave & Maranget HSA-in-cat
#   [SCATOM] Batty Donaldson Wickerson, Overhauling SC Atomics, POPL'16
#   [gcn3]   hetlitmus/cats/amd-gcn3.cat -- anchor cross-check and one-way
#            falsifier ONLY.  NEVER a Key-2 and NEVER a CDNA3 model (memo 2.1).
#
# THE RULE (memo sect 3.3), in three steps, run per test:
#   STEP 1  per-side preserved program order.  A thread that may reorder its own
#           program-order pair reaches the weak outcome unaided  ->  Allowed.
#   STEP 2  thin air.  Every external edge `rf' and every thread preserving R->W
#           ->  Disallowed by (CMM-No-Thin-Air) alone.  Only LB qualifies.
#   STEP 3  every external edge must be global: morally strong endpoints (`ms'),
#           an A-cumulative source (`cum'), a non-stale sink (`fresh'), and for a
#           `co' edge out of a proc with a po-earlier write, global write
#           serialisation (`ws').  `ws' is FALSE on the GPU side -> NO-ORACLE.
#
# THE TWO-KEY RULE, as amended 2026-08-02 and confirmed by Nguyen (memo 2.0):
#   two independent keys -> FULL-STRENGTH Disallowed; a single-key derivation MAY
#   be Disallowed but MUST carry declared single-chain provenance (`derived' or
#   `decision'), and that declaration CAPS the reported claim strength -- a
#   mismatch on such a row indicts THIS ORACLE ROW first, never the CMCM.  Doubt
#   about the derivation itself still resolves to Allowed.  32 of the 146
#   Disallowed rows report at full strength; 114 report capped (memo 5.4.1 as
#   amended by decision D24 -- see the grade-3 vacuity guard below; the memo's
#   own 41/105 counted 9 rows full-strength on a VACUOUS anchor test).
#   The rejected alternative (demote the 110 declared single-chain rows, census
#   258/146/7 -> 359/45/7) is NOT implemented and must not be: there is no
#   D23_CONFIRMED switch here, by instruction (memo 7.D23).
#
# An observed weak outcome makes a verdict Allowed and is robust; a
# NON-OBSERVATION NEVER PROVES Disallowed.  oracle-compare.sh:118-120's honesty
# clause -- a Disallowed test seen as Never is MATCH with note "forbidden not
# seen", never a confirmation -- is carried unchanged.
#
# Usage:  build-amd-oracle.sh              gates G1 G15 G13 G14 G0 then write the CSV
#         build-amd-oracle.sh --anchors    the anchor gate alone (memo 9.4 G1)
#         build-amd-oracle.sh --swmr-list  the 65-row sect 8 P2 contingency list
#         build-amd-oracle.sh --g15        the !SWMR hook split alone (G15)
#         build-amd-oracle.sh --cells      memo 5.4.1 re-derived by ablation
# Any other argument is REFUSED (fail-closed on an unrecognised mode).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh          # SHAPE_CYCLE, SHAPE_NPROCS

MODEL="AMD-CDNA3-x86"
OUT=expected-amd.csv

# The instantiation guard on clause (ii) of the !SWMR hook (memo 7.D20 as
# resolved by P2-0 item R-7; addendum sect 7 item 4).  `M = GCN3-VIPER' keeps the
# NARROW hook -- clause (i) alone, which is the calibration to the artifact's one
# observed flip -- and `M = CDNA3' gets the WIDE hook.  Named rather than
# inlined so gate G15 can drop it and MEASURE the cost (33/34 on no-SWMR
# IRIW1-sys).  Never set this anywhere but in G15's own bite.
HOOK_II_GUARD_MODEL="${HOOK_II_GUARD_MODEL:-CDNA3}"

# ===========================================================================
# TABLES.  Four of them carry data and nothing else does (memo 9.3).
# ===========================================================================

# --- SHAPE_ROT (memo 3.0) ---------------------------------------------------
# SHAPE_CYCLE is written starting at an arbitrary cycle position; diy renumbers
# procs.  The rotation that maps cycle position to litmus proc index was FITTED
# by parsing all 411 .litmus files and comparing per-proc direction strings, and
# gate G0 below re-checks it against every file on every run -- it is an
# assertion, not a comment.  It yields e.g. IRIW proc order [RR W RR W], so
# IRIW-cgcg is CPU readers + GPU writers = the artifact's IRIW1.
declare -A SHAPE_ROT=(
  [MP]=0 [SB]=0 [LB]=0 [2+2W]=0 [R]=0 [S]=0
  [WRC]=1 [RWC]=1 [ISA2]=0 [IRIW]=1 [WRC3]=1
)

# --- PRIM_CPU (memo 3.1): 3 rows, 2 REACHABLE -------------------------------
# ord_x86(v,X,Y) = not(X=W and Y=R) or v in {MFENCE,LOCK}.  [CMCM] 5 p153:14:
# "Reads writes and fences have no variants with different strengths ... we
# always order r -> r' in a thread unless r is a write and r' a read.  Fences
# additionally enforce W -> R."  [APM] Table 7-4 p.202 cell e(mf) names MFENCE
# -- NOT SFENCE -- for the store->load cell on WB memory.
# The TSO collapse (memo 3.1, G2 B.2, both sides machine-measured): the corpus
# CPU tokens `ra' (STLR/LDAPR), `st' (DMB ST) and `ld' (DMB LD) all render as a
# bare MOV on x86, so the CPU axis is 4 -> 2.  `lock' is architecturally real
# ([APM] 7.5.1 "Locked writes are never buffered") and machine-checked, but it
# is UNREACHABLE from this corpus (memo 7.D6: no test emits an RMW on the race
# path) -- G14 asserts that, and no gate may claim to check this row.
#   fields:  ord | role | mnemonic | reachable
declare -A PRIM_CPU=(
  [plain]="WW RR RW|rel acq|MOV|yes"
  [mfence]="WW RR WR RW|rel acq sc|MFENCE|yes"
  [lock]="WW RR WR RW|rel acq sc|LOCK-prefixed RMW or XCHG|no"
)

# --- PRIM_GPU (memo 3.2.1, M = CDNA3): 7 rows, 6 REACHABLE ------------------
# RE-KEYED 2026-08-02 (P2-0 item R-5, memo 7.D18 RESOLVED): the shape of this
# table is derived from [LLVM] AMDGPUUsage @ 8212d301fd86 at two layers -- the
# target-generic Single Thread Optimization Constraints table (L7454-7484) and
# the GFX942 per-target "must happen after / must happen before" bullets
# (L11238-13457).  Every cell AND every deliberate omission is independently
# licensed, cell-for-cell exact (env-research/r2-grounding/R5-ord-rekey.md sect 4).
# Two cells are deliberately absent and each is a registered decision:
#   * `relaxed' contributes no R->W          -- memo 7.D4 (monotonic -> none, L7462)
#   * release/acquire contribute no W->R     -- memo 7.D1 ("there is nothing
#     preventing a store release followed by load acquire from completing out of
#     order", GFX942 table L13419)
#   * f[release]/f[acquire] contribute no W->R -- memo 7.D16, kept empty as the
#     fail-safe reading AND as what C5/C6's fence-paired-atomic bullets state.
#     Restoring it would flip 5 rows Allowed -> Disallowed; declined.
# `w[sc,S]'/`r[sc,S]' has ZERO occurrences in all 411 tests: the corpus realises
# the `sc' column as a standalone f[sc,S] fence.  Retained for completeness;
# G14 asserts the occurrence count is 0 and G4 must not claim to check it.
#   fields:  ord | role | notation | reachable
declare -A PRIM_GPU=(
  [acc-relaxed]="-|-|w/r[relaxed;S]|yes"
  [acc-release]="WW RW|rel|w[release;S]|yes"
  [acc-acquire]="RR RW|acq|r[acquire;S]|yes"
  [acc-sc]="WW RR WR RW|rel acq sc|w/r[sc;S]|no"
  [fence-release]="WW RW|rel|f[release;S]|yes"
  [fence-acquire]="RR RW|acq|f[acquire;S]|yes"
  [fence-sc]="WW RR WR RW|rel acq sc|f[sc;S]|yes"
)

# --- the two hand-written reference tests -----------------------------------
# MP-het and SB-het are NOT grid members: they are hand-written and their GPU
# annotation profile is asymmetric (MP-het acquires only the consumer's FIRST
# load, mirroring the artifact's MP2-sys-F), so no grid token names them.  What
# is tabulated here is their PROGRAM, transcribed from generate.sh's own hetgen7
# arguments (tests/het/generate.sh (A), the `-cpu'/`-gpu' edge lists); the
# VERDICT is derived by the same classify_amd as every other row.  G0 proves the
# transcription against the .litmus files on every run.  The NVIDIA generator
# hard-coded these two rows to (Allowed, S_SYS1) on an ARMv9-RC premise; that
# hard-coding is NOT carried (memo 5.6 (A), G4 sect E.3).
declare -A REF_SHAPE=( [MP-het]=MP [SB-het]=SB )
declare -A REF_CUT=(   [MP-het]=cg [SB-het]=cg )
declare -A REF_PROG=(  # per proc, `;'-separated; events `DIR:annot:scope'
  [MP-het]="W:x86:- W:x86:-;R:acquire:sys R:relaxed:sys"
  [SB-het]="W:x86:- R:x86:-;W:release:sys R:acquire:sys"
)

# --- the S_* justification strings (memo 5.2) -------------------------------
# NORMATIVE TEXT.  Byte-stable once landed (G4 sect D).  Re-keyed at authoring
# time per R5-ord-rekey.md sect 6 (addendum sect 7 item 7): the `[CMCM] 5
# p153:14 ord-table' citations are replaced by the [LLVM] AMDGPUUsage clauses
# that now carry the shape; the [CMCM] 6.2 X1/X2a citations -- which are the
# COUPLING, not the `ord' -- stay untouched.
# EVERY ONE OF THESE IS COMMA-FREE AND THE GUARD ON IT IS FATAL (memo 9.2): a
# comma would split the free-text field across CSV fields 5..n.  The NVIDIA
# generator degrades the same check to advisory because 38 legacy strings
# already contain commas; a new file has no such legacy.
declare -A SRC=(
[S_RELAXED]="relaxed: the GPU proc carries no synchronising op so CDNA3 leaves its own program-order pair unordered [LLVM AMDGPUUsage single-thread optimization constraints monotonic=none L7462; GFX942 load/store atomic monotonic system L11324/L11332; g3probe2-gfx942.s lb_relaxed; cf artifact Compound MP1-sys + MP2-sys Allowed]"
[S_SCOPE]="scope too narrow: the GPU annotation is cta- or gpu-scoped so it neither orders the proc toward its cycle neighbour nor is morally strong with the unscoped x86 thread [CMCM 6.2 p153:18 morally-strong; CMCM Fig10 p153:15 worked compound WRC -- a genuine scope-ANNOTATION example; CMCM 7.2 p153:21 'when the scopes of the operations are not morally strong then the litmus tests are allowed -- for example when the MP litmus test is run with a CTA-scoped fence on two different CTAs'; the artifact cta rows are protocol-configured not annotated so they are NOT cited here -- see decision D15]"
[S_ROLE]="wrong role for this pair: a GPU synchronising primitive is present but a release orders only {WW RW} and an acquire only {RR RW} so this proc's own pair stays unordered at EVERY scope -- which is why the row is classed by ROLE and not by SCOPE even where the annotation is cta- or gpu-scoped [LLVM AMDGPUUsage optimization-constraints acquire L7463-7467 / release L7468-7473; GFX942 rows L11454 L12058 L11880 L12386]"
[S_PPO_C]="x86 store buffer: the CPU proc's W->R pair is the one reordering x86-TSO permits and no MFENCE separates it [CMCM 5 p153:14 'unless r is a write and r-prime a read'; APM 7.2 'Non-overlapping Loads may pass stores'; DECIDED IN THE SOUND DIRECTION by herd7 -cat x86tso.cat: the all-x86 rendering of every one of these 46 rows is Sometimes; artifact Compound SB-sys Allowed and SB-sys-HF Allowed]"
[S_RF_NOCUM]="no A-cumulativity: the rf source is a relaxed GPU store so what its thread previously read or wrote is not pushed with it [LLVM AMDGPUUsage optimization-constraints monotonic=none L7462; GFX942 store atomic monotonic emits no buffer_wbl2 L11332]"
[S_NTA]="thin air: every external edge of this cycle is rf and both threads preserve R->W so the cycle is cut with no synchronisation no scope and no coherence assumption [CMCM p153:19 CMM-No-Thin-Air acyclic(rf u dep u ppo) -- and that ppo is x86TSO's: Fig12 p153:17 defines ppo = (WW u RW u RR) n po in the x86TSO column ONLY and p153:19 states 'we augment the PTX (No-Thin-Air) axiom with ppo ordering in x86TSO' so the axiom carries the CPU half of the cut and NOT the GPU half; LLVM AMDGPUUsage optimization-constraints acquire L7463-7467; GFX942 rows L11454 L11880 carry the GPU-side R->W]. The GPU half rests on the recorded gfx942 emission and on the ISSUE-TIME contradiction an LB cycle is -- the load returned a value its own thread had not yet stored -- which needs neither cumulativity nor multi-copy atomicity. KEY-2 for the GPU-side R->W is per-row: 9 rows by the recorded gfx942 emission (g3probe2 lb_acq_sys for acc-acquire@RW; g3probe4 f_acq_rw for fence-acquire@RW) and 10 rows have NO second key and ship as DECLARED SINGLE-CHAIN rows under the amended two-key rule of 2.0 (see 5.4.1). The artifact LB-sys anchor is NOT a key here -- decision D4 shows it is a different program. The herd7 x86tso LB Never result decides the CPU half ONLY and does not discriminate these rows from LB-cg-sys-relaxed which is Allowed"
[S_CUT]="cycle cut: every thread preserves its own program-order pair and every communication edge is global -- morally-strong sys-scope endpoints an A-cumulative source and a non-stale sink [CMCM 6.2 p153:18 x86 write/read are at least a sys-scoped release/acquire + rfe-g-x as strong as x86TSO rfe; LLVM AMDGPUUsage optimization-constraints acquire L7463-7467 / release L7468-7473; GFX942 buffer_wbl2/buffer_inv rows L11454 L12058 L11880 L12386]. DISCLOSED for the co-edge sub-case (19 S-cg-sys-* rows close through a co edge from a GPU write to an x86 write on the SAME location): 'global' there means a SHARED PER-LOCATION coherence order exists between the CDNA3 XCDs and the Zen-4 CCDs and respects hb. That is precondition P2 of memo 8 (SWMR on the race path) and it is strictly WEAKER than the cross-location propagation order memo 6 declines to assume for 2+2W -- which is why those rows are Disallowed and the 2+2W rows are NO-ORACLE. Surviving artifact anchors are MP1-sys-F and MP2-sys-F and IRIW1-sys and IRIW2-sys-F and they cover exactly two GPU mechanism cells (sys release on a W;W proc and sys acquire on an R;R proc); SB-sys-F is REVOKED by decision D1 and LB-sys by D4 so neither is cited; sc-fence and standalone-fence and every @RW cell have NO artifact anchor and NO second key and ship as DECLARED SINGLE-CHAIN rows under the amended two-key rule of 2.0 -- see 5.4.1"
[S_CUT_MCA]="cycle cut through a GPU observer that must agree with a second observer on the order of two x86 writes: this is decision D2 and the MCA step is a DECISION not a derivation. Key-1 is CMCM 6.2 p153:18 X2a plus LLVM AMDGPUUsage: a system-scope acquire emits s_waitcnt vmcnt(0); buffer_inv sc0 sc1 which invalidates the reader private copy. Key-2 is the artifact anchor IRIW2-sys-F for the 4 acquire-ANNOTATION rows (its cell acc-acquire@RR is anchored and survives removal of GCN3-a/GCN3-b) while the 4 sc-FENCE rows have no artifact anchor of any kind and no second key and ship as DECLARED SINGLE-CHAIN decision rows under the amended two-key rule of 2.0 (see 5.4.1). Departs from G3 recommendation Allowed-unless-probed; confirm before first campaign"
[S_WS_FENCE]="write serialisation unresolved (fence sub-shape): this cycle is closed only by a co edge out of a GPU proc whose two writes are RELAXED and separated by a standalone fence so it needs the GPU W;W program order to be global propagation order. CMCM 5.1(1) names exactly this as where its operational and its axiomatic model part company -- 'Write serialization is enforced within the causality constraints by our operational model but not by the axiomatic PTX model' -- with 2+2W as its own Fig11a witness; and no admitted AMD VENDOR source (HSA PRM 6.2.1 LLVM AMDGPUUsage CDNA3 ISA) states it for relaxed accesses separated by a fence. The recorded gfx942 emission for this exact body (g3probe3.hip kernels ws_2p2w_fsc/ws_rgc_fsc: two global_store separated by buffer_wbl2 sc0 sc1 then s_waitcnt vmcnt(0)) settles ord-visibility and NOT co-placement -- turning visible-at-system-scope into a shared per-location coherence order needs system-scope multi-copy atomicity of the compound machine which no admitted source states for CDNA3. DISCLOSED: the non-vendor axiom SCATOM Def 27 p644 as transcribed into amd-gcn3.cat axiom (4) DOES forbid 2+2W-sys-fence; it is not cited as a key because gcn3 is never a Key-2 (2.1) and Def 27 is a proposed SC axiom for OpenCL C11 rather than a CDNA3 model [CMCM 5.1+Fig11 p153:15-16; HSA PRM 6.2.1; LLVM seq_cst total orderings; decision D7 and D21]"
[S_WS_REL]="write serialisation unresolved (release sub-shape): both GPU writes are w[release;sys] (comma-free event notation for CSV) and no fence is present. The admitted instrument amd-gcn3.cat DOES decide this sub-shape -- measured Never for 2+2W-sys-release -- but it decides it through axiom (3) sys-strong which is precisely the axiom decision D1 revokes for CDNA3. So the silence here is a CONSEQUENCE OF D1 not an absence of sources; ord-visibility and co-placement are distinct axioms (the axiomatic PTX model is the existence proof) so a local writeback-and-wait does not by itself constrain a per-location coherence order [CMCM 5.1+Fig11 p153:15-16; amd-gcn3.cat axiom 3; decision D1 and D21]"
)

# ===========================================================================
# FAIL-CLOSED ACCESSORS.
# The NVIDIA generator's lesson, carried verbatim (build-nvidia-oracle.sh:124-134):
# as first written its guard ran inside $(...), so `exit 1' killed only the
# subshell and the script "printed unknown fence-pair primitive 'ra' three times
# and emitted a complete CSV anyway".  NEVER VALIDATE INSIDE A COMMAND
# SUBSTITUTION.  These set globals and are called as plain statements.
# ===========================================================================
die() { echo "build-amd-oracle: $*" >&2; exit 1; }

prim_cpu() {                       # prim_cpu <plain|mfence|lock>
  local e="${PRIM_CPU[$1]:-}"
  [ -n "$e" ] || die "unknown CPU primitive '$1'"
  PC_ORD="${e%%|*}"; e="${e#*|}"; PC_ROLE="${e%%|*}"; e="${e#*|}"
  PC_NAME="${e%%|*}"; PC_REACH="${e##*|}"
}
prim_gpu() {                       # prim_gpu <acc-*|fence-*>
  local e="${PRIM_GPU[$1]:-}"
  [ -n "$e" ] || die "unknown GPU primitive '$1'"
  PG_ORD="${e%%|*}"; e="${e#*|}"; PG_ROLE="${e%%|*}"; e="${e#*|}"
  PG_NAME="${e%%|*}"; PG_REACH="${e##*|}"
}
src_of() {                         # src_of <S_*>
  local s="${SRC[$1]:-}"
  [ -n "$s" ] || die "unknown justification class '$1'"
  SOURCE="$s"
}
rank_of() {                        # rank_of <cta|gpu|sys>
  case "$1" in
    cta) RANK=0;; gpu) RANK=1;; sys) RANK=2;;
    cluster) die "cluster scope is REJECTED for AMD (decision D8): LLVM degrades syncscope(cluster) to agent HIP has no __HIP_MEMORY_SCOPE_CLUSTER and CDNA3 SC[1:0] has no cluster level -- refusing to emit a degraded (agent) row";;
    *) die "unknown scope '$1'";;
  esac
}
has_tok() { local n="$1"; shift; case " $* " in (*" $n "*) return 0;; (*) return 1;; esac; }

# role_of <acc|fence> <annot> -> ROLE ("" for a relaxed access).  This is what
# keeps the `role' column of PRIM_GPU LOAD-BEARING instead of documentation:
# memo 3.2.1's role column IS "which half of a morally-strong pair the event
# supplies", so `cum' asks it for `rel' and `fresh' asks it for `acq' rather
# than re-listing the annotations.  Fails closed on a token PRIM_GPU lacks.
role_of() {
  if [ "$2" = relaxed ]; then ROLE=""; return; fi
  prim_gpu "$1-$2"; ROLE="$PG_ROLE"
}

# ===========================================================================
# CYCLE STRUCTURE  (memo 3.0).  cycle <shape> sets
#   CY_N        number of procs
#   CY_DIRS[i]  that proc's program-order direction string ("WW" "RR" "W" ...)
#   CY_EDGES[]  "kind srcproc srcidx dstproc dstidx" per external edge
# ===========================================================================
cycle() {
  local shape="$1"
  local spec="${SHAPE_CYCLE[$shape]:-}"
  [ -n "$spec" ] || die "unknown shape '$shape'"
  local rot="${SHAPE_ROT[$shape]:-}"
  [ -n "$rot" ] || die "no SHAPE_ROT entry for shape '$shape'"
  local -a base; read -ra base <<< "$spec"
  local k=${#base[@]} i j
  local -a KIND=() SRC_D=() DST_D=()
  for ((i=0; i<k; i++)); do
    local e="${base[(rot+i)%k]}"
    case "$e" in
      Pod??) KIND[i]=po;  SRC_D[i]="${e:3:1}"; DST_D[i]="${e:4:1}";;
      Rfe)   KIND[i]=rf;  SRC_D[i]=W; DST_D[i]=R;;
      Fre)   KIND[i]=fr;  SRC_D[i]=R; DST_D[i]=W;;
      Coe)   KIND[i]=co;  SRC_D[i]=W; DST_D[i]=W;;
      *) die "unknown base edge '$e' in shape '$shape'";;
    esac
  done
  # group events into procs: event j and j+1 share a proc iff edge j is po
  local -a EVP=() EVL=()
  CY_DIRS=(); CY_N=0
  local cur_dirs="${SRC_D[0]}" cur_len=1
  EVP[0]=0; EVL[0]=0
  for ((i=0; i<k-1; i++)); do
    if [ "${KIND[i]}" = po ]; then
      EVP[i+1]=$CY_N; EVL[i+1]=$cur_len
      cur_dirs="$cur_dirs${SRC_D[i+1]}"; cur_len=$((cur_len+1))
    else
      CY_DIRS[CY_N]="$cur_dirs"; CY_N=$((CY_N+1))
      EVP[i+1]=$CY_N; EVL[i+1]=0
      cur_dirs="${SRC_D[i+1]}"; cur_len=1
    fi
  done
  CY_DIRS[CY_N]="$cur_dirs"; CY_N=$((CY_N+1))
  CY_EDGES=()
  for ((i=0; i<k; i++)); do
    [ "${KIND[i]}" = po ] && continue
    j=$(( (i+1)%k ))
    CY_EDGES+=("${KIND[i]} ${EVP[i]} ${EVL[i]} ${EVP[j]} ${EVL[j]}")
  done
}

# ===========================================================================
# PROGRAM SYNTHESIS from the NAME alone (memo 9.1: the .litmus NAMES plus
# _grid_lib.sh and nothing else -- no per-test data and no lookup table of
# verdicts).  Sets PROG_SHAPE PROG_CUT PROG_SCOPE PROG_N PROG_DEV[] PROG_EV[].
# Event encoding: `DIR:annot:scope', DIR in {R W F}.  CPU events are already the
# x86 PROJECTION of memo 3.1: STLR/LDAPR/LDR/STR -> plain MOV (`x86'), DMB.SY ->
# MFENCE, DMB.ST and DMB.LD DROPPED (G2 B.3: [CACM] p.93 models SFENCE/LFENCE as
# no-ops for WB memory and [APM] Table 7-4 p.202 names MFENCE for the store->load
# cell).  That collapse is what makes the CPU axis {plain mfence}.
# ===========================================================================
gpu_annot() {                      # gpu_annot <dir> <order> -> GA
  case "$2" in
    relaxed|fence) GA=relaxed;;
    acquire) if [ "$1" = R ]; then GA=acquire; else GA=relaxed; fi;;
    release) if [ "$1" = W ]; then GA=release; else GA=relaxed; fi;;
    acqrel)  if [ "$1" = R ]; then GA=acquire; else GA=release; fi;;
    *) die "unknown GPU order '$2'";;
  esac
}
gpu_events() {                     # gpu_events <dirs> <scope> <order> -> EV
  local dirs="$1" scope="$2" order="$3" i d fence=""
  [ "$order" = fence ] && fence=sc
  rank_of "$scope"
  EV=""
  for ((i=0; i<${#dirs}; i++)); do
    d="${dirs:i:1}"
    if [ "$i" -gt 0 ] && [ -n "$fence" ]; then EV="$EV F:$fence:$scope"; fi
    gpu_annot "$d" "$order"; EV="$EV $d:$GA:$scope"
  done
  EV="${EV# }"
}
gpu_events_2s() {                  # gpu_events_2s <dirs> <ra|sc|rel|acq> -> EV
  local dirs="$1" tok="$2" i d ann
  case "$tok" in
    ra)  gpu_events "$dirs" sys acqrel; return;;
    sc)  ann=sc;; rel) ann=release;; acq) ann=acquire;;
    *) die "unknown two-sided GPU token '$tok'";;
  esac
  EV=""
  for ((i=0; i<${#dirs}; i++)); do
    d="${dirs:i:1}"
    if [ "$i" -gt 0 ]; then EV="$EV F:$ann:sys"; fi
    EV="$EV $d:relaxed:sys"
  done
  EV="${EV# }"
}
cpu_events() {                     # cpu_events <dirs> <order|-> -> EV
  local dirs="$1" order="$2" i d mf=0
  case "$order" in
    -|acqrel|ra|st|ld) mf=0;;      # all collapse onto plain MOV on x86
    fence|sy)          mf=1;;      # DMB.SY -> MFENCE
    *) die "unknown CPU order '$order'";;
  esac
  EV=""
  for ((i=0; i<${#dirs}; i++)); do
    d="${dirs:i:1}"
    if [ "$i" -gt 0 ] && [ "$mf" = 1 ]; then EV="$EV F:MFENCE:-"; fi
    EV="$EV $d:x86:-"
  done
  EV="${EV# }"
}

program() {                        # program <name>
  local name="$1" i
  if [ -n "${REF_PROG[$name]:-}" ]; then
    PROG_SHAPE="${REF_SHAPE[$name]}"; PROG_CUT="${REF_CUT[$name]}"; PROG_SCOPE=sys
    cycle "$PROG_SHAPE"
    PROG_N=$CY_N; PROG_DEV=(); PROG_EV=()
    local rest="${REF_PROG[$name]}"
    for ((i=0; i<PROG_N; i++)); do
      case "${PROG_CUT:i:1}" in c) PROG_DEV[i]=cpu;; g) PROG_DEV[i]=gpu;;
        *) die "bad device char in reference cut '$PROG_CUT'";; esac
      PROG_EV[i]="${rest%%;*}"; rest="${rest#*;}"
    done
    return
  fi
  local base="$name" two=0
  case "$name" in *-2s) base="${name%-2s}"; two=1;; esac
  local -a F; IFS='-' read -ra F <<< "$base"
  local n=${#F[@]}
  [ "$n" -ge 4 ] || die "cannot parse test name '$name' (need shape-cut-scope-order)"
  local order="${F[n-1]}" scope="${F[n-2]}" cut="${F[n-3]}" shape="${F[0]}"
  rank_of "$scope"                                   # D8 lives here: fail closed
  cycle "$shape"
  [ "${#cut}" = "$CY_N" ] || die "cut tag '$cut' has ${#cut} procs but shape '$shape' has $CY_N ($name)"
  [ "${SHAPE_NPROCS[$shape]}" = "$CY_N" ] || die "SHAPE_NPROCS[$shape] != derived proc count ($name)"
  PROG_SHAPE="$shape"; PROG_CUT="$cut"; PROG_SCOPE="$scope"; PROG_N=$CY_N
  PROG_DEV=(); PROG_EV=()
  local ctok gtok
  for ((i=0; i<PROG_N; i++)); do
    case "${cut:i:1}" in c) PROG_DEV[i]=cpu;; g) PROG_DEV[i]=gpu;;
      *) die "unknown device char '${cut:i:1}' in cut tag '$cut' ($name)";; esac
    if [ "$two" = 1 ]; then
      case "$order" in
        *.*) ctok="${order%%.*}"; gtok="${order##*.}"
             case "$ctok" in ra|sy|st|ld) :;; *) die "unknown two-sided CPU token '$ctok' ($name)";; esac
             case "$gtok" in ra|sc|rel|acq) :;; *) die "unknown two-sided GPU token '$gtok' ($name)";; esac
             if [ "${PROG_DEV[i]}" = gpu ]; then gpu_events_2s "${CY_DIRS[i]}" "$gtok"
             else                                cpu_events    "${CY_DIRS[i]}" "$ctok"; fi;;
        acqrel|fence)
             if [ "${PROG_DEV[i]}" = gpu ]; then gpu_events "${CY_DIRS[i]}" "$scope" "$order"
             else                                cpu_events "${CY_DIRS[i]}" "$order"; fi;;
        *) die "unknown two-sided order '$order' ($name)";;
      esac
    else
      case "$order" in
        relaxed|acquire|release|fence) :;;
        *) die "unknown one-sided order '$order' ($name)";;
      esac
      if [ "${PROG_DEV[i]}" = gpu ]; then gpu_events "${CY_DIRS[i]}" "$scope" "$order"
      else                                cpu_events "${CY_DIRS[i]}" -; fi
    fi
    PROG_EV[i]="$EV"
  done
}

# ===========================================================================
# PER-PROC VIEWS.  load_proc <i> sets
#   LP_DEV  LP_DIRS               (shared-access direction string)
#   LP_A[]  LP_S[]                (annotation / scope of each shared access)
#   LP_FB[j] fences BEFORE shared access j     (space-separated "annot:scope")
#   LP_FBET  fences BETWEEN shared 0 and 1
# ===========================================================================
load_proc() {
  local i="$1" tok d a s
  LP_DEV="${PROG_DEV[i]}"; LP_DIRS=""; LP_A=(); LP_S=(); LP_FB=(); LP_FBET=""
  local pend="" ns=0
  for tok in ${PROG_EV[i]}; do
    d="${tok%%:*}"; a="${tok#*:}"; s="${a#*:}"; a="${a%%:*}"
    if [ "$d" = F ]; then pend="$pend $a:$s"
    else
      LP_FB[ns]="${pend# }"; LP_A[ns]="$a"; LP_S[ns]="$s"
      LP_DIRS="$LP_DIRS$d"; ns=$((ns+1)); pend=""
    fi
  done
  LP_NS=$ns
  # NB `if', not `[ ... ] && ...': this is the LAST command of the function, so a
  # false test would make load_proc return 1 and `set -e' would kill the script
  # on every single-access proc (IRIW's writers, WRC's head).  Same class of bug
  # as the NVIDIA generator's `exit 1 inside $(...)' -- a guard that changes
  # control flow by accident.
  if [ "$ns" -ge 2 ]; then LP_FBET="${LP_FB[1]}"; fi
}

# ---------------------------------------------------------------------------
# ordered(p) -- STEP 1.  Is p's 2-access program-order pair preserved toward an
# observer at scope >= `need'?  A primitive contributes iff the proc's pair is in
# its PRIM_* `ord' set AND its scope covers `need' (memo 3.2.3: an ordering
# primitive at scope S constrains only observers inside its S-instance).
# ---------------------------------------------------------------------------
ordered() {                        # ordered <proc-idx> <model> <need>
  load_proc "$1"
  local model="$2" need="$3" pair f fa fs
  ORD_WHY=""
  if [ "$LP_NS" -lt 2 ]; then ORD_WHY="single access"; return 0; fi
  pair="${LP_DIRS:0:2}"
  rank_of "$need"; local nrank=$RANK
  if [ "$LP_DEV" = cpu ]; then
    local key=plain
    case " $LP_FBET " in (*" MFENCE:"*) key=mfence;; esac
    prim_cpu "$key"
    ORD_WHY="x86 $PC_NAME"
    if has_tok "$pair" $PC_ORD; then return 0; fi
    ORD_WHY="x86 W->R store buffer with no MFENCE"
    return 1
  fi
  # candidate list, exactly memo 3.3's ordered(): (ord-set, scope, why)
  local -a CO=() CS=() CW=()
  if [ "${LP_A[1]}" = release ] || [ "${LP_A[1]}" = sc ]; then
    prim_gpu acc-release; CO+=("$PG_ORD"); CS+=("${LP_S[1]}"); CW+=("release store")
  fi
  if [ "${LP_A[0]}" = acquire ] || [ "${LP_A[0]}" = sc ]; then
    prim_gpu acc-acquire; CO+=("$PG_ORD"); CS+=("${LP_S[0]}"); CW+=("acquire load")
  fi
  if [ "${LP_A[0]}" = sc ] && [ "${LP_A[1]}" = sc ]; then
    prim_gpu acc-sc
    rank_of "${LP_S[0]}"; local r0=$RANK; rank_of "${LP_S[1]}"
    local lo="${LP_S[0]}"; [ "$RANK" -lt "$r0" ] && lo="${LP_S[1]}"
    CO+=("$PG_ORD"); CS+=("$lo"); CW+=("sc accesses")
  fi
  for f in $LP_FBET; do
    fa="${f%%:*}"; fs="${f##*:}"
    if [ "$fa" = release ] || [ "$fa" = sc ]; then
      prim_gpu fence-release; CO+=("$PG_ORD"); CS+=("$fs"); CW+=("release fence")
    fi
    if [ "$fa" = acquire ] || [ "$fa" = sc ]; then
      prim_gpu fence-acquire; CO+=("$PG_ORD"); CS+=("$fs"); CW+=("acquire fence")
    fi
    if [ "$fa" = sc ]; then
      prim_gpu fence-sc; CO+=("$PG_ORD"); CS+=("$fs"); CW+=("sc fence")
    fi
  done
  if [ "$model" = GCN3 ]; then     # (GCN3-a)/(GCN3-b): anchor gate only
    [ "$pair" = RW ] && { CO+=("WW RR WR RW"); CS+=(sys); CW+=("ScopedXC R->W"); }
    if gpu_has_sys_sync "$1" between; then
      CO+=("WW RR WR RW"); CS+=(sys); CW+=("ScopedXC sys rel/acq = SC fence")
    fi
  fi
  local n=${#CO[@]} i
  for ((i=0; i<n; i++)); do
    rank_of "${CS[i]}"
    if [ "$RANK" -ge "$nrank" ] && has_tok "$pair" ${CO[i]}; then
      ORD_WHY="${CW[i]} at ${CS[i]} scope"; return 0
    fi
  done
  ORD_WHY="no primitive at scope>=$need"
  return 1
}

# (GCN3-b) helper: does the proc carry a sys-scope rel/acq/sc op?  `between'
# restricts the fence search to the two accesses' interval (the `ws'/`ordered'
# form); `all' takes every fence before the given access (the cum/fresh form).
gpu_has_sys_sync() {               # gpu_has_sys_sync <proc-idx> <between|upto:N>
  load_proc "$1"
  local mode="$2" i f fa fs hi
  case "$mode" in
    between) hi=$((LP_NS-1));;
    upto:*)  hi="${mode#upto:}";;
    *) die "gpu_has_sys_sync: bad mode '$mode'";;
  esac
  for ((i=0; i<=hi && i<LP_NS; i++)); do
    case "${LP_A[i]}" in release|acquire|sc|acq_rel)
      [ "${LP_S[i]}" = sys ] && return 0;; esac
  done
  local scan=""
  if [ "$mode" = between ]; then scan="$LP_FBET"
  else for ((i=0; i<=hi && i<LP_NS; i++)); do scan="$scan ${LP_FB[i]}"; done; fi
  for f in $scan; do
    fa="${f%%:*}"; fs="${f##*:}"
    case "$fa" in release|acquire|sc|acq_rel) [ "$fs" = sys ] && return 0;; esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# fresh(R) -- the READ side of non-MCA: R cannot be satisfied from a stale
# private copy w.r.t. the coherence point `need' names.
# ---------------------------------------------------------------------------
fresh() {                          # fresh <proc-idx> <shared-idx> <model> <need>
  load_proc "$1"
  local li="$2" model="$3" need="$4" j f fa fs
  [ "$LP_DEV" = cpu ] && return 0                 # x86 loads are MCA [CMCM 2.2]
  rank_of "$need"; local nrank=$RANK
  role_of acc "${LP_A[li]}"
  if has_tok acq $ROLE; then
    rank_of "${LP_S[li]}"; [ "$RANK" -ge "$nrank" ] && return 0
  fi
  for ((j=0; j<li; j++)); do                      # a po-earlier acquire/sc ACCESS
    role_of acc "${LP_A[j]}"
    if has_tok acq $ROLE; then
      rank_of "${LP_S[j]}"; [ "$RANK" -ge "$nrank" ] && return 0
    fi
  done
  for ((j=0; j<=li; j++)); do                     # every FENCE po-before li
    for f in ${LP_FB[j]}; do
      fa="${f%%:*}"; fs="${f##*:}"
      role_of fence "$fa"
      if has_tok acq $ROLE; then
        rank_of "$fs"; [ "$RANK" -ge "$nrank" ] && return 0
      fi
    done
  done
  if [ "$model" = GCN3 ]; then
    gpu_has_sys_sync "$1" "upto:$li" && return 0
    load_proc "$1"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# cum(W) -- A-cumulativity, the WRITE side: everything proc(W) did before W has
# propagated by the time another thread reads W.
# ---------------------------------------------------------------------------
cum() {                            # cum <proc-idx> <shared-idx> <model> <need>
  load_proc "$1"
  local li="$2" model="$3" need="$4" j f fa fs
  # An x86 store read by ANY other thread is at the coherence point (the store
  # buffer is thread-local: [APM] 7.2 "a LOCAL load can read the result of a
  # local store in a store buffer before the store becomes globally visible")
  # and x86 stores reach it in program order ([APM] 7.2 "Stores do not pass
  # previous stores").  [CMCM] 6.2 p153:18 X1.
  [ "$LP_DEV" = cpu ] && return 0
  [ "$li" = 0 ] && return 0                       # nothing po-earlier to push
  rank_of "$need"; local nrank=$RANK
  role_of acc "${LP_A[li]}"
  if has_tok rel $ROLE; then
    rank_of "${LP_S[li]}"; [ "$RANK" -ge "$nrank" ] && return 0
  fi
  for ((j=0; j<=li; j++)); do                     # every FENCE po-before li
    for f in ${LP_FB[j]}; do
      fa="${f%%:*}"; fs="${f##*:}"
      role_of fence "$fa"
      if has_tok rel $ROLE; then
        rank_of "$fs"; [ "$RANK" -ge "$nrank" ] && return 0
      fi
    done
  done
  if [ "$model" = GCN3 ]; then
    gpu_has_sys_sync "$1" "upto:$li" && return 0
    load_proc "$1"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# ws(p) -- global WRITE SERIALISATION.  DECISION D7, RESOLVED 2026-08-02 (P2-0
# item R-1) as option (b): it stays FALSE on the GPU side, so the 7 rows whose
# cycle closes only through a `co' edge out of a GPU (W;W) proc are NO-ORACLE.
# The two-write gfx942 body WAS probed (g3probe3.hip ws_*); the emitted
# separator `buffer_wbl2 sc0 sc1 ; s_waitcnt vmcnt(0)' settles ord-VISIBILITY
# and not co-PLACEMENT.  Filling it needs system-scope multi-copy atomicity of
# the compound machine, which is the same unconfirmed premise as D2 and has no
# artifact anchor.  The silence is EARNED, not asserted.
# ---------------------------------------------------------------------------
ws() {                             # ws <proc-idx> <model>
  load_proc "$1"
  [ "$LP_DEV" = cpu ] && return 0    # [APM] 7.2 FIFO store buffer + x86TSO MCA
  [ "$LP_NS" -lt 2 ] && return 0
  if [ "$2" = GCN3 ]; then gpu_has_sys_sync "$1" between && return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# ms(a,b) -- morally strong.  [CMCM] 6.2 p153:18 "both events have a scope that
# includes the other access and neither of them is weak".  x86 events are
# unconditionally system-scope [CMCM 5 p153:14].  The "neither is weak" clause is
# DISCHARGED not ignored: every GPU access in this corpus is an emitted scoped
# ATOMIC, never PTX-`weak', so only scope binds; for the artifact anchors the
# plain non-atomic GPU accesses are modelled (relaxed sys) under decision D17.
# ---------------------------------------------------------------------------
ms() {                             # ms <pa> <ia> <pb> <ib>
  local pa="$1" ia="$2" pb="$3" ib="$4" s
  MS_WHY="both system-scope"
  load_proc "$pa"
  if [ "$LP_DEV" != cpu ]; then
    s="${LP_S[ia]}"
    if [ "$s" != sys ]; then
      if ! { [ "$s" = gpu ] && [ "${PROG_DEV[pb]}" = gpu ]; }; then
        MS_WHY="$s scope excludes the paired thread"; return 1; fi
    fi
  fi
  load_proc "$pb"
  if [ "$LP_DEV" != cpu ]; then
    s="${LP_S[ib]}"
    if [ "$s" != sys ]; then
      if ! { [ "$s" = gpu ] && [ "${PROG_DEV[pa]}" = gpu ]; }; then
        MS_WHY="$s scope excludes the paired thread"; return 1; fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# need_of(i): the scope an ordering primitive on proc i must reach.  `gpu' only
# when every cycle-neighbour of i is itself a GPU proc; `sys' otherwise.  For a
# het test the adjacency always includes a CPU proc, so only sys-scope GPU
# primitives count -- this single clause subsumes G4's S_CTA + S_GPU classes.
# ---------------------------------------------------------------------------
need_of() {
  local i="$1" e k sp si dp di
  NEED=sys
  [ "${PROG_DEV[i]}" != gpu ] && return
  for e in "${CY_EDGES[@]}"; do
    read -r k sp si dp di <<< "$e"
    if [ "$sp" = "$i" ] && [ "${PROG_DEV[dp]}" != gpu ]; then return; fi
    if [ "$dp" = "$i" ] && [ "${PROG_DEV[sp]}" != gpu ]; then return; fi
  done
  NEED=gpu
}

# a second observer on event (sp,si): another proc != dp with a cycle edge
# incident on that same write event.  Clause (ii) of the !SWMR hook (R-7).
has_second_observer() {
  local sp="$1" si="$2" dp="$3" e k a ai b bi
  for e in "${CY_EDGES[@]}"; do
    read -r k a ai b bi <<< "$e"
    if [ "$a" = "$sp" ] && [ "$ai" = "$si" ] && [ "$b" != "$dp" ]; then return 0; fi
    if [ "$b" = "$sp" ] && [ "$bi" = "$si" ] && [ "$a" != "$dp" ]; then return 0; fi
  done
  return 1
}

# ===========================================================================
# classify_amd(T, M) -- memo 3.3, transcribed.  Sets VERDICT and CLASS.
#   MODEL_M   CDNA3 (the shipping oracle) | GCN3 (the anchor-gate instantiation)
#   SWMR      1 (assumed, memo 8 P2) | 0 (the contingency branch)
# ===========================================================================
classify_amd() {
  local model="$1" swmr="$2" i e k sp si dp di
  cycle "$PROG_SHAPE"
  [ "$CY_N" = "$PROG_N" ] || die "proc count drift for shape '$PROG_SHAPE'"
  for ((i=0; i<PROG_N; i++)); do                   # G0's per-run half
    load_proc "$i"
    [ "${CY_DIRS[i]}" = "$LP_DIRS" ] || \
      die "cycle/program direction mismatch on P$i: cycle says '${CY_DIRS[i]}' program says '$LP_DIRS'"
  done

  # ---- STEP 1.  per-side preserved program order ---------------------------
  for ((i=0; i<PROG_N; i++)); do
    need_of "$i"
    if ! ordered "$i" "$model" "$NEED"; then
      VERDICT=Allowed
      load_proc "$i"
      if [ "$LP_DEV" = cpu ]; then CLASS=S_PPO_C; return; fi
      # refine the GPU-side failure into the three Allowed reasons of memo 5.2
      local anns=0 j
      for ((j=0; j<LP_NS; j++)); do
        case "${LP_A[j]}" in release|acquire|sc|acq_rel) anns=1;; esac
      done
      local f
      for f in $LP_FBET; do
        case "${f%%:*}" in release|acquire|sc|acq_rel) anns=1;; esac
      done
      if [ "$anns" = 0 ]; then CLASS=S_RELAXED; return; fi
      # A primitive IS present: is it the SCOPE that kills it or the ROLE?
      # `cta' is scope-rank 0 so this asks "would these same primitives order the
      # pair if scope never bound?".  No => the cause is ROLE and scope is not
      # what decides the row.  ROLE therefore WINS over SCOPE when both hold --
      # the same precedence as the memo's own prototype (r2-artifacts/refine.py
      # `refine'), and it is the more robust label because widening the scope to
      # sys would leave the row Allowed anyway.
      # MEASURED 2026-08-02 (P2a reconciliation): 8 of the 44 S_ROLE rows are at
      # cta/gpu scope -- R-cg-{cta,gpu}-{acquire,release} and
      # RWC-cgc-{cta,gpu}-{acquire,release} -- so the S_ROLE string must NOT say
      # "sys-scope primitive"; memo 5.2's wording did and was false on those 8.
      # Verdict-neutral (all 44 are Allowed under either label) and the 104/44
      # census that memo 9.4 G5 pins is unchanged.
      if ordered "$i" CDNA3 cta; then CLASS=S_SCOPE; else CLASS=S_ROLE; fi
      return
    fi
  done

  # ---- STEP 2.  thin air ---------------------------------------------------
  local allrf=1
  for e in "${CY_EDGES[@]}"; do
    read -r k sp si dp di <<< "$e"
    [ "$k" = rf ] || allrf=0
  done
  if [ "$allrf" = 1 ]; then VERDICT=Disallowed; CLASS=S_NTA; return; fi

  # ---- STEP 3.  every external edge must be global -------------------------
  for e in "${CY_EDGES[@]}"; do
    read -r k sp si dp di <<< "$e"
    if ! ms "$sp" "$si" "$dp" "$di"; then VERDICT=Allowed; CLASS=S_SCOPE; return; fi
    case "$k" in
      rf)
        # PRECONDITION HOOK (memo 8 P2 / 7.D20), TWO CLAUSES.
        #   (i)  UNGUARDED: a GPU proc's program order is not transmitted to a
        #        CPU observer.  This is the calibration to the artifact's single
        #        red-highlighted Table 2 cell and the anchor gate needs it.
        #   (ii) GUARDED BY M == CDNA3 (P2-0 item R-7 / addendum sect 7 item 4):
        #        a single GPU write is not multi-copy-atomic either, once the
        #        coherence invariant is broken.  Transfer to the GCN3 gate
        #        instantiation is REFUSED per D3 -- with clause (ii) live there
        #        the anchor gate falls to 33/34 on no-SWMR IRIW1-sys.
        # Dead code in the shipped CSV by construction: SWMR = 1 there.
        if [ "$swmr" = 0 ] && [ "${PROG_DEV[sp]}" = gpu ] && [ "${PROG_DEV[dp]}" = cpu ]; then
          load_proc "$sp"
          if [ "$LP_NS" -gt 1 ]; then VERDICT=Allowed; CLASS=S_NOSWMR; return; fi
          # The guard is a NAMED PARAMETER so that G15 can drop it and observe
          # what the drop costs.  Written as a literal `= CDNA3' it could not be
          # dropped without editing the rule -- and the G15 that used to sit here
          # ran the whole gate at M = CDNA3 instead, which flips six rows through
          # (GCN3-a)/(GCN3-b) whatever this clause does.  MEASURED: with clause
          # (ii) DELETED OUTRIGHT that check still printed "guard is live".
          if [ "$model" = "$HOOK_II_GUARD_MODEL" ] && has_second_observer "$sp" "$si" "$dp"; then
            VERDICT=Allowed; CLASS=S_NOSWMR; return
          fi
        fi
        need_of "$sp"
        if ! cum "$sp" "$si" "$model" "$NEED"; then
          VERDICT=Allowed; CLASS=S_RF_NOCUM; return; fi;;
      fr)
        need_of "$sp"
        if ! fresh "$sp" "$si" "$model" "$NEED"; then
          VERDICT=Allowed; CLASS=S_FR_STALE; return; fi;;
      co)
        if [ "$si" -gt 0 ]; then
          load_proc "$sp"
          if [ "${LP_DIRS:si-1:1}" = W ]; then
            if ! ws "$sp" "$model"; then
              VERDICT=NO-ORACLE
              # the two sub-shapes are one emitted cell but TWO provenance
              # chains and must not be merged (addendum sect 1 R-1)
              load_proc "$sp"
              if [ -n "$LP_FBET" ]; then CLASS=S_WS_FENCE; else CLASS=S_WS_REL; fi
              return
            fi
          fi
        fi;;
      *) die "unknown edge kind '$k'";;
    esac
  done
  VERDICT=Disallowed; CLASS=S_CUT
}

# ---------------------------------------------------------------------------
# S_CUT_MCA (memo 5.2 split 1, decision D2) -- detected STRUCTURALLY, never by
# name: a Disallowed S_CUT whose shape has two INDEPENDENT observers (IRIW RWC)
# and whose cycle has an `fr' edge out of a GPU proc that is a pure observer
# (program-order pair R;R).  Both clauses are load-bearing: without the R;R
# clause the ordinary RWC W->R proc is swept in (10 rows); without the shape
# clause every MP-cg acquire row is (35).  G12 asserts the count is exactly 8.
# ---------------------------------------------------------------------------
is_mca() {
  [ "$VERDICT" = Disallowed ] && [ "$CLASS" = S_CUT ] || return 1
  case "$PROG_SHAPE" in IRIW|RWC) :;; *) return 1;; esac
  local e k sp si dp di
  for e in "${CY_EDGES[@]}"; do
    read -r k sp si dp di <<< "$e"
    if [ "$k" = fr ] && [ "${PROG_DEV[sp]}" = gpu ]; then
      load_proc "$sp"
      [ "$LP_DIRS" = RR ] && return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# PROVENANCE (memo 2.3), single-valued, assigned by PRECEDENCE, highest first.
# The first rule that matches wins and this is exactly that order.
#   1 decision            the verdict depends on an unconfirmed sect 7 entry
#   2 artifact-csv-corrected   appears only in the ANCHOR table (0 corpus rows)
#   3 artifact            a surviving [ART] anchor covers the load-bearing cell
#   4 herd7-checked       a herd7 run decides the row in the SOUND direction
#   5 derived             composition of admitted sources
# Grade -> claim strength on a Disallowed row: `artifact' (32 rows after D24)
# is the only FULL-STRENGTH grade.  `derived' (106) is the declared single-chain
# grade; `decision' (8) means the verdict rests on an unconfirmed sect 7 entry.
# 114 of the 146 report CAPPED.  `herd7-checked' never lands on a Disallowed row.
# ---------------------------------------------------------------------------
# Grade 3 is MEASURED, not asserted: re-classify with every GPU primitive outside
# the two surviving artifact-anchored cells (acc-release@WW from MP1-sys-F and
# GPU-Only MP-sys-F; acc-acquire@RR from MP2-sys-F IRIW2-sys-F and GPU-Only
# IRIW-sys-F) downgraded to relaxed and every GPU fence deleted.  A row that is
# still Disallowed has its load-bearing cell anchor-covered.
ablate_to_anchored() {
  local i tok d a s pair out
  for ((i=0; i<PROG_N; i++)); do
    if [ "${PROG_DEV[i]}" != gpu ]; then continue; fi
    load_proc "$i"
    pair="-"; [ "$LP_NS" -ge 2 ] && pair="${LP_DIRS:0:2}"
    out=""
    for tok in ${PROG_EV[i]}; do
      d="${tok%%:*}"; a="${tok#*:}"; s="${a#*:}"; a="${a%%:*}"
      if [ "$d" = F ]; then continue; fi            # no fence cell is anchored
      case "$a" in
        release) [ "$pair" = WW ] || a=relaxed;;
        acquire) [ "$pair" = RR ] || a=relaxed;;
        sc|acq_rel) a=relaxed;;
      esac
      out="$out $d:$a:$s"
    done
    PROG_EV[i]="${out# }"
  done
}

# ---------------------------------------------------------------------------
# THE GRADE-3 VACUITY GUARD (decision D24, landed by P2a 2026-08-02).
#
# `ablate_to_anchored' MEASURES grade 3 by keeping only the two anchor-covered
# GPU cells and asking whether the row is still Disallowed.  For a row that has
# NO GPU ordering at all -- memo 5.4's K-CPU population, where every GPU proc in
# the cycle carries exactly one shared access -- that test is VACUOUS: there is
# nothing to ablate, so the row survives EVERY ablation including a total one
# and it passes for the wrong reason.  MEASURED: exactly the 17 K-CPU rows of
# memo 5.4 survive a TOTAL GPU-primitive ablation, and all 17 shipped `artifact'
# i.e. FULL STRENGTH -- the only grade memo 9.2's mismatch protocol lets a
# reader report as a candidate CMCM refutation.
#
# For such a row the [ART] link is not cell coverage but a SHAPE transfer, so
# the guard asks for one directly: the row's own shape must itself carry a
# Disallowed artifact anchor.
#   * IRIW does -- Compound IRIW1-sys (memo 5.4's exact twin; 5.5).  The 8 IRIW
#     K-CPU rows are that twin (cgcg-relaxed) or a STRENGTHENING of it (cgcc
#     replaces a GPU writer with an x86 one; -release / -acqrel-2s add
#     annotations), so Disallowed transfers in the sound direction.
#   * WRC WRC3 and RWC do NOT.  Memo 5.4 says so in terms -- "there is no
#     artifact shape anchor for WRC/WRC3/RWC" -- and their Key-2 is "X2a alone
#     applied as a mechanism transfer", i.e. 7.D21, which is still OPEN and
#     which Key-1 (the S_CUT string) ALREADY cites.  Key-1 and that Key-2 are
#     the same chain counted twice: exactly the device 7.D23 rejects.
# So those 9 rows take grade 5 `derived' -- CAPPED, the fail-safe direction.
# NO VERDICT MOVES; 146 Disallowed is unchanged.  Grade census 41/309 -> 32/318.
# ---------------------------------------------------------------------------
gpu_supplies_ordering() {          # 0 (true) iff a GPU proc has >1 shared access
  local i
  for ((i=0; i<PROG_N; i++)); do
    if [ "${PROG_DEV[i]}" = gpu ]; then
      load_proc "$i"
      if [ "$LP_NS" -gt 1 ]; then return 0; fi
    fi
  done
  return 1
}

# ===========================================================================
# MEMO 5.4.1 -- THE SINGLE-CHAIN DECLARATION, TRANSCRIBED AND MEASURED.
# The addendum (sect 7 item 1) makes that sub-section NORMATIVE and says this
# script transcribes it, so it is transcribed as NUMBERS THE SCRIPT RE-DERIVES,
# not as a comment: each cell's "rows for which it is load-bearing" is recomputed
# by ablating that one cell and re-classifying, and the aggregate coverage rows
# are recomputed the same way.  A cell here is (prim, pair) where pair is the
# HOST PROC's program-order direction pair.
#
#   cell                rows   artifact anchor?   recorded gfx942 emission
#   acc-acquire@RR       16    YES                g3probe:mp_acq_sys
#   acc-release@WW       12    YES                g3probe:mp_rel_sys
#   fence-sc@RW          18    no                 g3probe3:f_sc_rw
#   fence-sc@RR          15    no                 g3probe3:f_sc_rr
#   fence-sc@WW          12    no                 g3probe3:f_sc_ww
#   acc-release@RW       10    no                 g3probe3:acc_rel_rw
#   fence-release@RW      8    no                 g3probe3:f_rel_rw
#   fence-release@WW      8    no                 g3probe2:f_rel_ww
#   fence-acquire@RW      8    no                 g3probe4:f_acq_rw   <- NOT
#         g3probe:fence_acq_sys, WITHDRAWN by P2-0 as a NON-ATOMIC probe whose
#         uniform load lowers to a scalar s_load_dword; the memo's own
#         lb_reg_shape standard disqualifies it.  Had it stood, coverage would
#         have been 138/146, not 146/146.
#   fence-sc@WR           8    no                 g3probe2:f_sc_wr
#   fence-acquire@RR      4    no                 g3probe2:f_acq_rr
#   acc-acquire@RW        2    no                 g3probe2:lb_acq_sys
#
# Coverage, MEASURED below: anchors alone 45/146; anchors + the recorded
# emissions 146/146, uninstrumented 0.  A recorded emission is part of KEY-1
# (the S_* derivation over [LLVM]'s GFX942 code sequences), NOT an independent
# Key-2, so no grade changes ON THIS ACCOUNT and the declared single-chain rows
# stay single-chain (addendum sect 2 and sect 4).  The single-chain population is
# 110 after D24 (106 `derived' + the 4 `S_CUT_MCA' sc-fence `decision' rows); it
# was 101 before, and the 9 added are the WRC/WRC3/RWC K-CPU rows whose claimed
# Key-2 turned out to be Key-1's own X2a.
# ===========================================================================
CELL_TABLE="acc-acquire@RR:16 acc-release@WW:12 fence-sc@RW:18 fence-sc@RR:15
fence-sc@WW:12 acc-release@RW:10 fence-release@RW:8 fence-release@WW:8
fence-acquire@RW:8 fence-sc@WR:8 fence-acquire@RR:4 acc-acquire@RW:2"
ANCHORED_CELLS="acc-release@WW acc-acquire@RR"

# ablate_keep <"cell cell ..."> -- downgrade every GPU primitive whose (prim,pair)
# cell is NOT in the list to `relaxed', and delete every GPU fence whose cell is
# not in it.  Mutates PROG_EV in place; the caller re-runs program() to restore.
ablate_keep() {
  local keep=" $1 " i tok d a s pair out
  for ((i=0; i<PROG_N; i++)); do
    if [ "${PROG_DEV[i]}" != gpu ]; then continue; fi
    load_proc "$i"
    pair="-"; if [ "$LP_NS" -ge 2 ]; then pair="${LP_DIRS:0:2}"; fi
    out=""
    for tok in ${PROG_EV[i]}; do
      d="${tok%%:*}"; a="${tok#*:}"; s="${a#*:}"; a="${a%%:*}"
      if [ "$d" = F ]; then
        case "$keep" in (*" fence-$a@$pair "*) out="$out $d:$a:$s";; esac
        continue
      fi
      case "$a" in release|acquire|sc|acq_rel)
        case "$keep" in (*" acc-$a@$pair "*) :;; (*) a=relaxed;; esac;;
      esac
      out="$out $d:$a:$s"
    done
    PROG_EV[i]="${out# }"
  done
}

# every (prim,pair) cell that OCCURS on a Disallowed row -- derived, not listed
cells_occurring() {
  local n i tok d a s pair
  CELLS_ALL=""
  for n in $DIS_ROWS; do
    program "$n"
    for ((i=0; i<PROG_N; i++)); do
      if [ "${PROG_DEV[i]}" != gpu ]; then continue; fi
      load_proc "$i"
      pair="-"; if [ "$LP_NS" -ge 2 ]; then pair="${LP_DIRS:0:2}"; fi
      for tok in ${PROG_EV[i]}; do
        d="${tok%%:*}"; a="${tok#*:}"; a="${a%%:*}"
        local c=""
        if [ "$d" = F ]; then c="fence-$a@$pair"
        else case "$a" in release|acquire|sc|acq_rel) c="acc-$a@$pair";; esac; fi
        if [ -n "$c" ]; then
          case " $CELLS_ALL " in (*" $c "*) :;; (*) CELLS_ALL="$CELLS_ALL $c";; esac
        fi
      done
    done
  done
  CELLS_ALL="${CELLS_ALL# }"
}

gate_cells() {
  echo "== memo 5.4.1 per-cell load-bearing ablation over the Disallowed rows ==" >&2
  local f n c keep cnt bad=0 e w
  DIS_ROWS=""
  for f in $(ls ./*.litmus | LC_ALL=C sort); do
    n="$(basename "$f" .litmus)"
    program "$n"; classify_amd CDNA3 1
    [ "$VERDICT" = Disallowed ] && DIS_ROWS="$DIS_ROWS $n"
  done
  local ndis=0; for n in $DIS_ROWS; do ndis=$((ndis+1)); done
  [ "$ndis" = 146 ] || die "5.4.1: $ndis Disallowed rows not 146"
  cells_occurring
  printf '   %-20s %6s %6s\n' cell measured memo >&2
  for e in $CELL_TABLE; do
    c="${e%%:*}"; w="${e##*:}"
    case " $CELLS_ALL " in (*" $c "*) :;;
      (*) die "5.4.1: cell $c is in the transcribed table but OCCURS ON NO Disallowed row";; esac
    keep=""
    for n in $CELLS_ALL; do [ "$n" = "$c" ] || keep="$keep $n"; done
    cnt=0
    for n in $DIS_ROWS; do
      program "$n"; ablate_keep "${keep# }"; classify_amd CDNA3 1
      [ "$VERDICT" = Disallowed ] || cnt=$((cnt+1))
    done
    printf '   %-20s %6s %6s\n' "$c" "$cnt" "$w" >&2
    [ "$cnt" = "$w" ] || { echo "   ^ MISMATCH" >&2; bad=$((bad+1)); }
  done
  [ "$bad" = 0 ] || die "5.4.1 FAILED: $bad cell(s) have a load-bearing row count the memo does not"
  # every cell that occurs but is NOT in the table must be load-bearing for ZERO
  # rows, else the twelve-cell set is not the whole story
  for c in $CELLS_ALL; do
    case " $(echo "$CELL_TABLE" | tr ' \n' '  ' | sed 's/:[0-9]*//g') " in
      (*" $c "*) continue;; esac
    keep=""
    for n in $CELLS_ALL; do [ "$n" = "$c" ] || keep="$keep $n"; done
    cnt=0
    for n in $DIS_ROWS; do
      program "$n"; ablate_keep "${keep# }"; classify_amd CDNA3 1
      [ "$VERDICT" = Disallowed ] || cnt=$((cnt+1))
    done
    [ "$cnt" = 0 ] || die "5.4.1 FAILED: cell $c is outside the transcribed twelve but is load-bearing for $cnt row(s)"
    echo "   $c: occurs but load-bearing for 0 rows (outside the twelve by measurement)" >&2
  done
  # coverage aggregates
  cnt=0
  for n in $DIS_ROWS; do
    program "$n"; ablate_keep "$ANCHORED_CELLS"; classify_amd CDNA3 1
    [ "$VERDICT" = Disallowed ] && cnt=$((cnt+1))
  done
  echo "   anchors alone: $cnt / 146 covered" >&2
  [ "$cnt" = 45 ] || die "5.4.1 FAILED: anchors alone cover $cnt rows but the memo measured 45"
  # Of those 45, the K-CPU rows pass VACUOUSLY -- they have no GPU ordering to
  # ablate.  Memo 5.4.1 said "17 are K-CPU rows that carry no GPU primitive at
  # all"; MEASURED, 8 of the 17 DO carry a sys-scope w[release] on their
  # single-access GPU proc (IRIW-cgcc/cgcg and WRC-ccg and WRC3-cccg at
  # -release and -acqrel-2s).  It is structurally INERT -- a one-access proc has
  # no pair to order and cum() is true because the access is the cycle's first
  # event -- which is why the ablation still does not move them; but the memo's
  # sentence was false of those 8 and it is that sentence which justified the
  # grade.  D24 replaces the vacuous pass with an explicit shape-anchor test.
  local nvacc=0 nvacc_noanchor=0
  for n in $DIS_ROWS; do
    program "$n"; ablate_keep "$ANCHORED_CELLS"; classify_amd CDNA3 1
    [ "$VERDICT" = Disallowed ] || continue
    program "$n"
    gpu_supplies_ordering && continue
    nvacc=$((nvacc+1))
    shape_has_dis_anchor "$PROG_SHAPE" || nvacc_noanchor=$((nvacc_noanchor+1))
  done
  echo "   of which VACUOUS (no GPU ordering to ablate): $nvacc ; of those with no Disallowed artifact anchor for their SHAPE: $nvacc_noanchor -> graded derived by D24" >&2
  [ "$nvacc" = 17 ] || die "5.4.1 FAILED: $nvacc rows pass the anchor ablation vacuously but memo 5.4's K-CPU population is 17"
  [ "$nvacc_noanchor" = 9 ] || die "D24 FAILED: $nvacc_noanchor vacuous rows lack a shape anchor but P2a measured 9 (WRC WRC3 RWC)"
  local twelve; twelve=$(echo "$CELL_TABLE" | tr ' \n' '  ' | sed 's/:[0-9]*//g')
  cnt=0
  for n in $DIS_ROWS; do
    program "$n"; ablate_keep "$twelve"; classify_amd CDNA3 1
    [ "$VERDICT" = Disallowed ] && cnt=$((cnt+1))
  done
  echo "   anchors + the recorded gfx942 emissions: $cnt / 146 covered ; uninstrumented $((146-cnt))" >&2
  [ "$cnt" = 146 ] || die "5.4.1 FAILED: the twelve instrumented cells cover $cnt rows but the addendum measured 146 (gap 0)"
}

# ===========================================================================
# THE ANCHOR GATE (memo 4, gate G1).  34 rows re-encoded AS PROGRAMS from the
# .cpp bodies plus the build configuration, run through classify_amd at
# M = GCN3-VIPER with the NARROW !SWMR hook.  It must pass 34/34 BEFORE the CSV
# is written.  Two rows carry `artifact-csv-corrected' reference values: the
# shipped expected.csv says Disallowed for Compound MP1-cta-F (l.14) and no-SWMR
# MP1-sys-F (l.26), and [CMCM] Table 2 p153:22 plus the artifact's own per-test
# ReadMes say Allowed on both.  The second is the paper's single red-highlighted
# cell and the CSV error erases the headline ablation result.
# ===========================================================================
EXPECT_ANCHORS=34                  # memo 4.2's row count; asserted in anchor_gate()
ANCHORS=(
 "CPU-Only|MP-sys|Disallowed|MP|cc|W:x86:- W:x86:-;R:x86:- R:x86:-|1|artifact"
 "CPU-Only|LB-sys|Disallowed|LB|cc|R:x86:- W:x86:-;R:x86:- W:x86:-|1|artifact"
 "CPU-Only|SB-sys|Allowed|SB|cc|W:x86:- R:x86:-;W:x86:- R:x86:-|1|artifact"
 "CPU-Only|IRIW-sys|Disallowed|IRIW|cccc|R:x86:- R:x86:-;W:x86:-;R:x86:- R:x86:-;W:x86:-|1|artifact"
 "GPU-Only|MP-sys|Allowed|MP|gg|W:relaxed:sys W:relaxed:sys;R:relaxed:sys R:relaxed:sys|1|artifact"
 "GPU-Only|MP-sys-F|Disallowed|MP|gg|W:relaxed:sys W:release:sys;R:acquire:sys R:relaxed:sys|1|artifact"
 "GPU-Only|LB-sys|Disallowed|LB|gg|R:relaxed:sys W:relaxed:sys;R:relaxed:sys W:relaxed:sys|1|artifact"
 "GPU-Only|SB-sys|Allowed|SB|gg|W:relaxed:sys R:relaxed:sys;W:relaxed:sys R:relaxed:sys|1|artifact"
 "GPU-Only|SB-sys-F|Disallowed|SB|gg|W:release:sys R:acquire:sys;W:release:sys R:acquire:sys|1|artifact"
 "GPU-Only|IRIW-sys|Allowed|IRIW|gggg|R:relaxed:sys R:relaxed:sys;W:relaxed:sys;R:relaxed:sys R:relaxed:sys;W:relaxed:sys|1|artifact"
 "GPU-Only|IRIW-sys-F|Disallowed|IRIW|gggg|R:acquire:sys R:relaxed:sys;W:release:sys;R:acquire:sys R:relaxed:sys;W:release:sys|1|artifact"
 "GPU-Only|MP-cta-F|Allowed|MP|gg|W:relaxed:cta W:release:cta;R:acquire:cta R:acquire:cta|1|artifact"
 "Compound|MP1-sys|Allowed|MP|gc|W:relaxed:sys W:relaxed:sys;R:x86:- R:x86:-|1|artifact"
 "Compound|MP1-sys-F|Disallowed|MP|gc|W:relaxed:sys W:release:sys;R:x86:- R:x86:-|1|artifact"
 "Compound|MP1-cta-F|Allowed|MP|gc|W:relaxed:cta W:release:cta;R:x86:- R:x86:-|1|artifact-csv-corrected"
 "Compound|MP2-sys|Allowed|MP|cg|W:x86:- W:x86:-;R:relaxed:sys R:relaxed:sys|1|artifact"
 "Compound|MP2-sys-F|Disallowed|MP|cg|W:x86:- W:x86:-;R:acquire:sys R:relaxed:sys|1|artifact"
 "Compound|LB-sys|Disallowed|LB|cg|R:x86:- W:x86:-;R:relaxed:sys W:relaxed:sys|1|artifact"
 "Compound|SB-sys|Allowed|SB|cg|W:x86:- R:x86:-;W:relaxed:sys R:relaxed:sys|1|artifact"
 "Compound|SB-sys-F|Disallowed|SB|cg|W:x86:- F:MFENCE:- R:x86:-;W:release:sys R:acquire:sys|1|artifact"
 "Compound|IRIW1-sys|Disallowed|IRIW|cgcg|R:x86:- R:x86:-;W:relaxed:sys;R:x86:- R:x86:-;W:relaxed:sys|1|artifact"
 "Compound|IRIW2-sys|Allowed|IRIW|gcgc|R:relaxed:sys R:relaxed:sys;W:x86:-;R:relaxed:sys R:relaxed:sys;W:x86:-|1|artifact"
 "Compound|IRIW2-sys-F|Disallowed|IRIW|gcgc|R:acquire:sys R:relaxed:sys;W:x86:-;R:acquire:sys R:relaxed:sys;W:x86:-|1|artifact"
 "Compound-orphan|SB-sys-HF|Allowed|SB|cg|W:x86:- R:x86:-;W:release:sys R:acquire:sys|1|artifact-readme"
 "no-SWMR|MP1-sys|Allowed|MP|gc|W:relaxed:sys W:relaxed:sys;R:x86:- R:x86:-|0|artifact"
 "no-SWMR|MP1-sys-F|Allowed|MP|gc|W:relaxed:sys W:release:sys;R:x86:- R:x86:-|0|artifact-csv-corrected"
 "no-SWMR|MP2-sys|Allowed|MP|cg|W:x86:- W:x86:-;R:relaxed:sys R:relaxed:sys|0|artifact"
 "no-SWMR|MP2-sys-F|Disallowed|MP|cg|W:x86:- W:x86:-;R:acquire:sys R:relaxed:sys|0|artifact"
 "no-SWMR|LB-sys|Disallowed|LB|cg|R:x86:- W:x86:-;R:relaxed:sys W:relaxed:sys|0|artifact"
 "no-SWMR|SB-sys|Allowed|SB|cg|W:x86:- R:x86:-;W:relaxed:sys R:relaxed:sys|0|artifact"
 "no-SWMR|SB-sys-F|Disallowed|SB|cg|W:x86:- F:MFENCE:- R:x86:-;W:release:sys R:acquire:sys|0|artifact"
 "no-SWMR|IRIW1-sys|Disallowed|IRIW|cgcg|R:x86:- R:x86:-;W:relaxed:sys;R:x86:- R:x86:-;W:relaxed:sys|0|artifact"
 "no-SWMR|IRIW2-sys|Allowed|IRIW|gcgc|R:relaxed:sys R:relaxed:sys;W:x86:-;R:relaxed:sys R:relaxed:sys;W:x86:-|0|artifact"
 "no-SWMR|IRIW2-sys-F|Disallowed|IRIW|gcgc|R:acquire:sys R:relaxed:sys;W:x86:-;R:acquire:sys R:relaxed:sys;W:x86:-|0|artifact"
)
# The table's SIZE is a static property of this file so it is asserted HERE at
# top level -- unredirected -- and therefore in EVERY mode.  `--g15' runs its
# pre-flight anchor_gate under `>/dev/null 2>&1', so a die() raised inside the
# function exits 1 with NO PRINTED REASON; and `--cells'/`--swmr-list' never
# call anchor_gate at all and so never saw the table.  Checking the array here
# is what makes a truncated table report itself to a human in all five modes.
[ "${#ANCHORS[@]}" = "$EXPECT_ANCHORS" ] ||
  die "anchor table has ${#ANCHORS[@]} rows but memo 4.2 has $EXPECT_ANCHORS"

# The shapes for which [ART] supplies a DISALLOWED anchor, DERIVED from the table
# above rather than listed -- a shape that ever leaves the anchor set must lose
# the grade-3 shape transfer with it.  Read by the grade-3 vacuity guard (D24).
ANCHOR_DIS_SHAPES=""
for _arow in "${ANCHORS[@]}"; do
  IFS='|' read -r _at _an _ae _as _arest <<< "$_arow"
  [ "$_ae" = Disallowed ] || continue
  case " $ANCHOR_DIS_SHAPES " in (*" $_as "*) :;;
    (*) ANCHOR_DIS_SHAPES="$ANCHOR_DIS_SHAPES $_as";; esac
done
ANCHOR_DIS_SHAPES="${ANCHOR_DIS_SHAPES# }"
unset _arow _at _an _ae _as _arest
[ -n "$ANCHOR_DIS_SHAPES" ] || die "no Disallowed artifact anchor at all -- the grade-3 shape transfer has no basis"
shape_has_dis_anchor() {           # shape_has_dis_anchor <shape>
  case " $ANCHOR_DIS_SHAPES " in (*" $1 "*) return 0;; esac
  return 1
}

load_anchor() {                    # load_anchor <row-string>
  local row="$1" i rest
  IFS='|' read -r A_TYPE A_NAME A_EXP PROG_SHAPE PROG_CUT rest A_SWMR A_PROV <<< "$row"
  PROG_SCOPE=sys
  cycle "$PROG_SHAPE"
  PROG_N=$CY_N; PROG_DEV=(); PROG_EV=()
  for ((i=0; i<PROG_N; i++)); do
    case "${PROG_CUT:i:1}" in c) PROG_DEV[i]=cpu;; g) PROG_DEV[i]=gpu;;
      *) die "bad device char in anchor cut '$PROG_CUT'";; esac
    PROG_EV[i]="${rest%%;*}"; rest="${rest#*;}"
  done
}

anchor_gate() {                    # anchor_gate [hook-override]
  local hookmodel="${1:-GCN3}" row bad=0 n=0
  local ncorr=0 nread=0 nplain=0 who_corr="" who_read=""
  printf '%-16s %-12s %-11s %-11s %-6s %s\n' Type Litmus reference predicted match class >&2
  for row in "${ANCHORS[@]}"; do
    load_anchor "$row"
    classify_amd "$hookmodel" "$A_SWMR"
    n=$((n+1))
    local ok=OK
    if [ "$VERDICT" != "$A_EXP" ]; then ok="**MISMATCH**"; bad=$((bad+1)); fi
    # A_PROV IS LOAD-BEARING (P2a 2026-08-02).  It used to be parsed and never
    # read, which made memo 9.4 G1's requirement that the gate carry "the two
    # artifact-csv-corrected values" a COMMENT rather than an assertion.  The
    # three grades are counted here and the two special ones are named, so a
    # relabelled or renamed row reddens the gate that exists to reproduce
    # memo 4.2 -- not a later reader's eye.
    case "$A_PROV" in
      artifact)               nplain=$((nplain+1));;
      artifact-csv-corrected) ncorr=$((ncorr+1));  who_corr="$who_corr $A_TYPE/$A_NAME";;
      artifact-readme)        nread=$((nread+1));  who_read="$who_read $A_TYPE/$A_NAME";;
      *) die "anchor '$A_TYPE $A_NAME' carries provenance '$A_PROV'; memo 4.2 knows only artifact | artifact-csv-corrected | artifact-readme";;
    esac
    printf '%-16s %-12s %-11s %-11s %-6s %s\n' \
      "$A_TYPE" "$A_NAME" "$A_EXP" "$VERDICT" "$ok" "$CLASS" >&2
  done
  ANCHOR_N=$n; ANCHOR_BAD=$bad
  # memo 4.2: rows 15 and 26 are the two CSV corrections (4.3), row 24 the ReadMe
  # orphan (4.2 footnote), the other 31 plain `artifact'.
  [ "$ncorr" = 2 ] || die "anchor table has $ncorr artifact-csv-corrected row(s); memo 4.3 adjudicates exactly 2"
  [ "$nread" = 1 ] || die "anchor table has $nread artifact-readme row(s); memo 4.2 footnote has exactly 1"
  [ "$nplain" = 31 ] || die "anchor table has $nplain plain-artifact row(s); memo 4.2 has 31"
  [ "${who_corr# }" = "Compound/MP1-cta-F no-SWMR/MP1-sys-F" ] ||
    die "the artifact-csv-corrected rows are '${who_corr# }' but memo 4.3 adjudicates Compound/MP1-cta-F and no-SWMR/MP1-sys-F"
  [ "${who_read# }" = "Compound-orphan/SB-sys-HF" ] ||
    die "the artifact-readme row is '${who_read# }' but memo 4.2 footnote names Compound-orphan/SB-sys-HF"
  echo "anchor provenance: $nplain artifact / $ncorr artifact-csv-corrected (${who_corr# }) / $nread artifact-readme (${who_read# })" >&2
  # OMISSION guard, and it belongs HERE not at the call site.  Measured 2026-08-02:
  # the size assert used to live only on the generate path (just before the CSV is
  # written) so `--anchors' and `--g15' both reported a SILENTLY TRUNCATED table
  # as green -- delete one row and they printed `anchor gate: 33/33' and exited 0.
  # Those are precisely the two modes a reviewer runs standalone to check memo 9.4
  # G1, so the corruption bite passed while the omission bite did not exist.
  [ "$n" = "$EXPECT_ANCHORS" ] ||
    die "anchor gate has $n rows but memo 4.2 has $EXPECT_ANCHORS"
  echo "anchor gate: $((n-bad))/$n  (mismatches: $bad)" >&2
}

# ===========================================================================
# G0 -- CYCLE STRUCTURE + PROGRAM SYNTHESIS vs the .litmus FILES.
# The rule takes the NAME; this asserts the name-derived program is the program
# the corpus actually contains, for all 411 tests, event for event.  It is the
# assertion memo 3.0 demands ("must carry this as an assertion not a comment").
# The awk projection mirrors memo 3.1 exactly: MOV/LDR/STR/LDAPR/STLR -> x86,
# DMB SY -> MFENCE, DMB ST / DMB LD dropped, GPU r/w/f[annot,scope] verbatim.
# ===========================================================================
litmus_program() {                 # litmus_program <file> -> LIT_PROG ("ev;ev;...")
  LIT_PROG=$(awk '
    /^ *P0:/ && !seen { seen=1; n=split($0,H,"|");
      for (i=1;i<=n;i++) { gsub(/[ \t;]/,"",H[i]); split(H[i],D,":"); dev[i]=D[2] }
      next }
    seen {
      line=$0; sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
      if (line=="") next
      if (line ~ /^(scopes:|exists|locations|forall)/) { seen=0; next }
      if (line !~ /;$/) { seen=0; next }
      sub(/;$/,"",line); m=split(line,C,"|")
      for (i=1;i<=n;i++) {
        c=C[i]; gsub(/^[ \t]+|[ \t]+$/,"",c)
        if (c=="") continue
        if (dev[i]=="cpu") {
          # NB no \b: in a POSIX/gawk regexp constant \b is NOT a word boundary
          # (gawk reads it as backspace), so /^(LDR|LDAPR)\b/ matched NOTHING and
          # every CPU instruction fell through to the "?" arm.  Measured over the
          # corpus the CPU column has exactly 8 forms (G5 B.1) and they are these.
          if (c ~ /^(LDR|LDAPR|LDAR)[ \t]/)   ev[i]=ev[i] " R:x86:-"
          else if (c ~ /^(STR|STLR)[ \t]/)    ev[i]=ev[i] " W:x86:-"
          else if (c ~ /^DMB[ .]SY/)          ev[i]=ev[i] " F:MFENCE:-"
          else if (c ~ /^DMB[ .](ST|LD)/)     { }
          else if (c ~ /^MOV[ \t]/)           { }
          else                                ev[i]=ev[i] " ?:" c ":-"
        } else {
          if (match(c,/^[rwf]\[[a-z_]+,[a-z]+\]/)) {
            t=substr(c,RSTART,RLENGTH); k=substr(t,1,1)
            sub(/^[rwf]\[/,"",t); sub(/\]$/,"",t); split(t,A,",")
            d=(k=="r")?"R":((k=="w")?"W":"F")
            ev[i]=ev[i] " " d ":" A[1] ":" A[2]
          } else ev[i]=ev[i] " ?:" c ":-"
        }
      }
    }
    END { out=""
      for (i=1;i<=n;i++) { s=ev[i]; sub(/^ /,"",s); out=(i==1)?s:out ";" s }
      print out }' "$1")
}

gate_G0() {
  local f name i want got bad=0 nfile=0
  for f in $(ls ./*.litmus | LC_ALL=C sort); do
    name="$(basename "$f" .litmus)"; nfile=$((nfile+1))
    program "$name"
    got=""
    for ((i=0; i<PROG_N; i++)); do
      if [ "$i" = 0 ]; then got="${PROG_EV[i]}"; else got="$got;${PROG_EV[i]}"; fi
    done
    litmus_program "$f"; want="$LIT_PROG"
    if [ "$got" != "$want" ]; then
      bad=$((bad+1))
      echo "G0 FAIL $name" >&2
      echo "   name-derived: $got" >&2
      echo "   .litmus file: $want" >&2
    fi
  done
  echo "G0 cycle-structure + program synthesis vs $nfile .litmus files: $bad mismatch(es)" >&2
  [ "$bad" = 0 ] || die "G0 FAILED: the name-derived program is not the corpus program"
  G0_N=$nfile
}

# ===========================================================================
# G13 -- ZERO GPU->GPU external edges (memo 9.4 G13).  Decision D5 and sect 6's
# "divergence (2) is inert" both depend on it.
# G14 -- UNREACHABLE-PRIMITIVE HONESTY (memo 9.4 G14): the PRIM_GPU `acc-sc' row
# and the PRIM_CPU `lock' row must have 0 occurrences across all 411 tests, and
# no CSV row's derivation may have used them.
# ===========================================================================
gate_G13_G14() {
  local f name i tok d a e k sp si dp di
  local ext=0 gg=0 scacc=0 lock=0 unreach_used=0
  # (a) FILE-LEVEL first, and on the raw text.  No test NAME can produce an `sc'
  # ACCESS (the grid realises the sc column as a standalone f[sc,S] fence), so
  # without this half G14 could only ever be bitten by editing PRIM_GPU -- never
  # by the corpus growing one.  It runs before G0 for the same reason: a corpus
  # that contains an unreachable primitive must be refused by G14 by NAME, not
  # reported as a program-synthesis mismatch.
  local ftext=0
  ftext=$(grep -l -E '[rw]\[sc,' ./*.litmus 2>/dev/null | wc -l || true)
  [ "$ftext" = 0 ] || {
    grep -l -E '[rw]\[sc,' ./*.litmus >&2
    die "G14 FAILED: $ftext corpus file(s) carry a w/r[sc,*] ACCESS; PRIM_GPU's acc-sc row is declared unreachable (memo 3.2.1 -- 0 occurrences in all 411 tests) and G4 must not claim to check it"; }
  ftext=$(grep -l -E '\b(LDXR|STXR|CAS[AL]*|SWP|LDADD|LOCK|XCHG)\b' ./*.litmus 2>/dev/null | wc -l || true)
  [ "$ftext" = 0 ] || {
    grep -l -E '\b(LDXR|STXR|CAS[AL]*|SWP|LDADD|LOCK|XCHG)\b' ./*.litmus >&2
    die "G14 FAILED: $ftext corpus file(s) carry a locked/exclusive RMW; PRIM_CPU's lock row is declared unreachable (memo 7.D6) and no gate may claim to check it"; }
  for f in $(ls ./*.litmus | LC_ALL=C sort); do
    name="$(basename "$f" .litmus)"
    program "$name"
    cycle "$PROG_SHAPE"
    for e in "${CY_EDGES[@]}"; do
      read -r k sp si dp di <<< "$e"
      ext=$((ext+1))
      if [ "${PROG_DEV[sp]}" = gpu ] && [ "${PROG_DEV[dp]}" = gpu ]; then
        gg=$((gg+1)); echo "G13 FAIL: GPU->GPU $k edge in $name (P$sp -> P$dp)" >&2
      fi
    done
    for ((i=0; i<PROG_N; i++)); do
      for tok in ${PROG_EV[i]}; do
        d="${tok%%:*}"; a="${tok#*:}"; a="${a%%:*}"
        case "$d:$a" in
          R:sc|W:sc) scacc=$((scacc+1));;
          R:lock|W:lock) lock=$((lock+1));;
        esac
      done
    done
  done
  echo "G13 external edges: $ext  GPU->GPU: $gg (must be 0)" >&2
  echo "G14 unreachable primitives: w/r[sc;*] accesses $scacc (must be 0)  LOCK/RMW $lock (must be 0)" >&2
  [ "$gg" = 0 ] || die "G13 FAILED: a GPU->GPU external edge exists"
  [ "$scacc" = 0 ] || die "G14 FAILED: PRIM_GPU acc-sc is declared unreachable but $scacc occurrence(s) exist"
  [ "$lock" = 0 ] || die "G14 FAILED: PRIM_CPU lock is declared unreachable but $lock occurrence(s) exist"
  prim_gpu acc-sc;  [ "$PG_REACH" = no ] || die "G14 FAILED: PRIM_GPU acc-sc must be declared unreachable"
  prim_cpu lock;    [ "$PC_REACH" = no ] || die "G14 FAILED: PRIM_CPU lock must be declared unreachable"
  G13_EXT=$ext
}

# ===========================================================================
# THE VALIDITY-PRECONDITION BANNER (memo sect 8).  These are NOT resolved and
# every row of expected-amd.csv carries a dagger until they return.
# ===========================================================================
banner() {
  cat >&2 <<'EOB'

  ======================================================================
  VALIDITY PRECONDITIONS -- UNRESOLVED.  Every Disallowed row below is a
  MODEL DERIVATION and is void until these return (memo sect 8).
  ----------------------------------------------------------------------
  P1  The shared buffer must map WB (write-back cacheable) on the CPU side.
      [APM] 7.2 scopes its rules to "normal cacheable accesses on naturally
      aligned boundaries to WB memory".  If WC: MP S 2+2W ISA2 WRC WRC3 IRIW
      flip Disallowed -> Allowed and the oracle manufactures false refutations
      across ~120 rows.  If UC: SB R RWC flip Allowed -> Disallowed (footnote f
      + Table 7-2 p.199; footnote i is REVERSED in Rev 3.45 and is NOT cited).
      Probe: PAT/MTRR + /proc/self/smaps or an SB microbenchmark ON THE ACTUAL
      SHARED ALLOCATION per candidate allocator.
  P2  The race-path allocator must give hardware CPU-GPU coherence WITH SWMR --
      not driver zero-copy emulation.  This is the SWMR parameter of the rule.
      IF P2 FAILS 65 OF THE 146 Disallowed ROWS LOSE THEIR VERDICT (was 48
      before the P2-0 hook widening); 81 survive (19 S_NTA + 62 S_CUT).  The
      65-row list is printed below and by `build-amd-oracle.sh --swmr-list'.
  P3  The GPU-side allocation must be FINE-GRAINED.  ROCm: coarse-grained
      memory downgrades system-scope atomics to device scope -- every sys-scope
      row is void and all 146 Disallowed collapse to Allowed.
  P4  Record the compute-partition mode (SPX/CPX) and tgsplit per run.
  P5  Host __hip_atomic_fetch_add(...SEQ_CST...) must lower to a LOCK-prefixed
      RMW on x86-64 or the rendezvous barrier does not drain the store buffer.
  P6  No REP-prefixed string instruction on the race path; accesses naturally
      aligned ([APM] 7.2's string-operation carve-out would void the RR cell).
  ----------------------------------------------------------------------
  D10 A CPU-ONLY POSITIVE CONTROL IS MANDATORY BEFORE ANY OF THIS MEANS
      ANYTHING: SB and R must be OBSERVED on the MI300A host on the actual
      shared allocation; MP LB 2+2W IRIW must never be.  If a CPU-only
      Disallowed shape is observed the finding is "x86-TSO does not describe
      this implementation" -- NOT a refutation of the compound model.
  ======================================================================

EOB
}

# ===========================================================================
# THE !SWMR HOOK SETS + GATE G15 (addendum sect 7 items 3 and 4).
#
# NARROW = clause (i) only          -- the M = GCN3-VIPER (anchor gate) hook
# WIDE   = clause (i) + clause (ii) -- the M = CDNA3 hook
# Both are computed by RUNNING the rule, never tabulated.  The shipped CSV is
# generated with SWMR = 1, so the whole hook is dead code there; what these sets
# fix is the sect 8 P2 CONTINGENCY (65 rows) and the structural tie between the
# widening and the K-CPU key inventory.
# ===========================================================================
# memo 5.4's K-CPU list, verbatim (17 rows).  PINNED here and re-derived
# structurally below; G15 asserts wide \ narrow equals it ELEMENT FOR ELEMENT,
# which is the measured confirmation that the widening IS "revoke X2a".
KCPU_ROWS="
IRIW-cgcc-sys-relaxed IRIW-cgcc-sys-release IRIW-cgcc-sys-acqrel-2s IRIW-cgcc-sys-fence-2s
IRIW-cgcg-sys-relaxed IRIW-cgcg-sys-release IRIW-cgcg-sys-acqrel-2s IRIW-cgcg-sys-fence-2s
WRC-ccg-sys-relaxed   WRC-ccg-sys-release   WRC-ccg-sys-acqrel-2s   WRC-ccg-sys-fence-2s
WRC3-cccg-sys-relaxed WRC3-cccg-sys-release WRC3-cccg-sys-acqrel-2s WRC3-cccg-sys-fence-2s
RWC-ccg-sys-fence-2s
"

swmr_sets() {                      # -> P2_ROWS (wide) NARROW_ROWS KCPU_DERIVED
  local f name base i gpuord
  P2_ROWS=(); NARROW_ROWS=(); KCPU_DERIVED=()
  for f in $(ls ./*.litmus | LC_ALL=C sort); do
    name="$(basename "$f" .litmus)"
    program "$name"; classify_amd CDNA3 1
    [ "$VERDICT" = Disallowed ] || continue
    base="$VERDICT"
    # K-CPU, DERIVED (memo 5.4): a Disallowed row where every GPU proc in the
    # cycle has exactly one shared access, so no GPU proc supplies ordering.
    gpuord=0
    for ((i=0; i<PROG_N; i++)); do
      if [ "${PROG_DEV[i]}" = gpu ]; then
        load_proc "$i"; if [ "$LP_NS" -gt 1 ]; then gpuord=1; fi
      fi
    done
    if [ "$gpuord" = 0 ]; then KCPU_DERIVED+=("$name"); fi
    # WIDE: clause (i) + clause (ii)   (M = CDNA3, the shipping instantiation)
    program "$name"; classify_amd CDNA3 0
    [ "$VERDICT" = "$base" ] || P2_ROWS+=("$name")
    # NARROW: clause (i) only.  Reached by running the SAME rule at the gate
    # instantiation's model -- but that also removes (GCN3-a)/(GCN3-b), so it is
    # NOT a clean isolation.  Isolate instead by disabling the guard's match.
    program "$name"
    HOOK_II_GUARD_MODEL=__none__ classify_amd CDNA3 0
    [ "$VERDICT" = "$base" ] || NARROW_ROWS+=("$name")
  done
}

# set difference: WIDE \ NARROW, sorted
swmr_delta() {
  DELTA=()
  local a b found
  for a in "${P2_ROWS[@]}"; do
    found=0
    for b in "${NARROW_ROWS[@]}"; do if [ "$a" = "$b" ]; then found=1; break; fi; done
    if [ "$found" = 0 ]; then DELTA+=("$a"); fi
  done                          # `if', not `&&': see the note in load_proc
}

gate_G15() {
  echo "== G15 the !SWMR hook split must not drift (addendum sect 7 item 3) ==" >&2
  # (iv) the anchor gate under the NARROW hook is still 34/34 -------------------
  anchor_gate GCN3 >/dev/null 2>&1
  [ "$ANCHOR_BAD" = 0 ] || die "G15(iv) FAILED: anchor gate is $((ANCHOR_N-ANCHOR_BAD))/$ANCHOR_N under the narrow hook"
  echo "   (iv) anchor gate under the NARROW hook: $((ANCHOR_N-ANCHOR_BAD))/$ANCHOR_N" >&2
  # (i) the guard is LOAD-BEARING: drop it and the gate must fall to 33/34 ------
  # This is the isolation the old check lacked: the MODEL stays GCN3 (so
  # (GCN3-a)/(GCN3-b) are unchanged) and ONLY the guard moves.
  local saved="$HOOK_II_GUARD_MODEL"
  HOOK_II_GUARD_MODEL=GCN3
  local g15tmp; g15tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$g15tmp'" RETURN            # no droppings even when `die' fires
  anchor_gate GCN3 >"$g15tmp" 2>&1 || true
  local dropped_ok=$((ANCHOR_N-ANCHOR_BAD)) dropped_bad=$ANCHOR_BAD
  # `|| true': under `set -o pipefail' a grep that finds nothing makes the whole
  # substitution status 1, which -- MEASURED -- killed the script here with NO
  # message at all whenever clause (ii) was deleted outright.  A gate that exits
  # non-zero without saying why is not a gate.
  local who; who=$(grep MISMATCH "$g15tmp" | awk '{print $1" "$2}' || true)
  [ -n "$who" ] || who="<nothing -- the gate did not fall at all>"
  HOOK_II_GUARD_MODEL="$saved"
  [ "$dropped_bad" = 1 ] || die "G15(i) FAILED: with the M == CDNA3 guard dropped the anchor gate is $dropped_ok/$ANCHOR_N (expected 33/34) -- clause (ii) has become inert or the hook is not two-clause"
  case "$who" in
    "no-SWMR IRIW1-sys") :;;
    *) die "G15(i) FAILED: dropping the guard breaks '$who' but the addendum measured no-SWMR IRIW1-sys";;
  esac
  echo "   (i)  guard dropped -> anchor gate $dropped_ok/$ANCHOR_N breaking exactly '$who'" >&2
  anchor_gate GCN3 >/dev/null 2>&1     # restore the reported state
  # (ii)/(iii) |wide \ narrow| == 17 and the delta EQUALS the K-CPU list --------
  swmr_sets; swmr_delta
  echo "   (ii) !SWMR rows moved: narrow ${#NARROW_ROWS[@]}  wide ${#P2_ROWS[@]}  delta ${#DELTA[@]}" >&2
  [ "${#NARROW_ROWS[@]}" = 48 ] || die "G15(ii) FAILED: the narrow hook moves ${#NARROW_ROWS[@]} rows but R-7 measured 48"
  [ "${#P2_ROWS[@]}" = 65 ]     || die "G15(ii) FAILED: the wide hook moves ${#P2_ROWS[@]} rows but R-7 measured 65"
  [ "${#DELTA[@]}" = 17 ]       || die "G15(ii) FAILED: |wide \\ narrow| = ${#DELTA[@]} but the addendum pins 17"
  local pinned derived delta
  pinned=$(printf '%s\n' $KCPU_ROWS | LC_ALL=C sort)
  derived=$(printf '%s\n' "${KCPU_DERIVED[@]}" | LC_ALL=C sort)
  delta=$(printf '%s\n' "${DELTA[@]}" | LC_ALL=C sort)
  if [ "$pinned" != "$derived" ]; then
    echo "G15(iii) K-CPU pinned-vs-derived differences:" >&2
    diff <(echo "$pinned") <(echo "$derived") >&2 || true
    die "G15(iii) FAILED: memo 5.4's pinned K-CPU list is not the set the rule derives"
  fi
  if [ "$delta" != "$pinned" ]; then
    echo "G15(iii) wide-minus-narrow vs K-CPU differences (< delta only  > K-CPU only):" >&2
    diff <(echo "$delta") <(echo "$pinned") >&2 || true
    die "G15(iii) FAILED: wide \\ narrow is not element-for-element the K-CPU list of memo 5.4"
  fi
  echo "   (iii) wide \\ narrow == the 17 K-CPU rows of memo 5.4 == the rule's own derived set" >&2
}

# ===========================================================================
# MAIN
# ===========================================================================
MODE="${1:---generate}"
case "$MODE" in
  --anchors)
    anchor_gate GCN3
    [ "$ANCHOR_BAD" = 0 ] || die "anchor gate FAILED ($ANCHOR_BAD mismatches)"
    exit 0;;
  --swmr-list)
    swmr_sets
    printf '%s\n' "${P2_ROWS[@]}"
    echo "sect 8 P2 contingency: ${#P2_ROWS[@]} rows (narrow hook would move ${#NARROW_ROWS[@]})" >&2
    exit 0;;
  --g15)
    anchor_gate GCN3 >/dev/null 2>&1
    gate_G15
    echo "G15 OK" >&2
    exit 0;;
  --cells)
    gate_cells
    echo "memo 5.4.1 OK" >&2
    exit 0;;
  --generate) ;;
  *) die "unknown mode '$MODE' (expected --generate | --anchors | --swmr-list | --g15 | --cells)";;
esac

# --- G1: the anchor gate runs and passes BEFORE the CSV is written ----------
echo "== G1 anchor gate (memo 4.2) -- M = GCN3-VIPER + narrow !SWMR hook ==" >&2
anchor_gate GCN3
[ "$ANCHOR_BAD" = 0 ] || die "anchor gate FAILED ($ANCHOR_BAD mismatches) -- refusing to write $OUT"
[ "$ANCHOR_N" = "$EXPECT_ANCHORS" ] ||
  die "anchor gate has $ANCHOR_N rows but memo 4.2 has $EXPECT_ANCHORS"

# --- G15: the !SWMR hook split ---------------------------------------------
gate_G15

# --- G13 / G14 / G0 --------------------------------------------------------
# G14's file-level half runs FIRST: a corpus carrying an unreachable primitive
# must be refused as such, not reported as a G0 synthesis mismatch.
echo "== G13 / G14 / G0 structural assertions over the corpus ==" >&2
gate_G13_G14
gate_G0

# --- generate --------------------------------------------------------------
# ATOMIC WRITE (P2a 2026-08-02).  The rows are emitted to a TEMPORARY file, every
# fatal guard below runs against THAT, and only a clean run renames it over
# $OUT.  Measured before the fix: the comma guard and the census pins run AFTER
# the redirection closes, so injecting one comma left a corrupt 274915-byte
# expected-amd.csv on disk and then exited 1.  Harmless under
# `make hetlitmus-amd-oracle' (temp dir) but NOT under `make hetlitmus-promote',
# which runs this generator in the tree.  A failed guard must leave the previous
# CSV untouched, not a half-verified one.
TMPOUT="$(mktemp "$PWD/.expected-amd.csv.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$TMPOUT'" EXIT
banner
declare -A NCLASS=() NPROV=() NVERD=()
{
  echo "Litmus,Expected,Model,Provenance,Source"
  echo "# AMD MI300A het oracle (Zen 4 x86-64 CCDs + CDNA3 XCDs = $MODEL)."
  echo "# Verdicts are DERIVED not measured; no line of this file is a hardware"
  echo "# observation.  Spec: env-research/PORT2-R2-amd-oracle.md (sect 9 is the"
  echo "# contract) as amended by env-research/PORT2-P2-0-addendum.md sect 7."
  echo "# Provenance is single-valued (memo 2.3) and CAPS the claim strength of a"
  echo "# Disallowed row: only 'artifact' is full strength.  A mismatch on a"
  echo "# 'derived' or 'decision' row indicts THIS ORACLE ROW first never the CMCM."
  echo "# A non-observation never proves Disallowed.  MI300X has NO oracle: it must"
  echo "# use its own Model string and an UNINTERPRETED frame -- never these rows."
  echo "# oracle-compare.sh prints UNINTERPRETED for a test absent from this file and"
  echo "# keeps NO-ORACLE for the 7 rows that EARN it (memo 6); it also switches its"
  echo "# mismatch sentence on column 4 -- full strength only for 'artifact'."
  echo "# QUOTATION CONVENTION: commas are STRIPPED from quoted source text below"
  echo "# because the comma guard is fatal; quotes are otherwise verbatim."
  echo "# Preconditions P1 P2 P3 (memo sect 8) are UNRESOLVED; the banner and the"
  echo "# 65-row P2 contingency list are printed to stderr at generation time."
  for f in $(ls ./*.litmus | LC_ALL=C sort); do
    name="$(basename "$f" .litmus)"
    program "$name"
    classify_amd CDNA3 1
    if is_mca; then CLASS=S_CUT_MCA; fi
    # provenance, by the precedence of memo 2.3
    local_prov=derived
    case "$CLASS" in
      S_CUT_MCA|S_WS_FENCE|S_WS_REL) local_prov=decision;;
      *)
        if [ "$VERDICT" = Disallowed ]; then
          v0="$VERDICT"
          ablate_to_anchored
          classify_amd CDNA3 1
          [ "$VERDICT" = Disallowed ] && local_prov=artifact
          VERDICT="$v0"
          program "$name"; classify_amd CDNA3 1
          if is_mca; then CLASS=S_CUT_MCA; fi
          # D24, the grade-3 vacuity guard: the ablation above measured NOTHING
          # for a row with no GPU ordering at all, so ask for the shape transfer
          # explicitly instead of accepting a vacuous pass.  Fail-safe: the only
          # move is artifact -> derived, i.e. full strength -> capped.
          if [ "$local_prov" = artifact ] && ! gpu_supplies_ordering; then
            shape_has_dis_anchor "$PROG_SHAPE" || local_prov=derived
          fi
        fi
        if [ "$local_prov" = derived ] && [ "$CLASS" = S_PPO_C ]; then
          local_prov=herd7-checked
        fi;;
    esac
    src_of "$CLASS"
    NCLASS[$CLASS]=$(( ${NCLASS[$CLASS]:-0} + 1 ))
    NPROV[$local_prov]=$(( ${NPROV[$local_prov]:-0} + 1 ))
    NVERD[$VERDICT]=$(( ${NVERD[$VERDICT]:-0} + 1 ))
    echo "$name,$VERDICT,$MODEL,$local_prov,$SOURCE"
  done
} > "$TMPOUT"

# --- the sect 8 P2 contingency list, at generation time --------------------
# (gate_G15 already populated P2_ROWS; recomputed here so the printed list can
# never be a stale variable from a different code path.)
swmr_sets
echo "  sect 8 P2 CONTINGENCY -- the ${#P2_ROWS[@]} Disallowed rows that lose their verdict" >&2
echo "  if the race-path allocator does not give hardware SWMR coherence:" >&2
printf '    %s\n' "${P2_ROWS[@]}" >&2
[ "${#P2_ROWS[@]}" = 65 ] || die "sect 8 P2 contingency is ${#P2_ROWS[@]} rows but the addendum (item 5) measured 65"

# ===========================================================================
# INVARIANTS.  All fatal, all run against $TMPOUT -- the file that was just
# written -- BEFORE it is renamed over $OUT.
#
# EVERY CENSUS NUMBER BELOW IS RE-MEASURED FROM THAT FILE.  It used to be read
# out of the NCLASS/NPROV/NVERD arrays the emit loop accumulated, while the
# comment above claimed the opposite.  DEMONSTRATED 2026-08-02: patch only the
# `echo' that emits a row so one verdict prints NO-ORACLE while the counters stay
# correct, and the generator wrote a 257/146/8 CSV and exited 0 printing
# "build-amd-oracle: OK".  The loop counters are kept as a SECOND, INDEPENDENT
# measurement and asserted to agree with the file, which is what catches exactly
# that class of bug -- a divergence between what was counted and what was
# emitted -- instead of hiding it.
# ===========================================================================
csvrows() { grep -vE '^#|^Litmus,' "$TMPOUT"; }
csvcount() {                       # csvcount <field> <value>
  csvrows | awk -F, -v f="$1" -v v="$2" '$f==v' | wc -l
}
ndata=$(csvrows | wc -l)
nlit=$(ls ./*.litmus | wc -l)
echo "wrote $OUT: $ndata rows for $nlit .litmus files" >&2
csvrows | cut -d, -f2 | LC_ALL=C sort | uniq -c >&2
csvrows | cut -d, -f4 | LC_ALL=C sort | uniq -c >&2
[ "$ndata" = "$nlit" ] || die "row count $ndata != .litmus count $nlit"
[ "$ndata" = 411 ] || die "expected 411 corpus rows got $ndata"

# Column guard, FATAL (the NVIDIA precedent, build-nvidia-oracle.sh:271-276).
badcols=$(csvrows | awk -F, -v m="$MODEL" '
  NF<5 || ($2!="Allowed" && $2!="Disallowed" && $2!="NO-ORACLE") || $3!=m ||
  ($4!="decision" && $4!="artifact-csv-corrected" && $4!="artifact" &&
   $4!="herd7-checked" && $4!="derived") {print NR": "$0}')
if [ -n "$badcols" ]; then
  echo "ERROR: malformed row(s) -- f2 verdict f3 model f4 provenance:" >&2
  printf '%s\n' "$badcols" >&2; exit 1
fi

# THE COMMA GUARD IS FATAL (memo 9.2).  A comma inside a Source string splits it
# across CSV fields 5..n.  The NVIDIA generator degrades this to advisory only
# because 38 legacy strings already contain one and are pinned byte-stable
# (MEASURED: `build-nvidia-oracle.sh' itself prints "38 row(s) have a comma
# inside the Source string (advisory)"; memo 9.2 says 41, which is the
# full-strength artifact Disallowed count -- a number collision, not a count of
# strings).  A new file has no legacy and every S_* string above is comma-free
# BY CONSTRUCTION.
ncomma=$(csvrows | awk -F, 'NF>5' | wc -l)
[ "$ncomma" = 0 ] || {
  echo "ERROR: $ncomma row(s) have a comma inside the Source string:" >&2
  csvrows | awk -F, 'NF>5 {print NR": "$1}' >&2
  exit 1; }

# Census pins.  If your build disagrees with these the BUILD is wrong until
# proven otherwise -- do not adjust the target (memo 5.1, 5.2, 2.3).
# Argument 2 of every chk is a COUNT READ BACK OUT OF $TMPOUT.
chk() { [ "$2" = "$3" ] || die "census FAILED: $1 = $2 but the memo pins $3"; }
chk "Allowed"       "$(csvcount 2 Allowed)"       258
chk "Disallowed"    "$(csvcount 2 Disallowed)"    146
chk "NO-ORACLE"     "$(csvcount 2 NO-ORACLE)"     7
chk "decision"      "$(csvcount 4 decision)"      15
chk "artifact"      "$(csvcount 4 artifact)"      32
chk "herd7-checked" "$(csvcount 4 herd7-checked)" 46
chk "derived"       "$(csvcount 4 derived)"       318
# The per-class census is measured by counting each S_* string IN THE FILE.  The
# comma guard above has already established that no row has more than 5 fields,
# so field 5 IS the whole Source string and an EXACT match is the honest test;
# a substring grep would survive a truncated string.
# Each entry is class:rows:verdict.  The VERDICT is checked PER ROW, not just in
# aggregate: MEASURED 2026-08-02, a census-preserving corruption -- swap the
# verdicts of one Allowed row and one NO-ORACLE row -- leaves every aggregate in
# this file and in amdordercheck.py Phase 3/4 unchanged and would ship.  The
# class determines the verdict, both are in the CSV, so the honest check is that
# they agree row by row.
for _cl in S_RELAXED:60:Allowed S_SCOPE:104:Allowed S_ROLE:44:Allowed \
           S_PPO_C:46:Allowed S_RF_NOCUM:4:Allowed S_NTA:19:Disallowed \
           S_CUT:119:Disallowed S_CUT_MCA:8:Disallowed \
           S_WS_FENCE:4:NO-ORACLE S_WS_REL:3:NO-ORACLE; do
  _k="${_cl%%:*}"; _rest="${_cl#*:}"; _w="${_rest%%:*}"; _v="${_rest##*:}"
  src_of "$_k"
  chk "$_k" "$(csvrows | awk -F, -v s="$SOURCE" '$5==s' | wc -l)" "$_w"
  _bad=$(csvrows | awk -F, -v s="$SOURCE" -v v="$_v" '$5==s && $2!=v {print $1" carries "$2}')
  [ -z "$_bad" ] || {
    echo "CLASS/VERDICT DISAGREEMENT -- $_k must always be $_v:" >&2
    printf '  %s\n' "$_bad" >&2
    die "class $_k has row(s) whose emitted verdict is not $_v"; }
done
unset _cl _k _w _v _rest _bad
# SECOND, INDEPENDENT measurement: the loop's own counters must agree with the
# file.  This is the assertion that catches an emit-line bug -- a row printed
# with a value the counters never saw -- which neither half can catch alone.
for _v in Allowed Disallowed NO-ORACLE; do
  [ "${NVERD[$_v]:-0}" = "$(csvcount 2 "$_v")" ] ||
    die "EMIT DIVERGENCE: the loop counted ${NVERD[$_v]:-0} $_v row(s) but the file carries $(csvcount 2 "$_v") -- the emitted line is not what was classified"
done
for _v in decision artifact herd7-checked derived; do
  [ "${NPROV[$_v]:-0}" = "$(csvcount 4 "$_v")" ] ||
    die "EMIT DIVERGENCE: the loop counted ${NPROV[$_v]:-0} '$_v' row(s) but the file carries $(csvcount 4 "$_v")"
done
unset _v
# G12 here as well as in amdordercheck.py: S_CUT_MCA is the whole exposure of
# D2, the only decision in the memo that moves toward Disallowed.
# `|| true' on the trailing grep -c: with `set -o pipefail' a count of 0 would
# make the substitution fail and kill the script BEFORE the die below, i.e. the
# gate would exit 1 without ever saying which invariant broke.
nmca=$(csvrows | awk -F, '$4=="decision"' | grep -c 'cycle cut through a GPU observer' || true)
[ "$nmca" = 8 ] || die "G12 FAILED: S_CUT_MCA is $nmca rows in the CSV but must be exactly 8"
# no Disallowed row may ever carry herd7-checked (memo 2.3)
nbadgrade=$(csvrows | awk -F, '$2=="Disallowed" && $4=="herd7-checked"' | wc -l)
[ "$nbadgrade" = 0 ] || die "$nbadgrade Disallowed row(s) carry herd7-checked -- forbidden by memo 2.3"
# D24: no vacuously-graded row may carry `artifact'.  A K-CPU row (no GPU proc
# with more than one shared access) passes ablate_to_anchored for FREE, so the
# grade must come from a shape anchor or not at all.  Re-derived from the file +
# the corpus so the guard cannot drift away from the emitted grades.
nvac=0
for _n in $(csvrows | awk -F, '$2=="Disallowed" && $4=="artifact" {print $1}'); do
  program "$_n"
  if ! gpu_supplies_ordering && ! shape_has_dis_anchor "$PROG_SHAPE"; then
    echo "  D24 VIOLATION: $_n has no GPU ordering and shape $PROG_SHAPE has no Disallowed artifact anchor" >&2
    nvac=$((nvac+1))
  fi
done
unset _n
[ "$nvac" = 0 ] || die "D24 FAILED: $nvac row(s) carry full-strength 'artifact' on a VACUOUS ablation pass"
# claim-strength split, printed because it is what a reader must be told
nfull=$(csvrows | awk -F, '$2=="Disallowed" && $4=="artifact"' | wc -l)
ncap=$(csvrows | awk -F, '$2=="Disallowed" && $4!="artifact"' | wc -l)
echo "Disallowed claim strength: $nfull FULL (artifact) / $ncap CAPPED (declared single chain)" >&2
[ "$nfull" = 32 ] || die "full-strength Disallowed is $nfull but the memo pins 32 (D24)"
[ "$ncap" = 114 ] || die "capped Disallowed is $ncap but the memo pins 114 (D24)"
# Every guard has passed against $TMPOUT.  Only now does it become $OUT.
mv -f "$TMPOUT" "$OUT"
trap - EXIT
echo "build-amd-oracle: OK" >&2
