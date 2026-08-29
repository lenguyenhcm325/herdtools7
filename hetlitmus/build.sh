#!/usr/bin/env bash
# Build every harness dir of EMIT: `make clean' then `make <vendor>-bin' in each,
# with the device arch exported.  The clean is NOT optional -- a `-D' knob
# touches no source, so make alone would keep objects built with the old knobs.
# Each worker writes $RESULTS/build/<t>.log and <t>.rc; the failure table is
# tabulated from the .rc files, since xargs reports 123 rather than a count.
#
# usage: build.sh EMIT [--tests LIST|FILE] [--arch A] [-j N]
# Exit: 0 = every dir built; 1 = one did not; 2 = bad argument, arch or toolchain.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

usage() { echo "usage: build.sh EMIT [--tests LIST|FILE] [--arch A] [-j N]" >&2 ; }
refuse() { echo "build: REFUSING -- $*" >&2 ; exit 2 ; }
need()   { [ "$2" -ge 2 ] || { usage ; refuse "$1 needs a value" ; } ; }

EMIT="" ; TESTS="" ; ARCH="" ; J=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tests) need "$1" $# ; TESTS="$2" ; shift 2 ;;
    --arch)  need "$1" $# ; ARCH="$2"  ; shift 2 ;;
    -j)      need "$1" $# ; J="$2"     ; shift 2 ;;
    -h|--help) usage ; exit 0 ;;
    -*)      usage ; refuse "unknown argument \"$1\"" ;;
    *)  [ -z "$EMIT" ] || { usage ; refuse "one EMIT per run, not \"$EMIT\" and \"$1\"" ; }
        EMIT="$1" ; shift ;;
  esac
done
[ -n "$EMIT" ] || { usage ; refuse "EMIT is mandatory" ; }
[ -d "$EMIT" ] || refuse "EMIT $EMIT is not a directory"
EMIT="$(cd "$EMIT" && pwd)"
[ -n "$J" ] || J="$( (nproc 2>/dev/null || echo 4) )"
echo "$J" | grep -qE '^[1-9][0-9]*$' || refuse "-j \"$J\" is not a positive integer"

RESULTS="${RESULTS:-$HETL/run-out/$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"
mkdir -p "$RESULTS/build"
RESULTS="$(cd "$RESULTS" && pwd)"

# --tests as a comma list or as a file with one name per line, `#' and blanks
# ignored -- the first field of a line is the name.
name_list() {                   # <LIST|FILE>
  if [ -f "$1" ]; then
    awk 'NF && $1 !~ /^#/ { print $1 }' "$1"
  else
    printf '%s\n' "$1" | tr ',' '\n' | awk 'NF { print $1 }'
  fi
}
if [ -n "$TESTS" ]; then
  # A name listed twice would be two workers running make clean in one dir.
  RAW="$(name_list "$TESTS")"
  LIST="$(printf '%s\n' "$RAW" | awk '!seen[$0]++')"
  DUP="$(printf '%s\n' "$RAW" | sort | uniq -d | paste -sd ' ')"
  [ -z "$DUP" ] || echo "build: --tests names $DUP more than once; one build each"
else
  LIST="$(cd "$EMIT" && ls -1d ./*/ 2>/dev/null | sed 's|^\./||; s|/$||' || true)"
fi
[ -n "$LIST" ] || refuse "no harness dir under $EMIT -- emit the corpus first"

# The vendor is the render each dir carries, and one run builds one vendor: the
# arch is a single value and the two dialects do not share a spelling for it.
VENDOR=""
for t in $LIST; do
  d="$EMIT/$t"
  [ -d "$d" ] || refuse "$EMIT holds no harness dir $t"
  v=""
  if [ -f "$d/$t.cu" ]; then v="cuda" ; fi
  if [ -f "$d/$t.hip" ]; then
    [ -z "$v" ] || refuse "$t carries both a .cu and a .hip render, so it names no vendor"
    v="hip"
  fi
  [ -n "$v" ] || refuse "$t carries neither a .cu nor a .hip render, so it names no vendor"
  if [ -z "$VENDOR" ]; then
    VENDOR="$v" ; VENDOR_FIRST="$t"
  elif [ "$v" != "$VENDOR" ]; then
    refuse "$EMIT mixes vendors: $t renders $v and $VENDOR_FIRST renders $VENDOR. \
One build carries one arch, so emit one dialect per directory."
  fi
done

if [ "$VENDOR" = cuda ]; then
  COMPILER="${NVCC:-nvcc}" ; ARCH_VAR=CUDA_ARCH ; ARCH_RE='^sm_[0-9]+[a-z]?$'
  ARCH_SHAPE='sm_XX' ; PROBE_KEY=suggested_cuda_arch
else
  COMPILER="${HIPCC:-hipcc}" ; ARCH_VAR=HIP_ARCH ; ARCH_RE='^gfx[0-9a-f]+$'
  ARCH_SHAPE='gfxXXX' ; PROBE_KEY=suggested_hip_arch
fi
# The compiler variable may carry flags (`NVCC="nvcc -DHET_LLC_MB=256"'), which
# make expands into the command line: only its first word is a program name.
CBIN="${COMPILER%% *}"
# command -v alone resolves a builtin or function, which compiles nothing.
[ -x "$(command -v "$CBIN" 2>/dev/null || true)" ] \
  || refuse "$CBIN does not resolve to an executable, and the $VENDOR harnesses are built with it"

# The probe is the ONLY other source of an arch, and it writes literal NONE and
# AMBIGUOUS(...) values, which the shape check below rejects like any other.
PROBE="$RESULTS/probe.txt"
if [ -n "$ARCH" ]; then
  ARCH_SOURCE="explicit (--arch)"
  [ "$ARCH" != native ] || refuse "--arch native is not accepted: the arch a binary \
was built for must be a recorded value, and 'native' records nothing"
else
  [ -r "$PROBE" ] || refuse "no --arch and no probe record at $PROBE -- run \
probe-cuda.sh or probe-hip.sh into this results dir first, or pass --arch $ARCH_SHAPE"
  ARCH="$(sed -n "s/^$PROBE_KEY=//p" "$PROBE" | head -1)"
  ARCH_SOURCE="$PROBE ($PROBE_KEY)"
  [ -n "$ARCH" ] || refuse "$PROBE carries no $PROBE_KEY, so it names no device to build for"
fi
echo "$ARCH" | grep -qE "$ARCH_RE" \
  || refuse "\"$ARCH\" from $ARCH_SOURCE is not a $VENDOR architecture (want $ARCH_SHAPE)"

CVER="$( { "$CBIN" --version 2>/dev/null || true ; } \
         | grep -m1 -E 'release|HIP version|clang version' || true )"
[ -n "$CVER" ] || CVER="$( { "$CBIN" --version 2>/dev/null || true ; } | sed -n '1p' )"
[ -n "$CVER" ] || CVER="unknown"

build_one() {                   # <test> -- one dir, its own log and its own .rc
  t="$1" ; rc=0
  ( cd "$BUILD_EMIT/$t" && export "$BUILD_ARCH_VAR=$BUILD_ARCH" \
      && make clean && make "$BUILD_VENDOR-bin" ) \
    > "$BUILD_RESULTS/build/$t.log" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$BUILD_RESULTS/build/$t.rc"
}
export -f build_one
export BUILD_EMIT="$EMIT" BUILD_RESULTS="$RESULTS" BUILD_VENDOR="$VENDOR"
export BUILD_ARCH="$ARCH" BUILD_ARCH_VAR="$ARCH_VAR"

ntests="$(printf '%s\n' $LIST | wc -l)"
echo "build: $ntests $VENDOR harness dir(s) in $EMIT, $ARCH_VAR=$ARCH [$ARCH_SOURCE], -j $J"
printf '%s\n' $LIST | xargs -r -P "$J" -I{} bash -c 'build_one "$@"' _ {} || true

OUT="$RESULTS/build.txt"
{
  echo "build_date=$(date -Is 2>/dev/null || date)"
  echo "git_rev=$( (cd "$REPO" && git rev-parse HEAD 2>/dev/null) || echo nogit)"
  echo "git_dirty=$( [ -z "$( (cd "$REPO" && git status --porcelain -- litmus hetlitmus 2>/dev/null) || true)" ] && echo no || echo YES )"
  echo "host_uname=$(uname -srm)"
  echo "vendor=$VENDOR"
  echo "arch=$ARCH"
  echo "arch_source=$ARCH_SOURCE"
  echo "arch_var=$ARCH_VAR"
  echo "compiler=$COMPILER"
  echo "compiler_version=$CVER"
  echo "emit=$EMIT"
  echo "tests=$ntests"
} > "$OUT"

nfail=0
TAB=""
for t in $LIST; do
  rc="$(cat "$RESULTS/build/$t.rc" 2>/dev/null || echo '?')"
  if [ "$rc" != 0 ] || [ ! -x "$EMIT/$t/$t" ]; then
    why="$(grep -m1 -iE 'error|refuses' "$RESULTS/build/$t.log" 2>/dev/null | cut -c1-100 || true)"
    TAB="$TAB$(printf '%-44s rc=%-5s %s' "$t" "$rc" "$why")
"
    nfail=$((nfail + 1))
  fi
done
{
  echo "built=$((ntests - nfail))"
  echo "failed=$nfail"
  echo "--- failures: test, rc, first error line (empty when every dir built) ---"
  printf '%s' "$TAB"
} >> "$OUT"

echo "build: $((ntests - nfail)) of $ntests built; per-dir logs in $RESULTS/build/"
echo "build: wrote $OUT"
if [ "$nfail" -ne 0 ]; then
  printf '%s' "$TAB" >&2
  echo "build: $nfail harness(es) did not build; the table is in $OUT" >&2
  exit 1
fi
