#!/usr/bin/env python3
"""HetLitmus -- the STATISTICS gate for het_stats_compute() (het_verdict.h).

het_stats_compute() says what a "Never" is worth and what a sighting reproduces
at, and every part of it can pass every gate while answering the same thing
forever: a KS gate that "passes" without running tested nothing, and it passes for
free on an all-zero stream -- which would unlock P_rep for a harness where nothing
co-ran.  This gate drives the REAL emitted header, which cannot drift from a copy:

  1 THE INPUTS     het_win_of maps frames to windows rather than returning a
                   constant, and the Python mirrors of the header's knobs are
                   COMPARED to the header instead of assumed.
  2 THE AGGREGATE  every statistic re-derived independently in Python to 1e-9;
                   every class, KS outcome, tier and flag REACHABLE.
  3 THE PRODUCER   the emitted recovery scan, lifted out onto planted buffers.
  4 THE CORPUS     every harness carries the post-pass and a decode channel.
  5/6 SCHEDULING   the stop rule and campaign.py, against a stub runner.

Spec: env-research/Q3-stats.md R1-R6; impl-briefs/B7-impl-brief.md -- both
SUPERSEDED (they design the withdrawn non-observation bound).  Where they and
litmus/het-runtime/het_verdict.h disagree the header is what ships, and what a
null reports now is hetlitmus/docs/00-environment-design.md 3.7.

Usage:  statscheck.py [-q]      run the gate
        statscheck.py --bite    prove the gate FAILS when the mechanism breaks
"""

import argparse
import contextlib
import csv
import io
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

KS_C05 = 1.358
# THE PYTHON MIRRORS OF THE HEADER'S KNOBS.  "Must match" is not a check: no fixture
# straddles the THETA_D or TAU_HOT boundary (the decode counts are 0/1/900/5000, the
# control totals 0/500/~1280), so a header change would keep every comparison's truth
# value and desynchronise the mirror in silence.  All four are therefore EMITTED by the
# C driver and compared in phase 1 -- NWIN on the WIN| line, the rest on MIRROR|.
NWIN = 128                  # must match HET_NWIN (a swept knob, not a constant)
CORROB_RUNS = 2             # must match HET_CORROB_RUNS      (pinned via MIRROR|)
THETA_D = 2                 # must match HET_THETA_DISTINCT   (pinned via MIRROR|)
TAU_HOT = 30                # must match HET_TAU_HOT          (pinned via MIRROR|)
MAX_CELLS = 128             # must match HET_STATS_MAX_CELLS  (pinned via MIRROR|)

TOL = 1e-9


# ---------------------------------------------------------------------------
# THE PYTHON REFERENCE: an independent re-derivation from the definitions, never a
# transcription of the C -- a bug transcribed into both sides would pass the
# differential.
# ---------------------------------------------------------------------------
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
# ten copies of one hand-picked stream is one sample counted ten times, and the
# collapsed ECDF that leaves makes the KS over-sensitive.
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
    """Knuth.  Arrivals that neither clump nor drift -- the plain stationary
    baseline the bursty and drifting streams below are read against."""
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
    This is the regime Q3-stats.md S2.4 predicts on real C2C, and it is STATIONARY --
    the rate does not change across the run, only its arrivals clump -- which is what
    makes it the counter-fixture to drift_stream below.

    A burst is a TIME INTERVAL, so it spans `span` consecutive windows.  A
    single-bucket burst is a fixture artefact: at a fine HET_NWIN it concentrates the
    marginal instead of doing what a real burst does under refinement, which is raise
    the window-to-window correlation."""
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


_R = _Rng(20260714)
POISSON_CELLS = [poisson_stream(_R) for _ in range(10)]
BURSTY_CELLS = [bursty_stream(_R) for _ in range(10)]
DRIFT_CELLS = [drift_stream(_R) for _ in range(10)]
FLAT_CELLS = [[10] * NWIN for _ in range(10)]     # nonzero, but with no variance
ZERO_CELLS = [[0] * NWIN for _ in range(10)]

# ONE RECORD MORE THAN THE AGGREGATE CAN HOLD.  het_stats_compute clamps its record
# array at HET_STATS_MAX_CELLS and the tail is dropped from every statistic; the field
# is producible (hetEmit sizes _recs[NUMBER_OF_RUN] from Cfg.runs, so litmus7 -r above
# 128 hands it more than it can hold), and the ONLY thing that says the aggregate was
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


def observed_at(cells_, idx):
    """Make the cell at idx -- and ONLY it -- see the target, cleanly.  WHERE in the
    stream a sighting lands is what the confirmation window is measured from, so a
    fixture that can only fire at the head cannot drive that window at all."""
    observed(cells_[idx:idx + 1], 1)
    return cells_


CASES = []


def case(name, cells_, **want):
    CASES.append(dict(name=name, cells=cells_, want=want))


# ============================ THE CASE SET =================================
# --- NEVER, on a live control stream: the shape every null in the corpus takes ---
case("never-poisson", stream(POISSON_CELLS),
     obs="Never", ks="pass", flags_none=["CTRL_STREAM_EMPTY"])

# A BURSTY STREAM IS NOT A DRIFTING ONE, and the gate must not confuse them: the same
# mean rate delivered in window-local bursts is stationary, so KS must NOT reject it.
# A gate that rejected here would suppress P_rep on every real C2C channel, where
# arrivals come in bursts (Q3-stats.md S2.4) -- the opposite failure to the drift case
# below, and the reason both are driven.
case("bursty-stream-is-stationary-and-KS-must-not-reject", stream(BURSTY_CELLS),
     obs="Never", ks="pass",
     flags_none=["CTRL_STREAM_EMPTY", "NONSTATIONARY"])

# THE EMPTINESS GUARD'S NEGATIVE SIDE.  A constant stream is degenerate in every way
# a stream can be except the one that matters here: its windows sum to something.  The
# guard is on the SUM and not on the variance, so this must NOT be called empty -- a
# guard that fired here would refuse the KS gate on any channel with a steady rate.
case("flat-nonzero-stream-is-not-an-EMPTY-one", stream(FLAT_CELLS),
     obs="Never", ks="pass", flags_none=["CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"])

# --- STATIONARITY ----------------------------------------------------------
# A control rate that CHANGES mid-run.  KS must REJECT and P_rep be suppressed even
# though the target WAS seen: P_rep is never reported across a non-stationary boundary
# (Q3-stats.md S2.2, R4 -- the KS precheck is mandatory because Kirkham's own data
# already fails it 4/18 GPU-only).  The stream rides the CANARY channel, which is the
# only one a test with no mu(T) has (canary-channel-read-when-no-mutant below).
case("ks-split-rejects-and-suppresses-Prep",
     observed(stream(DRIFT_CELLS, chan="canary",                      control_compiled_in=0, control_target_count=0), 4),
     obs="Sometimes", ks="SPLIT", flags_any=["NONSTATIONARY"], P_rep=-1.0)

# --- OBSERVED: P_rep at the (instance,run) unit, from k_eff -----------------
case("sometimes-Prep-from-cells-not-frames",
     observed(stream(POISSON_CELLS), 3),
     obs="Sometimes", ks="pass", P_rep=1.0 - math.exp(-3.0), k=3, k_eff=3)

case("always", observed(stream(POISSON_CELLS), 10),
     obs="Always", k=10)

# --- VOID: a dead harness measured nothing ---------------------------------
case("void-when-every-cell-is-cold",
     stream(ZERO_CELLS, canary_target_count=0),
     obs="VOID", flags_any=["CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"])

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

# ... and the same price at a LATE position, which is what pins the INDEXING: the
# fifth run of ten fires, so the price is 5 -- the count of runs spent through the
# sighting, one-based, neither the four spent before it nor a run id.  The
# confirmation window is measured from this number (het_verdict.h's stopping rule),
# so an off-by-one here silently shortens or lengthens every window by a run.
case("first-sight-counts-the-runs-spent-through-the-sighting",
     observed_at(stream(POISSON_CELLS), 4),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=5)

# --- THE SELF-PROVING INVARIANT --------------------------------------------
# The window bump sits on the same line as the count, so sum(win) == total.  A total
# that is nonzero with all windows zero means the bump did not run: the stream is not
# the run's history, so the stationarity precheck must be REFUSED rather than run on it.
case("window-desync-refuses-the-stationarity-precheck",
     stream(ZERO_CELLS, control_target_count=500),
     obs="Never", ks="underpowered",
     flags_any=["WIN_DESYNC", "CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"])

# --- WHICH CHANNEL THE PRECHECK READ ---------------------------------------
# 78 of 411 have no mu(T) by construction -- they ARE the lattice floor -- so the
# stationarity precheck reads the Layer-B canary's stream instead.  That canary is the
# het MP floor, so on every shape but MP it is another shape's time structure: a
# weaker claim, hence a flag.
case("canary-channel-read-when-no-mutant",
     stream(POISSON_CELLS, chan="canary",             control_compiled_in=0, control_target_count=0),
     obs="Never", flags_any=["CTRL_IS_CANARY"], flags_none=["CTRL_STREAM_EMPTY"])

# --- A MIXED STAMPED/UNSTAMPED STREAM IS READ AS ITS STAMPED HALF -------------
# Ten stamped cells whose mu(T) is not compiled in, plus two UNSTAMPED cells whose
# control counts are memset residue.  Everything below rec_magic is unreadable, so
# the residue must reach neither the printed mu report nor the choice of calibration
# channel: unguarded it makes mu_total nonzero, which SELECTS mu(T) as the channel --
# and the stamped cells' mu(T) stream is all zeros, so the pooled stream is empty and
# the stationarity precheck is refused.  A wrong number and a refused precheck from
# records nothing may read (het_verdict() stops at the stamp; so does every total here).
MIXED_STAMP_CELLS = (
    stream(POISSON_CELLS, chan="canary", control_compiled_in=0,
           control_target_count=0)
    + stream_runs(POISSON_CELLS[:2], [10, 11], rec_magic=0))
case("unstamped-cells-feed-neither-the-mu-report-nor-the-channel-choice",
     MIXED_STAMP_CELLS,
     obs="Never", R=12, R_usable=10,
     mu_total=0, can_total=sum(sum(w) for w in POISSON_CELLS),
     flags_any=["CTRL_IS_CANARY"], flags_none=["CTRL_STREAM_EMPTY", "WIN_DESYNC"])

# --- THE SELF-CANARY SELECTION EFFECT ---------------------------------------
# MP-{cg,gc}-sys-relaxed ARE the Layer-B canary, so they co-run no control and a run in
# which they did not fire is COLD and discarded: "usable" is then DEFINED BY firing and
# the survivors are tautologically the ones that fired.  Classifying over usable cells
# would report ALWAYS for a canary that fired in 3 runs of 10 -- and that rate is what
# the rest of the campaign is calibrated against -- so the denominator must be R.  They
# also have NO CALIBRATION CHANNEL: nothing independent co-runs to test stationarity
# against, so their P_rep is refused too.
SELF_CANARY = dict(canary_name='"synthetic"',
                   control_compiled_in=0, canary_compiled_in=0,
                   control_target_count=0, canary_target_count=0)
case("self-canary-fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(ZERO_CELLS, **SELF_CANARY), 3),
     obs="Sometimes", k=3, k_eff=3, R_usable=3, frames=10 * 100000,
     flags_any=["SELF_CONTROL", "CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"],
     flags_none=["NO_CONTROL_CORUN"],
     P_rep=-1.0)

# ... AND ONE UNSTAMPED CELL MUST NOT UNDO IT.  The same ten, plus a cell whose
# compiled-in flag is memset residue.  Read, that residue says something co-runs:
# the row stops naming itself the canary, the denominator moves from R to R_usable
# -- where "usable" is defined by firing -- and 3 of 10 is reported as ALWAYS.  Its
# frame count would be added to the effort total on the same pass.  Same answer as
# the case above, to the flag and to the frame, is the whole assertion.
case("self-canary-plus-one-unstamped-cell-is-still-SOMETIMES",
     observed(stream(ZERO_CELLS, **SELF_CANARY), 3)
     + stream_runs([[0] * NWIN], [10], rec_magic=0, control_compiled_in=1),
     obs="Sometimes", k=3, k_eff=3, R=11, R_usable=3, frames=10 * 100000,
     flags_any=["SELF_CONTROL", "CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"],
     flags_none=["NO_CONTROL_CORUN"],
     P_rep=-1.0)

# --- ... AND THE ROW THAT CO-RUNS NOTHING WITHOUT BEING THE CANARY -------------
# Every harness emitted with no control map beside the test looks like this: nothing
# co-runs AND nothing names this row the canary (canary_name is NULL, not the test's
# own name).  The arithmetic is the self-canary one -- "usable" is still defined by
# firing, so the denominator is still R -- but the CLAIM is not: this row is no
# canary, and its missing calibration channel is an omission we have not closed
# rather than a property of the design.  Two flags, so the printout can say which.
case("no-control-map-fired-3-of-10-is-SOMETIMES-and-is-NOT-the-canary",
     observed(stream(ZERO_CELLS,                      control_compiled_in=0, canary_compiled_in=0,
                     control_target_count=0, canary_target_count=0), 3),
     obs="Sometimes", k=3, k_eff=3, R_usable=3,
     flags_any=["NO_CONTROL_CORUN", "CTRL_STREAM_EMPTY", "KS_UNDERPOWERED"],
     flags_none=["SELF_CONTROL"],
     P_rep=-1.0)

# --- A SIGHTING-FREE NULL IS CALIBRATED BY WHAT CO-RAN WITH IT ------------------
# Which channel the precheck reads is a choice, and it must prefer the shape-matched
# one where it exists and fired -- here mu(T), compiled in and hot; the canary half of
# the pair is canary-channel-read-when-no-mutant above.
case("sighting-free-null-reads-its-own-mu-channel",
     stream(POISSON_CELLS),
     obs="Never", flags_none=["CTRL_STREAM_EMPTY", "CTRL_IS_CANARY"])

# --- MORE RUNS THAN THE AGGREGATE CAN HOLD ----------------------------------
# The tail beyond HET_STATS_MAX_CELLS is DROPPED from every statistic (R_usable = 128
# of the 129 supplied), which would quietly report a campaign as having spent less
# effort than it did -- so st->R keeps the PRE-clamp count and the flag says the
# discard happened.
# Production runs at R = 10 per invocation, but campaign.py pools invocations and
# litmus7 -r is an operator knob, so this is reachable in the field and reached here.
case("cells-truncated-above-HET_STATS_MAX_CELLS", stream(POISSON_CELLS_TRUNC),
     obs="Never", R=MAX_CELLS + 1, R_usable=MAX_CELLS,
     flags_any=["CELLS_TRUNCATED"])


# ===================== PHASE 5a: THE STOPPING RULE ==========================
# het_campaign_should_stop() decides where the hardware hours go, so every reason it
# can give must be REACHABLE and every guard must hold at its boundary: a lone clean
# sighting holds the row open (it is not banked) but only as far as the confirmation
# window; a degenerate-only sighting holds nothing open; rate mode disables the
# sighting stop and NOTHING else; and residue from an unstamped record decides
# nothing.  The matrix drives the C rule directly, on synthetic records, with no GPU.
CONFIRM_RUNS = 30           # must match the driver's HET_CONFIRM_RUNS default
STOPS = []


def stop(name, cells_, budget, want, rate=0, confirm=CONFIRM_RUNS):
    STOPS.append(dict(name=name, cells=cells_, budget=budget,
                      want=want, rate=rate, confirm=confirm))


# A LONE clean sighting does NOT stop: one run cannot rule out a per-run artefact,
# so the row keeps running to corroborate.
stop("one-clean-sighting-does-not-stop",
     observed(stream(POISSON_CELLS), 1),
     20, "CONTINUE")
# ... and neither does a degenerate one, at any count: an artefact must never
# de-schedule a test (the branch is on k_eff, not on the tier, which k sets).
stop("degenerate-sightings-never-stop",
     observed(stream(POISSON_CELLS), 3, clean=False),
     20, "CONTINUE")
# The bar is HET_CORROB_RUNS distinct clean RUNS, and it is reached exactly there.
stop("sighting-corroborated-stops",
     observed(stream(POISSON_CELLS), CORROB_RUNS),
     20, "CORROBORATED")
# THE CONFIRMATION WINDOW, AT ITS BOUNDARY.  The same lone sighting in the FIRST of
# ten runs, so nine have elapsed since it: one run short of the window it keeps
# running, at the window it stops -- and UNCONFIRMED-SIGHTING is its own outcome,
# neither a corroboration nor a null.
stop("lone-sighting-below-the-confirm-window-continues",
     observed(stream(POISSON_CELLS), 1),
     20, "CONTINUE", confirm=10)
stop("lone-sighting-at-the-confirm-window-stops-unconfirmed",
     observed(stream(POISSON_CELLS), 1),
     20, "UNCONFIRMED-SIGHTING", confirm=9)
# THE PRECEDENCE, BOTH WAYS.  budget is spent (n >= budget) in both, and neither
# answers BUDGET: while a clean sighting is open the window decides, because a row
# ended at BUDGET here would bank "seen once, stopped looking".  Below the window
# that means CONTINUE -- the caller's own run capacity is what ends the invocation,
# and the row is left unterminated rather than recorded as budget-stopped.
stop("lone-sighting-outranks-the-budget-stop",
     observed(stream(POISSON_CELLS), 1),
     5, "CONTINUE")
stop("the-window-not-the-budget-ends-a-lone-sighting",
     observed(stream(POISSON_CELLS), 1),
     5, "UNCONFIRMED-SIGHTING", confirm=9)
# THE WINDOW IS MEASURED FROM THE SIGHTING, and these three are why it must be.  A
# row whose one sighting lands in its LAST run has spent none of its window yet, so
# it must keep running: closing the window on it hands a sighting zero runs to
# reproduce in and banks the un-reproduced answer.  With the sighting at the fifth
# run of ten the boundary is driven from both sides -- five runs have elapsed since
# it, so a six-run window is still open and a five-run one has just closed.
stop("a-sighting-in-the-last-run-gets-its-window",
     observed_at(stream(POISSON_CELLS), 9),
     20, "CONTINUE", confirm=5)
stop("late-sighting-inside-its-window-continues",
     observed_at(stream(POISSON_CELLS), 4),
     20, "CONTINUE", confirm=6)
stop("late-sighting-past-its-window-stops-unconfirmed",
     observed_at(stream(POISSON_CELLS), 4),
     20, "UNCONFIRMED-SIGHTING", confirm=5)
# RATE MODE (HET_RATE=1) disables the sighting stop and nothing else: the row runs on
# to measure a rate, and its budget still stops it.
stop("rate-mode-does-not-stop-on-a-corroborated-sighting",
     observed(stream(POISSON_CELLS), CORROB_RUNS),
     20, "CONTINUE", rate=1)
stop("rate-mode-still-stops-at-budget",
     observed(stream(POISSON_CELLS), CORROB_RUNS),
     10, "BUDGET", rate=1)
# ... and a LONE sighting under rate mode is a rate to be measured like any other:
# neither the corroboration stop nor the confirmation window applies, so the row
# reaches its budget and is never banked UNCONFIRMED.  (Rate mode is the operator's
# answer to an UNCONFIRMED row, so it must not be able to produce one.)
stop("rate-mode-runs-a-lone-sighting-to-budget",
     observed(stream(POISSON_CELLS), 1),
     10, "BUDGET", rate=1)
stop("cold-row-runs-to-budget",
     stream(POISSON_CELLS),
     10, "BUDGET")
# An UNSTAMPED record earns no early stop: every cell is COLD-INVALID, so there is
# nothing to corroborate, and the row spends its budget.
stop("unstamped-records-fail-closed-to-budget",
     stream(POISSON_CELLS, rec_magic=0),
     10, "BUDGET")
# ... and the same holds when the unstamped stream is FULL OF SIGHTINGS in distinct
# runs.  Every count below rec_magic is then memset residue, so scoring it would let
# a harness the emitter built wrong corroborate itself into CORROBORATED -- the one
# stop that means "nothing further is bought by running this row".
stop("unstamped-sightings-earn-no-corroboration",
     observed(stream(POISSON_CELLS, rec_magic=0), CORROB_RUNS),
     10, "BUDGET")
# A MIXED stream decides from its stamped half alone.  The two unstamped cells are
# SIGHTINGS in distinct runs, so read, the residue alone would corroborate the row and
# stop it -- the one stop that means "nothing further is bought here".  The stamped ten
# are nulls, so the answer is theirs: the row spends its budget.
stop("mixed-stream-is-decided-by-its-stamped-half",
     (stream(POISSON_CELLS, chan="canary", control_compiled_in=0,
             control_target_count=0)
      + observed(stream_runs(POISSON_CELLS[:2], [10, 11], rec_magic=0), 2)),
     12, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(cells_):
    # The record array is CLAMPED at HET_STATS_MAX_CELLS and the tail is dropped from
    # every statistic below; st->R keeps the pre-clamp count so the discard is visible.
    R = len(cells_)
    cells_ = cells_[:MAX_CELLS]
    n = len(cells_)

    def stamped(c):
        # het_verdict() reads no field of a record that does not carry the stamp, so
        # neither does anything derived from one: every total, every count, every
        # calibration sample here is drawn from the stamped cells alone.
        return c["rec_magic"] == "HET_REC_MAGIC"

    mu_present = any(c["control_compiled_in"] for c in cells_ if stamped(c))
    mu_total = sum(c["control_target_count"] for c in cells_ if stamped(c))
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
        # Mirrors het_verdict()'s COLD-INVALID: an unstamped record is cold at step 0;
        # a sighting is never cold; otherwise the harness must be hot (mu(T) or canary
        # >= tau) AND its decode channel live.
        if not stamped(c):
            return False
        if c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0:
            return True
        hot_c = c["control_compiled_in"] and c["control_target_count"] >= TAU_HOT
        hot_k = c["canary_compiled_in"] and c["canary_target_count"] >= TAU_HOT
        return bool((hot_c or hot_k) and channel_live(c))

    def mu_hot(c):
        # het_verdict()'s NOT-OBSERVED-MU-HOT tier, which is what a null names as its
        # voucher: a usable cell that saw nothing and whose OWN mu(T) reached tau_hot
        # with the ground-truth scan behind it.  Everything else usable carries the
        # weaker NOT-OBSERVED-CANARY-ONLY.
        if not usable(c):
            return False
        if c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0:
            return False
        return bool(c["control_compiled_in"]
                    and c["control_target_count"] >= TAU_HOT
                    and c["exhaustive_valid"])

    k = k_eff = n_degen = R_usable = first_sight = n_mu_hot = 0
    runs, allruns, win = [], [], []
    ctrl_pooled = 0
    desync = False
    for c in cells_:
        # THE STAMP GATES EVERY READ.  A cell that does not carry it is residue, and
        # nothing below may see one: not the run tally, not the window sums, not the
        # frames, not the calibration samples.  It is unusable by that same test, so
        # skipping it whole loses nothing but the residue.
        if not stamped(c):
            continue
        u = usable(c)
        if u:
            R_usable += 1
        if mu_hot(c):
            n_mu_hot += 1
        y = c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0
        # Runs consumed so far, over EVERY stamped cell: first_sight is a price in
        # runs, so the denominator is the runs that were actually spent.
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
            ctrl_pooled += sum(ctrl_win(c))
            win.extend(float(x) for x in ctrl_win(c))

    # THE SELECTION EFFECT: wherever nothing co-runs, "usable" is defined by firing,
    # so the denominator is R and not R_usable.  That holds for the `self' canary rows
    # and for every harness of a pair with no control map alike -- the C splits them
    # into two FLAGS, because only one of them is a canary, but not into two
    # denominators (see the two cases of those names).
    nothing_coruns = not any(c["control_compiled_in"] or c["canary_compiled_in"]
                             for c in cells_ if stamped(c))
    denom = R if nothing_coruns else R_usable    # st->R, i.e. PRE-clamp, as in the C
    if R_usable == 0:
        obs = "VOID"
    elif k == 0:
        obs = "Never"
    elif k >= denom:
        obs = "Always"
    else:
        obs = "Sometimes"

    # THE EMPTINESS GUARD, re-derived: fewer than two pooled windows, an all-zero
    # pooled stream, or sub-tallies that do not sum to their totals.  Any of the three
    # and the KS gate below is REFUSED rather than run on nothing.
    stream_empty = (len(win) < 2) or (ctrl_pooled == 0) or desync

    n_early = max(1, (NWIN * 20) // 100)
    n_late = max(1, (NWIN * 10) // 100)
    early, late = [], []
    for i in range(0, len(win) - NWIN + 1, NWIN):
        early.extend(win[i:i + n_early])
        late.extend(win[i + NWIN - n_late:i + NWIN])
    if stream_empty:
        ks, D, Dcrit = -1, 0.0, 0.0
    else:
        ks, D, Dcrit = py_ks2(early, late)

    P_rep = -1.0
    # k_eff > 0 is load-bearing: 1 - e^0 = 0 prints as "P_rep = 0.00%", which reads as
    # "never reproduces" when it means "no clean cell to estimate from".
    if obs in ("Sometimes", "Always") and ks == 1 and k_eff > 0:
        P_rep = 1.0 - math.exp(-float(k_eff))

    tier = "none"
    if k > 0:
        tier = ("CORROBORATED" if len(runs) >= CORROB_RUNS else "UNCONFIRMED")

    return dict(obs=obs, k=k, k_eff=k_eff, k_runs=len(runs), n_degen=n_degen,
                first_sight=first_sight, mu_total=mu_total,
                can_total=sum(c["canary_target_count"]
                              for c in cells_ if stamped(c)),
                frames=sum(c["frames_examined"] for c in cells_ if stamped(c)),
                R=R, R_usable=R_usable, n_mu_hot=n_mu_hot, P_rep=P_rep,
                ks=("underpowered" if ks < 0 else ("pass" if ks else "SPLIT")),
                ks_D=D, tier=tier, stream_empty=stream_empty)


# ---------------------------------------------------------------------------
# The C driver.
# ---------------------------------------------------------------------------
C_MAIN = r"""
/* GENERATED by hetlitmus/verify/statscheck.py -- do not edit. */
#include "het_verdict.h"

static void run_case(const char *name, const het_obs_record *recs, int n) {
  het_stats_t st;
  het_stats_compute(recs, n, &st);
  printf("CASE|%s|%s|%d|%d|%d|%d|%d|%.12g|%s|%.12g|%s|0x%x|%d|%d|%llu|%llu|%llu\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.k_runs, st.n_degen,
         st.R_usable, st.P_rep,
         (st.flags & HET_ST_KS_UNDERPOWERED) ? "underpowered"
           : (st.ks_pass ? "pass" : "SPLIT"),
         st.ks_D, het_sighting_name(st.tier), st.flags,
         /* st.R is the PRE-clamp record count: R > R_usable can mean cold cells,
            R > HET_STATS_MAX_CELLS means the tail was discarded. */
         st.R, st.n_at_first_sight,
         (unsigned long long)st.mu_total, (unsigned long long)st.can_total,
         /* the EFFORT total, summed per cell: what the effort line discloses */
         (unsigned long long)st.frames_examined);
  printf("PRINT-BEGIN|%s\n", name);
  het_stats_print(stdout, &st);
  printf("PRINT-END|%s\n", name);
}

/* PHASE 5a -- the campaign stopping rule, from the same synthetic records.  The
   why-string rides along: it is the one sentence an UNCONFIRMED-SIGHTING stop is
   entitled to, and a sentence nothing checks is a sentence that can go blank. */
static void stop_case(const char *name, const het_obs_record *recs, int n,
                      int budget, int rate_mode, int confirm_runs) {
  het_campaign_stop_t s = het_campaign_should_stop(recs, n, budget,
                                                   rate_mode, confirm_runs);
  printf("STOP|%s|%s|%s\n", name, het_campaign_stop_name(s),
         het_campaign_stop_why(s));
}

/* PHASE 1 -- the inputs the aggregate is built on. */
static void anchors(void) {
  /* het_win_of must MAP, not return a constant. */
  printf("WIN|%d|%d|%d|%d\n", het_win_of(0, 100000), het_win_of(50000, 100000),
         het_win_of(99999, 100000), (int)HET_NWIN);
  /* THE PYTHON MIRRORS, emitted so they can be COMPARED.  Every fixture below sits
     far from the THETA_D and TAU_HOT boundaries -- deliberately, since a fixture at
     the boundary tests the boundary and not the statistic -- so nothing else in this
     gate can notice one of these macros moving under the mirror. */
  printf("MIRROR|%d|%d|%d|%d\n", (int)HET_THETA_DISTINCT, (int)HET_TAU_HOT,
         (int)HET_STATS_MAX_CELLS, (int)HET_CORROB_RUNS);
}

int main(void) {
  anchors();
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
        body.append('    stop_case("%s", stopc%d, %d, %d, %d, %d);'
                    % (s["name"], i, len(s["cells"]), s["budget"],
                       s["rate"], s["confirm"]))
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


# THE BIT NUMBER IS WRITTEN DOWN, not derived from position in this list.  The
# header leaves retired bits vacant (3, 4, 10, 12, 13, 14) because flags=0x... is a
# wire format that archived transcripts and fixtures are already written in, so an
# index-derived map would silently mis-decode every flag above the first hole -- and
# a mis-decode here reads as a passing gate, not as an error.
FLAG_BIT = {
    "CTRL_STREAM_EMPTY":  1 << 0,
    "NONSTATIONARY":      1 << 1,
    "DEGEN_SIGHTING":     1 << 2,
    "NO_DECODE_CHANNEL":  1 << 5,
    "WIN_DESYNC":         1 << 6,
    "KS_UNDERPOWERED":    1 << 7,
    "CELLS_TRUNCATED":    1 << 8,
    "CTRL_IS_CANARY":     1 << 9,
    "SELF_CONTROL":       1 << 11,
    "MIXED_POOL":         1 << 15,
    "NO_CONTROL_CORUN":   1 << 16,
}
FLAGS = sorted(FLAG_BIT, key=FLAG_BIT.get)


def _parse_case_fields(l):
    """Parse one CASE| line from the C driver into (name, stats-dict).  The tuple width
    is the assertion: a column added or dropped in the C without a matching change here
    unpacks short and fails loudly, which no other consumer of this line does."""
    f = l.split("|")
    (_, name, obs, k, k_eff, k_runs, n_degen, R_usable, P_rep, ks, ks_D, tier,
     flags, R, first_sight, mu_total, can_total, frames) = f
    return name, dict(
        obs=obs, k=int(k), k_eff=int(k_eff), k_runs=int(k_runs),
        n_degen=int(n_degen), R=int(R), R_usable=int(R_usable),
        first_sight=int(first_sight), mu_total=int(mu_total),
        can_total=int(can_total), frames=int(frames),
        P_rep=float(P_rep), ks=ks, ks_D=float(ks_D), tier=tier,
        flags=int(flags, 16))


def _compile_and_run(header_dir, workdir, defines=()):
    """Build the C case set in workdir against header_dir's het_verdict.h, run it and
    return its stdout lines.  Raises _CompileFailed if gcc rejects it.

    ONE definition of the copy/emit/compile/run sequence: run() and phase2b()
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


def phase1(lines, quiet):
    print("===== PHASE 1: do the aggregate's INPUTS map, and do the mirrors "
          "hold? =====")
    bad = 0
    for l in lines:
        if l.startswith("WIN|"):
            _, w0, wmid, wlast, nwin = l.split("|")
            if int(nwin) != NWIN:
                print("  *** HET_NWIN is %s, statscheck assumes %d" % (nwin, NWIN))
                bad += 1
            # het_win_of must MAP: a constant would land every sighting in one bucket,
            # and the stream the precheck reads would be that spike rather than the
            # run's history.
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
                 "set of cells as usable, so R_usable and the pooled stream itself"),
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

    if bad:
        print("\nINPUTS FAILED: %d problem(s).  A window map that is a constant puts "
              "every sighting in one bucket, and a stale mirror derives the Python "
              "reference from a different header than the C." % bad)
        return 1
    print("\nINPUTS OK (het_win_of maps frames to windows and is not a constant; the "
          "four mirrored knobs are COMPARED to the header, not assumed)")
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

    refs = {}
    for c in CASES:
        name = c["name"]
        g = got.get(name)
        if g is None:
            print("  *** %s produced no CASE line" % name)
            bad += 1
            continue
        ref = refs[name] = py_reference(c["cells"])
        errs = []

        # (a) DIFFERENTIAL: every statistic, independently re-derived, to 1e-9.
        for fld in ("P_rep", "ks_D"):
            if not close(g[fld], ref[fld]):
                errs.append("%s: C %.12g != py %.12g" % (fld, g[fld], ref[fld]))
        for fld in ("obs", "k", "k_eff", "k_runs", "n_degen", "R", "R_usable", "ks",
                    "tier", "first_sight", "mu_total", "can_total", "frames"):
            if g[fld] != ref[fld]:
                errs.append("%s: C %s != py %s" % (fld, g[fld], ref[fld]))

        # (a') THE EMPTINESS GUARD, on EVERY case rather than on the few that name it.
        # It is the one conjunct standing between an all-zero control stream and a KS
        # "pass" that unlocks P_rep for a harness where nothing ever fired, and the
        # numbers alone cannot show it: a stream nothing was measured on and a stream
        # measured to be flat print the same zeros.
        empty_c = bool(g["flags"] & FLAG_BIT["CTRL_STREAM_EMPTY"])
        if empty_c != ref["stream_empty"]:
            errs.append("CTRL_STREAM_EMPTY=%s but the pooled stream %s empty"
                        % (empty_c, "is" if ref["stream_empty"] else "is NOT"))
        # ... and what it BUYS: refusing the gate, never passing it.  A guard that
        # fires and still lets the KS run has moved a flag and nothing else.
        if ref["stream_empty"] and g["ks"] != "underpowered":
            errs.append("the pooled stream is empty but the KS gate reports %r"
                        % g["ks"])

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
            print("      %-44s obs=%-9s ks=%-12s P_rep=%-9.4g %s"
                  % (name, g["obs"], g["ks"], g["P_rep"],
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

    need_flags = {"CTRL_STREAM_EMPTY", "NONSTATIONARY", "DEGEN_SIGHTING",
                  "NO_DECODE_CHANNEL", "WIN_DESYNC", "KS_UNDERPOWERED",
                  "CELLS_TRUNCATED", "CTRL_IS_CANARY", "SELF_CONTROL",
                  "NO_CONTROL_CORUN"}
    print("  diagnostic flags    : %d/%d  (%s)"
          % (len(seen_flags & need_flags), len(need_flags),
             ", ".join(sorted(seen_flags))))
    if need_flags - seen_flags:
        print("  *** UNREACHABLE FLAG: %s -- a diagnostic that never fires is not a "
              "diagnostic" % ", ".join(sorted(need_flags - seen_flags)))
        bad += 1

    # THE PRINTOUT IS THE DELIVERABLE, NOT THE FLAG.  A null now says in words that
    # no rate and no probability is attached to it, and says what vouches for it
    # instead; a flag nobody reads is not what a reader files the result under.
    for name, g in sorted(got.items()):
        txt = blocks.get(name, "")
        if g["obs"] != "Never":
            continue
        # What vouched is a per-cell fact (het_verdict.h, n_mu_hot), so the clause is
        # pinned against the count of NOT-OBSERVED-MU-HOT cells rather than merely
        # required to exist -- the pooled channel flag cannot stand in for it.
        r = refs.get(name, {})
        nmu, nusable = r.get("n_mu_hot", 0), r.get("R_usable", 0)
        if nmu == nusable:
            vouch = ("vouched for by this test's own mu(T) lattice-floor twin: all %d "
                     "of these cells are NOT-OBSERVED-MU-HOT" % nusable)
        elif nmu == 0:
            vouch = ("vouched for by nothing of this test's own shape: all %d of "
                     "these cells are NOT-OBSERVED-CANARY-ONLY" % nusable)
        else:
            vouch = ("lattice-floor twin on only %d of these cells; the other %d are "
                     "NOT-OBSERVED-CANARY-ONLY" % (nmu, nusable - nmu))
        for frag, why in (
                ("NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
                 "it does not say that nothing is attached to the null"),
                (vouch, "it names a voucher %d of its %d usable cell(s) did not carry"
                        % (nusable - nmu, nusable)),
                ("effort:", "it does not disclose the effort behind the zero")):
            if frag not in txt:
                print("  *** %s reports a Never but %s" % (name, why))
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
        # An obs of ALWAYS on a row that co-runs nothing.  The runcheck twin of this
        # line (ch_check's F assertion) additionally reads `0 < k < R', because it
        # judges a device run where k == R is a legitimate Always.  Here that guard
        # would delete the check: the fixture this line catches by itself is
        # `always', k = R = 10, when a leak in het_verdict.h's co-run scan marks it
        # as co-running nothing.  Its case names no flag expectation, so the
        # differential sees nothing move.
        if (g["flags"] & (FLAG_BIT["SELF_CONTROL"] | FLAG_BIT["NO_CONTROL_CORUN"])) \
           and g["k"] > 0 and g["obs"] == "Always":
            print("  *** %s reports ALWAYS while nothing co-runs: the denominator "
                  "collapsed onto the runs that fired" % name)
            bad += 1

    for name, g in sorted(got.items()):
        txt = blocks.get(name, "")
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
              "The per-window bump is DEAD or mis-indexed, so the stream is not this "
              "run's history and the precheck reads a fiction." % (s1, t1))
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
    got, why = {}, {}
    for l in lines:
        if l.startswith("STOP|"):
            _, name, verdict, w = l.split("|")
            got[name] = verdict
            why[name] = w
    seen = set(got.values())
    for s in STOPS:
        have = got.get(s["name"])
        if have is None:
            print("  *** %s produced no STOP line" % s["name"])
            bad += 1
        elif have != s["want"]:
            print("  *** %-52s %s, want %s" % (s["name"], have, s["want"]))
            bad += 1
        elif not quiet:
            print("      %-52s -> %s" % (s["name"], have))
        # WHAT THE UNCONFIRMED STOP IS ALLOWED TO SAY, and where it must say nothing.
        # It is the one outcome whose name is not its meaning, so it carries one
        # sentence -- and the sentence must not creep onto the other stops, where it
        # would read as an adjudication of them.
        if have is not None:
            w = why.get(s["name"], "")
            if have == "UNCONFIRMED-SIGHTING":
                if "confirmation window closed" not in w or "did not reproduce" not in w:
                    print("  *** %s: the UNCONFIRMED stop's sentence does not say the "
                          "window closed on a sighting that did not reproduce (%r)"
                          % (s["name"], w))
                    bad += 1
            elif w:
                print("  *** %s: stop %s carries a sentence of its own (%r)"
                      % (s["name"], have, w))
                bad += 1
    want_all = {"CONTINUE", "CORROBORATED", "UNCONFIRMED-SIGHTING", "BUDGET"}
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
    print("\nSTOPPING RULE OK (every reason reachable; a lone clean sighting holds "
          "the row open for the confirmation window MEASURED FROM THE RUN IT FIRED "
          "IN, and no further; a degenerate one holds nothing open; rate mode "
          "disables the sighting stop and nothing else; unstamped residue decides "
          "nothing)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 5b -- THE SCHEDULER, END TO END, against a stub runner.  campaign.py spends
# (or saves) the hardware hours and none of its policy needs a GPU: the HetStats line
# is its whole interface.  The stub emits deterministic lines per (test, invocation),
# so the pooling arithmetic and the stop decisions are pinned exactly -- e.g. a null
# pools 10 runs an invocation and is ended by its 100-run budget in the tenth.
#
# WHAT IS PINNED HERE is that campaign.py applies het_verdict.h's rule at the pooled
# scale: one policy for every row, corroboration before the confirmation window before
# the budget, rate mode disabling the sighting stop alone, and the mirror that keeps
# the two copies of the rule from drifting.  The fixtures are named for the BEHAVIOUR
# they drive, because there is no class left to name them after.
# ---------------------------------------------------------------------------
STUB_RUNNER = r'''#!/usr/bin/env python3
import os, sys
d = sys.argv[1]
test = os.path.basename(d)
cf = os.path.join(d, "inv.count")
inv = (int(open(cf).read()) + 1) if os.path.exists(cf) else 1
open(cf, "w").write(str(inv))
with open(os.path.join(d, "seeds.log"), "a") as fh:
    fh.write("%d %s %s %s %s %s\n" % (inv, os.environ.get("HET_SEED"),
                                      os.environ.get("HET_ADAPTIVE"),
                                      os.environ.get("HET_RUNS_MAX"),
                                      os.environ.get("HET_RATE"),
                                      os.environ.get("HET_CONFIRM_RUNS")))
# The real harness runs at most HET_RUNS_MAX runs, so the stub does too: what a row
# whose entitlement the scheduler raised past its budget is ALLOWED to run is visible
# nowhere else, and a stub that ignored the cap would land on run counts no harness
# can produce.  Everything it reports scales with that R.
R = min(10, int(os.environ.get("HET_RUNS_MAX") or "10"))
base = ("R=%d usable=%d degen=0 ctrl=canary win_n=1280 nwin=128 "
        "ks=pass ks_D=0.1 ks_Dcrit=0.2 "
        "ks_split=-1 N=100000 frames=100000 flags=0x0" % (R, R))
NULL = "P_rep=-1"
FIRED = "P_rep=0.632 first_sight=1"
if test == "NULL-pooled":
    print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 sighting=none "
          "%s %s" % (test, NULL, base))
elif test == "SIGHT-corrob":
    # One clean sighting in one distinct run EVERY invocation: the pooled k_runs
    # reaches HET_CORROB_RUNS at invocation 2, and nothing further is bought.
    print("HetStats %s obs=Sometimes k=1 k_eff=1 k_runs=1 "
          "sighting=UNCONFIRMED %s %s" % (test, FIRED, base))
elif test == "SIGHT-lone":
    # Fires ONCE, in the first invocation, and never again: the row is held open by
    # the confirmation window and by nothing else.
    if inv == 1:
        print("HetStats %s obs=Sometimes k=1 k_eff=1 k_runs=1 "
              "sighting=UNCONFIRMED %s %s" % (test, FIRED, base))
    else:
        print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 sighting=none "
              "%s %s" % (test, NULL, base))
elif test == "SIGHT-late":
    # Fires ONCE, at the FIFTH invocation, and never again.  Its window opens 40 runs
    # into a 100-run budget, and what it is owed from there is a WHOLE window -- a
    # row whose window is measured from run 0 has none of it left and is banked
    # UNCONFIRMED the moment it fires.
    if inv == 5:
        print("HetStats %s obs=Sometimes k=1 k_eff=1 k_runs=1 "
              "sighting=UNCONFIRMED %s %s" % (test, FIRED, base))
    else:
        print("HetStats %s obs=Never k=0 k_eff=0 k_runs=0 sighting=none "
              "%s %s" % (test, NULL, base))
elif test == "SIGHT-degen":
    # A sighting the decode guard REJECTED (k=1, k_eff=0).  It corroborates nothing
    # and holds nothing open, so the row runs to its budget.
    print("HetStats %s obs=Sometimes k=1 k_eff=0 k_runs=0 degen=1 "
          "sighting=UNCONFIRMED P_rep=-1 first_sight=0 R=10 usable=10 ctrl=canary "
          "win_n=1280 nwin=128 ks=pass ks_D=0.1 "
          "ks_Dcrit=0.2 ks_split=-1 N=100000 frames=100000 flags=0x0" % test)
else:
    sys.exit(3)
'''

CAMPAIGN = os.path.join(ROOT, "hetlitmus", "campaign.py")
SEED_STRIDE = 100003     # must match campaign.py
# The budget phase 6 drives the campaign with, the confirmation window it passes, and
# the R every STUB_RUNNER line reports.  Named because the HET_RUNS_MAX assertion
# re-derives what the row is entitled to from them.
STUB_BUDGET, CONFIRM, STUB_R = 100, 30, 10
STUB_TESTS = ["NULL-pooled", "SIGHT-corrob", "SIGHT-degen", "SIGHT-lone"]


def _mk_corpus(tmp, name, tests):
    corpus = os.path.join(tmp, name)
    for t in tests:
        os.makedirs(os.path.join(corpus, t))
    return corpus


def _run_campaign(stub, corpus, state, extra):
    return subprocess.run(
        [sys.executable, CAMPAIGN, "--corpus", corpus,
         "--runner", "%s %s {dir}" % (sys.executable, stub),
         "--budget-runs", str(STUB_BUDGET), "--confirm-runs", str(CONFIRM),
         "--seed0", "777", "--state", state] + extra,
        capture_output=True, text=True)


def _done_rows(out):
    done, order = {}, []
    for l in out.splitlines():
        if l.startswith("done  "):
            f = l.split()
            done[f[1]] = dict(stop=f[2], inv=int(f[3].split("=")[1]),
                              runs=int(f[4].split("=")[1]))
            order.append(f[1])
    return done, order


def _mirror_bite(tmp, name, doctor, want_frag, quiet):
    """campaign.py's mirror, against a DOCTORED copy of the header.  A mirror nothing
    ever contradicts is not a mirror, so both halves of it are contradicted here."""
    hdr = os.path.join(tmp, "h-%s.h" % name)
    with open(os.path.join(ROOT, "litmus", "het-runtime", "het_verdict.h")) as fh:
        src = fh.read()
    new = doctor(src)
    if new == src:
        print("  *** VACUOUS MIRROR BITE %s: the injection matched nothing" % name)
        return 1
    with open(hdr, "w") as fh:
        fh.write(new)
    r = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import campaign; "
         "campaign.check_flag_mirror(path=sys.argv[1])"
         % os.path.join(ROOT, "hetlitmus"), hdr],
        capture_output=True, text=True)
    if r.returncode != 2 or want_frag not in r.stderr:
        print("  *** the mirror did not FATAL on %s (rc=%d, stderr=%r) -- a scheduler "
              "applying a stale copy of the harness's policy is the drift the mirror "
              "exists to stop" % (name, r.returncode, r.stderr.strip()[-300:]))
        return 1
    if not quiet:
        print("      mirror rejects %-26s naming %s" % (name, want_frag))
    return 0


def _window_arithmetic(out, want_rows):
    """THE PRINTED SENTENCE MUST ADD UP.  The summary says where each flagged row's
    sighting fired and where the row ended; a row the confirmation window ended ran
    at least that window's runs AFTER firing, or the sentence reports a window that
    closed before it opened."""
    bad = 0
    fired = re.findall(r"first fired at run (\d+) of (\d+)", out)
    if len(fired) != want_rows:
        print("  *** %d flagged row(s) printed a first-sighting line, want %d"
              % (len(fired), want_rows))
        bad += 1
    for first, total in fired:
        if int(total) - int(first) < CONFIRM:
            print("  *** a row ended UNCONFIRMED having fired at run %s of %s: only "
                  "%d run(s) of its %d-run window were ever run, so the sentence it "
                  "printed contradicts itself"
                  % (first, total, int(total) - int(first), CONFIRM))
            bad += 1
    return bad


def phase6_campaign(quiet):
    print("\n===== PHASE 6: does the scheduler spend the hours where the brief "
          "says? =====")
    tmp = tempfile.mkdtemp(prefix="statssched.")
    bad = 0
    try:
        # --- 6.0: THE MIRROR.  campaign.py carries its own copy of the corroboration
        # bar and of every stop-name string, and it is copied standalone onto rented
        # boxes, so nothing but this check stands between the two policies drifting.
        # It must pass against the real header and FATAL against a doctored one.
        loader = ("import sys; sys.path.insert(0, %r); import campaign; "
                  % os.path.join(ROOT, "hetlitmus"))
        r0 = subprocess.run(
            [sys.executable, "-c", loader +
             "assert campaign.check_flag_mirror() is not None, 'header out of reach'; "
             "assert campaign.CORROB_RUNS == %d, campaign.CORROB_RUNS; "
             "print('ok')" % CORROB_RUNS],
            capture_output=True, text=True)
        if r0.returncode != 0 or r0.stdout.strip() != "ok":
            print("  *** campaign.py's mirror does not agree with the shipped header: "
                  "rc=%d out=%r err=%r"
                  % (r0.returncode, r0.stdout.strip(), r0.stderr.strip()[-300:]))
            bad += 1
        bad += _mirror_bite(
            tmp, "a moved corroboration bar",
            lambda s: s.replace("#define HET_CORROB_RUNS 2",
                                "#define HET_CORROB_RUNS 3", 1),
            "HET_CORROB_RUNS", quiet)
        bad += _mirror_bite(
            tmp, "a renamed stop",
            lambda s: s.replace('case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CORROBORATED";',
                                'case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CONFIRMED";', 1),
            "stop names", quiet)
        # ... and the third piece of the policy a name cannot carry: WHERE the
        # confirmation window starts.  A header that measures it from run 0 ends rows
        # this scheduler would still be running.
        bad += _mirror_bite(
            tmp, "a window measured from run 0",
            lambda s: s.replace("if (n - st.n_at_first_sight >= confirm_runs)",
                                "if (n >= confirm_runs)", 1),
            "n_at_first_sight", quiet)
        # A header out of reach is the standalone-copy case: the mirror stands rather
        # than dying, or campaign.py could not run on the box it is copied to.
        r1 = subprocess.run(
            [sys.executable, "-c", loader +
             "assert campaign.check_flag_mirror(path='/nonexistent/het_verdict.h') "
             "is None; print('ok')"], capture_output=True, text=True)
        if r1.returncode != 0 or r1.stdout.strip() != "ok":
            print("  *** the mirror does not tolerate an out-of-reach header, so "
                  "campaign.py cannot run from the standalone bundle (rc=%d err=%r)"
                  % (r1.returncode, r1.stderr.strip()[-300:]))
            bad += 1

        stub = os.path.join(tmp, "stub.py")
        with open(stub, "w") as fh:
            fh.write(STUB_RUNNER)

        # --- 6.1: THE POLICY, END TO END.
        corpus = _mk_corpus(tmp, "corpus", STUB_TESTS)
        state = os.path.join(tmp, "state.csv")
        r = _run_campaign(stub, corpus, state, [])
        out = r.stdout

        # A CRASH EXITS 1 TOO.  This fixture set ends one row UNCONFIRMED-SIGHTING, so
        # the campaign is expected to exit 1 -- which means an unhandled exception
        # produces the "right" code by accident and the rc check below passes for free.
        if "Traceback" in r.stderr:
            print("  *** the campaign CRASHED (its exit code 1 is indistinguishable "
                  "from the expected flagged exit):\n%s" % r.stderr[-800:])
            bad += 1
        if r.returncode != 1:
            print("  *** campaign exited %d (want 1: a row ended UNCONFIRMED-SIGHTING, "
                  "which is not a result to be read unattended)\n%s%s"
                  % (r.returncode, out[-1500:], r.stderr[-500:]))
            bad += 1

        done, order = _done_rows(out)
        if order != sorted(STUB_TESTS):
            print("  *** run order %s -- one policy means one order, and it is the "
                  "corpus's" % order)
            bad += 1
        want = {
            # A null is ended by the budget and by nothing else: 10 runs an
            # invocation, so the 100-run budget lands in the tenth.  Nothing the
            # harness reports about the null shortens that.
            "NULL-pooled": ("BUDGET", 10),
            # clean sightings pool to k_runs >= HET_CORROB_RUNS at invocation 2.
            "SIGHT-corrob": ("CORROBORATED", 2),
            # one sighting in the first run, then nulls: held open by the window (30
            # runs after the run it fired in, so through run 31) and ended by it in
            # the fourth invocation -- not by the 100-run budget.
            "SIGHT-lone": ("UNCONFIRMED-SIGHTING", 4),
            # a rejected sighting stops nothing (STUB_RUNNER), so the row runs to its
            # budget.
            "SIGHT-degen": ("BUDGET", 10),
        }
        for t, (stop, inv) in want.items():
            g = done.get(t)
            if g is None:
                print("  *** no 'done' line for %s" % t)
                bad += 1
            elif (g["stop"], g["inv"]) != (stop, inv):
                print("  *** %-12s stop=%s inv=%d, want stop=%s inv=%d"
                      % (t, g["stop"], g["inv"], stop, inv))
                bad += 1
            elif not quiet:
                print("      %-12s stop=%-20s after %d invocation(s)"
                      % (t, g["stop"], g["inv"]))
        # The flagged row must be called out AND say what it is: a lone sighting the
        # window closed on, which STANDS as an observation and must be reproduced
        # before it is written up.  No adjudication -- nothing here says what the
        # sighting is worth against a model.
        for frag, why in (
                ("UNCONFIRMED-SIGHTING", "the flagged row is not called out"),
                ("did not reproduce", "the summary does not say what the window "
                                      "closed on"),
                ("sighting STANDS", "the summary does not say the sighting stands -- "
                                    "falsification is one-sided and suppressing it "
                                    "would be the overclaim in the other direction")):
            if frag not in out:
                print("  *** %s" % why)
                bad += 1
        bad += _window_arithmetic(out, 1)
        if "CORROBORATED" not in out:
            print("  *** a corroborated row is not reported at all")
            bad += 1

        # The D10 precondition is LOUDER when it did not run than when it failed: this
        # corpus has no CPU-only row, so the WB probe did not run and must say so.
        if "WB probe): *** NOT RUN" not in out:
            print("  *** the D10 WB probe is silently absent -- a precondition nobody "
                  "sees is a precondition nobody checked")
            bad += 1

        # --- 6.1b: WHAT A NULL IS WORTH IS THE EFFORT THAT FAILED TO SEE IT, so the
        # row the pooled null leaves in the state file must carry every run its budget
        # bought.  It is read by column name, so it also pins the five columns it names:
        # one renamed or dropped reads None here and fails.  `usable' does not
        # discriminate -- every stub line reports usable == R, so a driver banking
        # `runs' into both columns would pass this.
        want_bank = {"stop": "BUDGET", "invocations": "10",
                     "runs": str(STUB_BUDGET), "usable": str(STUB_BUDGET), "k": "0"}
        banked = {}
        if os.path.exists(state):
            with open(state) as fh:
                banked = {row["test"]: row for row in csv.DictReader(fh)}
        bank = banked.get("NULL-pooled")
        if bank is None:
            print("  *** NULL-pooled has no row in the campaign state at all")
            bad += 1
        elif {c: bank.get(c) for c in want_bank} != want_bank:
            print("  *** the pooled null NULL-pooled banked %s, want %s: it ran to its "
                  "budget, so the row it leaves behind is all %d of the runs that "
                  "failed to see the outcome"
                  % ({c: bank.get(c) for c in want_bank}, want_bank, STUB_BUDGET))
            bad += 1
        elif not quiet:
            print("      NULL-pooled  banks 10 invocation(s) / %d run(s) at BUDGET -- "
                  "a null is worth the effort spent on it" % STUB_BUDGET)

        # Every invocation must carry a FRESH seed base (seed0 + i*stride) and the
        # adaptive knobs -- a replayed seed adds no new phase draws -- and it must
        # carry the run count the row is ENTITLED to.  HET_RUNS_MAX is how a budget of
        # 100 becomes ten invocations of 10 rather than ten of 100: unchecked, the last
        # invocation of a nearly-spent row could overshoot by a whole invocation.  The
        # harness applies the same rule inside the invocation, so it also gets
        # HET_RATE and HET_CONFIRM_RUNS -- a harness told a different policy from the
        # scheduler's would stop on its own terms.
        for t in STUB_TESTS:
            log = os.path.join(corpus, t, "seeds.log")
            with open(log) as fh:
                for line in fh:
                    inv, seed, adaptive, runs_max, rate, confirm = line.split()
                    want_seed = 777 + (int(inv) - 1) * SEED_STRIDE
                    if int(seed) != want_seed or adaptive != "1":
                        print("  *** %s invocation %s: HET_SEED=%s (want %d), "
                              "HET_ADAPTIVE=%s" % (t, inv, seed, want_seed, adaptive))
                        bad += 1
                    if rate != "0" or int(confirm) != CONFIRM:
                        print("  *** %s invocation %s: HET_RATE=%s HET_CONFIRM_RUNS=%s "
                              "-- the harness applies the rule inside the invocation, "
                              "on the two policy knobs this driver hands it"
                              % (t, inv, rate, confirm))
                        bad += 1
                    want_max = STUB_BUDGET - STUB_R * (int(inv) - 1)
                    if int(runs_max) != want_max:
                        print("  *** %s invocation %s: HET_RUNS_MAX=%s, want %d "
                              "(budget %d minus the %d runs already spent).  The "
                              "harness is being told to run past the budget the "
                              "campaign is accounting for."
                              % (t, inv, runs_max, want_max, STUB_BUDGET,
                                 STUB_R * (int(inv) - 1)))
                        bad += 1
        if not quiet:
            print("      HET_RUNS_MAX curtails each invocation to the REMAINING "
                  "budget (%d, %d, %d, ...); HET_RATE/HET_CONFIRM_RUNS ride along"
                  % (STUB_BUDGET, STUB_BUDGET - STUB_R, STUB_BUDGET - 2 * STUB_R))
        if not os.path.exists(state):
            print("  *** no campaign state written")
            bad += 1

        # --- 6.2: THE CONFIRMATION WINDOW OUTRANKS THE BUDGET, in hardware hours.
        # The SAME lone-sighting row under a budget SMALLER than the window: it must
        # neither stop at BUDGET nor be curtailed to it -- the row runs past the
        # budget to the window and ends UNCONFIRMED-SIGHTING there.  Without the
        # precedence this row banks "seen once, stopped looking" at 20 runs.
        lone = _mk_corpus(tmp, "lone", ["SIGHT-lone"])
        r2 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", lone,
             "--runner", "%s %s {dir}" % (sys.executable, stub),
             "--budget-runs", "20", "--confirm-runs", str(CONFIRM),
             "--seed0", "777", "--state", os.path.join(tmp, "lone.csv")],
            capture_output=True, text=True)
        d2, _ = _done_rows(r2.stdout)
        g2 = d2.get("SIGHT-lone", {})
        if (g2.get("stop"), g2.get("runs")) != ("UNCONFIRMED-SIGHTING", 31):
            print("  *** the lone sighting under a 20-run budget ended %s after %s "
                  "run(s), want UNCONFIRMED-SIGHTING after 31 (it fired in run 1, so "
                  "its window closes at 31): the confirmation window outranks the "
                  "budget stop, or a row that fired once is banked as budget-spent"
                  % (g2.get("stop"), g2.get("runs")))
            bad += 1
        else:
            maxes = [int(l.split()[3])
                     for l in open(os.path.join(lone, "SIGHT-lone", "seeds.log"))]
            # 21 is the assertion: the entitlement is the WINDOW's end (run 31), not
            # the budget (20), and the harness is told so run by run.
            if maxes != [20, 21, 11, 1]:
                print("  *** HET_RUNS_MAX over the overshoot was %s, want "
                      "[20, 21, 11, 1] -- the harness must be told the runs the row "
                      "is ENTITLED to, not the budget the scheduler has already "
                      "overruled" % maxes)
                bad += 1
            elif not quiet:
                print("      SIGHT-lone   budget 20 < window (fired at run 1, closes "
                      "at 31) -> runs 31 (HET_RUNS_MAX 20, 21, 11, 1)")

        # --- 6.2b: A LATE SIGHTING GETS A WHOLE WINDOW, not the remains of one that
        # opened at run 0.  This row fires ONCE, in its fifth invocation (run 41 of a
        # 100-run budget), so its window closes at run 71 and the row ends in the
        # eighth.  Measured from run 0 the window is long gone when the sighting
        # lands: the row is banked UNCONFIRMED the moment it fires, having run none
        # of the runs the window exists to buy.
        late = _mk_corpus(tmp, "late", ["SIGHT-late"])
        r2b = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", late,
             "--runner", "%s %s {dir}" % (sys.executable, stub),
             "--budget-runs", str(STUB_BUDGET), "--confirm-runs", str(CONFIRM),
             "--seed0", "777", "--state", os.path.join(tmp, "late.csv")],
            capture_output=True, text=True)
        d2b, _ = _done_rows(r2b.stdout)
        g2b = d2b.get("SIGHT-late", {})
        want2b = ("UNCONFIRMED-SIGHTING", 8, 80)
        if (g2b.get("stop"), g2b.get("inv"), g2b.get("runs")) != want2b:
            print("  *** the row that fired at run 41 ended %s after %s invocation(s) "
                  "/ %s run(s), want %s: the confirmation window is measured from the "
                  "SIGHTING, so this row is owed %d runs after run 41"
                  % (g2b.get("stop"), g2b.get("inv"), g2b.get("runs"), want2b,
                     CONFIRM))
            bad += 1
        elif not quiet:
            print("      SIGHT-late   fires at run 41 -> window closes at 71 -> ends "
                  "UNCONFIRMED-SIGHTING at run 80 (invocation 8)")
        bad += _window_arithmetic(r2b.stdout, 1)

        # --- 6.3: --rate DISABLES THE SIGHTING STOP AND NOTHING ELSE.  The row that
        # corroborates at invocation 2 above must now run to its budget, and the null,
        # which no sighting stop was holding anyway, must end exactly where it did.
        rate = _mk_corpus(tmp, "rate", ["SIGHT-corrob", "NULL-pooled"])
        r3 = _run_campaign(stub, rate, os.path.join(tmp, "rate.csv"), ["--rate"])
        d3, _ = _done_rows(r3.stdout)
        for t, want3 in (("SIGHT-corrob", ("BUDGET", 10)),
                         ("NULL-pooled", ("BUDGET", 10))):
            g3 = d3.get(t, {})
            if (g3.get("stop"), g3.get("inv")) != want3:
                print("  *** --rate: %s ended %s after %s invocation(s), want %s -- "
                      "rate mode turns the SIGHTING stop off and nothing else"
                      % (t, g3.get("stop"), g3.get("inv"), want3))
                bad += 1
        if "--rate" not in r3.stdout and "a sighting stops NOTHING" not in r3.stdout:
            print("  *** a --rate campaign does not say that sightings stop nothing")
            bad += 1
        if r3.returncode != 0:
            print("  *** --rate campaign exited %d, want 0 (no row errored and none "
                  "was flagged)" % r3.returncode)
            bad += 1
        elif not quiet:
            print("      --rate       SIGHT-corrob runs to BUDGET, NULL-pooled ends "
                  "where it did")

        # FAIL CLOSED: a named test with no harness dir must kill the campaign (rc=2).
        r4 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--runner", "true",
             "--tests", "GHOST"], capture_output=True, text=True)
        if r4.returncode != 2:
            print("  *** a test with no harness dir exited %d, want 2 (fail closed: "
                  "there is nothing to run)" % r4.returncode)
            bad += 1
        elif not quiet:
            print("      a test with no harness dir fails the campaign closed (rc=2)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if bad:
        print("\nSCHEDULER FAILED: %d problem(s)." % bad)
        return 1
    print("\nSCHEDULER OK -- campaign.py applies het_verdict.h's rule at the pooled "
          "scale (corroboration, then the confirmation window, then the budget), the "
          "window runs from the sighting and outranks the budget in hardware hours, "
          "--rate disables the sighting stop alone, and the mirror rejects a header "
          "that moved the bar, renamed a stop or moved the window's origin.  A null "
          "runs to its budget and banks every run of it; seeds are fresh per "
          "invocation.")
    return 0


# ---------------------------------------------------------------------------
# PHASE 2b -- THE ARM A BUILD WITH NO MAP BESIDE IT TAKES.  The sentence a row that
# co-runs nothing prints depends on HET_NO_CONTROL_MAP, which the emitter stamps
# when the control map was not beside the test -- it is looked for beside every
# one -- so the default build above can never reach that sentence.  Compiled a
# second time with the stamp to reach it, under a HET_PAIR_NAME found nowhere
# else, which is what proves the sentence names the pair the binary was built for.
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
            ("It has NO CALIBRATION CHANNEL, and that is an OMISSION, not a "
             "construction",
             "it calls a gap we have not closed a property of the design"),
            # ...and WHICH omission.  The map is loaded for every lane, so the
            # flag says the FILE was not beside the test; a note that blamed a
            # registry would send a reader looking for a row to add.
            ("the map is looked for BESIDE THE TEST",
             "it does not say where the map was looked for"),
            ("what was omitted is the map FILE beside this test",
             "it does not say WHICH omission the missing calibration channel came "
             "from")):
        if frag not in txt:
            print("  *** the no-control-map note %s" % why)
            bad += 1
        elif not quiet:
            print("      %s" % frag[:96])
    # The self-canary arm's two sentences, refused here: they are the OTHER absence,
    # and a note that borrows them files a gap in the instrumentation under a
    # property of the design.
    for frag in ("IS the Layer-B canary", "by construction, not by omission"):
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
          "the missing calibration channel an omission; the self-canary note "
          "untouched)")
    return 0


# ---------------------------------------------------------------------------
# The header-driven phases, in print order.  1, 2 and 5 read one compiled run of
# the layer; 2b and 3 each build a program of their own, so a caller that names
# only the phases its subject can reach builds one program rather than three.
GATE_PHASES = ("1", "2", "2b", "5")


def run(header_dir, tmp, quiet, phases=GATE_PHASES):
    out = None
    if {"1", "2", "5"} & set(phases):
        try:
            out = _compile_and_run(header_dir, tmp)
        except _CompileFailed as e:
            print(e.out + e.err)
            print("\nSTATSCHECK FAILED: the statistics layer does not compile")
            return 1
    rc = 0
    for p in ("1", "2", "2b", "5", "3"):
        if p not in phases:
            continue
        if p == "1":
            rc |= phase1(out, quiet)
        elif p == "2":
            rc |= phase2(out, quiet)
        elif p == "2b":
            rc |= phase2b(header_dir, tmp, quiet)
        elif p == "5":
            rc |= phase5_stops(out, quiet)
        else:
            rc |= phase3(header_dir, tmp, quiet)
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
        print("STATSCHECK: PASS  (inputs + aggregate + producer + corpus "
              "+ stopping rule + scheduler)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: every injection below is a way this layer could ship a constant while
# compiling cleanly and passing every structural gate.  Each is verified to have
# actually CHANGED the file (one that matched nothing would pass for free), names
# the phases it can reach, and must redden one of them with a diagnostic carrying
# its own reason -- the fixture that moved and which way it moved.
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


def _named(said, expect):
    """The diagnostic that names this injection: one `***' line carrying every
    fragment of `expect'.  Both halves are required of a fragment pair -- the
    fixture that moved and WHICH WAY it moved -- because a phase reddening on some
    other fixture is another injection's evidence, not this one's."""
    want = (expect,) if isinstance(expect, str) else expect
    for l in said.splitlines():
        s = l.strip()
        if s.startswith("***") and all(w in s for w in want):
            return s
    return None


def _bite(label, hdir, mutate, phases, expect):
    """`phases' are the ones this injection can reach, `expect' the diagnostic it
    must produce there.  A nonzero exit is not enough on its own: a red for
    another reason would let a broken injection stand in for a live gate."""
    hp = os.path.join(hdir, "het_verdict.h")
    with open(hp) as fh:
        orig = fh.read()
    new = mutate(orig)
    if new == orig:
        print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
        return False
    sub = tempfile.mkdtemp(prefix="statsbite.")
    said = io.StringIO()
    try:
        # phase3 derives the test name from the directory basename: keep it.
        test = os.path.basename(hdir)
        bdir = os.path.join(sub, test)
        os.makedirs(bdir)
        shutil.copy(os.path.join(hdir, test + ".cu"), bdir)
        with open(os.path.join(bdir, "het_verdict.h"), "w") as fh:
            fh.write(new)
        with contextlib.redirect_stdout(said):
            rc = run(bdir, sub, quiet=True, phases=phases)
    finally:
        shutil.rmtree(sub, ignore_errors=True)
    hit = _named(said.getvalue(), expect)
    if rc and hit:
        print("  BITES (P%s): %s   [%s]" % ("+".join(phases), hit[:104], label))
        return True
    print("  *** DID NOT BITE for its own reason (P%s rc=%d, wanted %r)   [%s]"
          % ("+".join(phases), rc, expect, label))
    for l in said.getvalue().splitlines():
        if l.strip().startswith("***"):
            print("        | " + l.strip()[:140])
    return False


def bite():
    print("===== B7 BITE TEST: does this gate FAIL when the statistics break? =====")
    tmp = tempfile.mkdtemp(prefix="statsbite.")
    ok = True
    try:
        hdir = emit_harness(tmp)

        # (1) THE EMPTINESS CONJUNCT DROPPED FROM THE KS GATE.  The flag still fires
        # and still prints; the gate simply stops consulting it, so a `self' canary row
        # -- which co-runs no control by construction -- has its all-zero stream KS-ed
        # against itself, D = 0 against 0, "pass", and P_rep is unlocked for a harness
        # in which nothing ever fired.  This is the one way this layer can OVERCLAIM.
        ok &= _bite("the KS gate stops consulting the emptiness guard (an all-zero "
                    "stream passes and unlocks P_rep)", hdir,
                    lambda s: _subst(s, [
                        ("  ks = (st->flags & HET_ST_CTRL_STREAM_EMPTY)\n"
                         "       ? -1\n",
                         "  ks = 0\n       ? -1\n")]),
                    ("2",), "the pooled stream is empty but the KS gate reports")

        # (2) ... and the same overclaim from the other side: the guard never fires,
        # so there is nothing for the gate to consult.  Two injections because the
        # guard has two halves -- the predicate that raises it and the consumer that
        # obeys it -- and either alone reaches the same P_rep.
        ok &= _bite("the emptiness test forced false (nothing is ever called empty)",
                    hdir,
                    lambda s: _subst(s, [
                        ("  if (nwin < 2 || ctrl_pooled == 0 || "
                         "(st->flags & HET_ST_WIN_DESYNC))\n",
                         "  if (0)\n")]),
                    ("2",), "CTRL_STREAM_EMPTY=False but the pooled stream is empty")

        # (3) THE DEGENERACY GUARD DISABLED: a constant-read decoder artefact could
        # then forge a CORROBORATED sighting out of an artefact that never varied.
        ok &= _bite("the degeneracy guard disabled (a constant read can forge a "
                    "corroborated sighting)", hdir,
                    lambda s: s.replace(
                        "static int het_cell_degenerate(const het_obs_record *r) {",
                        "static int het_cell_degenerate(const het_obs_record *r) {\n"
                        "  if (r) return 0;"),
                    ("5",), ("degenerate-sightings-never-stop",
                             "CORROBORATED, want CONTINUE"))

        # (4) THE KS GATE MADE CONSTANT-PASS: stationarity is never tested and P_rep
        # is reported across a rate change, which Kirkham's own data says to expect.
        ok &= _bite("the KS gate made constant-pass (stationarity never tested)", hdir,
                    lambda s: s.replace("  return (D <= *Dcrit_out) ? 1 : 0;\n",
                                        "  return 1;\n"),
                    ("2",), ("ks-split-rejects-and-suppresses-Prep",
                             "ks: C pass != py SPLIT"))

        # (5) THE CORROBORATION GUARD GUTTED: one un-reproduced sighting would stop
        # the row and bank a sighting nothing reproduced.
        ok &= _bite("the stop rule corroborates on ONE sighting (an unreproduced "
                    "sighting banked)", hdir,
                    lambda s: s.replace(
                        "    if (st.tier == HET_SIGHT_CORROBORATED) "
                        "return HET_CAMPAIGN_STOP_CORROBORATED;",
                        "    if (st.k > 0) return HET_CAMPAIGN_STOP_CORROBORATED;"),
                    ("5",), ("one-clean-sighting-does-not-stop",
                             "CORROBORATED, want CONTINUE"))

        # (6) RATE MODE IGNORED: the row that was supposed to run on and yield a
        # rate stops at its first corroborated sighting instead, and the campaign
        # measures nothing it was asked to measure.
        ok &= _bite("rate mode ignored (a sighting stops the row anyway)", hdir,
                    lambda s: s.replace("  if (st.k_eff > 0 && !rate_mode) {",
                                        "  if (st.k_eff > 0) {"),
                    ("5",), ("rate-mode-does-not-stop-on-a-corroborated-sighting",
                             "CORROBORATED, want CONTINUE"))

        # (7) THE CONFIRMATION WINDOW NEVER CLOSES: a lone sighting holds the row
        # open forever, and UNCONFIRMED-SIGHTING -- the one flagged outcome -- becomes
        # unreachable while the row silently eats the budget it was allowed to
        # outrun.
        ok &= _bite("the confirmation window never closes (a lone sighting runs "
                    "forever)", hdir,
                    lambda s: s.replace(
                        "    if (n - st.n_at_first_sight >= confirm_runs)",
                        "    if (0)"),
                    ("5",), ("lone-sighting-at-the-confirm-window-stops-unconfirmed",
                             "CONTINUE, want UNCONFIRMED-SIGHTING"))

        # (8) THE WINDOW MEASURED FROM RUN 0 AGAIN: it then closes on a row that
        # fires late before that row has run any of it, and UNCONFIRMED-SIGHTING --
        # the outcome that says "we looked and it did not come back" -- is written
        # over a row nobody looked at again.
        ok &= _bite("the confirmation window measured from run 0 (a late sighting "
                    "gets none of it)", hdir,
                    lambda s: s.replace(
                        "    if (n - st.n_at_first_sight >= confirm_runs)",
                        "    if (n >= confirm_runs)"),
                    ("5",), ("lone-sighting-below-the-confirm-window-continues",
                             "UNCONFIRMED-SIGHTING, want CONTINUE"))

        # (9) THE CORROBORATION BAR MOVED: HET_CORROB_RUNS is what both sides of
        # the tier fixtures are sized from and what the MIRROR| line pins, so a
        # header that quietly raises it must redden by NAME.
        ok &= _bite("the corroboration bar raised (HET_CORROB_RUNS 2 -> 3)", hdir,
                    lambda s: s.replace("#define HET_CORROB_RUNS 2",
                                        "#define HET_CORROB_RUNS 3"),
                    ("1",), "MIRROR DRIFT: HET_CORROB_RUNS is 3 in the header")

        # (10) THE RECORD STAMP STOPS BEING CHECKED: het_stats_compute reuses
        # het_verdict() per cell, so an unstamped stream would score as a live one
        # and the aggregate would report a result over memset zeros.
        ok &= _bite("rec_magic no longer fails closed inside the aggregate", hdir,
                    lambda s: s.replace("  if (r->rec_magic != HET_REC_MAGIC) {",
                                        "  if (0) {"),
                    ("5",), ("unstamped-sightings-earn-no-corroboration",
                             "CORROBORATED, want BUDGET"))

        # ---- THE STRUCTURAL INVARIANTS ------------------------------------------
        # This family of assertions guards structure the shipped header enforces
        # unconditionally -- a clamp, a conjunct, a dedup, a flag -- so no injection
        # above can redden one of them, and an assertion never seen to fail is not
        # evidence that it is compared.  Each injection below deletes the ONE line
        # that makes one of them true.

        # (11) THE RUN DEDUP DELETED: several cells of ONE run then count as several
        # runs, so sightings from a single thermal/phase draw corroborate each
        # other -- a sighting "corroborated" by itself.
        ok &= _bite("the run dedup deleted (cells of ONE run corroborate each other)",
                    hdir,
                    lambda s: _subst(s, [(
                        "        for (j = 0; j < nruns; j++) "
                        "if (runs[j] == recs[i].run_id) seen = 1;",
                        "        for (j = 0; j < nruns; j++) if (0) seen = 1;")]),
                    ("2",), ("sighting-unconfirmed-3-cells-of-ONE-run",
                             "k_runs: C 3 != py 1"))

        # (12) THE P_rep DECODE GUARD DELETED: where every sighting was rejected by
        # the degeneracy guard, 1 - e^{-0} = 0 is then reported as "P_rep = 0.00%",
        # which reads as "never reproduces" when it means "no clean cell to estimate
        # from" -- a number that walks into a table as evidence of the opposite.
        ok &= _bite("the P_rep k_eff>0 conjunct deleted (an ABSENCE printed as 0.00%)",
                    hdir,
                    lambda s: _subst(s, [("    if (st->ks_pass && st->k_eff > 0)",
                                          "    if (st->ks_pass)")]),
                    ("2",), ("degenerate-sightings-rejected-but-reported",
                             "P_rep: C 0 != py -1"))

        # (13) THE TRUNCATION STOPS SAYING IT TRUNCATED: the tail is still discarded
        # (the clamp stays, so nothing overruns), but nothing records that the
        # aggregate was computed from fewer runs than the campaign paid for.
        ok &= _bite("the CELLS_TRUNCATED flag dropped (a silently shortened campaign)",
                    hdir,
                    lambda s: _subst(s, [(
                        "  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;\n"
                        "                                 st->flags |= "
                        "HET_ST_CELLS_TRUNCATED; }",
                        "  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS; }")]),
                    ("2",), ("cells-truncated-above-HET_STATS_MAX_CELLS",
                             "flag CELLS_TRUNCATED NOT set"))

        # ---- THE PYTHON MIRRORS -------------------------------------------------
        # (14)-(16) Move a mirrored macro in the header and leave statscheck's Python
        # copy behind.  The MIRROR| comparison in phase 1 is what must name each
        # drift, and for THETA_DISTINCT and TAU_HOT it is the ONLY thing that can:
        # every fixture sits far from those two boundaries, so each comparison keeps
        # its truth value on both sides of the move and the differential stays green
        # on a mirror that no longer describes the header.  MAX_CELLS is not like
        # that -- the truncation fixture is sized from it, so the differential moves
        # too -- but phase 1 is still where the drift is named.
        ok &= _bite("HET_THETA_DISTINCT moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_THETA_DISTINCT 2",
                                          "#define HET_THETA_DISTINCT 3")]),
                    ("1",), "MIRROR DRIFT: HET_THETA_DISTINCT is 3 in the header")
        ok &= _bite("HET_TAU_HOT moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_TAU_HOT 30",
                                          "#define HET_TAU_HOT 31")]),
                    ("1",), "MIRROR DRIFT: HET_TAU_HOT is 31 in the header")
        ok &= _bite("HET_STATS_MAX_CELLS moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_STATS_MAX_CELLS 128",
                                          "#define HET_STATS_MAX_CELLS 129")]),
                    ("1",), "MIRROR DRIFT: HET_STATS_MAX_CELLS is 129 in the header")

        # (17)-(18) THE TWO NO-CONTROL STATES CONFLATED.  This is the defect in
        # its simplest form: infer "this row IS the Layer-B canary" from "no record
        # has a control", which is true of EVERY harness of a pair with no control
        # map.  The numbers do not move -- both states take the same denominator --
        # so nothing but the flag and the sentence can see it.
        print("\n-- the self-canary inference --")
        ok &= _bite("the self-canary test dropped (anything that co-runs nothing is "
                    "called the canary)", hdir,
                    lambda s: _subst(s, [
                        ('      if (recs[first].canary_name && recs[first].test_name\n'
                         '          && strcmp(recs[first].canary_name, '
                         'recs[first].test_name) == 0)\n',
                         '      if (1)\n')]),
                    ("2", "2b"),
                    ("no-control-map-fired-3-of-10-is-SOMETIMES-and-is-NOT-the-canary",
                     "flag SELF_CONTROL set (must not be)"))
        # ... and the reverse: a genuine self-canary row demoted to the no-map state,
        # which would report a gap in the instrumentation where the design has none.
        ok &= _bite("the self-canary test made unsatisfiable (a real canary row "
                    "reported as having no control map)", hdir,
                    lambda s: _subst(s, [
                        ('      if (recs[first].canary_name && recs[first].test_name\n'
                         '          && strcmp(recs[first].canary_name, '
                         'recs[first].test_name) == 0)\n',
                         '      if (0)\n')]),
                    ("2", "2b"),
                    ("self-canary-fired-3-of-10-is-SOMETIMES-not-ALWAYS",
                     "flag SELF_CONTROL NOT set"))

        # (19) THE WINDOW BUMP DELETED FROM THE PRODUCER: het_win_of still exists and
        # the aggregate still computes, but the sub-tallies never move, so the stream
        # the precheck reads is a fiction.  Only phase 3 can see this.
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

        # (20) THE EMITTER STOPS TAGGING THE DECODE CHANNEL: the guard would read a
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
        print("BITE OK: all 20 injections were caught --")
        print("         2 against the EMPTINESS GUARD, one per half (the KS gate")
        print("         stops consulting it; the test that raises it forced false):")
        print("         either one alone unlocks P_rep on a stream nothing fired on,")
        print("         which is the only way this layer can overclaim,")
        print("         2 against the DECODE and STATIONARITY guards (degeneracy")
        print("         disabled, KS made constant-pass),")
        print("         6 against the STOP RULE (corroboration on one sighting, rate")
        print("         mode ignored, both ways of losing the confirmation window,")
        print("         the corroboration bar, the record stamp),")
        print("         3 against the STRUCTURAL INVARIANTS (run dedup, the P_rep")
        print("         decode conjunct, the truncation flag),")
        print("         3 against the PYTHON MIRRORS (THETA_D / TAU_HOT / MAX_CELLS")
        print("         moved under them),")
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
