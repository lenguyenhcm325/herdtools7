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
set -eu
cd "$1" || exit 2
exec "./$2"
