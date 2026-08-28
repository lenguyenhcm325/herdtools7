# shellcheck shell=bash
# HetLitmus corpus grid library -- shared by tests/gpu-only/generate.sh,
# tests/het/generate.sh and tests/het/generate-x86.sh.  Pure bash (associative
# arrays => needs bash >= 4).  It holds the shape catalogue, the canonical
# device cuts per shape, and the renderers that turn a base cycle into the
# annotated edge cycle diyone7/hetgen7 consume: LISA/Bell for GPU procs,
# AArch64 for CPU procs.  The one-sided scope x order grid and its rationale:
# hetlitmus/docs/corpus-grid.md; the two-sided families are specified here,
# beside the knob that drives each.

# --- shape catalogue: cycle (base edges) + proc count -----------------------
# Base-edge vocabulary (Po<L><XY>, Rfe, Fre, Coe) and the `-oneloc' rule an
# all-`Pos' cycle needs: hetlitmus/docs/corpus-grid.md, "The shape catalogue".
declare -A SHAPE_CYCLE=(
  [MP]="PodWW Rfe PodRR Fre"
  [SB]="PodWR Fre PodWR Fre"
  [LB]="PodRW Rfe PodRW Rfe"
  [2+2W]="PodWW Coe PodWW Coe"
  [R]="PodWW Coe PodWR Fre"
  [S]="PodWW Rfe PodRW Coe"
  [WRC]="Rfe PodRW Rfe PodRR Fre"
  [RWC]="Rfe PodRR Fre PodWR Fre"
  [ISA2]="PodWW Rfe PodRW Rfe PodRR Fre"
  [IRIW]="Rfe PodRR Fre Rfe PodRR Fre"
  [WRC3]="Rfe PodRW Rfe PodRW Rfe PodRR Fre"
  [CoRR]="Rfe PosRR Fre"
  [CoWR]="PosWR Fre Coe"
  [CoRW2]="Rfe PosRW Coe"
)
declare -A SHAPE_NPROCS=(
  [MP]=2 [SB]=2 [LB]=2 [2+2W]=2 [R]=2 [S]=2 [CoRR]=2 [CoWR]=2 [CoRW2]=2
  [WRC]=3 [RWC]=3 [ISA2]=3
  [IRIW]=4 [WRC3]=4
)

# Generation order (associative arrays are unordered in bash).
SHAPE_ORDER="MP SB LB 2+2W R S WRC RWC ISA2 IRIW WRC3 CoRR CoWR CoRW2"

# --- heterogeneous device cuts ----------------------------------------------
# Role-based and symmetry-reduced, NOT 2^n; SB / LB / 2+2W emit one cut because
# their cycle is invariant under rotation-by-two, which swaps P0/P1.  The rule
# per shape: hetlitmus/docs/corpus-grid.md, "Heterogeneous device cuts".
declare -A SHAPE_HET_CUTS=(
  [MP]="cpu,gpu gpu,cpu"
  [SB]="cpu,gpu"
  [LB]="cpu,gpu"
  [2+2W]="cpu,gpu"
  [R]="cpu,gpu gpu,cpu"
  [S]="cpu,gpu gpu,cpu"
  [WRC]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [RWC]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [ISA2]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [IRIW]="cpu,gpu,cpu,cpu gpu,cpu,cpu,cpu cpu,gpu,cpu,gpu gpu,cpu,gpu,cpu"
  [WRC3]="gpu,cpu,cpu,cpu cpu,gpu,cpu,cpu cpu,cpu,gpu,cpu cpu,cpu,cpu,gpu"
  [CoRR]="cpu,gpu gpu,cpu"
  [CoWR]="cpu,gpu gpu,cpu"
  [CoRW2]="cpu,gpu gpu,cpu"
)

GRID_SCOPES="cta gpu sys"
GRID_ORDERS="relaxed acquire release fence"

# Two-sided het orders: the complete morally-strong pairings, applied to BOTH
# devices at sys scope so the cross-device pair closes.
#   acqrel : reads -> acquire, writes -> release
#   fence  : DMB.SY (CPU) + fence.sc.sys (GPU)
TWO_SIDED_ORDERS="acqrel fence"

# two_sided_cpu_tok <two-sided order>  ->  the CPU token render_x86_cpu takes,
# the inverse of render_2s_cpu's `ra'/`sy' rows; it lives beside the list above
# so an added order has ONE place to fail closed.
two_sided_cpu_tok() {
  case "$1" in
    acqrel) echo ra;;
    fence)  echo sy;;
    *) echo "unknown two-sided order: $1" >&2; return 1;;
  esac
}

# --- helpers ----------------------------------------------------------------

# scope_cc <scope>  ->  CamelCase scope token used inside edge names
scope_cc() { case "$1" in cta) echo Cta;; gpu) echo Gpu;; sys) echo Sys;;
  *) echo "bad scope: $1" >&2; return 1;; esac; }

# edge_src_dst <base-edge>  -> sets globals SRC,DST (each W or R), IS_PO (0/1)
# and, for an intra-proc edge, its location letter PO_LOC (d|s) plus access
# suffix PO_XY -- a fence edge is spelled <fence><PO_LOC><PO_XY>.  PO_LOC/PO_XY
# are cleared first, so a caller that reads them without checking IS_PO cannot
# pick up the PREVIOUS edge's letters.
edge_src_dst() {
  PO_LOC=""; PO_XY=""
  case "$1" in
    Po[ds]??) PO_LOC=${1:2:1}; PO_XY=${1:3:2}
              SRC=${PO_XY:0:1}; DST=${PO_XY:1:1}; IS_PO=1;;
    Rfe)   SRC=W; DST=R; IS_PO=0;;
    Fre)   SRC=R; DST=W; IS_PO=0;;
    Coe)   SRC=W; DST=W; IS_PO=0;;
    *) echo "unknown base edge: $1" >&2; return 1;;
  esac
}

# ord_for <dir W|R> <order>  ->  CamelCase order token for that access
#   relaxed/fence : everything relaxed (a fence event supplies the ordering)
#   acquire : reads -> Acquire ; release : writes -> Release
#   acqrel  : reads -> Acquire AND writes -> Release, the complete pair, used
#             only by the two-sided variants (cf. render_cpu_cycle)
ord_for() {
  case "$2" in
    relaxed|fence) echo Relaxed;;
    acquire) [ "$1" = R ] && echo Acquire || echo Relaxed;;
    release) [ "$1" = W ] && echo Release || echo Relaxed;;
    acqrel)  [ "$1" = R ] && echo Acquire || echo Release;;
    *) echo "bad order: $2" >&2; return 1;;
  esac
}

# render_cycle <scope> <order> <base-edge>...  ->  annotated edge token list
# Each shared event's annotation is fixed by its W/R direction + scope + order
# profile, so both adjacent edges spell it identically and the cycle is always
# atom-consistent for diy.
render_cycle() {
  local scope="$1" order="$2"; shift 2
  local SC; SC=$(scope_cc "$scope") || return 1
  local out="" e os od base
  for e in "$@"; do
    edge_src_dst "$e" || return 1
    os=$(ord_for "$SRC" "$order"); od=$(ord_for "$DST" "$order")
    base="$e"
    if [ "$order" = fence ] && [ "$IS_PO" = 1 ]; then
      # standalone scoped fence between the two (relaxed) accesses of this proc
      base="FenceSc${SC}${PO_LOC}${PO_XY}"
    fi
    out="$out ${base}${os}${SC}${od}${SC}"
  done
  echo "${out# }"
}

# -----------------------------------------------------------------------------
# CPU (AArch64) annotator, the other half of the morally-strong pair.  hetgen7's
# `-cpu <edges>' is parsed verbatim, so the one-sided default leaves every CPU
# proc a plain ARMv9 ld/st and closes no cross-device pair.  ARM ops are
# scope-free, so no scope token is appended.  Mapping: hetlitmus/docs/faithfulness.md.
# diy atom letters: L = release (STLR), Q = LDAPR (RCpc acquire), A = LDAR.

# arm_ord <dir W|R> <order>  ->  AArch64 diy atom letter for that access
#   acqrel : reads -> Q (LDAPR) , writes -> L (STLR)   [the complete pair]
arm_ord() {
  case "$2" in
    acqrel) [ "$1" = R ] && echo Q || echo L;;
    *) echo "bad cpu order: $2 (only acqrel uses per-access atoms)" >&2; return 1;;
  esac
}

# render_cpu_cycle <order> <base-edge>...  ->  annotated AArch64 edge token list
#   acqrel            : every read -> Q, every write -> L
#   fence             : accesses plain, each intra-proc Po<L><XY> becomes
#                       `DMB.SY<L><XY>', external edges bare
#   fence-st/fence-ld : the same with `DMB.ST' / `DMB.LD'
render_cpu_cycle() {
  local order="$1"; shift
  local out="" e as ad base fb=""
  case "$order" in
    fence)    fb=DMB.SY;;
    fence-st) fb=DMB.ST;;
    fence-ld) fb=DMB.LD;;
  esac
  for e in "$@"; do
    edge_src_dst "$e" || return 1
    if [ -n "$fb" ]; then
      if [ "$IS_PO" = 1 ]; then base="${fb}${PO_LOC}${PO_XY}"; else base="$e"; fi
      out="$out $base"
    else
      as=$(arm_ord "$SRC" "$order") || return 1
      ad=$(arm_ord "$DST" "$order") || return 1
      out="$out ${e}${as}${ad}"
    fi
  done
  echo "${out# }"
}

# -----------------------------------------------------------------------------
# The two-sided order-pair grid (off-diagonal), named `<cpu>.<gpu>'; the token
# table and the exclusions: hetlitmus/docs/corpus-grid.md, "The two-sided families".
TWO_SIDED_CPU_ORDERS="ra sy st ld"
TWO_SIDED_GPU_ORDERS="ra sc rel acq"

# Shapes + cuts for the off-diagonal sweep, one cpu and one gpu token per test
# (why these shapes and cuts: corpus-grid.md, "The two-sided families").
TWO_SIDED_PAIR_SHAPES="MP SB LB R S"
declare -A SHAPE_2S_PAIR_CUTS=(
  [MP]="cpu,gpu gpu,cpu"
  [SB]="cpu,gpu"
  [LB]="cpu,gpu"
  [R]="cpu,gpu gpu,cpu"
  [S]="cpu,gpu gpu,cpu"
)

# render_2s_cpu <cpu-tok> <base-edge>...  ->  AArch64 edge token list
render_2s_cpu() {
  local t="$1"; shift
  case "$t" in
    ra) render_cpu_cycle acqrel   "$@";;
    sy) render_cpu_cycle fence    "$@";;
    st) render_cpu_cycle fence-st "$@";;
    ld) render_cpu_cycle fence-ld "$@";;
    *) echo "bad two-sided cpu order: $t" >&2; return 1;;
  esac
}

# render_2s_gpu <gpu-tok> <base-edge>...  ->  Bell/LISA edge token list.
# `sc|rel|acq' keep every access relaxed at sys scope and put the ordering in a
# standalone `Fence<o>Sys<L><XY>' event, as the `fence' column does; `sc'
# reproduces `render_cycle sys fence' token for token.
render_2s_gpu() {
  local t="$1"; shift
  local o
  case "$t" in
    ra)  render_cycle sys acqrel "$@"; return;;
    sc)  o=Sc;;
    rel) o=Release;;
    acq) o=Acquire;;
    *) echo "bad two-sided gpu order: $t" >&2; return 1;;
  esac
  local out="" e base
  for e in "$@"; do
    edge_src_dst "$e" || return 1
    base="$e"
    [ "$IS_PO" = 1 ] && base="Fence${o}Sys${PO_LOC}${PO_XY}"
    out="$out ${base}RelaxedSysRelaxedSys"
  done
  echo "${out# }"
}

# scope_tree <nprocs>  ->  parseable `scopes:' tree, each proc in its own CTA
# (matches the GPU-only convention: cta-scope sync is then too narrow to cross
# threads, so it does not fire -- scope strength is read, not assumed).
scope_tree() {
  local n="$1" inner="" i
  for ((i=0; i<n; i++)); do inner="$inner (cta $i)"; done
  echo "(sys (gpu${inner}))"
}

# cut_tag <devices>   e.g. cpu,gpu -> cg ; gpu,cpu,cpu -> gcc
cut_tag() { echo "$1" | sed 's/cpu/c/g; s/gpu/g/g; s/,//g'; }
