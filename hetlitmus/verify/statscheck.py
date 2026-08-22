#!/usr/bin/env python3
"""HetLitmus -- the statistics gate for het_stats_compute() (het_verdict.h).

het_stats_compute() says what a "Never" cost and how many independent runs a
sighting reproduced in, and every part of it can pass a structural gate while
answering the same thing forever: a denominator that collapses onto the runs that
fired reports ALWAYS for a row that fired in 3 of 10, and a decode guard that
never fires lets a constant read corroborate itself.  This gate drives the
emitted header itself, which cannot drift from a copy.  What a null is entitled
to report: hetlitmus/docs/00-environment-design.md sec 3.7.

  1  Inputs      the Python mirrors of the header's knobs are compared to the
                 header instead of assumed.
  2  Aggregate   every statistic re-derived independently in Python; every
                 class, tier and flag reachable.
  4  Corpus      every harness carries the post-pass and a decode channel.
  5  Stop rule   every reason reachable, each guard driven at its boundary.
  6  Scheduler   campaign.py end to end, against a stub runner.

Usage:  statscheck.py [-q]      run the gate
        statscheck.py --bite    prove the gate FAILS when the mechanism breaks
"""

import argparse
import contextlib
import csv
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")

# The emitted-corpus census, derived from the corpus rather than pasted off a run: a
# test carries the sync channel when it has a register (reader) observable and the
# observer channel when it has a coherence-final [loc] atom, and the store-only shapes
# are exactly the ones with no reader.  Most carry both; a test carrying NEITHER is a
# build bug, and its absence is what lets the degeneracy guard switch channel instead
# of firing blind.  Phase 4 measures all three off the emitted corpus.
CENSUS_SYNC, CENSUS_OBS, CENSUS_NEITHER = 460, 159, 0
CENSUS_TESTS = 471

# The Python mirrors of the header's knobs.  "Must match" is not a check: no fixture
# straddles the THETA_D boundary, so a header change would keep every comparison's
# truth value and desynchronise the mirror in silence.  All three are therefore
# emitted by the C driver and COMPARED in phase 1, on the MIRROR| line.
CORROB_RUNS = 2             # must match HET_CORROB_RUNS      (pinned via MIRROR|)
THETA_D = 2                 # must match HET_THETA_DISTINCT   (pinned via MIRROR|)
MAX_CELLS = 128             # must match HET_STATS_MAX_CELLS  (pinned via MIRROR|)


# ---------------------------------------------------------------------------
# Synthetic cells.  A cell is one (instance, run).  BASE is a live, stressed,
# reportable run: every requested mechanism measured alive, nothing seen.  Each
# case perturbs a few fields, so each isolates exactly one reason.  (Same
# construction as verdictcheck.py, on purpose.)
# ---------------------------------------------------------------------------
BASE = dict(
    test_name='"synthetic"',
    # The stamp, by symbol: het_verdict() reads no field of a record that does not
    # carry it, so every fixture here has to be a stamped one.
    rec_magic="HET_REC_MAGIC",
    exhaustive_valid=1,
    target_count_exhaustive=0,
    target_count_heuristic=0,
    interleavings_detected=1000,
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
)

# ---------------------------------------------------------------------------
# The record stream.  A cell is one (instance, run) and carries exactly what the
# surviving estimator reads off it: which outcome het_verdict() gives it, whether
# it saw the target, whether its decode is degenerate, and which decode channel it
# has.  The fixtures are therefore counts of records rather than sampled series --
# nothing here is drawn.
# ---------------------------------------------------------------------------
CELLS = 10                        # the record stream most fixtures are R long
# One record more than the aggregate can hold.  het_stats_compute clamps its record
# array at HET_STATS_MAX_CELLS and the tail is dropped from every statistic; the field
# is producible (hetEmit sizes _recs[NUMBER_OF_RUN] from Cfg.runs, so litmus7 -r above
# that clamp hands it more than it can hold), and the ONLY thing that says the aggregate
# was computed from fewer runs than were executed is HET_ST_CELLS_TRUNCATED.
CELLS_TRUNC = MAX_CELLS + 1


def cell(**kw):
    r = dict(BASE)
    r.update(kw)
    return r


def stream(nc, **kw):
    """One record per run, run ids 0, 1, 2, ..."""
    return [cell(run_id=i, **kw) for i in range(nc)]


def stream_runs(run_ids, **kw):
    """stream() with explicit run ids, so a fixture can put several cells in ONE run.
    stream() numbers its cells 0, 1, 2, ..., which makes k_runs identically k_eff and
    leaves het_stats_compute's run-dedup loop -- and with it the corroboration tier's
    "distinct runs, not merely distinct cells" rule -- unexercised.  The emitter writes
    one record per run, so this is the multi-record-per-run layout the tier rule is
    written for, driven before an emitter grows one."""
    return [cell(run_id=r, **kw) for r in run_ids]


def observed(cells_, k, clean=True, obs_degen=False):
    """Make the first k cells see the target (optionally in a degenerate decode).
       obs_degen degrades the observer channel on the sighting cells ONLY (a real
       ws-edge needs >=2 distinct GPU store-values, so observer_unique_count=1 on a
       sighting is the constant-read artefact), leaving the background nulls live."""
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
    """Make the cell at idx -- and ONLY it -- see the target, cleanly.  Where in the
    stream a sighting lands is what the confirmation window is measured from, so a
    fixture that can only fire at the head cannot drive that window at all."""
    observed(cells_[idx:idx + 1], 1)
    return cells_


CASES = []


def case(name, cells_, **want):
    CASES.append(dict(name=name, cells=cells_, want=want))


# ============================== The case set ===============================
# --- Never, over a stream of live runs: the shape every null in the corpus takes -
case("never-over-ten-live-runs", stream(CELLS), obs="Never", R=CELLS,
     R_usable=CELLS, k=0)

# --- Observed at the (instance,run) unit, never at the frame ---------------
case("sometimes-3-of-10-cells-not-frames", observed(stream(CELLS), 3),
     obs="Sometimes", k=3, k_eff=3)

case("always", observed(stream(CELLS), CELLS), obs="Always", k=CELLS)

# --- Void: a dead harness measured nothing ---------------------------------
# Every cell COLD-INVALID (the two engines never overlapped), so R_usable is 0 and
# there is no reading at all -- which is NOT the same answer as "Never".
case("void-when-every-cell-is-cold",
     stream(CELLS, interleavings_detected=0),
     obs="VOID", R=CELLS, R_usable=0)

# --- The degeneracy guard ---------------------------------------------------
# Seen in 3 cells, but every decode was constant -- the reader-stuck-on-one-value
# artefact of [Srivastava24 sec 4.1].  k=3 but k_eff=0, so it cannot corroborate; it is
# still reported.
case("degenerate-sightings-rejected-but-reported",
     observed(stream(CELLS), 3, clean=False),
     obs="Sometimes", k=3, k_eff=0, n_degen=3,
     flags_any=["DEGEN_SIGHTING"], tier="UNCONFIRMED")

# The store-only (2+2W) tests decode through the observer, not a synchrony read, so
# reading skew_stddev on them would call every cell degenerate forever.  BOTH arms of
# the channel switch must be live:
case("observer-channel-clean",
     observed(stream(CELLS, sync_valid=0, obs_valid=1, observer_unique_count=900,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     obs="Sometimes", k=3, k_eff=3, flags_none=["DEGEN_SIGHTING"])

# ... and the degenerate arm.  The degeneracy sits on the sightings (unique_count=1),
# where it physically belongs: a cold observer on a non-sighting null COLD-INVALIDs
# that cell instead, so the background nulls stay usable and the classification stays
# honestly "Sometimes" with every sighting degenerate.
case("observer-channel-degenerate",
     observed(stream(CELLS, sync_valid=0, obs_valid=1, observer_unique_count=900,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3, obs_degen=True),
     obs="Sometimes", k=3, k_eff=0, flags_any=["DEGEN_SIGHTING"])

# No decode channel at all: FAIL CLOSED.  No emitted harness is in that state
# (CENSUS_NEITHER), so reaching it is a build bug.
case("no-decode-channel-fails-closed",
     observed(stream(CELLS, sync_valid=0, obs_valid=0,
                     distinct_decoded_iters=0, skew_stddev=0.0), 3),
     k=3, k_eff=0, flags_any=["NO_DECODE_CHANNEL", "DEGEN_SIGHTING"])

# --- The corroboration tier (HET_CORROB_RUNS distinct clean runs) -----------
# The bar is on runs and the boundary is at HET_CORROB_RUNS exactly, so BOTH sides
# of it are driven: one run short is UNCONFIRMED, one run over is CORROBORATED.
case("sighting-corroborated-at-the-bar",
     observed(stream(CELLS), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS)

case("sighting-unconfirmed-one-run-short",
     observed(stream(CELLS), CORROB_RUNS - 1),
     obs="Sometimes", tier="UNCONFIRMED", k_runs=CORROB_RUNS - 1)

# The CPU-only campaign.  het_stats_compute resolves cpu_only upward over the cells it
# is handed and het_stats_print says, inside the sighting tier and nowhere else, that
# no cross-device path carried the cycle [Goens23 sec 4.6].  It is the campaign-level
# twin of the per-run sentence verify/verdictcheck.py pins, and a CPU-only sighting
# written up without it reads as a compound-model result.
CPU_ONLY_CASE = "cpu-only-sighting-says-what-was-under-test"
CPU_ONLY_TEXT = "CPU-ONLY CYCLE: every proc of this test is a CPU proc"
# The same fact machine-readably, on het_stats_line rather than in the tier block.
CPU_ONLY_LINE = re.compile(r"HetStats \S+ cpu_only=\d+ ")
case(CPU_ONLY_CASE,
     observed(stream(CELLS, cpu_only=1), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS)

# ... and a pool whose cells disagree, which is the ONLY fixture that runs the
# resolution at all: cpu_only names the narrower experiment, so a pool carrying one
# CPU-only cell resolves to CPU-only and is flagged rather than absorbed into the
# het reading.  The disagreeing cell is not the first, since the first is what the
# rest are compared against.
MIXED_POOL_CASE = "mixed-pool-resolves-cpu-only-upward"
_mixed = observed(stream(CELLS), CORROB_RUNS)
_mixed[CORROB_RUNS]["cpu_only"] = 1
case(MIXED_POOL_CASE, _mixed,
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS,
     flags_any=["MIXED_POOL"])

# ... and the rule is about runs, NOT cells.  Three clean sightings that all landed in
# the same run: runs are re-seeded and carry a fresh phase/thermal draw, three cells of
# one run do not, so this must stay UNCONFIRMED where the case above it is
# CORROBORATED.  The only fixture where k_runs < k_eff, and therefore the only one that
# runs het_stats_compute's run-dedup loop at all.
case("sighting-unconfirmed-3-cells-of-ONE-run",
     observed(stream_runs([0, 0, 0] + list(range(1, 8))), 3),
     obs="Sometimes", k=3, k_eff=3, k_runs=1, tier="UNCONFIRMED")

# ... and n_at_first_sight is the price in runs, so it must be the run the first
# clean sighting landed in and NOT the count of sightings.  Here the first three
# runs are null and run 3 (the fourth) fires.
case("first-sight-is-priced-in-runs",
     observed(stream_runs([3, 4, 0, 1, 2, 5, 6, 7, 8, 9]), 1),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=1)

# ... and the same price at a late position, which is what pins the indexing: the
# fifth run of ten fires, so the price is 5 -- the count of runs spent through the
# sighting, one-based, NEITHER the four spent before it nor a run id.  The
# confirmation window is measured from this number (het_verdict.h's stopping rule),
# so an off-by-one here silently shortens or lengthens every window by a run.
case("first-sight-counts-the-runs-spent-through-the-sighting",
     observed_at(stream(CELLS), 4),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=5)

# --- A mixed stamped/unstamped stream is read as its stamped half -------------
# Ten stamped null cells plus two unstamped ones whose every field is memset residue.
# Everything below rec_magic is unreadable, so nothing here may see one: not the run
# count, not the frame total, not R_usable.  R keeps them, because R is the records
# supplied and the discard has to stay visible.
MIXED_STAMP_CELLS = stream(CELLS) + stream_runs([10, 11], rec_magic=0)
case("unstamped-cells-are-read-by-nothing",
     MIXED_STAMP_CELLS,
     obs="Never", R=CELLS + 2, R_usable=CELLS, frames=CELLS * 100000)

# --- The selection effect on the denominator ---------------------------------
# Nothing co-runs, so a cell is usable when it fired or when its own liveness
# counters were alive: here seven runs saw no interleaving at all and are COLD, and
# the three that fired are usable BECAUSE they fired.  Classifying over usable cells
# would report Always for a row that fired in 3 runs of 10, so the denominator is R
# -- the runs EXECUTED.
case("fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(CELLS, interleavings_detected=0), 3),
     obs="Sometimes", k=3, k_eff=3, R=CELLS, R_usable=3, frames=CELLS * 100000)

# ... and one unstamped cell must NOT undo it.  The same ten, plus a cell that is
# memset residue throughout.  Read, the residue adds a usable cell and a frame
# total; counted into R alone, it moves the denominator the right way and nothing
# else.  Same class and same frame count as the case above is the whole assertion.
case("plus-one-unstamped-cell-is-still-SOMETIMES",
     observed(stream(CELLS, interleavings_detected=0), 3)
     + stream_runs([10], rec_magic=0),
     obs="Sometimes", k=3, k_eff=3, R=CELLS + 1, R_usable=3,
     frames=CELLS * 100000)

# --- More runs than the aggregate can hold ----------------------------------
# The tail beyond HET_STATS_MAX_CELLS is dropped from every statistic, which would
# quietly report a campaign as having spent less effort than it did -- so st->R keeps
# the pre-clamp count and the flag says the discard happened.  A harness runs fewer
# cells than that per invocation, but campaign.py pools invocations and litmus7 -r is
# an operator knob, so the path is reachable in the field and reached here.
case("cells-truncated-above-HET_STATS_MAX_CELLS", stream(CELLS_TRUNC),
     obs="Never", R=MAX_CELLS + 1, R_usable=MAX_CELLS,
     flags_any=["CELLS_TRUNCATED"])


# ===================== PHASE 5a: the stopping rule ==========================
# het_campaign_should_stop() decides where the hardware hours go, so every reason it
# can give has to be reachable and every guard has to hold at its boundary: a lone
# clean sighting holds the row open (it is not banked) but only as far as the
# confirmation window; a degenerate-only sighting holds nothing open; rate mode
# disables the sighting stop and NOTHING else; and residue from an unstamped record
# decides nothing.  The matrix drives the C rule directly, on synthetic records.
CONFIRM_RUNS = 30           # must match the driver's HET_CONFIRM_RUNS default
STOPS = []


def stop(name, cells_, budget, want, rate=0, confirm=CONFIRM_RUNS):
    STOPS.append(dict(name=name, cells=cells_, budget=budget,
                      want=want, rate=rate, confirm=confirm))


# A lone clean sighting does NOT stop: one run cannot rule out a per-run artefact,
# so the row keeps running to corroborate.
stop("one-clean-sighting-does-not-stop",
     observed(stream(CELLS), 1),
     20, "CONTINUE")
# ... and neither does a degenerate one, at any count: an artefact must NEVER
# de-schedule a test (the branch is on k_eff, not on the tier, which k sets).
stop("degenerate-sightings-never-stop",
     observed(stream(CELLS), 3, clean=False),
     20, "CONTINUE")
# The bar is HET_CORROB_RUNS distinct clean runs, and it is reached exactly there.
stop("sighting-corroborated-stops",
     observed(stream(CELLS), CORROB_RUNS),
     20, "CORROBORATED")
# The confirmation window, at its boundary.  The same lone sighting in the first of
# ten runs, so nine have elapsed since it: one run short of the window it keeps
# running, at the window it stops -- and UNCONFIRMED-SIGHTING is its own outcome,
# NEITHER a corroboration nor a null.
stop("lone-sighting-below-the-confirm-window-continues",
     observed(stream(CELLS), 1),
     20, "CONTINUE", confirm=10)
stop("lone-sighting-at-the-confirm-window-stops-unconfirmed",
     observed(stream(CELLS), 1),
     20, "UNCONFIRMED-SIGHTING", confirm=9)
# The precedence, both ways.  budget is spent (n >= budget) in both, and NEITHER
# answers BUDGET: while a clean sighting is open the window decides, because a row
# ended at BUDGET here would bank "seen once, stopped looking".  Below the window
# that means CONTINUE -- the caller's own run capacity is what ends the invocation,
# and the row is left unterminated rather than recorded as budget-stopped.
stop("lone-sighting-outranks-the-budget-stop",
     observed(stream(CELLS), 1),
     5, "CONTINUE")
stop("the-window-not-the-budget-ends-a-lone-sighting",
     observed(stream(CELLS), 1),
     5, "UNCONFIRMED-SIGHTING", confirm=9)
# The window is measured from the sighting, and these three are why it must be.  A
# row whose one sighting lands in its LAST run has spent none of its window yet, so
# it keeps running: closing the window on it hands a sighting zero runs to reproduce
# in and banks the un-reproduced answer.  With the sighting at the fifth run of ten
# the boundary is driven from both sides -- five runs have elapsed since it, so a
# six-run window is still open and a five-run one has just closed.
stop("a-sighting-in-the-last-run-gets-its-window",
     observed_at(stream(CELLS), 9),
     20, "CONTINUE", confirm=5)
stop("late-sighting-inside-its-window-continues",
     observed_at(stream(CELLS), 4),
     20, "CONTINUE", confirm=6)
stop("late-sighting-past-its-window-stops-unconfirmed",
     observed_at(stream(CELLS), 4),
     20, "UNCONFIRMED-SIGHTING", confirm=5)
# Rate mode (HET_RATE=1) disables the sighting stop and NOTHING else: the row runs on
# to measure a rate, and its budget still stops it.
stop("rate-mode-does-not-stop-on-a-corroborated-sighting",
     observed(stream(CELLS), CORROB_RUNS),
     20, "CONTINUE", rate=1)
stop("rate-mode-still-stops-at-budget",
     observed(stream(CELLS), CORROB_RUNS),
     10, "BUDGET", rate=1)
# ... and a lone sighting under rate mode is a rate to be measured like any other:
# neither the corroboration stop nor the confirmation window applies, so the row
# reaches its budget and is never banked UNCONFIRMED.  Rate mode is the operator's
# answer to an UNCONFIRMED row, so it must NOT be able to produce one.
stop("rate-mode-runs-a-lone-sighting-to-budget",
     observed(stream(CELLS), 1),
     10, "BUDGET", rate=1)
stop("cold-row-runs-to-budget",
     stream(CELLS),
     10, "BUDGET")
# An unstamped record earns no early stop: every cell is COLD-INVALID, so there is
# nothing to corroborate, and the row spends its budget.
stop("unstamped-records-fail-closed-to-budget",
     stream(CELLS, rec_magic=0),
     10, "BUDGET")
# ... and the same holds when the unstamped stream is full of sightings in distinct
# runs.  Every count below rec_magic is then memset residue, so scoring it would let
# a harness the emitter built wrong corroborate itself into CORROBORATED -- the one
# stop that means "nothing further is bought by running this row".
stop("unstamped-sightings-earn-no-corroboration",
     observed(stream(CELLS, rec_magic=0), CORROB_RUNS),
     10, "BUDGET")
# A mixed stream decides from its stamped half ALONE.  The two unstamped cells are
# sightings in distinct runs, so read, the residue alone would corroborate the row and
# stop it -- the one stop that means "nothing further is bought here".  The stamped ten
# are nulls, so the answer is theirs: the row spends its budget.
stop("mixed-stream-is-decided-by-its-stamped-half",
     (stream(CELLS)
      + observed(stream_runs([10, 11], rec_magic=0), 2)),
     12, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(cells_):
    # The record array is clamped at HET_STATS_MAX_CELLS and the tail is dropped from
    # every statistic below; st->R keeps the pre-clamp count so the discard is visible.
    R = len(cells_)
    pool = cells_
    cells_ = cells_[:MAX_CELLS]
    n = len(cells_)

    def stamped(c):
        # het_verdict() reads no field of a record that does not carry the stamp, so
        # neither does anything derived from one: every total, every count, every
        # calibration sample here is drawn from the stamped cells ALONE.
        return c["rec_magic"] == "HET_REC_MAGIC"

    # The pool's identity, read before the clamp and resolved upward: ONE CPU-only
    # cell names the narrower experiment for the whole pool, so a het reading may not
    # absorb it.  het_stats_line prints it and hetlitmus/campaign.py schedules off
    # that field.
    cpu_only = 1 if any(c.get("cpu_only", 0) for c in pool if stamped(c)) else 0

    def degenerate(c):
        if c["sync_valid"]:
            return (c["distinct_decoded_iters"] < THETA_D) or (c["skew_stddev"] == 0.0)
        if c["obs_valid"]:
            return c["observer_unique_count"] < THETA_D
        return True

    def channel_live(c):
        # Mirrors het_verdict()'s channel-aware liveness disqualifier: the sync
        # channel's evidence is interleavings_detected>0, the observer channel's is
        # observer_unique_count>=THETA_D, and a record with NEITHER fails closed.
        if c["sync_valid"]:
            return c["interleavings_detected"] > 0
        if c["obs_valid"]:
            return c["observer_unique_count"] >= THETA_D
        return False

    def usable(c):
        # Mirrors het_verdict()'s COLD-INVALID: an unstamped record is cold at step 0;
        # a sighting is never cold; otherwise the run's decode channel has to be live.
        if not stamped(c):
            return False
        if c["target_count_exhaustive"] > 0 or c["target_count_heuristic"] > 0:
            return True
        return channel_live(c)

    k = k_eff = n_degen = R_usable = first_sight = 0
    runs, allruns = [], []
    for c in cells_:
        # The stamp gates every read.  A cell that does not carry it is residue, and
        # nothing below may see one: NEITHER the run tally, nor the window sums, nor
        # the frames, nor the calibration samples.  It is unusable by that same test,
        # so skipping it whole loses nothing but the residue.
        if not stamped(c):
            continue
        if usable(c):
            R_usable += 1
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

    # The selection effect: nothing co-runs, so "usable" is defined by firing wherever
    # the run's own liveness rides on the outcome, and the denominator is R -- the
    # records SUPPLIED, i.e. PRE-clamp, as in the C.
    denom = R
    if R_usable == 0:
        obs = "VOID"
    elif k == 0:
        obs = "Never"
    elif k >= denom:
        obs = "Always"
    else:
        obs = "Sometimes"

    tier = "none"
    if k > 0:
        tier = ("CORROBORATED" if len(runs) >= CORROB_RUNS else "UNCONFIRMED")

    return dict(obs=obs, k=k, k_eff=k_eff, k_runs=len(runs), n_degen=n_degen,
                first_sight=first_sight,
                frames=sum(c["frames_examined"] for c in cells_ if stamped(c)),
                R=R, R_usable=R_usable, tier=tier, cpu_only=cpu_only)


# ---------------------------------------------------------------------------
# The C driver.
# ---------------------------------------------------------------------------
C_MAIN = r"""
/* GENERATED by hetlitmus/verify/statscheck.py -- do not edit. */
#include "het_verdict.h"

static void run_case(const char *name, const het_obs_record *recs, int n) {
  het_stats_t st;
  het_stats_compute(recs, n, &st);
  printf("CASE|%s|%s|%d|%d|%d|%d|%d|%s|0x%x|%d|%d|%llu\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.k_runs, st.n_degen,
         st.R_usable, het_sighting_name(st.tier), st.flags,
         /* st.R is the PRE-clamp record count: R > R_usable can mean cold cells,
            R > HET_STATS_MAX_CELLS means the tail was discarded. */
         st.R, st.n_at_first_sight,
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

/* PHASE 1 -- the constants the aggregate is built on.
   THE PYTHON MIRRORS, emitted so they can be COMPARED.  Every fixture below sits
   far from the THETA_D boundary -- deliberately, since a fixture at the boundary
   tests the boundary and not the statistic -- so nothing else in this gate can
   notice one of these macros moving under the mirror. */
static void anchors(void) {
  printf("MIRROR|%d|%d|%d\n", (int)HET_THETA_DISTINCT,
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
    """Emit a REAL harness and return its directory (the header comes from it)."""
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
# THE BIT NUMBER IS WRITTEN DOWN, not derived from position in this list.  The
# header leaves retired bits vacant (0, 1, 3, 4, 6, 7, 9, 10, 11, 12, 13, 14, 16)
# because flags=0x... is a wire format that archived transcripts and fixtures are
# already written in, so an index-derived map would silently mis-decode every flag
# above the first hole -- and a mis-decode here reads as a passing gate, not as an
# error.
FLAG_BIT = {
    "DEGEN_SIGHTING":     1 << 2,
    "NO_DECODE_CHANNEL":  1 << 5,
    "CELLS_TRUNCATED":    1 << 8,
    "MIXED_POOL":         1 << 15,
}
FLAGS = sorted(FLAG_BIT, key=FLAG_BIT.get)


def _parse_case_fields(l):
    """Parse one CASE| line from the C driver into (name, stats-dict).  The tuple width
    is the assertion: a column added or dropped in the C without a matching change here
    unpacks short and fails loudly, which no other consumer of this line does."""
    f = l.split("|")
    (_, name, obs, k, k_eff, k_runs, n_degen, R_usable, tier,
     flags, R, first_sight, frames) = f
    return name, dict(
        obs=obs, k=int(k), k_eff=int(k_eff), k_runs=int(k_runs),
        n_degen=int(n_degen), R=int(R), R_usable=int(R_usable),
        first_sight=int(first_sight), frames=int(frames),
        tier=tier, flags=int(flags, 16))


class _CompileFailed(Exception):
    """gcc rejected the case set.  Carries both streams, because the caller reports
    them: a compile failure that surfaced as a traceback would say which line of
    Python raised and not which line of C did not build."""

    def __init__(self, out, err):
        Exception.__init__(self, "the statistics layer does not compile")
        self.out, self.err = out, err


def _compile_and_run(header_dir, workdir):
    """Build the C case set in workdir against header_dir's het_verdict.h, run it and
    return its stdout lines.  Raises _CompileFailed if gcc rejects it."""
    shutil.copy(os.path.join(header_dir, "het_verdict.h"),
                os.path.join(workdir, "het_verdict.h"))
    src = os.path.join(workdir, "st.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(workdir, "st")
    cc = subprocess.run(["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
                         "-I", workdir, src, "-o", exe, "-lm"],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        raise _CompileFailed(cc.stdout, cc.stderr)
    return subprocess.run([exe], capture_output=True, text=True).stdout.splitlines()


def phase1(lines, quiet):
    print("===== PHASE 1: do the mirrored constants hold? =====")
    bad = 0
    # --- The mirror pins.  statscheck re-derives every statistic in Python, and the
    # header's knobs are hard-coded there rather than read from it.  No fixture
    # straddles their boundaries, so a differential CANNOT notice the drift: move
    # HET_THETA_DISTINCT by one and every decode count in this file keeps its truth
    # value on both sides while the gate stays green on a stale mirror.
    seen_mirror = False
    for l in lines:
        if not l.startswith("MIRROR|"):
            continue
        seen_mirror = True
        _, td, mc, cr = l.split("|")
        for have, want, macro, what in (
                (int(td), THETA_D, "HET_THETA_DISTINCT",
                 "the degeneracy guard's floor: the mirror would call cells "
                 "degenerate that the C does not, or the reverse"),
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
                  "MAX_CELLS=%d, CORROB_RUNS=%d" % (int(td), int(mc), int(cr)))
    if not seen_mirror:
        print("  *** no MIRROR| line: the header's THETA_D / MAX_CELLS / "
              "CORROB_RUNS are not being compared to statscheck's Python mirrors "
              "at all")
        bad += 1

    if bad:
        print("\nINPUTS FAILED: %d problem(s).  A stale mirror derives the Python "
              "reference from a different header than the C." % bad)
        return 1
    print("\nINPUTS OK (the three mirrored knobs are COMPARED to the header, not "
          "assumed)")
    return 0


def phase2(lines, quiet):
    print("\n===== PHASE 2: is het_stats_compute() a statistic, or a constant? =====")
    bad = 0
    seen_obs, seen_flags, seen_tier = set(), set(), set()
    blocks, cur, buf = {}, None, []
    got = {}

    for l in lines:
        if l.startswith("CASE|"):
            name, rec = _parse_case_fields(l)
            got[name] = rec
            seen_obs.add(rec["obs"])
            seen_tier.add(rec["tier"])
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

        # (a) The differential: every statistic, independently re-derived.
        for fld in ("obs", "k", "k_eff", "k_runs", "n_degen", "R", "R_usable",
                    "tier", "first_sight", "frames"):
            if g[fld] != ref[fld]:
                errs.append("%s: C %s != py %s" % (fld, g[fld], ref[fld]))

        # (b) the case's own expectations
        w = c["want"]
        for fld, val in w.items():
            if fld in ("flags_any", "flags_none"):
                continue
            if g[fld] != val:
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
            print("      %-44s obs=%-9s k=%d/%d tier=%-12s %s"
                  % (name, g["obs"], g["k"], g["R"], g["tier"],
                     ",".join(f for f in FLAGS if g["flags"] & FLAG_BIT[f])))

    # ---- The anti-constant assertions --------------------------------------
    print()
    want_obs = {"VOID", "Never", "Sometimes", "Always"}
    miss = want_obs - seen_obs
    print("  observation classes : %d/%d  (%s)"
          % (len(seen_obs), len(want_obs), ", ".join(sorted(seen_obs))))
    if miss:
        print("  *** UNREACHABLE: %s -- the class is a constant on this input space"
              % ", ".join(sorted(miss)))
        bad += 1

    want_tier = {"none", "UNCONFIRMED", "CORROBORATED"}
    print("  corroboration tiers : %d/%d  (%s)"
          % (len(seen_tier), len(want_tier), ", ".join(sorted(seen_tier))))
    if want_tier - seen_tier:
        print("  *** UNREACHABLE TIER: %s" % ", ".join(sorted(want_tier - seen_tier)))
        bad += 1

    need_flags = {"DEGEN_SIGHTING", "NO_DECODE_CHANNEL", "CELLS_TRUNCATED",
                  "MIXED_POOL"}
    print("  diagnostic flags    : %d/%d  (%s)"
          % (len(seen_flags & need_flags), len(need_flags),
             ", ".join(sorted(seen_flags))))
    if need_flags - seen_flags:
        print("  *** UNREACHABLE FLAG: %s -- a diagnostic that never fires is not a "
              "diagnostic" % ", ".join(sorted(need_flags - seen_flags)))
        bad += 1

    # The printout is the deliverable, NOT the flag.  A null says in words that no
    # rate and no probability rides on it, that nothing certifies the harness, that
    # it is characterization and not validation, and what it cost -- a flag nobody
    # reads is not what a reader files the result under.  The effort clause is
    # pinned against the numbers the mirror re-derived rather than merely required
    # to exist, so a block that printed a constant effort would fail here.
    for name, g in sorted(got.items()):
        txt = blocks.get(name, "")
        if g["obs"] != "Never":
            continue
        r = refs.get(name, {})
        for frag, why in (
                ("NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
                 "it does not say that nothing is attached to the null"),
                ("NOTHING VOUCHES FOR THIS HARNESS",
                 "it does not say that nothing certifies the reach it reports"),
                ("CHARACTERIZATION, NEVER VALIDATION",
                 "it does not say the null agrees with no model and refutes none"),
                ("effort: %d run(s)" % r.get("R_usable", -1),
                 "it does not disclose the effort behind the zero"),
                ("%d frames examined" % r.get("frames", -1),
                 "the effort line does not carry the frames this pool examined")):
            if frag not in txt:
                print("  *** %s reports a Never but %s" % (name, why))
                bad += 1

    # The CPU-only sentence, BOTH ways.  het_stats_print carries it inside the
    # sighting tier and nowhere else, so the campaigns entitled to it are the ones
    # the mirror resolves to cpu_only with a tier to print it under -- keyed on that
    # rather than on a case name, so a fixture whose pool resolves the flag is covered
    # by construction.  Why both directions: verify/verdictcheck.py's CPU_ONLY_TEXT,
    # which pins the per-run twin.
    for name in sorted(refs):
        owed = bool(refs[name]["cpu_only"] and refs[name]["tier"] != "none")
        said = CPU_ONLY_TEXT in blocks.get(name, "")
        if owed and not said:
            print("  *** %s is a CPU-only campaign but its printout never says so"
                  % name)
            bad += 1
        elif said and not owed:
            print("  *** %s printed the CPU-only sentence, which belongs to a cycle "
                  "whose every proc is a CPU proc" % name)
            bad += 1

    # ... and the machine-readable twin of that sentence, which prints on every
    # campaign rather than on the sighting tier alone.  het_stats_line's field is what
    # hetlitmus/campaign.py schedules off, so it is asserted against the same Python
    # re-derivation as the statistics: a constant there is invisible to the sentence
    # above, and on a mixed pool the field is the ONLY reader of the upward
    # resolution.
    for name in sorted(refs):
        line = next((l for l in blocks.get(name, "").splitlines()
                     if CPU_ONLY_LINE.match(l)), "")
        want = "cpu_only=%d" % refs[name]["cpu_only"]
        if want not in line:
            print("  *** %s pools %s, but its HetStats line says %r"
                  % (name, "a CPU-only cell" if refs[name]["cpu_only"]
                     else "no CPU-only cell", line[:64]))
            bad += 1

    # ALWAYS is the class that says "every run fired", so it may be reported only
    # where every run did.  Nothing co-runs, so a cell is usable partly BECAUSE it
    # fired: a denominator that collapsed onto the usable count would report ALWAYS
    # for a row that fired in 3 runs of 10, and the printed class is what a reader
    # files the row under.  Asserted here as well as differentially, because both
    # mirrors reading R_usable would agree with each other and with nothing else.
    for name, g in sorted(got.items()):
        if 0 < g["k"] < g["R"] and g["obs"] == "Always":
            print("  *** %s reports ALWAYS on k=%d of R=%d: the denominator "
                  "collapsed onto the runs that fired" % (name, g["k"], g["R"]))
            bad += 1

    if bad:
        print("\nAGGREGATE FAILED: %d problem(s)." % bad)
        return 1
    print("\nAGGREGATE OK (%d cases; every statistic matches an independent Python "
          "re-derivation; every class, tier and flag reachable)" % len(CASES))
    return 0


# ---------------------------------------------------------------------------
def phase4(tamper=None):
    print("\n===== PHASE 4: does the EMITTED CORPUS carry the statistics machinery? "
          "=====")
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    tmp = tempfile.mkdtemp(prefix="statscorpus.")
    n_sync = n_obs = n_neither = n_stats = n_stop = 0
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
            if "het_stats_compute" in src:
                n_stats += 1
            # Every harness carries the adaptive stop.
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
                            ("stats post-pass", n_stats, CENSUS_TESTS),
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
# PHASE 5a -- the stopping rule.
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
        # What the UNCONFIRMED stop is allowed to say, and where it must say nothing.
        # It is the one outcome whose name is not its meaning, so it carries one
        # sentence -- and the sentence must NOT creep onto the other stops, where it
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
# PHASE 5b -- the scheduler, end to end, against a stub runner.  campaign.py spends
# (or saves) the hardware hours and none of its policy needs a GPU: the HetStats line
# is its whole interface.  The stub emits deterministic lines per (test, invocation),
# so the pooling arithmetic and the stop decisions are pinned exactly -- a null pools
# STUB_R runs an invocation and is ended by its STUB_BUDGET budget.
#
# What is pinned here is that campaign.py applies het_verdict.h's rule at the pooled
# scale: one policy for every row, corroboration before the confirmation window before
# the budget, rate mode disabling the sighting stop ALONE, and the mirror that keeps
# the two copies of the rule from drifting.  The fixtures are named for the behaviour
# they drive, since no class of row is left to name them after.
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


def line(obs, k, k_eff, k_runs, degen, first_sight, sighting):
    """One HetStats machine line, in het_stats_line's field ORDER and field SET: a
    stub speaking a shape the runtime cannot produce tests a protocol nobody
    implements."""
    print("HetStats %s cpu_only=0 obs=%s R=%d usable=%d k=%d k_eff=%d k_runs=%d "
          "degen=%d first_sight=%d sighting=%s N=100000 frames=100000 flags=0x0"
          % (test, obs, R, R, k, k_eff, k_runs, degen, first_sight, sighting))


NULL = ("Never", 0, 0, 0, 0, 0, "none")
FIRED = ("Sometimes", 1, 1, 1, 0, 1, "UNCONFIRMED")
if test == "NULL-pooled":
    line(*NULL)
elif test == "SIGHT-corrob":
    # One clean sighting in one distinct run EVERY invocation: the pooled k_runs
    # reaches HET_CORROB_RUNS at invocation 2, and nothing further is bought.
    line(*FIRED)
elif test == "SIGHT-lone":
    # Fires ONCE, in the first invocation, and never again: the row is held open by
    # the confirmation window and by nothing else.
    line(*(FIRED if inv == 1 else NULL))
elif test == "SIGHT-late":
    # Fires ONCE, at the FIFTH invocation, and never again.  Its window opens 40 runs
    # into a 100-run budget, and what it is owed from there is a WHOLE window -- a
    # row whose window is measured from run 0 has none of it left and is banked
    # UNCONFIRMED the moment it fires.
    line(*(FIRED if inv == 5 else NULL))
elif test == "SIGHT-degen":
    # A sighting the decode guard REJECTED (k=1, k_eff=0).  It corroborates nothing
    # and holds nothing open, so the row runs to its budget.
    line("Sometimes", 1, 0, 0, 1, 0, "UNCONFIRMED")
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


def _run_campaign(stub, corpus, state, extra, campaign_py=None):
    return subprocess.run(
        [sys.executable, campaign_py or CAMPAIGN, "--corpus", corpus,
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


def _mirror_bite(tmp, name, doctor, want_frag, quiet, campaign_py=None):
    """campaign.py's mirror, against a doctored copy of the header.  A mirror nothing
    ever contradicts is not a mirror, so BOTH halves of it are contradicted here."""
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
         % os.path.dirname(campaign_py or CAMPAIGN), hdr],
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
    """The printed sentence has to add up.  The summary says where each flagged row's
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


def phase6_campaign(quiet, campaign_py=None):
    """`campaign_py' is the scheduler under test.  It is a parameter so --bite can
    point the phase at a doctored copy: nothing else here reaches campaign.py, and a
    phase no injection reaches is a phase nobody has seen fail."""
    campaign_py = campaign_py or CAMPAIGN
    print("\n===== PHASE 6: does the scheduler spend the hours where the brief "
          "says? =====")
    tmp = tempfile.mkdtemp(prefix="statssched.")
    bad = 0
    try:
        # --- 6.0: the mirror.  campaign.py carries its own copy of the corroboration
        # bar and of every stop-name string, and it travels without the repo, so
        # nothing but this check stands between the two policies drifting.  It must
        # pass against the shipped header and FATAL against a doctored one.
        loader = ("import sys; sys.path.insert(0, %r); import campaign; "
                  % os.path.dirname(campaign_py))
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
            "HET_CORROB_RUNS", quiet, campaign_py)
        bad += _mirror_bite(
            tmp, "a renamed stop",
            lambda s: s.replace('case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CORROBORATED";',
                                'case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CONFIRMED";', 1),
            "stop names", quiet, campaign_py)
        # ... and the third piece of the policy a name cannot carry: where the
        # confirmation window starts.  A header that measures it from run 0 ends rows
        # this scheduler would still be running.
        bad += _mirror_bite(
            tmp, "a window measured from run 0",
            lambda s: s.replace("if (n - st.n_at_first_sight >= confirm_runs)",
                                "if (n >= confirm_runs)", 1),
            "n_at_first_sight", quiet, campaign_py)
        # A header out of reach is the travelling-copy case: the mirror stands rather
        # than dying, or campaign.py could not run on the box it was copied to.
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

        # --- 6.1: the policy, end to end.
        corpus = _mk_corpus(tmp, "corpus", STUB_TESTS)
        state = os.path.join(tmp, "state.csv")
        r = _run_campaign(stub, corpus, state, [], campaign_py)
        out = r.stdout

        # A crash exits 1 too.  This fixture set ends one row UNCONFIRMED-SIGHTING, so
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
            # A null is ended by the budget and by NOTHING else: STUB_R runs an
            # invocation, so the budget lands in the tenth.  Nothing the harness
            # reports about a null shortens that.
            "NULL-pooled": ("BUDGET", 10),
            # clean sightings pool to k_runs >= HET_CORROB_RUNS at invocation 2.
            "SIGHT-corrob": ("CORROBORATED", 2),
            # one sighting in the first run, then nulls: held open by the window
            # (CONFIRM runs after the run it fired in, so through run 31) and ended by
            # it in the fourth invocation -- NOT by the budget.
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
        # The flagged row is called out AND says what it is: a lone sighting the
        # window closed on, which STANDS as an observation and has to be reproduced
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

        # The CPU-only precondition is louder when it did not run than when it failed:
        # this corpus holds no CPU-only row, so the probe did not run and must say so.
        if "write-back probe (CPU-only positive control): *** NOT RUN" not in out:
            print("  *** the CPU-only write-back probe is silently absent -- a "
                  "precondition nobody sees is a precondition nobody checked")
            bad += 1

        # --- 6.1b: what a null is worth is the effort that failed to see it, so the
        # row the pooled null leaves in the state file carries every run its budget
        # bought.  It is read by column name, so it also pins the columns it names: one
        # renamed or dropped reads None here and fails.  `usable' does not
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

        # Every invocation carries a fresh seed base (seed0 + i*stride) and the
        # adaptive knobs -- a replayed seed adds no new phase draws -- and the run count
        # the row is ENTITLED to.  HET_RUNS_MAX is how a budget becomes ten invocations
        # of STUB_R rather than ten of the whole budget: unchecked, the last invocation
        # of a nearly-spent row overshoots by a whole invocation.  The harness applies
        # the same rule inside the invocation, so it also gets HET_RATE and
        # HET_CONFIRM_RUNS -- a harness told a different policy from the scheduler's
        # would stop on its own terms.
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

        # --- 6.2: the confirmation window outranks the budget, in hardware hours.
        # The same lone-sighting row under a budget smaller than the window: it must
        # NEITHER stop at BUDGET nor be curtailed to it -- the row runs past the budget
        # to the window and ends UNCONFIRMED-SIGHTING there.  Without the precedence
        # this row banks "seen once, stopped looking" at 20 runs.
        lone = _mk_corpus(tmp, "lone", ["SIGHT-lone"])
        r2 = subprocess.run(
            [sys.executable, campaign_py, "--corpus", lone,
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
            # 21 is the assertion: the entitlement is the window's end (run 31), NOT
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

        # --- 6.2b: a late sighting gets a WHOLE window, not the remains of one that
        # opened at run 0.  This row fires once, in its fifth invocation (run 41 of the
        # budget), so its window closes at run 71 and the row ends in the eighth.
        # Measured from run 0 the window is long gone when the sighting lands: the row
        # is banked UNCONFIRMED the moment it fires, having run none of the runs the
        # window exists to buy.
        late = _mk_corpus(tmp, "late", ["SIGHT-late"])
        r2b = subprocess.run(
            [sys.executable, campaign_py, "--corpus", late,
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

        # --- 6.3: --rate disables the sighting stop and NOTHING else.  The row that
        # corroborates at invocation 2 above now runs to its budget, and the null,
        # which no sighting stop was holding anyway, ends exactly where it did.
        rate = _mk_corpus(tmp, "rate", ["SIGHT-corrob", "NULL-pooled"])
        r3 = _run_campaign(stub, rate, os.path.join(tmp, "rate.csv"), ["--rate"],
                           campaign_py)
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

        # Fail closed: a named test with no harness dir kills the campaign (rc=2).
        r4 = subprocess.run(
            [sys.executable, campaign_py, "--corpus", corpus, "--runner", "true",
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
          "scale, the confirmation window outranks the budget, --rate disables the "
          "sighting stop alone, and the mirror rejects a moved bar, a renamed stop or "
          "a moved window origin.")
    return 0


# ---------------------------------------------------------------------------
# The header-driven phases, in print order.  1, 2 and 5 all read ONE compiled run
# of the layer, so a caller that names only the phases its subject can reach still
# builds one program.
GATE_PHASES = ("1", "2", "5")


def run(header_dir, tmp, quiet, phases=GATE_PHASES, campaign_py=None):
    out = None
    if {"1", "2", "5"} & set(phases):
        try:
            out = _compile_and_run(header_dir, tmp)
        except _CompileFailed as e:
            print(e.out + e.err)
            print("\nSTATSCHECK FAILED: the statistics layer does not compile")
            return 1
    rc = 0
    for p in ("1", "2", "5", "6"):
        if p not in phases:
            continue
        if p == "1":
            rc |= phase1(out, quiet)
        elif p == "2":
            rc |= phase2(out, quiet)
        elif p == "5":
            rc |= phase5_stops(out, quiet)
        else:
            rc |= phase6_campaign(quiet, campaign_py)
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
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= phase4()
    rc |= run(None, None, a.quiet, phases=("6",))

    print("\n" + "=" * 70)
    if rc:
        print("STATSCHECK: FAIL")
    else:
        print("STATSCHECK: PASS  (inputs + aggregate + corpus + stopping rule "
              "+ scheduler)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: every injection below is a way this layer could ship a constant while
# compiling cleanly and passing every structural gate.  Each is verified to have
# actually changed the file (one that matched nothing would pass for free), names the
# phases it can reach, and must redden one of them with a diagnostic carrying its own
# reason -- the fixture that moved and WHICH way it moved.
# ---------------------------------------------------------------------------
def _subst(s, pairs):
    """Apply (find, replace) pairs, failing loudly if any `find' matched nothing.
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
    fragment of `expect'.  BOTH halves are required of a fragment pair -- the fixture
    that moved and which way it moved -- because a phase reddening on some other
    fixture is another injection's evidence, not this one's."""
    want = (expect,) if isinstance(expect, str) else expect
    for l in said.splitlines():
        s = l.strip()
        if s.startswith("***") and all(w in s for w in want):
            return s
    return None


def _bite(label, hdir, mutate, phases, expect):
    """`phases' are the ones this injection can reach, `expect' the diagnostic it has
    to produce there.  A nonzero exit is not enough on its own: a red for another
    reason would let a broken injection stand in for a live gate."""
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
        bdir = os.path.join(sub, os.path.basename(hdir))
        os.makedirs(bdir)
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


def _bite_campaign(label, mutate, expect):
    """Doctor a copy of campaign.py and require phase 6 to redden by name.

    The copy keeps campaign.py's own path shape -- <root>/hetlitmus/campaign.py beside
    <root>/litmus/het-runtime/het_verdict.h -- because campaign.py resolves the header
    it mirrors relative to itself, and a copy that cannot reach one would redden phase
    6 for being out of reach rather than for the injection."""
    tmp = tempfile.mkdtemp(prefix="statscampbite.")
    said = io.StringIO()
    try:
        hetl = os.path.join(tmp, "hetlitmus")
        hrt = os.path.join(tmp, "litmus", "het-runtime")
        os.makedirs(hetl)
        os.makedirs(hrt)
        shutil.copy(os.path.join(ROOT, "litmus", "het-runtime", "het_verdict.h"), hrt)
        with open(CAMPAIGN) as fh:
            orig = fh.read()
        new = mutate(orig)
        if new == orig:
            print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
            return False
        cp = os.path.join(hetl, "campaign.py")
        with open(cp, "w") as fh:
            fh.write(new)
        with contextlib.redirect_stdout(said):
            rc = run(None, None, True, phases=("6",), campaign_py=cp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    hit = _named(said.getvalue(), expect)
    if rc and hit:
        print("  BITES (P6): %s   [%s]" % (hit[:104], label))
        return True
    print("  *** DID NOT BITE for its own reason (P6 rc=%d, wanted %r)   [%s]"
          % (rc, expect, label))
    for l in said.getvalue().splitlines():
        if l.strip().startswith("***"):
            print("        | " + l.strip()[:140])
    return False


def bite():
    print("===== BITE TEST: does this gate FAIL when the statistics break? =====")
    tmp = tempfile.mkdtemp(prefix="statsbite.")
    ok = True
    try:
        hdir = emit_harness(tmp)

        # (1) The DENOMINATOR collapsed onto the usable cells.  Nothing co-runs, so a
        # cell is usable partly BECAUSE it fired: scored that way a row that fired in
        # 3 runs of 10 reports ALWAYS -- the class a reader files it under -- while
        # every count on the line stays right.  This is the one way this layer can
        # overclaim.
        ok &= _bite("the denominator collapsed onto the usable cells (3 of 10 reads "
                    "as ALWAYS)", hdir,
                    lambda s: _subst(s, [("  { int denom = st->R;\n",
                                          "  { int denom = st->R_usable;\n")]),
                    ("2",), ("fired-3-of-10-is-SOMETIMES-not-ALWAYS",
                             "obs: C Always != py Sometimes"))

        # (2) The degeneracy guard disabled: a decoder that never varied could then
        # forge a CORROBORATED sighting out of a constant read.
        ok &= _bite("the degeneracy guard disabled (a constant read can forge a "
                    "corroborated sighting)", hdir,
                    lambda s: s.replace(
                        "static int het_cell_degenerate(const het_obs_record *r) {",
                        "static int het_cell_degenerate(const het_obs_record *r) {\n"
                        "  if (r) return 0;"),
                    ("5",), ("degenerate-sightings-never-stop",
                             "CORROBORATED, want CONTINUE"))

        # (3) The corroboration guard gutted: ONE un-reproduced sighting would stop
        # the row and bank a sighting nothing reproduced.
        ok &= _bite("the stop rule corroborates on ONE sighting (an unreproduced "
                    "sighting banked)", hdir,
                    lambda s: s.replace(
                        "    if (st.tier == HET_SIGHT_CORROBORATED) "
                        "return HET_CAMPAIGN_STOP_CORROBORATED;",
                        "    if (st.k > 0) return HET_CAMPAIGN_STOP_CORROBORATED;"),
                    ("5",), ("one-clean-sighting-does-not-stop",
                             "CORROBORATED, want CONTINUE"))

        # (4) Rate mode ignored: the row that was to run on and yield a rate stops at
        # its first corroborated sighting instead, and the campaign measures nothing it
        # was asked to measure.
        ok &= _bite("rate mode ignored (a sighting stops the row anyway)", hdir,
                    lambda s: s.replace("  if (st.k_eff > 0 && !rate_mode) {",
                                        "  if (st.k_eff > 0) {"),
                    ("5",), ("rate-mode-does-not-stop-on-a-corroborated-sighting",
                             "CORROBORATED, want CONTINUE"))

        # (5) The confirmation window never closes: a lone sighting holds the row open
        # forever, and UNCONFIRMED-SIGHTING -- the one flagged outcome -- becomes
        # unreachable while the row silently eats the budget it was allowed to outrun.
        ok &= _bite("the confirmation window never closes (a lone sighting runs "
                    "forever)", hdir,
                    lambda s: s.replace(
                        "    if (n - st.n_at_first_sight >= confirm_runs)",
                        "    if (0)"),
                    ("5",), ("lone-sighting-at-the-confirm-window-stops-unconfirmed",
                             "CONTINUE, want UNCONFIRMED-SIGHTING"))

        # (6) The window measured from run 0: it then closes on a row that fires late
        # before that row has run any of it, and UNCONFIRMED-SIGHTING -- the outcome
        # that says "we looked and it did not come back" -- is written over a row
        # nobody looked at again.
        ok &= _bite("the confirmation window measured from run 0 (a late sighting "
                    "gets none of it)", hdir,
                    lambda s: s.replace(
                        "    if (n - st.n_at_first_sight >= confirm_runs)",
                        "    if (n >= confirm_runs)"),
                    ("5",), ("lone-sighting-below-the-confirm-window-continues",
                             "UNCONFIRMED-SIGHTING, want CONTINUE"))

        # (7) The corroboration bar moved: HET_CORROB_RUNS is what both sides of the
        # tier fixtures are sized from and what the MIRROR| line pins, so a header that
        # quietly raises it must redden by NAME.
        ok &= _bite("the corroboration bar raised (HET_CORROB_RUNS 2 -> 3)", hdir,
                    lambda s: s.replace("#define HET_CORROB_RUNS 2",
                                        "#define HET_CORROB_RUNS 3"),
                    ("1",), "MIRROR DRIFT: HET_CORROB_RUNS is 3 in the header")

        # (8) The record stamp stops being checked: het_stats_compute reuses
        # het_verdict() per cell, so an unstamped stream would score as a live one and
        # the aggregate would report a result over memset zeros.
        ok &= _bite("rec_magic no longer fails closed inside the aggregate", hdir,
                    lambda s: s.replace("  if (r->rec_magic != HET_REC_MAGIC) {",
                                        "  if (0) {"),
                    ("5",), ("unstamped-sightings-earn-no-corroboration",
                             "CORROBORATED, want BUDGET"))

        # ---- The structural invariants ------------------------------------------
        # This family of assertions guards structure the shipped header enforces
        # unconditionally -- a clamp, a conjunct, a dedup, a flag -- so no injection
        # above can redden one of them, and an assertion NEVER seen to fail is not
        # evidence that it is compared.  Each injection below deletes the one line
        # that makes one of them true.

        # (9) The run dedup deleted: several cells of ONE run then count as several
        # runs, so sightings from a single thermal/phase draw corroborate each other --
        # a sighting "corroborated" by itself.
        ok &= _bite("the run dedup deleted (cells of ONE run corroborate each other)",
                    hdir,
                    lambda s: _subst(s, [(
                        "        for (j = 0; j < nruns; j++) "
                        "if (runs[j] == recs[i].run_id) seen = 1;",
                        "        for (j = 0; j < nruns; j++) if (0) seen = 1;")]),
                    ("2",), ("sighting-unconfirmed-3-cells-of-ONE-run",
                             "k_runs: C 3 != py 1"))

        # (10) The truncation stops saying it truncated: the tail is still discarded
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

        # ---- The Python mirrors -------------------------------------------------
        # (11)-(12) Move a mirrored macro in the header and leave statscheck's Python
        # copy behind.  The MIRROR| comparison in phase 1 is what names each drift, and
        # for THETA_DISTINCT it is the ONLY thing that can: every fixture sits far from
        # that boundary, so each comparison keeps its truth value on both sides of the
        # move and the differential stays green on a mirror that no longer describes
        # the header.  MAX_CELLS is not like that -- the truncation fixture is sized
        # from it, so the differential moves too -- but phase 1 is still where the
        # drift is named.
        ok &= _bite("HET_THETA_DISTINCT moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_THETA_DISTINCT 2",
                                          "#define HET_THETA_DISTINCT 3")]),
                    ("1",), "MIRROR DRIFT: HET_THETA_DISTINCT is 3 in the header")
        ok &= _bite("HET_STATS_MAX_CELLS moved under the Python mirror", hdir,
                    lambda s: _subst(s, [("#define HET_STATS_MAX_CELLS 128",
                                          "#define HET_STATS_MAX_CELLS 129")]),
                    ("1",), "MIRROR DRIFT: HET_STATS_MAX_CELLS is 129 in the header")

        # (13)-(16) The CPU-only sentence inverted.  One injection reaches BOTH halves of
        # the assertion at once: the CPU-only campaign loses the sentence that says
        # what was under test, and every other sighting gains it.
        print("\n-- the CPU-only campaign sentence --")
        ok &= _bite("the CPU-only sentence keyed on the negation of the flag", hdir,
                    lambda s: _subst(s, [
                        ("    if (_s->cpu_only)\n", "    if (!_s->cpu_only)\n")]),
                    ("2",),
                    (CPU_ONLY_CASE, "never says so"))
        # ... and the two readers of that flag no sentence covers: the field
        # campaign.py schedules off, and the resolution that decides what the field
        # says on a pool holding both kinds of cell.
        ok &= _bite("the HetStats line's cpu_only field keyed on the negation of "
                    "the flag", hdir,
                    lambda s: _subst(s, [
                        ("    _s->cpu_only,\n", "    !_s->cpu_only,\n")]),
                    ("2",),
                    (CPU_ONLY_CASE, "its HetStats line says"))
        ok &= _bite("the upward resolution dropped (a mixed pool reads as a het "
                    "campaign)", hdir,
                    lambda s: _subst(s, [
                        ("          if (recs[_i].cpu_only) st->cpu_only = 1;\n",
                         "")]),
                    ("2",),
                    (MIXED_POOL_CASE, "its HetStats line says"))
        ok &= _bite("the mixed-pool flag never raised (two experiments pooled as "
                    "one, silently)", hdir,
                    lambda s: _subst(s, [
                        ("          st->flags |= HET_ST_MIXED_POOL;\n", "")]),
                    ("2",),
                    (MIXED_POOL_CASE, "flag MIXED_POOL NOT set"))

        # (17) The scheduler's confirmation window measured from run 0.  Phase 6 is
        # the only reader of campaign.py, and the header-side twin of this defect is
        # already a mirror arm -- but the mirror compares the header against
        # campaign.py's names and numbers, NOT against its arithmetic, so the same
        # mistake made on this side is invisible to it.  A row that fired late then
        # banks the moment it fires, with none of its window run.
        print("\n-- the scheduler (campaign.py) --")
        ok &= _bite_campaign(
            "the confirmation window measured from run 0, not from the sighting",
            lambda s: s.replace(
                "elif self.runs - self.runs_at_first_sight >= confirm_runs:",
                "elif self.runs >= confirm_runs:", 1),
            ("SIGHT-lone", "want stop=UNCONFIRMED-SIGHTING"))

        # (18) The emitter stops tagging the decode channel: the guard would read a
        # structurally-zero skew_stddev as "degenerate" on the store-only tests and
        # call every one of their sightings an artefact.  ONLY phase 4 can see this.
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
        print("BITE OK: 18/18 injections caught -- denominator 1, decode guard 1,")
        print("         stop rule 6, structural invariants 2, Python mirrors 2,")
        print("         CPU-only campaign 4, scheduler 1, emitted corpus 1.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


if __name__ == "__main__":
    sys.exit(main())
