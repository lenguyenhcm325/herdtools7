#!/usr/bin/env python3
"""HetLitmus -- the statistics gate for het_stats_compute() (het_verdict.h).

Compiles the REAL emitted header and drives it with synthetic record streams:
  1  Inputs     the Python mirrors of the header's knobs are COMPARED to it.
  2  Aggregate  every statistic re-derived independently in Python; every class,
                tier and flag reachable; the fields campaign.py reads are fields
                the machine line prints.
  5  Stop rule  every reason reachable, each guard driven at its boundary.
  6  Scheduler  campaign.py end to end, against a stub runner.
A miss means the layer answers the same thing whatever it is handed.
What a null is worth: hetlitmus/docs/harness-reporting.md sec 4-5.  Usage: [-q]
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")
CAMPAIGN = os.path.join(ROOT, "hetlitmus", "campaign.py")

# The Python mirrors of the header's knobs.  No fixture straddles their boundaries,
# so a differential cannot notice drift: both are COMPARED in phase 1.
CORROB_RUNS = 2             # must match HET_CORROB_RUNS      (pinned via MIRROR|)
MAX_CELLS = 128             # must match HET_STATS_MAX_CELLS  (pinned via MIRROR|)


# ---------------------------------------------------------------------------
# Synthetic cells.  A cell is one (instance, run); BASE is a live, stressed,
# reportable run, and each case perturbs a few fields to isolate one reason.
# ---------------------------------------------------------------------------
BASE = dict(
    test_name='"synthetic"',
    # The stamp, by symbol: het_verdict() reads no field of a record without it.
    rec_magic="HET_REC_MAGIC",
    target_count=0,
    outcomes_vary=1,
    stress_truncated=0,
    gpu_stress_rounds=64,
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    cpu_aff_failures=0,
    place_failures=0,
    stress_requested=0x3D,
    N=100000,
    # The readout ran, every iteration was scored, none was discarded, and the caps
    # it waited under are a measurement: no fixture is COLD for a reason it did not set.
    rdv_valid=1,
    iters_scored=100000,
    iters_discarded=0,
    cap_calibrated=1,
    run_id=0,
)

# The fixtures are counts of records rather than sampled series: nothing is drawn.
CELLS = 10                        # the record stream most fixtures are R long
# One record more than the aggregate can hold.  litmus7 -r above the clamp hands
# het_stats_compute more cells than its array holds, and only the flag says so.
CELLS_TRUNC = MAX_CELLS + 1


def cell(**kw):
    r = dict(BASE)
    r.update(kw)
    return r


def stream(nc, **kw):
    """One record per run, run ids 0, 1, 2, ..."""
    return [cell(run_id=i, **kw) for i in range(nc)]


def stream_runs(run_ids, **kw):
    """stream() with explicit run ids, so a fixture can put several cells in ONE
    run -- the layout the tier's "distinct runs, not distinct cells" rule wants."""
    return [cell(run_id=r, **kw) for r in run_ids]


def observed(cells_, k, clean=True):
    """Make the first k cells see the target, optionally in a degenerate readout
    (every scored iteration read back one outcome vector), leaving the rest live."""
    for i in range(k):
        cells_[i]["target_count"] = 7
        if not clean:
            cells_[i]["outcomes_vary"] = 0
    return cells_


def observed_at(cells_, idx):
    """Make the cell at idx -- and ONLY it -- see the target, cleanly.  The
    confirmation window is measured from where the sighting lands."""
    observed(cells_[idx:idx + 1], 1)
    return cells_


CASES = []


def case(name, cells_, **want):
    CASES.append(dict(name=name, cells=cells_, want=want))


# ============================== The case set ===============================
case("never-over-ten-live-runs", stream(CELLS), obs="Never", R=CELLS,
     R_usable=CELLS, k=0)

# Observed at the (instance,run) unit, never at the frame.
case("sometimes-3-of-10-cells-not-frames", observed(stream(CELLS), 3),
     obs="Sometimes", k=3, k_eff=3)

case("always", observed(stream(CELLS), CELLS), obs="Always", k=CELLS)

# Every cell COLD-INVALID: R_usable is 0 and there is no reading at all, which is
# NOT the same answer as "Never".
case("void-when-every-cell-is-cold",
     stream(CELLS, stress_truncated=1),
     obs="VOID", R=CELLS, R_usable=0)

# The decode guard, on each of its three disjuncts.  A constant decode
# [Srivastava24 sec 4.1] is reported (k=3) and corroborates nothing (k_eff=0).
case("degenerate-sightings-rejected-but-reported",
     observed(stream(CELLS), 3, clean=False),
     obs="Sometimes", k=3, k_eff=0, n_degen=3,
     flags_any=["DEGEN_SIGHTING"], tier="UNCONFIRMED")

# ... and a sighting from a cell whose readout NEVER ran: its counts are memset
# zeros, so it is reported and counts toward no corroboration.
_dead_rdv = observed(stream(CELLS), 1)
_dead_rdv[0]["rdv_valid"] = 0
case("sighting-from-a-readout-that-never-ran-is-degenerate", _dead_rdv,
     obs="Sometimes", k=1, k_eff=0, n_degen=1, tier="UNCONFIRMED",
     flags_any=["DEGEN_SIGHTING"])

# ... and one from a cell that scored NOTHING: it read nothing back, so what the
# sighting was decoded from is not a measurement either.
_none_scored = observed(stream(CELLS), 1)
_none_scored[0]["iters_scored"] = 0
case("sighting-from-a-cell-that-scored-nothing-is-degenerate", _none_scored,
     obs="Sometimes", k=1, k_eff=0, n_degen=1, tier="UNCONFIRMED",
     flags_any=["DEGEN_SIGHTING"])

# The corroboration bar is on RUNS and both sides of it are driven: one run short
# is UNCONFIRMED, at the bar it is CORROBORATED.
case("sighting-corroborated-at-the-bar",
     observed(stream(CELLS), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS)

case("sighting-unconfirmed-one-run-short",
     observed(stream(CELLS), CORROB_RUNS - 1),
     obs="Sometimes", tier="UNCONFIRMED", k_runs=CORROB_RUNS - 1)

# The CPU-only campaign: het_stats_print says, inside the sighting tier and nowhere
# else, that no cross-device path carried the cycle [Goens23 sec 4.6].
CPU_ONLY_CASE = "cpu-only-sighting-says-what-was-under-test"
CPU_ONLY_TEXT = "CPU-ONLY CYCLE: every proc of this test is a CPU proc"
# The same fact machine-readably, on het_stats_line rather than in the tier block.
CPU_ONLY_LINE = re.compile(r"HetStats \S+ cpu_only=\d+ ")
case(CPU_ONLY_CASE,
     observed(stream(CELLS, cpu_only=1), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS)

# ... and a pool whose cells disagree, the only fixture that runs the upward
# resolution.  The disagreeing cell is not the first, which the rest are read against.
MIXED_POOL_CASE = "mixed-pool-resolves-cpu-only-upward"
_mixed = observed(stream(CELLS), CORROB_RUNS)
_mixed[CORROB_RUNS]["cpu_only"] = 1
case(MIXED_POOL_CASE, _mixed,
     obs="Sometimes", tier="CORROBORATED", k_runs=CORROB_RUNS,
     flags_any=["MIXED_POOL"])

# ... and the rule is about runs, NOT cells.  The only fixture where k_runs <
# k_eff, so the only one that runs the run-dedup loop.
case("sighting-unconfirmed-3-cells-of-ONE-run",
     observed(stream_runs([0, 0, 0] + list(range(1, 8))), 3),
     obs="Sometimes", k=3, k_eff=3, k_runs=1, tier="UNCONFIRMED")

# n_at_first_sight is a price in RUNS, so it is the run the first clean sighting
# landed in and not the count of sightings.
case("first-sight-is-priced-in-runs",
     observed(stream_runs([3, 4, 0, 1, 2, 5, 6, 7, 8, 9]), 1),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=1)

# ... and the same price at a late position: the fifth run of ten fires, so the
# price is 5 -- one-based, NEITHER the four spent before it nor a run id.
case("first-sight-counts-the-runs-spent-through-the-sighting",
     observed_at(stream(CELLS), 4),
     obs="Sometimes", k=1, k_eff=1, k_runs=1, tier="UNCONFIRMED",
     first_sight=5)

# Ten stamped null cells plus two whose every field is memset residue.  Nothing
# below rec_magic may be read; R keeps them, because the discard stays visible.
MIXED_STAMP_CELLS = stream(CELLS) + stream_runs([10, 11], rec_magic=0)
case("unstamped-cells-are-read-by-nothing",
     MIXED_STAMP_CELLS,
     obs="Never", R=CELLS + 2, R_usable=CELLS, scored=CELLS * 100000)

# The selection effect: the three that fired are usable BECAUSE they fired, so
# scoring over usable cells would report Always here.  The denominator is R.
case("fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(CELLS, stress_truncated=1), 3),
     obs="Sometimes", k=3, k_eff=3, R=CELLS, R_usable=3, scored=CELLS * 100000)

# ... and one unstamped cell must NOT undo it: counted into R alone, it moves the
# denominator and nothing else.  Same class and same scored total is the assertion.
case("plus-one-unstamped-cell-is-still-SOMETIMES",
     observed(stream(CELLS, stress_truncated=1), 3)
     + stream_runs([10], rec_magic=0),
     obs="Sometimes", k=3, k_eff=3, R=CELLS + 1, R_usable=3,
     scored=CELLS * 100000)

# ... and the same effect on a NULL, where a null's two numbers are told apart: the
# scoring statement is over the three usable cells, the effort over the ten runs.
NEVER_COLD_CASE = "never-over-three-live-runs-of-ten"
_never_cold = stream(CELLS)
for _c in _never_cold[3:]:
    _c["stress_truncated"] = 1
case(NEVER_COLD_CASE, _never_cold,
     obs="Never", k=0, R=CELLS, R_usable=3, scored=CELLS * 100000)

# The other half of that disclosure: every other fixture discards nothing, so
# without this one the discarded total is a constant zero over the whole input space.
DISCARD_CASE = "never-with-part-of-every-run-discarded"
case(DISCARD_CASE,
     stream(CELLS, iters_scored=60000, iters_discarded=40000),
     obs="Never", k=0, R=CELLS, R_usable=CELLS,
     scored=CELLS * 60000, discarded=CELLS * 40000)

# More runs than the aggregate can hold: the tail is dropped from every statistic,
# so st->R keeps the pre-clamp count and the flag says the discard happened.
case("cells-truncated-above-HET_STATS_MAX_CELLS", stream(CELLS_TRUNC),
     obs="Never", R=MAX_CELLS + 1, R_usable=MAX_CELLS,
     flags_any=["CELLS_TRUNCATED"])


# PHASE 5 -- every reason het_campaign_should_stop() gives is reachable, each
# guard driven at its boundary on synthetic records.
CONFIRM_RUNS = 30           # must match the driver's HET_CONFIRM_RUNS default
STOPS = []


def stop(name, cells_, budget, want, rate=0, confirm=CONFIRM_RUNS):
    STOPS.append(dict(name=name, cells=cells_, budget=budget,
                      want=want, rate=rate, confirm=confirm))


# A lone clean sighting does NOT stop: one run cannot rule out a per-run artefact.
stop("one-clean-sighting-does-not-stop",
     observed(stream(CELLS), 1),
     20, "CONTINUE")
# ... and neither does a degenerate one, at any count: the branch is on k_eff, not
# on the tier, and an artefact must never de-schedule a test.
stop("degenerate-sightings-never-stop",
     observed(stream(CELLS), 3, clean=False),
     20, "CONTINUE")
# The bar is HET_CORROB_RUNS distinct clean runs, and it is reached exactly there.
stop("sighting-corroborated-stops",
     observed(stream(CELLS), CORROB_RUNS),
     20, "CORROBORATED")
# The confirmation window at its boundary: the same lone sighting in the first of
# ten runs continues one run short of the window and stops at it.
stop("lone-sighting-below-the-confirm-window-continues",
     observed(stream(CELLS), 1),
     20, "CONTINUE", confirm=10)
stop("lone-sighting-at-the-confirm-window-stops-unconfirmed",
     observed(stream(CELLS), 1),
     20, "UNCONFIRMED-SIGHTING", confirm=9)
# The precedence, both ways: the budget is spent in both and NEITHER answers BUDGET,
# because a row ended there would bank "seen once, stopped looking".
stop("lone-sighting-outranks-the-budget-stop",
     observed(stream(CELLS), 1),
     5, "CONTINUE")
stop("the-window-not-the-budget-ends-a-lone-sighting",
     observed(stream(CELLS), 1),
     5, "UNCONFIRMED-SIGHTING", confirm=9)
# The window is measured from the sighting: a row that fired in its LAST run has
# spent none of it, and a sighting at run 5 of ten drives the boundary both ways.
stop("a-sighting-in-the-last-run-gets-its-window",
     observed_at(stream(CELLS), 9),
     20, "CONTINUE", confirm=5)
stop("late-sighting-inside-its-window-continues",
     observed_at(stream(CELLS), 4),
     20, "CONTINUE", confirm=6)
stop("late-sighting-past-its-window-stops-unconfirmed",
     observed_at(stream(CELLS), 4),
     20, "UNCONFIRMED-SIGHTING", confirm=5)
# Rate mode disables the sighting stop and NOTHING else: the row runs on to measure
# a rate, and its budget still stops it.
stop("rate-mode-does-not-stop-on-a-corroborated-sighting",
     observed(stream(CELLS), CORROB_RUNS),
     20, "CONTINUE", rate=1)
stop("rate-mode-still-stops-at-budget",
     observed(stream(CELLS), CORROB_RUNS),
     10, "BUDGET", rate=1)
# ... and rate mode is the operator's answer to an UNCONFIRMED row, so it must not
# be able to produce one: a lone sighting reaches its budget and is never banked.
stop("rate-mode-runs-a-lone-sighting-to-budget",
     observed(stream(CELLS), 1),
     10, "BUDGET", rate=1)
stop("cold-row-runs-to-budget",
     stream(CELLS),
     10, "BUDGET")
# An unstamped record earns no early stop: every cell is COLD-INVALID, so there is
# nothing to corroborate and the row spends its budget.
stop("unstamped-records-fail-closed-to-budget",
     stream(CELLS, rec_magic=0),
     10, "BUDGET")
# ... and the same when the unstamped stream is full of sightings in distinct runs:
# read, the residue would corroborate a harness the emitter built wrong.
stop("unstamped-sightings-earn-no-corroboration",
     observed(stream(CELLS, rec_magic=0), CORROB_RUNS),
     10, "BUDGET")
# A mixed stream decides from its stamped half ALONE: the two unstamped sightings
# would stop the row, the stamped ten are nulls, so the row spends its budget.
stop("mixed-stream-is-decided-by-its-stamped-half",
     (stream(CELLS)
      + observed(stream_runs([10, 11], rec_magic=0), 2)),
     12, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(cells_):
    # The record array is clamped at HET_STATS_MAX_CELLS and the tail is dropped
    # from every statistic; R keeps the pre-clamp count so the discard is visible.
    R = len(cells_)
    pool = cells_
    cells_ = cells_[:MAX_CELLS]
    n = len(cells_)

    def stamped(c):
        # het_verdict() reads no field of a record without the stamp, so neither
        # does anything derived from one.
        return c["rec_magic"] == "HET_REC_MAGIC"

    # The pool's identity, read before the clamp and resolved upward: ONE CPU-only
    # cell names the narrower experiment, so a het reading may not absorb it.
    cpu_only = 1 if any(c.get("cpu_only", 0) for c in pool if stamped(c)) else 0

    def degenerate(c):
        # Mirrors het_cell_degenerate: a readout that never ran, a cell that
        # scored nothing, and one whose every iteration read one vector.
        return (not c.get("rdv_valid", 0) or c["iters_scored"] == 0
                or not c["outcomes_vary"])

    def usable(c):
        # Mirrors het_verdict()'s COLD-INVALID.  Only stress_truncated is
        # perturbed here; the other disqualifiers are verdictcheck.py's subject.
        if not stamped(c):
            return False
        if c["target_count"] > 0:
            return True
        return c["stress_truncated"] == 0

    k = k_eff = n_degen = R_usable = first_sight = 0
    runs, allruns = [], []
    for c in cells_:
        # The stamp gates every read: NEITHER the run tally, nor the window sums,
        # nor the scored total may see residue.
        if not stamped(c):
            continue
        if usable(c):
            R_usable += 1
        y = c["target_count"] > 0
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

    # Nothing co-runs, so "usable" is defined partly by firing: the denominator is
    # R, the records SUPPLIED, i.e. PRE-clamp, as in the C.
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
                scored=sum(c["iters_scored"] for c in cells_ if stamped(c)),
                discarded=sum(c["iters_discarded"] for c in cells_ if stamped(c)),
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
  printf("CASE|%s|%s|%d|%d|%d|%d|%d|%s|0x%x|%d|%d|%llu|%llu\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.k_runs, st.n_degen,
         st.R_usable, het_sighting_name(st.tier), st.flags,
         /* st.R is the PRE-clamp record count: R > R_usable can mean cold cells,
            R > HET_STATS_MAX_CELLS means the tail was discarded. */
         st.R, st.n_at_first_sight,
         /* the effort totals: the iterations the readout scored, and the ones the
            rendezvous threw away before it could */
         (unsigned long long)st.iters_scored,
         (unsigned long long)st.iters_discarded);
  printf("PRINT-BEGIN|%s\n", name);
  het_stats_print(stdout, &st);
  printf("PRINT-END|%s\n", name);
}

/* PHASE 5 -- the campaign stopping rule, from the same synthetic records. */
static void stop_case(const char *name, const het_obs_record *recs, int n,
                      int budget, int rate_mode, int confirm_runs) {
  het_campaign_stop_t s = het_campaign_should_stop(recs, n, budget,
                                                   rate_mode, confirm_runs);
  printf("STOP|%s|%s|%s\n", name, het_campaign_stop_name(s),
         het_campaign_stop_why(s));
}

/* PHASE 1 -- the two constants the Python reference is derived from, emitted so
   they can be COMPARED: every fixture sits far from their boundaries. */
static void anchors(void) {
  printf("MIRROR|%d|%d\n", (int)HET_STATS_MAX_CELLS, (int)HET_CORROB_RUNS);
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
    subprocess.run(["litmus7", "-gpu-target", "cuda",
                    "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, os.path.join(HET_DIR, test + ".litmus")],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = os.path.join(out, test)
    if not os.path.exists(os.path.join(d, "het_verdict.h")):
        raise SystemExit("statscheck: litmus7 did not emit het_verdict.h")
    return d


# The bit number is WRITTEN DOWN, not derived from position: the header leaves
# retired bits vacant, so an index-derived map would mis-decode and read as green.
FLAG_BIT = {
    "DEGEN_SIGHTING":     1 << 2,
    "CELLS_TRUNCATED":    1 << 8,
    "MIXED_POOL":         1 << 15,
}
FLAGS = sorted(FLAG_BIT, key=FLAG_BIT.get)


def _parse_case_fields(l):
    """Parse one CASE| line into (name, stats-dict).  The tuple width is the
    assertion: a column added in the C without a change here unpacks short."""
    f = l.split("|")
    (_, name, obs, k, k_eff, k_runs, n_degen, R_usable, tier,
     flags, R, first_sight, scored, discarded) = f
    return name, dict(
        obs=obs, k=int(k), k_eff=int(k_eff), k_runs=int(k_runs),
        n_degen=int(n_degen), R=int(R), R_usable=int(R_usable),
        first_sight=int(first_sight), scored=int(scored),
        discarded=int(discarded), tier=tier, flags=int(flags, 16))


class _CompileFailed(Exception):
    """gcc rejected the case set.  Carries both streams: a traceback would say
    which line of Python raised and not which line of C did not build."""

    def __init__(self, out, err):
        Exception.__init__(self, "the statistics layer does not compile")
        self.out, self.err = out, err


def _compile_and_run(header_dir, workdir):
    """Build the C case set against header_dir's het_verdict.h, run it and return
    its stdout lines.  Raises _CompileFailed if gcc rejects it."""
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
    # A differential CANNOT notice this drift: move HET_CORROB_RUNS by one and
    # every fixture keeps its tier on both sides while the mirror goes stale.
    seen_mirror = False
    for l in lines:
        if not l.startswith("MIRROR|"):
            continue
        seen_mirror = True
        _, mc, cr = l.split("|")
        for have, want, macro, what in (
                (int(mc), MAX_CELLS, "HET_STATS_MAX_CELLS",
                 "the truncation fixture is sized from the mirror, so it would "
                 "stop reaching the truncation path"),
                (int(cr), CORROB_RUNS, "HET_CORROB_RUNS",
                 "the tier fixtures are sized from the mirror, so both sides of "
                 "the bar would move with it")):
            if have != want:
                print("  *** MIRROR DRIFT: %s is %d in the header, %d here -- %s"
                      % (macro, have, want, what))
                bad += 1
        if not quiet and not bad:
            print("      the Python mirrors match the header: MAX_CELLS=%d, "
                  "CORROB_RUNS=%d" % (int(mc), int(cr)))
    if not seen_mirror:
        print("  *** no MIRROR| line: the header's knobs are compared to nothing")
        bad += 1

    if bad:
        print("\nINPUTS FAILED: %d problem(s).  A stale mirror derives the Python "
              "reference from a different header than the C." % bad)
        return 1
    print("\nINPUTS OK (both mirrored knobs are COMPARED to the header)")
    return 0


# The HetStats line is the whole interface between a harness and its readers.
# campaign.py reads it by key, and fnum() reads a missing key as 0.0.
CONSUMER_KEY_RE = re.compile(r'fnum\(\s*kv\s*,\s*"(\w+)"')
LINE_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
# A reformat that hid call sites from the pattern would narrow this check instead
# of reddening it, so the count is pinned as well as the keys.
EXPECT_CONSUMER_KEYS = 7


def _consumer_keys():
    """The HetStats fields hetlitmus/campaign.py reads, off its source."""
    with open(CAMPAIGN) as fh:
        return sorted(set(CONSUMER_KEY_RE.findall(fh.read())))


def _stats_key_list(seg):
    """The ordered field names of one HetStats line -- printed, or a producer's
    format string unquoted -- or None: a real line runs cpu_only .. flags."""
    keys = []
    for k in LINE_KEY_RE.findall(seg):
        keys.append(k)
        if k == "flags":
            return keys if keys[0] == "cpu_only" else None
    return None


def _stand_in_lines():
    """Every HetStats line the gates under verify/ print themselves, as
    (file, line, field names), anchored on the line's TERMINATOR."""
    out = []
    for fn in sorted(f for f in os.listdir(HERE) if f.endswith(".py")):
        with open(os.path.join(HERE, fn)) as fh:
            txt = fh.read()
        for m in re.finditer(r"flags=0x", txt):
            head = txt.rfind("HetStats ", max(0, m.start() - 800), m.start())
            if head < 0:
                continue
            seg = txt[head + len("HetStats "):m.start() + 20]
            keys = _stats_key_list(" ".join(seg.replace('"', "").replace("'", "").split()))
            if keys is not None:
                out.append((fn, txt.count("\n", 0, head) + 1, keys))
    return out


def _keydiff(got, want):
    miss = [k for k in want if k not in got]
    extra = [k for k in got if k not in want]
    if miss or extra:
        return "missing %s, extra %s" % (miss or "none", extra or "none")
    return "the same fields in a different ORDER: %s, not %s" % (got, want)


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
                    "tier", "first_sight", "scored", "discarded"):
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
            print("  *** %-48s %s" % (name, "; ".join(errs)))
        elif not quiet:
            print("      %-48s obs=%-9s k=%d/%d tier=%-12s %s"
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

    need_flags = {"DEGEN_SIGHTING", "CELLS_TRUNCATED", "MIXED_POOL"}
    print("  diagnostic flags    : %d/%d  (%s)"
          % (len(seen_flags & need_flags), len(need_flags),
             ", ".join(sorted(seen_flags))))
    if need_flags - seen_flags:
        print("  *** UNREACHABLE FLAG: %s -- a diagnostic that never fires is not a "
              "diagnostic" % ", ".join(sorted(need_flags - seen_flags)))
        bad += 1

    # The printout is the deliverable, NOT the flag: the effort clause is pinned
    # against the numbers the mirror re-derived, so a constant effort fails here.
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
                ("effort: %d run(s)" % r.get("R", -1),
                 "it does not disclose the effort behind the zero"),
                ("%llu scored".replace("%llu", "%d") % r.get("scored", -1),
                 "the effort line does not carry the iterations this pool scored"),
                ("%llu discarded".replace("%llu", "%d") % r.get("discarded", -1),
                 "the effort line does not carry the iterations its rendezvous "
                 "threw away")):
            if frag not in txt:
                print("  *** %s reports a Never but %s" % (name, why))
                bad += 1

    # The CPU-only sentence, BOTH ways: het_stats_print carries it inside the
    # sighting tier and nowhere else, keyed on the mirror rather than on a name.
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

    # ... and its machine-readable twin, which prints on every campaign: on a
    # mixed pool the field is the ONLY reader of the upward resolution.
    for name in sorted(refs):
        line = next((l for l in blocks.get(name, "").splitlines()
                     if CPU_ONLY_LINE.match(l)), "")
        want = "cpu_only=%d" % refs[name]["cpu_only"]
        if want not in line:
            print("  *** %s pools %s, but its HetStats line says %r"
                  % (name, "a CPU-only cell" if refs[name]["cpu_only"]
                     else "no CPU-only cell", line[:64]))
            bad += 1

    # ... and the fields campaign.py reads, against the line the header just
    # printed: a key the printer never prints reads back 0 and schedules on it.
    real = next((l for b in sorted(blocks) for l in blocks[b].splitlines()
                 if CPU_ONLY_LINE.match(l)), None)
    keys = _consumer_keys()
    if real is None:
        print("  *** no HetStats line was printed at all, so the fields campaign.py "
              "reads are being compared against nothing")
        bad += 1
    elif len(keys) != EXPECT_CONSUMER_KEYS:
        print("  *** campaign.py reads %d HetStats field(s), expected %d: the "
              "consumer check narrowed instead of failing" % (len(keys),
                                                              EXPECT_CONSUMER_KEYS))
        bad += 1
    else:
        printed = LINE_KEY_RE.findall(real.split("HetStats ", 1)[1])
        missing = [k for k in keys if k not in printed]
        if missing:
            print("  *** campaign.py schedules off %s, which het_stats_line does "
                  "not print" % ", ".join(missing))
            bad += 1
        elif not quiet:
            print("  HetStats consumer   : campaign.py reads %d of the printed "
                  "line's %d field(s)" % (len(keys), len(printed)))

    # ... and the stand-ins that speak this line without a device: a gate driving
    # the scheduler off another field set tests a protocol nothing implements.
    want_keys = _stats_key_list(real.split("HetStats ", 1)[1]) if real else None
    if want_keys is None:
        print("  *** no HetStats line was printed at all, so the field set the "
              "stand-ins are held to is being read off nothing")
        bad += 1
    else:
        stand = _stand_in_lines()
        if not stand:
            print("  *** no gate under verify/ prints a HetStats line of its own: "
                  "this check has nothing to compare and is inspecting nothing")
            bad += 1
        for fn, ln, ks in stand:
            if ks != want_keys:
                print("  *** %s:%d speaks a HetStats line het_stats_line cannot "
                      "produce: %s" % (fn, ln, _keydiff(ks, want_keys)))
                bad += 1
        if not quiet:
            print("  HetStats stand-ins  : %d, each in the printed line's %d "
                  "field(s)" % (len(stand), len(want_keys)))

    # ALWAYS says "every run fired".  Asserted here as well as differentially:
    # both mirrors reading R_usable would agree with each other and nothing else.
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
def phase5_stops(lines, quiet):
    print("\n===== PHASE 5: does the stopping rule DECIDE, or always say one "
          "thing? =====")
    bad = 0
    got = {}
    for l in lines:
        if l.startswith("STOP|"):
            _, name, verdict, _why = l.split("|")
            got[name] = verdict
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
          "disables the sighting stop and nothing else)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 6 -- the scheduler, end to end, against a stub runner: the HetStats line
# is campaign.py's whole interface, and the stub emits deterministic lines.
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
# The real harness runs at most HET_RUNS_MAX runs, so the stub does too: a stub
# that ignored the cap would land on run counts no harness can produce.
R = min(10, int(os.environ.get("HET_RUNS_MAX") or "10"))


def line(obs, k, k_eff, k_runs, degen, first_sight, sighting):
    """One HetStats machine line, in het_stats_line's field ORDER and field SET."""
    print("HetStats %s cpu_only=0 obs=%s R=%d usable=%d k=%d k_eff=%d k_runs=%d "
          "degen=%d first_sight=%d sighting=%s N=100000 scored=100000 discarded=0 "
          "flags=0x0"
          % (test, obs, R, R, k, k_eff, k_runs, degen, first_sight, sighting))


NULL = ("Never", 0, 0, 0, 0, 0, "none")
FIRED = ("Sometimes", 1, 1, 1, 0, 1, "UNCONFIRMED")
if test == "NULL-pooled":
    line(*NULL)
elif test == "SIGHT-corrob":
    # One clean sighting in one distinct run EVERY invocation: the pooled k_runs
    # reaches HET_CORROB_RUNS at invocation 2.
    line(*FIRED)
elif test == "SIGHT-lone":
    # Fires ONCE, in the first invocation: the row is held open by the confirmation
    # window and by nothing else.
    line(*(FIRED if inv == 1 else NULL))
elif test == "SIGHT-late":
    # Fires ONCE, at the fifth invocation: its window opens 40 runs into a 100-run
    # budget, and what it is owed from there is a whole window.
    line(*(FIRED if inv == 5 else NULL))
elif test == "SIGHT-degen":
    # A sighting the decode guard REJECTED (k=1, k_eff=0): it corroborates nothing
    # and holds nothing open, so the row runs to its budget.
    line("Sometimes", 1, 0, 0, 1, 0, "UNCONFIRMED")
else:
    sys.exit(3)
'''

SEED_STRIDE = 100003     # must match campaign.py
# The budget phase 6 drives the campaign with, the confirmation window it passes,
# and the R every stub line reports: the HET_RUNS_MAX assertion is derived from them.
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


def _mirror_rejects(tmp, name, doctor, want_frag, quiet):
    """campaign.py's mirror, against a doctored copy of the header: it must FATAL,
    naming the piece of policy that moved."""
    hdr = os.path.join(tmp, "h-%s.h" % name)
    with open(os.path.join(ROOT, "litmus", "het-runtime", "het_verdict.h")) as fh:
        src = fh.read()
    new = doctor(src)
    if new == src:
        print("  *** VACUOUS MIRROR CONTROL %s: the injection matched nothing" % name)
        return 1
    with open(hdr, "w") as fh:
        fh.write(new)
    r = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import campaign; "
         "campaign.check_flag_mirror(path=sys.argv[1])"
         % os.path.dirname(CAMPAIGN), hdr],
        capture_output=True, text=True)
    if r.returncode != 2 or want_frag not in r.stderr:
        print("  *** the mirror did not FATAL on %s (rc=%d, stderr=%r) -- a scheduler "
              "applying a stale copy of the harness's policy is the drift the mirror "
              "exists to stop" % (name, r.returncode, r.stderr.strip()[-300:]))
        return 1
    if not quiet:
        print("      mirror rejects %-26s naming %s" % (name, want_frag))
    return 0


def phase6_campaign(quiet):
    print("\n===== PHASE 6: does the scheduler spend the hours where the brief "
          "says? =====")
    tmp = tempfile.mkdtemp(prefix="statssched.")
    bad = 0
    try:
        # --- 6.0: the mirror.  campaign.py carries its own copy of the
        # corroboration bar and of every stop name, and it travels without the repo.
        loader = ("import sys; sys.path.insert(0, %r); import campaign; "
                  % os.path.dirname(CAMPAIGN))
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
        bad += _mirror_rejects(
            tmp, "a moved corroboration bar",
            lambda s: s.replace("#define HET_CORROB_RUNS 2",
                                "#define HET_CORROB_RUNS 3", 1),
            "HET_CORROB_RUNS", quiet)
        bad += _mirror_rejects(
            tmp, "a renamed stop",
            lambda s: s.replace('case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CORROBORATED";',
                                'case HET_CAMPAIGN_STOP_CORROBORATED: return '
                                '"CONFIRMED";', 1),
            "stop names", quiet)
        # ... and the policy a name cannot carry: a header measuring the window
        # from run 0 ends rows this scheduler would still be running.
        bad += _mirror_rejects(
            tmp, "a window measured from run 0",
            lambda s: s.replace("if (n - st.n_at_first_sight >= confirm_runs)",
                                "if (n >= confirm_runs)", 1),
            "n_at_first_sight", quiet)
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
        r = _run_campaign(stub, corpus, state, [])
        out = r.stdout

        # A crash exits 1 too, and this fixture set is expected to exit 1 (one row
        # ends UNCONFIRMED-SIGHTING), so the rc check alone would pass for free.
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
            # invocation, so the budget lands in the tenth.
            "NULL-pooled": ("BUDGET", 10),
            # clean sightings pool to k_runs >= HET_CORROB_RUNS at invocation 2.
            "SIGHT-corrob": ("CORROBORATED", 2),
            # one sighting in the first run, then nulls: held open by the window
            # (through run 31) and ended by it in the fourth invocation.
            "SIGHT-lone": ("UNCONFIRMED-SIGHTING", 4),
            # a rejected sighting stops nothing, so the row runs to its budget.
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

        # The CPU-only precondition is louder when it did not run than when it
        # failed: this corpus holds no CPU-only row, so the probe must say so.
        if "write-back probe (CPU-only positive control): *** NOT RUN" not in out:
            print("  *** the CPU-only write-back probe is silently absent -- a "
                  "precondition nobody sees is a precondition nobody checked")
            bad += 1

        # The pooled null banks every run its budget bought, read by column name
        # so it pins the columns; `usable' does not discriminate (usable == R).
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
            print("      NULL-pooled  banks 10 invocation(s) / %d run(s) at BUDGET"
                  % STUB_BUDGET)

        # Every invocation carries a fresh seed base and the run count the row is
        # ENTITLED to; the harness gets HET_RATE and HET_CONFIRM_RUNS with it.
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
                              "(budget %d minus the %d runs already spent)"
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

        # The lone-sighting row under a budget smaller than its window must NEITHER
        # stop at BUDGET nor be curtailed to it: the window outranks the budget.
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
                  "its window closes at 31)"
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
                      "is ENTITLED to" % maxes)
                bad += 1
            elif not quiet:
                print("      SIGHT-lone   budget 20 < window (fired at run 1, closes "
                      "at 31) -> runs 31 (HET_RUNS_MAX 20, 21, 11, 1)")

        # A late sighting gets a WHOLE window: it fires at run 41, so its window
        # closes at run 71 and the row ends in the eighth invocation.
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
                  "/ %s run(s), want %s: the window is measured from the SIGHTING, so "
                  "this row is owed %d runs after run 41"
                  % (g2b.get("stop"), g2b.get("inv"), g2b.get("runs"), want2b,
                     CONFIRM))
            bad += 1
        elif not quiet:
            print("      SIGHT-late   fires at run 41 -> window closes at 71 -> ends "
                  "UNCONFIRMED-SIGHTING at run 80 (invocation 8)")

        # --rate disables the sighting stop and NOTHING else: the row that
        # corroborated at invocation 2 now runs to budget, the null is unmoved.
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
        if r3.returncode != 0:
            print("  *** --rate campaign exited %d, want 0 (no row errored and none "
                  "was flagged)" % r3.returncode)
            bad += 1
        elif not quiet:
            print("      --rate       SIGHT-corrob runs to BUDGET, NULL-pooled ends "
                  "where it did")

        # Fail closed: a named test with no harness dir kills the campaign (rc=2).
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
          "scale, the confirmation window outranks the budget, --rate disables the "
          "sighting stop alone, and the mirror rejects a moved bar, a renamed stop or "
          "a moved window origin.")
    return 0


# The header-driven phases read ONE compiled run of the layer; phase 6 compiles
# nothing.
GATE_PHASES = ("1", "2", "5")


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
            rc |= phase6_campaign(quiet)
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="statscheck.")
    try:
        hdir = emit_harness(tmp)
        print("  header : %s" % os.path.join(hdir, "het_verdict.h"))
        rc = run(hdir, tmp, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= run(None, None, a.quiet, phases=("6",))

    print("\n" + "=" * 70)
    if rc:
        print("STATSCHECK: FAIL")
    else:
        print("STATSCHECK: PASS  (inputs + aggregate + stopping rule + scheduler)")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
