# shellcheck shell=bash
# HetLitmus corpus grid library -- shared by tests/gpu-only/generate.sh and
# tests/het/generate.sh.  Pure bash (associative arrays => needs bash >= 4).
#
# Defines the litmus shape catalogue (closed critical cycles in diy's
# architecture-agnostic edge vocabulary), the canonical heterogeneous device
# cuts per shape, and the renderers that turn a base cycle into the annotated
# edge cycle diyone7/hetgen7 consume -- LISA/Bell for GPU procs, AArch64 for
# CPU procs.  The GPU annotation grid is scope in {cta,gpu,sys} x order in
# {relaxed,acquire,release,fence}.
#
# The grid rule and its rationale: hetlitmus/docs/corpus-grid.md.

# --- shape catalogue: cycle (base edges) + proc count -----------------------
# Base-edge vocabulary used here, with L the location letter (d = different
# location, s = same location):
#   Po<L><XY>  intra-proc program order, X->Y  (X,Y in {W,R})
#   Rfe        read-from external          (W -> R)
#   Fre        from-read external          (R -> W)
#   Coe        coherence-order external    (W -> W)
# A cycle whose program-order edges are all `Pos' touches one location, which
# diy refuses unless the driver passes `-oneloc'.
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
# Role-based and symmetry-reduced, NOT 2^n.  2-proc shapes take both directions
# except SB / LB / 2+2W, whose cycle is invariant under rotation-by-two (it
# swaps P0/P1, and the annotation follows the device rather than the proc
# index), so those emit one cut and verify/dupcheck.py holds that honest.
# 3-proc shapes (distinct roles) put each proc in turn on the GPU; IRIW (2
# symmetric writers + 2 symmetric readers) takes four of its eight symmetry
# classes {one writer, one reader, both writers, both readers}; WRC3 (4-stage
# causal chain) puts each chain stage in turn on the GPU.  The rule and its
# rationale: hetlitmus/docs/corpus-grid.md, "Heterogeneous device cuts".
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

# --- helpers ----------------------------------------------------------------

# scope_cc <scope>  ->  CamelCase scope token used inside edge names
scope_cc() { case "$1" in cta) echo Cta;; gpu) echo Gpu;; sys) echo Sys;;
  *) echo "bad scope: $1" >&2; return 1;; esac; }

# edge_src_dst <base-edge>  -> sets globals SRC,DST (each W or R), IS_PO (0/1)
# and, for an intra-proc edge, its location letter PO_LOC (d|s) plus access
# suffix PO_XY.  A fence edge is spelled <fence><PO_LOC><PO_XY>, so the letter
# travels with the edge instead of being fixed at each call site.  PO_LOC and
# PO_XY are cleared before the case, so a caller that reads them without
# checking IS_PO cannot pick up the previous edge's letters.
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
#   relaxed/fence : everything relaxed (fence supplies ordering via a fence event)
#   acquire       : reads -> Acquire, writes -> Relaxed
#   release       : writes -> Release, reads -> Relaxed
#   acqrel        : reads -> Acquire, writes -> Release -- the complete
#                   release/acquire pair, used only by the two-sided variants
#                   (which apply it to both devices; cf. render_cpu_cycle)
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

# --- CPU (AArch64) annotator: the other half of the morally-strong pair -------
# hetgen7's `-cpu <edges>' is parsed verbatim by the AArch64 builder.  Passing
# the plain base cycle (the one-sided default) leaves every CPU proc a plain
# ARMv9 ld/st, so a GPU sys release/acquire can never close a morally-strong
# pair: the GH200 CPU is ARMv9, not x86, and supplies no implicit
# acquire/release.  The two-sided variants pass an annotated CPU cycle instead.
#
# Instruction mapping: release -> STLR, acquire -> LDAPR (RCpc, not RCsc),
# fence -> DMB.SY.  ARM ops are scope-free -- unscoped is treated as system
# scope -- so no scope token is appended, unlike the GPU/Bell side.
#
# diy atom letters (`diyone7 -arch AArch64 -show annotations'):
#   L = release (STLR) ; Q = LDAPR (RCpc acquire) ; A = LDAR (RCsc, unused).

# arm_ord <dir W|R> <order>  ->  AArch64 diy atom letter for that access
#   acqrel : reads -> Q (LDAPR) , writes -> L (STLR)   [the complete pair]
arm_ord() {
  case "$2" in
    acqrel) [ "$1" = R ] && echo Q || echo L;;
    *) echo "bad cpu order: $2 (only acqrel uses per-access atoms)" >&2; return 1;;
  esac
}

# render_cpu_cycle <order> <base-edge>...  ->  annotated AArch64 edge token list
# (the CPU-side mirror of render_cycle, but with ARM atoms and NO scope).
#   acqrel   : every read -> LDAPR (Q), every write -> STLR (L)  (atom per end)
#   fence    : every access plain; each intra-proc Po<L><XY> becomes the
#              full-barrier edge `DMB.SY<L><XY>'.  External edges (Rfe/Fre/Coe)
#              stay bare: their plain ends agree with the adjacent atoms.
#   fence-st : the same with the partial barriers `DMB.ST<L><XY>' (orders
#   fence-ld   store->store only) and `DMB.LD<L><XY>' (load->load and
#              load->store only) -- the CPU one-role halves, used only by the
#              order-pair grid (the two-sided family stays on acqrel/fence).
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

# --- the two-sided order-pair grid (off-diagonal) ---------------------------
# TWO_SIDED_ORDERS above gives each device the same order name, i.e. only the
# two diagonal cells of a pairing grid.  The ordering a primitive supplies
# depends on which program-order pair its proc has -- a release fence on a
# load;load consumer orders nothing, RCpc STLR->LDAPR never orders store->load
# -- so the off-diagonal is swept too.  Name token `<cpu>.<gpu>':
#
#   cpu  ra -> STLR / LDAPR atoms      sy -> DMB SY
#        st -> DMB ST                  ld -> DMB LD
#   gpu  ra -> w[release,sys] / r[acquire,sys] atoms
#        sc -> f[sc,sys]   rel -> f[release,sys]   acq -> f[acquire,sys]
#
# 4 x 4 = 16 cells per cut class, of which 2 are the diagonal (`ra.ra' IS
# <shape>-<cut>-sys-acqrel-2s, `sy.sc' is <shape>-<cut>-sys-fence-2s) -> 14
# emitted; generate.sh byte-diffs the two rather than assuming the identity.
#
# `f[acq_rel,sys]' is unavailable: `FenceAcq_relSys' does not lex as a diy edge
# name (the underscore breaks the edge lexer).
TWO_SIDED_CPU_ORDERS="ra sy st ld"
TWO_SIDED_GPU_ORDERS="ra sc rel acq"

# Shapes + cuts for the off-diagonal sweep.  What it has to cover is the
# (primitive, program-order pair) product, since the pair a proc carries is what
# decides what its primitive orders (note above).  These five 2-proc shapes
# already realise all four Pod kinds -- WW RR WR RW -- on the CPU side and all
# four on the GPU side, so no further shape adds a combination.  Two procs also
# keep a cell legible: one cpu and one gpu token per test, so a 3- or 4-proc cut
# would put a single token on several procs at once.  SB and LB emit one cut,
# for the rotation-by-two reason recorded at SHAPE_HET_CUTS above.  A `Pos'
# shape stays out: only one of its procs carries a program-order pair.
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
