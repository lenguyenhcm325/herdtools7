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
# parses.  It is a copy, never a filter: both streams are forwarded on the
# stream they arrived on and the harness's own exit status is what this script
# exits with.  THE TWO STREAMS STAY SEPARATE -- campaign.py builds an errored
# row's note from the runner's stderr, so merging them leaves that note blank on
# exactly the invocations that failed, and a non-zero status a pipeline swallowed
# would turn a dead harness into a silent one.
set -eu
cd "$1" || exit 2
[ -n "${HET_RUN_LOG_DIR:-}" ] || exec "./$2"

mkdir -p "$HET_RUN_LOG_DIR"
o="$(mktemp)" ; e="$(mktemp)"
rc=0
"./$2" > "$o" 2> "$e" || rc=$?
{ echo "### $2 rc=$rc seed=${HET_SEED:-<unset>} runs_max=${HET_RUNS_MAX:-<unset>}"
  cat "$o"
  if [ -s "$e" ]; then echo "### stderr" ; cat "$e" ; fi ; } \
  >> "$HET_RUN_LOG_DIR/$2.log"
cat "$o"
cat "$e" >&2
rm -f "$o" "$e"
exit "$rc"
