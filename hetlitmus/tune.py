#!/usr/bin/env python3
"""HetLitmus B8a -- the AUTOTUNER search machinery (the dev-box-testable half).

WHAT THIS IS.  A factored, seeded, variance-aware random search over the het harness's
STRESS parameter space, scored on the observable positive-control death rate.  It is a
search loop over a scalar objective; the scalar is hardware-only, so on the dev box the
loop is validated against a SYNTHETIC objective with a KNOWN optimum (hetlitmus/verify/
tunecheck.py).  This file PRODUCES NOT ONE TUNED NUMBER (Q7 4.2): every numeric it can
emit is a warm-start SEED, explicitly labelled "not measured here".

WHY IT EXISTS.  On correct hardware the forbidden violation occurs ZERO times by
construction, so it carries no gradient (Q7 2.1).  The field's surrogate, and ours, is
the mutant DEATH RATE -- "legitimate MCS violations are too rare to use as an efficacy
metric" (MC-Mutants ASPLOS'23, Abstract p.473).  The objective is a THROUGHPUT (yield x
rate), Delta control_target_count / Delta t, which correctly penalises a config that
widens the window but slows the loop (Q7 2.3; the Q6 3.3 remote-placement confound).

SOURCES REUSED (cited as a licence/attribution condition, per the SHARED CHARGE):
  * seeded Park-Miller (Lehmer minimal-standard) config selection, so a campaign replays
    from a seed -- Levine et al., GPUHarbor ISSTA'23 3.4.  Same generator as
    het_stress.cuh het_rng (16807 / 2^31-1): the tuner and the device draw from one lineage.
  * the data-peeking random-search + early-stop SHAPE -- Kirkham et al., "Foundations of
    Empirical Memory Consistency Testing", OOPSLA'20 5.1 (Fig.10).  We REUSE the skeleton
    and REPLACE the statistics (Q7 5.2): the Bernoulli-variance CI, the iteration-as-trial
    unit, and the sequential config order each break under Q3's overdispersion/drift.
  * the variance-aware racing rule -- Mnih, Szepesvari, Audibert, "Empirical Bernstein
    Stopping", ICML'08.  The empirical variance absorbs overdispersion with no F_hat
    pre-estimate.
  * randomized round-robin best-arm identification under NON-STATIONARY rewards -- SER^3
    (Allesiardo & Feraud).  De-confounds thermal/occupancy drift by interleaving arms.
  * the reproducibility/time budget -- MC-Mutants ASPLOS'23 Alg.1, ceilingRate =
    ceil(-log(1-r)/b).  Reused AS A LOWER BOUND, widened by F_hat (Q7 5.2 E); it is the
    SAME formula as het_verdict.h het_budget_runs (F*log(0.05)/log(1-p_min)).
  * the GPU stress knob space + the cuda-litmus warm-start seed -- Sorensen & Donaldson
    PLDI'16, Kirkham OOPSLA'20 3.1, Reese Levine's cuda-litmus params/stress_params.txt.

THE TWO KINDS OF KNOB (Q7 TRAP 1 -- tuning the second kind is FABRICATION).  The emitter
exposes ~37 -D knobs.  EXPERIMENT knobs change the HARDWARE BEHAVIOUR UNDER TEST -- B8
tunes these.  INSTRUMENT knobs change WHAT WE ARE ALLOWED TO CONCLUDE (HET_TAU_HOT,
HET_P_GOAL, HET_NWIN, ...) -- lowering them would make more nulls "credible" or more
tests "bounded"; that is tuning the VERDICT, not the experiment.  The split is enforced
STRUCTURALLY: the sampler draws only from EXPERIMENT (a whitelist); an instrument knob is
not a value the sampler can reach.  HET_WINDOW is a DETECTOR-resolution knob (TRAP 2):
tuning a detector to maximise its own detections is circular, so it too is unreachable --
it is CALIBRATED against the exhaustive ground truth (calibrate_window below), not tuned.

RELATION TO campaign.py (B7b).  That driver schedules the CAMPAIGN (which tests, how many
runs).  This driver schedules the TUNING (which config).  Both spawn harness invocations
via a --runner template and read the machine-readable HetStats line; both are validated on
the dev box against a STUB runner.  The tuner NEVER runs the emitted harness expecting weak
behaviours -- the dev box has no CPU-GPU coherence (SHARED CHARGE); a real death rate is
hardware-only.

WHY RANDOM SEARCH, NOT BAYESIAN OPT (Q7 3.3, a settled decision -- do not re-open).
Bayesian optimisation is REJECTED: its GP surrogate assumes a SMOOTH, STATIONARY,
HOMOSCEDASTIC objective, and Q3 established the het objective is none of the three
(non-smooth memory-stress functions -- Kirkham/Iorga'20 show random search ~ intelligent
search here; drift; overdispersion).  Hyperband / successive-halving is the OPTIONAL
multi-fidelity upgrade IF the hardware window bites (a strict generalisation of the racing
loop here -- data-peeking is its 2-arm special case); the SAME three fixes (empirical-
Bernstein, (instance,run) unit, randomized round-robin) apply to its promotion rule.  Not
built here because the factored + early-stop search is expected to fit the window; it is a
B8b decision, made on measured budget.

WHAT IS DELIBERATELY DEFERRED TO B8b (the hardware campaign).  Every NUMERIC value; whether
the interconnect sub-search actually raises the het death rate (Fusco measured bandwidth,
never yield); the Fano factor F_hat (it sets both the CI width and the budget multiplier);
the oracle-validity correlation (that a het mutant's C2C death rate tracks genuine CMCM-
violation exposure is ASSUMED, unmeasured -- state it as an assumption, never a theorem);
HET_WINDOW's calibrated value; and the harness-side RUNTIME re-parse of a stress config
(the emitter's stress knobs are compile-time #defines today -- see HarnessObjective's
BOUNDARY note).  This file builds and validates the MACHINERY; it settles no value.
"""

import argparse
import math
import os
import shlex
import subprocess
import sys
import time

# ===========================================================================
# Park-Miller (Lehmer minimal-standard) RNG.                 [GPUHarbor 3.4]
# The SAME generator as het_stress.cuh het_rng (multiplier 16807, modulus
# 2^31-1): a tuning campaign is replayable from its seed, on the host exactly
# as on the device.  Reimplemented (not "a second het_ks2"): the device
# function is CUDA, and a search over configs runs host-side.
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
        """Fisher-Yates in place, with THIS generator -- the SER^3 round order is
        part of what a seed replays."""
        for i in range(len(lst) - 1, 0, -1):
            j = self.randint(0, i)
            lst[i], lst[j] = lst[j], lst[i]
        return lst


# ===========================================================================
# THE KNOB WHITELIST (Q7 TRAP 1).  A domain is one of:
#   ("int",  lo, hi)          -- uniform integer in [lo, hi]
#   ("choice", [v, v, ...])   -- one of an explicit set
# These are SEARCH SPACES (bounds the sampler explores), NOT tuned values.
# The three sub-searches target three near-separable resources (Q7 3.2):
# on-die GPU caches (G), CPU-local caches/LPDDR (C), the C2C interconnect (I).
#
# Every knob name below was verified against the LIVE emitter this session
# (litmus/het-runtime/{het_stress.cuh,het_cpu_stress.h}).  DRIFT vs the brief:
# the brief wrote HET_CPU_TEST_CORE; the live knob is HET_CPU_TEST_CORE0.
# ===========================================================================
SUBSEARCH = {
    # -- Sub-search G: GPU scratchpad stress (S&D patch/spread/sequence; Q5). ------
    "G": {
        "HET_STRESS_LINE_SIZE": ("choice", [4, 8, 16, 32, 64, 128]),   # S&D patch size P
        "HET_STRESS_TARGETS":   ("int", 1, 32),                        # S&D spread m
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
    # -- Sub-search C: CPU incantations (litmus7 domain; Q6 Half 1). ---------------
    "C": {
        "HET_CPU_ENEMIES":       ("choice", [-1, 0, 1, 2, 4, 8, 16]),  # -1=auto spare cores
        "HET_CPU_ENEMY_SEQ":     ("choice", [0, 1, 2, 3]),             # sigma st;st .. ld;ld
        "HET_CPU_PRELOAD_PCT":   ("int", 0, 100),
        "HET_CPU_SPREAD":        ("choice", [1, 2, 4, 8, 16, 32]),     # S&D spread m
        "HET_CPU_STRIDE":        ("choice", [1, 2, 4, 8, 16, 32]),
        "HET_CPU_AFFINITY":      ("choice", [0, 1]),
        "HET_CPU_TEST_CORE0":    ("int", 0, 8),                        # first pinned core
        "HET_CPU_RESERVE_CORES": ("int", 0, 4),
        "HET_CPU_SCRATCH_WORDS": ("choice", [65536, 131072, 262144, 524288]),
    },
    # -- Sub-search I: interconnect stress (C2C; Q6 Half 2).  NO portable seed. -----
    "I": {
        "HET_PLACE":           ("choice", [0, 1, 2]),   # first-touch / prefer-HBM / prefer-DDR
        "HET_NOISE_MB":        ("choice", [0, 128, 256, 1024, 4096, 8192]),  # 0=off; else > LLC
        "HET_NOISE_CPU":       ("choice", [0, 1]),
        "HET_NOISE_GPU_BLOCKS": ("choice", [0, 4, 8, 16, 32]),
        "HET_NOISE_CHUNK":     ("choice", [1024, 2048, 4096, 8192]),
        "HET_NOISE_STRIDE":    ("choice", [1, 2, 4, 8]),
    },
}

# INSTRUMENT knobs -- the sampler must NEVER reach these (Q7 TRAP 1).  Kept as an
# explicit set so the gate can assert the whitelist and the denylist are DISJOINT and
# the sampler's reachable set never intersects the denylist.  (HET_EXHAUSTIVE_MAX is
# historical -- no live #define -- but stays here as defence in depth.)
INSTRUMENT_KNOBS = frozenset({
    "HET_TAU_HOT", "HET_THETA_DISTINCT", "HET_P_GOAL", "HET_P_MIN", "HET_NWIN",
    "HET_STATS_MAX_CELLS", "HET_TAU_MIN_SAMPLES", "HET_EXHAUSTIVE_MAX",
})
# HET_WINDOW is a DETECTOR-resolution knob (TRAP 2): calibrated, never tuned.
DETECTOR_KNOBS = frozenset({"HET_WINDOW"})

SUBSEARCH_ORDER = ["G", "C", "I"]   # I LAST: warm-started with G*,C* fixed (Q7 3.2/3.3)


def whitelisted_knobs():
    """The union of every knob the sampler may draw -- the ONLY reachable set."""
    out = set()
    for space in SUBSEARCH.values():
        out.update(space.keys())
    return out


def _assert_split_is_clean():
    """The structural guarantee TRAP 1 demands, checked at import: an instrument or
    detector knob is UNREACHABLE because it is not in any sub-search space.  If a future
    edit adds one to a whitelist, this fails LOUDLY at import rather than silently letting
    the tuner tune the verdict."""
    reach = whitelisted_knobs()
    leaked = reach & (INSTRUMENT_KNOBS | DETECTOR_KNOBS)
    if leaked:
        raise AssertionError(
            "TRAP 1/2 VIOLATION: the sampler can reach non-experiment knob(s) %s -- "
            "tuning an instrument/detector knob is fabrication, not tuning.  Remove it "
            "from SUBSEARCH." % sorted(leaked))


_assert_split_is_clean()


# The WARM-START seeds (Q7 3.2(3)).  NOT MEASURED VALUES -- a starting point to local-search
# around.  G0 = cuda-litmus params/stress_params.txt, with the MEM_STRESS bug FIXED (B4): the
# shipped config's mem-stress was read-only, so pattern 0 -- the only WRITER -- was inert;
# here it is live, which is exactly why re-tuning on target hardware is MANDATORY, not
# optional (Kirkham 6.4: "not optimal on another chip, even from the same vendor").  C0 =
# het_cpu_stress.h defaults (= litmus7 defaults' spirit).  I0 = {no noise, first-touch}: no
# prior art exists for a C2C stress config, so I is the one true search.
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
    """Draw ONE config from a sub-search space, local to the warm-start seed: with
    probability ~1/3 per knob keep the seed value, else draw fresh from the domain.  This
    is Kirkham's "local search around a portable seed", not blind global random search
    (Q7 3.2(3): a portable seed costs only ~12%, so warm-start is cheap).  Returns a dict
    of {knob: value}; ONLY whitelisted knobs can appear."""
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
# THE OBJECTIVE INTERFACE.  A search loop over a scalar; the scalar is a BOUT.
# ===========================================================================
class Bout(object):
    """One measurement of a config: a run (or short group of runs) of the harness.

      value   -- the observed mutant-kill RATE in [0,1] for this bout (real adapter:
                 k_eff/usable from the HetStats line; the yield the death rate is built on).
      weight  -- the EFFECTIVE sample count of the bout = R_eff = R_usable*N_eff/DEFF
                 (Q3/B7b; deliverable #3's Q = R x N_eff).  Deflated under within-run
                 correlation, which is exactly how the racing CI learns to widen.
      raw_n   -- the RAW cell count (usable runs).  Used ONLY by the Bernoulli CI (the
                 broken one, kept for the bite): Bernoulli trusts raw_n as iid trials.
      secs    -- wall-clock seconds this bout cost (throughput denominator).
      kills   -- raw control_target_count sum (throughput numerator); death rate =
                 kills/secs.  Hardware-only channel; the synthetic objective supplies it.
      ks_ok   -- het_ks2's stationarity verdict for this bout (reused, NOT recomputed:
                 the harness runs het_ks2 and reports ks= in the HetStats line).  A
                 non-stationary bout is dropped from the rate estimate in-loop (Q7 5.2 C1).
      valid   -- interleavings_detected>0 AND the control was not cold.  An invalid bout
                 is VACUOUS (window shut / engines never met), not evidence of a low rate.
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
# THE ARM: one config under race, accumulating bouts.  Holds BOTH the
# empirical-Bernstein radius (the real rule) and the Bernoulli radius (kept
# only so the gate can DEMONSTRATE the transfer failure -- Q7 5.2 A).
# ===========================================================================
LN3 = math.log(3.0)


class Arm(object):
    def __init__(self, config, label):
        self.config = config
        self.label = label
        self._vals = []      # per-bout value
        self._wts = []       # per-bout effective weight (Q contribution)
        self._raw = []       # per-bout raw cell count (Bernoulli's Q)
        self.kills = 0.0     # sum control_target_count (throughput numerator)
        self.secs = 0.0      # sum wall-seconds   (throughput denominator)
        self.n_valid = 0
        self.n_invalid = 0
        self.n_nonstationary = 0

    def add(self, bout):
        if not bout.valid:
            self.n_invalid += 1
            return                                    # vacuous: not a low rate, no rate
        if not bout.ks_ok:
            # Kirkham 5.1 "restart from the point of instability": a non-stationary bout's
            # rate is untrustworthy; exclude it rather than let drift alias into the mean.
            self.n_nonstationary += 1
            return
        self.n_valid += 1
        self._vals.append(bout.value)
        self._wts.append(max(bout.weight, 1e-9))
        self._raw.append(max(bout.raw_n, 1.0))
        self.kills += bout.kills
        self.secs += bout.secs

    def raceable(self):
        return self.n_valid >= 1

    def cold(self):
        """No valid bout ever -- the cold floor (Q7 2.3): the sub-search is VOID on this
        config, not 'config bad'."""
        return self.n_valid == 0 and (self.n_invalid + self.n_nonstationary) > 0

    def Q(self):
        return sum(self._wts)                         # effective sample size (deliverable #3)

    def Q_raw(self):
        return sum(self._raw)

    def mean(self):
        q = self.Q()
        if q <= 0.0:
            return 0.0
        return sum(w * v for w, v in zip(self._wts, self._vals)) / q

    def death_rate(self):
        """The PRIMARY objective (Q7 2.3): kills per wall-second.  Throughput, not yield --
        it penalises a config that widens the window but slows the loop."""
        if self.secs <= 0.0:
            return 0.0
        return self.kills / self.secs

    def var_hat(self):
        """Weighted empirical variance of the bout values about the weighted mean.  Under
        Q3 overdispersion (Fano>1) the between-bout spread is large, so this is large --
        that is how the empirical-Bernstein CI absorbs overdispersion WITHOUT a pre-
        estimated F_hat (Q7 5.2 Fix 2).

        DISCLOSURE (deep-review F9): the divisor is Q = sum(w) -- the MLE/biased weighted
        variance, no effective-degrees-of-freedom correction (the same biased 1/t form as
        Mnih'08 Section 2's own sigma_t^2).  It slightly UNDER-estimates the variance and so
        slightly UNDER-widens `eb_radius`.  Kept because the racing rule is a heuristic
        best-arm search carrying no anytime/family-wise guarantee to protect (see
        `eliminate`) -- NOT because this estimator is unbiased."""
        q = self.Q()
        if q <= 0.0 or len(self._vals) < 1:
            return 0.0
        m = self.mean()
        return sum(w * (v - m) ** 2 for w, v in zip(self._wts, self._vals)) / q

    def eb_radius(self, delta):
        """Empirical-Bernstein confidence radius (Mnih-Szepesvari-Audibert ICML'08;
        Maurer-Pontil form): sqrt(2 V_hat ln(3/delta) / Q) + 3 b ln(3/delta) / Q, range
        b=1.  Wide when few effective samples OR high empirical variance -- exactly the two
        regimes Kirkham's Bernoulli CI gets WRONG under overdispersion."""
        q = self.Q()
        if q <= 0.0:
            return 1.0
        t = LN3 - math.log(delta)                     # ln(3/delta)
        return math.sqrt(2.0 * self.var_hat() * t / q) + 3.0 * t / q

    def bernoulli_radius(self, z=1.96):
        """Kirkham Fig.10's CI = Z*sqrt(W(1-W)/Q), with Q = RAW cells (1 trial = 1
        iteration).  DOES NOT TRANSFER (Q7 5.2 A/B): W(1-W) understates the overdispersed
        variance AND raw_n is combinatorially inflated, so this is TOO NARROW and the
        early-stop fires too aggressively.  KEPT ONLY so tunecheck.py can demonstrate it
        eliminating the true optimum where empirical-Bernstein retains it."""
        qr = self.Q_raw()
        if qr <= 0.0:
            return 1.0
        w = self.mean()
        return z * math.sqrt(max(w * (1.0 - w), 0.0) / qr)


# ===========================================================================
# THE RACING RULE + THE SER^3 SCHEDULER (deliverables #3, #4).
# ===========================================================================
def _radius(arm, delta, use_bernoulli):
    return arm.bernoulli_radius() if use_bernoulli else arm.eb_radius(delta)


def eliminate(arms, delta, use_bernoulli):
    """Kirkham Fig.10 lines 38-41, variance-aware: drop config c once its UPPER bound falls
    below the current best's LOWER bound.  Returns the surviving arms (order preserved).

    CONFIDENCE SEMANTICS -- what `delta` does and does NOT buy (deep-review F9; read this
    before citing Mnih'08 for a guarantee).  `delta` is a FIXED per-comparison level (0.05,
    the `race()` default) applied UNCHANGED every round: no union bound over rounds, and no
    `delta/K` split across the K competing arms.  So the confidence each `eliminate` call
    spends is PER-COMPARISON only -- NOT anytime-valid and NOT family-wise.  Across the ~150
    sequential elimination rounds a factored search peeks this bound again and again, and the
    true probability of EVER wrongly dropping the best arm is not bounded by `delta`.
      * PROVIDED (the only Mnih'08 claim that stays valid): the per-round empirical-Bernstein
        radius of Mnih-Szepesvari-Audibert ICML'08 SECTION 2, Eq.(2) --
        sqrt(2*sigma^2*ln(3/delta)/t) + 3*R*ln(3/delta)/t, R=1.  `eb_radius` matches it
        exactly (deep-review slice-4 confirmed this numerically).
      * NOT provided: (i) the ANYTIME, all-t guarantee of Mnih'08 SECTION 3.1 (EBStop), which
        needs a spent sequence d_t with sum_t d_t <= delta (the paper uses
        d_t = delta*(p-1)/(p*t^p)) so one 1-delta band holds for every round at once; and
        (ii) the FAMILY-WISE racing guarantee of Mnih'08 SECTION 4 (the empirical Bernstein
        race), which needs the delta/(M*N) split over M arms x N rounds.  This function does
        neither, so neither guarantee holds.
      * WHY it is deliberately absent (do NOT "fix" this back without re-deriving the rule):
        the textbook anytime schedule -- d_t = delta*(p-1)/(p*t^p), p=2, with a delta/K
        per-arm split -- WAS implemented (2026-07-15, DR1 Part E) and empirically BROKE
        elimination: tunecheck went 4/7 (SER^3 drift recovery 0/20, EB-crowns-optimum 0/40,
        factored-search-beats-seed FAIL).  Progressive elimination over ~150 rounds needs
        usable confidence LATE, while any valid sum_t d_t <= delta schedule front-loads the
        budget and blows up the late-round radii, so the field stops separating.  A correct
        anytime/fixed-budget rule (LUCB, or a fixed-budget delta/(T_max*K) split reusing the
        `budget_runs` mirror = Mnih'08 Section 4's delta/(M*N)) is FUTURE WORK, not a
        comment-toggle.
      * What MAY therefore be claimed: this is a HEURISTIC best-arm search.  Its output is a
        stress CONFIGURATION whose worth is established by the downstream hardware campaign's
        statistics (B7; `budget_runs` / het_verdict.h), NOT by this racing rule's confidence.
        The tuner feeds no scientific verdict (separate path from het_verdict; Q7 TRAP 1)."""
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
        self.reason = reason          # "separated" | "budget" | "tied" | "void"


def race(objective, configs, pm, delta=0.05, max_rounds=200, min_rounds=3,
         use_bernoulli=False, schedule="ser3"):
    """Race a set of configs on `objective` and return the winner (or None).

    schedule="ser3"       -- SER^3 (Allesiardo-Feraud): each round, shuffle the SURVIVING
                             arms with the seeded RNG and run ONE bout of each, then
                             eliminate.  Randomized round-robin so any drift hits every
                             arm equally (Q7 5.2 C2) -- the fix for the sequential confound.
    schedule="sequential" -- Kirkham Fig.10's order: run arm A to max_rounds bouts, then B,
                             ...  KEPT so tunecheck.py can demonstrate drift aliasing onto
                             the config axis (the bite that justifies SER^3).  NOT the
                             production path.

    A winner is declared only when the field is reduced to ONE raceable arm AFTER
    min_rounds (so a single lucky early bout cannot crown a constant objective -- the
    anti-phantom guard).  If the budget is spent with >1 arm alive, returns the best mean
    but flags reason="budget"/"tied": NO confident winner, never a phantom."""
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
    # --- SER^3 ---
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
    # Budget spent with the field unresolved: report the leader but DO NOT crown it.
    return RaceResult(best if len(raceable) == 1 else None, arms, rounds,
                      "separated" if len(raceable) == 1 else "budget")


# ===========================================================================
# THE BUDGET MODEL (deliverable #6).  MC-Mutants Alg.1 ceilingRate, = the
# het_verdict.h het_budget_runs formula.  REUSE-AS-LOWER-BOUND: it inherits
# 1-e^{-x}, so it is OPTIMISTIC under overdispersion -- widen by F_hat.
# ===========================================================================
def budget_runs(p_min, F=1.0):
    """Runs needed to bound a should-be-forbidden 'Never' at reproducibility 0.95:
    F * log(0.05) / log(1 - p_min).  Mirror of het_verdict.h het_budget_runs (identical
    arithmetic) and MC-Mutants Alg.1 ceilingRate=ceil(-log(1-r)/b).

    p_min is a SYMBOL, not a number (Q7 R2; het_verdict.h HET_P_MIN=0.0): there is NO
    default -- the GPU-only 0.2% is NOT the het rate.  UNSET p_min => -1.0 ("NOT SIZED"),
    never an invented budget."""
    if not (0.0 < p_min < 1.0):
        return -1.0                                   # NOT SIZED (het_budget_runs contract)
    if not (F > 1.0):
        F = 1.0
    return F * math.log(0.05) / math.log(1.0 - p_min)


# ===========================================================================
# HET_WINDOW CALIBRATION (Q7 TRAP 2).  A MEASUREMENT, not a tuning.  HET_WINDOW is a
# detector-resolution knob; tuning it to maximise its own detections is circular.  It is
# calibrated against the O(N^T_L) exhaustive scan (valid only where
# control_exhaustive_valid==1): the smallest window at which the windowed control count
# CONVERGES to the exhaustive count.  This needs REAL runs (exhaustive vs windowed counts
# come off the device), so on the dev box it returns None -- the value stays the emitter's
# placeholder (top_litmus.ml HET_WINDOW=8).  Provided so B8b can run it; NEVER feeds the
# sampler.
# ===========================================================================
def calibrate_window(samples, tol=0):
    """samples :: iterable of (window, windowed_count, exhaustive_count, exhaustive_valid).
    Returns the smallest window whose windowed_count == exhaustive_count (within tol) on
    every valid sample, or None if no window converges / no valid ground truth exists."""
    by_w = {}
    saw_valid = False
    for w, wc, ec, valid in samples:
        if not valid:
            continue
        saw_valid = True
        by_w.setdefault(w, []).append(abs(wc - ec) <= tol)
    if not saw_valid:
        return None
    for w in sorted(by_w):
        if by_w[w] and all(by_w[w]):
            return w
    return None


# ===========================================================================
# CONFIG FILE I/O (deliverable #8).  Runtime-reparseable key=value, à la cuda-litmus
# parseStressParamsFile.  On the dev box the file carries ONLY the warm-start SEEDS,
# each stamped "not measured here" (acceptance #4: zero tuned numerics committed).
# ===========================================================================
def write_config(path, config_by_sub, target, measured=False):
    lines = []
    lines.append("# HetLitmus stress config for target=%s" % target)
    lines.append("# format: HET_KNOB=value (runtime-reparseable; à la cuda-litmus "
                 "parseStressParamsFile).")
    if not measured:
        lines.append("# *** NOT MEASURED HERE ***  Every value below is a WARM-START SEED,")
        lines.append("# not a tuned number.  The dev box (no CPU-GPU coherence, no C2C) is the")
        lines.append("# WRONG SUBSTRATE (Q7 4.2): it validates the tuning MACHINERY, never a")
        lines.append("# value.  Re-tune on the actual %s hardware (B8b)." % target)
    for sub in SUBSEARCH_ORDER:
        cfg = config_by_sub.get(sub, {})
        if not cfg:
            continue
        lines.append("# --- sub-search %s ---" % sub)
        for knob in sorted(cfg):
            if knob not in whitelisted_knobs():
                raise AssertionError(
                    "refusing to write non-experiment knob %r to the config file "
                    "(TRAP 1: only whitelisted stress knobs are tunable output)" % knob)
            lines.append("%s=%s" % (knob, cfg[knob]))
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def read_config(path):
    """Parse a key=value config file back into {knob: int}.  Rejects any non-whitelisted
    knob (an instrument knob in a 'stress config' is a red flag, not a value to apply)."""
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
                                 "config (TRAP 1/2)" % k)
            if k not in wl:
                raise ValueError("config file carries unknown knob %r" % k)
            out[k] = int(v)
    return out


# ===========================================================================
# THE REAL OBJECTIVE ADAPTER (for B8b).  Applies a config to a harness invocation and
# reads the death rate back from the HetStats line.  On the dev box it is exercised ONLY
# against a STUB runner (tunecheck.py), exactly as campaign.py's scheduler is: the dev box
# cannot produce a real death rate (no coherence, no C2C), so this NEVER runs the emitted
# harness expecting weak behaviours.
#
# BOUNDARY (stated honestly, per the SHARED CHARGE): the emitter's stress knobs are
# compile-time #defines today; the harness does not yet RUNTIME-reparse a stress config
# nor emit a control-count/wall-time death-rate channel.  Wiring those into the emitter is
# the hardware campaign's job (B8b) and is unvalidatable on the dev box.  This adapter
# therefore sets the config as env vars AND writes the file (forward-compatible), times
# the subprocess wall-clock itself, and reads what the CURRENT HetStats line exposes
# (k_eff/usable/R_eff/ks).  Its throughput reading is only as good as the channel B8b adds.
# ===========================================================================
def parse_hetstats(stdout):
    """The last machine-readable 'HetStats <test> key=value...' line (campaign.py contract)."""
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
        got = kv
    return got


def _fnum(kv, key, dflt=0.0):
    try:
        return float(kv.get(key, dflt))
    except (TypeError, ValueError):
        return dflt


class HarnessObjective(object):
    """Runs one bout = one harness invocation with a given stress config applied."""

    def __init__(self, runner, test, cfgdir, seed0=1):
        self.runner = runner
        self.test = test
        self.cfgdir = cfgdir
        self.seed0 = seed0
        self.n = 0

    def bout(self, config, pm):
        env = dict(os.environ)
        # Forward-compatible: set the config as env vars (B8b wires the harness to read
        # them / the config file).  Also a fresh HET_SEED per bout (replaying a seed adds
        # no fresh phase draws -- campaign.py's contract, MUST NOT REMOVE).
        for k, v in config.items():
            env[k] = str(v)
        env["HET_SEED"] = str(self.seed0 + self.n)
        env["HET_ADAPTIVE"] = "1"
        self.n += 1
        cmd = self.runner.replace("{test}", self.test).replace("{dir}", self.cfgdir)
        t0 = time.time()
        r = subprocess.run(shlex.split(cmd) if os.name != "nt" else cmd,
                           env=env, capture_output=True, text=True)
        secs = max(time.time() - t0, 1e-6)
        if r.returncode != 0:
            return Bout(0.0, 1.0, secs=secs, valid=False)
        kv = parse_hetstats(r.stdout)
        if kv is None:
            return Bout(0.0, 1.0, secs=secs, valid=False)
        usable = _fnum(kv, "usable")
        k_eff = _fnum(kv, "k_eff")
        r_eff = _fnum(kv, "R_eff")
        # interleavings/cold: a VOID/COLD obs is not a low rate (Q7 2.3 cold floor).
        obs = kv.get("obs", "")
        valid = usable > 0 and obs not in ("void", "VOID", "")
        ks_ok = kv.get("ks", "pass") == "pass"
        value = (k_eff / usable) if usable > 0 else 0.0
        weight = r_eff if r_eff > 0 else usable
        # kills/secs: the true death-rate numerator needs a control-count channel the
        # current HetStats line does not carry (see BOUNDARY above); k_eff is the best
        # available proxy until B8b adds it.
        return Bout(value, weight, raw_n=usable, secs=secs, kills=k_eff,
                    ks_ok=ks_ok, valid=valid)


# ===========================================================================
# THE FACTORED SEARCH (deliverable #2/top-level).  G, then C, then I (I last,
# warm-started with G*,C* fixed), then a short joint refinement (Q7 3.2/3.3).
# `objective_for(sub, base)` returns the Objective to score sub-search `sub`
# against, with the other sub-searches pinned at `base`.
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
# CLI.  --self-test runs the machinery on a trivial synthetic objective and
# prints a config file's worth of SEEDS (no tuned values) -- the plumbing smoke
# the cram uses.  Real tuning (--runner) is a HARDWARE activity (B8b).
# ===========================================================================
class _TrivialObjective(object):
    """A tiny synthetic objective whose optimum is a known knob setting: reward rises with
    HET_BARRIER_PCT (a stand-in gradient).  For --self-test plumbing only; the real
    validation is tunecheck.py."""
    def __init__(self, knob="HET_BARRIER_PCT"):
        self.knob = knob

    def bout(self, config, pm):
        base = config.get(self.knob, 0) / 100.0
        v = min(max(base + (pm.unit() - 0.5) * 0.02, 0.0), 1.0)
        return Bout(v, weight=8.0, raw_n=8.0, secs=1.0, kills=v * 8.0)


def main():
    ap = argparse.ArgumentParser(description="HetLitmus B8a stress autotuner (machinery).")
    ap.add_argument("--self-test", action="store_true",
                    help="run the search on a trivial synthetic objective (plumbing smoke)")
    ap.add_argument("--target", default="devbox",
                    help="target label for the output file name")
    ap.add_argument("--out", default=None, help="output config file (default stdout)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--runner", default=None,
                    help="HARDWARE ONLY (B8b): command template, {test}/{dir} substituted")
    ap.add_argument("--test", default=None)
    ap.add_argument("--corpus", default=None)
    a = ap.parse_args()

    if a.runner and not a.self_test:
        sys.stderr.write(
            "tune: --runner is a HARDWARE activity (B8b): the dev box has no CPU-GPU "
            "coherence and no C2C, so a real death rate cannot be measured here.  Run the "
            "MACHINERY validation with hetlitmus/verify/tunecheck.py; run --self-test for "
            "plumbing.\n")
        return 2

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
