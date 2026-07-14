#!/usr/bin/env python3
"""HetLitmus B7b -- the CAMPAIGN SCHEDULER: where the GH200 hours are actually saved.

B7's budget rule said a defensible "Never" needs ~1,500-30,000 runs per test.  Two of
the three levers that shrink that are PURE SCHEDULING, and this driver is both:

  LEVER 1 -- only 52 of the 338 tests need a bound at all.
      16 Disallowed  = the CMCM validation claim   -> run to a bound (or refutation)
      36 NO-ORACLE   = characterization            -> run to a bound
     286 Allowed     = just need to FIRE ONCE      -> a positive is self-vouching
                        (B6c ALLOWED-OBSERVED), so they stop at the first clean
                        sighting.  Running them to bound-grade budgets would burn
                        ~6.5x the campaign for nothing.
     The Allowed sweep is scheduled FIRST, and not only because it is cheap: its
     ALLOWED-OBSERVED rows ARE the observed-rate population from which the het
     p_min -- the number that sizes every bound budget -- is derived (HET_P_MIN,
     het_verdict.h).  The sweep's summary surfaces the candidate rate; it is NEVER
     auto-fed into anything (p_min is a campaign decision, not a scheduler guess).

  LEVER 2 -- adaptive per-test stopping.
     Run each test until its bound is met or its budget is spent.  Inside one
     invocation the harness does this itself (HET_ADAPTIVE=1 consults
     het_campaign_should_stop() after every run -- the header's rule and this
     scheduler apply the SAME policy, one function).  ACROSS invocations this
     driver pools the per-invocation HetStats lines and stops the test when the
     pooled bound reaches --p-goal, the sighting is corroborated, or the budget is
     gone.  Do not run 30,000 runs on a test that converged at 500.

  LEVER 3 -- H > 1 (parallel het pairs) is deliberately NOT here: it is real
     emitter work, the pairs share the C2C fabric (DEFF eats part of the gain),
     and it is the lever most likely to be redundant once N_eff is measured.
     Build it in B8 only if the measured N_eff turns out small.

POOLING ACROSS INVOCATIONS (the arithmetic, stated so it can be audited):
  each invocation i reports (HetStats line) k_i, k_eff_i, k_runs_i, R_usable_i,
  R_eff_i, mu_upper_i.  Invocations use FRESH seed bases (HET_SEED env -- replaying
  a seed adds no new phase draws and would double-count R_eff), so they are
  independent replicates and:
      k*      = sum k_i          (any sighting anywhere counts)
      k_runs* = sum k_runs_i     (runs are distinct across invocations by seeding)
      R_eff*  = sum over MEASURED invocations of R_eff_i
      bound*  = max(mu_upper_i) / R_eff*        <- widest numerator over the summed
                                                   denominator: conservative
  an invocation whose dispersion was unmeasured contributes NO R_eff (it printed no
  bound; pooling its effort would be inventing one).

STOP RULES (the header's policy, at campaign scope):
  ALLOWED      k_eff* >= 1                        -> OBSERVED   (self-vouching)
  DISALLOWED   k_runs* >= 3                       -> CONFIRMED  (corroborated
               refutation -- the campaign's most valuable output, reported LOUDLY;
               an uncorroborated sighting keeps the test running: escalate, never
               bank a possible artefact as a refutation)
  DISALLOWED / NO-ORACLE with k* == 0:
               bound* <= --p-goal                 -> BOUND-MET
  any          runs >= --budget-runs              -> BUDGET
  --p-goal unset => bound rows run to budget (a stopping target is a campaign
  decision; there is no default baked in, same rule as p_min).

RUNNER CONTRACT: --runner is a command template; '{test}' and '{dir}' are
substituted.  It must execute ONE invocation of the test's harness binary and
forward the harness stdout (the HetStats line is the interface).  This driver sets,
per invocation:  HET_SEED (fresh base), HET_ADAPTIVE=1, HET_P_GOAL, HET_RUNS_MAX.
On the GH200 the runner is typically:  'cd {dir} && ./run.exe'  (after comp.sh).
Nothing here needs a GPU: the scheduler is validated on the dev box against a stub
runner by hetlitmus/verify/statscheck.py (phase 5).

Usage:
  campaign.py --corpus <dir of emitted harness dirs> --control-map <csv>
              --runner CMD [--p-goal F] [--budget-runs N] [--allowed-budget-runs N]
              [--state campaign.csv] [--seed0 N] [--dry-run] [--tests A,B,...]
Exit: 0 = campaign completed; 2 = configuration/corpus error (fail closed);
      1 = completed but >=1 test errored or a CONFIRMED refutation was recorded
          (both demand a human before anything else is claimed).
"""

import argparse
import csv
import os
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
    """test -> oracle class.  Field 2 of tests/het/control-map.csv, the same
    grounded source the emitter tags harnesses from (B6c).  FAIL CLOSED."""
    classes = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = [x.strip() for x in line.split(",")]
            if len(f) < 2 or f[0] == "Litmus":
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


# het_verdict.h: HET_ST_TAU_UNRESOLVED (1u << 14) -- tau was not resolved by this
# invocation's pooled stream, so N_eff fell back to 1 (B7's reading).
HET_ST_TAU_UNRESOLVED = 1 << 14


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
        # B7c: an invocation whose tau was NOT RESOLVED scored N_eff = 1 (B7's
        # reading).  That is not an error and not a dead end -- it is a PRICE, and
        # tau_need is the price in runs.  Carried so the campaign can SAY which rows
        # bought no dividend and what it would cost to buy one.
        self.tau_unresolved = 0          # invocations whose tau was unresolved
        self.tau_need_max = 0            # ... and the largest run count they wanted
        self.stop = ""
        self.note = ""

    def pooled_bound(self):
        if self.k > 0 or self.R_eff <= 0.0 or self.mu_upper_max <= 0.0:
            return -1.0
        return self.mu_upper_max / self.R_eff

    def absorb(self, kv):
        self.invocations += 1
        self.runs += int(fnum(kv, "R"))
        self.usable += int(fnum(kv, "usable"))
        self.k += int(fnum(kv, "k"))
        self.k_eff += int(fnum(kv, "k_eff"))
        self.k_runs += int(fnum(kv, "k_runs"))
        nwin = int(fnum(kv, "nwin"))
        if self.nwin and nwin and nwin != self.nwin:
            # tau_w/F_win/N_eff are resolution-dependent (het_verdict.h): records
            # scored at different window resolutions must not be silently pooled.
            self.stop, self.note = "ERROR", (
                "nwin changed mid-test (%d -> %d): a swept HET_NWIN needs a fresh "
                "campaign state, not a silent pool" % (self.nwin, nwin))
            return
        self.nwin = nwin or self.nwin
        mu = fnum(kv, "mu_upper", -1.0)
        reff = fnum(kv, "R_eff", 0.0)
        p_bound = fnum(kv, "p_bound", -1.0)
        # Only an invocation that itself reported a bound may contribute effort to
        # the pooled one (p_bound >= 0 implies dispersion measured, obs Never).
        if p_bound >= 0.0 and reff > 0.0:
            self.R_eff += reff
            self.mu_upper_max = max(self.mu_upper_max, mu)
        if fnum(kv, "tau_w", -1.0) > 0.0:
            self.tau_w = fnum(kv, "tau_w")
            self.N_eff = fnum(kv, "N_eff", -1.0)
        # B7c.  KEEP GOING, do not give up: an unresolved tau scored N_eff = 1, so this
        # invocation's R_eff is B7's conservative number, the pooled bound is WIDER, and
        # the row therefore keeps running of its own accord.  It must never be treated
        # as an ERROR (that would de-schedule a test for being honest), and a BOUND-MET
        # it can still earn was earned on the conservative reading, so it stands.  All
        # the campaign owes the operator is the PRICE, in runs.
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
                self.stop, self.note = "CONFIRMED", (
                    "should-be-FORBIDDEN outcome corroborated in %d distinct clean "
                    "runs -- a REFUTATION of the CMCM prediction; stop and escalate "
                    "to a human before running anything else" % self.k_runs)
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True,
                    help="directory holding one emitted harness dir per test")
    ap.add_argument("--control-map", required=True)
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
    a = ap.parse_args()

    classes = read_control_map(a.control_map)
    subset = [t for t in a.tests.split(",") if t] or sorted(classes)
    missing_class = [t for t in subset if t not in classes]
    if missing_class:
        die("test(s) with NO oracle class in %s: %s -- fail closed, nothing to "
            "schedule" % (a.control_map, ", ".join(missing_class[:5])))
    work = []
    for t in subset:
        d = os.path.join(a.corpus, t)
        if not os.path.isdir(d):
            die("no harness dir for %s under %s (emit the corpus first)" % (t, a.corpus))
        work.append(t)

    # LEVER 1: the schedule.  Allowed sweep first (cheap + it feeds p_min), then the
    # 16 Disallowed (the validation claim), then the 36 NO-ORACLE.
    order = {"Allowed": 0, "Disallowed": 1, "NO-ORACLE": 2}
    work.sort(key=lambda t: (order[classes[t]], t))
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
    if a.dry_run:
        for t in work:
            print("  plan %-11s %s" % (classes[t], t))
        return 0

    prior = load_state(a.state)
    states, errors, confirmed = [], 0, 0
    for t in work:
        st = TestState(t, classes[t])
        states.append(st)
        if t in prior and prior[t].get("stop") in TERMINAL:
            st.stop = prior[t]["stop"]
            st.note = "resumed: terminal in %s" % a.state
            print("skip  %-11s %-28s %s (from state)" % (st.oclass, t, st.stop))
            continue
        budget = a.allowed_budget_runs if st.oclass == "Allowed" else a.budget_runs
        while not st.decide(a.p_goal, budget):
            env = dict(os.environ)
            env["HET_SEED"] = str(a.seed0 + st.invocations * SEED_STRIDE)
            env["HET_ADAPTIVE"] = "1"
            env["HET_RUNS_MAX"] = str(budget - st.runs)
            if a.p_goal > 0.0:
                env["HET_P_GOAL"] = repr(a.p_goal)
            cmd = a.runner.replace("{test}", t).replace(
                "{dir}", os.path.join(a.corpus, t))
            r = subprocess.run(cmd if os.name == "nt" else shlex.split(cmd),
                               env=env, capture_output=True, text=True)
            if r.returncode != 0:
                st.stop, st.note = "ERROR", ("runner rc=%d: %s" % (
                    r.returncode, r.stderr.strip()[-200:]))
                break
            got = parse_hetstats(r.stdout)
            if got is None:
                st.stop, st.note = "ERROR", "no HetStats machine line in runner output"
                break
            _, kv = got
            before = st.runs
            st.absorb(kv)
            if st.runs == before:
                # An invocation that scored zero runs makes no progress; looping on
                # it would poll the same dead harness forever.
                st.stop, st.note = "ERROR", "invocation reported R=0 runs"
                break
        b = st.pooled_bound()
        print("done  %-11s %-28s %-9s inv=%d runs=%d k=%d k_eff=%d k_runs=%d "
              "R_eff=%.4g bound=%s%s%s"
              % (st.oclass, t, st.stop, st.invocations, st.runs, st.k, st.k_eff,
                 st.k_runs, st.R_eff, ("%.4g" % b) if b >= 0 else "-",
                 ("  tau-UNRESOLVED in %d/%d inv (needs >=%d runs/inv)"
                  % (st.tau_unresolved, st.invocations, st.tau_need_max))
                 if st.tau_unresolved else "",
                 ("  ** " + st.note + " **") if st.stop == "CONFIRMED" else ""))
        if st.stop == "ERROR":
            errors += 1
        if st.stop == "CONFIRMED":
            confirmed += 1
        save_state(a.state, states)   # after every test: the campaign is resumable

    # The p_min candidate population (surfaced, NEVER auto-applied -- HET_P_MIN's
    # rule).  Rate per effective sample: sightings over pooled effective cells.
    fired = [s for s in states if s.oclass == "Allowed" and s.stop == "OBSERVED"]
    print("\ncampaign: %d Allowed row(s) OBSERVED (the p_min candidate population "
          "-- derive HET_P_MIN from their per-effective-sample rates; it is NOT "
          "set automatically)." % len(fired))

    # B7c: THE PRICE OF THE UNCLAIMED DIVIDEND.  These rows are not failures and
    # their bounds are not wrong -- they are B7's (conservative) bounds, because the
    # run count they were given could not resolve their tau.  Surfaced, never
    # auto-applied: raising the run count is a campaign decision that spends GH200
    # hours, exactly like --p-goal and HET_P_MIN.
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
        print("campaign: ** %d CONFIRMED refutation(s) recorded -- stop and get a "
              "human before anything else is claimed. **" % confirmed)
    return 1 if (errors or confirmed) else 0


if __name__ == "__main__":
    sys.exit(main())
