#!/usr/bin/env python3
"""The campaign scheduler: where the GH200 hours are spent, or saved (B7b;
env-research/impl-briefs/B7b-impl-brief.md, Q3-stats.md).

A defensible "Never" needs a bound, and a bound costs thousands of runs per test.  Two
of the three levers that shrink that cost are pure scheduling, and this driver is both.

  LEVER 1 -- only 92 of the 411 tests need a bound at all.
      18 Disallowed  the CMCM validation claim  -> run to a bound (or a refutation)
      74 NO-ORACLE   characterization           -> run to a bound
     319 Allowed     need only to FIRE ONCE     -> a positive is self-vouching, so
                     they stop at the first clean sighting
     The Disallowed/NO-ORACLE split moved 50/42 -> 18/74 with the NVOR regeneration
     (2026-08-06).  The 92 that need a bound did NOT move, so no budget arithmetic
     changes; what changed is how many of them can refute rather than only
     characterize.
     The Allowed sweep is scheduled first, and not only because it is cheap: its
     observed rows are the rate population the het p_min is derived from, and p_min
     sizes every bound budget (het_verdict.h HET_P_MIN).  The sweep surfaces the
     candidate rate and nothing is ever auto-fed from it -- p_min is a campaign
     decision, not a scheduler guess.  `plan_schedule` prints the cut the schedule
     buys for the budgets actually passed.

  LEVER 2 -- adaptive per-test stopping.  Run each test until its bound is met or its
     budget is spent.  Within one invocation the harness does this itself
     (HET_ADAPTIVE=1 consults het_campaign_should_stop() after every run), so
     het_verdict.h and this scheduler apply one policy through one function.  Across
     invocations this driver pools the HetStats lines and stops when the pooled bound
     reaches --p-goal, a sighting is corroborated, or the budget is gone.

  LEVER 3 -- H > 1 (parallel het pairs) is deliberately absent: it is real emitter
     work, the pairs share the C2C fabric so DEFF eats part of the gain, and it is the
     lever most likely to be redundant once N_eff is measured.  Build it only if the
     measured N_eff turns out small.

POOLING ACROSS INVOCATIONS (the arithmetic, stated so it can be audited; `absorb` and
`pooled_bound` implement it).  Invocations use FRESH seed bases, since replaying a seed
adds no new phase draws and pooling replays would double-count R_eff, so they are
independent replicates:  k* and k_runs* are sums; R_eff* sums only over invocations
that themselves reported a bound; and bound* = max(mu_upper_i) / R_eff* -- the widest
numerator over the summed denominator, i.e. conservative.  An invocation whose
dispersion went unmeasured printed no bound, so pooling its effort would invent one.

STOP RULES: `decide` below is the whole policy -- OBSERVED / CONFIRMED / BOUND-MET /
BUDGET, plus the ERROR states set upstream of it.  Two carry judgement rather than
arithmetic: a Disallowed sighting is CONFIRMED only once corroborated across distinct
clean runs (an uncorroborated one keeps the test running instead of banking a possible
artefact as a refutation), and an unset --p-goal leaves bound rows running to budget,
because a stopping target is a campaign decision with no default baked in -- the p_min
rule again.

RUNNER CONTRACT: --runner is a command template with '{test}' and '{dir}' substituted.
It must execute ONE invocation of the test's harness binary and forward the harness
stdout -- the HetStats line is the whole interface.  Per invocation this driver sets
HET_SEED (a fresh base), HET_ADAPTIVE=1, HET_P_GOAL and HET_RUNS_MAX.  Nothing here
needs a GPU: hetlitmus/verify/statscheck.py phase 6 drives it end to end against a
stub runner.

The runner is 'sh spotcheck/run-one.sh {dir} {test}', which is `cd {dir}; exec
./{test}'.  NOT ./run.exe -- that is upstream litmus7's binary name and no het
harness emits one; the het link targets write ./<test>.

VENDOR-AGNOSTIC ON PURPOSE, AND MEASURED (P2c, 2026-08-03): this file contains
zero occurrences of `cuda' or `hip', and it needs none.  Both vendors' link
targets -- `comp.sh cuda-link' / `make cuda-bin' and `comp.sh hip-link' / `make
hip-bin' -- write the SAME ./<test>, so an AMD campaign differs from an NVIDIA one
only in which target built the binary, which happens before this driver is
invoked.  Adding a --target axis here would be a knob with nothing behind it.

CHARACTERIZATION (--characterization, exclusive with --control-map).  A pair with no
oracle (litmus/hetOracle.ml) predicts nothing, so its rows have no class to read: the
switch assigns every test NO-ORACLE from the emitted corpus itself.  That removes the
Allowed sweep (nothing here fires against a prediction) and leaves `decide' with only
its bound arm, so OBSERVED and CONFIRMED -- the two stop reasons that state agreement
or disagreement with a prediction -- are unreachable rather than merely unused.  The
alternative, a control map with every row blanked, is banned: a blank cell in a map
reads as a class nobody wrote down, and this campaign would schedule it.

Usage:
  campaign.py --corpus <dir of emitted harness dirs>
              (--control-map <csv> | --characterization)
              --runner CMD [--p-goal F] [--budget-runs N] [--allowed-budget-runs N]
              [--state campaign.csv] [--seed0 N] [--dry-run] [--tests A,B,...]
Exit: 0 = campaign completed; 2 = configuration/corpus error (fail closed);
      1 = completed but >=1 test errored or a CONFIRMED refutation was recorded
          (both demand a human before anything else is claimed).
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

TERMINAL = ("OBSERVED", "CONFIRMED", "BOUND-MET", "BUDGET", "ERROR")


def die(msg):
    sys.stderr.write("campaign: FATAL: %s\n" % msg)
    sys.exit(2)


def read_control_map(path):
    """test -> oracle class.  Field 2 of tests/het/control-map.csv, the same grounded
    source the emitter tags harnesses from.  FAIL CLOSED."""
    classes = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = [x.strip() for x in line.split(",")]
            # Header skip: both grounded sources must parse -- control-map.csv's
            # header row starts "Test,...", expected-nvidia.csv's "Litmus,...".
            # Matching only one of them ingests the other's header as a test whose
            # oracle class is "Expected", which the guard below then kills the
            # campaign on (env-research/impl-briefs/PORT1-REPORT.md 4.1).
            if len(f) < 2 or f[0] in ("Litmus", "Test"):
                continue
            classes[f[0]] = f[1]
    if not classes:
        die("control map %s has no rows" % path)
    bad = sorted(set(classes.values()) - {"Disallowed", "Allowed", "NO-ORACLE"})
    if bad:
        die("control map carries unknown oracle class(es) %s -- an untagged or "
            "mistagged test cannot be scheduled (what would its stop rule MEAN?)"
            % bad)
    return classes


def characterization_classes(corpus):
    """test -> NO-ORACLE, one row per emitted harness dir.  The corpus IS the source:
    a pair with no oracle has no map to read, and writing one whose cells are all
    blank would put a class in the campaign that nobody derived."""
    if not os.path.isdir(corpus):
        die("--corpus %s is not a directory" % corpus)
    tests = sorted(d for d in os.listdir(corpus)
                   if os.path.isdir(os.path.join(corpus, d)))
    if not tests:
        die("--characterization found no harness dir under %s -- emit the corpus "
            "first (there is nothing to characterize)" % corpus)
    return dict.fromkeys(tests, "NO-ORACLE")


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

# The bit above is a hand-mirror of a C define, and reading a live flag word by a stale
# bit would mis-report which rows bought no N_eff dividend, silently.  This file is also
# deliberately standalone -- it is copied on its own onto a rented GPU box -- so the
# cross-check is conditional on the header being reachable at its in-repo path: present
# means it must agree, out of reach means the mirror stands.
_VERDICT_H = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                          "litmus", "het-runtime", "het_verdict.h")


def check_flag_mirror(path=_VERDICT_H, name="HET_ST_TAU_UNRESOLVED",
                      mirrored=HET_ST_TAU_UNRESOLVED):
    """The bit `name` is defined at in `path`, or None when the header is out of reach.
    Any disagreement is fatal, and so is a header that no longer defines the flag."""
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
    return bit


check_flag_mirror()


def flags(kv):
    """The HetStats line carries flags=0x<hex>."""
    try:
        return int(kv.get("flags", "0"), 16)
    except ValueError:
        return 0


class TestState(object):
    def __init__(self, name, oclass):
        self.name, self.oclass = name, oclass
        self.invocations = 0
        self.runs = 0            # records actually scored (sum of R)
        self.usable = 0
        self.k = self.k_eff = self.k_runs = 0
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
        # The HetStats line carries `cpu_only=<0|1>', and it caps what a
        # CONFIRMED row licenses: on an all-CPU cycle the compound model was not
        # under test.  Read rather than assumed, and 0 until a line says
        # otherwise (P2e dropped the `prov=' field this used to read too).
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
        self.runs += int(fnum(kv, "R"))
        self.usable += int(fnum(kv, "usable"))
        self.k += int(fnum(kv, "k"))
        self.k_eff += int(fnum(kv, "k_eff"))
        self.k_runs += int(fnum(kv, "k_runs"))
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

    def decide(self, p_goal, budget):
        if self.stop:
            return self.stop
        if self.oclass == "Allowed":
            if self.k_eff >= 1:
                self.stop = "OBSERVED"
        elif self.oclass == "Disallowed":
            if self.k_runs >= 3:
                # WHAT a corroborated sighting is a sighting AGAINST is about
                # what was under test, not about the run count.  Before P2d this
                # note said "a REFUTATION of the CMCM prediction" on every
                # Disallowed row; it is the sentence an operator pastes into a
                # report, and every oracle row is a DERIVATION, so the row is
                # what it indicts first (P2e).
                if self.cpu_only:
                    what = ("a CPU-ONLY cycle (D10), so NOT a CMCM refutation -- it "
                            "indicts x86-TSO on this silicon or the memory type of "
                            "the shared allocation (memo sect 8 P1)")
                else:
                    what = ("a DISAGREEMENT WITH THE ARGUED ORACLE ROW: it indicts "
                            "THAT ROW first, never the CMCM -- re-derive the row "
                            "from its Source citations before writing anything down")
                self.stop, self.note = "CONFIRMED", (
                    "should-be-FORBIDDEN outcome corroborated in %d distinct clean "
                    "runs -- %s; stop and escalate to a human before running "
                    "anything else" % (self.k_runs, what))
            elif self.k == 0 and p_goal > 0.0:
                b = self.pooled_bound()
                if 0.0 <= b <= p_goal:
                    self.stop = "BOUND-MET"
        else:  # NO-ORACLE
            if self.k == 0 and p_goal > 0.0:
                b = self.pooled_bound()
                if 0.0 <= b <= p_goal:
                    self.stop = "BOUND-MET"
        if not self.stop and self.runs >= budget:
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
    cols = ["test", "class", "stop", "invocations", "runs", "usable", "k", "k_eff",
            "k_runs", "R_eff", "mu_upper_max", "pooled_bound", "nwin", "tau_w",
            "N_eff", "tau_unresolved", "tau_need", "note"]
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for s in states:
            w.writerow([s.name, s.oclass, s.stop, s.invocations, s.runs, s.usable,
                        s.k, s.k_eff, s.k_runs, "%.6g" % s.R_eff,
                        "%.6g" % s.mu_upper_max, "%.6g" % s.pooled_bound(),
                        s.nwin, "%.4g" % s.tau_w, "%.4g" % s.N_eff,
                        s.tau_unresolved, s.tau_need_max, s.note])


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True,
                    help="directory holding one emitted harness dir per test")
    # EXACTLY ONE of the two, and argparse is what enforces it: the oracle class of
    # every row comes either from the pair's grounded map or from the pair having no
    # oracle at all, and a run that supplied both would leave which one unstated.
    klass = ap.add_mutually_exclusive_group(required=True)
    klass.add_argument("--control-map",
                       help="the pair's positive-control map; field 2 is the class")
    klass.add_argument("--characterization", action="store_true",
                       help="the pair carries no oracle: every row is NO-ORACLE")
    ap.add_argument("--runner", required=True,
                    help="command template; {test} and {dir} are substituted")
    ap.add_argument("--p-goal", type=float, default=-1.0,
                    help="stop a bound row once its pooled bound <= this "
                         "(unset: bound rows run to budget)")
    ap.add_argument("--budget-runs", type=int, default=100,
                    help="max runs per BOUND row (Disallowed / NO-ORACLE)")
    ap.add_argument("--allowed-budget-runs", type=int, default=30,
                    help="max runs per Allowed row (fire-once sweep)")
    ap.add_argument("--seed0", type=int, default=20260714)
    ap.add_argument("--state", default="campaign-state.csv")
    ap.add_argument("--tests", default="",
                    help="comma-separated subset (default: every test in the map "
                         "that has a harness dir)")
    ap.add_argument("--dry-run", action="store_true")
    return ap.parse_args()


def select_work(a, classes, source):
    """The tests to schedule: those named by --tests, else the whole map.  A test with
    no oracle class or no harness dir is FAIL CLOSED, not a skip."""
    subset = [t for t in a.tests.split(",") if t] or sorted(classes)
    missing_class = [t for t in subset if t not in classes]
    if missing_class:
        die("test(s) with NO oracle class in %s: %s -- fail closed, nothing to "
            "schedule" % (source, ", ".join(missing_class[:5])))
    work = []
    for t in subset:
        d = os.path.join(a.corpus, t)
        if not os.path.isdir(d):
            die("no harness dir for %s under %s (emit the corpus first)" % (t, a.corpus))
        work.append(t)
    return work


# LEVER 1: the schedule.  Allowed sweep first (cheap, and it feeds p_min), then the
# Disallowed rows (the validation claim), then NO-ORACLE.
def plan_schedule(a, classes, work):
    """`work` in run order, plus the printout of what the schedule buys at the budgets
    actually passed."""
    order = {"Allowed": 0, "Disallowed": 1, "NO-ORACLE": 2}
    work = sorted(work, key=lambda t: (order[classes[t]], t))
    if a.characterization:
        print("campaign: CHARACTERIZATION, %d test(s), every row NO-ORACLE: no "
              "Allowed sweep (nothing here fires against a prediction) and no row "
              "can agree or disagree with one.  Each runs to its bound or to <=%d "
              "runs; worst case %d runs." % (len(work), a.budget_runs,
                                             len(work) * a.budget_runs))
        if a.p_goal <= 0.0:
            print("campaign: NOTE --p-goal unset: every row will run to budget "
                  "(a stopping target is a campaign decision; none is baked in).")
        return work
    n_all = sum(1 for t in work if classes[t] == "Allowed")
    n_dis = sum(1 for t in work if classes[t] == "Disallowed")
    n_no = sum(1 for t in work if classes[t] == "NO-ORACLE")
    naive = len(work) * a.budget_runs
    planned = n_all * a.allowed_budget_runs + (n_dis + n_no) * a.budget_runs
    print("campaign: %d test(s): %d Allowed (fire-once sweep, <=%d runs) -> "
          "%d Disallowed + %d NO-ORACLE (bound rows, <=%d runs)"
          % (len(work), n_all, a.allowed_budget_runs, n_dis, n_no, a.budget_runs))
    print("campaign: worst-case budget %d runs vs %d if every row were a bound row "
          "(the scheduling cut alone: %.1fx); adaptive stopping only shrinks it."
          % (planned, naive, naive / float(max(planned, 1))))
    if a.p_goal <= 0.0:
        print("campaign: NOTE --p-goal unset: bound rows will run to budget "
              "(a stopping target is a campaign decision; none is baked in).")
    return work


def drive_test(a, st, budget):
    """Invoke one test's runner until its stop rule fires, pooling each HetStats line.
    Every failure mode ends the test as ERROR rather than looping on it."""
    while not st.decide(a.p_goal, budget):
        env = dict(os.environ)
        env["HET_SEED"] = str(a.seed0 + st.invocations * SEED_STRIDE)
        env["HET_ADAPTIVE"] = "1"
        env["HET_RUNS_MAX"] = str(budget - st.runs)
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
    print("done  %-11s %-28s %-9s inv=%d runs=%d k=%d k_eff=%d k_runs=%d "
          "R_eff=%.4g bound=%s%s%s"
          % (st.oclass, st.name, st.stop, st.invocations, st.runs, st.k, st.k_eff,
             st.k_runs, st.R_eff, ("%.4g" % b) if b >= 0 else "-",
             ("  tau-UNRESOLVED in %d/%d inv (needs >=%d runs/inv)"
              % (st.tau_unresolved, st.invocations, st.tau_need_max))
             if st.tau_unresolved else "",
             ("  ** " + st.note + " **") if st.stop == "CONFIRMED" else ""))


def run_campaign(a, classes, work):
    """Drive every test in order and return (states, errors, confirmed).  A row already
    terminal in --state is resumed, not re-run, and the state is written after every
    test so the campaign survives losing the box."""
    prior = load_state(a.state)
    states, errors, confirmed = [], 0, 0
    for t in work:
        st = TestState(t, classes[t])
        states.append(st)
        # A ROW MAY ONLY BE RESUMED BY A CAMPAIGN OF ITS OWN KIND.  The stop rules
        # are per class, so inheriting a terminal stop across classes would let a
        # characterization run report the OBSERVED or CONFIRMED some earlier
        # oracle run banked -- the one path by which a pair with no prediction
        # could still print an adjudication.  A row whose class cannot be read is
        # not resumable by ANY campaign: the class is what identifies the stop
        # rule that wrote the row, so a blank one is an unidentified rule, not a
        # matching one.
        if t in prior:
            pclass = (prior[t].get("class") or "").strip()
            if not pclass:
                die("%s carries no readable oracle class in %s: a row whose class "
                    "cannot be read is not resumable, because the stop rule that "
                    "wrote it cannot be identified" % (t, a.state))
            if pclass != st.oclass:
                die("%s is %s in this campaign and %s in %s: a state file cannot "
                    "be resumed by a campaign that classes its rows differently, "
                    "because the stop rule that wrote those rows is not this one"
                    % (t, st.oclass, pclass, a.state))
        if t in prior and prior[t].get("stop") in TERMINAL:
            st.stop = prior[t]["stop"]
            st.note = "resumed: terminal in %s" % a.state
            print("skip  %-11s %-28s %s (from state)" % (st.oclass, t, st.stop))
            # A resumed row still counts: a banked CONFIRMED that nobody counted
            # would let a resuming campaign exit 0 over a recorded sighting.
            if st.stop == "ERROR":
                errors += 1
            if st.stop == "CONFIRMED":
                confirmed += 1
            continue
        budget = a.allowed_budget_runs if st.oclass == "Allowed" else a.budget_runs
        drive_test(a, st, budget)
        report_test(st)
        if st.stop == "ERROR":
            errors += 1
        if st.stop == "CONFIRMED":
            confirmed += 1
        save_state(a.state, states)   # after every test: the campaign is resumable
    return states, errors, confirmed


def report_campaign(states, errors, confirmed, characterization=False):
    # The p_min candidate population: surfaced, never auto-applied (lever 1 above).
    if characterization:
        print("\ncampaign: CHARACTERIZATION -- no Allowed row was scheduled, so this "
              "campaign contributes no p_min candidate population.  What it produces "
              "is one bound (or one spent budget) per row of a pair that predicts "
              "nothing; not one row of it agrees or disagrees with a model.")
    else:
        fired = [s for s in states if s.oclass == "Allowed" and s.stop == "OBSERVED"]
        print("\ncampaign: %d Allowed row(s) OBSERVED (the p_min candidate population "
              "-- derive HET_P_MIN from their per-effective-sample rates; it is NOT "
              "set automatically)." % len(fired))

    # The price of the unclaimed dividend.  These rows are not failures and their
    # bounds are not wrong; they are the conservative bounds, because the run count
    # they were given could not resolve their tau.  Surfaced, never auto-applied:
    # raising the run count spends GH200 hours, so it is a campaign decision like
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
            print("            %-28s %-11s tau_w=%.4g  needs >=%d runs/inv "
                  "(had %d over %d invocation(s))"
                  % (s.name, s.oclass, s.tau_w, s.tau_need_max,
                     s.runs // max(s.invocations, 1), s.invocations))
    if errors:
        print("campaign: %d test(s) ERRORED -- their rows are not results." % errors)
    if confirmed:
        rows = [s for s in states if s.stop == "CONFIRMED"]
        d10rows = [s for s in rows if s.cpu_only]
        print("campaign: ** %d CONFIRMED sighting(s) on Disallowed row(s) -- stop and "
              "get a human before anything else is claimed. **" % confirmed)
        # WHAT THEY INDICT is stated once and unconditionally: every oracle row
        # is a derivation over cited sources, so a campaign that disagrees with
        # one indicts that row before it indicts the compound model.  D10 rows
        # are called out separately because on an all-CPU cycle the compound
        # model was not under test at all.
        print("campaign:    NONE of them is a CMCM refutation as it stands: %d "
              "DISAGREE WITH THEIR ARGUED ORACLE ROW and indict THAT ROW first "
              "(re-derive it from its Source citations), and %d are CPU-only (D10) "
              "cycles on which the compound model was not under test."
              % (confirmed - len(d10rows), len(d10rows)))
        for s in rows:
            print("            %-28s cpu_only=%d" % (s.name, s.cpu_only))

    # D10 -- the CPU-only positive control, and it is a PRECONDITION, not a row.
    # memo sect 7.D10: SB and R must be OBSERVED (the store buffer is live, which
    # rules a UC mapping out for this allocator).  If they are not, memo sect 8 P1
    # is unresolved and EVERY Disallowed row of the AMD oracle is void -- so this
    # is checked before, not after, anyone reads the bounds above.
    d10 = [s for s in states if s.cpu_only]
    if not d10 and characterization:
        # No Disallowed row exists here, so nothing in this campaign rests on the
        # probe -- but the probe still did not run, and the reading it would have
        # given about the shared allocation's memory type is still missing.
        print("\ncampaign D10 (CPU-only positive control / memo sect 8 P1 WB probe): "
              "NOT RUN.  No CPU-only row was in this campaign.  No verdict here "
              "depends on it -- a characterization campaign has no Disallowed row -- "
              "so nothing above is void; what is missing is the reading of the "
              "shared allocation's memory type, which stays unestablished on this "
              "box until the D10 set (hetlitmus/tests/het/generate-d10.sh) is run "
              "ON IT.")
    elif not d10:
        # A SILENTLY ABSENT PRECONDITION IS THE FAILURE MODE THIS BLOCK EXISTS TO
        # PREVENT.  It used to run under a bare `if d10:' with no else, so a
        # campaign over the het corpus alone -- the normal case -- printed no D10
        # line at all and read as if the probe had been satisfied.  memo sect 7.D10
        # makes it a precondition of EVERY Disallowed row, so its absence is
        # louder than its failure, not quieter.
        print("\ncampaign D10 (CPU-only positive control / memo sect 8 P1 WB probe): "
              "*** NOT RUN.  No CPU-only row was in this campaign, so the WB probe "
              "did not run and therefore did NOT pass.  Until it does, memo sect 8 P1 "
              "is UNRESOLVED and every Disallowed verdict below rests on an "
              "unchecked assumption about the shared allocation's memory type.  "
              "Generate the set with hetlitmus/tests/het/generate-d10.sh (or `make "
              "hetlitmus-d10') and run it ON THIS BOX -- a D10 reading from another "
              "machine is not a D10 reading. ***")
    else:
        probes = [s for s in d10 if s.oclass == "Allowed"]
        fired = [s for s in probes if s.stop == "OBSERVED"]
        print("\ncampaign D10 (CPU-only positive control / memo sect 8 P1 WB probe): "
              "%d CPU-only row(s), %d of %d Allowed probe(s) fired."
              % (len(d10), len(fired), len(probes)))
        if not probes:
            print("campaign D10: *** NO Allowed CPU-only shape was run.  The WB probe "
                  "did NOT run, so it did not pass: generate the D10 set with "
                  "tests/het/generate-d10.sh and include SB and R. ***")
        elif not fired:
            print("campaign D10: *** WB PROBE FAILED -- not one Allowed CPU-only "
                  "shape fired.  The x86 store buffer is the most reproducible "
                  "relaxation the ISA has, so this is evidence about the SHARED "
                  "ALLOCATION, not about the window.  memo sect 8 P1 is UNRESOLVED "
                  "and EVERY Disallowed row of this oracle is VOID -- not one row, "
                  "all of them.  Check PAT/MTRR and /proc/self/smaps for this "
                  "allocator before reporting anything. ***")
        else:
            print("campaign D10: WB probe PASSED (%s) -- a UC mapping is ruled out "
                  "for this allocator.  It does NOT establish WB over WC; only the "
                  "forbidden CPU-only shapes staying silent does that."
                  % ", ".join(s.name for s in fired))


def main():
    a = parse_args()
    if a.characterization:
        classes, source = characterization_classes(a.corpus), a.corpus
    else:
        classes, source = read_control_map(a.control_map), a.control_map
    work = plan_schedule(a, classes, select_work(a, classes, source))
    if a.dry_run:
        for t in work:
            print("  plan %-11s %s" % (classes[t], t))
        return 0
    states, errors, confirmed = run_campaign(a, classes, work)
    report_campaign(states, errors, confirmed, a.characterization)
    return 1 if (errors or confirmed) else 0


if __name__ == "__main__":
    sys.exit(main())
