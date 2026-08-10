#!/usr/bin/env python3
"""HetLitmus -- the STATISTICS gate for het_stats_compute() (het_verdict.h).

het_stats_compute() turns a "Never" into a BOUND, and every part of it can pass
every gate while reporting the same number forever: a Fano factor defaulting to
1 is the rule of three calling itself dispersion-aware, a KS gate that "passes"
without running tested nothing, dead sub-tallies make dispersion fiction.  This
gate therefore drives the REAL emitted header, which cannot drift from a copy:

  1 THE ESTIMATOR  mu_upper(r) = r*(0.05^{-1/r} - 1) and het_tau_ips against
                   their closed forms, both tau clamps, the runs-needed price.
  2 THE AGGREGATE  every statistic re-derived independently in Python to 1e-9;
                   every class, KS outcome, tier and flag REACHABLE.
  3 THE PRODUCER   the emitted recovery scan, lifted out onto planted buffers.
  4 THE CORPUS     every harness carries the post-pass and a decode channel.
  5/6 SCHEDULING   the stop rule and campaign.py, against a stub runner.

Spec: env-research/Q3-stats.md S2.4/R1-R6; impl-briefs/B7{,b,c}-impl-brief.md.

Usage:  statscheck.py [-q]      run the gate
        statscheck.py --bite    prove the gate FAILS when the mechanism breaks
"""

import argparse
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")

# The emitted-corpus census.  DERIVED, not observed-and-pasted:
#   sync = every test with a register (reader) observable   = 411 - the 11
#          store-only 2+2W harnesses                        = 400
#   obs  = every test with a coherence-final [loc] atom     = those 11 + R 53
#          + S 53                                           = 117
# 106 carry both and NONE carries neither, which is what lets the degeneracy guard
# switch channel instead of firing blind, and phase 4 measures all three from the
# emitted corpus.  (Per-sweep derivation: env-research/impl-briefs/Q10b-REPORT.md.)
CENSUS_SYNC, CENSUS_OBS, CENSUS_NEITHER = 400, 117, 0
CENSUS_WINBUMP = 409        # 411 - the 2 `self' canaries (a test cannot control itself)
CENSUS_TESTS = 411

LN20 = -math.log(0.05)      # 2.99573227355399...
R_POISSON = 1e9
KS_C05 = 1.358
# THE PYTHON MIRRORS OF THE HEADER'S KNOBS.  "Must match" is not a check: no fixture
# straddles the THETA_D or TAU_HOT boundary (the decode counts are 0/1/900/5000, the
# control totals 0/500/~1280), so a header change would keep every comparison's truth
# value and desynchronise the mirror in silence.  All four are therefore EMITTED by the
# C driver and compared in phase 1 -- NWIN on the WIN| line, TAU_MIN_SAMPLES on
# MINSAMP|, the rest on MIRROR|.
NWIN = 128                  # must match HET_NWIN (a swept knob, not a constant)
CORROB_RUNS = 2             # must match HET_CORROB_RUNS      (pinned via MIRROR|)
THETA_D = 2                 # must match HET_THETA_DISTINCT   (pinned via MIRROR|)
TAU_HOT = 30                # must match HET_TAU_HOT          (pinned via MIRROR|)
MAX_CELLS = 128             # must match HET_STATS_MAX_CELLS  (pinned via MIRROR|)
TAU_MIN_SAMPLES = 50.0      # must match HET_TAU_MIN_SAMPLES (emcee/Stan's 50*tau)

TOL = 1e-9

# The AR(1) recovery bands (phase 1).  tau_true = (1+rho)/(1-rho); wlen=2048 x 16
# runs.  Wide enough to survive a change of seed rather than tuned to one draw, and
# wide enough to contain the IPS truncation bias on finite windows.
AR1_BANDS = [
    # rho,  tau_true, lo,    hi
    (0.00,   1.00,    1.00,  1.30),
    (0.50,   3.00,    2.30,  3.70),
    (0.90,  19.00,   13.00, 25.00),
    (0.99, 199.00,  140.00, 280.00),
]

# THE RELIABILITY BAND.  At the shipped configuration (R = 10 runs x NWIN = 128) the
# pooled stream is 1,280 samples, so the 50*tau criterion resolves tau up to 25.6 and
# no further.  That is a property of how many runs we did, not of the channel, and it
# relaxes as R grows -- which is what makes TAU_UNRESOLVED a signal, not a veto.
RESOLVABLE_TAU_AT_R10 = 10 * NWIN / TAU_MIN_SAMPLES     # 25.6


# ---------------------------------------------------------------------------
# THE PYTHON REFERENCE: an independent re-derivation from the closed forms, never a
# transcription of the C -- a bug transcribed into both sides would pass the
# differential.
# ---------------------------------------------------------------------------
def py_mu_upper(r):
    if not (r > 0.0):
        return LN20
    if not (r < R_POISSON):
        return LN20
    return r * (0.05 ** (-1.0 / r) - 1.0)


def py_fano(xs):
    """Returns (F, mean, var); F = -1 when it cannot be measured."""
    n = len(xs)
    if n < 2:
        return -1.0, 0.0, 0.0
    m = sum(xs) / float(n)
    v = sum((x - m) ** 2 for x in xs) / float(n - 1)
    if not (m > 0.0):
        return -1.0, m, v
    return v / m, m, v


def py_r_from_fano(mean, F):
    if not (F > 1.0) or not (mean > 0.0):
        return float("inf")
    return mean / (F - 1.0)


def py_tau_ips(win, wlen, mean):
    """Geyer initial-positive-sequence, mirroring het_tau_ips' arithmetic exactly
    (same loop order, biased 1/n autocovariances, within-run lags, exhaustion ->
    cap, clamp to [1, wlen]) so the differential can hold to 1e-9.  The CLOSED-FORM
    anchor is independent (AR1_BANDS): a bug transcribed into both mirrors would
    still fail the closed form."""
    nwin = len(win)
    if wlen < 2 or nwin < wlen:
        return -1.0
    nrun = nwin // wlen
    g0 = 0.0
    for r in range(nrun):
        for w in range(wlen):
            d = win[r * wlen + w] - mean
            g0 += d * d
    g0 /= float(nrun * wlen)
    if not (g0 > 0.0):
        return -1.0
    s = 0.0
    exhausted = True
    m = 0
    while 2 * m < wlen:
        G = 0.0
        for k in (2 * m, 2 * m + 1):
            if k >= wlen:
                continue
            if k == 0:
                G += 1.0
                continue
            g = 0.0
            for r in range(nrun):
                for w in range(wlen - k):
                    g += (win[r * wlen + w] - mean) * (win[r * wlen + w + k] - mean)
            G += (g / float(nrun * wlen)) / g0
        if not (G > 0.0):
            exhausted = False
            break
        s += G
        m += 1
    if exhausted:
        return float(wlen)
    tau = 2.0 * s - 1.0
    return min(max(tau, 1.0), float(wlen))


def py_ks2(a, b):
    """Two-sample KS.  Returns (pass, D, Dcrit); pass=-1 when underpowered."""
    na, nb = len(a), len(b)
    if na < 2 or nb < 2:
        return -1, 0.0, 0.0
    a, b = sorted(a), sorted(b)
    i = j = 0
    D = 0.0
    while i < na and j < nb:
        x = min(a[i], b[j])
        while i < na and a[i] <= x:
            i += 1
        while j < nb and b[j] <= x:
            j += 1
        D = max(D, abs(i / float(na) - j / float(nb)))
    Dcrit = KS_C05 * math.sqrt((na + nb) / float(na * nb))
    return (1 if D <= Dcrit else 0), D, Dcrit


# ---------------------------------------------------------------------------
# SYNTHETIC CELLS.  A cell is one (instance, run).  BASE is a live, hot, credible
# run whose mu(T) fired; each case perturbs a few fields, so each isolates
# exactly one reason.  (Same construction as verdictcheck.py, on purpose.)
# ---------------------------------------------------------------------------
BASE = dict(
    test_name='"synthetic"',
    # The stamp, by SYMBOL: het_verdict() reads no field of a record that does not
    # carry it, so every fixture here has to be a stamped one.
    rec_magic="HET_REC_MAGIC",
    exhaustive_valid=1,
    target_count_exhaustive=0,
    target_count_heuristic=0,
    interleavings_detected=1000,
    control_compiled_in=1,
    canary_compiled_in=1,
    control_target_count=0,          # filled from control_win
    canary_target_count=500,
    control_exhaustive_valid=1,
    canary_exhaustive_valid=1,
    sync_valid=1,
    distinct_decoded_iters=5000,
    skew_stddev=3.5,
    observer_unique_count=0,
    obs_valid=0,
    stress_truncated=0,
    spin_rendezvous=900, spin_cap=100,
    gpu_stress_rounds=64,
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    cpu_aff_failures=0,
    place_failures=0,
    stress_requested=0x3F,
    N=100000,
    frames_examined=100000,
    run_id=0,
    nwin=NWIN,        # the REALISED window resolution rides in the record
)

# ---------------------------------------------------------------------------
# THE SYNTHETIC WINDOW STREAMS.  Each RUN gets its OWN stream, because real runs do:
# ten copies of one hand-picked stream is one sample counted ten times, which drives
# the across-cell Fano to 0 and makes the KS over-sensitive on the collapsed ECDF.
# The RNG is a hand-rolled LCG rather than `random' or numpy so the fixtures -- and
# therefore the reference numbers -- are identical on every machine and Python.
# ---------------------------------------------------------------------------
class _Rng:
    def __init__(self, seed):
        self.s = seed & 0x7FFFFFFF

    def u(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / float(0x7FFFFFFF)


def _poisson(rng, lam):
    """Knuth.  Var == Mean, so F -> 1 -- the regime the rule of three assumes."""
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.u()
        if p <= L:
            return k
        k += 1


def poisson_stream(rng, lam=10.0):
    return [_poisson(rng, lam) for _ in range(NWIN)]


def bursty_stream(rng, lam=10.0, nb=16, span=4):
    """The SAME mean rate delivered in BURSTS: a productive CPU/GPU alignment window
    emits many sightings, then a long dry spell (Q1-alignment.md S2(e); PerpLE Fig.12).
    This is the overdispersed regime Q3-stats.md S2.4 predicts on real C2C, and the
    one whose measured Fano must widen mu_upper past the Poisson 2.996.

    A burst is a TIME INTERVAL, so it spans `span` consecutive windows.  A
    single-bucket burst is a fixture artefact: at a fine HET_NWIN it concentrates the
    marginal (F_win explodes, r_hat -> 0) instead of doing what a real burst does
    under refinement, which is raise the window-to-window correlation.  Spanned bursts
    keep the two instruments factored -- multiplicity in F_win (the numerator),
    adjacency in tau_w (the denominator)."""
    w = [0] * NWIN
    for _ in range(nb):
        start = int(rng.u() * NWIN) % NWIN
        for j in range(span):
            w[(start + j) % NWIN] += _poisson(rng, lam * NWIN / (nb * span))
    return w


def drift_stream(rng, lo=2.0, hi=40.0):
    """A rate that CHANGES mid-run -- Kirkham's Vega-LB rate jump at ~7M iterations
    (Q3-stats.md S2.2).  The KS gate must REJECT this."""
    return ([_poisson(rng, lo) for _ in range(NWIN // 2)]
            + [_poisson(rng, hi) for _ in range(NWIN // 2)])


def ramp_cells(nrun=10):
    """THE TAU-AT-CAP REGIME: every window of run r carries the same count and only
    the level differs across runs, i.e. an alignment regime that outlives the run.
    Nothing decorrelates in view, so relative to the global mean every lag's products
    stay positive, the IPS never finds a non-positive pair, and tau saturates at the
    ceiling.  One run is then one alignment draw: N_eff = 1, and the bound must
    collapse to the run-level one exactly (B7b-impl-brief.md, the honest failure
    mode)."""
    return [[5 * (r + 1)] * NWIN for r in range(nrun)]


def cox_cells(rng, nrun=10, rho=0.99, mu=10.0, s=10.0):
    """THE FIXTURE THE RELIABILITY GUARD NEEDS: a Cox process (doubly-stochastic
    Poisson) -- a latent AR(1) RATE that drifts, sampled by COUNTING, which is what a
    control stream physically is.  The bare AR(1) of phase 1 cannot show the failure
    it guards: noiseless, it never decorrelates in view, the estimator exhausts and
    TAU_AT_CAP correctly fires.  Add counting noise and the Geyer sum meets a SPURIOUS
    non-positive pair early, truncates, and returns a tau far below both the truth and
    the cap -- so nothing is flagged and the under-read tau OVER-credits N_eff
    (B7c-impl-brief.md).

    It is still an exact instrument: with latent ACF rho^k and Poisson counting on top
    the counting noise is white, lands entirely at lag 0 and simply scales the ACF, so
        ACF_k = lam * rho^k,   lam = var_rate / (mean + var_rate)      (k >= 1)
        tau   = 1 + 2 * lam * rho / (1 - rho)
    -- and the estimator either recovers it or it does not."""
    sd = math.sqrt(1.0 / 12.0) / math.sqrt(1.0 - rho * rho)   # sd of the latent AR(1)
    out = []
    for _ in range(nrun):
        x, w = 0.0, []
        for _i in range(200):                      # burn-in to stationarity
            x = rho * x + (rng.u() - 0.5)
        for _i in range(NWIN):
            x = rho * x + (rng.u() - 0.5)
            rate = mu + s * x / sd
            w.append(_poisson(rng, rate if rate > 0.01 else 0.01))
        out.append(w)
    return out


def cox_tau(rho, mu=10.0, s=10.0):
    """The closed form the fixture above is pinned against."""
    lam = (s * s) / (mu + s * s)
    return 1.0 + 2.0 * lam * rho / (1.0 - rho)


def negacf_cells(rng, nrun=10, rho=-0.6):
    """An ANTI-correlated count stream: AR(1) with rho < 0 rounded to counts, so
    true tau = (1+rho)/(1-rho) = 0.25 < 1.  The floor must clamp it to 1 and N_eff
    land EXACTLY at NWIN -- a stream of NWIN windows can never claim more than NWIN
    independent samples.  An AR(1) and not a bare alternator: an exactly-periodic
    phase-locked fixture has pair sums +1/n at every lag, an artefact no counts
    process produces, which reads as never-decorrelating and caps instead."""
    out = []
    for _ in range(nrun):
        x, w = 0.0, []
        for _i in range(20):
            x = rho * x + (rng.u() - 0.5)          # burn-in
        for _i in range(NWIN):
            x = rho * x + (rng.u() - 0.5)
            w.append(max(0, int(round(10.0 + 8.0 * x))))
        out.append(w)
    return out


_R = _Rng(20260714)
POISSON_CELLS = [poisson_stream(_R) for _ in range(10)]
BURSTY_CELLS = [bursty_stream(_R) for _ in range(10)]
DRIFT_CELLS = [drift_stream(_R) for _ in range(10)]
FLAT_CELLS = [[10] * NWIN for _ in range(10)]     # F = 0: must clamp UP to Poisson
ZERO_CELLS = [[0] * NWIN for _ in range(10)]
RAMP_CELLS = ramp_cells()
NEGACF_CELLS = negacf_cells(_R)

# THE TWO SIDES OF THE RELIABILITY THRESHOLD, both on correlated count streams with
# an exact closed-form tau, because a guard that always fires is as dead as one that
# never does.  Both must be reachable at the SHIPPED R = 10 (1,280 pooled samples):
#   COX_SLOW  rho=0.99 -> tau_true 181, estimated ~54, needing 2,690 -> UNRESOLVED,
#             N_eff falls back to 1.  Believed, that tau would credit N_eff = 2.4,
#             and it sits well below the 128 cap so TAU_AT_CAP cannot catch it.
#   COX_FAST  rho=0.90 -> tau_true 17.4, estimated ~10, needing 513 -> RESOLVED, and
#             N_eff ~ 12.5 is CLAIMED: the guard has not just pinned N_eff at 1.
COX_SLOW_RHO, COX_FAST_RHO = 0.99, 0.90
COX_SLOW_CELLS = cox_cells(_Rng(20260714), 10, COX_SLOW_RHO)
COX_FAST_CELLS = cox_cells(_Rng(20260714), 10, COX_FAST_RHO)
# THE SELF-REFERENTIAL ESCAPE -- known-open, disclosed and fenced, not fixed
# (decisions/F8-decision.md, Path 1).  The guard scales its threshold by the ESTIMATED
# tau, so a stream whose tau the Geyer sum under-reads hard enough that 50*tau_est
# drops below the pooled nwin slips past it and credits N_eff off an estimate that
# vouches for itself.  Lower mu/s than COX_SLOW make the counting noise heavier
# relative to the drift, so tau_est comes back ~16.8 against tau_true 85.9 and N_eff
# is credited 7.6 where the honest reading is 1.49.  It is SEED-SENSITIVE (17 ->
# ~5.1x; 20260714 -> ~3.6x; 42 -> the guard fires and there is no escape), so the
# witness asserts its OWN escape-precondition: a fixture that has drifted out of the
# regime it demonstrates must fail loudly rather than pass vacuously.
COX_ESCAPE_SEED = 17
COX_ESCAPE_RHO, COX_ESCAPE_MU, COX_ESCAPE_S = 0.99, 3.0, 1.5
COX_ESCAPE_CELLS = cox_cells(_Rng(COX_ESCAPE_SEED), 10,
                             COX_ESCAPE_RHO, COX_ESCAPE_MU, COX_ESCAPE_S)
COX_ESCAPE_TAU_TRUE = cox_tau(COX_ESCAPE_RHO, COX_ESCAPE_MU, COX_ESCAPE_S)   # 85.857
F8_ESCAPE_CASE = "f8-escape-guard-passes-over-credits"
F8_NEFF_EXPECT = 7.63        # NWIN/tau_est at seed 17: the current ~5.1x over-credit, pinned
# TAU AT THE CAP, RESOLVED.  "The regime outlives the run" is itself a claim about
# tau and needs the same 50*tau evidence as any other: a tau at the 128-window ceiling
# needs 6,400 pooled samples = 50 usable runs before it may be BELIEVED to be there.
# At R = 10 the honest reading of a ramp is UNRESOLVED, so the at-cap case runs 64
# cells or TAU_AT_CAP is unreachable at every R the campaign runs.  The two flags
# prescribe different remedies -- AT_CAP raise HET_NWIN, UNRESOLVED raise R.
RAMP_CELLS_RESOLVED = ramp_cells(64)
# 100 runs of the same Poisson channel.  The bound MUST tighten with R -- if it does
# not, R_eff is not in the formula and the "bound" is a constant wearing a fraction.
POISSON_CELLS_100 = [poisson_stream(_R) for _ in range(100)]
# ONE RECORD MORE THAN THE AGGREGATE CAN HOLD.  het_stats_compute clamps its record
# array at HET_STATS_MAX_CELLS and the tail is dropped from every statistic; the field
# is producible (hetEmit sizes _recs[NUMBER_OF_RUN] from Cfg.runs, so litmus7 -r above
# 128 hands it more than it can hold), and the ONLY thing that says the bound was
# computed from fewer runs than were executed is HET_ST_CELLS_TRUNCATED.  Its own RNG,
# so adding it cannot shift the draws every earlier fixture is pinned on.
_R_TRUNC = _Rng(20260801)
POISSON_CELLS_TRUNC = [poisson_stream(_R_TRUNC) for _ in range(MAX_CELLS + 1)]


def _spread(total):
    """A window array summing EXACTLY to total, so the sum==total invariant holds on the
    channel a case is NOT exercising (an accidental desync there would mask the real
    signal)."""
    w = [total // NWIN] * NWIN
    for i in range(total % NWIN):
        w[i] += 1
    return w


def cell(win, chan="control", **kw):
    r = dict(BASE)
    r.update(kw)
    wk, tk = chan + "_win", chan + "_target_count"
    if wk not in kw:
        r[wk] = list(win)
    if tk not in kw:
        r[tk] = sum(r[wk])
    other = "canary" if chan == "control" else "control"
    if (other + "_win") not in kw:
        r[other + "_win"] = _spread(r.get(other + "_target_count", 0))
    return r


def stream(cells_, chan="control", **kw):
    """One record per run, each with its OWN window stream."""
    return [cell(w, chan=chan, run_id=i, **kw) for i, w in enumerate(cells_)]


def stream_runs(cells_, run_ids, chan="control", **kw):
    """stream() with EXPLICIT run ids, so a fixture can put SEVERAL cells in ONE run.
    stream() numbers its cells 0, 1, 2, ..., which makes k_runs identically k_eff and
    leaves het_stats_compute's run-dedup loop -- and with it the corroboration tier's
    "distinct RUNS, not merely distinct cells" rule -- unexercised.  Today's emitter
    does write one record per run, so this is the multi-record-per-run layout the tier
    rule is WRITTEN for, driven before the emitter grows one."""
    if len(run_ids) != len(cells_):
        raise SystemExit("statscheck: stream_runs got %d run ids for %d cells"
                         % (len(run_ids), len(cells_)))
    return [cell(w, chan=chan, run_id=r, **kw)
            for w, r in zip(cells_, run_ids)]


def observed(cells_, k, clean=True, obs_degen=False):
    """Make the first k cells SEE the target (optionally in a degenerate decode).
       obs_degen degrades the OBSERVER channel on the SIGHTING cells only (a real
       ws-edge needs >=2 distinct GPU store-values, so observer_unique_count=1 on a
       sighting IS the constant-read artefact), leaving the background nulls live."""
    for i in range(k):
        cells_[i]["target_count_exhaustive"] = 7
        cells_[i]["target_count_heuristic"] = 7
        if not clean:
            cells_[i]["distinct_decoded_iters"] = 1     # the constant-read artefact
            cells_[i]["skew_stddev"] = 0.0
        if obs_degen:
            cells_[i]["observer_unique_count"] = 1      # observer-channel constant-read
    return cells_


CASES = []


def case(name, cells_, **want):
    CASES.append(dict(name=name, cells=cells_, want=want))


# ============================ THE CASE SET =================================
# --- NEVER, with a measured dispersion: the thesis's validation claim -------
case("never-poisson", stream(POISSON_CELLS),
     obs="Never", ks="pass", flags_none=["BURSTY", "FANO_UNMEASURED"])

# THE BOUND IS NOT A CONSTANT.  Same null, same effort, same mean rate -- only the
# ARRIVAL PATTERN differs -- so the numerator must widen materially, or the
# "dispersion-aware" bound is the textbook rule of three in a hat and every
# non-observation is overclaimed ~6x (Q3-stats.md S2.4).
# The bursts are heavy but WINDOW-LOCAL (adjacent windows are nearly independent), so
# tau_w ~ 1 and each run still carries ~NWIN effective samples: the penalty (a wide
# mu_upper) is paid and the dividend (N_eff) is collected, and ten runs bound
# something on a channel where one bit per run would not.
case("never-bursty", stream(BURSTY_CELLS),
     obs="Never", flags_any=["BURSTY"],
     flags_none=["FANO_UNMEASURED", "BOUND_VACUOUS", "TAU_UNMEASURED"])

# THE BOUND MUST SCALE WITH R: same channel, 10x the runs, ~10x tighter.  A hardcoded
# R_eff would leave it unchanged.  Q3-stats.md F4 in one case -- the remedy for a weak
# null is more RUNS, not a bigger N.
case("bound-tightens-with-R", stream(POISSON_CELLS_100),
     obs="Never", flags_none=["FANO_UNMEASURED", "BOUND_VACUOUS"])

# Under-dispersion (F<1) must clamp UP to the Poisson floor, never tighten below it.
# (A flat stream also has zero variance in time, so tau is unmeasurable there and
# N_eff stays 1 -- the same one-directional rule on the other axis.)
case("never-underdispersed-clamps-to-poisson", stream(FLAT_CELLS),
     obs="Never", flags_any=["UNDERDISPERSED", "TAU_UNMEASURED"], mu_upper=LN20,
     N_eff=1.0)

# --- THE TWO ENDS OF THE N_eff SCALE ----------------------------------------
# TAU AT THE CAP, and THE CONTAINMENT CASE.  The alignment regime outlives the run, so
# the stream never decorrelates in view: tau_w saturates at HET_NWIN, N_eff = 1, and
# the bound must equal the run-level number EXACTLY (phase 2 pins p_bound ==
# mu_upper / (R_usable / DEFF) to 1e-9).  A correct N_eff implementation CONTAINS that
# conservative special case.  The across-run spread also blows up F_cell here, which
# is what keeps BOUND_VACUOUS reachable.  64 cells, not 10: see RAMP_CELLS_RESOLVED.
case("never-tau-at-cap-is-B7-exactly", stream(RAMP_CELLS_RESOLVED),
     obs="Never", flags_any=["TAU_AT_CAP", "BOUND_VACUOUS"],
     flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED", "TAU_UNRESOLVED"],
     tau_w=float(NWIN), N_eff=1.0, tau_need=int(TAU_MIN_SAMPLES))

# --- THE RELIABILITY GUARD, BOTH DIRECTIONS ---------------------------------
# THE OVERCLAIM CASE.  A slow-drifting control rate sampled by counting: tau_true is
# 181, the Geyer sum truncates early and returns ~54, and 54 is BELOW the 128 cap so
# TAU_AT_CAP cannot catch it.  Believed, it would credit N_eff = 2.4 and report a
# bound 2.4x tighter than the truth -- in exactly the slow-skew-drift regime we most
# expect on real C2C, where the conservative run-level reading is right.  1,280 pooled
# samples cannot resolve tau = 54, so the guard must FIRE, N_eff fall back to 1, and
# the bound be the run-level one exactly.
case("never-tau-unresolved-falls-back-to-B7", stream(COX_SLOW_CELLS),
     obs="Never", flags_any=["TAU_UNRESOLVED"],
     flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED", "TAU_AT_CAP"],
     N_eff=1.0)

# ... AND THE GUARD IS NOT A CONSTANT EITHER: one that always fires would discard the
# N_eff dividend on every channel.  Same channel, same counting noise, faster
# decorrelation (tau_true 17.4, estimated ~10, needing 513 of the 1,280 samples we
# have), so the guard must stay SILENT and N_eff (~12.5) must be CLAIMED.
case("never-tau-resolved-still-claims-Neff", stream(COX_FAST_CELLS),
     obs="Never", flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED", "TAU_AT_CAP",
                              "TAU_UNRESOLVED"])

# THE KNOWN-OPEN ESCAPE WITNESS (COX_ESCAPE_CELLS above; decisions/F8-decision.md).
# The guard PASSES here (tau_need 7 <= R_usable 10) and credits N_eff off a tau it
# cannot resolve.  This case pins only what phase 2 can see without the closed form:
# neither reliability flag fires, so neither can catch it.  The quantitative claims
# live in check_f8_escape_witness.  BOUND_VACUOUS also fires here (a heavy-F_cell null
# bounds nothing); that is incidental and deliberately unconstrained.
case(F8_ESCAPE_CASE, stream(COX_ESCAPE_CELLS),
     obs="Never",
     flags_none=["TAU_UNRESOLVED", "TAU_AT_CAP", "TAU_UNMEASURED", "FANO_UNMEASURED"])

# THE FLOOR / CEILING CLAMP: an anti-correlated stream has raw tau < 1, which would
# credit more independent samples than the stream has windows.  tau clamps to 1 and
# N_eff to EXACTLY NWIN, never above.
case("never-neg-acf-clamps-Neff-to-NWIN", stream(NEGACF_CELLS),
     obs="Never", flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED", "TAU_AT_CAP"],
     tau_w=1.0, N_eff=float(NWIN))

# --- STATIONARITY ----------------------------------------------------------
# A control rate that CHANGES mid-run.  KS must REJECT and P_rep be suppressed even
# though the target WAS seen: P_rep is never reported across a non-stationary boundary
# (Q3-stats.md S2.2, R4 -- the KS precheck is mandatory because Kirkham's own data
# already fails it 4/18 GPU-only).  The stream rides the CANARY channel, because an
# oracle-Allowed test has no mu(T) by construction.
case("ks-split-rejects-and-suppresses-Prep",
     observed(stream(DRIFT_CELLS, chan="canary",                      control_compiled_in=0, control_target_count=0), 4),
     obs="Sometimes", ks="SPLIT", flags_any=["NONSTATIONARY"], P_rep=-1.0)

# --- OBSERVED: P_rep at the (instance,run) unit, from k_eff -----------------
case("sometimes-Prep-from-cells-not-frames",
     observed(stream(POISSON_CELLS), 3),
     obs="Sometimes", ks="pass", P_rep=1.0 - math.exp(-3.0), k=3, k_eff=3)

case("always", observed(stream(POISSON_CELLS), 10),
     obs="Always", k=10)

# --- VOID: a dead harness bounds nothing -----------------------------------
case("void-when-every-cell-is-cold",
     stream(ZERO_CELLS, canary_target_count=0),
     obs="VOID", p_bound=-1.0, flags_any=["FANO_UNMEASURED", "KS_UNDERPOWERED"])

# --- THE DEGENERACY GUARD ---------------------------------------------------
# Seen in 3 cells, but every decode was CONSTANT -- the reader-stuck-on-one-value
# artefact Srivastava S4.1 observed (Q3-stats.md S3.1).  k=3 but k_eff=0, so it cannot
# corroborate; it is still REPORTED, and P_rep is NOT REPORTED (-1) rather than the
# 1-e^0 = 0 that would read as "never reproduces".
case("degenerate-sightings-rejected-but-reported",
     observed(stream(POISSON_CELLS), 3, clean=False),
     obs="Sometimes", k=3, k_eff=0, n_degen=3, P_rep=-1.0,
     flags_any=["DEGEN_SIGHTING"], tier="UNCONFIRMED")

# The 11 store-only (2+2W) tests decode through the OBSERVER, not a synchrony read, so
# reading skew_stddev on them would call every cell degenerate forever.  Both arms of
# the channel switch must be live:
case("observer-channel-clean",
     observed(stream(POISSON_CELLS,                      sync_valid=0, obs_valid=1, observer_unique_count=900,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     obs="Sometimes", k=3, k_eff=3, flags_none=["DEGEN_SIGHTING"])

# ... and the degenerate arm.  The degeneracy sits on the SIGHTINGS (unique_count=1),
# where it physically belongs: a cold observer on a non-sighting null COLD-INVALIDs
# that cell instead, so the 7 background nulls stay usable and the classification
# stays honestly "Sometimes" with all 3 sightings degenerate.
case("observer-channel-degenerate",
     observed(stream(POISSON_CELLS,                      sync_valid=0, obs_valid=1, observer_unique_count=900,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3, obs_degen=True),
     obs="Sometimes", k=3, k_eff=0, flags_any=["DEGEN_SIGHTING"])

# No decode channel at all: FAIL CLOSED (0 of 411 today -- reaching it is a build bug).
case("no-decode-channel-fails-closed",
     observed(stream(POISSON_CELLS, sync_valid=0, obs_valid=0,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     k=3, k_eff=0, flags_any=["NO_DECODE_CHANNEL", "DEGEN_SIGHTING"])

# --- THE CORROBORATION TIER (HET_CORROB_RUNS distinct clean RUNS) -----------
# The bar is on RUNS and the boundary is at HET_CORROB_RUNS exactly, so both sides
# of it are driven: one run short is UNCONFIRMED, one run over is CORROBORATED.
case("sighting-corroborated-at-the-bar",
     observed(stream(POISSON_CELLS), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS)

case("sighting-unconfirmed-one-run-short",
     observed(stream(POISSON_CELLS), CORROB_RUNS - 1),
     obs="Sometimes", tier="UNCONFIRMED", k_runs=CORROB_RUNS - 1)

# ... AND THE RULE IS ABOUT RUNS, NOT CELLS.  Three clean sightings that all landed in
# the SAME run: runs are re-seeded and carry a fresh phase/thermal draw, three cells of
# one run do not, so this must stay UNCONFIRMED where the case above it is
# CORROBORATED.  The only fixture where k_runs < k_eff, and therefore the only one that
# runs het_stats_compute's run-dedup loop at all.
case("sighting-unconfirmed-3-cells-of-ONE-run",
     observed(stream_runs(POISSON_CELLS, [0, 0, 0] + list(range(1, 8))), 3),
     obs="Sometimes", k=3, k_eff=3, k_runs=1, tier="UNCONFIRMED")

# ... and n_at_first_sight is the PRICE in runs, so it must be the run the first
# clean sighting landed in and not the count of sightings.  Here the first three
# runs are null and run 3 (the fourth) fires.
case("first-sight-is-priced-in-runs",
     observed(stream_runs(POISSON_CELLS, [3, 4, 0, 1, 2, 5, 6, 7, 8, 9]), 1),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=1)

# --- THE SELF-PROVING INVARIANT --------------------------------------------
# The window bump sits on the same line as the count, so sum(win) == total.  A total
# that is nonzero with all windows zero means the bump did not run, and that must VOID
# the dispersion rather than fall back to Poisson.
case("window-desync-voids-the-bound",
     stream(ZERO_CELLS, control_target_count=500),
     obs="Never", p_bound=-1.0, flags_any=["WIN_DESYNC", "FANO_UNMEASURED"])

# --- CALIBRATION PROVENANCE ------------------------------------------------
# 361 of 411 have no mu(T) by construction, so their dispersion is calibrated from the
# Layer-B canary -- a DIFFERENT shape's burstiness, hence a weaker claim, hence a flag.
case("canary-calibrated-when-no-mutant",
     stream(POISSON_CELLS, chan="canary",             control_compiled_in=0, control_target_count=0),
     obs="Never", flags_any=["CTRL_IS_CANARY"], flags_none=["FANO_UNMEASURED"])

# --- THE SELF-CANARY SELECTION EFFECT ---------------------------------------
# MP-{cg,gc}-sys-relaxed ARE the Layer-B canary, so they co-run no control and a run in
# which they did not fire is COLD and discarded: "usable" is then DEFINED BY firing and
# the survivors are tautologically the ones that fired.  Classifying over usable cells
# would report ALWAYS for a canary that fired in 3 runs of 10 -- and that rate is what
# the rest of the campaign is calibrated against -- so the denominator must be R.  They
# also get NO BOUND: there is nothing independent to calibrate dispersion against.
case("self-canary-fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(ZERO_CELLS,                      canary_name='"synthetic"',
                     control_compiled_in=0, canary_compiled_in=0,
                     control_target_count=0, canary_target_count=0), 3),
     obs="Sometimes", k=3, k_eff=3, R_usable=3,
     flags_any=["SELF_CONTROL", "FANO_UNMEASURED", "KS_UNDERPOWERED"],
     flags_none=["NO_CONTROL_CORUN"],
     P_rep=-1.0, p_bound=-1.0)

# --- ... AND THE ROW THAT CO-RUNS NOTHING WITHOUT BEING THE CANARY -------------
# Every harness of a pair REGISTERED WITHOUT AN ORACLE looks like this: no control
# map was read, so nothing co-runs AND nothing names this row the canary
# (canary_name is NULL, not the test's own name).  The arithmetic is the self-canary
# one -- "usable" is still defined by firing, so the denominator is still R -- but
# the CLAIM is not: this row is no canary, and its missing bound is an omission we
# have not closed rather than a property of the design.  Two flags, so the printout
# can say which.
case("no-control-map-fired-3-of-10-is-SOMETIMES-and-is-NOT-the-canary",
     observed(stream(ZERO_CELLS,                      control_compiled_in=0, canary_compiled_in=0,
                     control_target_count=0, canary_target_count=0), 3),
     obs="Sometimes", k=3, k_eff=3, R_usable=3,
     flags_any=["NO_CONTROL_CORUN", "FANO_UNMEASURED", "KS_UNDERPOWERED"],
     flags_none=["SELF_CONTROL"],
     P_rep=-1.0, p_bound=-1.0)

# --- ALLOWED / NO-ORACLE nulls still get a bound (a different CLAIM, same maths) ---
case("allowed-unobserved-gets-an-observability-bound",
     stream(POISSON_CELLS),
     obs="Never", flags_none=["FANO_UNMEASURED"])
case("no-oracle-unobserved-gets-a-characterization-bound",
     stream(POISSON_CELLS),
     obs="Never", flags_none=["FANO_UNMEASURED"])

# --- MORE RUNS THAN THE AGGREGATE CAN HOLD ----------------------------------
# The tail beyond HET_STATS_MAX_CELLS is DROPPED from every statistic (R_usable = 128
# of the 129 supplied), which would quietly bound a campaign on less effort than it
# spent -- so st->R keeps the PRE-clamp count and the flag says the discard happened.
# Production runs at R = 10 per invocation, but campaign.py pools invocations and
# litmus7 -r is an operator knob, so this is reachable in the field and reached here.
case("cells-truncated-above-HET_STATS_MAX_CELLS", stream(POISSON_CELLS_TRUNC),
     obs="Never", R=MAX_CELLS + 1, R_usable=MAX_CELLS,
     flags_any=["CELLS_TRUNCATED"])


# ===================== PHASE 5a: THE STOPPING RULE ==========================
# het_campaign_should_stop() decides where the hardware hours go, so every reason it
# can give must be REACHABLE, and two guards must hold: a LONE clean sighting
# escalates rather than stopping (an uncorroborated sighting is not banked), and a
# degenerate-only sighting never de-schedules a row at all.
# The confirmation window and the rate mode are NOT here yet (A4 owns them), so the
# matrix below is the interim one: corroborate, meet the bound, or spend the budget.
STOPS = []


def stop(name, cells_, budget, p_goal, want):
    STOPS.append(dict(name=name, cells=cells_, budget=budget, p_goal=p_goal,
                      want=want))


# A LONE clean sighting does NOT stop: one run cannot rule out a per-run artefact,
# so the row keeps running to corroborate.
stop("one-clean-sighting-does-not-stop",
     observed(stream(POISSON_CELLS), 1),
     20, -1.0, "CONTINUE")
# ... and neither does a degenerate one, at any count: an artefact must never
# de-schedule a test (the tier is computed from k_eff's runs, not from k).
stop("degenerate-sightings-never-stop",
     observed(stream(POISSON_CELLS), 3, clean=False),
     20, -1.0, "CONTINUE")
# The bar is HET_CORROB_RUNS distinct clean RUNS, and it is reached exactly there.
stop("sighting-corroborated-stops",
     observed(stream(POISSON_CELLS), CORROB_RUNS),
     20, -1.0, "CONFIRMED")
stop("cold-row-runs-to-budget",
     stream(POISSON_CELLS),
     10, -1.0, "BUDGET")
stop("null-stops-at-p-goal",
     stream(POISSON_CELLS),
     20, 0.05, "BOUND-MET")
stop("null-without-a-goal-runs-to-budget",
     stream(POISSON_CELLS),
     10, -1.0, "BUDGET")
# A VACUOUS bound must not satisfy ANY goal -- even an absurdly generous one.
stop("vacuous-bound-never-meets-a-goal",
     stream(RAMP_CELLS),
     20, 1e6, "CONTINUE")
# An UNSTAMPED record earns no early stop: every cell is COLD-INVALID, so there is
# no bound to meet and nothing to corroborate, and the row spends its budget.
stop("unstamped-records-fail-closed-to-budget",
     stream(POISSON_CELLS, rec_magic=0),
     10, 0.05, "BUDGET")
# ... and the same holds when the unstamped stream is FULL OF SIGHTINGS in distinct
# runs.  Every count below rec_magic is then memset residue, so scoring it would let
# a harness the emitter built wrong corroborate itself into CONFIRMED -- the one
# stop that means "nothing further is bought by running this row".
stop("unstamped-sightings-earn-no-corroboration",
     observed(stream(POISSON_CELLS, rec_magic=0), CORROB_RUNS),
     10, 0.05, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(cells_):
    # The record array is CLAMPED at HET_STATS_MAX_CELLS and the tail is dropped from
    # every statistic below; st->R keeps the pre-clamp count so the discard is visible.
    R = len(cells_)
    cells_ = cells_[:MAX_CELLS]
    n = len(cells_)
    mu_present = any(c["control_compiled_in"] for c in cells_)
    mu_total = sum(c["control_target_count"] for c in cells_)
    use_canary = 0 if (mu_present and mu_total > 0) else 1

    def ctrl_total(c):
        return c["canary_target_count"] if use_canary else c["control_target_count"]

    def ctrl_win(c):
        return c.get("canary_win", [0] * NWIN) if use_canary else c["control_win"]

    def degenerate(c):
        if c["sync_valid"]:
            return (c["distinct_decoded_iters"] < THETA_D) or (c["skew_stddev"] == 0.0)
        if c["obs_valid"]:
            return c["observer_unique_count"] < THETA_D
        return True

    def channel_live(c):
        # Mirrors het_verdict()'s channel-aware liveness disqualifier: the sync
        # channel's evidence is interleavings_detected>0, the observer channel's is
        # observer_unique_count>=THETA_D, and a record with NEITHER fails closed
        # (0 of 411 in the shipped corpus).
        if c["sync_valid"]:
            return c["interleavings_detected"] > 0
        if c["obs_valid"]:
            return c["observer_unique_count"] >= THETA_D
        return False

    def usable(c):
        # Mirrors het_verdict()'s COLD-INVALID: a sighting is never cold; otherwise the
        # harness must be hot (mu(T) or canary >= tau) AND its decode channel live.
        if c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0:
            return True
        hot_c = c["control_compiled_in"] and c["control_target_count"] >= TAU_HOT
        hot_k = c["canary_compiled_in"] and c["canary_target_count"] >= TAU_HOT
        return bool((hot_c or hot_k) and channel_live(c))

    k = k_eff = n_degen = R_usable = first_sight = 0
    runs, allruns, win, cellv = [], [], [], []
    desync = False
    for c in cells_:
        u = usable(c)
        if u:
            R_usable += 1
        y = c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0
        # Runs consumed so far, over EVERY cell: first_sight is a price in runs.
        if c["run_id"] not in allruns:
            allruns.append(c["run_id"])
        if y:
            k += 1
            if degenerate(c):
                n_degen += 1
            else:
                k_eff += 1
                if c["run_id"] not in runs:
                    runs.append(c["run_id"])
                if first_sight == 0:
                    first_sight = len(allruns)
        if sum(ctrl_win(c)) != ctrl_total(c):
            desync = True
        if u:
            cellv.append(float(ctrl_total(c)))
            win.extend(float(x) for x in ctrl_win(c))

    # THE SELECTION EFFECT: wherever nothing co-runs, "usable" is defined by firing,
    # so the denominator is R and not R_usable.  That holds for the `self' canary rows
    # and for every harness of a pair with no control map alike -- the C splits them
    # into two FLAGS, because only one of them is a canary, but not into two
    # denominators (see the two cases of those names).
    nothing_coruns = not any(c["control_compiled_in"] or c["canary_compiled_in"]
                             for c in cells_)
    denom = R if nothing_coruns else R_usable    # st->R, i.e. PRE-clamp, as in the C
    if R_usable == 0:
        obs = "VOID"
    elif k == 0:
        obs = "Never"
    elif k >= denom:
        obs = "Always"
    else:
        obs = "Sometimes"

    F_win, mean, var = py_fano(win)
    F_cell, _, _ = py_fano(cellv)
    unmeasured = (F_win < 0.0) or desync
    r_hat = float("inf") if unmeasured else py_r_from_fano(mean, F_win)

    # tau on the same stream's temporal axis; N_eff = NWIN/tau in [1, NWIN].  An
    # unmeasurable tau -- and a tau the stream is TOO SHORT TO RESOLVE -- leaves
    # N_eff = 1, i.e. each run is one trial, the conservative run-level reading.  The
    # reliability criterion (Foreman-Mackey: do not trust tau without >= 50*tau
    # samples) applies to the POOLED count, so it relaxes as runs accumulate; tau_w is
    # still REPORTED when unresolved, it just may not be SPENT.
    tau_w, N_eff, tau_need, unresolved = -1.0, 1.0, 0, False
    if not unmeasured:
        tau_w = py_tau_ips(win, NWIN, mean)
        if tau_w > 0.0:
            tau_need = int(math.ceil(TAU_MIN_SAMPLES * tau_w / NWIN))
            if len(win) < TAU_MIN_SAMPLES * tau_w:
                unresolved = True                 # N_eff stays 1: the run-level read
            else:
                N_eff = min(max(NWIN / tau_w, 1.0), float(NWIN))

    n_early = max(1, (NWIN * 20) // 100)
    n_late = max(1, (NWIN * 10) // 100)
    early, late = [], []
    for i in range(0, len(win) - NWIN + 1, NWIN):
        early.extend(win[i:i + n_early])
        late.extend(win[i + NWIN - n_late:i + NWIN])
    if unmeasured:
        ks, D, Dcrit = -1, 0.0, 0.0
    else:
        ks, D, Dcrit = py_ks2(early, late)

    P_rep = -1.0
    # k_eff > 0 is load-bearing: 1 - e^0 = 0 prints as "P_rep = 0.00%", which reads as
    # "never reproduces" when it means "no clean cell to estimate from".
    if obs in ("Sometimes", "Always") and ks == 1 and k_eff > 0:
        P_rep = 1.0 - math.exp(-float(k_eff))

    p_bound = -1.0
    mu_up = R_eff = 0.0
    if obs == "Never" and not unmeasured:
        deff = F_cell if F_cell > 1.0 else 1.0
        R_eff = R_usable * N_eff / deff       # the N_eff dividend, collected
        mu_up = py_mu_upper(r_hat)
        if R_eff > 0.0:
            p_bound = mu_up / R_eff

    tier = "none"
    if k > 0:
        tier = ("CORROBORATED" if len(runs) >= CORROB_RUNS else "UNCONFIRMED")

    return dict(obs=obs, k=k, k_eff=k_eff, k_runs=len(runs), n_degen=n_degen,
                first_sight=first_sight,
                mu_total=sum(c["control_target_count"] for c in cells_),
                can_total=sum(c["canary_target_count"] for c in cells_),
                R=R, R_usable=R_usable, F_win=F_win, F_cell=F_cell, r_hat=r_hat,
                mu_upper=mu_up, tau_w=tau_w, N_eff=N_eff, R_eff=R_eff,
                tau_need=tau_need, unresolved=unresolved,
                p_bound=p_bound, P_rep=P_rep,
                ks=("underpowered" if ks < 0 else ("pass" if ks else "SPLIT")),
                ks_D=D, tier=tier, unmeasured=unmeasured)


# ---------------------------------------------------------------------------
# The C driver.
# ---------------------------------------------------------------------------
C_MAIN = r"""
/* GENERATED by hetlitmus/verify/statscheck.py -- do not edit. */
#include "het_verdict.h"

static void run_case(const char *name, const het_obs_record *recs, int n) {
  het_stats_t st;
  het_stats_compute(recs, n, &st);
  printf("CASE|%s|%s|%d|%d|%d|%d|%d|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%s|%.12g|%s|%d|0x%x|%d|%d|%llu|%llu\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.k_runs, st.n_degen,
         st.R_usable, st.F_win, st.F_cell,
         (st.r_hat >= HET_R_POISSON) ? INFINITY : st.r_hat,
         st.mu_upper, st.tau_w, st.N_eff, st.R_eff, st.p_bound, st.P_rep,
         (st.flags & HET_ST_KS_UNDERPOWERED) ? "underpowered"
           : (st.ks_pass ? "pass" : "SPLIT"),
         st.ks_D, het_sighting_name(st.tier), st.tau_runs_needed, st.flags,
         /* st.R is the PRE-clamp record count: R > R_usable can mean cold cells,
            R > HET_STATS_MAX_CELLS means the tail was discarded. */
         st.R, st.n_at_first_sight,
         (unsigned long long)st.mu_total, (unsigned long long)st.can_total);
  printf("PRINT-BEGIN|%s\n", name);
  het_stats_print(stdout, &st);
  printf("PRINT-END|%s\n", name);
}

/* PHASE 5a -- the campaign stopping rule, from the same synthetic records. */
static void stop_case(const char *name, const het_obs_record *recs, int n,
                      int budget, double p_goal) {
  printf("STOP|%s|%s\n", name,
         het_campaign_stop_name(het_campaign_should_stop(recs, n, budget, p_goal)));
}

/* PHASE 1 -- the estimator, against the closed form. */
static void anchors(void) {
  static const double rs[] = { 0.5, 1.0, 2.0, 5.0, 10.0, HUGE_VAL };
  int i;
  for (i = 0; i < 6; i++)
    printf("MU|%.17g|%.17g\n", rs[i], het_mu_upper(rs[i]));
  /* het_win_of must MAP, not return a constant. */
  printf("WIN|%d|%d|%d|%d\n", het_win_of(0, 100000), het_win_of(50000, 100000),
         het_win_of(99999, 100000), (int)HET_NWIN);
  /* THE PYTHON MIRRORS, emitted so they can be COMPARED.  Every fixture below sits
     far from the THETA_D and TAU_HOT boundaries -- deliberately, since a fixture at
     the boundary tests the boundary and not the statistic -- so nothing else in this
     gate can notice one of these macros moving under the mirror. */
  printf("MIRROR|%d|%d|%d|%d\n", (int)HET_THETA_DISTINCT, (int)HET_TAU_HOT,
         (int)HET_STATS_MAX_CELLS, (int)HET_CORROB_RUNS);
  /* The campaign budget (Q3-stats.md R3).  p_min MUST stay unset in the shipped
     header: the het hit-rate is unpublished, and Bagchi's ~0.2% is the GPU-only
     inter-CTA rate.  An unset p_min must return NOT SIZED, never a budget. */
  printf("BUDGET|%.17g|%.17g|%.17g|%.17g\n",
         (double)HET_P_MIN,                     /* must be 0 = UNSET in the shipped hdr */
         het_budget_runs((double)HET_P_MIN, 1.0),   /* -> -1 (not sized)                */
         het_budget_runs(0.002, 1.0),               /* a rate: the Poisson budget        */
         het_budget_runs(0.002, 20.0));             /* ... dispersion-inflated 20x       */
}

/* PHASE 1b -- het_tau_ips against streams whose tau is KNOWN.  An AR(1) process
   x_{t+1} = rho*x_t + u_t has the closed form tau = (1+rho)/(1-rho), independent of
   the noise distribution, so the estimator is validatable with no GPU: if it cannot
   recover a known tau here, nothing it reports on hardware means anything.
   Deterministic LCG => the fixtures are identical on every machine. */
static unsigned long _ar1_lcg;
static double _ar1_u(void) {
  _ar1_lcg = (1103515245UL * _ar1_lcg + 12345UL) & 0x7FFFFFFFUL;
  return (double)_ar1_lcg / (double)0x7FFFFFFFUL;
}
static double _ar1_buf[16 * 2048];
static void ar1_case(const char *tag, double rho, int wlen, int nrun) {
  double mean = 0.0, x;
  int n = 0, r, w;
  _ar1_lcg = 20260714UL;
  for (r = 0; r < nrun; r++) {
    x = 0.0;
    for (w = 0; w < 100; w++) x = rho * x + (_ar1_u() - 0.5);   /* burn-in */
    for (w = 0; w < wlen; w++) { x = rho * x + (_ar1_u() - 0.5); _ar1_buf[n++] = x; }
  }
  for (w = 0; w < n; w++) mean += _ar1_buf[w];
  mean /= (double)n;
  printf("TAU|%s|%.17g|%.17g|%d\n", tag, rho,
         het_tau_ips(_ar1_buf, n, wlen, mean), wlen);
}
static void ar1(void) {
  ar1_case("ar1", 0.0,  2048, 16);
  ar1_case("ar1", 0.5,  2048, 16);
  ar1_case("ar1", 0.9,  2048, 16);
  ar1_case("ar1", 0.99, 2048, 16);
  /* THE CEILING: tau_true = 199 read through 128-window runs never decorrelates in
     view, so the estimator must saturate AT the cap -- a truncated partial sum
     under-reads tau and over-credits N_eff, the one forbidden direction. */
  ar1_case("cap", 0.99, 128, 16);
  /* THE FLOOR: anti-correlated (tau_true = 0.33) must clamp to 1 -- a stream of
     wlen windows can never claim more than wlen independent samples. */
  ar1_case("floor", -0.5, 128, 16);
}

/* PHASE 1c -- het_tau_runs_needed() is the PRICE the operator acts on ("run this
   many runs and N_eff becomes claimable"), pinned against the closed form
   ceil(HET_TAU_MIN_SAMPLES * tau / HET_NWIN).  A price that is silently 0 turns
   TAU_UNRESOLVED into a dead end instead of a signal. */
static void need(void) {
  static const double ts[] = { -1.0, 0.0, 1.0, 2.56, 25.6, 26.0, 54.0, 128.0 };
  int i;
  printf("MINSAMP|%.17g\n", (double)HET_TAU_MIN_SAMPLES);
  for (i = 0; i < 8; i++)
    printf("NEED|%.17g|%d\n", ts[i], het_tau_runs_needed(ts[i]));
}

int main(void) {
  anchors();
  ar1();
  need();
__CASES__
  return 0;
}
"""


def c_val(v):
    if isinstance(v, list):
        return "{" + ",".join(str(x) for x in v) + "}"
    if isinstance(v, float):
        return repr(v)
    return str(v)


def c_cells(name, cells_):
    out = ["  static const het_obs_record %s[%d] = {" % (name, len(cells_))]
    for c in cells_:
        fields = ", ".join(".%s=%s" % (k, c_val(v)) for k, v in sorted(c.items()))
        out.append("    { %s }," % fields)
    out.append("  };")
    return "\n".join(out)


def build_c():
    body = []
    for i, c in enumerate(CASES):
        body.append("  {")
        body.append(c_cells("cells%d" % i, c["cells"]))
        body.append('    run_case("%s", cells%d, %d);'
                    % (c["name"], i, len(c["cells"])))
        body.append("  }")
    for i, s in enumerate(STOPS):
        body.append("  {")
        body.append(c_cells("stopc%d" % i, s["cells"]))
        body.append('    stop_case("%s", stopc%d, %d, %d, %s);'
                    % (s["name"], i, len(s["cells"]), s["budget"],
                       repr(s["p_goal"])))
        body.append("  }")
    return C_MAIN.replace("__CASES__", "\n".join(body))


def _env():
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    return env


def emit_harness(tmp):
    """Emit a REAL harness and return its directory (header + scan both come from it)."""
    test = "MP-cg-sys-fence-2s"
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    subprocess.run(["litmus7", "-gpu-target", "cuda", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, os.path.join(HET_DIR, test + ".litmus")],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = os.path.join(out, test)
    if not os.path.exists(os.path.join(d, "het_verdict.h")):
        raise SystemExit("statscheck: litmus7 did not emit het_verdict.h")
    return d


# ---------------------------------------------------------------------------
def close(a, b, tol=TOL):
    if math.isinf(a) and math.isinf(b):
        return True
    if math.isnan(a) or math.isnan(b):
        return False
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


# ORDER IS THE BIT NUMBER (FLAG_BIT below is index-derived), so this list must
# stay a verbatim transcript of het_verdict.h's HET_ST_* block -- a name skipped
# here silently mis-decodes every flag above it.
FLAGS = ["FANO_UNMEASURED", "NONSTATIONARY", "DEGEN_SIGHTING", "UNDERDISPERSED",
         "BURSTY", "NO_DECODE_CHANNEL", "WIN_DESYNC", "KS_UNDERPOWERED",
         "CELLS_TRUNCATED", "CTRL_IS_CANARY", "BOUND_VACUOUS", "SELF_CONTROL",
         "TAU_UNMEASURED", "TAU_AT_CAP", "TAU_UNRESOLVED", "MIXED_POOL",
         "NO_CONTROL_CORUN"]
FLAG_BIT = {f: 1 << i for i, f in enumerate(FLAGS)}


def _parse_case_fields(l):
    """Parse one CASE| line from the C driver into (name, stats-dict).  Single source of
    truth for phase2 AND the F8 witness bites, so the two can never drift apart."""
    f = l.split("|")
    (_, name, obs, k, k_eff, k_runs, n_degen, R_usable, F_win, F_cell,
     r_hat, mu_up, tau_w, N_eff, R_eff, p_bound, P_rep, ks, ks_D, tier,
     tau_need, flags, R, first_sight, mu_total, can_total) = f
    return name, dict(
        obs=obs, k=int(k), k_eff=int(k_eff), k_runs=int(k_runs),
        n_degen=int(n_degen), R=int(R), R_usable=int(R_usable),
        first_sight=int(first_sight), mu_total=int(mu_total),
        can_total=int(can_total),
        F_win=float(F_win), F_cell=float(F_cell), r_hat=float(r_hat),
        mu_upper=float(mu_up), tau_w=float(tau_w), N_eff=float(N_eff),
        R_eff=float(R_eff), p_bound=float(p_bound),
        P_rep=float(P_rep), ks=ks, ks_D=float(ks_D), tier=tier,
        tau_need=int(tau_need), flags=int(flags, 16))


# ---------------------------------------------------------------------------
# THE KNOWN-OPEN ESCAPE WITNESS.  The tau guard scales its threshold by the ESTIMATED
# tau, so a count-valued bursty stream whose tau the Geyer sum under-reads slips past
# it.  Not fixed: disclosed (het_verdict.h, "WHAT THIS GUARD DOES *NOT* DO"),
# witnessed here, and operationally fenced (hetlitmus/docs/00-environment-design.md
# S6: any early stop below R = 50 usable runs is provisional).  Rationale and the
# rejected alternative: env-research/decisions/F8-decision.md.  This pins the CURRENT
# over-crediting behaviour; a future guard fix makes it fail, and it then BECOMES that
# fix's bite.
# ---------------------------------------------------------------------------
def check_f8_escape_witness(got, quiet=False, neff_expect=F8_NEFF_EXPECT):
    """Assert the four escape facts on the case's REAL C stats (`got` = phase2's map,
    already differential-checked against the Python mirror; the only independent anchor
    used here is the closed form cox_tau, never the mirror).  Returns the failure count.
    Runs from phase2 on the shipped header (must PASS) and from --bite on a mutated
    header or a mis-pinned expectation (must FAIL)."""
    g = got.get(F8_ESCAPE_CASE)
    if g is None:
        print("  *** F8-WITNESS: the escape case produced no CASE line")
        return 1
    fails = 0
    tau_est = g["tau_w"]
    tau_true = COX_ESCAPE_TAU_TRUE
    nwin = g["R_usable"] * NWIN
    guard_fired = bool(g["flags"] & FLAG_BIT["TAU_UNRESOLVED"])
    neff_honest = min(max(NWIN / tau_true, 1.0), float(NWIN))          # 1.49
    over = g["N_eff"] / neff_honest if neff_honest > 0.0 else 0.0

    # (1) ESCAPE-PRECONDITION / ANTI-VACUITY.  The guard must PASS (nwin >= 50*tau_est
    #     and TAU_UNRESOLVED clear).  If drift ever lifts the fixture out of the escape
    #     regime, THIS assertion fails rather than the witness passing on nothing.
    passes = (nwin >= TAU_MIN_SAMPLES * tau_est) and not guard_fired
    if not passes:
        fails += 1
        print("  *** F8-WITNESS(precondition): guard does NOT pass at R=10 (nwin=%d, "
              "50*tau_est=%.1f, TAU_UNRESOLVED=%s) -- the fixture is not in the escape "
              "regime it exists to demonstrate"
              % (nwin, TAU_MIN_SAMPLES * tau_est, guard_fired))

    # (2) THE UNDER-READ: tau_est < tau_true/2 (measured ~16.8 against 85.9).
    if not (tau_est < tau_true / 2.0):
        fails += 1
        print("  *** F8-WITNESS(under-read): tau_est=%.2f is NOT < tau_true/2=%.2f -- the "
              "estimator has stopped under-reading, so there is nothing to fool the guard"
              % (tau_est, tau_true / 2.0))

    # (3) THE OVER-CREDIT, pinned: N_eff credited ~7.6 (+-10%) against an honest
    #     NWIN/tau_true ~1.49, i.e. ~5x.  If a guard fix just made this fail, this
    #     witness IS that fix's bite; a corrupted pin must fail here too.
    if abs(g["N_eff"] - neff_expect) > 0.10 * neff_expect:
        fails += 1
        print("  *** F8-WITNESS(over-credit): N_eff credited=%.3f, pinned %.2f +-10%% "
              "(honest NWIN/tau_true=%.3f => ~%.1fx over-credit) -- either the guard was "
              "fixed (repurpose this witness) or the pin is wrong"
              % (g["N_eff"], neff_expect, neff_honest, over))

    # (4) THE MITIGATION: on these same records the RUN-LEVEL bound is unmoved --
    #     N_eff*p_bound == mu_upper*DEFF/R_usable to 1e-9 (het_verdict.h's R3 identity).
    #     The over-credit refines the per-effective-sample unit only.
    if g["p_bound"] >= 0.0:
        deff = g["F_cell"] if g["F_cell"] > 1.0 else 1.0
        run_level = g["N_eff"] * g["p_bound"]
        b7_headline = g["mu_upper"] * deff / g["R_usable"]
        if not close(run_level, b7_headline):
            fails += 1
            print("  *** F8-WITNESS(invariance): N_eff*p_bound=%.12g != mu_upper*DEFF/"
                  "R_usable=%.12g -- the over-credit is moving the HEADLINE bound, so Path "
                  "1's 'the escape touches only the secondary number' no longer holds"
                  % (run_level, b7_headline))

    if not fails and not quiet:
        print("  the F8 escape witness   :  guard PASSES (nwin=%d >= 50*tau_est=%.0f), "
              "tau_est=%.1f << tau_true=%.1f, N_eff credited=%.2f vs honest=%.2f (~%.1fx "
              "over-credit, KNOWN-OPEN); run-level bound invariant to 1e-9"
              % (nwin, TAU_MIN_SAMPLES * tau_est, tau_est, tau_true, g["N_eff"],
                 neff_honest, over))
    return fails


class _CompileFailed(Exception):
    """The C case set did not compile against a given het_verdict.h.  Carries the
    compiler's output so each caller can report it its own way."""

    def __init__(self, out, err):
        super().__init__(err)
        self.out, self.err = out, err


def _compile_and_run(header_dir, workdir, defines=()):
    """Build the C case set in workdir against header_dir's het_verdict.h, run it and
    return its stdout lines.  Raises _CompileFailed if gcc rejects it.

    ONE definition of the copy/emit/compile/run sequence: run() and _escape_got()
    differ only in how they REPORT a compile failure, and a second copy of the flag
    list is a flag list that can drift."""
    shutil.copy(os.path.join(header_dir, "het_verdict.h"),
                os.path.join(workdir, "het_verdict.h"))
    src = os.path.join(workdir, "st.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(workdir, "st")
    cc = subprocess.run(["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function"]
                        + ["-D" + d for d in defines]
                        + ["-I", workdir, src, "-o", exe, "-lm"],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        raise _CompileFailed(cc.stdout, cc.stderr)
    return subprocess.run([exe], capture_output=True, text=True).stdout.splitlines()


def _escape_got(header_dir):
    """Compile the case set against header_dir's het_verdict.h, run it, and return the
    parsed C stats for the escape case -- the same fields phase2 parses.  Lets --bite
    drive check_f8_escape_witness against a MUTATED header."""
    tmp = tempfile.mkdtemp(prefix="statsf8.")
    try:
        try:
            out = _compile_and_run(header_dir, tmp)
        except _CompileFailed as e:
            raise SystemExit("statscheck F8: witness harness did not compile\n" + e.err)
        for l in out:
            if l.startswith("CASE|"):
                name, rec = _parse_case_fields(l)
                if name == F8_ESCAPE_CASE:
                    return rec
        raise SystemExit("statscheck F8: the escape case produced no CASE line")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def phase1(lines, quiet):
    print("===== PHASE 1: is mu_upper() the closed form, or a disguised 3? =====")
    bad = 0
    got = {}
    for l in lines:
        if l.startswith("MU|"):
            _, r, v = l.split("|")
            got[float(r)] = float(v)
        elif l.startswith("WIN|"):
            _, w0, wmid, wlast, nwin = l.split("|")
            if int(nwin) != NWIN:
                print("  *** HET_NWIN is %s, statscheck assumes %d" % (nwin, NWIN))
                bad += 1
            # het_win_of must MAP: a constant would land every sighting in one bucket
            # and the Fano would be measuring nothing.
            if not (int(w0) == 0 and int(wmid) == NWIN // 2 and int(wlast) == NWIN - 1):
                print("  *** het_win_of does not map frames to windows: "
                      "0->%s, N/2->%s, N-1->%s (want 0, %d, %d)"
                      % (w0, wmid, wlast, NWIN // 2, NWIN - 1))
                bad += 1
            elif not quiet:
                print("      het_win_of maps 0->0, N/2->%d, N-1->%d (it is not a "
                      "constant)" % (NWIN // 2, NWIN - 1))

    # --- THE MIRROR PINS.  statscheck re-derives every statistic in Python, and three
    # of the header's knobs are hard-coded there rather than read from it.  No fixture
    # straddles their boundaries, so a differential CANNOT notice the drift: with
    # HET_THETA_DISTINCT moved 2 -> 3 every decode count in this file (0, 1, 900, 5000)
    # keeps its truth value on both sides and the gate stays green on a stale mirror.
    # Compared here, exactly as HET_NWIN is compared on the WIN| line.
    seen_mirror = False
    for l in lines:
        if not l.startswith("MIRROR|"):
            continue
        seen_mirror = True
        _, td, th, mc, cr = l.split("|")
        for have, want, macro, what in (
                (int(td), THETA_D, "HET_THETA_DISTINCT",
                 "the degeneracy guard's floor: the mirror would call cells "
                 "degenerate that the C does not, or the reverse"),
                (int(th), TAU_HOT, "HET_TAU_HOT",
                 "the COLD-INVALID threshold: the mirror would count a different "
                 "set of cells as usable, so R_usable and every bound built on it"),
                (int(mc), MAX_CELLS, "HET_STATS_MAX_CELLS",
                 "the record-array clamp: the truncation fixture is sized from the "
                 "mirror, so it would stop reaching the truncation path"),
                (int(cr), CORROB_RUNS, "HET_CORROB_RUNS",
                 "the corroboration bar: the tier fixtures are sized from the "
                 "mirror, so both sides of the bar would move with it")):
            if have != want:
                print("  *** MIRROR DRIFT: %s is %d in the header, statscheck's "
                      "Python mirror says %d -- %s is now derived from a different "
                      "constant than the C." % (macro, have, want, what))
                bad += 1
        if not quiet and not bad:
            print("      the Python mirrors match the header: THETA_D=%d, "
                  "TAU_HOT=%d, MAX_CELLS=%d, CORROB_RUNS=%d"
                  % (int(td), int(th), int(mc), int(cr)))
    if not seen_mirror:
        print("  *** no MIRROR| line: the header's THETA_D / TAU_HOT / MAX_CELLS / "
              "CORROB_RUNS are not being compared to statscheck's Python mirrors "
              "at all")
        bad += 1

    # --- The campaign budget: p_min stays a SYMBOL, not a number, until hardware. ---
    for l in lines:
        if not l.startswith("BUDGET|"):
            continue
        _, pmin, unset, b1, b20 = l.split("|")
        pmin, unset, b1, b20 = float(pmin), float(unset), float(b1), float(b20)
        if pmin != 0.0:
            print("  *** HET_P_MIN IS HARDCODED TO %g IN THE SHIPPED HEADER.  The het "
                  "hit-rate is UNPUBLISHED -- Bagchi's ~0.2%% is the GPU-only INTER-CTA "
                  "rate, which never crosses C2C.  A campaign sized off it is sized off "
                  "the wrong experiment." % pmin)
            bad += 1
        if unset >= 0.0:
            print("  *** an UNSET p_min produced a budget (%g) instead of NOT SIZED.  A "
                  "budget invented from no data looks like one." % unset)
            bad += 1
        want1 = math.log(0.05) / math.log(1.0 - 0.002)
        if not (close(b1, want1) and close(b20, 20.0 * want1)):
            print("  *** het_budget_runs is not F*log(0.05)/log(1-p): got %.6g / %.6g, "
                  "want %.6g / %.6g" % (b1, b20, want1, 20.0 * want1))
            bad += 1
        elif not quiet:
            print("      budget: p_min UNSET -> NOT SIZED (correct); at p=0.2%% it needs "
                  "%.0f runs, and %.0f if the channel is 20x overdispersed" % (b1, b20))

    for r in (0.5, 1.0, 2.0, 5.0, 10.0, float("inf")):
        want = py_mu_upper(r)
        have = got.get(r)
        if have is None:
            print("  *** mu_upper(%g) not emitted" % r)
            bad += 1
            continue
        if not close(have, want):
            print("  *** mu_upper(%g) = %.12g, closed form = %.12g" % (r, have, want))
            bad += 1
        elif not quiet:
            print("      mu_upper(%-5s) = %10.4f   (closed form %.4f)"
                  % (("inf" if math.isinf(r) else "%g" % r), have, want))

    # The three anchors that carry the argument.
    for r, anchor, what in ((float("inf"), 2.99573227, "the textbook rule of three"),
                            (1.0, 19.0, "geometric: the 3 has become 19"),
                            (0.5, 199.5, "extreme burst: the 3 has become ~200")):
        have = got.get(r, float("nan"))
        if abs(have - anchor) > 1e-6:
            print("  *** ANCHOR mu_upper(%g) = %.8f, want %.8f (%s)"
                  % (r, have, anchor, what))
            bad += 1
        elif not quiet:
            print("      ANCHOR mu_upper(%-3s) = %8.4f  -- %s"
                  % (("inf" if math.isinf(r) else "%g" % r), have, what))

    # --- het_tau_ips against KNOWN autocorrelation times.  An estimator that cannot
    # recover a known tau here reports nothing but noise on hardware.
    taus = []
    for l in lines:
        if l.startswith("TAU|"):
            _, tag, rho, est, wlen = l.split("|")
            taus.append((tag, float(rho), float(est), int(wlen)))
    ar1 = {rho: est for tag, rho, est, _ in taus if tag == "ar1"}
    for rho, true, lo, hi in AR1_BANDS:
        have = ar1.get(rho, float("nan"))
        if not (lo <= have <= hi):
            print("  *** TAU: AR(1) rho=%.2f has closed-form tau=%.0f but het_tau_ips "
                  "returned %.2f (allowed [%.0f, %.0f]).  The estimator does not "
                  "recover a KNOWN autocorrelation time, so every N_eff it produces "
                  "is fiction." % (rho, true, have, lo, hi))
            bad += 1
        elif not quiet:
            print("      TAU AR(1) rho=%-4.2f -> tau %7.2f   (closed form %6.2f, "
                  "band [%.0f, %.0f])" % (rho, have, true, lo, hi))
    for tag, rho, est, wlen in taus:
        if tag == "cap" and est != float(wlen):
            print("  *** TAU CEILING: a regime with tau=199 read through %d-window "
                  "runs returned %.2f, not the cap %d.  A truncated partial sum "
                  "under-reads tau and OVER-credits N_eff -- the one direction the "
                  "clamps exist to forbid." % (wlen, est, wlen))
            bad += 1
        if tag == "floor" and est != 1.0:
            print("  *** TAU FLOOR: an anti-correlated stream (tau_true=0.33) "
                  "returned %.3f, not the floor 1.0 -- it is claiming more "
                  "independent samples than the stream has windows." % est)
            bad += 1
    if not quiet and not bad:
        print("      TAU ceiling saturates at wlen; floor clamps to 1 "
              "(both one-directional)")

    # --- HET_TAU_MIN_SAMPLES and the PRICE function: TAU_UNRESOLVED is only a signal
    # if it comes with a number the operator can act on.
    for l in lines:
        if l.startswith("MINSAMP|"):
            got_ms = float(l.split("|")[1])
            if got_ms != TAU_MIN_SAMPLES:
                print("  *** HET_TAU_MIN_SAMPLES is %g, statscheck assumes %g.  The "
                      "F >= 50 threshold is the emcee/Stan rule of thumb; moving it "
                      "silently changes what may be CLAIMED." % (got_ms, TAU_MIN_SAMPLES))
                bad += 1
            elif not quiet:
                print("      HET_TAU_MIN_SAMPLES = %g (Foreman-Mackey: don't trust tau "
                      "without >= 50*tau samples); at R=10 that resolves tau <= %.1f"
                      % (got_ms, RESOLVABLE_TAU_AT_R10))
    for l in lines:
        if not l.startswith("NEED|"):
            continue
        _, t, n = l.split("|")
        t, n = float(t), int(n)
        want = 0 if not (t > 0.0) else int(math.ceil(TAU_MIN_SAMPLES * t / NWIN))
        if n != want:
            print("  *** het_tau_runs_needed(%g) = %d, closed form ceil(%g*tau/%d) = %d"
                  % (t, n, TAU_MIN_SAMPLES, NWIN, want))
            bad += 1
    if not quiet and not bad:
        print("      the PRICE of an unresolved tau: tau=54 -> %d usable runs, "
              "tau=128 (the cap) -> %d -- so TAU_UNRESOLVED is actionable, not a veto"
              % (int(math.ceil(TAU_MIN_SAMPLES * 54.0 / NWIN)),
                 int(math.ceil(TAU_MIN_SAMPLES * NWIN / NWIN))))

    if bad:
        print("\nESTIMATOR FAILED: %d problem(s).  A bound whose r->inf limit has "
              "drifted is the rule of three wearing a dispersion-aware hat." % bad)
        return 1
    print("\nESTIMATOR OK (mu_upper matches the closed form to 1e-9 at every r; the "
          "3 -> 19 -> 199.5 inflation is real; het_win_of maps; het_tau_ips "
          "recovers AR(1) tau at every rho and both clamps hold)")
    return 0


def check_neff1_containment(g, what, quiet):
    """THE CONSERVATIVE SPECIAL CASE IS CONTAINED -- stated as the identity it is.

    At N_eff = 1 the bound mu_upper / (R_usable * N_eff / DEFF) IS B7's run-level
    mu_upper / (R_usable / DEFF): `x * 1.0' is exact in IEEE754, and phase2's (a')
    already pins the first form for every case, so re-deriving the second and
    comparing the two could not fail on any input -- it restates an identity, and a
    check that cannot fail is not evidence.  What the two conservative regimes (tau at
    the cap, tau unresolved) actually CLAIM, and what is therefore asserted here, is
    that N_eff came back EXACTLY 1.0; the bound's equality with B7 then follows.
    (A genuinely independent containment test would have to re-run het_stats_compute
    on a header with N_eff forced to 1 and compare THAT number -- a second compile per
    regime, for an identity.  Deliberately not done.)"""
    if not g:
        return 0
    if g["N_eff"] != 1.0:
        print("  *** CONTAINMENT BROKEN: %s must score N_eff = 1 EXACTLY (got %.6g), "
              "so its bound is no longer B7's run-level number -- the N_eff refinement "
              "has changed a claim it had no licence to change." % (what, g["N_eff"]))
        return 1
    if not quiet:
        print("      containment: %s scores N_eff = 1, so its bound (%.4g) IS B7's "
              "mu_upper/(R_usable/DEFF) -- identically, not approximately"
              % (what, g["p_bound"]))
    return 0


def phase2(lines, quiet):
    print("\n===== PHASE 2: is het_stats_compute() a statistic, or a constant? =====")
    bad = 0
    seen_obs, seen_flags, seen_tier, seen_ks = set(), set(), set(), set()
    blocks, cur, buf = {}, None, []
    got = {}

    for l in lines:
        if l.startswith("CASE|"):
            name, rec = _parse_case_fields(l)
            got[name] = rec
            seen_obs.add(rec["obs"])
            seen_tier.add(rec["tier"])
            seen_ks.add(rec["ks"])
            for fl, bit in FLAG_BIT.items():
                if rec["flags"] & bit:
                    seen_flags.add(fl)
        elif l.startswith("PRINT-BEGIN|"):
            cur, buf = l.split("|", 1)[1], []
        elif l.startswith("PRINT-END|"):
            blocks[cur] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(l)

    for c in CASES:
        name = c["name"]
        g = got.get(name)
        if g is None:
            print("  *** %s produced no CASE line" % name)
            bad += 1
            continue
        ref = py_reference(c["cells"])
        errs = []

        # (a) DIFFERENTIAL: every statistic, independently re-derived, to 1e-9.
        for fld in ("F_win", "F_cell", "r_hat", "mu_upper", "tau_w", "N_eff",
                    "R_eff", "p_bound", "P_rep", "ks_D"):
            if not close(g[fld], ref[fld]):
                errs.append("%s: C %.12g != py %.12g" % (fld, g[fld], ref[fld]))

        # (a') SELF-CONSISTENCY, independent of the mirror: N_eff must stay inside the
        # clamp and the bound must decompose as mu_upper / (R_usable * N_eff / DEFF).
        if not (1.0 - TOL <= g["N_eff"] <= NWIN + TOL):
            errs.append("N_eff=%.6g outside [1, %d]" % (g["N_eff"], NWIN))
        if g["p_bound"] >= 0.0:
            deff = g["F_cell"] if g["F_cell"] > 1.0 else 1.0
            want_b = g["mu_upper"] / (g["R_usable"] * g["N_eff"] / deff)
            if not close(g["p_bound"], want_b):
                errs.append("p_bound %.12g != mu_upper/(R*N_eff/DEFF) %.12g"
                            % (g["p_bound"], want_b))
        for fld in ("obs", "k", "k_eff", "k_runs", "n_degen", "R", "R_usable", "ks",
                    "tier", "tau_need", "first_sight", "mu_total", "can_total"):
            if g[fld] != ref[fld]:
                errs.append("%s: C %s != py %s" % (fld, g[fld], ref[fld]))

        # (a'') THE GUARD/PRICE EQUIVALENCE.  The criterion nwin >= 50*tau on the
        # POOLED count, with nwin = R_usable * NWIN, is exactly R_usable >=
        # tau_runs_needed.  Pinning that keeps the flag and the price from drifting
        # apart: a price the flag disagrees with buys runs that change nothing.
        if g["tau_w"] > 0.0:
            fired = bool(g["flags"] & FLAG_BIT["TAU_UNRESOLVED"])
            want_fired = g["R_usable"] < g["tau_need"]
            if fired != want_fired:
                errs.append("TAU_UNRESOLVED=%s but R_usable=%d vs tau_need=%d"
                            % (fired, g["R_usable"], g["tau_need"]))
            # An unresolved tau must buy NOTHING.
            if fired and g["N_eff"] != 1.0:
                errs.append("TAU_UNRESOLVED but N_eff = %.6g (must be exactly 1: an "
                            "unmeasurable tau may not buy a tighter bound)" % g["N_eff"])
            # ... and the two tau flags must never BOTH fire: they prescribe different
            # remedies (AT_CAP -> raise HET_NWIN; UNRESOLVED -> raise R).
            if fired and (g["flags"] & FLAG_BIT["TAU_AT_CAP"]):
                errs.append("both TAU_UNRESOLVED and TAU_AT_CAP set -- they prescribe "
                            "contradictory remedies")

        # (b) the case's own expectations
        w = c["want"]
        for fld, val in w.items():
            if fld in ("flags_any", "flags_none"):
                continue
            if isinstance(val, float):
                if not close(g[fld], val):
                    errs.append("%s: %.12g, want %.12g" % (fld, g[fld], val))
            elif g[fld] != val:
                errs.append("%s: %s, want %s" % (fld, g[fld], val))
        for fl in w.get("flags_any", []):
            if not (g["flags"] & FLAG_BIT[fl]):
                errs.append("flag %s NOT set" % fl)
        for fl in w.get("flags_none", []):
            if g["flags"] & FLAG_BIT[fl]:
                errs.append("flag %s set (must not be)" % fl)

        if errs:
            bad += 1
            print("  *** %-44s %s" % (name, "; ".join(errs)))
        elif not quiet:
            print("      %-44s obs=%-9s F_win=%7.3f p_bound=%-10.4g %s"
                  % (name, g["obs"], g["F_win"], g["p_bound"],
                     ",".join(f for f in FLAGS if g["flags"] & FLAG_BIT[f])))

    # ---- THE ANTI-CONSTANT ASSERTIONS -------------------------------------
    print()
    want_obs = {"VOID", "Never", "Sometimes", "Always"}
    miss = want_obs - seen_obs
    print("  observation classes : %d/%d  (%s)"
          % (len(seen_obs), len(want_obs), ", ".join(sorted(seen_obs))))
    if miss:
        print("  *** UNREACHABLE: %s -- the class is a constant on this input space"
              % ", ".join(sorted(miss)))
        bad += 1

    want_ks = {"pass", "SPLIT", "underpowered"}
    print("  KS outcomes         : %d/%d  (%s)"
          % (len(seen_ks), len(want_ks), ", ".join(sorted(seen_ks))))
    if want_ks - seen_ks:
        print("  *** UNREACHABLE KS OUTCOME: %s -- a stationarity gate that only ever "
              "says one thing is not a gate" % ", ".join(sorted(want_ks - seen_ks)))
        bad += 1

    want_tier = {"none", "UNCONFIRMED", "CORROBORATED"}
    print("  corroboration tiers : %d/%d  (%s)"
          % (len(seen_tier), len(want_tier), ", ".join(sorted(seen_tier))))
    if want_tier - seen_tier:
        print("  *** UNREACHABLE TIER: %s" % ", ".join(sorted(want_tier - seen_tier)))
        bad += 1

    need_flags = {"FANO_UNMEASURED", "NONSTATIONARY", "DEGEN_SIGHTING",
                  "UNDERDISPERSED", "BURSTY", "NO_DECODE_CHANNEL", "WIN_DESYNC",
                  "KS_UNDERPOWERED", "CELLS_TRUNCATED", "CTRL_IS_CANARY",
                  "BOUND_VACUOUS", "SELF_CONTROL", "TAU_UNMEASURED", "TAU_AT_CAP",
                  "TAU_UNRESOLVED", "NO_CONTROL_CORUN"}
    print("  diagnostic flags    : %d/%d  (%s)"
          % (len(seen_flags & need_flags), len(need_flags),
             ", ".join(sorted(seen_flags))))
    if need_flags - seen_flags:
        print("  *** UNREACHABLE FLAG: %s -- a diagnostic that never fires is not a "
              "diagnostic" % ", ".join(sorted(need_flags - seen_flags)))
        bad += 1

    # ---- THE OVERCLAIM ASSERTION: a bare 3/N may never be the reported bound unless
    # the measured Fano really is ~1.  The bursty null and the Poisson null have the
    # same effort and the same zero, so if their bounds agree the dispersion is inert.
    p_pois = got.get("never-poisson", {}).get("mu_upper", 0.0)
    p_burst = got.get("never-bursty", {}).get("mu_upper", 0.0)
    print()
    print("  the rule-of-three inflation:  mu_upper(Poisson-like) = %.4f   "
          "mu_upper(bursty) = %.4f" % (p_pois, p_burst))
    if p_burst <= p_pois * 1.5:
        print("  *** THE BOUND DID NOT WIDEN ON A BURSTY CHANNEL.  It is reporting the "
              "textbook rule of three while calling itself dispersion-aware -- a ~6x "
              "optimistic overclaim on every non-observation in the thesis.")
        bad += 1
    elif not quiet:
        print("      the bursty channel WIDENED the bound %.1fx -- the constant 3 is "
              "not being reported" % (p_burst / max(p_pois, 1e-12)))

    # THE BOUND MUST MOVE WHEN THE EFFORT DOES: 10x the runs, ~10x tighter, or R_eff is
    # not really in the formula.
    b10 = got.get("never-poisson", {}).get("p_bound", -1.0)
    b100 = got.get("bound-tightens-with-R", {}).get("p_bound", -1.0)
    print("  the effort scaling     :  p_bound(R=10) = %.4g   p_bound(R=100) = %.4g"
          % (b10, b100))
    if not (0.0 < b100 < b10 / 5.0):
        print("  *** THE BOUND DID NOT TIGHTEN WITH R.  Ten times the runs bought "
              "nothing, so R_eff is not really in the formula -- the 'bound' is a "
              "constant with a fraction bar through it.")
        bad += 1
    elif not quiet:
        print("      10x the runs TIGHTENED the bound %.1fx -- R_eff is live"
              % (b10 / max(b100, 1e-12)))

    # ---- THE N_eff DIVIDEND IS COLLECTIBLE, BOTH WAYS: a white channel must recover
    # a large N_eff end to end (a mechanism whose output never leaves 1 is the
    # run-level reading with extra arithmetic), and the at-cap regime must be exactly 1.
    ne_w = got.get("never-poisson", {}).get("N_eff", -1.0)
    ne_c = got.get("never-tau-at-cap-is-B7-exactly", {}).get("N_eff", -1.0)
    print("  the N_eff dividend     :  N_eff(white) = %.1f   N_eff(at-cap) = %.1f"
          % (ne_w, ne_c))
    if not (ne_w > NWIN / 2.0):
        print("  *** THE DIVIDEND IS NOT COLLECTED: a near-white control stream "
              "recovered N_eff = %.2f (want > %d).  Every run is still being scored "
              "as ONE bit, so B7's 1,500-30,000-run budgets stand unshrunk -- the "
              "mechanism is dead weight." % (ne_w, NWIN // 2))
        bad += 1
    bad += check_neff1_containment(got.get("never-tau-at-cap-is-B7-exactly", {}),
                                   "the tau-at-cap regime", quiet)

    # ---- THE RELIABILITY GUARD, BOTH DIRECTIONS, AND ITS CONTAINMENT.  A guard that
    # never fires leaves the overclaim in place; one that always fires throws the N_eff
    # dividend away.  Both fixtures are correlated count streams with an exact
    # closed-form tau, so this is a measurement rather than a hand-picked fixture.
    gu = got.get("never-tau-unresolved-falls-back-to-B7", {})
    gr = got.get("never-tau-resolved-still-claims-Neff", {})
    print()
    if gu and gr:
        print("  the tau reliability guard:  UNRESOLVED tau_w = %.1f (needs %d runs, "
              "has %d) -> N_eff = %.1f   |   RESOLVED tau_w = %.1f (needs %d) -> "
              "N_eff = %.1f"
              % (gu["tau_w"], gu["tau_need"], gu["R_usable"], gu["N_eff"],
                 gr["tau_w"], gr["tau_need"], gr["N_eff"]))
        # The unresolved fixture's tau is under-read (~54 against a true 181) and sits
        # BELOW the 128 cap, so TAU_AT_CAP cannot catch it; unguarded it would credit
        # N_eff = NWIN/54 = 2.4 and report a bound that much tighter than the truth.
        naive = min(max(NWIN / gu["tau_w"], 1.0), float(NWIN)) if gu["tau_w"] > 0 else 1.0
        if naive <= 1.0:
            print("  *** THE UNRESOLVED FIXTURE IS NOT AN OVERCLAIM FIXTURE: believing "
                  "its tau would have credited N_eff = %.2f, so this case cannot show "
                  "that the guard prevents anything.  It has stopped being an "
                  "instrument." % naive)
            bad += 1
        elif not quiet:
            print("      without the guard this fixture would have credited N_eff = "
                  "%.1f (tau under-read to %.1f, BELOW the %d cap -- so TAU_AT_CAP "
                  "could never have caught it): a %.1fx tighter bound than the truth "
                  "supports" % (naive, gu["tau_w"], NWIN, naive))
        if gr["N_eff"] <= 1.0:
            print("  *** THE GUARD IS A SIXTH CONSTANT: it fired on a tau the stream "
                  "RESOLVES (%.1f, needing only %d runs of the %d it has), so N_eff is "
                  "pinned at 1 and B7b has been silently reverted to B7 -- the dividend "
                  "is thrown away on every channel."
                  % (gr["tau_w"], gr["tau_need"], gr["R_usable"]))
            bad += 1
        # CONTAINMENT: when the guard fires the fallback must be the run-level number,
        # so the guard can never be worse than the baseline it falls back to.
        bad += check_neff1_containment(gu, "the unresolved-tau fallback", quiet)

    # ---- The guard's two in-band outcomes are pinned above; this pins the third,
    # self-referential one it cannot see (check_f8_escape_witness).
    bad += check_f8_escape_witness(got, quiet)

    # THE PRINTOUT IS THE DELIVERABLE, NOT THE FLAG: the human block must SAY that tau
    # was not resolved, that N_eff fell back, and -- since this is a signal and not a
    # veto -- what it would COST in runs to resolve it.  Assert the sentences.
    for name, g in sorted(got.items()):
        txt = blocks.get(name, "")
        if g["flags"] & FLAG_BIT["TAU_UNRESOLVED"]:
            for frag, why in (
                    ("NOT RESOLVED", "it does not SAY tau is unresolved"),
                    ("N_eff FALLS BACK TO 1", "it does not say N_eff fell back"),
                    ("NOT A FAILURE AND NOT A VETO",
                     "it does not say the guard is a signal, not a veto"),
                    ("usable run(s)", "it does not PRICE the claim in runs")):
                if frag not in txt:
                    print("  *** %s sets TAU_UNRESOLVED but %s.  A flag the printout "
                          "does not explain is a flag nobody acts on." % (name, why))
                    bad += 1
            if ("%d usable run" % g["tau_need"]) not in txt:
                print("  *** %s does not print the runs needed (%d) to resolve its tau "
                      "-- the operator cannot act on a price that is not quoted"
                      % (name, g["tau_need"]))
                bad += 1

    # A ROW THAT CO-RUNS NOTHING MUST NOT CLAIM TO BE THE CANARY.  Both states set
    # the same denominator, so the numbers alone cannot tell them apart; only the
    # sentence can, and it is the sentence a reader files the result under.
    for name, g in sorted(got.items()):
        txt = blocks.get(name, "")
        if g["flags"] & FLAG_BIT["SELF_CONTROL"]:
            if "it IS the Layer-B canary" not in txt:
                print("  *** %s is the self-canary row but does not SAY so" % name)
                bad += 1
            if "NO POSITIVE-CONTROL MAP WAS READ" in txt:
                print("  *** %s claims BOTH that it is the canary and that no map "
                      "was read" % name)
                bad += 1
        if g["flags"] & FLAG_BIT["NO_CONTROL_CORUN"]:
            if "IS the Layer-B canary" in txt:
                print("  *** %s co-runs nothing and names no canary, yet the "
                      "printout calls it the Layer-B canary -- that is the "
                      "inference, not the record" % name)
                bad += 1
            # HET_NO_CONTROL_MAP is 0 in this standalone build, so this is the
            # can't-happen arm: a map WAS read and still nothing vouches for the row.
            if "that is a BUILD BUG, not a result" not in txt:
                print("  *** %s co-runs nothing with a control map present and the "
                      "printout does not call that a build bug" % name)
                bad += 1
        if (g["flags"] & (FLAG_BIT["SELF_CONTROL"] | FLAG_BIT["NO_CONTROL_CORUN"])) \
           and g["k"] > 0 and g["obs"] == "Always":
            print("  *** %s reports ALWAYS while nothing co-runs: the denominator "
                  "collapsed onto the runs that fired" % name)
            bad += 1

    # No bound may EVER be printed when the dispersion was not measured.
    for name, g in sorted(got.items()):
        if (g["flags"] & FLAG_BIT["FANO_UNMEASURED"]) and g["p_bound"] >= 0.0:
            print("  *** %s printed a bound (%.6g) with an UNMEASURED dispersion -- "
                  "that bound is the rule of three in disguise" % (name, g["p_bound"]))
            bad += 1
        txt = blocks.get(name, "")
        if (g["flags"] & FLAG_BIT["FANO_UNMEASURED"]) and g["obs"] == "Never" \
           and "NO FALSE-NEGATIVE BOUND IS REPORTED" not in txt:
            print("  *** %s has no measured dispersion but does not SAY it is "
                  "reporting no bound" % name)
            bad += 1

        # A REPORTED P_rep OF EXACTLY 0 IS NOT A STATISTIC: 1 - e^{-0} = 0 prints as
        # "P_rep = 0.00%", which reads as "never reproduces" when it means "every
        # sighting failed the decode guard".  Asserted DIRECTLY, not differentially:
        # both mirrors would compute the same 0, so the cross-check cannot see it.
        if g["P_rep"] == 0.0:
            print("  *** %s reports P_rep = 0.00%%.  That is not a reproducibility "
                  "estimate, it is the ABSENCE of one (k_eff = %d), and printing it "
                  "as a percentage invites it into a table as evidence."
                  % (name, g["k_eff"]))
            bad += 1
        if g["k_eff"] == 0 and g["P_rep"] >= 0.0:
            print("  *** %s reports a P_rep with ZERO clean cells behind it" % name)
            bad += 1

    if bad:
        print("\nAGGREGATE FAILED: %d problem(s)." % bad)
        return 1
    print("\nAGGREGATE OK (%d cases; every statistic matches an independent Python "
          "re-derivation to 1e-9; every class, KS outcome, tier and flag reachable)"
          % len(CASES))
    return 0


# ---------------------------------------------------------------------------
# PHASE 3 -- THE PRODUCER, LIVE BOTH WAYS.  The recovery scan is pure host C over host
# buffers, so it can be lifted out of the emitted harness and run on PLANTED buffers.
# That tests the DECODER only -- no GPU, no coherence, no memory-model claim -- which
# is the class of probe the dev box is allowed to run (impl-briefs/SHARED-CHARGE.md:
# "compile and (where a probe applies) smoke-run for plumbing/ABI only").
# ---------------------------------------------------------------------------
SCAN_RE = re.compile(r"/\* ---- recovery scan: [^\n]*Layer A[^\n]*\*/\n")


def extract_scan(cu_src):
    """Lift the mu(T) control scan (a balanced brace block) out of a real harness."""
    m = SCAN_RE.search(cu_src)
    if not m:
        raise SystemExit("statscheck: no Layer-A scan found in the emitted harness")
    i = cu_src.index("{", m.end())
    depth, j = 0, i
    while j < len(cu_src):
        if cu_src[j] == "{":
            depth += 1
        elif cu_src[j] == "}":
            depth -= 1
            if depth == 0:
                return cu_src[i:j + 1]
        j += 1
    raise SystemExit("statscheck: unbalanced braces in the extracted scan")


PROBE_C = r"""
/* GENERATED by hetlitmus/verify/statscheck.py -- the PRODUCER liveness probe. */
#include "het_verdict.h"
#include <stdlib.h>
#include <string.h>
#define SIZE_OF_TEST %(n)d
#define MU_K_TAG %(k)d
#ifndef HET_WINDOW
#define HET_WINDOW 8
#endif
#ifndef HET_EXHAUSTIVE_MAX
#define HET_EXHAUSTIVE_MAX 4096
#endif
%(bufdecl)s

int main(int argc, char **argv) {
  int mode = (argc > 1) ? atoi(argv[1]) : 0;   /* 0=OFF 1=SPREAD 2=EARLY */
  het_obs_record _rec;
  int _f, w, nz = 0;
  uint64_t sum = 0;
  memset(&_rec, 0, sizeof _rec);
%(bufalloc)s

  /* Plant GENUINE recovered MP cycles: the writer's tag is K*m + 2 (its 2nd store),
     and the reader saw init -- exactly the weak outcome the scan's own predicate
     decodes.  Nothing is faked; the buffers are what a firing control would leave. */
  if (mode == 1)                                   /* SPREAD: across the whole run */
    for (_f = 0; _f < SIZE_OF_TEST; _f += 1000) {
      %(b0)s[_f] = (uint64_t)MU_K_TAG * (uint64_t)(_f + 1) + 2;
      %(b1)s[_f] = 0;
    }
  /* EARLY: only the first HALF-WINDOW of frames (window 0 spans N/HET_NWIN of
     them), so every planted hit must land in bucket 0 -- at any HET_NWIN. */
  if (mode == 2)
    for (_f = 0; _f < SIZE_OF_TEST / (2 * HET_NWIN); _f += 10) {
      %(b0)s[_f] = (uint64_t)MU_K_TAG * (uint64_t)(_f + 1) + 2;
      %(b1)s[_f] = 0;
    }

%(scan)s

  for (w = 0; w < HET_NWIN; w++) {
    sum += _rec.control_win[w];
    if (_rec.control_win[w]) nz++;
  }
  printf("PROBE mode=%%d total=%%llu sum=%%llu nz=%%d win0=%%u\n", mode,
         (unsigned long long)_rec.control_target_count,
         (unsigned long long)sum, nz, _rec.control_win[0]);
  return 0;
}
"""


def phase3(hdir, tmp, quiet):
    print("\n===== PHASE 3: are the per-window sub-tallies LIVE, BOTH WAYS? =====")
    test = os.path.basename(hdir)
    with open(os.path.join(hdir, test + ".cu")) as fh:
        cu = fh.read()

    scan = extract_scan(cu)
    n = int(re.search(r"#define SIZE_OF_TEST (\d+)", cu).group(1))
    k = int(re.search(r"#define MU_K_TAG\s+(\d+)", cu).group(1))
    bufs = sorted(set(re.findall(r"\b(mu_[A-Za-z0-9_]*_h)\b", scan)))
    if len(bufs) < 2:
        raise SystemExit("statscheck: expected >=2 host buffers in the scan, got %s"
                         % bufs)
    print("  scan     : %d lines lifted from the REAL harness (%s)"
          % (scan.count("\n") + 1, test))
    print("  buffers  : %s   (K=%d, N=%d)" % (", ".join(bufs), k, n))

    src = PROBE_C % dict(
        n=n, k=k, scan=scan,
        bufdecl="\n".join("static uint64_t *%s;" % b for b in bufs),
        bufalloc="\n".join(
            '  %s = (uint64_t*)calloc(SIZE_OF_TEST, sizeof(uint64_t));' % b
            for b in bufs),
        b0=bufs[0], b1=bufs[1])
    p = os.path.join(tmp, "probe.c")
    with open(p, "w") as fh:
        fh.write(src)
    exe = os.path.join(tmp, "probe")
    cc = subprocess.run(["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
                         "-Wno-unused-variable", "-Wno-unused-but-set-variable",
                         "-I", hdir, "-I", tmp, p, "-o", exe, "-lm"],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        print(cc.stdout + cc.stderr)
        print("\nPRODUCER FAILED: the lifted scan does not compile")
        return 1

    res = {}
    for mode in (0, 1, 2):
        r = subprocess.run([exe, str(mode)], capture_output=True, text=True)
        m = re.match(r"PROBE mode=(\d+) total=(\d+) sum=(\d+) nz=(\d+) win0=(\d+)",
                     r.stdout.strip())
        if not m:
            print("  *** probe produced no output for mode %d: %r" % (mode, r.stdout))
            return 1
        res[mode] = tuple(int(x) for x in m.groups()[1:])
        if not quiet:
            print("      %-7s total=%-6d sum(win)=%-6d buckets_nonzero=%-3d win[0]=%d"
                  % (("OFF", "SPREAD", "EARLY")[mode], *res[mode]))

    bad = 0
    t0, s0, nz0, _ = res[0]
    t1, s1, nz1, _ = res[1]
    t2, s2, nz2, w2 = res[2]

    # OFF: zero buffers, nothing recovered, every window zero.
    if not (t0 == 0 and s0 == 0 and nz0 == 0):
        print("  *** OFF: the scan tallied %d hit(s) on ZERO buffers -- the detector "
              "is constant-true" % t0)
        bad += 1

    # ON: a tally that is always zero and one that is always nonzero are equally
    # worthless.  This half proves the bump RUNS.
    if t1 == 0:
        print("  *** SPREAD: the scan recovered NOTHING from planted cycles -- the "
              "detector is constant-false")
        bad += 1
    if s1 != t1:
        print("  *** SPREAD: sum(control_win) = %d but control_target_count = %d.  "
              "The per-window bump is DEAD or mis-indexed, and every dispersion "
              "number computed from it would be fiction." % (s1, t1))
        bad += 1
    if nz1 <= 1:
        print("  *** SPREAD: hits spread across the whole run landed in %d bucket(s) "
              "-- het_win_of is behaving like a constant" % nz1)
        bad += 1

    # THE MAPPING: sum(win)==total would still hold if every hit went to bucket 0, so
    # hits confined to the first half-window must put ALL the mass in window 0.
    if not (t2 > 0 and nz2 == 1 and w2 == t2):
        print("  *** EARLY: %d hit(s) confined to the first half-window landed in "
              "%d bucket(s) with win[0]=%d -- the frame->window MAP is wrong"
              % (t2, nz2, w2))
        bad += 1

    if bad:
        print("\nPRODUCER FAILED: %d problem(s)." % bad)
        return 1
    print("\nPRODUCER OK (zero when the control does not fire; nonzero and CORRECTLY "
          "BUCKETED when it does -- proved on the real emitted scan, on the host, with "
          "no GPU and no memory-model claim)")
    return 0


# ---------------------------------------------------------------------------
def phase4(tamper=None):
    print("\n===== PHASE 4: does the EMITTED CORPUS carry the B7 machinery? =====")
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    tmp = tempfile.mkdtemp(prefix="statscorpus.")
    n_sync = n_obs = n_neither = n_win = n_stats = n_nwin = n_stop = 0
    tampered = 0
    bad = 0
    try:
        r = subprocess.run(
            ["litmus7", "-gpu-target", "cuda", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
             "-o", tmp] + [os.path.join(HET_DIR, t + ".litmus") for t in tests],
            cwd=ROOT, env=_env(), capture_output=True, text=True)
        if r.returncode != 0:
            print("  *** litmus7 failed to emit the corpus:\n" + r.stderr[-2000:])
            return 1
        for t in tests:
            cu = os.path.join(tmp, t, t + ".cu")
            if not os.path.exists(cu):
                print("  *** %-26s no .cu emitted" % t)
                bad += 1
                continue
            with open(cu) as fh:
                src = fh.read()
            if tamper is not None:
                new = tamper(t, src)
                if new != src:
                    tampered += 1
                src = new
            s = "_rec.sync_valid = 1;" in src
            o = "_rec.obs_valid = 1;" in src
            n_sync += s
            n_obs += o
            if not s and not o:
                n_neither += 1
                print("  *** %-26s has NEITHER decode channel: its degeneracy guard "
                      "is blind" % t)
            if "het_win_of" in src:
                n_win += 1
            if "het_stats_compute" in src:
                n_stats += 1
            # The REALISED window resolution must ride in every record -- a swept
            # HET_NWIN the record does not report would silently mis-tune the
            # tuner -- and every harness must carry the adaptive stop.
            if "_rec.nwin = (uint32_t)HET_NWIN;" in src:
                n_nwin += 1
            if "het_campaign_should_stop" in src:
                n_stop += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if tamper is not None and tampered == 0:
        print("  *** VACUOUS BITE: the corpus injection matched NOTHING")
        return 2

    for what, got, want in (("sync_valid", n_sync, CENSUS_SYNC),
                            ("obs_valid", n_obs, CENSUS_OBS),
                            ("NEITHER (blind)", n_neither, CENSUS_NEITHER),
                            ("window bump", n_win, CENSUS_WINBUMP),
                            ("stats post-pass", n_stats, CENSUS_TESTS),
                            ("nwin in record", n_nwin, CENSUS_TESTS),
                            ("adaptive stop", n_stop, CENSUS_TESTS)):
        mark = "    " if got == want else " ***"
        print("%s  %-18s %3d / %d   (expect %3d)" % (mark, what, got, len(tests), want))
        if got != want:
            bad += 1

    if bad:
        print("\nCORPUS FAILED: %d problem(s).  A guard that branches on a field the "
              "emitter never sets is a guard nobody runs." % bad)
        return 1
    print("\nCORPUS OK (every one of the %d harnesses computes the statistics and has "
          "a decode channel; 0 are blind)" % len(tests))
    return 0


# ---------------------------------------------------------------------------
# PHASE 5a -- THE STOPPING RULE.
# ---------------------------------------------------------------------------
def phase5_stops(lines, quiet):
    print("\n===== PHASE 5: does the stopping rule DECIDE, or always say one "
          "thing? =====")
    bad = 0
    got = {}
    for l in lines:
        if l.startswith("STOP|"):
            _, name, verdict = l.split("|")
            got[name] = verdict
    seen = set(got.values())
    for s in STOPS:
        have = got.get(s["name"])
        if have is None:
            print("  *** %s produced no STOP line" % s["name"])
            bad += 1
        elif have != s["want"]:
            print("  *** %-44s %s, want %s" % (s["name"], have, s["want"]))
            bad += 1
        elif not quiet:
            print("      %-44s -> %s" % (s["name"], have))
    want_all = {"CONTINUE", "CONFIRMED", "BOUND-MET", "BUDGET"}
    miss = want_all - seen
    print("  stop reasons reachable: %d/%d  (%s)"
          % (len(seen & want_all), len(want_all), ", ".join(sorted(seen))))
    if miss:
        print("  *** UNREACHABLE STOP REASON: %s -- a scheduler whose rule cannot "
              "give this answer never will" % ", ".join(sorted(miss)))
        bad += 1
    if bad:
        print("\nSTOPPING RULE FAILED: %d problem(s)." % bad)
        return 1
    print("\nSTOPPING RULE OK (every reason reachable; a lone clean sighting "
          "escalates instead of stopping; a degenerate one never stops; a vacuous "
          "bound satisfies no goal; an unstamped record earns no early stop)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 5b -- THE SCHEDULER, END TO END, against a stub runner.  campaign.py spends
# (or saves) the hardware hours and none of its policy needs a GPU: the HetStats line
# is its whole interface.  The stub emits deterministic lines per (test, invocation),
# so the pooling arithmetic and the stop decisions are pinned exactly -- e.g. the
# pooled bound 2.9957/(100*i) crosses p_goal=0.01 at exactly the third invocation.
#
# WHAT IS PINNED HERE IS campaign.py AS IT STANDS, not a target design.  Its policy
# is still class-keyed -- it reads Allowed/Disallowed/NO-ORACLE out of a control map,
# sweeps the Allowed rows first, stops one at its first clean sighting, and calls a
# corroborated sighting on a Disallowed row a stop-everything event.  het_verdict.h's
# own rule branches on no class at all (it stops on corroboration, on the bound, or
# on the budget), so these two policies have already diverged; the redesign that
# closes the gap owns this phase's rewrite.  Until then the assertions below record
# the behaviour rather than endorse it.
# ---------------------------------------------------------------------------
STUB_RUNNER = r'''#!/usr/bin/env python3
import os, sys
d = sys.argv[1]
test = os.path.basename(d)
cf = os.path.join(d, "inv.count")
inv = (int(open(cf).read()) + 1) if os.path.exists(cf) else 1
open(cf, "w").write(str(inv))
with open(os.path.join(d, "seeds.log"), "a") as fh:
    fh.write("%d %s %s %s\n" % (inv, os.environ.get("HET_SEED"),
                                os.environ.get("HET_ADAPTIVE"),
                                os.environ.get("HET_RUNS_MAX")))
base = ("R=10 usable=10 degen=0 ctrl=canary win_n=1280 nwin=128 F_win=1.05 "
        "F_cell=1.02 r_hat=inf acf1=0.01 ks=pass ks_D=0.1 ks_Dcrit=0.2 "
        "ks_split=-1 N=100000 frames=100000 flags=0x0")
NULL = ("mu_upper=2.9957 tau_w=1.28 N_eff=100 tau_need=1 R_eff=100 "
        "p_bound=0.029957 P_rep=-1")
if test == "ALW-fires":
    k = 1 if inv >= 2 else 0
    print("HetStats %s obs=%s k=%d k_eff=%d k_runs=%d sighting=none "
          "mu_upper=0 tau_w=1.28 N_eff=100 tau_need=1 R_eff=0 p_bound=-1 P_rep=-1 %s"
          % (test, "Sometimes" if k else "Never", k, k, k, base))
elif test == "ALW-cold":
    print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 sighting=none "
          "%s %s" % (test, NULL, base))
elif test == "DIS-null":
    print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 "
          "sighting=none %s %s" % (test, NULL, base))
elif test == "DIS-unres":
    # THE SAME NULL AND THE SAME EFFORT as DIS-null, but this channel's tau (53.8)
    # needs 22 usable runs and the invocation has 10, so it is UNRESOLVED: N_eff falls
    # back to 1 and R_eff is 10, not 100.  Believing the under-read tau would give
    # R_eff = 100, the pooled bound 2.9957/(100*i) would cross p_goal=0.01 at
    # invocation 3, and the campaign would bank a bound it never earned.  Guarded, the
    # pooled bound 2.9957/(10*i) never reaches 0.01 inside the budget and the row keeps
    # running: "run more runs", not "give up" and not "stop early".
    print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 sighting=none "
          "mu_upper=2.9957 tau_w=53.8 N_eff=1 tau_need=22 R_eff=10 p_bound=0.29957 "
          "P_rep=-1 R=10 usable=10 degen=0 ctrl=canary win_n=1280 nwin=128 F_win=1.05 "
          "F_cell=1.02 r_hat=inf acf1=0.01 ks=pass ks_D=0.1 ks_Dcrit=0.2 ks_split=-1 "
          "N=100000 frames=100000 flags=0x4000" % test)
elif test == "DIS-fires":
    print("HetStats %s obs=Sometimes k=1 k_eff=1 k_runs=1 "
          "sighting=UNCONFIRMED mu_upper=0 tau_w=1.28 N_eff=100 tau_need=1 "
          "R_eff=0 p_bound=-1 P_rep=0.632 %s" % (test, base))
elif test == "NOR-null":
    print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 "
          "sighting=none %s %s" % (test, NULL, base))
else:
    sys.exit(3)
'''

CAMPAIGN = os.path.join(ROOT, "hetlitmus", "campaign.py")
SEED_STRIDE = 100003     # must match campaign.py
# The budgets phase 6 drives the campaign with, and the R every STUB_RUNNER line
# reports.  Named because the HET_RUNS_MAX assertion re-derives the remaining budget
# from them: budget - STUB_R * (invocations already spent).
BOUND_BUDGET, ALLOWED_BUDGET, STUB_R = 100, 30, 10


def phase6_campaign(quiet):
    print("\n===== PHASE 6: does the scheduler spend the hours where the brief "
          "says? =====")
    tmp = tempfile.mkdtemp(prefix="statssched.")
    bad = 0
    try:
        # --- 6.0: read_control_map must parse BOTH real grounded files, whose header
        # rows differ in their first column.  A header ingested as a test named "Test"
        # with class "Expected" kills the campaign before it schedules anything.  Then
        # prove the unknown-class guard still fatals on a mistagged row.
        loader = ("import sys; sys.path.insert(0, %r); import campaign; "
                  % os.path.join(ROOT, "hetlitmus"))
        for base in ("control-map.csv",):
            real = os.path.join(ROOT, "hetlitmus", "tests", "het", base)
            r0 = subprocess.run(
                [sys.executable, "-c", loader +
                 "m = campaign.read_control_map(sys.argv[1]); "
                 "assert len(m) == 411, len(m); "
                 "assert 'Test' not in m and 'Litmus' not in m, "
                 "'header ingested as a test'; "
                 "print('ok')", real],
                capture_output=True, text=True)
            if r0.returncode != 0 or r0.stdout.strip() != "ok":
                print("  *** read_control_map(%s): rc=%d out=%r err=%r"
                      % (base, r0.returncode, r0.stdout.strip(),
                         r0.stderr.strip()[-300:]))
                bad += 1
        badmap = os.path.join(tmp, "bad-class.csv")
        with open(badmap, "w") as fh:
            fh.write("Test,Expected,Mu,Canary\nSB-x,Allwoed,-,-\n")
        rg = subprocess.run(
            [sys.executable, "-c", loader +
             "campaign.read_control_map(sys.argv[1])", badmap],
            capture_output=True, text=True)
        if rg.returncode != 2 or "unknown oracle class" not in rg.stderr:
            print("  *** the unknown-class guard did not FATAL on a mistagged "
                  "row (rc=%d stderr=%r)" % (rg.returncode, rg.stderr[-300:]))
            bad += 1

        corpus = os.path.join(tmp, "corpus")
        tests = ["ALW-fires", "ALW-cold", "DIS-null", "DIS-unres", "DIS-fires",
                 "NOR-null"]
        for t in tests:
            os.makedirs(os.path.join(corpus, t))
        cmap = os.path.join(tmp, "control-map.csv")
        with open(cmap, "w") as fh:
            # The header line is deliberate: the real control-map.csv has one, and a
            # fixture without it would not exercise the skip 6.0 checks.
            fh.write("Test,Expected,Mu,Canary\n"
                     "ALW-fires,Allowed,-,MP-cg-sys-relaxed\n"
                     "ALW-cold,Allowed,-,MP-cg-sys-relaxed\n"
                     "DIS-null,Disallowed,mu,MP-cg-sys-relaxed\n"
                     "DIS-unres,Disallowed,mu,MP-cg-sys-relaxed\n"
                     "DIS-fires,Disallowed,mu,MP-cg-sys-relaxed\n"
                     "NOR-null,NO-ORACLE,-,MP-cg-sys-relaxed\n")
        stub = os.path.join(tmp, "stub.py")
        with open(stub, "w") as fh:
            fh.write(STUB_RUNNER)
        state = os.path.join(tmp, "state.csv")
        r = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--control-map", cmap,
             "--runner", "%s %s {dir}" % (sys.executable, stub),
             "--p-goal", "0.01", "--budget-runs", str(BOUND_BUDGET),
             "--allowed-budget-runs", str(ALLOWED_BUDGET),
             "--seed0", "777", "--state", state],
            capture_output=True, text=True)
        out = r.stdout

        # A CRASH EXITS 1 TOO.  This fixture set contains a CONFIRMED refutation, so
        # the campaign is expected to exit 1 -- which means an unhandled exception
        # produces the "right" code by accident and the rc check below passes for free.
        if "Traceback" in r.stderr:
            print("  *** the campaign CRASHED (its exit code 1 is indistinguishable "
                  "from the expected CONFIRMED exit):\n%s" % r.stderr[-800:])
            bad += 1

        # CONFIRMED is present in this fixture set, so the campaign must exit 1
        # (a recorded refutation demands a human, not a green build of the run).
        if r.returncode != 1:
            print("  *** campaign exited %d (want 1: a CONFIRMED refutation was "
                  "recorded)\n%s%s" % (r.returncode, out[-1500:], r.stderr[-500:]))
            bad += 1

        done = {}
        order = []
        for l in out.splitlines():
            if l.startswith("done  "):
                f = l.split()
                done[f[2]] = dict(cls=f[1], stop=f[3],
                                  inv=int(f[4].split("=")[1]),
                                  runs=int(f[5].split("=")[1]))
                order.append(f[2])

        # THE SCHEDULE: the Allowed sweep runs FIRST.  It is both the cheap cut (only
        # the Disallowed and NO-ORACLE rows need a bound; an Allowed row needs one
        # sighting) and the p_min candidate population.
        if order[:2] != ["ALW-cold", "ALW-fires"] or len(order) != 6:
            print("  *** scheduling order %s -- the Allowed sweep must run first"
                  % order)
            bad += 1
        want = {
            # fires on invocation 2 -> stops THERE, not at budget: fire-once.
            "ALW-fires": ("OBSERVED", 2),
            # never fires -> its small Allowed budget (30 runs = 3 invocations).
            "ALW-cold": ("BUDGET", 3),
            # pooled bound 2.9957/(100*i) <= 0.01 first at i=3: EXACT arithmetic.
            "DIS-null": ("BOUND-MET", 3),
            # Same null and effort as DIS-null but tau UNRESOLVED, so N_eff = 1,
            # R_eff = 10/invocation, and the pooled bound 2.9957/(10*i) never reaches
            # p_goal inside the 100-run budget: this row runs to BUDGET where DIS-null
            # banks BOUND-MET at 3.  That divergence is the guard, in hardware hours.
            "DIS-unres": ("BUDGET", 10),
            # clean sightings pool to k_runs>=3 at invocation 3 -> CONFIRMED.
            "DIS-fires": ("CONFIRMED", 3),
            "NOR-null": ("BOUND-MET", 3),
        }
        for t, (stop, inv) in want.items():
            g = done.get(t)
            if g is None:
                print("  *** no 'done' line for %s" % t)
                bad += 1
            elif (g["stop"], g["inv"]) != (stop, inv):
                print("  *** %-10s stop=%s inv=%d, want stop=%s inv=%d"
                      % (t, g["stop"], g["inv"], stop, inv))
                bad += 1
            elif not quiet:
                print("      %-10s %-10s stop=%-9s after %d invocation(s)"
                      % (t, g["cls"], g["stop"], g["inv"]))
        # The corroborated sighting must be called out AND its target named.
        # This pin was "CONFIRMED refutation" until P2d (2026-08-03); that phrase
        # was itself the overclaim, because every oracle row is a DERIVATION over
        # cited sources rather than a measurement, so what a corroborated
        # sighting disagrees with FIRST is the row.  P2e made that the one
        # unconditional sentence; the pin is that the summary is loud AND says
        # so, never that it reads as a refutation of the compound model.
        if "CONFIRMED sighting" not in out:
            print("  *** the CONFIRMED sighting is not called out in the summary")
            bad += 1
        # TWO pins, because there are TWO places the sentence has to appear and
        # one substring covering both is not a check on either.  MEASURED
        # 2026-08-03: a single `indict THAT ROW first' pin stayed green when the
        # PER-ROW note was replaced by "a corroborated sighting", because the
        # roll-up line below still carried the words.
        if "it indicts THAT ROW first" not in out:      # the per-row CONFIRMED note
            print("  *** the per-row CONFIRMED note does not say WHAT the sighting "
                  "indicts -- it would read as a CMCM refutation")
            bad += 1
        if "NONE of them is a CMCM refutation" not in out:   # the roll-up line
            print("  *** the confirmation roll-up does not state that no confirmed "
                  "sighting is a CMCM refutation as it stands")
            bad += 1
        if "CANDIDATE CMCM REFUTATION" in out:
            print("  *** the summary called a corroborated sighting a candidate "
                  "CMCM refutation; the oracle row is indicted first (P2e)")
            bad += 1

        # THE SCHEDULER MUST TREAT AN UNRESOLVED TAU AS A PRICE, NOT A FAILURE: not an
        # ERROR (that de-schedules a test for being honest), it KEEPS RUNNING (asserted
        # above by DIS-unres reaching BUDGET), and the price in runs is reported --
        # a signal the operator cannot see is a veto.
        gu = done.get("DIS-unres", {})
        if gu.get("stop") == "ERROR":
            print("  *** an UNRESOLVED tau was recorded as an ERROR.  It is not a "
                  "failure -- it is a conservative (B7) bound plus a price in runs.")
            bad += 1
        if done.get("DIS-null", {}).get("stop") != "BOUND-MET" or gu.get("stop") != "BUDGET":
            print("  *** DIS-null (tau resolved) and DIS-unres (tau UNRESOLVED) must "
                  "diverge: the resolved row earns BOUND-MET, the unresolved row must "
                  "NOT -- it keeps running.  Got %s / %s."
                  % (done.get("DIS-null", {}).get("stop"), gu.get("stop")))
            bad += 1
        for frag, why in (
                ("tau UNRESOLVED", "the campaign does not report which rows could not "
                                   "claim their N_eff"),
                ("PRICE, not a failure", "the campaign does not say an unresolved tau "
                                         "is a price rather than a failure"),
                ("22 usable run", "the campaign does not quote the runs needed")):
            if frag not in out:
                print("  *** %s -- an unclaimable dividend the operator cannot see is "
                      "an unclaimable dividend forever." % why)
                bad += 1
        if not quiet:
            print("      DIS-unres  tau UNRESOLVED -> N_eff not claimed -> keeps "
                  "running to BUDGET (the early BOUND-MET the over-credit would have "
                  "stolen); price surfaced as >=22 runs/inv")

        # Every invocation must carry a FRESH seed base (seed0 + i*stride) and the
        # adaptive knobs -- replayed seeds would double-count R_eff -- and it must
        # carry the REMAINING budget.  HET_RUNS_MAX is how a budget of 100 becomes ten
        # invocations of 10 rather than ten of 100: unchecked, the last invocation of a
        # nearly-spent row could overshoot its budget by a whole invocation, and the
        # per-class cut (Allowed rows get ALLOWED_BUDGET, not BOUND_BUDGET) would be
        # arithmetic nobody ever ran.  Each STUB_RUNNER line reports R = STUB_R.
        for t in tests:
            log = os.path.join(corpus, t, "seeds.log")
            budget = (ALLOWED_BUDGET if done.get(t, {}).get("cls") == "Allowed"
                      else BOUND_BUDGET)
            with open(log) as fh:
                for line in fh:
                    inv, seed, adaptive, runs_max = line.split()
                    want_seed = 777 + (int(inv) - 1) * SEED_STRIDE
                    if int(seed) != want_seed or adaptive != "1":
                        print("  *** %s invocation %s: HET_SEED=%s (want %d), "
                              "HET_ADAPTIVE=%s" % (t, inv, seed, want_seed, adaptive))
                        bad += 1
                    want_max = budget - STUB_R * (int(inv) - 1)
                    if int(runs_max) != want_max:
                        print("  *** %s invocation %s: HET_RUNS_MAX=%s, want %d "
                              "(%s budget %d minus the %d runs already spent).  The "
                              "harness is being told to run past the budget the "
                              "campaign is accounting for."
                              % (t, inv, runs_max, want_max,
                                 done.get(t, {}).get("cls", "?"), budget,
                                 STUB_R * (int(inv) - 1)))
                        bad += 1
        if not quiet:
            print("      HET_RUNS_MAX curtails each invocation to the REMAINING "
                  "budget (Allowed rows %d, %d, %d; bound rows %d, %d, ...)"
                  % (ALLOWED_BUDGET, ALLOWED_BUDGET - STUB_R,
                     ALLOWED_BUDGET - 2 * STUB_R, BOUND_BUDGET,
                     BOUND_BUDGET - STUB_R))
        if not os.path.exists(state):
            print("  *** no campaign state written")
            bad += 1

        # FAIL CLOSED: a test with no oracle class must kill the campaign (rc=2).
        r2 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--control-map", cmap,
             "--runner", "true", "--tests", "GHOST"],
            capture_output=True, text=True)
        if r2.returncode != 2:
            print("  *** a test with NO oracle class exited %d, want 2 (fail "
                  "closed: what would its stop rule MEAN?)" % r2.returncode)
            bad += 1
        elif not quiet:
            print("      unmapped test fails the campaign closed (rc=2)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if bad:
        print("\nSCHEDULER FAILED: %d problem(s)." % bad)
        return 1
    print("\nSCHEDULER OK -- campaign.py behaves as it is written, which is still "
          "class-keyed (Allowed sweep first; fire-once stops at the sighting; a "
          "corroborated sighting stops the campaign loudly) and no longer mirrors "
          "het_verdict.h's classless rule.  The pooled bound crosses p_goal at "
          "exactly the predicted invocation; seeds are fresh per invocation.")
    return 0


# ---------------------------------------------------------------------------
# PHASE 2b -- THE ARM A REGISTERED-NO-ORACLE BUILD ACTUALLY TAKES.  The sentence a
# row that co-runs nothing prints depends on HET_NO_CONTROL_MAP, which the emitter
# stamps only for a pair with no oracle, so the default build above can never reach
# it.  Compiled a second time with the stamp to read it -- and with a HET_PAIR_NAME
# of its own, because the same build is what proves the two sentences name the PAIR
# and not the oracle-source string.
NCM_PAIR = "(TESTISA, testdialect)"


def phase2b(header_dir, tmp, quiet):
    print("\n===== PHASE 2b: what a pair with NO CONTROL MAP prints =====")
    sub = tempfile.mkdtemp(prefix="statsncm.", dir=tmp)
    try:
        out = _compile_and_run(header_dir, sub,
                               defines=["HET_NO_CONTROL_MAP=1",
                                        'HET_PAIR_NAME="%s"' % NCM_PAIR])
    except _CompileFailed as e:
        print(e.out + e.err)
        print("  *** the header does not compile with HET_NO_CONTROL_MAP=1")
        return 1
    blocks, cur, buf = {}, None, []
    for l in out:
        if l.startswith("PRINT-BEGIN|"):
            cur, buf = l.split("|", 1)[1], []
        elif l.startswith("PRINT-END|"):
            blocks[cur] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(l)
    txt = blocks.get("no-control-map-fired-3-of-10-is-SOMETIMES-and-is-NOT-the-canary", "")
    bad = 0
    for frag, why in (
            ("NO POSITIVE-CONTROL MAP WAS READ for " + NCM_PAIR,
             "it does not say a map was never read, or does not name the pair"),
            ("Nothing marks this row a canary",
             "it does not say the row is unmarked"),
            ("It gets NO BOUND, and that is an OMISSION, not a construction",
             "it calls a gap we have not closed a property of the design"),
            # ...and WHICH omission.  The map is loaded for every lane, so the
            # flag says the FILE was not beside the test; a note that blamed a
            # registry would send a reader looking for a row to add.
            ("the map is looked for BESIDE THE TEST",
             "it does not say where the map was looked for"),
            ("what was omitted is the map FILE beside this test",
             "it does not say WHICH omission the missing bound came from")):
        if frag not in txt:
            print("  *** the no-control-map note %s" % why)
            bad += 1
        elif not quiet:
            print("      %s" % frag[:96])
    for frag in ("IS the Layer-B canary", "by construction, not by omission",
                 "no map is registered for that pair", "there is none to borrow"):
        if frag in txt:
            print("  *** the no-control-map note still says %r" % frag)
            bad += 1
    # ... and the SELF-canary row keeps its own sentence in this same build: the
    # define is a property of the pair, not a switch that rewrites every row.
    self_txt = blocks.get("self-canary-fired-3-of-10-is-SOMETIMES-not-ALWAYS", "")
    if "it IS the Layer-B canary" not in self_txt:
        print("  *** HET_NO_CONTROL_MAP=1 also silenced the genuine self-canary "
              "note -- the two states are keyed on the same thing again")
        bad += 1
    if bad:
        print("\nNO-CONTROL-MAP PROSE FAILED: %d problem(s)." % bad)
        return 1
    print("\nNO-CONTROL-MAP PROSE OK (its own sentence, naming the pair, calling "
          "the missing bound an omission; the self-canary note untouched)")
    return 0


# ---------------------------------------------------------------------------
def run(header_dir, tmp, quiet):
    try:
        out = _compile_and_run(header_dir, tmp)
    except _CompileFailed as e:
        print(e.out + e.err)
        print("\nSTATSCHECK FAILED: the statistics layer does not compile")
        return 1
    rc = phase1(out, quiet)
    rc |= phase2(out, quiet)
    rc |= phase2b(header_dir, tmp, quiet)
    rc |= phase5_stops(out, quiet)
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true",
                    help="prove this gate FAILS when the mechanism it guards breaks")
    a = ap.parse_args()
    if a.bite:
        return bite()

    tmp = tempfile.mkdtemp(prefix="statscheck.")
    try:
        hdir = emit_harness(tmp)
        print("  header : %s" % os.path.join(hdir, "het_verdict.h"))
        rc = run(hdir, tmp, a.quiet)
        rc |= phase3(hdir, tmp, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= phase4()
    rc |= phase6_campaign(a.quiet)

    print("\n" + "=" * 70)
    if rc:
        print("STATSCHECK: FAIL")
    else:
        print("STATSCHECK: PASS  (estimator + tau + aggregate + producer + corpus "
              "+ stopping rule + scheduler)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: every injection below is a way this layer could ship a constant while
# compiling cleanly and passing every structural gate.  Each is verified to have
# actually CHANGED the file (one that matched nothing would pass for free) and each
# must drive the gate to a NONZERO exit.
# ---------------------------------------------------------------------------
def _subst(s, pairs):
    """Apply (find, replace) pairs, FAILING LOUDLY if any `find' matched nothing.
    _bite only checks that the header changed OVERALL, which a two-fragment injection
    satisfies with one fragment matched and the other silently dropped -- half an
    injection that still reports "BITES"."""
    for a, b in pairs:
        if a not in s:
            raise SystemExit("statscheck bite: injection fragment not found in the "
                             "emitted header -- the header moved under the bite: %r"
                             % a[:70])
        s = s.replace(a, b)
    return s


def _bite(label, hdir, mutate):
    hp = os.path.join(hdir, "het_verdict.h")
    with open(hp) as fh:
        orig = fh.read()
    new = mutate(orig)
    if new == orig:
        print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
        return False
    sub = tempfile.mkdtemp(prefix="statsbite.")
    try:
        # phase3 derives the test name from the directory basename: keep it.
        test = os.path.basename(hdir)
        bdir = os.path.join(sub, test)
        os.makedirs(bdir)
        shutil.copy(os.path.join(hdir, test + ".cu"), bdir)
        with open(os.path.join(bdir, "het_verdict.h"), "w") as fh:
            fh.write(new)
        rc = run(bdir, sub, quiet=True)
        rc |= phase3(bdir, sub, quiet=True)
    finally:
        shutil.rmtree(sub, ignore_errors=True)
    if rc:
        print("  BITES (gate failed, as it must)   [%s]" % label)
        return True
    print("  *** DID NOT BITE: the gate PASSED on a broken layer   [%s]" % label)
    return False


def bite():
    print("===== B7 BITE TEST: does this gate FAIL when the statistics break? =====")
    tmp = tempfile.mkdtemp(prefix="statsbite.")
    ok = True
    try:
        hdir = emit_harness(tmp)

        # (1) F_hat FORCED TO 1: the layer still compiles, still prints a bound and
        # still calls itself dispersion-aware, while reporting the textbook rule of
        # three on an overdispersed channel.
        ok &= _bite("the Fano factor forced to 1 (the bound becomes the textbook 3)",
                    hdir,
                    lambda s: s.replace("  return v / m;\n", "  return 1.0;\n"))

        # (2) THE DEGENERACY GUARD DISABLED: a constant-read decoder artefact could
        # then forge a CORROBORATED sighting out of an artefact that never varied.
        ok &= _bite("the degeneracy guard disabled (a constant read can forge a "
                    "corroborated sighting)", hdir,
                    lambda s: s.replace(
                        "static int het_cell_degenerate(const het_obs_record *r) {",
                        "static int het_cell_degenerate(const het_obs_record *r) {\n"
                        "  if (r) return 0;"))

        # (3) THE KS GATE MADE CONSTANT-PASS: stationarity is never tested and P_rep
        # is reported across a rate change, which Kirkham's own data says to expect.
        ok &= _bite("the KS gate made constant-pass (stationarity never tested)", hdir,
                    lambda s: s.replace("  return (D <= *Dcrit_out) ? 1 : 0;\n",
                                        "  return 1;\n"))

        # (4) THE r->inf LIMIT DRIFTS: mu_upper returns 3.0 instead of ln(20)=2.9957,
        # a plausible-looking simplification that restores the hard-coded constant.
        ok &= _bite("mu_upper's Poisson limit hard-coded back to 3.0", hdir,
                    lambda s: s.replace("  const double L = -log(0.05);        /* ln 20"
                                        " = 2.99573227... */",
                                        "  const double L = 3.0;"))

        # ---- the tau / N_eff machinery ------------------------------------------
        # (7) TAU FORCED TO 1 -- "every window is independent".  Every run would claim
        # the full HET_NWIN effective samples and every bound would tighten ~128x on
        # evidence that does not support it.
        ok &= _bite("tau forced to 1 (every window claimed independent)", hdir,
                    lambda s: s.replace(
                        "  if (wlen < 2 || nwin < wlen) return -1.0;",
                        "  if (wlen < 2 || nwin < wlen) return -1.0;\n"
                        "  return 1.0;"))

        # (8) THE [1, wlen] CLAMPS DELETED: an anti-correlated stream's raw tau < 1
        # then credits more independent samples than the stream has windows.
        ok &= _bite("the tau clamps deleted (N_eff can exceed the resolution)", hdir,
                    lambda s: s.replace(
                        "  if (tau < 1.0) tau = 1.0;\n"
                        "  if (tau > (double)wlen) tau = (double)wlen;\n"
                        "  return tau;",
                        "  return tau;"))

        # (9) THE EXHAUSTION CAP DELETED: a regime longer than the window returns a
        # truncated partial sum, i.e. an under-read of tau and an over-credit of N_eff.
        # Only the AR(1) ceiling check can see it -- the Python mirror computes the
        # same truncated sum, so the differential is blind to it by construction.
        ok &= _bite("the never-decorrelated cap deleted (tau under-read at the "
                    "boundary)", hdir,
                    lambda s: s.replace(
                        "  if (exhausted) return (double)wlen;",
                        "  if (0 && exhausted) return (double)wlen;"))

        # (10) THE DIVIDEND DROPPED FROM THE DENOMINATOR: R_eff relapses to R/DEFF
        # while tau and N_eff still print plausibly.  Note the asymmetry -- N_eff = 1 as
        # a MEASURED outcome (tau at cap) is the contained conservative case and must
        # PASS; N_eff = 1 as a WIRING CONSTANT is a dead mechanism and must FAIL.
        ok &= _bite("N_eff dropped from R_eff (the dividend silently un-collected)",
                    hdir,
                    lambda s: s.replace(
                        "    st->R_eff    = (double)st->R_usable * st->N_eff / deff;",
                        "    st->R_eff    = (double)st->R_usable / deff;"))

        # (11) THE CORROBORATION GUARD GUTTED: one un-reproduced sighting would stop
        # the row and bank a sighting nothing reproduced.
        ok &= _bite("the stop rule confirms on ONE sighting (an unreproduced "
                    "sighting banked)", hdir,
                    lambda s: s.replace(
                        "  if (st.tier == HET_SIGHT_CORROBORATED) "
                        "return HET_CAMPAIGN_STOP_CONFIRMED;",
                        "  if (st.k > 0) return HET_CAMPAIGN_STOP_CONFIRMED;"))

        # (11b) THE CORROBORATION BAR MOVED: HET_CORROB_RUNS is what both sides of
        # the tier fixtures are sized from and what the MIRROR| line pins, so a
        # header that quietly raises it must redden by NAME.
        ok &= _bite("the corroboration bar raised (HET_CORROB_RUNS 2 -> 3)", hdir,
                    lambda s: s.replace("#define HET_CORROB_RUNS 2",
                                        "#define HET_CORROB_RUNS 3"))

        # (11c) THE RECORD STAMP STOPS BEING CHECKED: het_stats_compute reuses
        # het_verdict() per cell, so an unstamped stream would score as a live one
        # and the aggregate would report a bound over memset zeros.
        ok &= _bite("rec_magic no longer fails closed inside the aggregate", hdir,
                    lambda s: s.replace("  if (r->rec_magic != HET_REC_MAGIC) {",
                                        "  if (0) {"))

        # ---- the tau RELIABILITY guard -----------------------------------------
        # (12) THE GUARD DELETED: an unresolvable tau is believed anyway.  Geyer IPS
        # under-reads it, so the returned tau sits BELOW the cap, TAU_AT_CAP does not
        # fire, and N_eff is credited ~2.4x too high with nothing flagged.
        ok &= _bite("the tau reliability guard deleted (an unresolvable tau is "
                    "believed, and OVER-credits N_eff)", hdir,
                    lambda s: s.replace(
                        "      if ((double)nwin < HET_TAU_MIN_SAMPLES * st->tau_w) {",
                        "      if (0) {"))

        # (13) THE GUARD FORCED ALWAYS-ON -- the opposite failure, and just as dead.
        # N_eff pinned at 1 on EVERY channel throws the dividend away and brings back
        # the 1,500-30,000-run budgets (B7b-impl-brief.md), with nothing "wrong".
        ok &= _bite("the tau guard forced always-on (a sixth constant: B7b silently "
                    "reverted to B7)", hdir,
                    lambda s: s.replace(
                        "      if ((double)nwin < HET_TAU_MIN_SAMPLES * st->tau_w) {",
                        "      if (1) {"))

        # (14) THE PRICE SILENCED: the flag still fires and the arithmetic is right,
        # but tau_runs_needed returns 0 so the printout cannot say what resolving tau
        # would COST.  TAU_UNRESOLVED then reads as "give up" rather than "run more
        # runs", and the guard becomes a veto.
        ok &= _bite("the runs-needed price silenced (the signal becomes a veto)", hdir,
                    lambda s: s.replace(
                        "static int het_tau_runs_needed(double tau_w) {\n  double need;",
                        "static int het_tau_runs_needed(double tau_w) {\n  double need;\n"
                        "  if (tau_w > 0.0) return 0;"))

        # ---- THE STRUCTURAL INVARIANTS ------------------------------------------
        # This family of assertions guards structure the shipped header enforces
        # unconditionally -- a clamp, a conjunct, a dedup, a flag -- so no injection
        # above can redden one of them, and an assertion never seen to fail is not
        # evidence that it is compared.  Each injection below deletes the ONE line
        # that makes one of them true.

        # (17) THE RUN DEDUP DELETED: several cells of ONE run then count as several
        # runs, so sightings from a single thermal/phase draw corroborate each
        # other -- a sighting "corroborated" by itself.
        ok &= _bite("the run dedup deleted (cells of ONE run corroborate each other)",
                    hdir,
                    lambda s: _subst(s, [(
                        "        for (j = 0; j < nruns; j++) "
                        "if (runs[j] == recs[i].run_id) seen = 1;",
                        "        for (j = 0; j < nruns; j++) if (0) seen = 1;")]))

        # (18) THE P_rep DECODE GUARD DELETED: where every sighting was rejected by
        # the degeneracy guard, 1 - e^{-0} = 0 is then reported as "P_rep = 0.00%",
        # which reads as "never reproduces" when it means "no clean cell to estimate
        # from" -- a number that walks into a table as evidence of the opposite.
        ok &= _bite("the P_rep k_eff>0 conjunct deleted (an ABSENCE printed as 0.00%)",
                    hdir,
                    lambda s: _subst(s, [("    if (st->ks_pass && st->k_eff > 0)",
                                          "    if (st->ks_pass)")]))

        # (19) THE tau FLOOR AND THE N_eff CEILING DELETED TOGETHER.  Either alone is
        # invisible -- the tau floor keeps N_eff <= HET_NWIN, and the N_eff ceiling
        # re-clamps whatever the tau floor lets past -- so only removing both can show
        # the [1, HET_NWIN] assertion is live.  An anti-correlated stream then claims
        # 512 independent samples from 128 windows.
        ok &= _bite("the tau floor AND the N_eff ceiling deleted (N_eff exceeds the "
                    "stream's own resolution)", hdir,
                    lambda s: _subst(s, [
                        ("  if (tau < 1.0) tau = 1.0;\n", ""),
                        ("        if (st->N_eff > (double)HET_NWIN)  "
                         "st->N_eff = (double)HET_NWIN;\n", "")]))

        # (20) THE "NO BOUND WITHOUT A MEASURED DISPERSION" CONJUNCT DELETED: a null
        # whose control stream desynced then still gets a bound -- computed from the
        # DEFAULT r -> inf, i.e. the textbook 3/N, reported as though it had been
        # measured.  That is the exact substitution this whole layer exists to refuse.
        ok &= _bite("the FANO_UNMEASURED conjunct deleted (a bound from a dispersion "
                    "that was never measured)", hdir,
                    lambda s: _subst(s, [(
                        "  if (st->obs == HET_OBS_NEVER && "
                        "!(st->flags & HET_ST_FANO_UNMEASURED)) {",
                        "  if (st->obs == HET_OBS_NEVER) {")]))

        # (21) THE TRUNCATION STOPS SAYING IT TRUNCATED: the tail is still discarded
        # (the clamp stays, so nothing overruns), but nothing records that the bound
        # was computed from fewer runs than the campaign paid for.
        ok &= _bite("the CELLS_TRUNCATED flag dropped (a silently shortened campaign)",
                    hdir,
                    lambda s: _subst(s, [(
                        "  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;\n"
                        "                                 st->flags |= "
                        "HET_ST_CELLS_TRUNCATED; }",
                        "  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS; }")]))

        # ---- THE PYTHON MIRRORS -------------------------------------------------
        # (22)-(24) Move a mirrored macro in the header and leave statscheck's Python
        # copy behind.  Every fixture here sits far from these boundaries, so NOTHING
        # ELSE in the gate changes: without the MIRROR| comparison each of these is a
        # green run on a mirror that no longer describes the header.
        ok &= _bite("HET_THETA_DISTINCT moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_THETA_DISTINCT 2",
                                          "#define HET_THETA_DISTINCT 3")]))
        ok &= _bite("HET_TAU_HOT moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_TAU_HOT 30",
                                          "#define HET_TAU_HOT 31")]))
        ok &= _bite("HET_STATS_MAX_CELLS moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_STATS_MAX_CELLS 128",
                                          "#define HET_STATS_MAX_CELLS 129")]))

        # ---- THE KNOWN-OPEN ESCAPE WITNESS, BOTH DIRECTIONS ---------------------
        # check_f8_escape_witness pins the current over-crediting behaviour, so it must
        # FAIL both (15) when the escape DISAPPEARS -- the guard made
        # non-self-referential, the alternative F8-decision.md rejected -- and (16) when
        # the over-credit is MIS-PINNED.  Both drive the real compiled header.
        print("\n-- F8 escape witness (the known-open self-referential escape) --")

        # (15) THE ESCAPE REMOVED: with a 50*HET_NWIN threshold the guard fires here
        #      (1280 < 6400) and N_eff falls to 1, so the witness's precondition and its
        #      over-credit assertion must both catch it -- the witness repurposed as the
        #      fix's bite, made executable.
        f8dir = tempfile.mkdtemp(prefix="statsf8bite.")
        try:
            with open(os.path.join(hdir, "het_verdict.h")) as fh:
                horig = fh.read()
            hnew = horig.replace(
                "if ((double)nwin < HET_TAU_MIN_SAMPLES * st->tau_w) {",
                "if ((double)nwin < HET_TAU_MIN_SAMPLES * (double)HET_NWIN) {")
            if hnew == horig:
                print("  *** VACUOUS BITE: the guard-threshold injection matched NOTHING")
                ok = False
            else:
                with open(os.path.join(f8dir, "het_verdict.h"), "w") as fh:
                    fh.write(hnew)
                if check_f8_escape_witness({F8_ESCAPE_CASE: _escape_got(f8dir)},
                                           quiet=True) > 0:
                    print("  BITES (gate failed, as it must)   [the guard made "
                          "non-self-referential -> the escape vanishes -> witness fires]")
                else:
                    print("  *** DID NOT BITE   [the escape witness passed a fixed guard]")
                    ok = False
        finally:
            shutil.rmtree(f8dir, ignore_errors=True)

        # (16) THE OVER-CREDIT MIS-PINNED: same real header, pinned expectation
        #      corrupted to 3x, proving the pin is compared rather than decorative.
        if check_f8_escape_witness({F8_ESCAPE_CASE: _escape_got(hdir)}, quiet=True,
                                   neff_expect=F8_NEFF_EXPECT * 3.0) > 0:
            print("  BITES (gate failed, as it must)   [the over-credit pin corrupted "
                  "-> the witness rejects it]")
        else:
            print("  *** DID NOT BITE   [a corrupted over-credit pin passed]")
            ok = False

        # THE TWO NO-CONTROL STATES CONFLATED AGAIN.  This is the shipped defect in
        # its simplest form: infer "this row IS the Layer-B canary" from "no record
        # has a control", which is true of EVERY harness of a pair with no control
        # map.  The numbers do not move -- both states take the same denominator --
        # so nothing but the flag and the sentence can see it.
        print("\n-- the self-canary inference --")
        ok &= _bite("the self-canary test dropped (anything that co-runs nothing is "
                    "called the canary)", hdir,
                    lambda s: _subst(s, [
                        ('      if (recs[0].canary_name && recs[0].test_name\n'
                         '          && strcmp(recs[0].canary_name, recs[0].test_name) == 0)\n',
                         '      if (1)\n')]))
        # ... and the reverse: a genuine self-canary row demoted to the no-map state,
        # which would report a gap in the instrumentation where the design has none.
        ok &= _bite("the self-canary test made unsatisfiable (a real canary row "
                    "reported as having no control map)", hdir,
                    lambda s: _subst(s, [
                        ('      if (recs[0].canary_name && recs[0].test_name\n'
                         '          && strcmp(recs[0].canary_name, recs[0].test_name) == 0)\n',
                         '      if (0)\n')]))

        # (5) THE WINDOW BUMP DELETED FROM THE PRODUCER: het_win_of still exists and
        # the aggregate still computes, but the sub-tallies never move, so every
        # dispersion number is fiction.  Only phase 3 can see this.
        print("\n-- producer injection (the sub-tallies themselves) --")
        sub = tempfile.mkdtemp(prefix="statsbite.")
        try:
            test = os.path.basename(hdir)
            bdir = os.path.join(sub, test)
            os.makedirs(bdir)
            shutil.copy(os.path.join(hdir, "het_verdict.h"), bdir)
            with open(os.path.join(hdir, test + ".cu")) as fh:
                cu = fh.read()
            new = re.sub(r"\{ _rec\.control_target_count\+\+; "
                         r"_rec\.control_win\[het_win_of\(_f, SIZE_OF_TEST\)\]\+\+; \}",
                         "_rec.control_target_count++;", cu)
            if new == cu:
                print("  *** VACUOUS BITE: the window-bump injection matched NOTHING")
                ok = False
            else:
                with open(os.path.join(bdir, test + ".cu"), "w") as fh:
                    fh.write(new)
                rc = phase3(bdir, sub, quiet=True)
                if rc:
                    print("  BITES (gate failed, as it must)   "
                          "[the per-window bump deleted from the recovery scan]")
                else:
                    print("  *** DID NOT BITE   [the per-window bump deleted]")
                    ok = False
        finally:
            shutil.rmtree(sub, ignore_errors=True)

        # (6) THE EMITTER STOPS TAGGING THE DECODE CHANNEL: the guard would read a
        # structurally-zero skew_stddev as "degenerate" on the 11 store-only tests and
        # pin their P_rep at a constant 0.  Only phase 4 can see this.
        print("\n-- corpus injection --")
        rc = phase4(tamper=lambda t, s: s.replace("_rec.obs_valid = 1;\n", ""))
        if rc == 1:
            print("  BITES (gate failed, as it must)   "
                  "[the emitter stopped tagging the observer decode channel]")
        else:
            print("  *** DID NOT BITE (rc=%d)   [obs_valid dropped]" % rc)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 70)
    if ok:
        print("BITE OK: all 29 injections were caught -- 4 against the B7")
        print("         ESTIMATOR/RULE, 7 against the B7b tau/N_eff/stop machinery")
        print("         (including the corroboration bar and the record stamp),")
        print("         3 against the B7c reliability guard (deleted / always-on /")
        print("         price silenced -- both directions AND the signal), 5 against")
        print("         the STRUCTURAL INVARIANTS (run dedup, the P_rep decode")
        print("         conjunct, the tau/N_eff clamps, the unmeasured-dispersion")
        print("         conjunct, the truncation flag),")
        print("         3 against the PYTHON MIRRORS (THETA_D / TAU_HOT / MAX_CELLS")
        print("         moved under them), 2 against the B7c/F8 known-open escape")
        print("         witness (the escape removed AND the over-credit mis-pinned),")
        print("         2 against the SELF-CANARY INFERENCE (both directions: a row")
        print("         that co-runs nothing called the canary, and a real canary")
        print("         demoted), 1 against the PRODUCER (the sub-tallies), 1 against")
        print("         the EMITTED CORPUS.")
        print("         The gate is live both ways: it passes on the shipped code and")
        print("         fails on every way of breaking it.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


if __name__ == "__main__":
    sys.exit(main())
