# shellcheck shell=bash
# HetLitmus corpus grid library -- shared by tests/gpu-only/generate.sh and
# tests/het/generate.sh.  Pure bash (associative arrays => needs bash >= 4).
#
# Defines the standard litmus SHAPE catalogue (closed critical cycles, expressed
# in diy's architecture-agnostic edge vocabulary), the canonical heterogeneous
# device cuts per shape, and the renderer that turns a base cycle into the
# scope x order annotated LISA/Bell edge cycle that diyone7/hetgen7 consume.
#
# The annotation grid is  scope in {cta,gpu,sys}  x  order in
# {relaxed,acquire,release,fence}.  The mapping (matching the GPU-only corpus
# convention) is: reads carry acquire|relaxed, writes carry release|relaxed; the
# `fence' column keeps every access relaxed and instead inserts a standalone
# scoped fence (`f[sc,<scope>]') between the two accesses of each proc, by
# swapping each intra-proc program-order edge `Pod<XY>' for the Bell fence edge
# `FenceSc<Scope>d<XY>' (diy already supports this -- no generator code change).
#
# See hetlitmus/docs/corpus-grid.md.

# --- shape catalogue: cycle (base edges) + proc count -----------------------
# Base-edge vocabulary used here:
#   Pod<XY>  intra-proc program order, X->Y, different location (X,Y in {W,R})
#   Rfe      read-from external          (W -> R)
#   Fre      from-read external          (R -> W)
#   Coe      coherence-order external    (W -> W)
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
)
declare -A SHAPE_NPROCS=(
  [MP]=2 [SB]=2 [LB]=2 [2+2W]=2 [R]=2 [S]=2
  [WRC]=3 [RWC]=3 [ISA2]=3
  [IRIW]=4 [WRC3]=4
)

# Generation order (associative arrays are unordered in bash).
SHAPE_ORDER="MP SB LB 2+2W R S WRC RWC ISA2 IRIW WRC3"

# --- heterogeneous device cuts (settled decision #1) ------------------------
# ROLE-BASED, symmetry-reduced -- NOT 2^n.  2-proc shapes: both directions.
# 3-proc shapes (distinct roles): each proc, in turn, is the single GPU
# participant.  4-proc shapes: IRIW (2 symmetric writers + 2 symmetric readers)
# uses FOUR cuts {one writer, one reader, both writers, both readers} on the GPU
# -- these are four of IRIW's EIGHT symmetry classes (Q10 sect 2.2, measured
# with Q10-probe/canon.py --cuts), not all of them: the mixed writer+reader cuts
# are not generated; WRC3 (a 4-stage causal chain, all roles distinct) puts each
# chain stage, in turn, on the GPU.
declare -A SHAPE_HET_CUTS=(
  [MP]="cpu,gpu gpu,cpu"
  [SB]="cpu,gpu gpu,cpu"
  [LB]="cpu,gpu gpu,cpu"
  [2+2W]="cpu,gpu gpu,cpu"
  [R]="cpu,gpu gpu,cpu"
  [S]="cpu,gpu gpu,cpu"
  [WRC]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [RWC]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [ISA2]="gpu,cpu,cpu cpu,gpu,cpu cpu,cpu,gpu"
  [IRIW]="cpu,gpu,cpu,cpu gpu,cpu,cpu,cpu cpu,gpu,cpu,gpu gpu,cpu,gpu,cpu"
  [WRC3]="gpu,cpu,cpu,cpu cpu,gpu,cpu,cpu cpu,cpu,gpu,cpu cpu,cpu,cpu,gpu"
)

GRID_SCOPES="cta gpu sys"
GRID_ORDERS="relaxed acquire release fence"

# Two-sided het orders: the COMPLETE morally-strong pairings, applied to BOTH
# devices at sys scope so the cross-device pair actually closes (see the het
# generate.sh "(D) two-sided" section and docs/het-oracle.md).
#   acqrel : reads -> acquire, writes -> release   (forbids MP-family + LB)
#   fence  : DMB.SY (CPU) + fence.sc.sys (GPU)      (also forbids SB/R/RWC)
TWO_SIDED_ORDERS="acqrel fence"

# --- helpers ----------------------------------------------------------------

# scope_cc <scope>  ->  CamelCase scope token used inside edge names
scope_cc() { case "$1" in cta) echo Cta;; gpu) echo Gpu;; sys) echo Sys;;
  *) echo "bad scope: $1" >&2; return 1;; esac; }

# edge_src_dst <base-edge>  -> sets globals SRC,DST (each W or R) and IS_PO (0/1)
edge_src_dst() {
  case "$1" in
    Pod??) local xy=${1#Pod}; SRC=${xy:0:1}; DST=${xy:1:1}; IS_PO=1;;
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
#   acqrel        : reads -> Acquire, writes -> Release  (the COMPLETE morally-
#                   strong release/acquire pair -- used by the TWO-SIDED het
#                   variants, where it is applied to BOTH devices so both halves
#                   of the pair are present; see render_cpu_cycle and the het
#                   generate.sh "(D) two-sided" section)
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
# Annotation of each shared event is identical from both adjacent edges (it is
# fixed by the event's W/R direction + the scope + the order profile), so the
# cycle is always atom-consistent for diy.
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
      base="FenceSc${SC}d${e#Pod}"
    fi
    out="$out ${base}${os}${SC}${od}${SC}"
  done
  echo "${out# }"
}

# --- CPU (AArch64) annotator: the OTHER half of the morally-strong pair --------
# The het generator runs the cycle engine once per device; the CPU run gets its
# edge cycle from hetgen7's `-cpu <edges>' (parsed VERBATIM by the AArch64
# builder -- no OCaml change).  By default generate.sh passes the PLAIN base
# cycle there, so every CPU proc is a plain ARMv9 ld/st and a GPU sys
# release/acquire on the other proc can never CLOSE the morally-strong pair the
# CMCM needs to cut a cycle (the GH200 CPU is ARMv9, not x86, so it supplies no
# implicit acquire/release -- Bagchi ISMM'26 Fig 1, CMCM PLDI'23 Fig 2a).  The
# TWO-SIDED variants instead pass an ANNOTATED CPU cycle here, so the CPU proc
# carries its half of the pair and a complete cross-device pair can form.
#
# INSTRUCTION MAPPING (grounded; see hetlitmus/docs/het-oracle.md "Mapping"):
#   release  -> STLR    (ARM store-release; Bagchi Fig 1 shows the GH200
#                        toolchain compiling C++ memory_order_release to STLR)
#   acquire  -> LDAPR   (ARM RCpc load-acquire; GCC>=13.1/LLVM>=16 emit LDAPR for
#                        std::atomic acquire on -mcpu=neoverse-v* (Grace = Armv9
#                        Neoverse V2, FEAT_LRCPC); RCpc matches C++/PTX acquire,
#                        whereas LDAR/RCsc would OVER-strengthen and wrongly
#                        forbid SB/R/RWC -- see the doc)
#   fence    -> DMB.SY  (full system barrier; Bagchi Fig 2c uses DMB to order
#                        store->load)
# ARM ops are scope-free: an unscoped ARM access is treated as SYSTEM scope
# (Bagchi 3.2), so no scope token is appended (unlike the GPU/Bell side).
#
# diy atom letters (probed via `diyone7 -arch AArch64 -show annotations'):
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
#   acqrel   : every read -> LDAPR (Q), every write -> STLR (L)  (atom on each end)
#   fence    : every access plain; each intra-proc Pod<XY> becomes the full-barrier
#              edge `DMB.SYd<XY>' (emits a DMB SY between the two accesses); the
#              external edges (Rfe/Fre/Coe) stay bare (their plain ends agree with
#              the adjacent atoms -- verified with diyone7).
#   fence-st : the same, with the PARTIAL barrier `DMB.STd<XY>' (DMB ST orders
#   fence-ld   store->store only) resp. `DMB.LDd<XY>' (DMB LD orders load->load
#              and load->store only).  These are the CPU one-role halves that
#              Q10b unblocked -- diy has always generated them (`diyone7 -arch
#              AArch64 -show fences'); what was missing was litmus7 emission
#              (litmus/hetCpuBody.ml, Q10b c1).  Only the (E) order-pair grid
#              uses them; (D) still pairs `acqrel'/`fence' on both devices.
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
      if [ "$IS_PO" = 1 ]; then base="${fb}d${e#Pod}"; else base="$e"; fi
      out="$out $base"
    else
      as=$(arm_ord "$SRC" "$order") || return 1
      ad=$(arm_ord "$DST" "$order") || return 1
      out="$out ${e}${as}${ad}"
    fi
  done
  echo "${out# }"
}

# --- Q10: the two-sided ORDER-PAIR grid (off-diagonal) ----------------------
# TWO_SIDED_ORDERS above pairs each device with the SAME order name, so only the
# two DIAGONAL cells of the pairing grid were ever generated.  Nothing in the
# argument for restricting to sys scope and to complete pairings excludes the
# off-diagonal, and the per-side ordering a primitive supplies depends on WHICH
# program-order pair its proc has -- a release fence on a load;load consumer
# orders nothing, RCpc STLR->LDAPR never orders store->load.  So sweep the grid
# (Q10 sect 5 steps 1-3).  Name token `<cpu>.<gpu>':
#
#   cpu  ra -> STLR / LDAPR atoms (== the `acqrel' CPU half)
#        sy -> DMB SY             (== the `fence'  CPU half)
#        st -> DMB ST             ld -> DMB LD          [Q10b]
#   gpu  ra -> w[release,sys] / r[acquire,sys] atoms
#        sc -> f[sc,sys]          rel -> f[release,sys]   acq -> f[acquire,sys]
#
# The two DIAGONAL cells are NOT re-emitted: `ra.ra' IS <shape>-<cut>-sys-acqrel-2s
# and `sy.sc' IS <shape>-<cut>-sys-fence-2s.  generate.sh PROVES that (byte-diff
# against the committed file) rather than assuming it.  `st'/`ld' have no
# pre-existing sibling, so no diagonal cell is skipped for them: the grid is
# 4 x 4 = 16 cells per cut class, of which 2 are the (D) diagonal -> 14 emitted.
#
# Q10b LIFTED THE BLOCKED AXIS.  Until Q10b the CPU axis was `ra sy' only -- not
# because diy could not generate DMB.ST/DMB.LD (it always could: `diyone7 -arch
# AArch64 -show fences') nor because the oracle could not decide them (the rule
# and ordercheck.py always did), but because litmus/hetCpuBody.ml accepted only
# `DMB SY'/`DSB SY' and Warn.fatal'd on any other I_FENCE, so the tests could
# not be EMITTED.  Two match arms lifted it; the axis is now 4 wide.
#
# `f[acq_rel,sys]' is still unavailable: `FenceAcq_relSys' does not lex as a
# diy edge name (the underscore breaks the edge lexer) -- verified with diyone7.
TWO_SIDED_CPU_ORDERS="ra sy st ld"
TWO_SIDED_GPU_ORDERS="ra sc rel acq"

# Shapes + cuts for the off-diagonal sweep.  2-proc only: NO-ORACLE is a
# property of the SHAPE (a 3/4-proc two-sided test needs cross-device MCA or
# A-cumulativity, which Bagchi ISMM'26 sect 2.1 defers), so no annotation on a
# transitive shape can produce a Disallowed row -- Q10 sect 3.  2+2W is excluded
# for the same reason (its cycle is two `co' edges with no `rf' at all).
# SB and LB emit ONE cut: their cycle is invariant under rotation-by-two, which
# swaps P0/P1, and the annotation follows the DEVICE rather than the proc index,
# so `gc' would be `cg' with the labels exchanged -- an exact duplicate.
# verify/dupcheck.py is what holds that honest.
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
# standalone fence event, exactly as the `fence' column does; `Sc' reproduces
# `render_cycle sys fence' token for token.
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
    [ "$IS_PO" = 1 ] && base="Fence${o}Sysd${e#Pod}"
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
