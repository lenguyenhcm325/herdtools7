#!/usr/bin/env python3
"""The stress autotuner's search machinery: a factored, seeded, variance-aware random
search over the harness's stress knobs.

This is the search half -- it races configs on a caller-supplied objective and settles
no numeric value.  The objective is the positive control's mutant death rate, a forced
surrogate, since on correct hardware the outcome under test occurs zero times by
construction and so carries no gradient; reading one off a running harness is campaign
work, because the stress knobs are compile-time defines that nothing here can apply.
A death rate also needs CPU-GPU coherence and a live interconnect, so away from that
hardware every value written out is a warm-start seed stamped "not measured here".
Method, and the confidence residual it does not close:
hetlitmus/docs/00-environment-design.md sec 3.9.  campaign.py schedules the campaign
(which tests, how many runs); this schedules the tuning (which config).

Sources reused, cited as a condition of the reuse:
  * seeded Park-Miller config selection [GPUHarbor23 sec 3.4]
  * the data-peeking random search and its early stop [Kirkham20 Fig.10], skeleton
    reused and statistics replaced -- see `eliminate` and `race`
  * the variance-aware racing radius [Mnih08 sec 2]
  * randomized round-robin under non-stationary rewards [SER3 Alg.1]
  * the GPU knob space and the warm-start seed [Sorensen16 sec 3.2-3.4],
    [Kirkham20 sec 3.1], [CudaLitmus]
"""

import argparse
import math
import sys

# ===========================================================================
# Park-Miller (Lehmer minimal-standard) RNG.            [GPUHarbor23 sec 3.4]
# Same multiplier and modulus as het_stress.h het_rng, so a tuning campaign
# replays from its seed on the host exactly as on the device.  Reimplemented
# rather than shared: het_rng is device code, the config search runs host-side.
# ===========================================================================
PM_MOD = 2147483647          # 2^31 - 1 (Mersenne prime)
PM_MUL = 16807               # Park-Miller minimal-standard multiplier


class ParkMiller(object):
    def __init__(self, seed):
        s = int(seed) % PM_MOD
        if s == 0:
            s = 1                     # Park-Miller degenerates at 0 (het_rng_init)
        self.s = s

    def next_u32(self):
        self.s = (self.s * PM_MUL) % PM_MOD
        return self.s

    def unit(self):
        """A float in [0, 1)."""
        return (self.next_u32() - 1) / float(PM_MOD - 1)

    def randint(self, lo, hi):
        """Uniform integer in [lo, hi] inclusive."""
        if hi <= lo:
            return lo
        return lo + int(self.unit() * (hi - lo + 1))

    def choice(self, seq):
        return seq[self.randint(0, len(seq) - 1)]

    def shuffle(self, lst):
        """Fisher-Yates in place, with THIS generator -- the round order is part of
        what a seed replays."""
        for i in range(len(lst) - 1, 0, -1):
            j = self.randint(0, i)
            lst[i], lst[j] = lst[j], lst[i]
        return lst


# ===========================================================================
# The knob whitelist -- the ONLY knobs the sampler can reach.  The emitter's -D
# surface holds two kinds: experiment knobs change the hardware behaviour under
# test and are tunable; instrument knobs change what a result is allowed to
# conclude, so tuning one would be tuning the outcome.  The split is structural,
# not documentary -- the sampler draws from these spaces alone, and
# `_assert_split_is_clean` holds them apart at import.
# A domain is ("int", lo, hi) or ("choice", [v, ...]): search spaces, not values.
# The three sub-searches target three near-separable resources: on-die GPU caches
# (G), CPU caches and host DRAM (C), the CPU-GPU interconnect (I).  Every knob
# below exists in litmus/het-runtime/{het_stress.h,het_cpu_stress.h}.
# ===========================================================================
SUBSEARCH = {
    # -- Sub-search G: GPU scratchpad stress [Sorensen16 sec 3.2-3.4]. -------------
    "G": {
        "HET_STRESS_LINE_SIZE": ("choice", [4, 8, 16, 32, 64, 128]),   # patch size P
        "HET_STRESS_TARGETS":   ("int", 1, 32),                        # spread m
        "HET_STRESS_BLOCKS":    ("choice", [-1, 0, 16, 32, 64, 128]),  # -1=auto fill grid
        "HET_STRESS_ASSIGN":    ("choice", [0, 1]),                    # round-robin / chunk
        "HET_MEM_STRESS_PATTERN": ("choice", [0, 1, 2, 3]),            # st;st .. ld;ld
        "HET_MEM_STRESS_PCT":   ("int", 0, 100),
        "HET_MEM_STRESS_ITER":  ("choice", [50, 100, 200, 445, 800, 1600]),
        "HET_PRE_STRESS_PATTERN": ("choice", [0, 1, 2, 3]),
        "HET_PRE_STRESS_PCT":   ("int", 0, 100),
        "HET_PRE_STRESS_ITER":  ("choice", [16, 32, 57, 128, 256]),
        "HET_BARRIER_PCT":      ("int", 0, 100),
        "HET_SCRATCH_SIZE":     ("choice", [1024, 2048, 4608, 8192, 16384]),
        "HET_STRESS_MAX_ROUNDS": ("choice", [1000000000]),  # safety net, not a real tuning axis
    },
    # -- Sub-search C: CPU incantations [Alglave11 sec 3]. -------------------------
    "C": {
        "HET_CPU_ENEMIES":       ("choice", [-1, 0, 1, 2, 4, 8, 16]),  # -1=auto spare cores
        "HET_CPU_ENEMY_SEQ":     ("choice", [0, 1, 2, 3]),             # sigma st;st .. ld;ld
        "HET_CPU_PRELOAD_PCT":   ("int", 0, 100),
        "HET_CPU_SPREAD":        ("choice", [1, 2, 4, 8, 16, 32]),     # spread m
        "HET_CPU_STRIDE":        ("choice", [1, 2, 4, 8, 16, 32]),
        "HET_CPU_AFFINITY":      ("choice", [0, 1]),
        "HET_CPU_TEST_CORE0":    ("int", 0, 8),                        # first pinned core
        "HET_CPU_RESERVE_CORES": ("int", 0, 4),
        "HET_CPU_SCRATCH_WORDS": ("choice", [65536, 131072, 262144, 524288]),
    },
    # -- Sub-search I: interconnect stress.  NO portable seed exists for it. -------
    "I": {
        "HET_PLACE":           ("choice", [0, 1, 2]),   # first-touch / prefer-HBM / prefer-DDR
        "HET_NOISE_MB":        ("choice", [0, 128, 256, 1024, 4096, 8192]),  # 0=off; else > LLC
        "HET_NOISE_CPU":       ("choice", [0, 1]),
        "HET_NOISE_GPU_BLOCKS": ("choice", [0, 4, 8, 16, 32]),
        "HET_NOISE_CHUNK":     ("choice", [1024, 2048, 4096, 8192]),
        "HET_NOISE_STRIDE":    ("choice", [1, 2, 4, 8]),
    },
}

# The instrument knobs, named explicitly so this set and the whitelist can be asserted
# disjoint and no draw can land in it.
INSTRUMENT_KNOBS = frozenset({
    "HET_TAU_HOT", "HET_THETA_DISTINCT", "HET_NWIN",
    "HET_STATS_MAX_CELLS", "HET_EXHAUSTIVE_MAX",
})
# HET_WINDOW is a detector-resolution knob: calibrated against the exhaustive scan's
# ground truth at bring-up (hetlitmus/docs/00-environment-design.md sec 6), NEVER tuned.
DETECTOR_KNOBS = frozenset({"HET_WINDOW"})

SUBSEARCH_ORDER = ["G", "C", "I"]   # I last: warm-started with G*, C* fixed


def whitelisted_knobs():
    """The union of every knob the sampler may draw -- the ONLY reachable set."""
    out = set()
    for space in SUBSEARCH.values():
        out.update(space.keys())
    return out


def _assert_split_is_clean():
    """Checked at import: no instrument or detector knob sits in a sub-search space, so
    the sampler cannot reach one.  Adding one fails loudly here rather than silently
    letting the tuner tune the instrument."""
    reach = whitelisted_knobs()
    leaked = reach & (INSTRUMENT_KNOBS | DETECTOR_KNOBS)
    if leaked:
        raise AssertionError(
            "the sampler can reach non-experiment knob(s) %s: only whitelisted "
            "stress knobs are tunable, and a detector-resolution knob is never "
            "sampled.  Remove it from SUBSEARCH." % sorted(leaked))


_assert_split_is_clean()


# The warm-start seeds: a starting point to local-search around, NOT measured values.
# G is [CudaLitmus]'s params/stress_params.txt with its mem-stress pattern argument
# fixed, so pattern 0 (the only writer) is live here where that config left it
# read-only.  C is het_cpu_stress.h's defaults.  I is {no noise, first-touch}: no prior
# art exists for an interconnect stress config, so I is the one open search.  Re-tuning
# on the target is mandatory either way, since one chip's parameters need not be optimal
# on another chip of the same vendor [Kirkham20 sec 6.4].
WARM_START = {
    "G": {
        "HET_STRESS_LINE_SIZE": 16, "HET_STRESS_TARGETS": 9, "HET_STRESS_BLOCKS": -1,
        "HET_STRESS_ASSIGN": 1, "HET_MEM_STRESS_PATTERN": 0, "HET_MEM_STRESS_PCT": 20,
        "HET_MEM_STRESS_ITER": 445, "HET_PRE_STRESS_PATTERN": 3, "HET_PRE_STRESS_PCT": 65,
        "HET_PRE_STRESS_ITER": 57, "HET_BARRIER_PCT": 68, "HET_SCRATCH_SIZE": 4608,
        "HET_STRESS_MAX_ROUNDS": 1000000000,
    },
    "C": {
        "HET_CPU_ENEMIES": -1, "HET_CPU_ENEMY_SEQ": 0, "HET_CPU_PRELOAD_PCT": 50,
        "HET_CPU_SPREAD": 8, "HET_CPU_STRIDE": 8, "HET_CPU_AFFINITY": 1,
        "HET_CPU_TEST_CORE0": 0, "HET_CPU_RESERVE_CORES": 2, "HET_CPU_SCRATCH_WORDS": 262144,
    },
    "I": {
        "HET_PLACE": 0, "HET_NOISE_MB": 0, "HET_NOISE_CPU": 0, "HET_NOISE_GPU_BLOCKS": 0,
        "HET_NOISE_CHUNK": 4096, "HET_NOISE_STRIDE": 1,
    },
}


def sample_config(space, seed_config, pm):
    """Draw ONE config from a sub-search space, local to its warm-start seed: per knob,
    keep the seed value with probability ~1/3, else draw fresh from the domain.  Local
    search around a portable seed rather than blind global search, since a portable
    configuration costs about 12% of the relaxed-behaviour rate a hyper-tuned one
    reaches [Kirkham20 sec 1.2].  Returns {knob: value}, whitelisted knobs only."""
    cfg = dict(seed_config)
    for knob, dom in space.items():
        if pm.unit() < 0.34 and knob in seed_config:
            continue                              # keep the seed value (local search)
        kind = dom[0]
        if kind == "int":
            cfg[knob] = pm.randint(dom[1], dom[2])
        elif kind == "choice":
            cfg[knob] = pm.choice(dom[1])
        else:
            raise AssertionError("unknown domain kind %r" % (kind,))
    return cfg


# ===========================================================================
# The objective interface.  A search loop over a scalar; the scalar is a bout.
# ===========================================================================
class Bout(object):
    """One measurement of a config: a run (or short group of runs) of the harness.

      value   observed mutant-kill rate in [0,1] (real adapter: k_eff/usable).
      weight  effective sample count for this bout, supplied by the objective --
              nothing here derives one.  It is the bout's share of Q, which weights the
              arm's mean and variance and divides its empirical-Bernstein radius.
      raw_n   raw usable-run count -- used ONLY by `bernoulli_radius`, which trusts it
              as a count of iid trials.
      secs    wall-clock seconds this bout cost.
      kills   control_target_count sum.  Carried per bout for the hardware objective's
              throughput score; the search itself races on `value`.
      ks_ok   het_ks2's stationarity reading, taken from the HetStats `ks=' field and
              never recomputed; a non-stationary bout is dropped in-loop.
      valid   interleavings_detected>0 and the control was not cold.  An invalid bout is
              vacuous (window shut / engines never met), not evidence of a low rate.
    """
    __slots__ = ("value", "weight", "raw_n", "secs", "kills", "ks_ok", "valid")

    def __init__(self, value, weight, raw_n=None, secs=1.0, kills=0.0,
                 ks_ok=True, valid=True):
        self.value = float(value)
        self.weight = float(weight)
        self.raw_n = float(raw_n if raw_n is not None else weight)
        self.secs = float(secs)
        self.kills = float(kills)
        self.ks_ok = bool(ks_ok)
        self.valid = bool(valid)


# ===========================================================================
# The arm: one config under race, accumulating bouts.  It carries two radii --
# the empirical-Bernstein one that decides, and the Bernoulli one of
# [Kirkham20 Fig.10], kept only to exhibit why that one does not transfer.
# ===========================================================================
LN3 = math.log(3.0)


class Arm(object):
    def __init__(self, config, label):
        self.config = config
        self.label = label
        self._vals = []      # per-bout value
        self._wts = []       # per-bout effective weight (Q contribution)
        self._raw = []       # per-bout raw cell count (Bernoulli's Q)
        self.n_valid = 0
        self.n_invalid = 0
        self.n_nonstationary = 0

    def add(self, bout):
        if not bout.valid:
            self.n_invalid += 1
            return                                    # vacuous: not a low rate, no rate
        if not bout.ks_ok:
            # A non-stable run is restarted from the point of instability rather than
            # kept [Kirkham20 sec 5.1]: exclude it rather than let drift alias into
            # the mean.
            self.n_nonstationary += 1
            return
        self.n_valid += 1
        self._vals.append(bout.value)
        self._wts.append(max(bout.weight, 1e-9))
        self._raw.append(max(bout.raw_n, 1.0))

    def raceable(self):
        return self.n_valid >= 1

    def cold(self):
        """No valid bout ever -- the cold floor: the sub-search is VOID on this config,
        not "config bad"."""
        return self.n_valid == 0 and (self.n_invalid + self.n_nonstationary) > 0

    def Q(self):
        return sum(self._wts)                         # effective sample size

    def Q_raw(self):
        return sum(self._raw)

    def mean(self):
        q = self.Q()
        if q <= 0.0:
            return 0.0
        return sum(w * v for w, v in zip(self._wts, self._vals)) / q

    def var_hat(self):
        """Weighted empirical variance of the bout values about the weighted mean.  Under
        overdispersion (Fano>1) the between-bout spread is large, so this is large -- that
        is how `eb_radius` absorbs overdispersion with no pre-estimated dispersion figure.
        The divisor is Q = sum(w): the biased/MLE weighted form, no effective-df
        correction (the 1/t form of [Mnih08 sec 2]'s own sigma_t^2).  It under-estimates
        the variance and so under-widens the radius slightly -- kept because the racing
        rule is heuristic (see `eliminate`), not because the estimator is unbiased."""
        q = self.Q()
        if q <= 0.0 or len(self._vals) < 1:
            return 0.0
        m = self.mean()
        return sum(w * (v - m) ** 2 for w, v in zip(self._wts, self._vals)) / q

    def eb_radius(self, delta):
        """Empirical-Bernstein radius [Mnih08 sec 2]: sqrt(2 V_hat ln(3/delta)/Q) +
        3 b ln(3/delta)/Q, with the range b=1.  Wide when few effective samples OR high
        empirical variance -- the two regimes the Bernoulli interval gets wrong."""
        q = self.Q()
        if q <= 0.0:
            return 1.0
        t = LN3 - math.log(delta)                     # ln(3/delta)
        return math.sqrt(2.0 * self.var_hat() * t / q) + 3.0 * t / q

    def bernoulli_radius(self, z=1.96):
        """The interval Z*sqrt(W(1-W)/Q) of [Kirkham20 Fig.10], with Q = RAW cells (1
        trial = 1 iteration).  It does not transfer here: W(1-W) understates the
        overdispersed variance and raw_n is combinatorially inflated, so the radius is
        too narrow and the early stop fires too aggressively.  Kept as the contrast that
        shows it eliminating the true optimum where empirical-Bernstein retains it."""
        qr = self.Q_raw()
        if qr <= 0.0:
            return 1.0
        w = self.mean()
        return z * math.sqrt(max(w * (1.0 - w), 0.0) / qr)


# ===========================================================================
# The racing rule and the randomized round-robin scheduler [SER3 Alg.1].
# ===========================================================================
def _radius(arm, delta, use_bernoulli):
    return arm.bernoulli_radius() if use_bernoulli else arm.eb_radius(delta)


def eliminate(arms, delta, use_bernoulli):
    """The early stop of [Kirkham20 Fig.10] lines 38-41, made variance-aware: drop a
    config once its upper bound falls below the current best's lower bound.  Returns the
    survivors, order preserved.

    CONFIDENCE, precisely.  `delta` is a fixed per-comparison level applied unchanged
    every round -- no union bound over rounds, no delta/K split over arms.  What holds
    is the per-round empirical-Bernstein radius [Mnih08 sec 2], which `eb_radius`
    matches; the anytime guarantee [Mnih08 sec 3.1] and the family-wise race
    [Mnih08 sec 4] do NOT hold here and must not be cited as if they did.  The
    delta-spending schedule they rest on is absent by decision, since progressive
    elimination needs usable confidence late while any valid schedule front-loads the
    budget (hetlitmus/docs/00-environment-design.md sec 3.9, which tracks the residual
    as known-open).  So this is a heuristic best-arm search: what its pick is worth is
    established by the campaign the tuned harness then runs (het_verdict.h), not by this
    rule's confidence, and it feeds no reported outcome."""
    live = [a for a in arms if a.raceable()]
    if len(live) < 2:
        return live
    best = max(live, key=lambda a: a.mean())
    best_lo = best.mean() - _radius(best, delta, use_bernoulli)
    survivors = []
    for a in live:
        if a is best:
            survivors.append(a)
            continue
        a_hi = a.mean() + _radius(a, delta, use_bernoulli)
        if best_lo > a_hi:
            continue                                  # eliminated: strictly dominated
        survivors.append(a)
    return survivors


class RaceResult(object):
    def __init__(self, winner, arms, rounds, reason):
        self.winner = winner          # the winning Arm, or None (no confident winner)
        self.arms = arms
        self.rounds = rounds
        self.reason = reason          # "separated"|"budget"|"void"|"sequential"


def race(objective, configs, pm, delta=0.05, max_rounds=200, min_rounds=3,
         use_bernoulli=False, schedule="ser3"):
    """Race a set of configs on `objective` and return the winner (or None).

    schedule="ser3"       the production path [SER3 Alg.1]: each round, shuffle the
                          surviving arms with the seeded RNG, run one bout of each, then
                          eliminate.  Randomized round-robin, so drift hits every arm
                          equally instead of aliasing onto the config axis.
    schedule="sequential" the order of [Kirkham20 Fig.10]: run arm A to max_rounds
                          bouts, then B, ...  Kept as the contrast that exhibits that
                          aliasing.

    A winner is declared only once the field is down to ONE raceable arm after
    min_rounds, so a lucky early bout cannot crown a constant objective.  Budget spent
    with >1 arm alive returns no winner, reason="budget"; a field with no raceable arm
    left returns reason="void"."""
    arms = [Arm(c, "cfg%d" % i) for i, c in enumerate(configs)]
    rounds = 0
    if schedule == "sequential":
        for a in arms:
            for _ in range(max_rounds):
                a.add(objective.bout(a.config, pm))
            rounds += max_rounds
        survivors = eliminate(arms, delta, use_bernoulli)
        winner = max(survivors, key=lambda x: x.mean()) if survivors else None
        return RaceResult(winner, arms, rounds, "sequential")
    # --- randomized round-robin ---
    survivors = list(arms)
    while rounds < max_rounds:
        order = pm.shuffle([a for a in survivors if True])
        for a in order:
            a.add(objective.bout(a.config, pm))
        rounds += 1
        if rounds >= min_rounds:
            survivors = eliminate(survivors, delta, use_bernoulli)
        raceable = [a for a in survivors if a.raceable()]
        if not raceable:
            return RaceResult(None, arms, rounds, "void")
        if len(raceable) == 1 and rounds >= min_rounds:
            return RaceResult(raceable[0], arms, rounds, "separated")
    raceable = [a for a in survivors if a.raceable()]
    if not raceable:
        return RaceResult(None, arms, rounds, "void")
    best = max(raceable, key=lambda a: a.mean())
    # Budget spent with the field unresolved: report the leader but do NOT crown it.
    return RaceResult(best if len(raceable) == 1 else None, arms, rounds,
                      "separated" if len(raceable) == 1 else "budget")


# ===========================================================================
# Config file I/O.  key=value, in the shape [CudaLitmus]'s parseStressParamsFile reads,
# so a tuned config can be applied without a rebuild.  Off the target hardware the file
# carries only warm-start seeds, each stamped "not measured here".
# ===========================================================================
def write_config(path, config_by_sub, target, measured=False):
    lines = []
    lines.append("# HetLitmus stress config for target=%s" % target)
    lines.append("# format: HET_KNOB=value (runtime-reparseable; à la cuda-litmus "
                 "parseStressParamsFile).")
    if not measured:
        lines.append("# *** NOT MEASURED HERE ***  Every value below is a WARM-START SEED,")
        lines.append("# not a tuned number: a box with no CPU-GPU coherence and no C2C link")
        lines.append("# validates the tuning MACHINERY, never a value.  Re-tune on %s."
                     % target)
    for sub in SUBSEARCH_ORDER:
        cfg = config_by_sub.get(sub, {})
        if not cfg:
            continue
        lines.append("# --- sub-search %s ---" % sub)
        for knob in sorted(cfg):
            if knob not in whitelisted_knobs():
                raise AssertionError(
                    "refusing to write non-experiment knob %r to the config file: "
                    "only whitelisted stress knobs are tunable output" % knob)
            lines.append("%s=%s" % (knob, cfg[knob]))
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def read_config(path):
    """Parse a key=value config file back into {knob: int}.  Rejects any non-whitelisted
    knob: an instrument knob in a stress config is a fault, not a value to apply."""
    out = {}
    wl = whitelisted_knobs()
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if k in INSTRUMENT_KNOBS or k in DETECTOR_KNOBS:
                raise ValueError("config file carries a non-tunable knob %r -- an "
                                 "instrument/detector knob is never part of a stress "
                                 "config" % k)
            if k not in wl:
                raise ValueError("config file carries unknown knob %r" % k)
            out[k] = int(v)
    return out


# ===========================================================================
# The factored search.  G, then C, then I -- I last, warm-started with G*, C* fixed.
# Factoring turns a product |G|*|C|*|I| into a sum, which the three classes widening
# different windows is what licenses.  `objective_for(sub, base)` returns the objective
# for sub-search `sub` with the others pinned at `base`.  Random search rather than
# Bayesian optimisation: a GP surrogate assumes a smooth, stationary, homoscedastic
# objective and this one is none of the three.
# ===========================================================================
def factored_search(objective_for, pm, n_configs=8, delta=0.05, max_rounds=60,
                    min_rounds=3):
    best = {sub: dict(WARM_START[sub]) for sub in SUBSEARCH_ORDER}
    log = []
    for sub in SUBSEARCH_ORDER:
        base = {}
        for s in SUBSEARCH_ORDER:
            base.update(best[s])
        obj = objective_for(sub, base)
        configs = [dict(WARM_START[sub])]             # the seed is always in the field
        for _ in range(n_configs - 1):
            configs.append(sample_config(SUBSEARCH[sub], WARM_START[sub], pm))
        res = race(obj, configs, pm, delta=delta, max_rounds=max_rounds,
                   min_rounds=min_rounds, schedule="ser3")
        if res.winner is not None:
            best[sub] = res.winner.config
        log.append((sub, res.reason, None if res.winner is None else res.winner.mean()))
    return best, log


# ===========================================================================
# CLI.  --self-test runs the machinery on a trivial synthetic objective and prints
# a config file's worth of seeds -- plumbing smoke only.  Tuning against a real harness
# is a hardware activity and lives with the campaign, not here.
# ===========================================================================
class _TrivialObjective(object):
    """A synthetic objective with a known optimum: reward rises with HET_BARRIER_PCT.
    Plumbing smoke for --self-test, not a validation of the search."""
    def __init__(self, knob="HET_BARRIER_PCT"):
        self.knob = knob

    def bout(self, config, pm):
        base = config.get(self.knob, 0) / 100.0
        v = min(max(base + (pm.unit() - 0.5) * 0.02, 0.0), 1.0)
        return Bout(v, weight=8.0, raw_n=8.0, secs=1.0, kills=v * 8.0)


def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus stress autotuner (search machinery).")
    ap.add_argument("--self-test", action="store_true",
                    help="run the search on a trivial synthetic objective (plumbing smoke)")
    ap.add_argument("--target", default="devbox",
                    help="target label for the output file name")
    ap.add_argument("--out", default=None, help="output config file (default stdout)")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    pm = ParkMiller(a.seed)
    obj = _TrivialObjective()
    best, log = factored_search(lambda sub, base: obj, pm, n_configs=6, max_rounds=20)
    for sub, reason, mean in log:
        print("tune: sub-search %s -> %s (best mean %s)"
              % (sub, reason, "%.4f" % mean if mean is not None else "-"))
    if a.out:
        write_config(a.out, best, a.target, measured=False)
        print("tune: wrote %s (WARM-START SEEDS only -- not measured here)" % a.out)
    else:
        print("# (machinery self-test: the values below are SEEDS, not measured)")
        import io
        buf = io.StringIO()
        # reuse write_config's formatting via a temp path-free path
        for sub in SUBSEARCH_ORDER:
            for knob in sorted(best[sub]):
                buf.write("%s=%s\n" % (knob, best[sub][knob]))
        sys.stdout.write(buf.getvalue())
    return 0


if __name__ == "__main__":
    sys.exit(main())
