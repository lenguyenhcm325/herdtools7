#!/usr/bin/env python3
"""The tuner gate for hetlitmus/tune.py.

It does not check that the tuner RUNS -- structure is what every other gate checks, and
a tuner that always returned its seed would pass those while searching nothing.  It
checks that the search finds the right answer, refuses to answer when there is none, and
that removing any of Q7 5.2's three transfer fixes breaks it.

  PHASE 1  it finds a known optimum: given configs with distinct true means, the winner
           is the arg-max, and the win is by separation rather than by budget.
  PHASE 2  no phantom winner: on a constant objective it crowns nobody.
  PHASE 3  the drift bite (Q7 5.2 C2).  Under a rising baseline the sequential order
           (Kirkham Fig.10) picks the LATE config while SER^3 picks the true best, so
           the two schedules must disagree in those fixed directions.
  PHASE 4  the overdispersion bite (Q7 5.2 A).  On identical seeded bout streams the
           Bernoulli CI eliminates the true optimum far more often than empirical-
           Bernstein, which must both retain it and still crown it.
  PHASE 5  the structural split (Q7 traps 1/2): thousands of draws emit only experiment
           knobs, and the config writer and reader refuse anything else.
  PHASE 6  the in-loop KS gate (Q7 5.2 C1): a non-stationary bout is excluded from a
           config's rate estimate, and an all-invalid arm is the cold floor -- void,
           not a low rate.
  PHASE 7  the factored search over the REAL knob spaces: the warm-start seed is a floor
           the search never regresses below, and it strictly beats the seed in a
           majority of trials.

Run:  tunecheck.py          the seven phases (all must pass)
      tunecheck.py --bite   corrupt the tuner and prove each check fails, non-vacuously
Determinism: Park-Miller (tune.ParkMiller) + math only, no random/numpy, so the pins hold
on every machine and Python version.
"""

import argparse
import importlib.util
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tune  # noqa: E402
from tune import (ParkMiller, Bout, Arm, race,  # noqa: E402
                  SUBSEARCH, SUBSEARCH_ORDER, WARM_START,
                  INSTRUMENT_KNOBS, DETECTOR_KNOBS, write_config, read_config)

TUNE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tune.py")


# ===========================================================================
# The bite tool: a SCRATCH COPY of tune.py with a fragment replaced, imported under its
# own name.  Every phase below is written as a property parameterized on the tune module
# (or on a race callable), so a bite re-runs the phase's own check against a broken
# tuner instead of re-deriving it.  tune.py itself is never written -- the shell gates
# corrupt copies the same way (l0_tokens.sh).
# ===========================================================================
_SCRATCH = []
_NBITE = [0]


def _patched_tune(label, *subs):
    """Import tune.py with each (old, new) applied.  A fragment that does not occur
    EXACTLY once, or a copy that comes out byte-identical, raises: a doctoring that
    changed nothing proves nothing."""
    with open(TUNE_PY) as fh:
        src = fh.read()
    out = src
    for old, new in subs:
        n = out.count(old)
        if n != 1:
            raise AssertionError("BITE %s: fragment occurs %d times in tune.py (want 1): %r"
                                 % (label, n, old[:70]))
        out = out.replace(old, new)
    if out == src:
        raise AssertionError("VACUOUS BITE %s: the scratch tune.py is byte-identical to "
                             "the original" % label)
    if not _SCRATCH:
        _SCRATCH.append(tempfile.mkdtemp(prefix="tunecheck_bite."))
    _NBITE[0] += 1
    name = "tune_bite%d" % _NBITE[0]
    path = os.path.join(_SCRATCH[0], name + ".py")
    with open(path, "w") as fh:
        fh.write(out)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ===========================================================================
# The synthetic objective.  A config carries a hidden "_id"; the objective maps id ->
# true mean, optionally adds a wall-time drift baseline, and draws each bout as a
# latent rate plus a within-bout binomial -- doubly stochastic, so od_amp>0 makes the
# counts OVERDISPERSED (Fano>1).  weight_deflate makes the bout report fewer effective
# samples than cells drawn, while raw_n stays the full cell count the Bernoulli CI
# trusts, so the two CI rules divide by different Q (phase 4).
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
        # A non-stationary bout: corrupted mean, ks_ok=False, so the in-loop gate must
        # drop it (phase 6).
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


def _say(msg):
    print("  " + msg)


def _run(objective, configs, seed, schedule="ser3", use_bernoulli=False,
         max_rounds=150, min_rounds=3, delta=0.05, race_fn=None):
    pm = ParkMiller(seed)
    return (race_fn or race)(objective, [dict(c) for c in configs], pm, delta=delta,
                             max_rounds=max_rounds, min_rounds=min_rounds,
                             use_bernoulli=use_bernoulli, schedule=schedule)


def _runner(race_fn=None, **fixed):
    """An (objective, configs, seed) -> RaceResult callable.  `race_fn` swaps in a broken
    race, so a phase's property runs unchanged against it."""
    def run(objective, configs, seed):
        return _run(objective, configs, seed, race_fn=race_fn, **fixed)
    return run


def _winner_id(res):
    return None if res.winner is None else res.winner.config["_id"]


def _simulate_elim(means, seed, rounds, cells, od_amp, deflate, use_bernoulli,
                   min_rounds=3, delta=0.05, mod=tune):
    """Drive a race by hand in a fixed round-robin order, so the ONLY variable is the CI
    rule, and track cumulative elimination: once a config's upper bound falls below the
    best's lower bound it is dropped for good (Kirkham Fig.10's early-stop is permanent).
    Both rules see the identical bout stream (same seed => same Synth draws).  `mod`
    selects the tune module, so a bite can re-run this against a patched CI rule.
    Returns (eliminated_ids, crowned_id_or_None)."""
    pm = ParkMiller(seed)
    obj = Synth(means, cells=cells, od_amp=od_amp, weight_deflate=deflate)
    arms = {c: mod.Arm({"_id": c}, "c%d" % c) for c in means}
    elim = set()
    for r in range(rounds):
        for c in means:
            arms[c].add(obj.bout({"_id": c}, pm))
        if r + 1 >= min_rounds:
            live = [arms[c] for c in means if c not in elim and arms[c].raceable()]
            surv = {a.config["_id"] for a in mod.eliminate(live, delta, use_bernoulli)}
            for c in means:
                if c not in elim and arms[c].raceable() and c not in surv:
                    elim.add(c)
    liveids = [c for c in means if c not in elim and arms[c].raceable()]
    return elim, (liveids[0] if len(liveids) == 1 else None)


# --------------------------------------------------------------------------- PHASE 1
P1_MEANS = {0: 0.30, 1: 0.50, 2: 0.72, 3: 0.40}      # id 2 is the true best
P1_IDS, P1_BEST, P1_SEEDS = (0, 1, 2, 3), 2, 20


def _finds_optimum(run, seeds=P1_SEEDS):
    """PHASE 1's property: how often the arg-max wins, and whether the seed-0 race ends by
    separation rather than by exhausting the budget."""
    hits = 0
    for s in range(seeds):
        if _winner_id(run(Synth(P1_MEANS, od_amp=0.0), _cfgs(*P1_IDS), s)) == P1_BEST:
            hits += 1
    return hits, hits / float(seeds), run(Synth(P1_MEANS), _cfgs(*P1_IDS), 0).reason


def phase1():
    print("===== PHASE 1: does the search FIND a known optimum? =====")
    ok = True
    hits, frac, reason = _finds_optimum(_runner())
    print("  true optimum (id %d, mean %.2f) won %d/%d seeds (%.0f%%)"
          % (P1_BEST, P1_MEANS[P1_BEST], hits, P1_SEEDS, 100 * frac))
    if frac < 0.9:
        print("  *** the search does NOT reliably find the optimum")
        ok = False
    # And it converges to a single winner by separation, not by exhausting the budget.
    if reason != "separated":
        print("  *** winner declared without separation (reason=%s)" % reason)
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 2
P2_MEANS = {0: 0.50, 1: 0.50, 2: 0.50}
P2_SEEDS = 20


def _phantoms(run, seeds=P2_SEEDS):
    """PHASE 2's property: how many races crown a winner when no config is better."""
    n = 0
    for s in range(seeds):
        if run(Synth(P2_MEANS, od_amp=0.02), _cfgs(0, 1, 2), s).winner is not None:
            n += 1
    return n


def phase2():
    print("\n===== PHASE 2: does it REFUSE to crown a phantom on a constant objective? =====")
    ok = True
    phantom = _phantoms(_runner(max_rounds=60))
    print("  phantom winners on the constant objective: %d/20 (must be 0)" % phantom)
    if phantom != 0:
        print("  *** the tuner crowned a winner with no separating signal (a 7th constant)")
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 3
def phase3():
    print("\n===== PHASE 3: THE DRIFT BITE -- SER^3 de-confounds a rising baseline =====")
    # id 0 = true best (mean 0.60), id 1 = decoy (0.40), and the drift rises with the
    # global bout counter.  Sequential runs id 0 early/cold and id 1 late/hot, so the
    # decoy looks better; SER^3 interleaves, so both see the same mean drift.
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
    # The bite is the disagreement, in those directions: if sequential also picked id 0
    # the drift never bit, and SER^3 would be demonstrating nothing.
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
# id 0 = true best (mean 0.55), id 1 = decoy (0.45), under strong between-bout
# overdispersion.  Bernoulli's W(1-W)/Q_raw CI is far too narrow, so the decoy's transient
# early lead eliminates the true best FOR GOOD (the early-stop is permanent);
# empirical-Bernstein's empirical variance and deflated effective Q keep the radius
# honest.  The fixture point was picked by sweeping (OD, DEFL, CELLS, R) for a contrast
# that holds across seeds, not from one lucky seed.
P4_MEANS = {0: 0.55, 1: 0.45}
P4_OD, P4_DEFL, P4_CELLS, P4_R, P4_SEEDS = 0.40, 4.0, 24, 120, 40


def _od_contrast(mod=tune, seeds=P4_SEEDS):
    """PHASE 4's sweep: over identical bout streams, how often each CI rule eliminates the
    true optimum (id 0), and how often empirical-Bernstein still crowns it.  `mod` selects
    the tune module, so a bite re-runs the sweep against a patched CI rule."""
    eb_elim = be_elim = eb_crown = 0
    for s in range(seeds):
        e_eb, w_eb = _simulate_elim(P4_MEANS, s, P4_R, P4_CELLS, P4_OD, P4_DEFL,
                                    use_bernoulli=False, mod=mod)
        e_be, _ = _simulate_elim(P4_MEANS, s, P4_R, P4_CELLS, P4_OD, P4_DEFL,
                                 use_bernoulli=True, mod=mod)
        if 0 in e_eb:
            eb_elim += 1
        if 0 in e_be:
            be_elim += 1
        if w_eb == 0:
            eb_crown += 1
    return eb_elim, be_elim, eb_crown


def _od_verdict(counts, emit):
    """PHASE 4's three assertions over an `_od_contrast` result; returns the tags that
    failed.  Bernoulli must eliminate the true optimum materially more often than EB --
    equal counts would leave Q7 5.2 A's central claim unproven in our own code."""
    eb_elim, be_elim, eb_crown = counts
    bad = []
    if be_elim - eb_elim < 8:
        emit("*** Bernoulli does not eliminate the true optimum more than EB -- the "
             "overdispersion fixture is too weak to prove the adaptation matters (VACUOUS)")
        bad.append("no-contrast")
    if eb_elim > 2:
        emit("*** empirical-Bernstein ALSO eliminates the true optimum -- it is not "
             "retaining it as claimed")
        bad.append("eb-eliminates")
    if eb_crown < 15:
        emit("*** empirical-Bernstein rarely crowns the true optimum -- it is merely "
             "conservative, not USEFUL (it must still decide when the ranking is reliable)")
        bad.append("eb-undecided")
    return bad


def _od_report(counts, emit):
    eb_elim, be_elim, eb_crown = counts
    emit("Bernoulli CI ELIMINATED the true optimum (id 0): %d/%d  <- the transfer failure"
         % (be_elim, P4_SEEDS))
    emit("empirical-Bernstein eliminated the true optimum: %d/%d  <- retains it"
         % (eb_elim, P4_SEEDS))
    emit("empirical-Bernstein CROWNED the true optimum:    %d/%d  <- and it still decides"
         % (eb_crown, P4_SEEDS))


def phase4():
    print("\n===== PHASE 4: THE OVERDISPERSION BITE -- empirical-Bernstein retains the "
          "true optimum where Bernoulli eliminates it =====")
    counts = _od_contrast()
    _od_report(counts, _say)
    ok = not _od_verdict(counts, _say)
    print("  => PASS (Bernoulli eliminates the true optimum; EB retains AND crowns it)" if ok
          else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 5
def _split_property(mod, emit):
    """PHASE 5(a)+(b): the whitelist is disjoint from the never-tune sets, and thousands of
    draws from the REAL sampler emit whitelisted knobs only.  Parameterized on the tune
    module, so a bite runs the identical property against a corrupted sampler or a leaking
    whitelist.  Returns (failing tags, distinct knobs drawn)."""
    bad = []
    wl = mod.whitelisted_knobs()
    never = mod.INSTRUMENT_KNOBS | mod.DETECTOR_KNOBS
    # (a) the whitelist and the never-tune sets are disjoint (tune's import guard again).
    leak = wl & never
    if leak:
        emit("*** whitelist intersects instrument/detector knobs: %s" % sorted(leak))
        bad.append("leak")
    # (b) thousands of draws across all three sub-searches: only experiment knobs appear.
    pm = mod.ParkMiller(12345)
    seen = set()
    for _ in range(4000):
        sub = pm.choice(mod.SUBSEARCH_ORDER)
        seen.update(mod.sample_config(mod.SUBSEARCH[sub], mod.WARM_START[sub], pm))
    hit = seen & never
    if hit:
        emit("*** the sampler EMITTED a non-experiment knob: %s" % sorted(hit))
        bad.append("emitted")
    if "HET_WINDOW" in seen:
        emit("*** HET_WINDOW (a detector knob) was sampled -- TRAP 2 violated")
        bad.append("window")
    outside = seen - wl
    if outside:
        emit("*** the sampler emitted a knob outside the whitelist: %s" % sorted(outside))
        bad.append("outside")
    return bad, len(seen)


def phase5():
    print("\n===== PHASE 5: THE STRUCTURAL SPLIT -- the sampler cannot reach a verdict knob "
          "=====")
    bad, nseen = _split_property(tune, _say)
    ok = not bad
    print("  %d distinct knobs sampled, all in the whitelist, none instrument/detector"
          % nseen)
    # (c) the writer refuses a non-experiment knob; the reader rejects one in a file.
    tmp = tempfile.mkdtemp(prefix="tunecheck.")
    fpath = os.path.join(tmp, "sp.txt")
    try:
        write_config(fpath, {"G": {"HET_TAU_HOT": 5}}, "devbox")
        print("  *** write_config accepted an INSTRUMENT knob"); ok = False
    except AssertionError:
        pass
    # a legitimate file carries no instrument knob and no unlabelled tuned number.
    write_config(fpath, {sub: dict(WARM_START[sub]) for sub in SUBSEARCH_ORDER}, "devbox")
    with open(fpath) as fh:
        body = fh.read()
    if "NOT MEASURED HERE" not in body:
        print("  *** the dev-box config file is not labelled 'NOT MEASURED HERE'"); ok = False
    for ik in INSTRUMENT_KNOBS | DETECTOR_KNOBS:
        if ik + "=" in body:
            print("  *** a non-experiment knob %s leaked into the config file" % ik); ok = False
    # reader rejects an instrument knob planted in a file.
    planted = "HET_NWIN"
    with open(fpath, "a") as fh:
        fh.write("%s=64\n" % planted)
    try:
        read_config(fpath)
        print("  *** read_config accepted the planted instrument knob %s" % planted)
        ok = False
    except ValueError:
        pass
    print("  => PASS" if ok else "  => FAIL")
    return ok


# --------------------------------------------------------------------------- PHASE 6
def phase6():
    print("\n===== PHASE 6: THE IN-LOOP KS GATE -- a non-stationary bout is EXCLUDED =====")
    ok = True
    # An arm fed 8 stationary bouts at ~0.30 and 8 non-stationary ones at 0.99: the
    # latter must not pull the estimate toward 0.99.
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
# A per-sub-search gradient: each sub-search gets one rewarded knob whose domain-max is
# optimal (near-separable, Q7 3.2).  Two invariants -- the seed floor, since the warm-start
# seed is always a candidate and the search must NEVER land below it; and strict
# improvement over the seed in a majority of trials, without which the search may simply be
# returning the seed.  Every rewarded knob must be seeded INTERIOR to its domain, or the
# floor half of that pair holds by arithmetic rather than by search (`_seed_is_interior`).
P7_REWARD = {"G": ("HET_BARRIER_PCT", 100.0),
             "C": ("HET_CPU_PRELOAD_PCT", 100.0),
             "I": ("HET_NOISE_CHUNK", 8192.0)}


def _seed_is_interior(mod, sub, knob):
    """Does the knob's domain hold a value strictly BELOW its warm-start seed?"""
    dom = mod.SUBSEARCH[sub][knob]
    lo = dom[1] if dom[0] == "int" else min(dom[1])
    return lo < mod.WARM_START[sub][knob]


def _seed_floor(mod, reward, nseed=15, n_configs=14, max_rounds=90):
    """PHASE 7's two invariants, counted per sub-search: {sub: [regressed, improved,
    trials]} plus every non-whitelisted knob the search chose.  Parameterized on the tune
    module and on the field size, so a bite can drop the seed from the field."""
    def obj_for(sub, base):
        knob, hi = reward[sub]

        class _O(object):
            def bout(self, cfg, pm):
                v = cfg.get(knob, 0) / hi
                v = min(max(v + (pm.unit() - 0.5) * 0.05, 0.0), 1.0)
                return mod.Bout(v, weight=16.0, raw_n=16.0, kills=v * 16.0)
        return _O()

    wl = mod.whitelisted_knobs()
    tally = {sub: [0, 0, 0] for sub in mod.SUBSEARCH_ORDER}
    stray = set()
    for seed in range(nseed):
        pm = mod.ParkMiller(1 + seed)
        best, _log = mod.factored_search(obj_for, pm, n_configs=n_configs,
                                         max_rounds=max_rounds)
        for sub in mod.SUBSEARCH_ORDER:
            knob, _ = reward[sub]
            chosen, seedv = best[sub][knob], mod.WARM_START[sub][knob]
            t = tally[sub]
            t[2] += 1
            if chosen < seedv:
                t[0] += 1
            elif chosen > seedv:
                t[1] += 1
            stray.update(k for k in best[sub] if k not in wl)
    return tally, stray


def phase7():
    print("\n===== PHASE 7: THE FACTORED SEARCH -- G then C then I, over the REAL knob "
          "spaces =====")
    ok = True
    for sub in SUBSEARCH_ORDER:
        knob, _ = P7_REWARD[sub]
        if not _seed_is_interior(tune, sub, knob):
            _say("*** sub-search %s is rewarded on %s, whose warm start is its domain "
                 "MINIMUM: the seed floor cannot be regressed below and this sub-search "
                 "contributes no evidence (VACUOUS)" % (sub, knob))
            ok = False
    tally, stray = _seed_floor(tune, P7_REWARD)
    for k in sorted(stray):
        _say("*** factored_search chose a NON-whitelisted knob %r" % k)
        ok = False
    regressed = sum(t[0] for t in tally.values())
    improved = sum(t[1] for t in tally.values())
    trials = sum(t[2] for t in tally.values())
    _say("seed-floor regressions (must be 0): %d/%d   [%s]"
         % (regressed, trials, "  ".join("%s %d/%d" % (s, tally[s][0], tally[s][2])
                                         for s in SUBSEARCH_ORDER)))
    _say("strict improvements over the seed:  %d/%d (%.0f%%) -- proves it SEARCHES   [%s]"
         % (improved, trials, 100.0 * improved / trials,
            "  ".join("%s %d/%d" % (s, tally[s][1], tally[s][2]) for s in SUBSEARCH_ORDER)))
    if regressed != 0:
        _say("*** the search regressed BELOW the warm-start seed -- the seed must be a "
             "floor (it is always a candidate)")
        ok = False
    if improved < 0.5 * trials:
        _say("*** the search rarely beats the seed -- it may just be RETURNING the seed "
             "(a 7th constant)")
        ok = False
    print("  => PASS" if ok else "  => FAIL")
    return ok


# ===========================================================================
# --bite : corrupt the machinery and prove each guard BITES, non-vacuously.  Each bite
# runs the PHASE's own property -- once against tune.py, once against a scratch copy with
# one fragment replaced -- so what goes red is the shipped check, not a restatement of it.
# ===========================================================================
def _quiet(_msg):
    pass


def bite():
    print("===== --bite: does each check actually FAIL on a broken tuner? =====")
    ok = True
    try:
        # BITE 1 -- the tuner this file exists to reject: one that never races and hands
        # back the config it was seeded with, reporting it as separated.
        b1 = _patched_tune("seed-returning race", (
            '    arms = [Arm(c, "cfg%d" % i) for i, c in enumerate(configs)]\n',
            '    arms = [Arm(c, "cfg%d" % i) for i, c in enumerate(configs)]\n'
            '    return RaceResult(arms[0], arms, 1, "separated")\n'))
        h_ok, f_ok, r_ok = _finds_optimum(_runner())
        h_bad, f_bad, r_bad = _finds_optimum(_runner(race_fn=b1.race))
        print("  BITE 1: PHASE 1's property -- shipped race found id %d in %d/%d seeds "
              "(reason %s); seed-returning race %d/%d (reason %s)"
              % (P1_BEST, h_ok, P1_SEEDS, r_ok, h_bad, P1_SEEDS, r_bad))
        if f_ok < 0.9 or r_ok != "separated":
            print("  *** control: the shipped tuner does not pass PHASE 1 -- fixture broken")
            ok = False
        if f_bad >= 0.9:
            print("  *** a tuner that only ever returns its seed PASSES PHASE 1 (VACUOUS)")
            ok = False

        # BITE 2 -- the anti-phantom guard itself: at budget `race` crowns the leader
        # instead of refusing.  Nothing else moves, so the phantoms are attributable to
        # the guard and to nothing else.
        b2 = _patched_tune("anti-phantom guard removed", (
            '    return RaceResult(best if len(raceable) == 1 else None, arms, rounds,\n',
            '    return RaceResult(best, arms, rounds,\n'))
        guarded = _phantoms(_runner(max_rounds=60))
        unguarded = _phantoms(_runner(race_fn=b2.race, max_rounds=60))
        print("  BITE 2: phantoms on the constant objective -- guard in place %d/%d, "
              "guard removed %d/%d" % (guarded, P2_SEEDS, unguarded, P2_SEEDS))
        if guarded != 0 or unguarded < 15:
            print("  *** the anti-phantom guard is not what stops the phantom (VACUOUS)")
            ok = False

        # BITE 3 -- PHASE 4's verdict re-run against a `_radius` that ignores
        # use_bernoulli: both arms then race on the Bernoulli CI and the contrast collapses.
        b3 = _patched_tune("_radius always Bernoulli", (
            '    return arm.bernoulli_radius() if use_bernoulli else arm.eb_radius(delta)\n',
            '    return arm.bernoulli_radius()\n'))
        c_ok, c_bad = _od_contrast(), _od_contrast(mod=b3)
        fired_ok, fired_bad = _od_verdict(c_ok, _quiet), _od_verdict(c_bad, _quiet)
        print("  BITE 3: PHASE 4 (EB-elim, Bern-elim, EB-crown) shipped=%s -> %s ; "
              "_radius forced to Bernoulli=%s -> %s"
              % (c_ok, fired_ok or "PASS", c_bad, fired_bad or "PASS"))
        if fired_ok:
            print("  *** control: PHASE 4 does not pass against the shipped CI rule")
            ok = False
        if "no-contrast" not in fired_bad:
            print("  *** collapsing both arms onto the Bernoulli CI leaves PHASE 4 green "
                  "(VACUOUS)")
            ok = False

        # BITE 4 -- plant an instrument knob in a whitelist: the import-time guard must
        # fire, and removing it again must restore a clean split.
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
            print("  *** planting HET_TAU_HOT in a whitelist did NOT trip the split guard")
            ok = False
        else:
            print("  BITE 4: planting an instrument knob in a whitelist trips the split "
                  "guard; removing it restores clean (non-vacuous).")

        # BITE 5 -- the SAMPLER, which BITE 4 does not reach: sample_config plants a
        # detector knob in every draw while the sub-search spaces stay clean, so the
        # import guard sees nothing and only PHASE 5's 4000-draw loop can catch it.
        b5 = _patched_tune("sampler plants HET_WINDOW", (
            '    cfg = dict(seed_config)\n',
            '    cfg = dict(seed_config)\n    cfg["HET_WINDOW"] = 4\n'))
        clean5, _ = _split_property(tune, _quiet)
        fired5, _ = _split_property(b5, _quiet)
        print("  BITE 5: PHASE 5 -- shipped sampler -> %s ; sampler planting HET_WINDOW "
              "-> %s" % (clean5 or "PASS", fired5))
        if clean5:
            print("  *** control: PHASE 5 does not pass against the shipped sampler")
            ok = False
        for tag in ("emitted", "window", "outside"):
            if tag not in fired5:
                print("  *** PHASE 5's %r check stayed green on a sampler that emits a "
                      "detector knob" % tag)
                ok = False

        # BITE 6 -- the whitelist half of PHASE 5: an instrument knob inside a sub-search
        # space, with tune's import guard defused so the leak survives to the sampler.
        b6 = _patched_tune(
            "leaking whitelist, import guard defused",
            ('\n_assert_split_is_clean()\n',
             '\n# _assert_split_is_clean()  -- defused, so the leak reaches the sampler\n'),
            ('        "HET_BARRIER_PCT":      ("int", 0, 100),\n',
             '        "HET_BARRIER_PCT":      ("int", 0, 100),\n'
             '        "HET_TAU_HOT":          ("choice", [1, 5, 30]),\n'))
        fired6, _ = _split_property(b6, _quiet)
        print("  BITE 6: PHASE 5 -- a whitelist holding HET_TAU_HOT -> %s" % (fired6,))
        if "leak" not in fired6:
            print("  *** PHASE 5's whitelist-disjointness check stayed green on a leaking "
                  "whitelist")
            ok = False

        # BITE 7a -- the seed floor is evidence only where the reward knob is seeded
        # INTERIOR to its domain; rewarding I on a knob seeded at its domain minimum must
        # be rejected outright.
        stale = dict(P7_REWARD, I=("HET_NOISE_GPU_BLOCKS", 32.0))
        vac = [s for s in SUBSEARCH_ORDER if not _seed_is_interior(tune, s, stale[s][0])]
        live = [s for s in SUBSEARCH_ORDER
                if not _seed_is_interior(tune, s, P7_REWARD[s][0])]
        print("  BITE 7a: sub-searches whose seed floor is unfalsifiable -- shipped reward "
              "map %s ; I rewarded on HET_NOISE_GPU_BLOCKS %s" % (live or "none", vac))
        if live or vac != ["I"]:
            print("  *** the interior-seed guard does not separate the two reward maps "
                  "(VACUOUS)")
            ok = False

        # BITE 7b -- the floor itself: with the warm-start seed no longer in the field the
        # search does land below it, in every sub-search including I.
        b7 = _patched_tune("warm-start seed dropped from the field", (
            '        configs = [dict(WARM_START[sub])]             '
            '# the seed is always in the field\n',
            '        configs = []\n'))
        t_ok, _ = _seed_floor(tune, P7_REWARD, n_configs=2)
        t_bad, _ = _seed_floor(b7, P7_REWARD, n_configs=2)
        print("  BITE 7b: seed-floor regressions -- seed in the field %s ; seed dropped %s"
              % ({s: "%d/%d" % (t_ok[s][0], t_ok[s][2]) for s in SUBSEARCH_ORDER},
                 {s: "%d/%d" % (t_bad[s][0], t_bad[s][2]) for s in SUBSEARCH_ORDER}))
        if any(t_ok[s][0] for s in SUBSEARCH_ORDER):
            print("  *** control: the shipped search regressed below the seed")
            ok = False
        for s in SUBSEARCH_ORDER:
            if t_bad[s][0] == 0:
                print("  *** dropping the seed from sub-search %s's field produced NO "
                      "regression -- PHASE 7's floor is not falsifiable there" % s)
                ok = False
    finally:
        for d in _SCRATCH:
            shutil.rmtree(d, ignore_errors=True)
        del _SCRATCH[:]

    print("\n" + ("  => BITE PASS (every guard bites, non-vacuously)" if ok
                  else "  => BITE FAIL"))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true")
    a = ap.parse_args()
    if a.bite:
        return 0 if bite() else 1
    results = [phase1(), phase2(), phase3(), phase4(),
               phase5(), phase6(), phase7()]
    print("\n%s  tunecheck: %d/%d phases passed."
          % ("OK" if all(results) else "FAIL", sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
