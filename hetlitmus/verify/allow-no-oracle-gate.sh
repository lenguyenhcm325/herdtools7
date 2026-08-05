#!/usr/bin/env bash
# NO COMMITTED SCRIPT MAY PASS `-allow-no-oracle' (D-MV4).
#
# The flag emits a harness for a (CPU ISA x GPU dialect) pair the oracle table
# does not carry (litmus/hetOracle.ml): every test is stamped ORACLE_NONE and the
# stamp discloses the override, so such a run characterizes and never adjudicates.
# That is the right answer for a machine nobody has an oracle for yet -- and the
# wrong answer for everything else, because it turns "this pair is not registered"
# from a refusal a human reads into a line of output a campaign scrolls past.
#
# So the flag is a HUMAN's, typed once, for a named machine.  This gate is what
# keeps it that way: a committed script that passed it would make every future
# emission through that script silently oracle-less.
#
# WHAT IS SEARCHED: everything git tracks, minus this file and the places whose
# subject IS the flag -- the emitter that defines it, the option table that
# registers it, and the documentation and cram test that pin its behaviour.  Those
# exemptions are listed by path, one per line, so adding one is a visible edit.
#
#   hetlitmus/verify/allow-no-oracle-gate.sh          run the gate
#   hetlitmus/verify/allow-no-oracle-gate.sh --bite   prove it FAILS on a plant
#
# Exit: 0 = no committed script passes the flag; 1 = at least one does.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
cd "$REPO"

# The flag as a script would spell it.  A line is a HIT only if the flag appears
# before the line's first `#': that is the difference between a script PASSING it
# and a comment NAMING it, and comments must be able to name it -- emit-all.sh's
# own header explains why it may not pass it.  The three source files that define,
# register and consume the flag use OCaml comments, so they are exempted by path
# below instead.  The rule is deliberately coarse -- an echo naming the flag is a
# hit too, and the fix there is to reword the echo, not to widen the exemptions.
PATTERN='-allow-no-oracle'

# Paths whose subject IS the flag.  Each says what it is for.
EXEMPT="
litmus/hetOracle.ml                          # defines it
litmus/litmus.ml                             # registers it as a litmus7 option
litmus/hetEmit.ml                            # consumes the resolution it produces
hetlitmus/verify/allow-no-oracle-gate.sh     # this gate
hetlitmus/tests/cram/oracle-pairs.t          # pins that it emits + discloses
hetlitmus/docs/het-emission.md               # documents the deviation path
"

BITE=0
[ "${1:-}" = "--bite" ] && BITE=1

exempt_list() {                 # the EXEMPT block as bare paths, one per line
  printf '%s\n' "$EXEMPT" | sed 's/#.*//' | tr -d ' \t' | grep -v '^$'
}

# `git grep' rather than a per-file loop: it searches exactly the TRACKED files
# (which is the property this gate is about) in one process.  Its output is
# path:lineno:text, and the two filters below are applied to that.
scan() {                        # scan ROOT -> prints offending "path:lineno: text"
  local root="$1"
  ( cd "$root" && git grep -n -F -- "$PATTERN" -- . 2>/dev/null || true ) \
  | awk -v exempt="$(exempt_list | tr '\n' '|')" -v pat="$PATTERN" '
      BEGIN { n = split(exempt, E, "|"); for (i = 1; i <= n; i++) if (E[i] != "") X[E[i]] = 1 }
      { c1 = index($0, ":");            path = substr($0, 1, c1 - 1)
        rest = substr($0, c1 + 1)
        c2 = index(rest, ":");          lineno = substr(rest, 1, c2 - 1)
        text = substr(rest, c2 + 1)
        if (path in X) next
        code = text
        h = index(code, "#")
        if (h > 0) code = substr(code, 1, h - 1)
        if (index(code, pat) > 0) printf "%s:%s: %s\n", path, lineno, text }'
}

run_gate() {                    # run_gate ROOT LABEL -> 0/1
  local root="$1" label="$2" hits
  hits="$(scan "$root")"
  if [ -n "$hits" ]; then
    echo "FAIL ($label): a committed file passes -allow-no-oracle:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "  The flag emits harnesses that carry NO model prediction.  It is for a"
    echo "  human bringing up a machine with no oracle, not for a script -- see"
    echo "  litmus/hetOracle.ml.  Register the pair instead."
    return 1
  fi
  echo "OK ($label): no committed file passes -allow-no-oracle"
  return 0
}

if [ "$BITE" -eq 0 ]; then
  echo "===== allow-no-oracle gate: no committed script may pass the flag ====="
  run_gate "$REPO" "the tree"
  exit $?
fi

# --- BITE.  A gate never seen to fail is not evidence. ----------------------
# The plant goes into a COPY of the worktree, so the real tree is never edited:
# git ls-files is run inside the copy, which is what makes the copy scannable.
echo "===== allow-no-oracle gate BITE ====="
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/tree"
mkdir -p "$COPY"
git ls-files -z | tar --null -T - -cf - | ( cd "$COPY" && tar -xf - )
cp -r .git "$COPY/.git"

echo "-- (1) the untouched copy must be GREEN"
if ! run_gate "$COPY" "clean copy"; then
  echo "BITE FAILED: the copy is not green before the plant, so the plant proves nothing"
  exit 1
fi

# A committed script, given the flag exactly the way a hurried fix would give it.
VICTIM=hetlitmus/verify/emit-all.sh
echo "-- (2) plant the flag in $VICTIM -- the gate must go RED and name it"
sed -i 's|"\$LITMUS7" -gpu-target "\$target" -o "\$OUTDIR/\$sub" "\$t"|"$LITMUS7" -allow-no-oracle -gpu-target "$target" -o "$OUTDIR/$sub" "$t"|' \
  "$COPY/$VICTIM"
grep -q -- '-allow-no-oracle' "$COPY/$VICTIM" || {
  echo "BITE ERROR: the plant matched nothing -- $VICTIM changed shape"; exit 2; }
if run_gate "$COPY" "planted copy"; then
  echo "BITE FAILED: the gate stayed green with the flag planted in $VICTIM"
  exit 1
fi
echo "   (red, as required)"

echo "-- (3) restore the plant -- the gate must go GREEN again"
( cd "$COPY" && git checkout -- "$VICTIM" )
if ! run_gate "$COPY" "restored copy"; then
  echo "BITE FAILED: the gate stayed red after the plant was restored"
  exit 1
fi
echo
echo "ALLOW-NO-ORACLE BITE OK (green -> red -> green)"
