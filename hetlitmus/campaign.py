#!/usr/bin/env python3
"""The campaign scheduler: where the GPU hours are spent, or saved (B7b;
env-research/impl-briefs/B7b-impl-brief.md, Q3-stats.md).

A defensible "Never" needs a bound, and a bound costs thousands of runs per test.  No
harness carries a prediction, so there is no class to schedule against and every row
gets the SAME policy: run it until its sighting is corroborated, until a lone sighting
outlives the confirmation window, until its false-negative bound reaches --p-goal, or
until its budget is gone.

THE POLICY IS het_verdict.h's, MIRRORED.  `TestState.decide' below is a transcription
of het_campaign_should_stop() -- same precedence, same guards, same names -- applied at
the cross-invocation scale (pooled runs) instead of the in-invocation one (records so
far).  Within one invocation the harness applies it itself (HET_ADAPTIVE=1), so the two
layers cannot disagree about a row; `check_flag_mirror' pins the constants and the stop
names against the header so they cannot drift silently either.

  --rate (HET_RATE=1) turns the sighting stop off: the row runs to its budget and
     yields a RATE rather than a first sighting.  The bound and the budget still stop it.
  --confirm-runs (HET_CONFIRM_RUNS) is how long a LONE clean sighting may hold a row
     open while failing to reproduce.  It OUTRANKS the budget stop, because a row ended
     at BUDGET on one sighting banks "seen once, stopped looking"; het_verdict.h states
     the precedence and what it deliberately does not outrank.

  H > 1 (parallel het pairs) is deliberately absent: it is real emitter work, the pairs
     share the interconnect so DEFF eats part of the gain, and it is the lever most
     likely to be redundant once N_eff is measured.  Build it only if N_eff comes out
     small.

POOLING ACROSS INVOCATIONS (the arithmetic, stated so it can be audited; `absorb' and
`pooled_bound' implement it).  Invocations use FRESH seed bases, since replaying a seed
adds no new phase draws and pooling replays would double-count R_eff, so they are
independent replicates:  k* and k_runs* are sums; R_eff* sums only over invocations
that themselves reported a bound; and bound* = max(mu_upper_i) / R_eff* -- the widest
numerator over the summed denominator, i.e. conservative.  An invocation whose
dispersion went unmeasured printed no bound, so pooling its effort would invent one.

RUNNER CONTRACT: --runner is a command template with '{test}' and '{dir}' substituted.
It must execute ONE invocation of the test's harness binary and forward the harness
stdout -- the HetStats line is the whole interface.  Per invocation this driver sets
HET_SEED (a fresh base), HET_ADAPTIVE=1, HET_RUNS_MAX, HET_RATE, HET_CONFIRM_RUNS and
HET_P_GOAL.  Nothing here needs a GPU: hetlitmus/verify/statscheck.py phase 6 drives it
end to end against a stub runner.

The runner is 'sh spotcheck/run-one.sh {dir} {test}', which is `cd {dir}; exec
./{test}'.  NOT ./run.exe -- that is upstream litmus7's binary name and no het
harness emits one; the het link targets write ./<test>.

VENDOR-AGNOSTIC ON PURPOSE, AND MEASURED (P2c, 2026-08-03): this file contains
zero occurrences of `cuda' or `hip', and it needs none.  Both vendors' link
targets -- `comp.sh cuda-link' / `make cuda-bin' and `comp.sh hip-link' / `make
hip-bin' -- write the SAME ./<test>, so an AMD campaign differs from an NVIDIA one
only in which target built the binary, which happens before this driver is
invoked.  Adding a --target axis here would be a knob with nothing behind it.

Usage:
  campaign.py --corpus <dir of emitted harness dirs>
              --runner CMD [--p-goal F] [--budget-runs N] [--rate]
              [--confirm-runs N] [--state campaign.csv] [--seed0 N] [--dry-run]
              [--tests A,B,...]
Exit: 0 = campaign completed; 2 = configuration/corpus error (fail closed);
      1 = completed but >=1 test errored or ended UNCONFIRMED-SIGHTING (a row that
          is not a result, and a sighting that would not reproduce: both demand a
          human before anything is written up).
"""

import argparse
import csv
import os
import re
import shlex
import subprocess
import sys

# A prime stride far above any plausible NUMBER_OF_RUN: invocation i of a test uses
# seed base seed0 + i*SEED_STRIDE, and the harness consumes seed base + run for
# run < NUMBER_OF_RUN, so bases never collide across invocations of one test.
SEED_STRIDE = 100003

# THE MIRRORED HALF OF het_verdict.h's STOPPING RULE.  Every name and number here is
# pinned against the header by check_flag_mirror() below, so a change on one side and
# not the other is fatal rather than silent.
CORROB_RUNS = 2                      # HET_CORROB_RUNS
CONFIRM_RUNS = 30                    # the driver's HET_CONFIRM_RUNS default
STOP_NAMES = {
    "HET_CAMPAIGN_STOP_CORROBORATED": "CORROBORATED",
    "HET_CAMPAIGN_STOP_UNCONFIRMED":  "UNCONFIRMED-SIGHTING",
    "HET_CAMPAIGN_STOP_BOUND_MET":    "BOUND-MET",
    "HET_CAMPAIGN_STOP_BUDGET":       "BUDGET",
}
# ERROR is this driver's own: the harness produced no readable row, which the C rule
# never sees because it only ever reads records it was handed.
TERMINAL = tuple(sorted(STOP_NAMES.values())) + ("ERROR",)


def die(msg):
    sys.stderr.write("campaign: FATAL: %s\n" % msg)
    sys.exit(2)


def corpus_tests(corpus):
    """The tests to schedule: one row per emitted harness dir.  The corpus IS the
    source -- a harness is what a row of this campaign runs, so a name with no harness
    is not a row."""
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


# het_verdict.h HET_ST_TAU_UNRESOLVED: tau was not resolved by this invocation's
# pooled stream, so N_eff fell back to 1 -- the conservative reading.
HET_ST_TAU_UNRESOLVED = 1 << 14

# The bit above, CORROB_RUNS and STOP_NAMES are hand-mirrors of the header, and a
# scheduler applying a stale copy of the policy the harness applies is the drift this
# whole file is written to avoid.  This file is also deliberately standalone -- it is
# copied on its own onto a rented GPU box -- so the cross-check is conditional on the
# header being reachable at its in-repo path: present means it must agree, out of
# reach means the mirror stands.
_VERDICT_H = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                          "litmus", "het-runtime", "het_verdict.h")


def check_flag_mirror(path=_VERDICT_H, name="HET_ST_TAU_UNRESOLVED",
                      mirrored=HET_ST_TAU_UNRESOLVED, corrob=CORROB_RUNS,
                      stops=None):
    """The bit `name`, HET_CORROB_RUNS and every stop-name string, as `path` defines
    them -- or None when the header is out of reach.  Any disagreement is fatal, and so
    is a header that no longer defines one of them."""
    stops = STOP_NAMES if stops is None else stops
    # The terminal set is this driver's own consistency, checked with or without the
    # header: a stop the scheduler can write but never treats as terminal loops forever.
    if set(TERMINAL) != set(stops.values()) | {"ERROR"}:
        die("TERMINAL %s does not match the stop names %s plus ERROR"
            % (sorted(TERMINAL), sorted(stops.values())))
    try:
        with open(path) as fh:
            text = fh.read()
    except (IOError, OSError):
        return None
    m = re.search(r"^#define[ \t]+%s[ \t]+\([ \t]*1u?[ \t]*<<[ \t]*(\d+)[ \t]*\)"
                  % re.escape(name), text, re.M)
    if m is None:
        die("%s no longer defines %s -- the mirrored bit cannot be verified, and an "
            "unverifiable mirror of a flag word is not one" % (path, name))
    bit = 1 << int(m.group(1))
    if bit != mirrored:
        die("%s drifted: %s is 1<<%s there, 0x%x here" % (path, name, m.group(1),
                                                          mirrored))
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
    return bit


check_flag_mirror()


def flags(kv):
    """The HetStats line carries flags=0x<hex>."""
    try:
        return int(kv.get("flags", "0"), 16)
    except ValueError:
        return 0


class TestState(object):
    def __init__(self, name):
        self.name = name
        self.invocations = 0
        self.runs = 0            # records actually scored (sum of R)
        self.usable = 0
        self.k = self.k_eff = self.k_runs = 0
        # Pooled runs spent when the first CLEAN sighting landed; 0 = none has.  The
        # price of a sighting in the unit the campaign spends, carried so a row that
        # ends UNCONFIRMED can say how long ago the one sighting was.
        self.runs_at_first_sight = 0
        self.R_eff = 0.0         # summed over MEASURED invocations only
        self.mu_upper_max = 0.0
        self.nwin = 0
        self.tau_w = self.N_eff = -1.0   # last measured (reporting only)
        # An invocation whose tau was unresolved scored N_eff = 1: not an error and not
        # a dead end, but a PRICE, with tau_need the price in runs.  Carried so the
        # campaign can say which rows bought no dividend and what buying one costs.
        self.tau_unresolved = 0          # invocations whose tau was unresolved
        self.tau_need_max = 0            # ... and the largest run count they wanted
        self.stop = ""
        self.note = ""
        # The HetStats line carries `cpu_only=<0|1>', and it caps what a sighting on
        # this row licenses: on an all-CPU cycle no cross-device path carried the
        # cycle.  Read rather than assumed, and 0 until a line says otherwise.
        self.cpu_only = 0

    def pooled_bound(self):
        if self.k > 0 or self.R_eff <= 0.0 or self.mu_upper_max <= 0.0:
            return -1.0
        return self.mu_upper_max / self.R_eff

    def absorb(self, kv):
        self.invocations += 1
        # cpu_only resolves UPWARD across invocations, the same direction
        # het_stats_compute resolves it in: the CPU-only sentence is the WEAKER
        # claim about the compound model, so one D10 invocation in the pool is
        # enough to withhold the compound reading from the whole row.
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
            # sighting; the pooled price adds the runs spent before it started.  An
            # invocation that reported none falls back to its whole run count, which
            # can only over-state the price.
            fs = int(fnum(kv, "first_sight"))
            self.runs_at_first_sight = before + (fs if fs > 0 else int(fnum(kv, "R")))
        nwin = int(fnum(kv, "nwin"))
        if self.nwin and nwin and nwin != self.nwin:
            # tau_w/F_win/N_eff are window-resolution dependent (het_verdict.h), so
            # records scored at different resolutions must not be silently pooled.
            self.stop, self.note = "ERROR", (
                "nwin changed mid-test (%d -> %d): a swept HET_NWIN needs a fresh "
                "campaign state, not a silent pool" % (self.nwin, nwin))
            return
        self.nwin = nwin or self.nwin
        mu = fnum(kv, "mu_upper", -1.0)
        reff = fnum(kv, "R_eff", 0.0)
        p_bound = fnum(kv, "p_bound", -1.0)
        # Only an invocation that reported a bound itself may contribute effort to the
        # pooled one: p_bound >= 0 implies its dispersion was measured.
        if p_bound >= 0.0 and reff > 0.0:
            self.R_eff += reff
            self.mu_upper_max = max(self.mu_upper_max, mu)
        if fnum(kv, "tau_w", -1.0) > 0.0:
            self.tau_w = fnum(kv, "tau_w")
            self.N_eff = fnum(kv, "N_eff", -1.0)
        # An unresolved tau needs no special case: N_eff = 1 makes this invocation's
        # R_eff conservative and the pooled bound wider, so the row keeps running of its
        # own accord.  Never an ERROR -- that would de-schedule a test for being honest
        # -- and a BOUND-MET earned on the conservative reading stands.  What the
        # campaign owes the operator is the price, in runs.
        if flags(kv) & HET_ST_TAU_UNRESOLVED:
            self.tau_unresolved += 1
            self.tau_need_max = max(self.tau_need_max, int(fnum(kv, "tau_need", 0)))

    def sighting_open(self, rate_mode):
        """A CLEAN sighting this row has not corroborated yet -- the state that holds a
        row open past its budget.  k_eff, never k: a sighting the decode guard rejected
        can neither stop a row nor keep one alive."""
        return (not rate_mode) and self.k_eff > 0 and self.k_runs < CORROB_RUNS

    def target_runs(self, budget, rate_mode, confirm_runs):
        """The runs this row is still entitled to.  An open sighting holds it past the
        budget as far as the confirmation window, so the invocation has to be TOLD
        that: HET_RUNS_MAX derived from the budget alone would hand the harness a
        curtailment this scheduler has already overruled."""
        if self.sighting_open(rate_mode):
            return max(budget, max(confirm_runs, 1))
        return budget

    def decide(self, p_goal, budget, rate_mode, confirm_runs):
        """het_campaign_should_stop(), at the pooled scale: `runs' here is what `n' is
        there.  The order of the arms IS the policy and must not be rearranged."""
        if self.stop:
            return self.stop
        if confirm_runs < 1:
            confirm_runs = 1
        if self.k_eff > 0 and not rate_mode:
            if self.k_runs >= CORROB_RUNS:
                self.stop, self.note = "CORROBORATED", (
                    "the weak outcome reproduced in %d distinct clean run(s)"
                    % self.k_runs)
            elif self.runs >= confirm_runs:
                self.stop, self.note = "UNCONFIRMED-SIGHTING", (
                    "the confirmation window (%d runs) closed on a lone clean sighting "
                    "that did not reproduce; it first fired at run %d"
                    % (confirm_runs, self.runs_at_first_sight))
            return self.stop            # outranks the budget stop below
        if self.k == 0 and p_goal > 0.0:
            b = self.pooled_bound()
            # b >= 1 bounds nothing (het_verdict.h HET_ST_BOUND_VACUOUS), so it may not
            # meet a goal however generous the goal is.
            if 0.0 <= b < 1.0 and b <= p_goal:
                self.stop = "BOUND-MET"
        if not self.stop and budget > 0 and self.runs >= budget:
            self.stop = "BUDGET"
        return self.stop


def load_state(path):
    rows = {}
    if path and os.path.exists(path):
        with open(path) as fh:
            for r in csv.DictReader(fh):
                rows[r["test"]] = r
    return rows


def save_state(path, states):
    cols = ["test", "stop", "invocations", "runs", "usable", "k", "k_eff",
            "k_runs", "first_sight", "R_eff", "mu_upper_max", "pooled_bound",
            "nwin", "tau_w", "N_eff", "tau_unresolved", "tau_need", "cpu_only",
            "note"]
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for s in states:
            w.writerow([s.name, s.stop, s.invocations, s.runs, s.usable,
                        s.k, s.k_eff, s.k_runs, s.runs_at_first_sight,
                        "%.6g" % s.R_eff, "%.6g" % s.mu_upper_max,
                        "%.6g" % s.pooled_bound(), s.nwin, "%.4g" % s.tau_w,
                        "%.4g" % s.N_eff, s.tau_unresolved, s.tau_need_max,
                        s.cpu_only, s.note])


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True,
                    help="directory holding one emitted harness dir per test")
    ap.add_argument("--runner", required=True,
                    help="command template; {test} and {dir} are substituted")
    ap.add_argument("--p-goal", type=float, default=-1.0,
                    help="stop a row once its pooled bound <= this "
                         "(unset: rows run to budget)")
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
    """`work` in run order, plus what the schedule costs at the budgets passed.  One
    policy, so one order and one budget: the row that stops early is the one whose
    sighting corroborates or whose bound arrives, not the one whose class was cheap."""
    print("campaign: %d test(s), one stop rule each: corroborated sighting, lone "
          "sighting past %d run(s), pooled bound <= %s, or %d run(s) spent.  Worst "
          "case %d runs."
          % (len(work), a.confirm_runs,
             ("%g" % a.p_goal) if a.p_goal > 0.0 else "(no goal)",
             a.budget_runs, len(work) * a.budget_runs))
    if a.rate:
        print("campaign: --rate: a sighting stops NOTHING; every row runs to its "
              "bound or its budget, so a row that fires yields a rate.")
    if a.p_goal <= 0.0:
        print("campaign: NOTE --p-goal unset: every row will run to budget "
              "(a stopping target is a campaign decision; none is baked in).")
    return work


def drive_test(a, st, budget):
    """Invoke one test's runner until its stop rule fires, pooling each HetStats line.
    Every failure mode ends the test as ERROR rather than looping on it."""
    while not st.decide(a.p_goal, budget, a.rate, a.confirm_runs):
        env = dict(os.environ)
        env["HET_SEED"] = str(a.seed0 + st.invocations * SEED_STRIDE)
        env["HET_ADAPTIVE"] = "1"
        # The harness applies the SAME rule inside the invocation, so it is handed the
        # same knobs -- including the run count this row is entitled to, which an open
        # sighting can raise above the budget.
        env["HET_RUNS_MAX"] = str(max(
            1, st.target_runs(budget, a.rate, a.confirm_runs) - st.runs))
        env["HET_RATE"] = "1" if a.rate else "0"
        env["HET_CONFIRM_RUNS"] = str(a.confirm_runs)
        if a.p_goal > 0.0:
            env["HET_P_GOAL"] = repr(a.p_goal)
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
            # An invocation that scored zero runs makes no progress, and looping on
            # it would poll the same dead harness forever.
            st.stop, st.note = "ERROR", "invocation reported R=0 runs"
            return


def report_test(st):
    b = st.pooled_bound()
    print("done  %-28s %-20s inv=%d runs=%d k=%d k_eff=%d k_runs=%d "
          "R_eff=%.4g bound=%s%s%s"
          % (st.name, st.stop, st.invocations, st.runs, st.k, st.k_eff,
             st.k_runs, st.R_eff, ("%.4g" % b) if b >= 0 else "-",
             ("  tau-UNRESOLVED in %d/%d inv (needs >=%d runs/inv)"
              % (st.tau_unresolved, st.invocations, st.tau_need_max))
             if st.tau_unresolved else "",
             ("  ** " + st.note + " **")
             if st.stop == "UNCONFIRMED-SIGHTING" else ""))


def run_campaign(a, work):
    """Drive every test in order and return (states, errors, unconfirmed).  A row
    already terminal in --state is resumed, not re-run, and the state is written after
    every test so the campaign survives losing the box."""
    prior = load_state(a.state)
    states, errors, unconfirmed = [], 0, 0
    for t in work:
        st = TestState(t)
        states.append(st)
        # A ROW MAY ONLY BE RESUMED BY THE STOP RULE THAT WROTE IT.  The stop name IS
        # the rule's signature, so a stop this policy cannot write was written by
        # another one -- an oracle-era OBSERVED or CONFIRMED, say -- and resuming it
        # would bank an adjudication no harness here makes.
        if t in prior:
            pstop = (prior[t].get("stop") or "").strip()
            if pstop and pstop not in TERMINAL:
                die("%s carries stop=%r in %s, which this stop rule cannot write: the "
                    "row was banked by another policy and is not resumable by this one"
                    % (t, pstop, a.state))
        if t in prior and prior[t].get("stop") in TERMINAL:
            st.stop = prior[t]["stop"]
            st.note = "resumed: terminal in %s" % a.state
            print("skip  %-28s %s (from state)" % (t, st.stop))
            # A resumed row still counts: a banked flagged row that nobody counted
            # would let a resuming campaign exit 0 over it.
            if st.stop == "ERROR":
                errors += 1
            if st.stop == "UNCONFIRMED-SIGHTING":
                unconfirmed += 1
            continue
        drive_test(a, st, a.budget_runs)
        report_test(st)
        if st.stop == "ERROR":
            errors += 1
        if st.stop == "UNCONFIRMED-SIGHTING":
            unconfirmed += 1
        save_state(a.state, states)   # after every test: the campaign is resumable
    return states, errors, unconfirmed


def report_campaign(states, errors, unconfirmed):
    corrob = [s for s in states if s.stop == "CORROBORATED"]
    print("\ncampaign: %d row(s) ended CORROBORATED -- the weak outcome was observed "
          "and reproduced.  What that is worth against any model is settled offline "
          "(hetlitmus/oracle-compare.sh); nothing here says." % len(corrob))
    for s in corrob:
        print("            %-28s k_runs=%d cpu_only=%d" % (s.name, s.k_runs,
                                                           s.cpu_only))

    # The price of the unclaimed dividend.  These rows are not failures and their
    # bounds are not wrong; they are the conservative bounds, because the run count
    # they were given could not resolve their tau.  Surfaced, never auto-applied:
    # raising the run count spends GPU hours, so it is a campaign decision like
    # --p-goal and HET_P_MIN.
    unres = [s for s in states if s.tau_unresolved]
    if unres:
        need = max(s.tau_need_max for s in unres)
        print("campaign: %d test(s) ended with tau UNRESOLVED -- their N_eff could "
              "NOT be claimed, so they report B7's conservative (wider) bound.  This "
              "is a PRICE, not a failure: the criterion is on the POOLED window count "
              "(usable runs x HET_NWIN), so it relaxes with RUNS.  The hungriest row "
              "wants >= %d usable run(s) per invocation; re-run those tests with a "
              "larger NUMBER_OF_RUN / --budget-runs to buy the dividend.  (Grow R, "
              "NOT N: extra iterations only add correlated frames inside the same "
              "alignment windows.)" % (len(unres), need))
        for s in unres:
            print("            %-28s tau_w=%.4g  needs >=%d runs/inv "
                  "(had %d over %d invocation(s))"
                  % (s.name, s.tau_w, s.tau_need_max,
                     s.runs // max(s.invocations, 1), s.invocations))
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

    # D10 -- the CPU-only positive control, and it is a PRECONDITION, not a row.
    # memo sect 7.D10: SB and R must be OBSERVED (the store buffer is live, which
    # rules a UC mapping out for this allocator).  Until it is, the memory type of
    # the shared allocation is unestablished and every null in this campaign rests
    # on an unchecked assumption about it -- so this is checked before, not after,
    # anyone reads the bounds above.
    d10 = [s for s in states if s.cpu_only]
    if not d10:
        # A SILENTLY ABSENT PRECONDITION IS THE FAILURE MODE THIS BLOCK EXISTS TO
        # PREVENT.  It used to run under a bare `if d10:' with no else, so a campaign
        # over the het corpus alone -- the normal case -- printed no D10 line at all
        # and read as if the probe had been satisfied.
        print("\ncampaign D10 (CPU-only positive control / memo sect 8 P1 WB probe): "
              "*** NOT RUN.  No CPU-only row was in this campaign, so the WB probe "
              "did not run and therefore did NOT pass.  Until it does, the memory "
              "type of the shared allocation is UNRESOLVED and every bound above "
              "rests on an unchecked assumption about it.  Generate the set with "
              "hetlitmus/tests/het/generate-d10.sh (or `make hetlitmus-d10') and run "
              "it ON THIS BOX -- a D10 reading from another machine is not a D10 "
              "reading. ***")
    else:
        fired = [s for s in d10 if s.k_eff > 0]
        print("\ncampaign D10 (CPU-only positive control / memo sect 8 P1 WB probe): "
              "%d CPU-only row(s), %d of them fired." % (len(d10), len(fired)))
        if not fired:
            print("campaign D10: *** WB PROBE FAILED -- not one CPU-only row fired.  "
                  "The x86 store buffer is the most reproducible relaxation the ISA "
                  "has, so this is evidence about the SHARED ALLOCATION, not about "
                  "the window.  The memory type is UNRESOLVED and every bound above "
                  "rests on an unchecked assumption about it.  Check PAT/MTRR and "
                  "/proc/self/smaps for this allocator before reporting anything. ***")
        else:
            print("campaign D10: WB probe PASSED (%s) -- a UC mapping is ruled out "
                  "for this allocator.  It does NOT establish WB over WC; only the "
                  "CPU-only shapes that stay silent do that."
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
