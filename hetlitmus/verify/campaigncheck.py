#!/usr/bin/env python3
"""HetLitmus -- the campaign gate: hetlitmus/campaign.py end to end against a
stub harness printing deterministic HetStats lines.  Pinned: a clean sighting
ends a row and outranks the budget, a rejected sighting stops nothing, a row
with no usable run, no harness binary or a harness outliving --timeout ends
ERROR with its reason banked, --rate turns the sighting stop off and nothing
else, every invocation carries the seed base plus its stride, the runs the row
has left and the stop flag, and the state CSV banks every run the budget
bought.  A miss means the hardware hours go where the brief does not say.
What a null is worth: hetlitmus/docs/00-environment-design.md "Aggregate".
Usage: campaigncheck.py
"""

import csv
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CAMPAIGN = os.path.join(HERE, "..", "campaign.py")

SEED_STRIDE = 100003     # must match campaign.py
SEED0 = 777
# The budget the campaign is driven with, and what one stub invocation
# reports: R runs, scoring and discarding these totals.
BUDGET, R = 100, 10
SCORED, DISCARDED = 100000, 250
TESTS = ["NULL-pooled", "SIGHT-clean", "SIGHT-degen", "SIGHT-late",
         "VOID-dead", "VOID-late"]

# The stand-in runs as ./<test> from <corpus>/<test>: it locates its own dir,
# counts its invocations and logs the knobs it was handed.
STUB = r'''#!/usr/bin/env python3
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
test = os.path.basename(d)
cf = os.path.join(d, "inv.count")
inv = (int(open(cf).read()) + 1) if os.path.exists(cf) else 1
open(cf, "w").write(str(inv))
with open(os.path.join(d, "seeds.log"), "a") as fh:
    fh.write("%d %s %s %s\n" % (inv, os.environ.get("HET_SEED"),
                                os.environ.get("HET_RUNS_MAX"),
                                os.environ.get("HET_STOP_AT_SIGHTING")))
# The real harness runs at most HET_RUNS_MAX runs, so the stub does too.
R = min(10, int(os.environ.get("HET_RUNS_MAX") or "10"))


def line(obs, k, k_eff, degen, usable=None):
    """One HetStats machine line, in het_stats_line's field order and set."""
    print("HetStats %s obs=%s R=%d usable=%d k=%d k_eff=%d "
          "degen=%d N=100000 scored=100000 discarded=250"
          % (test, obs, R, R if usable is None else usable, k, k_eff, degen))


NULL = ("Never", 0, 0, 0)
DEAD = ("VOID", 0, 0, 0, 0)
FIRED = ("Sometimes", 1, 1, 0)
if test == "NULL-pooled":
    line(*NULL)
elif test == "SIGHT-clean":
    line(*FIRED)
elif test == "SIGHT-late":            # nulls, then one sighting at the fifth
    line(*(FIRED if inv == 5 else NULL))
elif test == "SIGHT-degen":           # a sighting the decode guard rejected
    line("Sometimes", 1, 0, 1)
elif test == "VOID-dead":             # no usable run, ever
    line(*DEAD)
elif test == "VOID-late":             # measures once, then goes dead
    line(*(NULL if inv == 1 else DEAD))
else:
    sys.exit(3)
'''

# A stand-in that outlives its timeout, having flushed a line first.
SLEEPER = ("#!/usr/bin/env python3\n"
           "import sys, time\n"
           "sys.stdout.write('HetLitmus: shared-mem mode=stub\\n')\n"
           "sys.stdout.flush()\n"
           "time.sleep(30)\n")

BAD = []


def check(ok, msg):
    if not ok:
        BAD.append(msg)
        print("  *** " + msg)


def mk_corpus(tmp, name, tests, body=STUB):
    """One harness dir per test holding the stand-in at <t>/<t>, the path
    campaign.py runs; body=None leaves the dir with no binary."""
    corpus = os.path.join(tmp, name)
    for t in tests:
        d = os.path.join(corpus, t)
        os.makedirs(d)
        if body is not None:
            with open(os.path.join(d, t), "w") as fh:
                fh.write(body)
            os.chmod(os.path.join(d, t), 0o755)
    return corpus


def campaign(corpus, state, *extra):
    return subprocess.run(
        [sys.executable, CAMPAIGN, "--corpus", corpus, "--budget-runs",
         str(BUDGET), "--seed0", str(SEED0), "--state", state] + list(extra),
        capture_output=True, text=True)


def banked(state):
    """test -> its row of the state CSV."""
    if not os.path.exists(state):
        return {}
    with open(state) as fh:
        return {row["test"]: row for row in csv.DictReader(fh)}


def done_rows(out):
    """test -> (stop, invocations, runs, usable) off the `done' lines, and
    the order they came in."""
    done, order = {}, []
    for l in out.splitlines():
        if l.startswith("done  "):
            f = l.split()
            done[f[1]] = (f[2],) + tuple(int(x.split("=")[1]) for x in f[3:6])
            order.append(f[1])
    return done, order


def seeds(corpus, test):
    """[(invocation, HET_SEED, HET_RUNS_MAX, HET_STOP_AT_SIGHTING)] the stub logged."""
    with open(os.path.join(corpus, test, "seeds.log")) as fh:
        return [tuple(l.split()) for l in fh]


def run(tmp):
    # ---- the policy, end to end: one row per stop rule.
    corpus = mk_corpus(tmp, "corpus", TESTS)
    state = os.path.join(tmp, "state.csv")
    r = campaign(corpus, state)
    check("Traceback" not in r.stderr, "the campaign CRASHED:\n" + r.stderr[-800:])
    check(r.returncode == 1, "campaign exited %d, want 1: one row ends ERROR"
          % r.returncode)
    check("campaign: seed0=%d " % SEED0 in r.stdout,
          "the seed base is not printed, so the campaign cannot be replayed")
    done, order = done_rows(r.stdout)
    check(order == sorted(TESTS), "run order %s is not the corpus's" % order)
    want = {                    # stop, invocations, runs, usable
        "NULL-pooled": ("BUDGET", 10, BUDGET, BUDGET),   # ended by the budget alone
        "SIGHT-clean": ("OBSERVED", 1, R, R),
        "SIGHT-late": ("OBSERVED", 5, 5 * R, 5 * R),     # the nulls before it are kept
        "SIGHT-degen": ("BUDGET", 10, BUDGET, BUDGET),   # a rejected sighting stops nothing
        "VOID-dead": ("ERROR", 1, R, 0),
        "VOID-late": ("BUDGET", 10, BUDGET, R),          # keeps the runs it measured
    }
    for t, w in want.items():
        check(done.get(t) == w, "%-12s done %s, want %s" % (t, done.get(t), w))
    # ---- the state CSV banks the row and the totals behind it.
    bank = banked(state)
    per_inv = BUDGET // R
    want_bank = {
        "NULL-pooled": dict(stop="BUDGET", invocations="10", seed0=str(SEED0),
                            runs=str(BUDGET), usable=str(BUDGET), k="0",
                            scored=str(per_inv * SCORED),
                            discarded=str(per_inv * DISCARDED)),
        "VOID-late": dict(stop="BUDGET", runs=str(BUDGET), usable=str(R)),
        "VOID-dead": dict(stop="ERROR",
                          note="usable=0 of R=%d: nothing was measured" % R),
    }
    for t, w in want_bank.items():
        got = {c: bank.get(t, {}).get(c) for c in w}
        check(got == w, "%s banked %s, want %s" % (t, got, w))
    # ---- every invocation: the seed base plus its stride, the runs the row
    # has left, and the stop flag.
    for t in TESTS:
        for inv, seed, runs_max, stop_at in seeds(corpus, t):
            i = int(inv) - 1
            w = (str(SEED0 + i * SEED_STRIDE), str(BUDGET - i * R), "1")
            check((seed, runs_max, stop_at) == w,
                  "%s invocation %s ran under HET_SEED=%s HET_RUNS_MAX=%s "
                  "HET_STOP_AT_SIGHTING=%s, want %s"
                  % (t, inv, seed, runs_max, stop_at, w))
    # ---- --rate turns the sighting stop off and nothing else.
    rate = mk_corpus(tmp, "rate", ["SIGHT-clean", "NULL-pooled"])
    r = campaign(rate, os.path.join(tmp, "rate.csv"), "--rate")
    done, _ = done_rows(r.stdout)
    check(r.returncode == 0, "--rate campaign exited %d, want 0" % r.returncode)
    for t in ("SIGHT-clean", "NULL-pooled"):
        check(done.get(t, ())[:2] == ("BUDGET", 10),
              "--rate: %s done %s, want BUDGET after 10 invocation(s)"
              % (t, done.get(t)))
    stops = set(s[3] for s in seeds(rate, "SIGHT-clean"))
    check(stops == {"0"}, "--rate handed HET_STOP_AT_SIGHTING=%s to the "
          "harness, want 0 on every invocation" % sorted(stops))
    # ---- a harness dir the build never reached ends ERROR naming the path.
    noexe = mk_corpus(tmp, "noexe", ["UNBUILT"], body=None)
    st = os.path.join(tmp, "noexe.csv")
    r = campaign(noexe, st)
    note = banked(st).get("UNBUILT", {}).get("note", "")
    check("Traceback" not in r.stderr and r.returncode == 1
          and os.path.join(noexe, "UNBUILT", "UNBUILT") in note,
          "a dir with no harness binary exited %d with note %r, want 1 and a "
          "note naming the path" % (r.returncode, note))
    # ---- a harness outliving --timeout ends ERROR, its partial transcript kept.
    slow = mk_corpus(tmp, "slow", ["SLOW"], body=SLEEPER)
    st, logs = os.path.join(tmp, "slow.csv"), os.path.join(tmp, "slow-logs")
    r = campaign(slow, st, "--timeout", "1", "--log-dir", logs)
    note = banked(st).get("SLOW", {}).get("note", "")
    check(r.returncode == 1 and note == "timeout after 1 s",
          "the harness outliving --timeout 1 exited %d with note %r"
          % (r.returncode, note))
    tr = os.path.join(logs, "SLOW.log")
    check(os.path.exists(tr) and "mode=stub" in open(tr).read(),
          "the timed-out invocation left no partial transcript in %s" % tr)


def main():
    print("===== campaigncheck: does the scheduler spend the hours where the "
          "brief says? =====")
    tmp = tempfile.mkdtemp(prefix="campaigncheck.")
    try:
        run(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if BAD:
        print("\nCAMPAIGNCHECK FAILED: %d problem(s)." % len(BAD))
        return 1
    print("\nCAMPAIGNCHECK OK -- a clean sighting ends a row and outranks the "
          "budget, --rate turns that off and nothing else, a row nothing ran "
          "and a row that measured nothing both end ERROR, and every "
          "invocation's seed, runs and stop flag are the driver's.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
