#!/bin/sh
# One harness invocation, for campaign.py's --runner template:
#
#   campaign.py --runner "sh run-one.sh {dir} {test}" ...
#
# campaign.py shlex-splits the template, so it must stay a plain argv -- hence a
# script rather than an inline `sh -c'.  The harness reads its per-invocation
# knobs (HET_SEED, HET_ADAPTIVE, HET_RUNS_MAX, HET_P_GOAL) from the environment
# campaign.py sets, and prints the HetStats machine line on stdout, which is the
# whole interface.  Nothing is filtered here: campaign.py parses the LAST
# machine line and ignores everything else, including the shared-mem banner.
#
# HET_RUN_LOG_DIR (optional) also APPENDS each invocation's transcript to
# <dir>/<test>.log, so a session keeps the HetStats lines campaign.py only
# parses.  It is a copy, never a filter: stdout is forwarded verbatim and the
# harness's own exit status is what this script exits with -- campaign.py reads
# a non-zero status as an errored row, so a pipeline that swallowed it would
# turn a dead harness into a silent one.
set -eu
cd "$1" || exit 2
[ -n "${HET_RUN_LOG_DIR:-}" ] || exec "./$2"

mkdir -p "$HET_RUN_LOG_DIR"
tmp="$(mktemp)"
rc=0
"./$2" > "$tmp" 2>&1 || rc=$?
{ echo "### $2 rc=$rc seed=${HET_SEED:-<unset>} runs_max=${HET_RUNS_MAX:-<unset>}"
  cat "$tmp" ; } >> "$HET_RUN_LOG_DIR/$2.log"
cat "$tmp"
rm -f "$tmp"
exit "$rc"
