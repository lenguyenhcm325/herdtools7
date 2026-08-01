#!/usr/bin/env bash
# Regenerate the NVIDIA GH200 het oracle  tests/het/expected-nvidia.csv  from the
# het corpus (the .litmus names produced by generate.sh).  Verdicts are derived,
# not measured (running on a GH200 is Task 9), and grounded in three primary
# sources -- docs/het-oracle.md carries the provenance, the per-shape proofs and
# the quotations behind every row below:
#   [CMCM]   Goens et al., Compound Memory Models, PLDI'23.
#   [PTX]    Lustig et al., A Formal Analysis of the NVIDIA PTX MCM, ASPLOS'19.
#   [Bagchi] Bagchi et al., Consistency & Coherence of the Grace-Hopper
#            Superchip, ISMM'26 (empirical GH200).
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
#    MP, LB, S                      Disallowed  Disallowed
#    SB, R                          Allowed     Disallowed  (RCpc rel/acq never
#                                               orders store->load; an SC fence
#                                               does)
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
#  unordered), Disallowed (both sides order their pair and the [PTX] pattern
#  completes) and NO-ORACLE (both order their pair, pattern does not complete --
#  the cells where CMCM's operational model forbids and its own axiomatic model
#  permits, [CMCM] 5.1 + Fig 11).  hetlitmus/verify/ordercheck.py proves the
#  rule is the function herd7 computes: 96 CPU-only cells under the native
#  AArch64 model, 96 GPU-only cells under nvidia-ptx.cat.
#
# The one step no solver decides: that a CPU DMB and a sys-scope GPU fence are
# morally strong at all, i.e. that the two sides compose across the C2C boundary
# ([CMCM] 3.2.3/4.4, [Bagchi] 3.2/4.2, [PTX] Table 1).
#
# An observed weak outcome makes a verdict Allowed and is robust; a
# non-observation NEVER proves Disallowed.  Every Disallowed row is a model
# derivation, not a measurement, and carries its grounding in the Source column.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../_grid_lib.sh
source ../_grid_lib.sh          # for SHAPE_NPROCS (2-proc vs transitive split)

MODEL="NVIDIA-PTX-AArch64"

# Source strings.  The one-sided ones are held byte-stable: regenerating the CSV
# must not churn the baseline verdict text.
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

# Grounding text for the matched 2-proc rows, keyed <shape>:<order>.  Their
# verdicts are not tabulated here -- they come from the order-pair grid below.
declare -A TWOSIDED_SRC=(
  [MP:acqrel]="$S_MP_RA"  [MP:fence]="$S_MP_F"
  [LB:acqrel]="$S_LB_RA"  [LB:fence]="$S_LB_F"
  [S:acqrel]="$S_S_RA"    [S:fence]="$S_S_F"
  [SB:acqrel]="$S_SBR_RA" [SB:fence]="$S_SBR_F"
  [R:acqrel]="$S_SBR_RA"  [R:fence]="$S_SBR_F"
)

# ---------------------------------------------------------------------------
# The two-sided order-pair grid  <cpu>.<gpu>  (header decision table).
# The Source strings built here must contain NO comma -- this file is a CSV --
# so primitives are named by their real mnemonics: `DMB SY', `fence.acquire.sys'.
# ---------------------------------------------------------------------------

# The order-pair alphabet: <side>:<tok> -> "<ord>|<role>|<name>".
#   ord   the program-order pairs of {WW RR WR RW} the primitive orders inside
#         its own thread.  ARM rows are herd7's own answer; GPU rows are [CMCM] 5
#         (quoted in docs/het-oracle.md).  Note that release/acquire lacks WR --
#         that is RCpc, and it is why SB/R stay Allowed under everything but a
#         pair of SC fences.
#   role  which half of a morally-strong pair the primitive can supply.
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

# two_sided_order_pair <shape> <cuttag> <cpu-tok> <gpu-tok> -> VERDICT, SOURCE
two_sided_order_pair() {
  local shape="$1" tag="$2" c="$3" g="$4"
  local -a CY; read -ra CY <<< "${SHAPE_CYCLE[$shape]}"
  local p0="${CY[0]#Pod}" p1="${CY[2]#Pod}"
  local d0="${tag:0:1}" pc pg r0 r1 oc og nc ng rolec roleg
  if [ "$d0" = c ]; then pc="$p0"; pg="$p1"; else pc="$p1"; pg="$p0"; fi
  prim cpu "$c"; nc="$PRIM_NAME"; oc="$PRIM_ORD"; rolec="$PRIM_ROLE"
  prim gpu "$g"; ng="$PRIM_NAME"; og="$PRIM_ORD"; roleg="$PRIM_ROLE"

  # (1) each thread's own model must order its own program-order pair
  if ! has_tok "$pc" $oc; then
    VERDICT=Allowed
    SOURCE="two-sided sys order pair ($nc | $ng): the CPU thread's own ISA leaves its $pc program-order pair unordered so no reading of the compound model cuts the cycle [machine-checked herd7 AArch64 via verify/ordercheck.py; CMCM 4.3 fence orderings]"
    return
  fi
  if ! has_tok "$pg" $og; then
    VERDICT=Allowed
    SOURCE="two-sided sys order pair ($nc | $ng): the GPU thread's own model leaves its $pg program-order pair unordered so no reading of the compound model cuts the cycle [machine-checked nvidia-ptx.cat via verify/ordercheck.py; CMCM 5 PTX sem>=rel/acq]"
    return
  fi

  # (2) the [PTX] Fig4/Fig6 pattern requirement on top of per-side ordering
  if [ "$d0" = c ]; then r0="$rolec"; r1="$roleg"
  else                   r0="$roleg"; r1="$rolec"; fi
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
    SOURCE="two-sided sys order pair ($nc | $ng): CPU orders its $pc pair and GPU orders its $pg pair and $why; unscoped ARM ops are system-scoped so the pair is morally strong; 2-proc cycle cut with no MCA needed [CMCM 3.2.3+4.4+4.6; Bagchi 3.2+4.2; PTX 3.3+Fig4+Fig6; machine-checked verify/ordercheck.py]"
  else
    VERDICT=NO-ORACLE
    SOURCE="two-sided sys order pair ($nc | $ng): both threads order their own pair so CMCM's OPERATIONAL model forbids -- but its own AXIOMATIC compound model CMM (a sound abstraction; PTX component = Lustig Fig4/Fig7) permits it. CMCM 5.1 names exactly this gap: 'There are two ways in which our operational model is stronger than the axiomatic PTX model: (1) Write serialization ... (2) Release and acquire fences are slightly stronger in cumulative chains ... events can be transitively ordered using either release or acquire fences though the axiomatic PTX model would only order if the fence is at least acqrel' (Fig 11 witnesses: 2+2W and ISA2). Characterization not a falsification claim [CMCM 5.1+Fig11+6.2; PTX Fig4/Fig7; machine-checked nvidia-ptx.cat via verify/ordercheck.py]"
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
    # acqrel is its (ra,ra) cell and fence its (sy,sc) one -- so the verdict is
    # the grid's and only the grounding text is the older per-shape one.
    # verify/ordercheck.py reads these 20 rows as exactly those cells.
    MP|LB|S|SB|R)
      case "$order" in
        acqrel) two_sided_order_pair "$shape" "$cuttag" ra ra;;
        fence)  two_sided_order_pair "$shape" "$cuttag" sy sc;;
        *) echo "build-nvidia-oracle: unhandled two-sided order '$order' ($name)" >&2; exit 1;;
      esac
      SOURCE="${TWOSIDED_SRC[$shape:$order]}";;
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
# Advisory (not fatal): a comma inside a free-text Source string splits it
# across CSV fields 4..n.  Fields 1-3 stay correct, but anything reading a
# single column sees a truncated Source.  38 baseline strings do this and are
# kept byte-stable on purpose; the order-pair strings are comma-free, and
# printing the count makes any growth visible.
ncomma=$(grep -vE '^#|^Litmus,' "$OUT" | awk -F, 'NF>4' | wc -l)
echo "note: $ncomma row(s) have a comma inside the Source string (advisory)" >&2
