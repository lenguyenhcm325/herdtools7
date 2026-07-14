#!/usr/bin/env python3
"""HetLitmus B7 -- the STATISTICS gate.

het_stats_compute() (het_verdict.h) is what turns a "Never" into a BOUND.  It has
exactly the shape of a mechanism that can compile, pass every structural gate, and
quietly report the same number forever:

  * a bound whose Fano factor silently defaults to 1 reports the TEXTBOOK rule of
    three (p < 3/N) while calling itself dispersion-aware.  On a channel whose real
    Fano is ~20 that is a ~6x OPTIMISTIC OVERCLAIM -- it would make every
    non-observation in the thesis look six times stronger than it is;
  * a KS gate that "passes" on an all-zero control stream has tested nothing;
  * a degeneracy guard that never fires cannot stop a decoder artefact from forging
    a MISMATCH, and a false MISMATCH is a FALSE REFUTATION of the compound model --
    the most damaging error this campaign can make;
  * per-window sub-tallies that are dead make every dispersion number fiction.

This is the fifth time this project has had to gate against "compiles, passes, does
nothing" (the constant-true `_cond', the constant-false `_weak' on 266/338, B4's
dead-code-eliminated stress, B6a's constant-0 exhaustive_valid).  So, like
verdictcheck.py, this gate COMPILES THE REAL HEADER -- the one litmus7 emits into
every harness, not a copy free to drift -- and drives it, in four phases:

  PHASE 1 -- THE ESTIMATOR (closed form)
    mu_upper(r) = r*(0.05^{-1/r} - 1) is pinned against the closed form to 1e-9 at
    r in {0.5, 1, 2, 5, 10, inf}, with the three anchors that matter:
        r -> inf (Poisson) = 2.996   <- the textbook "3"
        r = 1 (geometric)  = 19.0
        r = 0.5            = 199.5
    An r -> inf limit that drifts would silently restore the rule of three.

  PHASE 2 -- THE AGGREGATE (synthetic record streams, differential vs Python)
    Every statistic is recomputed independently in Python from the same synthetic
    cells and compared to 1e-9, and every branch is asserted REACHABLE: Poisson-like,
    BURSTY, KS-pass, KS-SPLIT, VOID, Never, Sometimes, Always, degenerate-rejected,
    window-desync, no-decode-channel, canary-calibrated, both MISMATCH tiers.
    A statistic that cannot vary is not a statistic.

  PHASE 3 -- THE PRODUCER, LIVE BOTH WAYS (the D1/D2 discipline)
    The per-window sub-tallies are produced by the recovery scan, and a tally that is
    always 0 and a tally that is always 1 are equally worthless.  The scan is PURE
    HOST C over host buffers, so this phase EXTRACTS the real emitted control scan
    and runs it on planted buffers -- no GPU, no coherence, no memory-model claim,
    just the decoder:
        OFF    (zero buffers)              -> total 0, every window 0
        SPREAD (hits across the whole run) -> total > 0, sum(win) == total, many
                                              buckets nonzero
        EARLY  (hits only in the first half-window) -> ALL the mass in window 0
    EARLY is the sharp one: it proves het_win_of() actually MAPS a frame to its
    window instead of returning a constant, which "sum(win) == total" alone would
    not catch.

  PHASE 4 -- THE EMITTED CORPUS
    All 338 harnesses carry the post-pass and a decode channel, with a census
    (316 sync / 72 observer / 0 NEITHER; 336 window bumps -- the 2 `self' canary rows
    co-run no control by construction).  A guard that branches on a field the emitter
    never sets is worthless.

  PHASE 5 -- B7b: THE STOPPING RULE AND THE SCHEDULER
    het_campaign_should_stop() is driven from synthetic records (every stop reason
    must be REACHABLE, and the false-refutation guard must hold: one Disallowed
    sighting never stops a test -- it escalates it), and hetlitmus/campaign.py is
    run end-to-end against a STUB runner: the Allowed sweep is scheduled first,
    fire-once rows stop at the first clean sighting, bound rows pool R_eff across
    invocations and stop at --p-goal or budget, every invocation gets a FRESH
    HET_SEED, and a test with no oracle class fails the whole campaign closed.

  B7b -- what changed in the estimator phases.  B7 collapsed each run to ONE
  Bernoulli bit, paying the burstiness penalty (F_win widens mu_upper, 3 -> 19)
  without collecting the burstiness dividend.  B7b adds the integrated
  autocorrelation time tau (Geyer 1992 initial-positive-sequence, het_tau_ips) of
  the per-window control stream and discounts instead of discarding:
  N_eff = HET_NWIN/tau_w in [1, HET_NWIN], R_eff = R_usable * N_eff / DEFF.  So:
    * PHASE 1 now also pins het_tau_ips against the AR(1) CLOSED FORM
      tau = (1+rho)/(1-rho) at rho in {0, 0.5, 0.9, 0.99} (this is why the task is
      dev-box-doable: the statistics need no GPU), plus the two clamps -- a regime
      longer than the window saturates AT the cap (never a truncated under-read),
      and an anti-correlated stream floors at 1 (never more samples than windows);
    * PHASE 2 differentially checks tau_w/N_eff/R_eff, asserts the dividend is
      COLLECTIBLE end-to-end (a white channel must recover N_eff >> 1), and pins
      CONTAINMENT: in the tau-at-cap regime N_eff = 1 and the bound must equal
      B7's run-level number EXACTLY -- a correct implementation contains B7 as its
      conservative special case.

Usage:  statscheck.py [-q]          run the gate
        statscheck.py --bite        prove the gate FAILS when the mechanism breaks
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

# The emitted-corpus census (measured; see the B7 hand-off).  316 tests carry a
# synchrony decode, 72 an observer decode (50 carry both), and NONE carries neither --
# which is what lets the degeneracy guard switch channel instead of firing blind.
CENSUS_SYNC, CENSUS_OBS, CENSUS_NEITHER = 316, 72, 0
CENSUS_WINBUMP = 336        # 338 - the 2 `self' canaries (a test cannot control itself)
CENSUS_TESTS = 338

LN20 = -math.log(0.05)      # 2.99573227355399...
R_POISSON = 1e9
KS_C05 = 1.358
NWIN = 128                  # must match HET_NWIN (raised 32 -> 128 by B7b; swept)
THETA_D = 2                 # must match HET_THETA_DISTINCT
TAU_HOT = 30                # must match HET_TAU_HOT

TOL = 1e-9

# The AR(1) recovery bands (PHASE 1).  tau_true = (1+rho)/(1-rho).  The fixtures are
# deterministic (fixed LCG), so these bands are wide enough to be robust to a change
# of seed, not tuned to one draw; the known IPS truncation bias on finite windows
# (a few % low at moderate rho) is inside them.  wlen=2048 x 16 runs.
AR1_BANDS = [
    # rho,  tau_true, lo,    hi
    (0.00,   1.00,    1.00,  1.30),
    (0.50,   3.00,    2.30,  3.70),
    (0.90,  19.00,   13.00, 25.00),
    (0.99, 199.00,  140.00, 280.00),
]


# ---------------------------------------------------------------------------
# THE PYTHON REFERENCE.  Deliberately an INDEPENDENT re-derivation from the closed
# forms, not a transcription of the C -- a bug transcribed into both would pass.
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
# Disallowed run whose mu(T) fired; each case perturbs a few fields, so each isolates
# exactly one reason.  (Same construction as verdictcheck.py, on purpose.)
# ---------------------------------------------------------------------------
BASE = dict(
    test_name='"synthetic"',
    het_oracle="ORACLE_DISALLOWED",
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
    nwin=NWIN,        # B7b: the realised window resolution rides in the record
)

# ---------------------------------------------------------------------------
# THE SYNTHETIC WINDOW STREAMS.
#
# Each RUN gets its OWN stream, because real runs do: 10 identical copies of one
# hand-picked stream is not a sample, it is one sample counted ten times, and it makes
# the across-cell Fano identically 0 and the KS wildly over-sensitive (the pooled ECDF
# collapses onto a handful of repeated values).  The first draft of this gate did
# exactly that and the KS correctly rejected its own "Poisson" fixture.
#
# The RNG is a hand-rolled LCG rather than `random` or numpy: the gate must produce the
# same fixtures on every machine and every Python version, or its reference numbers are
# not auditable.
# ---------------------------------------------------------------------------
class _Rng:
    def __init__(self, seed):
        self.s = seed & 0x7FFFFFFF

    def u(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / float(0x7FFFFFFF)


def _poisson(rng, lam):
    """Knuth.  Var == Mean, so F -> 1: the regime Kirkham ASSUMES."""
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.u()
        if p <= L:
            return k
        k += 1


def poisson_stream(rng, lam=10.0):
    return [_poisson(rng, lam) for _ in range(NWIN)]


def bursty_stream(rng, lam=10.0, nb=16, span=4):
    """The SAME mean rate, delivered in BURSTS -- a productive CPU/GPU alignment window
    emits many sightings, then a long dry spell (Q1 2e; PerpLE Fig.12's wide, drifting
    skew).  This is the regime Q3 predicts on real C2C, and it lands near Q3's headline
    example: Fano ~ 10, so the rule-of-three constant 3 inflates toward ~19 -- the
    "~6x optimistic overclaim" a bare p < 3/N would commit.

    B7b: a burst is a TIME INTERVAL, so it spans `span` consecutive windows -- a
    single-bucket burst would be an artefact of the fixture, and at a fine HET_NWIN it
    concentrates the marginal (F_win explodes, r_hat -> 0, mu_upper -> 1e9) instead of
    doing what a real burst does under refinement: raise the window-to-window
    correlation.  Spanned bursts land the fixture where the two instruments factor the
    physics -- multiplicity in F_win (numerator), adjacency in tau_w (denominator)."""
    w = [0] * NWIN
    for _ in range(nb):
        start = int(rng.u() * NWIN) % NWIN
        for j in range(span):
            w[(start + j) % NWIN] += _poisson(rng, lam * NWIN / (nb * span))
    return w


def drift_stream(rng, lo=2.0, hi=40.0):
    """A rate that CHANGES mid-run: Kirkham's Vega-LB analogue ("around iteration count
    7 million the rate jumps").  The KS gate must REJECT this."""
    return ([_poisson(rng, lo) for _ in range(NWIN // 2)]
            + [_poisson(rng, hi) for _ in range(NWIN // 2)])


def ramp_cells(nrun=10):
    """B7b: the TAU-AT-CAP regime -- every window of run r carries the same count,
    but the level differs across runs (a skew regime that outlives the run: within a
    run nothing decorrelates, so relative to the GLOBAL mean every lag's products
    stay positive, the IPS never finds a non-positive pair, and tau saturates at the
    ceiling).  This is the brief's honest failure mode made concrete: one run IS one
    alignment draw, N_eff = 1, and the bound must collapse to B7's EXACTLY."""
    return [[5 * (r + 1)] * NWIN for r in range(nrun)]


def negacf_cells(rng, nrun=10, rho=-0.6):
    """B7b: an ANTI-correlated count stream -- AR(1) with rho < 0, rounded to
    counts.  True tau = (1+rho)/(1-rho) = 0.25 < 1: the floor must clamp it to 1
    so N_eff lands EXACTLY at NWIN -- a stream of NWIN windows can never claim
    MORE than NWIN independent samples.  (An AR(1), not a bare alternator: an
    exactly-periodic phase-locked fixture has pair sums +1/n at every lag -- an
    artefact no counts process produces -- which reads as never-decorrelating
    and caps instead of flooring.)"""
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
# 100 runs of the same Poisson channel.  The bound MUST tighten with R -- if it does
# not, R_eff is not in the formula and the "bound" is a constant wearing a fraction.
POISSON_CELLS_100 = [poisson_stream(_R) for _ in range(100)]


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


def observed(cells_, k, clean=True):
    """Make the first k cells SEE the target (optionally in a degenerate decode)."""
    for i in range(k):
        cells_[i]["target_count_exhaustive"] = 7
        cells_[i]["target_count_heuristic"] = 7
        if not clean:
            cells_[i]["distinct_decoded_iters"] = 1     # the constant-read artefact
            cells_[i]["skew_stddev"] = 0.0
    return cells_


CASES = []


def case(name, cells_, **want):
    CASES.append(dict(name=name, cells=cells_, want=want))


# ============================ THE CASE SET =================================
# --- NEVER, with a measured dispersion: the thesis's validation claim -------
case("never-poisson", stream(POISSON_CELLS),
     obs="Never", ks="pass", flags_none=["BURSTY", "FANO_UNMEASURED"])

# THE CASE THAT PROVES THE BOUND IS NOT A CONSTANT.  Same null, same effort, same mean
# rate -- only the ARRIVAL PATTERN differs -- and the numerator must WIDEN materially.
# If mu_upper here equals the Poisson 2.996, the "dispersion-aware" bound is the
# textbook rule of three in a hat and every non-observation in the thesis is
# overclaimed ~6x.
#
# B7b changed what R = 10 buys on this channel.  Under B7 this exact case went
# VACUOUS (p >= 1: ten one-bit runs bound nothing against a bursty channel).  The
# bursts are heavy but WINDOW-LOCAL (adjacent windows are nearly independent), so
# tau_w ~ 1, each run carries ~NWIN effective samples, and the same ten runs now
# yield a real bound -- the penalty (wide mu_upper) is still paid, the dividend
# (N_eff) is finally collected.  This is the brief's headline arithmetic in one case.
case("never-bursty", stream(BURSTY_CELLS),
     obs="Never", flags_any=["BURSTY"],
     flags_none=["FANO_UNMEASURED", "BOUND_VACUOUS", "TAU_UNMEASURED"])

# THE BOUND MUST SCALE WITH R.  Same channel, 10x the runs -> the bound must tighten by
# ~10x.  A hardcoded R_eff would leave it unchanged, and a "bound" that does not move
# when you do ten times the work is a constant with a fraction bar through it.  This is
# also Q3's F4 in one line: the remedy for a weak null is MORE RUNS, not a bigger N.
case("bound-tightens-with-R", stream(POISSON_CELLS_100),
     obs="Never", flags_none=["FANO_UNMEASURED", "BOUND_VACUOUS"])

# Under-dispersion (F<1) must clamp UP to the Poisson floor, never tighten below it.
# (A flat stream also has zero variance in time, so tau is unmeasurable there and
# N_eff stays 1 -- the same one-directional rule on the other axis.)
case("never-underdispersed-clamps-to-poisson", stream(FLAT_CELLS),
     obs="Never", flags_any=["UNDERDISPERSED", "TAU_UNMEASURED"], mu_upper=LN20,
     N_eff=1.0)

# --- B7b: THE TWO ENDS OF THE N_eff SCALE -----------------------------------
# TAU AT THE CAP -- the brief's honest failure mode, and THE CONTAINMENT CASE.
# Every window of a run carries one level (the alignment regime outlives the run),
# so the stream never decorrelates in view: tau_w saturates at HET_NWIN, N_eff = 1,
# and the bound must equal B7's run-level number EXACTLY -- phase 2 pins
# p_bound == mu_upper / (R_usable / DEFF) to 1e-9.  "force N_eff = R -> the gate
# must still pass": a correct implementation CONTAINS the conservative special
# case.  (The across-run spread also blows up F_cell here, so the bound goes
# vacuous -- which keeps BOUND_VACUOUS reachable now that the bursty case no
# longer is.)
case("never-tau-at-cap-is-B7-exactly", stream(RAMP_CELLS),
     obs="Never", flags_any=["TAU_AT_CAP", "BOUND_VACUOUS"],
     flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED"],
     tau_w=float(NWIN), N_eff=1.0)

# THE FLOOR / CEILING CLAMP -- an ANTI-correlated stream has raw tau < 1, which
# would credit MORE independent samples than the stream has windows.  The clamp
# must pin tau to 1 and N_eff to EXACTLY NWIN, never above.
case("never-neg-acf-clamps-Neff-to-NWIN", stream(NEGACF_CELLS),
     obs="Never", flags_none=["FANO_UNMEASURED", "TAU_UNMEASURED", "TAU_AT_CAP"],
     tau_w=1.0, N_eff=float(NWIN))

# --- STATIONARITY ----------------------------------------------------------
# A control rate that CHANGES mid-run.  KS must REJECT, and P_rep must be suppressed
# even though the target WAS seen: "never report P_rep across a non-stationary
# boundary" (Q3 R4; Kirkham's own precheck already fails 4/18 GPU-only).  The stream
# rides the CANARY channel, because an oracle-Allowed test has no mu(T) by construction.
case("ks-split-rejects-and-suppresses-Prep",
     observed(stream(DRIFT_CELLS, chan="canary", het_oracle="ORACLE_ALLOWED",
                     control_compiled_in=0, control_target_count=0), 4),
     obs="Sometimes", ks="SPLIT", flags_any=["NONSTATIONARY"], P_rep=-1.0)

# --- OBSERVED: P_rep at the (instance,run) unit, from k_eff -----------------
case("sometimes-Prep-from-cells-not-frames",
     observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"), 3),
     obs="Sometimes", ks="pass", P_rep=1.0 - math.exp(-3.0), k=3, k_eff=3)

case("always", observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"), 10),
     obs="Always", k=10)

# --- VOID: a dead harness bounds nothing -----------------------------------
case("void-when-every-cell-is-cold",
     stream(ZERO_CELLS, canary_target_count=0),
     obs="VOID", p_bound=-1.0, flags_any=["FANO_UNMEASURED", "KS_UNDERPOWERED"])

# --- THE DEGENERACY GUARD (TRAP 3) -----------------------------------------
# Seen in 3 cells, but every decode was CONSTANT (Srivastava's artefact): k=3 but
# k_eff=0, so it CANNOT corroborate -- and it is REPORTED, never suppressed.
# P_rep must be NOT REPORTED (-1), never the 1-e^0 = 0 that reads as "never reproduces".
case("degenerate-sightings-rejected-but-reported",
     observed(stream(POISSON_CELLS), 3, clean=False),
     obs="Sometimes", k=3, k_eff=0, n_degen=3, P_rep=-1.0,
     flags_any=["DEGEN_SIGHTING"], tier="MISMATCH-UNCORROBORATED")

# The 22 store-only (2+2W) tests decode through the OBSERVER, not a synchrony read.  If
# the guard read skew_stddev on them it would call every cell degenerate FOREVER --
# k_eff constant 0, P_rep a constant 0, on 22 tests.  BOTH arms must be live:
case("observer-channel-clean",
     observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED",
                     sync_valid=0, obs_valid=1, observer_unique_count=900,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     obs="Sometimes", k=3, k_eff=3, flags_none=["DEGEN_SIGHTING"])

case("observer-channel-degenerate",
     observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED",
                     sync_valid=0, obs_valid=1, observer_unique_count=1,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     obs="Sometimes", k=3, k_eff=0, flags_any=["DEGEN_SIGHTING"])

# No decode channel at all: FAIL CLOSED (0 of 338 today -- reaching it is a build bug).
case("no-decode-channel-fails-closed",
     observed(stream(POISSON_CELLS, sync_valid=0, obs_valid=0,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     k=3, k_eff=0, flags_any=["NO_DECODE_CHANNEL", "DEGEN_SIGHTING"])

# --- THE CORROBORATION TIER (TRAP 3) ---------------------------------------
case("mismatch-confirmed-3-clean-runs", observed(stream(POISSON_CELLS), 3),
     obs="Sometimes", tier="MISMATCH-CONFIRMED", k_runs=3)

case("mismatch-uncorroborated-1-run", observed(stream(POISSON_CELLS), 1),
     obs="Sometimes", tier="MISMATCH-UNCORROBORATED", k_runs=1)

# --- THE SELF-PROVING INVARIANT --------------------------------------------
# The window bump sits on the same line as the count, so sum(win) == total.  If the
# bump were dead-code-eliminated the total would be NONZERO and the windows ALL ZERO.
# That must VOID the dispersion, not silently fall back to Poisson.
case("window-desync-voids-the-bound",
     stream(ZERO_CELLS, control_target_count=500),
     obs="Never", p_bound=-1.0, flags_any=["WIN_DESYNC", "FANO_UNMEASURED"])

# --- CALIBRATION PROVENANCE ------------------------------------------------
# 322 of 338 have no mu(T) by construction; their dispersion comes from the Layer-B
# canary -- a DIFFERENT shape's burstiness.  A weaker claim, so it must be flagged.
case("canary-calibrated-when-no-mutant",
     stream(POISSON_CELLS, chan="canary", het_oracle="ORACLE_ALLOWED",
            control_compiled_in=0, control_target_count=0),
     obs="Never", flags_any=["CTRL_IS_CANARY"], flags_none=["FANO_UNMEASURED"])

# --- THE SELF-CANARY SELECTION EFFECT ---------------------------------------
# MP-{cg,gc}-sys-relaxed ARE the Layer-B canary and co-run no control (a test cannot
# control itself, B6b).  So a run in which they did NOT fire is COLD and is discarded,
# and "usable cells" is DEFINED BY firing: the survivors are tautologically the ones
# that fired.  Classifying over usable cells would report ALWAYS for a canary that fired
# in 3 runs of 10 -- and THAT RATE is what the rest of the campaign is calibrated
# against.  The denominator must be R.  (It also gets NO BOUND: nothing independent to
# calibrate dispersion or stationarity against.)
case("self-canary-fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(ZERO_CELLS, het_oracle="ORACLE_ALLOWED",
                     control_compiled_in=0, canary_compiled_in=0,
                     control_target_count=0, canary_target_count=0), 3),
     obs="Sometimes", k=3, k_eff=3, R_usable=3,
     flags_any=["SELF_CONTROL", "FANO_UNMEASURED", "KS_UNDERPOWERED"],
     P_rep=-1.0, p_bound=-1.0)

# --- ALLOWED / NO-ORACLE nulls still get a bound (a different CLAIM, same maths) ---
case("allowed-unobserved-gets-an-observability-bound",
     stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"),
     obs="Never", flags_none=["FANO_UNMEASURED"])
case("no-oracle-unobserved-gets-a-characterization-bound",
     stream(POISSON_CELLS, het_oracle="ORACLE_NONE"),
     obs="Never", flags_none=["FANO_UNMEASURED"])


# ===================== PHASE 5a: THE STOPPING RULE ==========================
# het_campaign_should_stop() decides where the GH200 hours go, so every reason it
# can give must be REACHABLE (a rule that always answers the same thing schedules
# nothing) and the two guards that protect the science must hold: a single
# Disallowed sighting ESCALATES (never stops -- an uncorroborated refutation must
# not be banked), and a degenerate-only sighting never de-schedules an Allowed row.
STOPS = []


def stop(name, cells_, budget, p_goal, want):
    STOPS.append(dict(name=name, cells=cells_, budget=budget, p_goal=p_goal,
                      want=want))


stop("allowed-clean-sighting-stops",
     observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"), 1),
     20, -1.0, "OBSERVED")
stop("allowed-degenerate-sighting-does-not-stop",
     observed(stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"), 1, clean=False),
     20, -1.0, "CONTINUE")
stop("allowed-cold-runs-to-budget",
     stream(POISSON_CELLS, het_oracle="ORACLE_ALLOWED"),
     10, -1.0, "BUDGET")
stop("disallowed-one-sighting-escalates-not-stops",
     observed(stream(POISSON_CELLS), 1),
     20, 0.05, "CONTINUE")
stop("disallowed-corroborated-stops",
     observed(stream(POISSON_CELLS), 3),
     20, -1.0, "CONFIRMED")
stop("disallowed-null-stops-at-p-goal",
     stream(POISSON_CELLS),
     20, 0.05, "BOUND-MET")
stop("disallowed-null-without-goal-runs-to-budget",
     stream(POISSON_CELLS),
     10, -1.0, "BUDGET")
# A VACUOUS bound must not satisfy ANY goal -- even an absurdly generous one.
stop("vacuous-bound-never-meets-a-goal",
     stream(RAMP_CELLS),
     20, 1e6, "CONTINUE")
stop("no-oracle-null-stops-at-p-goal",
     stream(POISSON_CELLS, het_oracle="ORACLE_NONE"),
     20, 0.05, "BOUND-MET")
# ORACLE_UNSET fails closed: no early stop can be earned by an untagged harness.
stop("unset-oracle-fails-closed-to-budget",
     stream(POISSON_CELLS, het_oracle="ORACLE_UNSET"),
     10, 0.05, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(cells_):
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

    def usable(c):
        # Mirrors het_verdict()'s COLD-INVALID: a sighting is never cold; otherwise the
        # harness must be hot (mu(T) or canary >= tau) with the liveness fields alive.
        if c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0:
            return True
        hot_c = c["control_compiled_in"] and c["control_target_count"] >= TAU_HOT
        hot_k = c["canary_compiled_in"] and c["canary_target_count"] >= TAU_HOT
        return bool(hot_c or hot_k)

    k = k_eff = n_degen = R_usable = 0
    runs, win, cellv = [], [], []
    desync = False
    for c in cells_:
        u = usable(c)
        if u:
            R_usable += 1
        y = c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0
        if y:
            k += 1
            if degenerate(c):
                n_degen += 1
            else:
                k_eff += 1
                if c["run_id"] not in runs:
                    runs.append(c["run_id"])
        if sum(ctrl_win(c)) != ctrl_total(c):
            desync = True
        if u:
            cellv.append(float(ctrl_total(c)))
            win.extend(float(x) for x in ctrl_win(c))

    # THE SELF-CANARY SELECTION EFFECT.  For the 2 `self' rows (which co-run no control
    # at all) "usable" is DEFINED BY firing, so classifying over usable cells would
    # report ALWAYS for a canary that fired in 3 runs of 10 -- and that rate is what the
    # whole campaign is calibrated against.  Their denominator is R.
    self_control = not any(c["control_compiled_in"] or c["canary_compiled_in"]
                           for c in cells_)
    denom = n if self_control else R_usable
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

    # B7b: tau on the same stream's temporal axis; N_eff = NWIN/tau in [1, NWIN].
    # Unmeasured (or a dead stream) leaves N_eff = 1: each run is one trial, the
    # B7 reading -- the conservative special case a correct implementation contains.
    tau_w, N_eff = -1.0, 1.0
    if not unmeasured:
        tau_w = py_tau_ips(win, NWIN, mean)
        if tau_w > 0.0:
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
    # k_eff > 0 is load-bearing: 1 - e^0 = 0 would print "P_rep = 0.00%", which reads
    # as "never reproduces" when it means "no clean cell to estimate from".
    if obs in ("Sometimes", "Always") and ks == 1 and k_eff > 0:
        P_rep = 1.0 - math.exp(-float(k_eff))

    p_bound = -1.0
    mu_up = R_eff = 0.0
    if obs == "Never" and not unmeasured:
        deff = F_cell if F_cell > 1.0 else 1.0
        R_eff = R_usable * N_eff / deff       # B7b: the dividend, collected
        mu_up = py_mu_upper(r_hat)
        if R_eff > 0.0:
            p_bound = mu_up / R_eff

    tier = "none"
    if cells_[0]["het_oracle"] == "ORACLE_DISALLOWED" and k > 0:
        tier = "MISMATCH-CONFIRMED" if len(runs) >= 3 else "MISMATCH-UNCORROBORATED"

    return dict(obs=obs, k=k, k_eff=k_eff, k_runs=len(runs), n_degen=n_degen,
                R_usable=R_usable, F_win=F_win, F_cell=F_cell, r_hat=r_hat,
                mu_upper=mu_up, tau_w=tau_w, N_eff=N_eff, R_eff=R_eff,
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
  printf("CASE|%s|%s|%d|%d|%d|%d|%d|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%s|%.12g|%s|0x%x\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.k_runs, st.n_degen,
         st.R_usable, st.F_win, st.F_cell,
         (st.r_hat >= HET_R_POISSON) ? INFINITY : st.r_hat,
         st.mu_upper, st.tau_w, st.N_eff, st.R_eff, st.p_bound, st.P_rep,
         (st.flags & HET_ST_KS_UNDERPOWERED) ? "underpowered"
           : (st.ks_pass ? "pass" : "SPLIT"),
         st.ks_D, het_tier_name(st.tier), st.flags);
  printf("PRINT-BEGIN|%s\n", name);
  het_stats_print(stdout, &st);
  printf("PRINT-END|%s\n", name);
}

/* PHASE 5a -- B7b: the campaign stopping rule, from the same synthetic records. */
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
  /* R3, the campaign budget.  p_min MUST be unset in the shipped header -- the het
     hit-rate is unpublished, and any number here would be imported from the wrong
     experiment (Bagchi's 0.2% is GPU-only inter-CTA).  UNSET must return NOT SIZED. */
  printf("BUDGET|%.17g|%.17g|%.17g|%.17g\n",
         (double)HET_P_MIN,                     /* must be 0 = UNSET in the shipped hdr */
         het_budget_runs((double)HET_P_MIN, 1.0),   /* -> -1 (not sized)                */
         het_budget_runs(0.002, 1.0),               /* a rate: the Poisson budget        */
         het_budget_runs(0.002, 20.0));             /* ... dispersion-inflated 20x       */
}

/* PHASE 1b -- B7b: het_tau_ips against streams whose tau is KNOWN.
   An AR(1) process x_{t+1} = rho*x_t + u_t has the closed form
   tau = (1+rho)/(1-rho), independent of the noise distribution -- so the
   estimator can be validated on the dev box with no GPU at all: if it cannot
   recover a known tau here, nothing it reports on GH200 means anything.
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
  /* THE CEILING: tau_true = 199 read through 128-window runs never decorrelates
     in view; the estimator must saturate AT the cap (a truncated partial sum
     would under-read tau and over-credit N_eff -- the forbidden direction). */
  ar1_case("cap", 0.99, 128, 16);
  /* THE FLOOR: anti-correlated (tau_true = 0.33) must clamp to 1 -- a stream of
     wlen windows can never claim more than wlen independent samples. */
  ar1_case("floor", -0.5, 128, 16);
}

int main(void) {
  anchors();
  ar1();
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


def emit_harness(tmp, test="MP-cg-sys-fence-2s"):
    """Emit a REAL harness and return its directory (header + scan both come from it)."""
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    subprocess.run(["litmus7", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
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


FLAGS = ["FANO_UNMEASURED", "NONSTATIONARY", "DEGEN_SIGHTING", "UNDERDISPERSED",
         "BURSTY", "NO_DECODE_CHANNEL", "WIN_DESYNC", "KS_UNDERPOWERED",
         "CELLS_TRUNCATED", "CTRL_IS_CANARY", "BOUND_VACUOUS", "SELF_CONTROL",
         "TAU_UNMEASURED", "TAU_AT_CAP"]
FLAG_BIT = {f: 1 << i for i, f in enumerate(FLAGS)}


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
            # het_win_of must MAP.  A constant would make every sighting land in one
            # bucket and the Fano would be measuring nothing.
            if not (int(w0) == 0 and int(wmid) == NWIN // 2 and int(wlast) == NWIN - 1):
                print("  *** het_win_of does not map frames to windows: "
                      "0->%s, N/2->%s, N-1->%s (want 0, %d, %d)"
                      % (w0, wmid, wlast, NWIN // 2, NWIN - 1))
                bad += 1
            elif not quiet:
                print("      het_win_of maps 0->0, N/2->%d, N-1->%d (it is not a "
                      "constant)" % (NWIN // 2, NWIN - 1))

    # --- R3: the campaign budget.  p_min is a SYMBOL, not a number, until GH200. ---
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

    # --- B7b: het_tau_ips against KNOWN autocorrelation times.  This is the whole
    # reason the task is dev-box-doable: the statistics need no GPU.  An estimator
    # that cannot recover a known tau here reports nothing but noise on GH200.
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

    if bad:
        print("\nESTIMATOR FAILED: %d problem(s).  A bound whose r->inf limit has "
              "drifted is the rule of three wearing a dispersion-aware hat." % bad)
        return 1
    print("\nESTIMATOR OK (mu_upper matches the closed form to 1e-9 at every r; the "
          "3 -> 19 -> 199.5 inflation is real; het_win_of maps; het_tau_ips "
          "recovers AR(1) tau at every rho and both clamps hold)")
    return 0


def phase2(lines, quiet):
    print("\n===== PHASE 2: is het_stats_compute() a statistic, or a constant? =====")
    bad = 0
    seen_obs, seen_flags, seen_tier, seen_ks = set(), set(), set(), set()
    blocks, cur, buf = {}, None, []
    got = {}

    for l in lines:
        if l.startswith("CASE|"):
            f = l.split("|")
            (_, name, obs, k, k_eff, k_runs, n_degen, R_usable, F_win, F_cell,
             r_hat, mu_up, tau_w, N_eff, R_eff, p_bound, P_rep, ks, ks_D, tier,
             flags) = f
            got[name] = dict(
                obs=obs, k=int(k), k_eff=int(k_eff), k_runs=int(k_runs),
                n_degen=int(n_degen), R_usable=int(R_usable),
                F_win=float(F_win), F_cell=float(F_cell), r_hat=float(r_hat),
                mu_upper=float(mu_up), tau_w=float(tau_w), N_eff=float(N_eff),
                R_eff=float(R_eff), p_bound=float(p_bound),
                P_rep=float(P_rep), ks=ks, ks_D=float(ks_D), tier=tier,
                flags=int(flags, 16))
            seen_obs.add(obs)
            seen_tier.add(tier)
            seen_ks.add(ks)
            for fl, bit in FLAG_BIT.items():
                if int(flags, 16) & bit:
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

        # (a') B7b SELF-CONSISTENCY, independent of the mirror: N_eff must be the
        # clamped resolution quotient, and the bound must decompose as
        # mu_upper / (R_usable * N_eff / DEFF) -- a "bound" that does not contain
        # its own denominator is a constant with a fraction bar through it.
        if not (1.0 - TOL <= g["N_eff"] <= NWIN + TOL):
            errs.append("N_eff=%.6g outside [1, %d]" % (g["N_eff"], NWIN))
        if g["p_bound"] >= 0.0:
            deff = g["F_cell"] if g["F_cell"] > 1.0 else 1.0
            want_b = g["mu_upper"] / (g["R_usable"] * g["N_eff"] / deff)
            if not close(g["p_bound"], want_b):
                errs.append("p_bound %.12g != mu_upper/(R*N_eff/DEFF) %.12g"
                            % (g["p_bound"], want_b))
        for fld in ("obs", "k", "k_eff", "k_runs", "n_degen", "R_usable", "ks", "tier"):
            if g[fld] != ref[fld]:
                errs.append("%s: C %s != py %s" % (fld, g[fld], ref[fld]))

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

    want_tier = {"none", "MISMATCH-UNCORROBORATED", "MISMATCH-CONFIRMED"}
    print("  corroboration tiers : %d/%d  (%s)"
          % (len(seen_tier), len(want_tier), ", ".join(sorted(seen_tier))))
    if want_tier - seen_tier:
        print("  *** UNREACHABLE TIER: %s" % ", ".join(sorted(want_tier - seen_tier)))
        bad += 1

    need_flags = {"FANO_UNMEASURED", "NONSTATIONARY", "DEGEN_SIGHTING",
                  "UNDERDISPERSED", "BURSTY", "NO_DECODE_CHANNEL", "WIN_DESYNC",
                  "KS_UNDERPOWERED", "CTRL_IS_CANARY", "BOUND_VACUOUS",
                  "SELF_CONTROL", "TAU_UNMEASURED", "TAU_AT_CAP"}
    print("  diagnostic flags    : %d/%d  (%s)"
          % (len(seen_flags & need_flags), len(need_flags),
             ", ".join(sorted(seen_flags))))
    if need_flags - seen_flags:
        print("  *** UNREACHABLE FLAG: %s -- a diagnostic that never fires is not a "
              "diagnostic" % ", ".join(sorted(need_flags - seen_flags)))
        bad += 1

    # ---- THE OVERCLAIM ASSERTION.  This is the one that matters.
    # "3/N must not appear as a reported bound anywhere unless F_hat was measured and
    # is ~1."  The bursty null and the Poisson null have the SAME effort and the SAME
    # zero -- if their bounds agree, the dispersion is doing nothing.
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

    # THE BOUND MUST MOVE WHEN THE EFFORT DOES.  Ten times the runs on the same channel
    # must tighten the bound ~10x.  If it does not, R_eff is not in the formula.
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

    # ---- B7b: THE DIVIDEND IS COLLECTIBLE, BOTH WAYS.  A white channel must
    # recover a large N_eff end-to-end through het_stats_compute (a mechanism whose
    # output never leaves 1 is B7 with extra arithmetic -- the recurring failure,
    # sixth edition), and the at-cap regime must collapse to exactly 1.
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
    if ne_c != 1.0:
        print("  *** CONTAINMENT BROKEN: the tau-at-cap regime must score N_eff = 1 "
              "exactly (got %.4g)." % ne_c)
        bad += 1

    # ---- B7b: CONTAINMENT -- the brief's own acceptance clause.  In the at-cap
    # regime the corrected bound must equal B7's run-level formula EXACTLY: forcing
    # N_eff to its conservative special case must reproduce B7, or the "correction"
    # changed claims it had no licence to change.
    gc = got.get("never-tau-at-cap-is-B7-exactly", {})
    if gc:
        deff = gc["F_cell"] if gc["F_cell"] > 1.0 else 1.0
        b7 = gc["mu_upper"] / (gc["R_usable"] / deff)
        if not close(gc["p_bound"], b7):
            print("  *** at-cap p_bound %.12g != B7's mu_upper/(R_usable/DEFF) "
                  "%.12g -- the conservative special case is NOT contained"
                  % (gc["p_bound"], b7))
            bad += 1
        elif not quiet:
            print("      containment: at-cap bound == B7's formula to 1e-9 "
                  "(the conservative special case is contained)")

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

        # A REPORTED P_rep OF EXACTLY 0 IS NOT A STATISTIC.  1 - e^{-k_eff} with
        # k_eff = 0 is 0, and "P_rep = 0.00%" reads as "this behaviour never
        # reproduces" when it means "every sighting failed the decode guard, so there
        # is nothing to estimate from".  This one shipped: BOTH the C and the Python
        # reference computed it, so the differential test could not see it -- a bug
        # transcribed into both sides of a cross-check passes it.  Hence a DIRECT
        # assertion, not a comparison.
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
# PHASE 3 -- THE PRODUCER, LIVE BOTH WAYS.
#
# The recovery scan is pure host C over host buffers, so it can be lifted out of the
# emitted harness and run on PLANTED buffers.  No GPU, no coherence, no memory-model
# claim -- this tests the DECODER, which is exactly the class of probe the shared
# charge permits ("compile and, where a probe applies, smoke-run for plumbing only").
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

    # D2 -- OFF.  Zero buffers, nothing recovered, every window zero.
    if not (t0 == 0 and s0 == 0 and nz0 == 0):
        print("  *** OFF: the scan tallied %d hit(s) on ZERO buffers -- the detector "
              "is constant-true" % t0)
        bad += 1

    # D1 -- ON.  A tally that is always zero and a tally that is always one are equally
    # worthless; this is the half that proves the bump RUNS.
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

    # THE MAPPING.  sum(win)==total would still hold if every hit went to bucket 0.
    # Planting only in the first half-window of frames must put ALL the mass in
    # window 0, at any HET_NWIN.
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
def phase4(quiet, tamper=None):
    print("\n===== PHASE 4: does the EMITTED CORPUS carry the B7 machinery? =====")
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    tmp = tempfile.mkdtemp(prefix="statscorpus.")
    n_sync = n_obs = n_neither = n_win = n_stats = n_nwin = n_stop = 0
    tampered = 0
    bad = 0
    try:
        r = subprocess.run(
            ["litmus7", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
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
            # B7b: the realised window resolution must ride in every record (a
            # swept HET_NWIN that the record does not report would silently
            # mis-tune B8), and every harness must carry the adaptive stop.
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
# PHASE 5a -- B7b: THE STOPPING RULE.
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
    want_all = {"CONTINUE", "OBSERVED", "CONFIRMED", "BOUND-MET", "BUDGET"}
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
    print("\nSTOPPING RULE OK (every reason reachable; one Disallowed sighting "
          "escalates instead of stopping; a vacuous bound satisfies no goal; "
          "ORACLE_UNSET earns no early stop)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 5b -- B7b: THE SCHEDULER, END TO END, against a stub runner.
#
# hetlitmus/campaign.py is the piece that actually spends (or saves) the GH200
# hours, and nothing about its policy needs a GPU: the HetStats line is its whole
# interface.  The stub runner below emits deterministic lines per (test,
# invocation), so the pooling arithmetic and the stop decisions can be pinned
# exactly -- e.g. pooled bound 2.9957/(100*i) crosses p_goal=0.01 at EXACTLY the
# third invocation.
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
NULL = "mu_upper=2.9957 tau_w=1.28 N_eff=100 R_eff=100 p_bound=0.029957 P_rep=-1"
if test == "ALW-fires":
    k = 1 if inv >= 2 else 0
    print("HetStats %s oracle=Allowed obs=%s k=%d k_eff=%d k_runs=%d tier=none "
          "mu_upper=0 tau_w=1.28 N_eff=100 R_eff=0 p_bound=-1 P_rep=-1 %s"
          % (test, "Sometimes" if k else "Never", k, k, k, base))
elif test == "ALW-cold":
    print("HetStats %s oracle=Allowed obs=Never k=0 k_eff=0 k_runs=0 tier=none "
          "%s %s" % (test, NULL, base))
elif test == "DIS-null":
    print("HetStats %s oracle=Disallowed obs=Never k=0 k_eff=0 k_runs=0 "
          "tier=none %s %s" % (test, NULL, base))
elif test == "DIS-fires":
    print("HetStats %s oracle=Disallowed obs=Sometimes k=1 k_eff=1 k_runs=1 "
          "tier=MISMATCH-UNCORROBORATED mu_upper=0 tau_w=1.28 N_eff=100 R_eff=0 "
          "p_bound=-1 P_rep=0.632 %s" % (test, base))
elif test == "NOR-null":
    print("HetStats %s oracle=NO-ORACLE obs=Never k=0 k_eff=0 k_runs=0 "
          "tier=none %s %s" % (test, NULL, base))
else:
    sys.exit(3)
'''

CAMPAIGN = os.path.join(ROOT, "hetlitmus", "campaign.py")
SEED_STRIDE = 100003     # must match campaign.py


def phase6_campaign(quiet):
    print("\n===== PHASE 6: does the scheduler spend the hours where the brief "
          "says? =====")
    tmp = tempfile.mkdtemp(prefix="statssched.")
    bad = 0
    try:
        corpus = os.path.join(tmp, "corpus")
        tests = ["ALW-fires", "ALW-cold", "DIS-null", "DIS-fires", "NOR-null"]
        for t in tests:
            os.makedirs(os.path.join(corpus, t))
        cmap = os.path.join(tmp, "control-map.csv")
        with open(cmap, "w") as fh:
            fh.write("ALW-fires,Allowed,-,MP-cg-sys-relaxed\n"
                     "ALW-cold,Allowed,-,MP-cg-sys-relaxed\n"
                     "DIS-null,Disallowed,mu,MP-cg-sys-relaxed\n"
                     "DIS-fires,Disallowed,mu,MP-cg-sys-relaxed\n"
                     "NOR-null,NO-ORACLE,-,MP-cg-sys-relaxed\n")
        stub = os.path.join(tmp, "stub.py")
        with open(stub, "w") as fh:
            fh.write(STUB_RUNNER)
        state = os.path.join(tmp, "state.csv")
        r = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--control-map", cmap,
             "--runner", "%s %s {dir}" % (sys.executable, stub),
             "--p-goal", "0.01", "--budget-runs", "100",
             "--allowed-budget-runs", "30", "--seed0", "777", "--state", state],
            capture_output=True, text=True)
        out = r.stdout

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

        # LEVER 1 -- the schedule: the Allowed sweep runs FIRST (it is both the
        # cheap 6.5x cut and the p_min candidate population).
        if order[:2] != ["ALW-cold", "ALW-fires"] or len(order) != 5:
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
        if "CONFIRMED refutation" not in out:
            print("  *** the CONFIRMED refutation is not called out in the summary")
            bad += 1

        # Every invocation must carry a FRESH seed base (seed0 + i*stride) and the
        # adaptive knobs -- replayed seeds would double-count R_eff.
        for t in tests:
            log = os.path.join(corpus, t, "seeds.log")
            with open(log) as fh:
                for line in fh:
                    inv, seed, adaptive, runs_max = line.split()
                    want_seed = 777 + (int(inv) - 1) * SEED_STRIDE
                    if int(seed) != want_seed or adaptive != "1":
                        print("  *** %s invocation %s: HET_SEED=%s (want %d), "
                              "HET_ADAPTIVE=%s" % (t, inv, seed, want_seed, adaptive))
                        bad += 1
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
    print("\nSCHEDULER OK (Allowed sweep first; fire-once stops at the sighting; "
          "the pooled bound crosses p_goal at exactly the predicted invocation; "
          "a refutation stops the campaign loudly; seeds are fresh per invocation)")
    return 0


# ---------------------------------------------------------------------------
def run(header_dir, tmp, quiet):
    shutil.copy(os.path.join(header_dir, "het_verdict.h"),
                os.path.join(tmp, "het_verdict.h"))
    src = os.path.join(tmp, "st.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(tmp, "st")
    cc = subprocess.run(["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
                         "-I", tmp, src, "-o", exe, "-lm"],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        print(cc.stdout + cc.stderr)
        print("\nSTATSCHECK FAILED: the statistics layer does not compile")
        return 1
    out = subprocess.run([exe], capture_output=True, text=True).stdout.splitlines()
    rc = phase1(out, quiet)
    rc |= phase2(out, quiet)
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
    rc |= phase4(a.quiet)
    rc |= phase6_campaign(a.quiet)

    print("\n" + "=" * 70)
    if rc:
        print("STATSCHECK: FAIL")
    else:
        print("STATSCHECK: PASS  (estimator + tau + aggregate + producer + corpus "
              "+ stopping rule + scheduler)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: THE GATE MUST BITE.
#
# Every injection below is a way this layer could ship a constant while compiling
# cleanly and passing every structural gate.  Each is cmp-verified to have actually
# CHANGED the file (an injection that silently matched nothing "passes" for free --
# that has happened in this project) and each must drive the gate to a NONZERO exit.
# ---------------------------------------------------------------------------
def _bite(label, hdir, mutate, quiet=True):
    hp = os.path.join(hdir, "het_verdict.h")
    with open(hp) as fh:
        orig = fh.read()
    new = mutate(orig)
    if new == orig:
        print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
        return False
    sub = tempfile.mkdtemp(prefix="statsbite.")
    try:
        # phase3 derives the test name from the directory basename, so the bitten copy
        # must keep it.
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

        # (1) F_hat FORCED TO 1.  The layer still compiles, still prints a bound, still
        # calls itself dispersion-aware -- and reports the textbook rule of three on a
        # channel whose real Fano is ~20.  This is THE bug of B7 and the fifth instance
        # of this project's recurring failure.
        ok &= _bite("the Fano factor forced to 1 (the bound becomes the textbook 3)",
                    hdir,
                    lambda s: s.replace("  return v / m;\n", "  return 1.0;\n"))

        # (2) THE DEGENERACY GUARD DISABLED.  A decoder artefact (Srivastava's
        # constant read) could then forge a MISMATCH-CONFIRMED -- a FALSE REFUTATION of
        # the compound model, the most damaging error the campaign can make.
        ok &= _bite("the degeneracy guard disabled (a constant read can forge a "
                    "refutation)", hdir,
                    lambda s: s.replace(
                        "static int het_cell_degenerate(const het_obs_record *r) {",
                        "static int het_cell_degenerate(const het_obs_record *r) {\n"
                        "  if (r) return 0;"))

        # (3) THE KS GATE MADE CONSTANT-PASS.  Stationarity is then never tested, and
        # P_rep is reported across a rate change -- exactly what Kirkham's own data
        # (Vega-@7M) says will happen.
        ok &= _bite("the KS gate made constant-pass (stationarity never tested)", hdir,
                    lambda s: s.replace("  return (D <= *Dcrit_out) ? 1 : 0;\n",
                                        "  return 1;\n"))

        # (4) THE r->inf LIMIT DRIFTS.  mu_upper silently returns 3.0 instead of
        # ln(20)=2.9957 -- a small, plausible-looking "simplification" that reintroduces
        # the hard-coded constant the whole task exists to remove.
        ok &= _bite("mu_upper's Poisson limit hard-coded back to 3.0", hdir,
                    lambda s: s.replace("  const double L = -log(0.05);        /* ln 20"
                                        " = 2.99573227... */",
                                        "  const double L = 3.0;"))

        # ---- B7b: the tau/N_eff machinery ---------------------------------------
        # (7) TAU FORCED TO 1 -- the OPTIMISTIC LIE ("every window is independent").
        # Every run would claim the full HET_NWIN effective samples and every bound
        # would tighten ~128x on evidence that does not support it.  The AR(1)
        # closed-form checks and the differential both catch it.  This is the bite
        # the brief names first, and it MUST fail.
        ok &= _bite("tau forced to 1 (every window claimed independent)", hdir,
                    lambda s: s.replace(
                        "  if (wlen < 2 || nwin < wlen) return -1.0;",
                        "  if (wlen < 2 || nwin < wlen) return -1.0;\n"
                        "  return 1.0;"))

        # (8) THE [1, wlen] CLAMPS DELETED.  An anti-correlated stream's raw tau < 1
        # then credits MORE independent samples than the stream has windows.
        ok &= _bite("the tau clamps deleted (N_eff can exceed the resolution)", hdir,
                    lambda s: s.replace(
                        "  if (tau < 1.0) tau = 1.0;\n"
                        "  if (tau > (double)wlen) tau = (double)wlen;\n"
                        "  return tau;",
                        "  return tau;"))

        # (9) THE EXHAUSTION CAP DELETED.  A regime longer than the window then
        # returns a truncated partial sum (an UNDER-read of tau = an over-credit of
        # N_eff).  Only the AR(1) ceiling check can see this: the pipeline mirror
        # computes the same truncated sum on both sides, so the differential is
        # blind to it by construction -- which is exactly why the closed-form
        # anchors exist.
        ok &= _bite("the never-decorrelated cap deleted (tau under-read at the "
                    "boundary)", hdir,
                    lambda s: s.replace(
                        "  if (exhausted) return (double)wlen;",
                        "  if (0 && exhausted) return (double)wlen;"))

        # (10) THE DIVIDEND DROPPED FROM THE DENOMINATOR -- a silent relapse to B7's
        # R_eff = R/DEFF while tau/N_eff still print plausibly.  NOTE the asymmetry
        # the brief draws: N_eff = 1 as a MEASURED OUTCOME (tau at cap) is the
        # contained conservative case and is tested to PASS (the
        # never-tau-at-cap-is-B7-exactly scenario); N_eff = 1 as a WIRING CONSTANT
        # is a dead mechanism -- the recurring failure -- and must FAIL.
        ok &= _bite("N_eff dropped from R_eff (the dividend silently un-collected)",
                    hdir,
                    lambda s: s.replace(
                        "    st->R_eff    = (double)st->R_usable * st->N_eff / deff;",
                        "    st->R_eff    = (double)st->R_usable / deff;"))

        # (11) THE CORROBORATION GUARD GUTTED.  One un-reproduced sighting would
        # then STOP a Disallowed test and bank an uncorroborated refutation of the
        # CMCM -- the most damaging output the campaign can produce.
        ok &= _bite("the stop rule confirms on ONE sighting (false-refutation "
                    "banked)", hdir,
                    lambda s: s.replace(
                        "    if (st.tier == HET_MT_CONFIRMED) "
                        "return HET_CAMPAIGN_STOP_CONFIRMED;",
                        "    if (st.k > 0) return HET_CAMPAIGN_STOP_CONFIRMED;"))

        # (5) THE WINDOW BUMP DELETED FROM THE PRODUCER.  het_win_of still exists and
        # the aggregate still computes -- but the sub-tallies never move, so every
        # dispersion number is fiction.  Only PHASE 3 can see this.
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

        # (6) THE EMITTER STOPS TAGGING THE DECODE CHANNEL.  The guard would then read
        # a structurally-zero skew_stddev as "degenerate" on 22 store-only tests and
        # make their P_rep a constant 0.  Only PHASE 4 can see this.
        print("\n-- corpus injection --")
        rc = phase4(quiet=True,
                    tamper=lambda t, s: s.replace("_rec.obs_valid = 1;\n", ""))
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
        print("BITE OK: all 11 injections were caught -- 4 against the B7")
        print("         ESTIMATOR/RULE, 5 against the B7b tau/N_eff/stop machinery,")
        print("         1 against the PRODUCER (the sub-tallies), 1 against the")
        print("         EMITTED CORPUS.  The gate is live both ways: it passes on the")
        print("         shipped code and fails on every way of breaking it.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


if __name__ == "__main__":
    sys.exit(main())
