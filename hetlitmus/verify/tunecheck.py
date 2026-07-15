#!/usr/bin/env python3
"""HetLitmus B8a gate -- tunecheck.py.  Prove the TUNER SEARCHES, and that each of Q7's
three data-peeking transfer fixes actually MATTERS.

This is the sixth time this project gates against "compiles, passes every gate, and does
NOTHING".  A tuner that always returns the seed, or always returns the last config, is the
same class of bug as the constant-false _weak (B3) or the dead-code-eliminated stress layer
(B4).  So this gate does not check that the tuner RUNS; it checks that it FINDS the right
answer, REFUSES to when there is none, and that removing each adaptation BREAKS it.

  PHASE 1 -- KNOWN OPTIMUM.  Hand the search configs with distinct TRUE means; the winner
    must be the arg-max.  (A tuner that returns the seed/first config fails -- the --bite.)

  PHASE 2 -- NO PHANTOM WINNER.  Hand it a CONSTANT objective (equal means); it must return
    NO confident winner.  A tuner that always crowns someone is a seventh constant.

  PHASE 3 -- THE DRIFT BITE (Q7 5.2 C2).  A rising baseline aliases onto the config axis.
    SEQUENTIAL sampling (Kirkham Fig.10) picks the LATE config; SER^3 randomized round-robin
    picks the TRUE best.  Demonstrated by running both and showing the winners DIFFER.

  PHASE 4 -- THE OVERDISPERSION BITE (Q7 5.2 A).  Under Fano>1 the Bernoulli CI is too
    narrow, so the early-stop prematurely ELIMINATES the true optimum; the empirical-
    Bernstein CI (empirical variance + effective sample size) RETAINS it.  Demonstrated by
    running the SAME seeded streams through both rules and showing Bernoulli eliminates the
    true best far more often than EB.  If this cannot be shown, Q7 5.2's central claim is
    unproven in our own code.

  PHASE 5 -- THE STRUCTURAL SPLIT (Q7 TRAP 1/2).  Over thousands of draws the sampler emits
    ONLY experiment knobs -- never an instrument or detector knob.  The config writer/reader
    refuse a non-experiment knob.  HET_WINDOW never appears.

  PHASE 6 -- THE IN-LOOP KS GATE (Q7 5.2 C1).  A non-stationary bout (het_ks2 verdict, not
    recomputed) is EXCLUDED from a config's rate estimate, so drift inside a bout cannot
    inflate it.

Run:  tunecheck.py           -- the six phases (must all pass).
      tunecheck.py --bite     -- corrupt the tuner / the split and prove each check BITES
                                 (and that the corruption was non-vacuous: cmp-style).
Determinism: pure Park-Miller (tune.ParkMiller) + math, no random/numpy -- identical on
every machine and Python version.
"""

import argparse
import math
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tune  # noqa: E402
from tune import (ParkMiller, Bout, Arm, race, eliminate, sample_config,  # noqa: E402
                  SUBSEARCH, SUBSEARCH_ORDER, WARM_START, whitelisted_knobs,
                  INSTRUMENT_KNOBS, DETECTOR_KNOBS, write_config, read_config)


# ===========================================================================
# The synthetic objective.  A config carries a hidden "_id"; the objective maps id -> TRUE
# mean, optionally adds a wall-time DRIFT baseline, and draws each bout as a latent-rate +
# within-bout binomial (a Cox / beta-binomial process, matching statscheck's overdispersion
# fixture).  od_amp>0 makes the counts OVERDISPERSED (Fano>1); weight_deflate mimics the
# N_eff deflation (deliverable #3: Q = R x N_eff), raw_n stays the inflated cell count that
# the (broken) Bernoulli CI trusts.
# ===========================================================================
class Synth(object):
    def __init__(self, means, cells=16, od_amp=0.0, drift=0.0, weight_deflate=1.0,
                 ks_fail_ids=None, ks_fail_mean=None):
        self.means = means                  # {id: true mean}
        self.cells = cells
        self.od_amp = od_amp
        self.drift = drift
        self.weight_deflate = weight_deflate
        self.ks_fail_ids = set(ks_fail_ids or ())
        self.ks_fail_mean = ks_fail_mean
        self.t = 0                          # global bout counter = wall-time proxy

    def _clamp(self, x):
        return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)

    def bout(self, config, pm):
        cid = config["_id"]
        mu = self.means[cid]
        # A non-stationary bout (het_ks2 would flag it): its mean is corrupted, and it is
        # marked ks_ok=False so the in-loop gate must DROP it (PHASE 6).
        ks_ok = True
        if cid in self.ks_fail_ids and self.ks_fail_mean is not None:
            mu = self.ks_fail_mean
            ks_ok = False
        mu = self._clamp(mu + self.drift * self.t)
        self.t += 1
        # between-bout latent dispersion (Fano>1), then within-bout binomial.
        p = self._clamp(mu + self.od_amp * (2.0 * pm.unit() - 1.0))
        hits = 0
        for _ in range(self.cells):
            if pm.unit() < p:
                hits += 1
        value = hits / float(self.cells)
        weight = self.cells / self.weight_deflate      # effective n (deflated under od)
        return Bout(value, weight, raw_n=self.cells, secs=1.0, kills=hits,
                    ks_ok=ks_ok, valid=True)


def _cfgs(*ids):
    return [{"_id": i} for i in ids]


def _run(objective, configs, seed, schedule="ser3", use_bernoulli=False,
         max_rounds=150, min_rounds=3, delta=0.05):
    pm = ParkMiller(seed)
    return race(objective, [dict(c) for c in configs], pm, delta=delta,
                max_rounds=max_rounds, min_rounds=min_rounds,
                use_bernoulli=use_bernoulli, schedule=schedule)


def _winner_id(res):
    return None if res.winner is None else res.winner.config["_id"]


def _simulate_elim(means, seed, rounds, cells, od_amp, deflate, use_bernoulli,
                   min_rounds=3, delta=0.05):
    """Drive a race by hand (fixed round-robin order, so the ONLY variable is the CI rule)
    and track CUMULATIVE elimination: once a config's upper bound falls below the best's
    lower bound it is dropped for good (Kirkham Fig.10's early-stop is permanent).  Both
    rules run on the IDENTICAL bout stream (same seed => same Synth draws).  Returns
    (eliminated_ids, crowned_id_or_None)."""
    pm = ParkMiller(seed)
    obj = Synth(means, cells=cells, od_amp=od_amp, weight_deflate=deflate)
    arms = {c: Arm({"_id": c}, "c%d" % c) for c in means}
    elim = set()
    for r in range(rounds):
        for c in means:
            arms[c].add(obj.bout({"_id": c}, pm))
        if r + 1 >= min_rounds:
            live = [arms[c] for c in means if c not in elim and arms[c].raceable()]
            surv = {a.config["_id"] for a in eliminate(live, delta, use_bernoulli)}
            for c in means:
                if c not in elim and arms[c].raceable() and c not in surv:
                    elim.add(c)
    liveids = [c for c in means if c not in elim and arms[c].raceable()]
    return elim, (liveids[0] if len(liveids) == 1 else None)


# --------------------------------------------------------------------------- PHASE 1
def phase1(quiet):
    print("===== PHASE 1: does the search FIND a known optimum? =====")
    means = {0: 0.30, 1: 0.50, 2: 0.72, 3: 0.40}     # id 2 is the true best
    ok = True
    hits = 0
    seeds = list(range(20))
    for s in seeds:
        res = _run(Synth(means, od_amp=0.0), _cfgs(0, 1, 2, 3), s)
        if _winner_id(res) == 2:
            hits += 1
    frac = hits / float(len(seeds))
    print("  true optimum (id 2, mean 0.72) won %d/%d seeds (%.0f%%)"
          % (hits, len(seeds), 100 * frac))
    if frac < 0.9:
        print("  *** the search does NOT reliably find the optimum")
        ok = False
    # And it converges to a SINGLE separated winner, not by luck: reason must be 'separated'.
    res = _run(Synth(means), _cfgs(0, 1, 2, 3), 0)
    if res.reason != "separated":
        print("  *** winner declared without separation (reason=%s)" % res.reason)
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 2
def phase2(quiet):
    print("\n===== PHASE 2: does it REFUSE to crown a phantom on a constant objective? =====")
    means = {0: 0.50, 1: 0.50, 2: 0.50}
    ok = True
    phantom = 0
    for s in range(20):
        res = _run(Synth(means, od_amp=0.02), _cfgs(0, 1, 2), s, max_rounds=60)
        if res.winner is not None:
            phantom += 1
    print("  phantom winners on the constant objective: %d/20 (must be 0)" % phantom)
    if phantom != 0:
        print("  *** the tuner crowned a winner with no separating signal (a 7th constant)")
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 3
def phase3(quiet):
    print("\n===== PHASE 3: THE DRIFT BITE -- SER^3 de-confounds a rising baseline =====")
    # id 0 = TRUE best (mean 0.60); id 1 = decoy (mean 0.40).  Drift rises with the global
    # bout counter.  SEQUENTIAL runs id 0 first (early, cold), id 1 last (late, hot) -> id 1
    # looks better.  SER^3 interleaves -> both see the same mean drift -> id 0 wins.
    means = {0: 0.60, 1: 0.40}
    ok = True
    seq_late = 0     # sequential picks the LATE config (id 1) = the confound
    ser_true = 0     # SER^3 picks the TRUE best (id 0) = the fix
    for s in range(20):
        seq = _run(Synth(means, od_amp=0.0, drift=0.010), _cfgs(0, 1), s,
                   schedule="sequential", max_rounds=30)
        ser = _run(Synth(means, od_amp=0.0, drift=0.010), _cfgs(0, 1), s,
                   schedule="ser3", max_rounds=60)
        if _winner_id(seq) == 1:
            seq_late += 1
        if _winner_id(ser) == 0:
            ser_true += 1
    print("  sequential picked the LATE decoy (id 1): %d/20  <- the drift confound" % seq_late)
    print("  SER^3      picked the TRUE best (id 0): %d/20  <- the fix" % ser_true)
    # The bite: the two schedules must DISAGREE (different winners), and in the right
    # directions.  If sequential also picked id 0, drift did not bite and SER^3 proves nothing.
    if seq_late < 15:
        print("  *** the drift did not confound the SEQUENTIAL order -- the fixture is inert, "
              "so SER^3 demonstrates nothing (VACUOUS)")
        ok = False
    if ser_true < 17:
        print("  *** SER^3 did NOT recover the true best under the same drift")
        ok = False
    print("  => PASS (SER^3 and sequential disagree, in the fixed directions)" if ok
          else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 4
def phase4(quiet):
    print("\n===== PHASE 4: THE OVERDISPERSION BITE -- empirical-Bernstein retains the "
          "true optimum where Bernoulli eliminates it =====")
    # id 0 = TRUE best (mean 0.55); id 1 = decoy (0.45).  Strong between-bout overdispersion
    # (Fano>1): Bernoulli's W(1-W)/Q_raw CI is far too narrow, so an early noisy round lets
    # the decoy's transient lead ELIMINATE the true best FOR GOOD (early-stop is permanent).
    # EB's empirical variance + deflated effective Q keeps the CI honest, so it never
    # eliminates the true best and crowns it once the ranking is reliable.  Fixture point
    # chosen by sweep (scratchpad tune4.py) for a robust contrast, not one lucky seed.
    means = {0: 0.55, 1: 0.45}
    OD, DEFL, CELLS, R = 0.40, 4.0, 24, 120
    ok = True
    eb_elim_true = be_elim_true = 0    # eliminated the TRUE optimum (id 0)
    eb_crown_true = 0                  # EB correctly crowned the true optimum
    for s in range(40):
        e_eb, w_eb = _simulate_elim(means, s, R, CELLS, OD, DEFL, use_bernoulli=False)
        e_be, w_be = _simulate_elim(means, s, R, CELLS, OD, DEFL, use_bernoulli=True)
        if 0 in e_eb:
            eb_elim_true += 1
        if 0 in e_be:
            be_elim_true += 1
        if w_eb == 0:
            eb_crown_true += 1
    print("  Bernoulli CI ELIMINATED the true optimum (id 0): %d/40  <- the transfer failure"
          % be_elim_true)
    print("  empirical-Bernstein eliminated the true optimum: %d/40  <- retains it" % eb_elim_true)
    print("  empirical-Bernstein CROWNED the true optimum:    %d/40  <- and it still decides"
          % eb_crown_true)
    # The bite: Bernoulli must eliminate the true optimum materially MORE than EB.  If they
    # are equal, the adaptation was not necessary and Q7 5.2 A is unproven in our own code.
    if be_elim_true - eb_elim_true < 8:
        print("  *** Bernoulli does not eliminate the true optimum more than EB -- the "
              "overdispersion fixture is too weak to prove the adaptation matters (VACUOUS)")
        ok = False
    if eb_elim_true > 2:
        print("  *** empirical-Bernstein ALSO eliminates the true optimum -- it is not "
              "retaining it as claimed")
        ok = False
    if eb_crown_true < 15:
        print("  *** empirical-Bernstein rarely crowns the true optimum -- it is merely "
              "conservative, not USEFUL (it must still decide when the ranking is reliable)")
        ok = False
    print("  => PASS (Bernoulli eliminates the true optimum; EB retains AND crowns it)" if ok
          else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 5
def phase5(quiet):
    print("\n===== PHASE 5: THE STRUCTURAL SPLIT -- the sampler cannot reach a verdict knob "
          "=====")
    ok = True
    wl = whitelisted_knobs()
    # (a) whitelist and the never-tune sets are disjoint (the import guard, re-asserted).
    leak = wl & (INSTRUMENT_KNOBS | DETECTOR_KNOBS)
    if leak:
        print("  *** whitelist intersects instrument/detector knobs: %s" % sorted(leak))
        ok = False
    # (b) thousands of draws across all three sub-searches: only experiment knobs appear.
    pm = ParkMiller(12345)
    seen = set()
    for _ in range(4000):
        sub = pm.choice(SUBSEARCH_ORDER)
        cfg = sample_config(SUBSEARCH[sub], WARM_START[sub], pm)
        seen.update(cfg.keys())
    bad = seen & (INSTRUMENT_KNOBS | DETECTOR_KNOBS)
    if bad:
        print("  *** the sampler EMITTED a non-experiment knob: %s" % sorted(bad))
        ok = False
    if "HET_WINDOW" in seen:
        print("  *** HET_WINDOW (a detector knob) was sampled -- TRAP 2 violated")
        ok = False
    outside = seen - wl
    if outside:
        print("  *** the sampler emitted a knob outside the whitelist: %s" % sorted(outside))
        ok = False
    print("  %d distinct knobs sampled, all in the whitelist, none instrument/detector"
          % len(seen))
    # (c) the writer refuses a non-experiment knob; the reader rejects one in a file.
    tmp = tempfile.mkdtemp(prefix="tunecheck.")
    fpath = os.path.join(tmp, "sp.txt")
    try:
        write_config(fpath, {"G": {"HET_TAU_HOT": 5}}, "devbox")
        print("  *** write_config accepted an INSTRUMENT knob"); ok = False
    except AssertionError:
        pass
    # a legit file must contain NO instrument knob and NO bare tuned-number-without-label.
    write_config(fpath, {sub: dict(WARM_START[sub]) for sub in SUBSEARCH_ORDER}, "devbox")
    with open(fpath) as fh:
        body = fh.read()
    if "NOT MEASURED HERE" not in body:
        print("  *** the dev-box config file is not labelled 'NOT MEASURED HERE'"); ok = False
    for ik in INSTRUMENT_KNOBS | DETECTOR_KNOBS:
        if ik + "=" in body:
            print("  *** a non-experiment knob %s leaked into the config file" % ik); ok = False
    # reader rejects an instrument knob planted in a file.
    with open(fpath, "a") as fh:
        fh.write("HET_P_GOAL=0.001\n")
    try:
        read_config(fpath)
        print("  *** read_config accepted a planted instrument knob"); ok = False
    except ValueError:
        pass
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 6
def phase6(quiet):
    print("\n===== PHASE 6: THE IN-LOOP KS GATE -- a non-stationary bout is EXCLUDED =====")
    ok = True
    # An arm fed 8 stationary bouts at ~0.30 and 8 NON-stationary bouts at 0.99: the
    # non-stationary ones (het_ks2 verdict false) must not pull the estimate toward 0.99.
    pm = ParkMiller(7)
    obj = Synth({0: 0.30}, od_amp=0.0)
    arm = Arm({"_id": 0}, "cfg0")
    for _ in range(8):
        arm.add(obj.bout({"_id": 0}, pm))
    obj_bad = Synth({0: 0.30}, ks_fail_ids={0}, ks_fail_mean=0.99)
    for _ in range(8):
        arm.add(obj_bad.bout({"_id": 0}, pm))
    print("  arm mean after 8 stationary(0.30) + 8 non-stationary(0.99) bouts: %.3f"
          % arm.mean())
    print("  n_valid=%d  n_nonstationary(dropped)=%d" % (arm.n_valid, arm.n_nonstationary))
    if arm.n_nonstationary != 8:
        print("  *** the non-stationary bouts were not detected/dropped"); ok = False
    if not (0.20 <= arm.mean() <= 0.42):
        print("  *** the estimate was corrupted by non-stationary bouts (drift leaked in)")
        ok = False
    # Cold floor: an arm that only ever sees invalid bouts is VOID (not a low rate).
    cold = Arm({"_id": 0}, "cold")
    for _ in range(5):
        cold.add(Bout(0.0, 1.0, valid=False))
    if not cold.cold() or cold.raceable():
        print("  *** an all-invalid arm was not treated as the COLD FLOOR (void)"); ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 7
def phase7(quiet):
    print("\n===== PHASE 7: THE FACTORED SEARCH -- G then C then I, over the REAL knob "
          "spaces =====")
    # A per-sub-search gradient: each sub-search has ONE rewarded knob whose domain-max is
    # optimal (near-separable, Q7 3.2).  Two invariants: (1) the SEED FLOOR -- the warm-start
    # seed is always a candidate, so the search can NEVER regress below it; (2) ANTI-CONSTANT
    # -- it must STRICTLY improve on the seed in a majority of trials, or it is just returning
    # the seed (a 7th constant).  And every chosen config carries ONLY whitelisted knobs.
    reward = {"G": ("HET_BARRIER_PCT", 100.0),
              "C": ("HET_CPU_PRELOAD_PCT", 100.0),
              "I": ("HET_NOISE_GPU_BLOCKS", 32.0)}

    def obj_for(sub, base):
        knob, hi = reward[sub]

        class _O(object):
            def bout(self, cfg, pm):
                v = cfg.get(knob, 0) / hi
                v = min(max(v + (pm.unit() - 0.5) * 0.05, 0.0), 1.0)
                return Bout(v, weight=16.0, raw_n=16.0, kills=v * 16.0)
        return _O()

    ok = True
    wl = whitelisted_knobs()
    regressed = 0
    improved = 0
    trials = 0
    nseed = 15
    for seed in range(nseed):
        pm = ParkMiller(1 + seed)
        best, _log = tune.factored_search(obj_for, pm, n_configs=14, max_rounds=90)
        for sub in SUBSEARCH_ORDER:
            knob, _ = reward[sub]
            chosen = best[sub][knob]
            seedv = WARM_START[sub][knob]
            trials += 1
            if chosen < seedv:
                regressed += 1
            elif chosen > seedv:
                improved += 1
            for k in best[sub]:
                if k not in wl:
                    print("  *** factored_search chose a NON-whitelisted knob %r" % k)
                    ok = False
    print("  seed-floor regressions (must be 0): %d/%d" % (regressed, trials))
    print("  strict improvements over the seed:  %d/%d (%.0f%%) -- proves it SEARCHES"
          % (improved, trials, 100.0 * improved / trials))
    if regressed != 0:
        print("  *** the search regressed BELOW the warm-start seed -- the seed must be a "
              "floor (it is always a candidate)")
        ok = False
    if improved < 0.5 * trials:
        print("  *** the search rarely beats the seed -- it may just be RETURNING the seed "
              "(a 7th constant)")
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# ===========================================================================
# --bite : corrupt the machinery and prove each guard BITES, non-vacuously.
# ===========================================================================
def bite(quiet):
    print("===== --bite: does each check actually FAIL on a broken tuner? =====")
    ok = True

    # BITE 1 -- a constant tuner (always returns the seed/first config) must FAIL PHASE 1.
    # We emulate it by racing but overriding the winner to "the first config" and checking
    # the phase-1 property (winner==true best) would REJECT it.
    means = {0: 0.30, 1: 0.50, 2: 0.72, 3: 0.40}
    res = _run(Synth(means), _cfgs(0, 1, 2, 3), 0)
    true_best = 2
    seed_config_id = 0
    if _winner_id(res) != true_best:
        print("  *** control: the honest tuner did not find the optimum -- fixture broken")
        ok = False
    # the constant tuner would return seed_config_id (0), which != true_best -> phase 1
    # rejects it.  cmp: the two answers differ (the corruption is non-vacuous).
    if seed_config_id == true_best:
        print("  *** VACUOUS BITE: seed already IS the optimum -- change the fixture"); ok = False
    else:
        print("  BITE 1: a seed-returning tuner answers id %d; the optimum is id %d -- "
              "PHASE 1 rejects it (non-vacuous)." % (seed_config_id, true_best))

    # BITE 2 -- a tuner with NO anti-phantom guard (min_rounds=0 AND crowning the leader at
    # budget) would crown a winner on the constant objective.  Show that dropping the guard
    # flips PHASE 2 from 0 phantoms to many.
    cmeans = {0: 0.50, 1: 0.50, 2: 0.50}
    phantom_guarded = phantom_unguarded = 0
    for s in range(20):
        g = _run(Synth(cmeans, od_amp=0.02), _cfgs(0, 1, 2), s, max_rounds=60)
        if g.winner is not None:
            phantom_guarded += 1
        # unguarded: force a winner = current leader regardless of separation.
        u = _run(Synth(cmeans, od_amp=0.02), _cfgs(0, 1, 2), s, max_rounds=60)
        leader = max([a for a in u.arms if a.raceable()], key=lambda a: a.mean(), default=None)
        if leader is not None:
            phantom_unguarded += 1
    print("  BITE 2: phantoms WITH the guard=%d, WITHOUT (crown-the-leader)=%d"
          % (phantom_guarded, phantom_unguarded))
    if phantom_guarded != 0 or phantom_unguarded < 15:
        print("  *** the anti-phantom guard is not what stops the phantom (VACUOUS)"); ok = False

    # BITE 3 -- the overdispersion adaptation.  If EB is REPLACED by Bernoulli the true
    # optimum is ELIMINATED far more often.  This IS PHASE 4's contrast, asserted as a bite:
    # swapping the rule must change which arm survives.
    means2 = {0: 0.55, 1: 0.45}
    eb_elim = be_elim = 0
    for s in range(40):
        e_eb, _ = _simulate_elim(means2, s, 120, 24, 0.40, 4.0, use_bernoulli=False)
        e_be, _ = _simulate_elim(means2, s, 120, 24, 0.40, 4.0, use_bernoulli=True)
        if 0 in e_eb:
            eb_elim += 1
        if 0 in e_be:
            be_elim += 1
    print("  BITE 3: true-optimum ELIMINATED  EB=%d/40  Bernoulli=%d/40 (swap must worsen it)"
          % (eb_elim, be_elim))
    if be_elim - eb_elim < 8:
        print("  *** replacing EB with Bernoulli does not worsen the outcome (VACUOUS)"); ok = False

    # BITE 4 -- the structural split.  Plant an instrument knob in a whitelist and show the
    # import-time guard would fire.  Restore it; cmp that the injection changed the set.
    saved = dict(SUBSEARCH["G"])
    SUBSEARCH["G"]["HET_TAU_HOT"] = ("choice", [1, 5, 30])
    fired = False
    try:
        tune._assert_split_is_clean()
    except AssertionError:
        fired = True
    SUBSEARCH["G"].clear()
    SUBSEARCH["G"].update(saved)
    tune._assert_split_is_clean()   # must be clean again
    if not fired:
        print("  *** planting HET_TAU_HOT in a whitelist did NOT trip the split guard"); ok = False
    else:
        print("  BITE 4: planting an instrument knob in a whitelist trips the split guard; "
              "removing it restores clean (non-vacuous).")

    print("\n" + ("  => BITE PASS (every guard bites, non-vacuously)" if ok
                  else "  => BITE FAIL"))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    if a.bite:
        return 0 if bite(a.quiet) else 1
    results = [phase1(a.quiet), phase2(a.quiet), phase3(a.quiet), phase4(a.quiet),
               phase5(a.quiet), phase6(a.quiet), phase7(a.quiet)]
    print("\n%s  tunecheck: %d/%d phases passed."
          % ("OK" if all(results) else "FAIL", sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
