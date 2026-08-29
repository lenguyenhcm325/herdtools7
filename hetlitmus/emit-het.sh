#!/usr/bin/env bash
# Emit one harness dir per test of CORPUS into EMIT, one litmus7 run at a time:
# the batch driver exits 0 on a refusal, so every test is read on BOTH its own
# exit status and the "HetLitmus REFUSED" marker.  Each test's litmus7 output is
# appended to $RESULTS/emit.log under a header naming it.
#
# usage: emit-het.sh --gpu-target cuda|hip CORPUS [--tests LIST|FILE] [-o EMIT]
#   RESULTS  the results dir (default hetlitmus/run-out/<date>-<host>);
#            EMIT defaults to $RESULTS/emit.
# Exit: 0 = every test emitted; 1 = one did not; 2 = bad argument, or no litmus7.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

usage() {
  echo "usage: emit-het.sh --gpu-target cuda|hip CORPUS [--tests LIST|FILE] [-o EMIT]" >&2
}
refuse() { echo "emit-het: REFUSING -- $*" >&2 ; exit 2 ; }
fail()   { echo "emit-het: $*" >&2 ; exit 1 ; }
need()   { [ "$2" -ge 2 ] || { usage ; refuse "$1 needs a value" ; } ; }

TARGET="" ; CORPUS="" ; TESTS="" ; EMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu-target) need "$1" $# ; TARGET="$2" ; shift 2 ;;
    --tests)      need "$1" $# ; TESTS="$2"  ; shift 2 ;;
    -o)           need "$1" $# ; EMIT="$2"   ; shift 2 ;;
    -h|--help)    usage ; exit 0 ;;
    -*)           usage ; refuse "unknown argument \"$1\"" ;;
    *)  [ -z "$CORPUS" ] || { usage ; refuse "one CORPUS per run, not \"$CORPUS\" and \"$1\"" ; }
        CORPUS="$1" ; shift ;;
  esac
done

case "$TARGET" in
  cuda|hip) ;;
  "") usage ; refuse "--gpu-target is mandatory: it names the GPU dialect litmus7 renders" ;;
  *)  refuse "--gpu-target \"$TARGET\" is not a GPU dialect (accepted: cuda, hip)" ;;
esac
[ -n "$CORPUS" ] || { usage ; refuse "CORPUS is mandatory" ; }
[ -d "$CORPUS" ] || refuse "CORPUS $CORPUS is not a directory"
CORPUS="$(cd "$CORPUS" && pwd)"
[ -x "$LITMUS7" ] || refuse "litmus7 is not built at $LITMUS7 (run 'make all')"

RESULTS="${RESULTS:-$HETL/run-out/$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"
mkdir -p "$RESULTS"
RESULTS="$(cd "$RESULTS" && pwd)"
[ -n "$EMIT" ] || EMIT="$RESULTS/emit"
mkdir -p "$EMIT"
EMIT="$(cd "$EMIT" && pwd)"

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
  RAW="$(name_list "$TESTS")"
  LIST="$(printf '%s\n' "$RAW" | awk '!seen[$0]++')"
  DUP="$(printf '%s\n' "$RAW" | sort | uniq -d | paste -sd ' ')"
  [ -z "$DUP" ] || echo "emit-het: --tests names $DUP more than once; one emission each"
else
  LIST="$(cd "$CORPUS" && ls -1 ./*.litmus 2>/dev/null | sed 's|^\./||; s|\.litmus$||' || true)"
fi
[ -n "$LIST" ] || refuse "no .litmus test to emit out of $CORPUS"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

n=0
for t in $LIST; do
  [ -f "$CORPUS/$t.litmus" ] || refuse "$CORPUS holds no $t.litmus"
  st=0
  ( cd "$CORPUS" && "$LITMUS7" -gpu-target "$TARGET" -set-libdir "$LIBDIR" \
      -o "$EMIT" "$t.litmus" ) > "$LOG" 2>&1 || st=$?
  { echo "### $t (exit $st)" ; cat "$LOG" ; } >> "$RESULTS/emit.log"
  if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$LOG"; then
    cat "$LOG" >&2
    fail "litmus7 -gpu-target $TARGET emitted no harness for $t (exit $st) -- \
the whole log is $RESULTS/emit.log"
  fi
  n=$((n + 1))
done

echo "emit-het: $n harness dir(s) for -gpu-target $TARGET in $EMIT"
echo "emit-het: litmus7 output in $RESULTS/emit.log"
