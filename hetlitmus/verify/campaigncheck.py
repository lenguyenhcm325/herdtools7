#!/usr/bin/env python3
"""HetLitmus -- the campaign gate: hetlitmus/campaign.py end to end against a
stub harness printing deterministic HetStats lines.  Pinned in the state CSV:
a clean sighting ends a row and outranks the budget, a rejected sighting stops
nothing, a row with no usable run, no harness binary or a harness outliving
--timeout ends ERROR with its reason banked, --rate turns the sighting stop
off and nothing else, and every invocation carries the seed base plus its
stride, the runs the row has left and the stop flag.  A miss means the
hardware hours go where the brief does not say (what a null is worth:
hetlitmus/docs/environment-design.md "Aggregate").  Usage: campaigncheck.py
"""

import csv
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import campaign

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


NULL, DEAD, FIRED = ("Never", 0, 0, 0), ("VOID", 0, 0, 0, 0), ("Sometimes", 1, 1, 0)
SCRIPT = {"NULL-pooled": lambda inv: NULL,
          "SIGHT-clean": lambda inv: FIRED,
          "SIGHT-late": lambda inv: FIRED if inv == 5 else NULL,
          "SIGHT-degen": lambda inv: ("Sometimes", 1, 0, 1),
          "VOID-dead": lambda inv: DEAD,
          "VOID-late": lambda inv: NULL if inv == 1 else DEAD}
line(*SCRIPT[test](inv))
'''

# A stand-in that outlives its timeout, having flushed a line first.
SLEEPER = ("#!/usr/bin/env python3\n"
           "import sys, time\n"
           "sys.stdout.write('HetLitmus: shared-mem mode=stub\\n')\n"
           "sys.stdout.flush()\n"
           "time.sleep(30)\n")


def row(stop, inv, usable, k, k_eff, note=""):
    """The state CSV row a test ends with after inv stub invocations."""
    return dict(stop=stop, invocations=str(inv), seed0=str(SEED0),
                runs=str(inv * R), usable=str(usable), k=str(k), k_eff=str(k_eff),
                scored=str(inv * SCORED), discarded=str(inv * DISCARDED), note=note)


SEEN = "the weak outcome was seen in 1 clean run(s)"
WANT = {
    "NULL-pooled": row("BUDGET", 10, BUDGET, 0, 0),
    "SIGHT-clean": row("OBSERVED", 1, R, 1, 1, SEEN),
    "SIGHT-late": row("OBSERVED", 5, 5 * R, 1, 1, SEEN),  # four nulls, then a sighting
    "SIGHT-degen": row("BUDGET", 10, BUDGET, 10, 0),     # every sighting guard-rejected
    "VOID-dead": row("ERROR", 1, 0, 0, 0,
                     "usable=0 of R=%d: nothing was measured" % R),
    "VOID-late": row("BUDGET", 10, R, 0, 0),             # measured once, then went dead
}

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


def run_campaign(corpus, state, *extra):
    return subprocess.run(
        [sys.executable, campaign.__file__, "--corpus", corpus, "--budget-runs",
         str(BUDGET), "--seed0", str(SEED0), "--state", state] + list(extra),
        capture_output=True, text=True)


def banked(state):
    """The state CSV's rows, in the order they were written."""
    if not os.path.exists(state):
        return []
    with open(state) as fh:
        return list(csv.DictReader(fh))


def note_of(state, test):
    return {r["test"]: r["note"] for r in banked(state)}.get(test, "")


def seeds(corpus, test):
    """[(invocation, HET_SEED, HET_RUNS_MAX, HET_STOP_AT_SIGHTING)] the stub logged."""
    with open(os.path.join(corpus, test, "seeds.log")) as fh:
        return [tuple(l.split()) for l in fh]


def run(tmp):
    # ---- the policy, end to end: one row per stop rule, banked in the CSV.
    corpus = mk_corpus(tmp, "corpus", TESTS)
    state = os.path.join(tmp, "state.csv")
    r = run_campaign(corpus, state)
    check("Traceback" not in r.stderr, "the campaign CRASHED:\n" + r.stderr[-800:])
    check(r.returncode == 1, "campaign exited %d, want 1: one row ends ERROR"
          % r.returncode)
    rows = banked(state)
    check([x["test"] for x in rows] == sorted(TESTS),
          "banked order %s is not the corpus's" % [x["test"] for x in rows])
    for x in rows:
        w = WANT.get(x["test"], {})
        off = {c: (x.get(c), w[c]) for c in w if x.get(c) != w[c]}
        check(not off, "%-12s banked %s (got, want)" % (x["test"], off))
    # ---- every invocation: the seed base plus its stride, the runs the row
    # has left, and the stop flag.
    for t in TESTS:
        for inv, seed, runs_max, stop_at in seeds(corpus, t):
            i = int(inv) - 1
            w = (str(SEED0 + i * campaign.SEED_STRIDE), str(BUDGET - i * R), "1")
            check((seed, runs_max, stop_at) == w,
                  "%s invocation %s ran under HET_SEED=%s HET_RUNS_MAX=%s "
                  "HET_STOP_AT_SIGHTING=%s, want %s"
                  % (t, inv, seed, runs_max, stop_at, w))
    # ---- --rate turns the sighting stop off and nothing else.
    rate = mk_corpus(tmp, "rate", ["SIGHT-clean", "NULL-pooled"])
    st = os.path.join(tmp, "rate.csv")
    r = run_campaign(rate, st, "--rate")
    check(r.returncode == 0, "--rate campaign exited %d, want 0" % r.returncode)
    for x in banked(st):
        check((x["stop"], x["invocations"]) == ("BUDGET", "10"),
              "--rate: %s banked %s after %s invocation(s), want BUDGET after 10"
              % (x["test"], x["stop"], x["invocations"]))
    stops = set(s[3] for s in seeds(rate, "SIGHT-clean"))
    check(stops == {"0"}, "--rate handed HET_STOP_AT_SIGHTING=%s to the "
          "harness, want 0 on every invocation" % sorted(stops))
    # ---- a harness dir the build never reached ends ERROR naming the path.
    noexe = mk_corpus(tmp, "noexe", ["UNBUILT"], body=None)
    st = os.path.join(tmp, "noexe.csv")
    r = run_campaign(noexe, st)
    note = note_of(st, "UNBUILT")
    check("Traceback" not in r.stderr and r.returncode == 1
          and os.path.join(noexe, "UNBUILT", "UNBUILT") in note,
          "a dir with no harness binary exited %d with note %r, want 1 and a "
          "note naming the path" % (r.returncode, note))
    # ---- a harness outliving --timeout ends ERROR, its partial transcript kept.
    slow = mk_corpus(tmp, "slow", ["SLOW"], body=SLEEPER)
    st, logs = os.path.join(tmp, "slow.csv"), os.path.join(tmp, "slow-logs")
    r = run_campaign(slow, st, "--timeout", "1", "--log-dir", logs)
    note = note_of(st, "SLOW")
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
