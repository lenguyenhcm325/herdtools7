#!/usr/bin/env python3
"""The campaign scheduler: where the hardware hours are spent, or saved.

One policy for every row -- het_verdict.h's, no harness carrying a prediction: pooled
here, per-invocation in the harness (HET_ADAPTIVE=1); `check_flag_mirror' pins what must
agree.  hetlitmus/docs/harness-reporting.md sec 5; knobs, hetlitmus/spotcheck/README.md.
`--runner' is a template (`{test}', `{dir}') running ONE invocation of `./<test>' -- not
litmus7's `./run.exe' -- and forwarding its stdout.
Exit: 0 = completed; 2 = configuration/corpus error; 1 = a test errored or ended
UNCONFIRMED-SIGHTING, which demands a human before anything is written up.
"""

import argparse
import csv
import os
import re
import shlex
import subprocess
import sys

# A prime stride far above any plausible NUMBER_OF_RUN: the harness consumes
# base + run, so bases never collide across invocations of one test.
SEED_STRIDE = 100003

# The mirrored half of het_verdict.h's stopping rule; check_flag_mirror() below pins
# every name and number here against the header.
CORROB_RUNS = 2                      # HET_CORROB_RUNS
CONFIRM_RUNS = 30                    # the driver's HET_CONFIRM_RUNS default
STOP_NAMES = {
    "HET_CAMPAIGN_STOP_CORROBORATED": "CORROBORATED",
    "HET_CAMPAIGN_STOP_UNCONFIRMED":  "UNCONFIRMED-SIGHTING",
    "HET_CAMPAIGN_STOP_BUDGET":       "BUDGET",
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


# This file also travels without the repo (hetlitmus/spotcheck/pack-bundle.sh), so the
# cross-check is conditional: header present means it must agree, out of reach means
# the mirror stands.
_VERDICT_H = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                          "litmus", "het-runtime", "het_verdict.h")


def check_flag_mirror(path=_VERDICT_H, corrob=CORROB_RUNS, stops=None):
    """Every stop-name string as `path` defines it, or None when the header is out of
    reach.  HET_CORROB_RUNS is checked against `corrob`, not returned."""
    stops = STOP_NAMES if stops is None else stops
    # This driver's own consistency, checked with or without the header: a stop it can
    # write but never treats as terminal loops forever.
    if set(TERMINAL) != set(stops.values()) | {"ERROR"}:
        die("TERMINAL %s does not match the stop names %s plus ERROR"
            % (sorted(TERMINAL), sorted(stops.values())))
    try:
        with open(path) as fh:
            text = fh.read()
    except (IOError, OSError):
        return None
    mc = re.search(r"^#define[ \t]+HET_CORROB_RUNS[ \t]+(\d+)", text, re.M)
    if mc is None:
        die("%s no longer defines HET_CORROB_RUNS -- the corroboration bar this "
            "scheduler applies cannot be verified against the one the harness does"
            % path)
    if int(mc.group(1)) != corrob:
        die("%s drifted: HET_CORROB_RUNS is %s there, %d here -- the scheduler and "
            "the harness would corroborate a sighting at different run counts"
            % (path, mc.group(1), corrob))
    got = dict(re.findall(r"case[ \t]+(HET_CAMPAIGN_STOP_\w+):[ \t]*"
                          r'return[ \t]+"([^"]*)";', text))
    if got != stops:
        die("%s drifted on the stop names: %s there, %s here -- the scheduler writes "
            "these strings into its state file and reads them back as terminal"
            % (path, sorted(got.items()), sorted(stops.items())))
    if not re.search(r'default:[ \t]*return[ \t]+"CONTINUE";', text):
        die("%s no longer returns \"CONTINUE\" for a non-stop -- the scheduler treats "
            "every name it does not know as terminal" % path)
    # Where the window starts is policy a name cannot carry: a header measuring it from
    # run 0 rather than from the sighting ends rows this scheduler would still run.
    if not re.search(r"n[ \t]*-[ \t]*st\.n_at_first_sight[ \t]*>=[ \t]*confirm_runs",
                     text):
        die("%s no longer measures the confirmation window from n_at_first_sight -- "
            "the harness and this scheduler would close a lone sighting's window at "
            "different runs, and a late sighting would be banked with none of it run"
            % path)
    return got


check_flag_mirror()


class TestState(object):
    def __init__(self, name):
        self.name = name
        self.invocations = 0
        self.runs = 0            # records actually scored (sum of R)
        self.usable = 0
        self.k = self.k_eff = self.k_runs = 0
        # Pooled runs spent when the first clean sighting landed; 0 = none has, and a
        # row ending UNCONFIRMED reports how long ago the one sighting was.
        self.runs_at_first_sight = 0
        self.stop = ""
        self.note = ""
        # From the HetStats line, 0 until a line says otherwise: it caps what a
        # sighting on this row licenses [Goens23 sec 4.6].
        self.cpu_only = 0

    def absorb(self, kv):
        self.invocations += 1
        # Resolves upward across the pool, as het_stats_compute resolves it: ONE
        # CPU-only invocation withholds the compound reading from the whole row.
        if int(fnum(kv, "cpu_only")):
            self.cpu_only = 1
        before = self.runs
        self.runs += int(fnum(kv, "R"))
        self.usable += int(fnum(kv, "usable"))
        self.k += int(fnum(kv, "k"))
        k_eff = int(fnum(kv, "k_eff"))
        self.k_eff += k_eff
        self.k_runs += int(fnum(kv, "k_runs"))
        if self.runs_at_first_sight == 0 and k_eff > 0:
            # first_sight is the runs THIS invocation spent before its first clean
            # sighting; the pooled price adds the runs before it started.  One that
            # reported none falls back to its whole R, which can only over-state.
            fs = int(fnum(kv, "first_sight"))
            self.runs_at_first_sight = before + (fs if fs > 0 else int(fnum(kv, "R")))

    def sighting_open(self, rate_mode):
        """A clean sighting not yet corroborated -- what holds a row open past its
        budget.  k_eff, NEVER k: a rejected sighting neither stops a row nor holds one."""
        return (not rate_mode) and self.k_eff > 0 and self.k_runs < CORROB_RUNS

    def target_runs(self, budget, rate_mode, confirm_runs):
        """The runs this row is still entitled to.  An open sighting holds it past the
        budget as far as the confirmation window, which moves with the sighting; the
        invocation is told, or HET_RUNS_MAX would curtail what this scheduler overruled."""
        if self.sighting_open(rate_mode):
            return max(budget, self.runs_at_first_sight + max(confirm_runs, 1))
        return budget

    def decide(self, budget, rate_mode, confirm_runs):
        """het_campaign_should_stop(), at the pooled scale: `runs' here is what `n' is
        there.  The order of the arms is the policy and must NOT be rearranged."""
        if self.stop:
            return self.stop
        if confirm_runs < 1:
            confirm_runs = 1
        if self.k_eff > 0 and not rate_mode:
            if self.k_runs >= CORROB_RUNS:
                self.stop, self.note = "CORROBORATED", (
                    "the weak outcome reproduced in %d distinct clean run(s)"
                    % self.k_runs)
            elif self.runs - self.runs_at_first_sight >= confirm_runs:
                # The window elapses FROM the sighting (het_verdict.h's rule): read
                # off the pooled count alone, a late sighting is banked unrun.
                self.stop, self.note = "UNCONFIRMED-SIGHTING", (
                    "the confirmation window (%d runs) closed on a lone clean sighting "
                    "that did not reproduce; it first fired at run %d"
                    % (confirm_runs, self.runs_at_first_sight))
            return self.stop            # outranks the budget stop below
        if budget > 0 and self.runs >= budget:
            self.stop = "BUDGET"
        return self.stop


def save_state(path, states):
    cols = ["test", "stop", "invocations", "runs", "usable", "k", "k_eff",
            "k_runs", "first_sight", "cpu_only", "note"]
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for s in states:
            w.writerow([s.name, s.stop, s.invocations, s.runs, s.usable,
                        s.k, s.k_eff, s.k_runs, s.runs_at_first_sight,
                        s.cpu_only, s.note])


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True,
                    help="directory holding one emitted harness dir per test")
    ap.add_argument("--runner", required=True,
                    help="command template; {test} and {dir} are substituted")
    ap.add_argument("--budget-runs", type=int, default=100,
                    help="max runs per row")
    ap.add_argument("--rate", action="store_true",
                    help="HET_RATE: run to budget even after the outcome is seen, so "
                         "a row that fires yields a rate (sightings stop nothing)")
    ap.add_argument("--confirm-runs", type=int, default=CONFIRM_RUNS,
                    help="HET_CONFIRM_RUNS: runs a LONE clean sighting may hold a row "
                         "open for before it ends UNCONFIRMED-SIGHTING")
    ap.add_argument("--seed0", type=int, default=20260714)
    ap.add_argument("--state", default="campaign-state.csv")
    ap.add_argument("--tests", default="",
                    help="comma-separated subset (default: every harness dir in "
                         "--corpus)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    # A budget of 0 or less is "no budget" to het_verdict.h's rule, which the harness
    # can afford (its run loop is bounded by the record array) and this loop cannot.
    if a.budget_runs < 1:
        die("--budget-runs %d names no bound, and this driver loops until one is "
            "reached" % a.budget_runs)
    # save_state rewrites --state whole after every test, so starting on a file that
    # holds rows overwrites measurements nothing here re-ran.  The bar is existence,
    # NOT terminality: a half-written state is a reading too.
    if os.path.exists(a.state):
        die("--state %s already exists and a campaign is never resumed: running on "
            "would silently overwrite the rows it holds. Move it aside, or point "
            "--state at a fresh path." % a.state)
    return a


def select_work(a, tests):
    """Those named by --tests, else the whole corpus.  A named test with no harness dir
    is FAIL CLOSED, not a skip."""
    known = set(tests)
    subset = [t for t in a.tests.split(",") if t] or list(tests)
    missing = [t for t in subset if t not in known]
    if missing:
        die("no harness dir under %s for: %s -- fail closed, nothing to schedule"
            % (a.corpus, ", ".join(missing[:5])))
    return sorted(subset)


def plan_schedule(a, work):
    """`work` in run order, plus what the schedule costs.  One policy, so one order and
    one budget: a row stops early because its sighting corroborated."""
    # The worst case carries the window: a sighting in the last budgeted run is
    # entitled to confirm_runs after it, so a row can cost budget + confirm_runs.
    # --rate turns the sighting stop off and caps at the budget.
    per_row = a.budget_runs + (0 if a.rate else a.confirm_runs)
    print("campaign: %d test(s), one stop rule each: corroborated sighting, lone "
          "sighting %d run(s) after it fires, or %d run(s) spent.  Worst case %d runs."
          % (len(work), a.confirm_runs, a.budget_runs, len(work) * per_row))
    if a.rate:
        print("campaign: --rate: a sighting stops NOTHING; every row runs to its "
              "budget, so a row that fires yields a rate.")
    return work


def drive_test(a, st, budget):
    """Invoke one test's runner until its stop rule fires, pooling each HetStats line.
    Every failure mode ends the test as ERROR rather than looping on it."""
    while not st.decide(budget, a.rate, a.confirm_runs):
        env = dict(os.environ)
        env["HET_SEED"] = str(a.seed0 + st.invocations * SEED_STRIDE)
        env["HET_ADAPTIVE"] = "1"
        # The harness applies the SAME rule inside the invocation, so it gets the same
        # knobs -- including an entitlement an open sighting can raise above the budget.
        env["HET_RUNS_MAX"] = str(max(
            1, st.target_runs(budget, a.rate, a.confirm_runs) - st.runs))
        env["HET_RATE"] = "1" if a.rate else "0"
        env["HET_CONFIRM_RUNS"] = str(a.confirm_runs)
        cmd = a.runner.replace("{test}", st.name).replace(
            "{dir}", os.path.join(a.corpus, st.name))
        r = subprocess.run(cmd if os.name == "nt" else shlex.split(cmd),
                           env=env, capture_output=True, text=True)
        if r.returncode != 0:
            st.stop, st.note = "ERROR", ("runner rc=%d: %s" % (
                r.returncode, r.stderr.strip()[-200:]))
            return
        got = parse_hetstats(r.stdout)
        if got is None:
            st.stop, st.note = "ERROR", "no HetStats machine line in runner output"
            return
        _, kv = got
        before = st.runs
        st.absorb(kv)
        if st.runs == before:
            # Zero scored runs is no progress; looping would poll a dead harness.
            st.stop, st.note = "ERROR", "invocation reported R=0 runs"
            return


def report_test(st):
    print("done  %-28s %-20s inv=%d runs=%d k=%d k_eff=%d k_runs=%d%s"
          % (st.name, st.stop, st.invocations, st.runs, st.k, st.k_eff,
             st.k_runs,
             ("  ** " + st.note + " **")
             if st.stop == "UNCONFIRMED-SIGHTING" else ""))


def run_campaign(a, work):
    """Drive every test in order; return (states, errors, unconfirmed).  The state is
    written after every test, so a campaign that loses its box leaves the rows it did
    measure -- not a campaign to continue: parse_args refuses an existing --state."""
    states, errors, unconfirmed = [], 0, 0
    for t in work:
        st = TestState(t)
        states.append(st)
        drive_test(a, st, a.budget_runs)
        report_test(st)
        if st.stop == "ERROR":
            errors += 1
        if st.stop == "UNCONFIRMED-SIGHTING":
            unconfirmed += 1
        save_state(a.state, states)
    return states, errors, unconfirmed


def report_campaign(states, errors, unconfirmed):
    corrob = [s for s in states if s.stop == "CORROBORATED"]
    print("\ncampaign: %d row(s) ended CORROBORATED -- the weak outcome was observed "
          "and reproduced.  What that is worth against any model is settled offline, "
          "against a verdicts file the reader supplies; nothing here says."
          % len(corrob))
    for s in corrob:
        print("            %-28s k_runs=%d cpu_only=%d" % (s.name, s.k_runs,
                                                           s.cpu_only))

    if errors:
        print("campaign: %d test(s) ERRORED -- their rows are not results." % errors)
    if unconfirmed:
        rows = [s for s in states if s.stop == "UNCONFIRMED-SIGHTING"]
        print("campaign: ** %d row(s) ended UNCONFIRMED-SIGHTING: the confirmation "
              "window closed on a lone clean sighting that did not reproduce. **"
              % unconfirmed)
        print("campaign:    The sighting STANDS -- falsification is one-sided and a "
              "positive needs no control -- but a sighting that does not reproduce is "
              "the most damaging thing a campaign can write down, so reproduce it "
              "(--rate, or a larger --budget-runs and --confirm-runs) before it is "
              "written up.")
        for s in rows:
            print("            %-28s first fired at run %d of %d  cpu_only=%d"
                  % (s.name, s.runs_at_first_sight, s.runs, s.cpu_only))

    # A precondition on the campaign, not a result of it: until a CPU-only row fires,
    # the memory type of the shared allocation is unestablished and every null above
    # rests on it.  hetlitmus/docs/het-emission.md "The CPU-only set", [APM Table 7-2].
    cpu_only_rows = [s for s in states if s.cpu_only]
    if not cpu_only_rows:
        # The het corpus alone holds no CPU-only row, so the absent case has to
        # print: silence here would read as a satisfied precondition.
        print("\ncampaign write-back probe (CPU-only positive control): *** NOT RUN.  "
              "No CPU-only row was in this campaign, so the probe did NOT pass: the "
              "memory type of the shared allocation stays UNRESOLVED and every null "
              "above rests on it.  Generate the set (`make hetlitmus-cpuonly') and "
              "run it on THIS box -- a reading from another machine is not one. ***")
    else:
        fired = [s for s in cpu_only_rows if s.k_eff > 0]
        print("\ncampaign write-back probe (CPU-only positive control): %d CPU-only "
              "row(s), %d of them fired." % (len(cpu_only_rows), len(fired)))
        if not fired:
            print("campaign write-back probe: *** FAILED -- not one CPU-only row "
                  "fired.  The x86 store buffer is the most reproducible relaxation "
                  "the ISA has, so this is evidence about the SHARED ALLOCATION and "
                  "not about the window: check PAT/MTRR and /proc/self/smaps for this "
                  "allocator before reporting anything. ***")
        else:
            print("campaign write-back probe: PASSED (%s) -- a UC mapping is ruled "
                  "out for this allocator.  It does NOT establish WB over WC; only "
                  "the CPU-only shapes that stay silent do that."
                  % ", ".join(s.name for s in fired))


def main():
    a = parse_args()
    work = plan_schedule(a, select_work(a, corpus_tests(a.corpus)))
    if a.dry_run:
        for t in work:
            print("  plan %s" % t)
        return 0
    states, errors, unconfirmed = run_campaign(a, work)
    report_campaign(states, errors, unconfirmed)
    return 1 if (errors or unconfirmed) else 0


if __name__ == "__main__":
    sys.exit(main())
