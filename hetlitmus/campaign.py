#!/usr/bin/env python3
"""The campaign scheduler: where the hardware hours are spent, or saved.

One policy for every row -- het_verdict.h's, no harness carrying a prediction: pooled
here, per-invocation in the harness (HET_ADAPTIVE=1); `check_flag_mirror' pins what must
agree.  hetlitmus/docs/harness-reporting.md sec 5; the four steps a results dir is
built by, hetlitmus/docs/het-emission.md "From a corpus to a results dir".
One invocation is `./<test>' run in its own harness dir under `--timeout'; the
HetStats line it prints on stdout is the whole interface.
Exit: 0 = completed; 2 = configuration/corpus error; 1 = a test errored.
"""

import argparse
import csv
import os
import re
import secrets
import subprocess
import sys
import time

# A prime stride far above any plausible NUMBER_OF_RUN: the harness consumes
# base + run, so bases never collide across invocations of one test.
SEED_STRIDE = 100003

# The mirrored half of het_verdict.h's stopping rule; check_flag_mirror() below pins
# every name here against the header.
STOP_NAMES = {
    "HET_CAMPAIGN_STOP_OBSERVED": "OBSERVED",
    "HET_CAMPAIGN_STOP_BUDGET":   "BUDGET",
}
# ERROR is this driver's own: no readable row, which the C rule never sees.
TERMINAL = tuple(sorted(STOP_NAMES.values())) + ("ERROR",)


def die(msg):
    sys.stderr.write("campaign: FATAL: %s\n" % msg)
    sys.exit(2)


def corpus_tests(corpus):
    """The tests to schedule: one row per emitted harness dir."""
    if not os.path.isdir(corpus):
        die("--corpus %s is not a directory" % corpus)
    tests = sorted(d for d in os.listdir(corpus)
                   if os.path.isdir(os.path.join(corpus, d)))
    if not tests:
        die("no harness dir under %s -- emit the corpus first (there is nothing to "
            "characterize)" % corpus)
    return tests


def parse_hetstats(stdout):
    """The LAST machine-readable 'HetStats <test> key=value...' line (the human block
    also starts 'HetStats' but its second field ends in ':')."""
    got = None
    for line in stdout.splitlines():
        if not line.startswith("HetStats "):
            continue
        f = line.split()
        if len(f) < 3 or f[1].endswith(":"):
            continue
        kv = {}
        for tok in f[2:]:
            p = tok.find("=")
            if p > 0:
                kv[tok[:p]] = tok[p + 1:]
        got = (f[1], kv)
    return got


def fnum(kv, key, dflt=0.0):
    try:
        return float(kv.get(key, dflt))
    except ValueError:
        return dflt


def fhex(kv, key):
    """A 0x-printed field; a missing or unreadable one reads as 0, like fnum."""
    try:
        return int(kv.get(key, "0"), 0)
    except ValueError:
        return 0


# The header the harness compiles its own stopping rule from.  The mirror below is
# the only thing pinning this driver's copy of that rule to it, so a header out of
# reach is fatal rather than tolerated.
_VERDICT_H = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                          "litmus", "het-runtime", "het_verdict.h")


def check_flag_mirror(path=_VERDICT_H, stops=None):
    """Every stop-name string as `path` defines it."""
    stops = STOP_NAMES if stops is None else stops
    # This driver's own consistency, checked before the header is opened: a stop it
    # can write but never treats as terminal loops forever.
    if set(TERMINAL) != set(stops.values()) | {"ERROR"}:
        die("TERMINAL %s does not match the stop names %s plus ERROR"
            % (sorted(TERMINAL), sorted(stops.values())))
    try:
        with open(path) as fh:
            text = fh.read()
    except (IOError, OSError) as e:
        die("%s cannot be read (%s) -- the stopping rule this scheduler applies "
            "cannot be checked against the one the harness compiled" % (path, e))
    got = dict(re.findall(r"case[ \t]+(HET_CAMPAIGN_STOP_\w+):[ \t]*"
                          r'return[ \t]+"([^"]*)";', text))
    if got != stops:
        die("%s drifted on the stop names: %s there, %s here -- the scheduler writes "
            "these strings into its state file and reads them back as terminal"
            % (path, sorted(got.items()), sorted(stops.items())))
    if not re.search(r'default:[ \t]*return[ \t]+"CONTINUE";', text):
        die("%s no longer returns \"CONTINUE\" for a non-stop -- the scheduler treats "
            "every name it does not know as terminal" % path)
    return got


check_flag_mirror()


class TestState(object):
    def __init__(self, name):
        self.name = name
        self.invocations = 0
        self.runs = 0            # records actually scored (sum of R)
        self.usable = 0
        self.k = self.k_eff = 0
        # The effort behind the row, and every diagnostic bit any invocation raised.
        self.scored = self.discarded = 0
        self.flags = 0
        self.stop = ""
        self.note = ""

    def absorb(self, kv):
        self.invocations += 1
        self.runs += int(fnum(kv, "R"))
        self.usable += int(fnum(kv, "usable"))
        self.k += int(fnum(kv, "k"))
        self.k_eff += int(fnum(kv, "k_eff"))
        self.scored += int(fnum(kv, "scored"))
        self.discarded += int(fnum(kv, "discarded"))
        self.flags |= fhex(kv, "flags")

    def decide(self, budget, rate_mode):
        """het_campaign_should_stop(), at the pooled scale: `runs' here is what `n' is
        there.  The order of the arms is the policy and must NOT be rearranged."""
        if self.stop:
            return self.stop
        # k_eff, NEVER k: a sighting the decode guard rejected stops nothing.
        if self.k_eff > 0 and not rate_mode:
            self.stop, self.note = "OBSERVED", (
                "the weak outcome was seen in %d clean run(s)" % self.k_eff)
        elif budget > 0 and self.runs >= budget:
            self.stop = "BUDGET"
        return self.stop


def save_state(path, states, seed0):
    cols = ["test", "stop", "invocations", "seed0", "runs", "usable", "k", "k_eff",
            "scored", "discarded", "flags", "note"]
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for s in states:
            w.writerow([s.name, s.stop, s.invocations, seed0, s.runs, s.usable,
                        s.k, s.k_eff,
                        s.scored, s.discarded, "0x%x" % s.flags,
                        s.note])


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True,
                    help="directory holding one emitted harness dir per test")
    ap.add_argument("--budget-runs", type=int, default=100,
                    help="max runs per row")
    ap.add_argument("--rate", action="store_true",
                    help="HET_RATE: run to budget even after the outcome is seen, so "
                         "a row that fires yields a rate (a sighting stops nothing)")
    ap.add_argument("--seed0", type=int, default=None,
                    help="the seed base: invocation i of a row runs at seed0 + "
                         "i*%d, counting from 0.  The default is a fresh random "
                         "base per campaign, printed and banked in the state CSV; "
                         "pass it back to replay those bases" % SEED_STRIDE)
    ap.add_argument("--state", required=True,
                    help="the state CSV, rewritten after every test; it must not "
                         "exist yet")
    ap.add_argument("--tests", default="",
                    help="comma-separated subset, or a file with one name per line "
                         "(default: every harness dir in --corpus)")
    ap.add_argument("--timeout", type=int, default=900,
                    help="seconds one invocation may take before its row ends ERROR")
    ap.add_argument("--log-dir", default="",
                    help="append each invocation's transcript to DIR/<test>.log; "
                         "the default is --state's path without its extension, "
                         "plus -logs")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    # Absolute, so an errored row's note names a path a reader can open from
    # anywhere and the harness cwd does not depend on this process's.
    a.corpus = os.path.abspath(a.corpus)
    # A budget of 0 or less is "no budget" to het_verdict.h's rule, which the harness
    # can afford (its run loop is bounded by the record array) and this loop cannot.
    if a.budget_runs < 1:
        die("--budget-runs %d names no bound, and this driver loops until one is "
            "reached" % a.budget_runs)
    # save_state rewrites --state whole after every test, so starting on a file that
    # holds rows overwrites measurements nothing here re-ran.  The bar is existence,
    # NOT terminality: a half-written state is a reading too.  A --dry-run writes
    # nothing, so it is free to plan against a state that already exists.
    if not a.dry_run and os.path.exists(a.state):
        die("--state %s already exists and a campaign is never resumed: running on "
            "would silently overwrite the rows it holds. Move it aside, or point "
            "--state at a fresh path." % a.state)
    if not a.log_dir:
        a.log_dir = os.path.splitext(a.state)[0] + "-logs"
    # log_invocation APPENDS, so a dir holding anything would interleave two
    # campaigns' transcripts under one name.
    if not a.dry_run and os.path.exists(a.log_dir) and (
            not os.path.isdir(a.log_dir) or os.listdir(a.log_dir)):
        die("--log-dir %s exists and is not an empty directory, and every "
            "transcript is appended: running on would mix this campaign's "
            "transcripts with what is there. Move it aside, or point --log-dir "
            "at a fresh path." % a.log_dir)
    if a.seed0 is None:
        a.seed0 = secrets.randbits(31)
    # Every invocation adds at least one run and the budget bounds a row, so both a
    # row's invocations and the runs inside one are under it.
    if a.seed0 < 0 or a.seed0 + a.budget_runs * (SEED_STRIDE + 1) >= 2 ** 32:
        die("--seed0 %d with --budget-runs %d reaches past 2^32-1, the width the "
            "harness reads a seed at" % (a.seed0, a.budget_runs))
    return a


def named_tests(spec):
    """--tests, as a comma list or as a path to a file with one name per line: the
    first field of a line, `#' and blanks ignored."""
    if not spec:
        return []
    if not os.path.isfile(spec):
        return [t for t in spec.split(",") if t]
    out = []
    with open(spec) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line.split()[0])
    return out


def select_work(a, tests):
    """Those named by --tests, else the whole corpus.  A named test with no harness dir
    is FAIL CLOSED, not a skip."""
    known = set(tests)
    subset = named_tests(a.tests) or list(tests)
    uniq = list(dict.fromkeys(subset))
    if len(uniq) != len(subset):
        print("campaign: --tests names %s more than once; one row each."
              % ", ".join(sorted(t for t in uniq if subset.count(t) > 1)))
    missing = [t for t in uniq if t not in known]
    if missing:
        die("no harness dir under %s for: %s -- fail closed, nothing to schedule"
            % (a.corpus, ", ".join(missing[:5])))
    return sorted(uniq)


def plan_schedule(a, work):
    """`work` in run order, plus what the schedule costs.  One policy, so one order and
    one budget: a row stops early because a clean run saw the outcome."""
    # A worst case, not a schedule (hetlitmus/docs/harness-reporting.md sec 5).
    print("campaign: %d test(s), one stop rule each: a clean sighting, or %d run(s) "
          "spent.  Worst case %d runs."
          % (len(work), a.budget_runs, len(work) * a.budget_runs))
    if a.rate:
        print("campaign: --rate: a sighting stops NOTHING; every row runs to its "
              "budget, so a row that fires yields a rate.")
    return work


def _text(stream):
    """A TimeoutExpired carries its partial streams as bytes even under text=True."""
    if stream is None:
        return ""
    return stream if isinstance(stream, str) else stream.decode("utf-8", "replace")


def log_invocation(log_dir, name, rc, env, secs, out, err):
    """One invocation's transcript, which nothing else keeps: stdout then stderr,
    each on the stream it arrived on, under a header naming the run."""
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, name + ".log"), "a") as fh:
        fh.write("### %s rc=%s seed=%s runs_max=%s secs=%.1f\n"
                 % (name, rc, env.get("HET_SEED"), env.get("HET_RUNS_MAX"), secs))
        fh.write(out)
        if err:
            fh.write("### stderr\n")
            fh.write(err)


def drive_test(a, st, budget):
    """Invoke one test's harness until its stop rule fires, pooling each HetStats line.
    Every failure mode ends the test as ERROR rather than looping on it."""
    d = os.path.join(a.corpus, st.name)
    exe = os.path.join(d, st.name)
    while not st.decide(budget, a.rate):
        if not os.path.isfile(exe) or not os.access(exe, os.X_OK):
            # The dir exists (corpus_tests listed it) and the binary does not: the
            # build did not reach this row, which is not a reading of anything.
            st.stop, st.note = "ERROR", "no executable harness at %s" % exe
            return
        env = dict(os.environ)
        env["HET_SEED"] = str(a.seed0 + st.invocations * SEED_STRIDE)
        env["HET_ADAPTIVE"] = "1"
        # The harness applies the SAME rule inside the invocation, so it gets the same
        # knobs, and no more runs than the row has left.
        env["HET_RUNS_MAX"] = str(max(1, budget - st.runs))
        env["HET_RATE"] = "1" if a.rate else "0"
        t0 = time.time()
        timed_out = False
        try:
            r = subprocess.run([exe], cwd=d, env=env, capture_output=True,
                               text=True, timeout=a.timeout)
            rc, out, err = r.returncode, r.stdout, r.stderr
        except subprocess.TimeoutExpired as e:
            timed_out, rc = True, "TIMEOUT"
            out, err = _text(e.stdout), _text(e.stderr)
        secs = time.time() - t0
        log_invocation(a.log_dir, st.name, rc, env, secs, out, err)
        if timed_out:
            st.stop, st.note = "ERROR", "timeout after %d s" % a.timeout
            return
        if rc != 0:
            st.stop, st.note = "ERROR", ("harness rc=%d: %s" % (
                rc, err.strip()[-200:]))
            return
        got = parse_hetstats(out)
        if got is None:
            st.stop, st.note = "ERROR", "no HetStats machine line in harness output"
            return
        _, kv = got
        before = st.runs
        st.absorb(kv)
        if st.runs == before:
            # Zero scored runs is no progress; looping would poll a dead harness.
            st.stop, st.note = "ERROR", "invocation reported R=0 runs"
            return
        if st.usable == 0:
            # A pool with no usable run measured nothing
            # (hetlitmus/docs/harness-reporting.md sec 5).
            st.stop, st.note = "ERROR", ("usable=0 of R=%d: nothing was measured"
                                         % st.runs)
            return


def report_test(st):
    print("done  %-28s %-20s inv=%d runs=%d usable=%d k=%d k_eff=%d"
          % (st.name, st.stop, st.invocations, st.runs, st.usable, st.k, st.k_eff))


def run_campaign(a, work):
    """Drive every test in order; return (states, errors).  The state is written
    after every test, so a campaign that loses its box leaves the rows it did
    measure -- not a campaign to continue: parse_args refuses an existing --state."""
    states, errors = [], 0
    print("campaign: seed0=%d -- pass --seed0 %d to replay these seed bases."
          % (a.seed0, a.seed0))
    for t in work:
        st = TestState(t)
        states.append(st)
        drive_test(a, st, a.budget_runs)
        report_test(st)
        if st.stop == "ERROR":
            errors += 1
        save_state(a.state, states, a.seed0)
    return states, errors


def report_campaign(states, errors, secs):
    seen = [s for s in states if s.stop == "OBSERVED"]
    if seen:
        print("\ncampaign: %d row(s) ended OBSERVED -- a clean run saw the weak "
              "outcome." % len(seen))
        for s in seen:
            print("            %-28s k_eff=%d" % (s.name, s.k_eff))
    else:
        print("\ncampaign: no row ended OBSERVED.")

    if errors:
        print("campaign: %d test(s) ERRORED -- their rows are not results." % errors)
    flagged = [s for s in states if s.flags]
    if flagged:
        print("campaign: %d row(s) carry harness flags:" % len(flagged))
        for s in flagged:
            print("            %-28s flags=0x%x" % (s.name, s.flags))

    print("\ncampaign: total wall clock %.1f s over %d row(s)."
          % (secs, len(states)))


def main():
    a = parse_args()
    work = plan_schedule(a, select_work(a, corpus_tests(a.corpus)))
    if a.dry_run:
        for t in work:
            print("  plan %s" % t)
        return 0
    t0 = time.time()
    states, errors = run_campaign(a, work)
    report_campaign(states, errors, time.time() - t0)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
