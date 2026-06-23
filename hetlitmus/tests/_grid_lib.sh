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
# uses the four symmetry-class cuts {one writer, one reader, both writers, both
# readers} on the GPU; WRC3 (a 4-stage causal chain, all roles distinct) puts
# each chain stage, in turn, on the GPU.
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
ord_for() {
  case "$2" in
    relaxed|fence) echo Relaxed;;
    acquire) [ "$1" = R ] && echo Acquire || echo Relaxed;;
    release) [ "$1" = W ] && echo Release || echo Relaxed;;
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
