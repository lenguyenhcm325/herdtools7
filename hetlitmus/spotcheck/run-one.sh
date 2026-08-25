#!/bin/sh
# One harness invocation, for campaign.py's --runner template:
#
#   campaign.py --runner "sh run-one.sh {dir} {test}" ...
#
# campaign.py shlex-splits the template, so it must stay a plain argv, and it
# parses the HetStats line the harness prints on stdout: nothing is filtered
# here.  With HET_RUN_LOG_DIR set the transcript is also appended to
# $HET_RUN_LOG_DIR/<test>.log.  The two streams stay SEPARATE and the harness's own status
# is this script's exit: campaign.py builds an errored row's note from the
# runner's stderr, and a merged stream leaves that note blank.
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
