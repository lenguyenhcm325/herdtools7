#!/usr/bin/env python3
"""HetLitmus -- the statistics gate for het_stats_compute() (het_verdict.h).

Compiles the REAL emitted header and drives it with synthetic record streams:
  1  Inputs     the Python mirror of the header's knob is COMPARED to it.
  2  Aggregate  every statistic re-derived independently in Python; every class,
                tier and flag reachable; the fields campaign.py reads are fields
                the machine line prints.
  5  Stop rule  every reason reachable, each guard driven at its boundary.
  6  Scheduler  campaign.py end to end, against a stub harness.
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

# The Python mirror of the header's knob.  No fixture straddles its boundary, so
# a differential cannot notice drift: it is COMPARED in phase 1.
CORROB_RUNS = 2             # must match HET_CORROB_RUNS      (pinned via MIRROR|)


# ---------------------------------------------------------------------------
# Synthetic records, one per run.  BASE is a live, stressed, reportable run,
# and each case perturbs a few fields to isolate one reason.
# ---------------------------------------------------------------------------
BASE = dict(
    test_name='"synthetic"',
    target_count=0,
    outcomes_vary=1,
    stress_truncated=0,
    gpu_stress_rounds=64,
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    noise_inert=0,
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
RUNS = 10                         # the record stream most fixtures are R long


def rec(**kw):
    r = dict(BASE)
    r.update(kw)
    return r


def stream(nc, **kw):
    """One record per run, run ids 0, 1, 2, ..."""
    return [rec(run_id=i, **kw) for i in range(nc)]


def observed(recs, k, clean=True):
    """Make the first k runs see the target, optionally in a degenerate readout
    (every scored iteration read back one outcome vector), leaving the rest live."""
    for i in range(k):
        recs[i]["target_count"] = 7
        if not clean:
            recs[i]["outcomes_vary"] = 0
    return recs


def observed_at(recs, idx):
    """Make the run at idx -- and ONLY it -- see the target, cleanly.  The
    confirmation window is measured from where the sighting lands."""
    observed(recs[idx:idx + 1], 1)
    return recs


CASES = []


def case(name, recs, **want):
    CASES.append(dict(name=name, recs=recs, want=want))


# ============================== The case set ===============================
case("never-over-ten-live-runs", stream(RUNS), obs="Never", R=RUNS,
     R_usable=RUNS, k=0)

# Observed per run, never per frame.
case("sometimes-3-of-10-runs-not-frames", observed(stream(RUNS), 3),
     obs="Sometimes", k=3, k_eff=3)

case("always", observed(stream(RUNS), RUNS), obs="Always", k=RUNS)

# Every run COLD-INVALID: R_usable is 0 and there is no reading at all, which is
# NOT the same answer as "Never".
case("void-when-every-run-is-cold",
     stream(RUNS, stress_truncated=1),
     obs="VOID", R=RUNS, R_usable=0)

# The decode guard, on each of its three disjuncts.  A constant decode
# [Srivastava24 sec 4.1] is reported (k=3) and corroborates nothing (k_eff=0).
case("degenerate-sightings-rejected-but-reported",
     observed(stream(RUNS), 3, clean=False),
     obs="Sometimes", k=3, k_eff=0, n_degen=3,
     flags_any=["DEGEN_SIGHTING"], tier="UNCONFIRMED")

# ... and a sighting from a run whose readout NEVER ran: its counts are memset
# zeros, so it is reported and counts toward no corroboration.
_dead_rdv = observed(stream(RUNS), 1)
_dead_rdv[0]["rdv_valid"] = 0
case("sighting-from-a-readout-that-never-ran-is-degenerate", _dead_rdv,
     obs="Sometimes", k=1, k_eff=0, n_degen=1, tier="UNCONFIRMED",
     flags_any=["DEGEN_SIGHTING"])

# ... and one from a run that scored NOTHING: it read nothing back, so what the
# sighting was decoded from is not a measurement either.
_none_scored = observed(stream(RUNS), 1)
_none_scored[0]["iters_scored"] = 0
case("sighting-from-a-run-that-scored-nothing-is-degenerate", _none_scored,
     obs="Sometimes", k=1, k_eff=0, n_degen=1, tier="UNCONFIRMED",
     flags_any=["DEGEN_SIGHTING"])

# The corroboration bar is on RUNS and both sides of it are driven: one run short
# is UNCONFIRMED, at the bar it is CORROBORATED.
case("sighting-corroborated-at-the-bar",
     observed(stream(RUNS), CORROB_RUNS),
     obs="Sometimes", tier="CORROBORATED", k_eff=CORROB_RUNS)

case("sighting-unconfirmed-one-run-short",
     observed(stream(RUNS), CORROB_RUNS - 1),
     obs="Sometimes", tier="UNCONFIRMED", k_eff=CORROB_RUNS - 1)

# n_at_first_sight is a price in RUNS: the fifth run of ten fires, so the price
# is 5 -- one-based, NEITHER the four spent before it nor a run id.
case("first-sight-counts-the-runs-spent-through-the-sighting",
     observed_at(stream(RUNS), 4),
     obs="Sometimes", k=1, k_eff=1, tier="UNCONFIRMED",
     first_sight=5)

# The selection effect: the three that fired are usable BECAUSE they fired, so
# scoring over usable runs would report Always here.  The denominator is R.
case("fired-3-of-10-is-SOMETIMES-not-ALWAYS",
     observed(stream(RUNS, stress_truncated=1), 3),
     obs="Sometimes", k=3, k_eff=3, R=RUNS, R_usable=3, scored=RUNS * 100000)

# ... and the same effect on a NULL, where a null's two numbers are told apart: the
# scoring statement is over the three usable runs, the effort over the ten runs.
NEVER_COLD_CASE = "never-over-three-live-runs-of-ten"
_never_cold = stream(RUNS)
for _c in _never_cold[3:]:
    _c["stress_truncated"] = 1
case(NEVER_COLD_CASE, _never_cold,
     obs="Never", k=0, R=RUNS, R_usable=3, scored=RUNS * 100000)

# The other half of that disclosure: every other fixture discards nothing, so
# without this one the discarded total is a constant zero over the whole input space.
DISCARD_CASE = "never-with-part-of-every-run-discarded"
case(DISCARD_CASE,
     stream(RUNS, iters_scored=60000, iters_discarded=40000),
     obs="Never", k=0, R=RUNS, R_usable=RUNS,
     scored=RUNS * 60000, discarded=RUNS * 40000)

# PHASE 5 -- every reason het_campaign_should_stop() gives is reachable, each
# guard driven at its boundary on synthetic records.
CONFIRM_RUNS = 30           # must match the driver's HET_CONFIRM_RUNS default
STOPS = []


def stop(name, recs, budget, want, rate=0, confirm=CONFIRM_RUNS):
    STOPS.append(dict(name=name, recs=recs, budget=budget,
                      want=want, rate=rate, confirm=confirm))


# A lone clean sighting does NOT stop: one run cannot rule out a per-run artefact.
stop("one-clean-sighting-does-not-stop",
     observed(stream(RUNS), 1),
     20, "CONTINUE")
# ... and neither does a degenerate one, at any count: the branch is on k_eff, not
# on the tier, and an artefact must never de-schedule a test.
stop("degenerate-sightings-never-stop",
     observed(stream(RUNS), 3, clean=False),
     20, "CONTINUE")
# The bar is HET_CORROB_RUNS clean runs, and it is reached exactly there.
stop("sighting-corroborated-stops",
     observed(stream(RUNS), CORROB_RUNS),
     20, "CORROBORATED")
# The confirmation window at its boundary: the same lone sighting in the first of
# ten runs continues one run short of the window and stops at it.
stop("lone-sighting-below-the-confirm-window-continues",
     observed(stream(RUNS), 1),
     20, "CONTINUE", confirm=10)
stop("lone-sighting-at-the-confirm-window-stops-unconfirmed",
     observed(stream(RUNS), 1),
     20, "UNCONFIRMED-SIGHTING", confirm=9)
# The precedence, both ways: the budget is spent in both and NEITHER answers BUDGET,
# because a row ended there would bank "seen once, stopped looking".
stop("lone-sighting-outranks-the-budget-stop",
     observed(stream(RUNS), 1),
     5, "CONTINUE")
stop("the-window-not-the-budget-ends-a-lone-sighting",
     observed(stream(RUNS), 1),
     5, "UNCONFIRMED-SIGHTING", confirm=9)
# The window is measured from the sighting: a row that fired in its LAST run has
# spent none of it, and a sighting at run 5 of ten drives the boundary both ways.
stop("a-sighting-in-the-last-run-gets-its-window",
     observed_at(stream(RUNS), 9),
     20, "CONTINUE", confirm=5)
stop("late-sighting-inside-its-window-continues",
     observed_at(stream(RUNS), 4),
     20, "CONTINUE", confirm=6)
stop("late-sighting-past-its-window-stops-unconfirmed",
     observed_at(stream(RUNS), 4),
     20, "UNCONFIRMED-SIGHTING", confirm=5)
# Rate mode disables the sighting stop and NOTHING else: the row runs on to measure
# a rate, and its budget still stops it.
stop("rate-mode-does-not-stop-on-a-corroborated-sighting",
     observed(stream(RUNS), CORROB_RUNS),
     20, "CONTINUE", rate=1)
stop("rate-mode-still-stops-at-budget",
     observed(stream(RUNS), CORROB_RUNS),
     10, "BUDGET", rate=1)
# ... and rate mode is the operator's answer to an UNCONFIRMED row, so it must not
# be able to produce one: a lone sighting reaches its budget and is never banked.
stop("rate-mode-runs-a-lone-sighting-to-budget",
     observed(stream(RUNS), 1),
     10, "BUDGET", rate=1)
stop("cold-row-runs-to-budget",
     stream(RUNS),
     10, "BUDGET")


# ---------------------------------------------------------------------------
# The Python reference for a whole case (mirrors het_stats_compute's structure).
# ---------------------------------------------------------------------------
def py_reference(recs):
    R = len(recs)

    def degenerate(c):
        # Mirrors het_run_degenerate: a readout that never ran, a run that
        # scored nothing, and one whose every iteration read one vector.
        return (not c.get("rdv_valid", 0) or c["iters_scored"] == 0
                or not c["outcomes_vary"])

    def usable(c):
        # Mirrors het_verdict()'s COLD-INVALID.  Only stress_truncated is
        # perturbed here; the other disqualifiers are verdictcheck.py's subject.
        if c["target_count"] > 0:
            return True
        return c["stress_truncated"] == 0

    k = k_eff = n_degen = R_usable = first_sight = 0
    for i, c in enumerate(recs):
        if usable(c):
            R_usable += 1
        y = c["target_count"] > 0
        if y:
            k += 1
            if degenerate(c):
                n_degen += 1
            else:
                k_eff += 1
                # first_sight is a price in runs: every run spent through this one.
                if first_sight == 0:
                    first_sight = i + 1

    # Nothing co-runs, so "usable" is defined partly by firing: the denominator is
    # R, the records SUPPLIED, as in the C.
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
        tier = ("CORROBORATED" if k_eff >= CORROB_RUNS else "UNCONFIRMED")

    return dict(obs=obs, k=k, k_eff=k_eff, n_degen=n_degen,
                first_sight=first_sight,
                scored=sum(c["iters_scored"] for c in recs),
                discarded=sum(c["iters_discarded"] for c in recs),
                R=R, R_usable=R_usable, tier=tier)


# ---------------------------------------------------------------------------
# The C driver.
# ---------------------------------------------------------------------------
C_MAIN = r"""
/* GENERATED by hetlitmus/verify/statscheck.py -- do not edit. */
#include "het_verdict.h"

static void run_case(const char *name, const het_obs_record *recs, int n) {
  het_stats_t st;
  het_stats_compute(recs, n, &st);
  printf("CASE|%s|%s|%d|%d|%d|%d|%s|0x%x|%d|%d|%llu|%llu\n",
         name, het_obs_class_name(st.obs), st.k, st.k_eff, st.n_degen,
         st.R_usable, het_sighting_name(st.tier), st.flags,
         /* st.R is the record count: R > R_usable means cold runs. */
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

/* PHASE 1 -- the constant the Python reference is derived from, emitted so it
   can be COMPARED: every fixture sits far from its boundary. */
static void anchors(void) {
  printf("MIRROR|%d\n", (int)HET_CORROB_RUNS);
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


def c_recs(name, recs):
    out = ["  static const het_obs_record %s[%d] = {" % (name, len(recs))]
    for c in recs:
        fields = ", ".join(".%s=%s" % (k, c_val(v)) for k, v in sorted(c.items()))
        out.append("    { %s }," % fields)
    out.append("  };")
    return "\n".join(out)


def build_c():
    body = []
    for i, c in enumerate(CASES):
        body.append("  {")
        body.append(c_recs("recs%d" % i, c["recs"]))
        body.append('    run_case("%s", recs%d, %d);'
                    % (c["name"], i, len(c["recs"])))
        body.append("  }")
    for i, s in enumerate(STOPS):
        body.append("  {")
        body.append(c_recs("stopr%d" % i, s["recs"]))
        body.append('    stop_case("%s", stopr%d, %d, %d, %d, %d);'
                    % (s["name"], i, len(s["recs"]), s["budget"],
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
}
FLAGS = sorted(FLAG_BIT, key=FLAG_BIT.get)


def _parse_case_fields(l):
    """Parse one CASE| line into (name, stats-dict).  The tuple width is the
    assertion: a column added in the C without a change here unpacks short."""
    f = l.split("|")
    (_, name, obs, k, k_eff, n_degen, R_usable, tier,
     flags, R, first_sight, scored, discarded) = f
    return name, dict(
        obs=obs, k=int(k), k_eff=int(k_eff),
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
    print("===== PHASE 1: does the mirrored constant hold? =====")
    bad = 0
    # A differential CANNOT notice this drift: move HET_CORROB_RUNS by one and
    # every fixture keeps its tier on both sides while the mirror goes stale.
    seen_mirror = False
    for l in lines:
        if not l.startswith("MIRROR|"):
            continue
        seen_mirror = True
        _, cr = l.split("|")
        if int(cr) != CORROB_RUNS:
            print("  *** MIRROR DRIFT: HET_CORROB_RUNS is %d in the header, %d here "
                  "-- the tier fixtures are sized from the mirror, so both sides "
                  "of the bar would move with it" % (int(cr), CORROB_RUNS))
            bad += 1
        elif not quiet:
            print("      the Python mirror matches the header: CORROB_RUNS=%d"
                  % int(cr))
    if not seen_mirror:
        print("  *** no MIRROR| line: the header's knob is compared to nothing")
        bad += 1

    if bad:
        print("\nINPUTS FAILED: %d problem(s).  A stale mirror derives the Python "
              "reference from a different header than the C." % bad)
        return 1
    print("\nINPUTS OK (the mirrored knob is COMPARED to the header)")
    return 0


# The HetStats line is the whole interface between a harness and its readers, and
# campaign.py reads it by key: fnum() and fhex() both read a missing one as 0.
CONSUMER_KEY_RE = re.compile(r'\bf(?:num|hex)\(\s*kv\s*,\s*"(\w+)"')
LINE_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
# The machine line, told from the human block that shares its prefix by the first
# key following the test name.
STATS_LINE = re.compile(r"HetStats \S+ obs=\S+ ")
# A reformat that hid call sites from the pattern would narrow this check instead
# of reddening it, so the count is pinned as well as the keys.
EXPECT_CONSUMER_KEYS = 8


def _consumer_keys():
    """The HetStats fields hetlitmus/campaign.py reads, off its source."""
    with open(CAMPAIGN) as fh:
        return sorted(set(CONSUMER_KEY_RE.findall(fh.read())))


def _stats_key_list(seg):
    """The ordered field names of one HetStats line -- printed, or a producer's
    format string unquoted -- or None: a real line runs obs .. flags."""
    keys = []
    for k in LINE_KEY_RE.findall(seg):
        keys.append(k)
        if k == "flags":
            return keys if keys[0] == "obs" else None
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
        ref = refs[name] = py_reference(c["recs"])
        errs = []

        # (a) The differential: every statistic, independently re-derived.
        for fld in ("obs", "k", "k_eff", "n_degen", "R", "R_usable",
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

    need_flags = {"DEGEN_SIGHTING"}
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

    # The fields campaign.py reads, against the line the header just
    # printed: a key the printer never prints reads back 0 and schedules on it.
    real = next((l for b in sorted(blocks) for l in blocks[b].splitlines()
                 if STATS_LINE.match(l)), None)
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
# PHASE 6 -- the scheduler, end to end, against a stub harness: the HetStats line
# is campaign.py's whole interface, and the stub emits deterministic lines.
# ---------------------------------------------------------------------------
# The stand-in campaign.py runs as ./<test> from <corpus>/<test>, so it locates
# its own dir from its path and takes no argument.
STUB_HARNESS = r'''#!/usr/bin/env python3
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
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


def line(obs, k, k_eff, degen, first_sight, sighting, usable=None, flags=0):
    """One HetStats machine line, in het_stats_line's field ORDER and field SET."""
    print("HetStats %s obs=%s R=%d usable=%d k=%d k_eff=%d "
          "degen=%d first_sight=%d sighting=%s N=100000 scored=100000 discarded=250 "
          "flags=0x%x"
          % (test, obs, R, R if usable is None else usable, k, k_eff,
             degen, first_sight, sighting, flags))


NULL = ("Never", 0, 0, 0, 0, "none")
DEAD = ("VOID", 0, 0, 0, 0, "none", 0)
FIRED = ("Sometimes", 1, 1, 0, 1, "UNCONFIRMED")
if test == "NULL-pooled":
    line(*NULL)
elif test == "SIGHT-corrob":
    # One clean sighting EVERY invocation: the pooled k_eff reaches
    # HET_CORROB_RUNS at invocation 2.
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
    line("Sometimes", 1, 0, 1, 0, "UNCONFIRMED")
elif test == "VOID-dead":
    # Every run COLD in every invocation: the pool measured nothing at all.
    line(*DEAD)
elif test == "VOID-late":
    # Measures in its first invocation and goes dead after.
    if inv == 1:
        line(*NULL)
    else:
        line(*DEAD)
else:
    sys.exit(3)
'''

# A stand-in that outlives its timeout, having flushed a line first: the row
# must end ERROR and the partial transcript must still be logged.
STUB_SLEEPER = ("#!/usr/bin/env python3\n"
                "import sys, time\n"
                "sys.stdout.write('HetLitmus: shared-mem mode=stub\\n')\n"
                "sys.stdout.flush()\n"
                "time.sleep(30)\n")

SEED_STRIDE = 100003     # must match campaign.py
# The budget phase 6 drives the campaign with, the confirmation window it passes,
# and the R every stub line reports: the HET_RUNS_MAX assertion is derived from them.
STUB_BUDGET, CONFIRM, STUB_R = 100, 30, 10
STUB_SCORED = 100000     # the iterations one stub line reports scored
# ... and the iterations it reports discarded: NOT zero, or the pooled total
# is zero however the driver pools it.
STUB_DISCARDED = 250
STUB_TESTS = ["NULL-pooled", "SIGHT-corrob", "SIGHT-degen", "SIGHT-lone",
              "VOID-dead", "VOID-late"]


def _mk_corpus(tmp, name, tests, body=STUB_HARNESS):
    """One harness dir per test, each holding the stand-in at <t>/<t>: that path
    is what campaign.py runs.  `body=None' leaves the dir with no binary at all."""
    corpus = os.path.join(tmp, name)
    for t in tests:
        d = os.path.join(corpus, t)
        os.makedirs(d)
        if body is not None:
            with open(os.path.join(d, t), "w") as fh:
                fh.write(body)
            os.chmod(os.path.join(d, t), 0o755)
    return corpus


def _run_campaign(corpus, state, extra):
    return subprocess.run(
        [sys.executable, CAMPAIGN, "--corpus", corpus,
         "--budget-runs", str(STUB_BUDGET), "--confirm-runs", str(CONFIRM),
         "--seed0", "777", "--state", state] + extra,
        capture_output=True, text=True)


def _state_notes(path):
    """test -> the note column, which is where an errored row's reason lands."""
    with open(path) as fh:
        return {r["test"]: (r.get("note") or "") for r in csv.DictReader(fh)}


def _done_rows(out):
    done, order = {}, []
    for l in out.splitlines():
        if l.startswith("done  "):
            f = l.split()
            done[f[1]] = dict(stop=f[2], inv=int(f[3].split("=")[1]),
                              runs=int(f[4].split("=")[1]),
                              usable=int(f[5].split("=")[1]))
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
        # A define that is gone is its own arm: the regex finds nothing to compare.
        bad += _mirror_rejects(
            tmp, "a dropped corroboration bar",
            lambda s: re.sub(r"^#define[ \t]+HET_CORROB_RUNS[ \t].*\n", "", s,
                             count=1, flags=re.M),
            "no longer defines HET_CORROB_RUNS", quiet)
        # ... and the policy a name cannot carry: a header measuring the window
        # from run 0 ends rows this scheduler would still be running.
        bad += _mirror_rejects(
            tmp, "a window measured from run 0",
            lambda s: s.replace("if (n - st.n_at_first_sight >= confirm_runs)",
                                "if (n >= confirm_runs)", 1),
            "n_at_first_sight", quiet)
        # A header out of reach is FATAL: the mirror is the only thing holding
        # this driver's copy of the stopping rule to the one the harness compiled.
        r1 = subprocess.run(
            [sys.executable, "-c", loader +
             "campaign.check_flag_mirror(path='/nonexistent/het_verdict.h')"],
            capture_output=True, text=True)
        if r1.returncode != 2 or "cannot be read" not in r1.stderr:
            print("  *** an unreadable header did not FATAL (rc=%d err=%r) -- a "
                  "scheduler applying an unverifiable copy of the harness's policy "
                  "is the drift the mirror exists to stop"
                  % (r1.returncode, r1.stderr.strip()[-300:]))
            bad += 1
        elif not quiet:
            print("      mirror rejects %-26s naming %s"
                  % ("an unreadable header", "cannot be read"))

        # --- 6.1: the policy, end to end.
        corpus = _mk_corpus(tmp, "corpus", STUB_TESTS)
        state = os.path.join(tmp, "state.csv")
        r = _run_campaign(corpus, state, [])
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
            # clean sightings pool to k_eff >= HET_CORROB_RUNS at invocation 2.
            "SIGHT-corrob": ("CORROBORATED", 2),
            # one sighting in the first run, then nulls: held open by the window
            # (through run 31) and ended by it in the fourth invocation.
            "SIGHT-lone": ("UNCONFIRMED-SIGHTING", 4),
            # a rejected sighting stops nothing, so the row runs to its budget.
            "SIGHT-degen": ("BUDGET", 10),
            # no usable run in any invocation: the row ends after the first.
            "VOID-dead": ("ERROR", 1),
            # usable in invocation 1 and dead after: pooled, the row keeps what it
            # measured and runs on to its own stop.
            "VOID-late": ("BUDGET", 10),
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

        # An ERROR row says what it failed to measure, not only that it did.
        notes61 = _state_notes(state) if os.path.exists(state) else {}
        for t, frag in (("VOID-dead", "usable=0 of R=%d: nothing was measured"
                         % STUB_R),):
            if frag not in notes61.get(t, ""):
                print("  *** %s banked the note %r, want one carrying %r"
                      % (t, notes61.get(t, ""), frag))
                bad += 1

        # usable is pooled and independent of the stop: 0 is "nothing was
        # measured", and a row that went dead late keeps the runs it did measure.
        for t, want_u in (("VOID-dead", 0), ("VOID-late", STUB_R),
                          ("NULL-pooled", STUB_BUDGET)):
            g = done.get(t) or {}
            if g.get("usable") != want_u:
                print("  *** %-12s done line says usable=%s, want %d -- the runs a "
                      "row measured on are what its stop is read against"
                      % (t, g.get("usable"), want_u))
                bad += 1

        # The corroboration headline is a fact at zero: exactly one row here
        # reproduced its outcome.
        if "1 row(s) ended CORROBORATED" not in out:
            print("  *** the campaign report does not say 1 row(s) ended "
                  "CORROBORATED:\n%s" % out[-800:])
            bad += 1

        # The pooled null banks every run its budget bought, read by column name
        # so it pins the columns; `usable' does not discriminate (usable == R).
        want_bank = {"stop": "BUDGET", "invocations": "10",
                     "runs": str(STUB_BUDGET), "usable": str(STUB_BUDGET), "k": "0",
                     "scored": str(STUB_BUDGET // STUB_R * STUB_SCORED),
                     "discarded": str(STUB_BUDGET // STUB_R * STUB_DISCARDED),
                     "flags": "0x0"}
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

        # The pooled semantics, banked: usable counts the runs that measured, runs
        # counts every run the budget bought, and they part company on this row.
        want_late = {"stop": "BUDGET", "runs": str(STUB_BUDGET),
                     "usable": str(STUB_R)}
        late_bank = banked.get("VOID-late")
        if late_bank is None:
            print("  *** VOID-late has no row in the campaign state at all")
            bad += 1
        elif {c: late_bank.get(c) for c in want_late} != want_late:
            print("  *** the row that went dead after its first invocation banked "
                  "%s, want %s: a row that measured something is not turned into "
                  "an ERROR row by losing its harness later"
                  % ({c: late_bank.get(c) for c in want_late}, want_late))
            bad += 1
        elif not quiet:
            print("      VOID-late    measures %d run(s), then goes dead: still "
                  "BUDGET at %d run(s)" % (STUB_R, STUB_BUDGET))

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

        # The transcripts are kept without being asked for, under a dir derived
        # from --state: nothing else holds what an invocation printed.
        deflog = os.path.join(tmp, "state-logs", "NULL-pooled.log")
        got_log = open(deflog).read() if os.path.exists(deflog) else ""
        if got_log.count("### NULL-pooled") != 10:
            print("  *** %s holds %d transcript header(s), want 10 -- a campaign "
                  "given no --log-dir still keeps one per invocation"
                  % (deflog, got_log.count("### NULL-pooled")))
            bad += 1
        elif not quiet:
            print("      the transcripts land in %s with no --log-dir asked for"
                  % os.path.basename(os.path.dirname(deflog)))
        r7 = _run_campaign(corpus, os.path.join(tmp, "state2.csv"),
                           ["--log-dir", os.path.join(tmp, "state-logs")])
        if r7.returncode != 2:
            print("  *** a campaign pointed at a log dir that already holds "
                  "transcripts exited %d, want 2: every transcript is appended, so "
                  "it would mix two campaigns under one name" % r7.returncode)
            bad += 1

        # The lone-sighting row under a budget smaller than its window must NEITHER
        # stop at BUDGET nor be curtailed to it: the window outranks the budget.
        lone = _mk_corpus(tmp, "lone", ["SIGHT-lone"])
        r2 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", lone,
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
        r3 = _run_campaign(rate, os.path.join(tmp, "rate.csv"), ["--rate"])
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
        # --rate never reaches the CORROBORATED stop, so the headline must be a
        # stop-name fact rather than a count of what reproduced.
        if ("no row ended CORROBORATED." not in r3.stdout
                or "0 row(s) ended CORROBORATED" in r3.stdout):
            print("  *** the --rate report says %r -- the row DID reproduce its "
                  "outcome there, and only the stop is absent"
                  % [l for l in r3.stdout.splitlines() if "CORROBORATED" in l])
            bad += 1

        # The seed base: fresh per campaign, printed and banked, so the seeds
        # every invocation ran under are derivable.
        seedc = _mk_corpus(tmp, "seedbase", ["NULL-pooled"])
        st8 = os.path.join(tmp, "seedbase.csv")
        r8 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", seedc, "--budget-runs",
             str(STUB_BUDGET), "--confirm-runs", str(CONFIRM), "--state", st8],
            capture_output=True, text=True)
        m8 = re.search(r"^campaign: seed0=(\d+) ", r8.stdout, re.M)
        slog = os.path.join(seedc, "NULL-pooled", "seeds.log")
        seeds8 = ([int(l.split()[1]) for l in open(slog)]
                  if os.path.exists(slog) else [])
        banked8 = {}
        if os.path.exists(st8):
            with open(st8) as fh:
                banked8 = {row["test"]: row for row in csv.DictReader(fh)}
        if m8 is None:
            print("  *** a campaign given no --seed0 printed no seed base:\n%s"
                  % r8.stdout[:600])
            bad += 1
        elif not 0 <= int(m8.group(1)) < 2 ** 31:
            print("  *** the drawn seed base is %s, outside [0, 2^31)"
                  % m8.group(1))
            bad += 1
        elif (banked8.get("NULL-pooled", {}).get("seed0") != m8.group(1)
              or seeds8[:2] != [int(m8.group(1)),
                                int(m8.group(1)) + SEED_STRIDE]):
            print("  *** the base printed (%s), the base banked (%s) and the first "
                  "two bases run (%s) disagree -- a base nothing records is a "
                  "campaign nobody can replay"
                  % (m8.group(1), banked8.get("NULL-pooled", {}).get("seed0"),
                     seeds8[:2]))
            bad += 1
        elif not quiet:
            print("      the seed base is drawn, printed, banked and stridden by "
                  "%d per invocation" % SEED_STRIDE)
        # The base is drawn per campaign: a second campaign must not replay the
        # first's seeds (an equal pair is 2^-31 of the space).
        seedc2 = _mk_corpus(tmp, "seedbase2", ["NULL-pooled"])
        r8b = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", seedc2, "--budget-runs",
             str(STUB_R), "--confirm-runs", str(CONFIRM),
             "--state", os.path.join(tmp, "seedbase2.csv")],
            capture_output=True, text=True)
        m8b = re.search(r"^campaign: seed0=(\d+) ", r8b.stdout, re.M)
        if m8 is None or m8b is None or m8.group(1) == m8b.group(1):
            print("  *** two campaigns given no --seed0 ran under the bases %s and "
                  "%s -- a base that does not move makes the second campaign a "
                  "replay of the first, not a second sample"
                  % (m8 and m8.group(1), m8b and m8b.group(1)))
            bad += 1
        elif not quiet:
            print("      a second campaign given no --seed0 draws a different base")
        # A base the harness cannot read at its own width is refused, not truncated.
        r9 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", seedc, "--budget-runs",
             str(STUB_BUDGET), "--seed0", str(2 ** 32 - 1),
             "--state", os.path.join(tmp, "wide.csv")],
            capture_output=True, text=True)
        if r9.returncode != 2 or "2^32-1" not in r9.stderr:
            print("  *** --seed0 %d exited %d (%r), want 2: the seeds it would hand "
                  "the harness do not fit the width one is read at"
                  % (2 ** 32 - 1, r9.returncode, r9.stderr.strip()[-200:]))
            bad += 1
        elif not quiet:
            print("      a seed base whose strides overflow a uint32 is refused")

        # A test named twice is one row, and a --dry-run runs nothing: it draws
        # and prints no base.
        r10 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--tests",
             "NULL-pooled,NULL-pooled", "--dry-run",
             "--state", os.path.join(tmp, "dry.csv")],
            capture_output=True, text=True)
        plans = [l for l in r10.stdout.splitlines() if l == "  plan NULL-pooled"]
        if len(plans) != 1 or "more than once; one row each." not in r10.stdout:
            print("  *** --tests NULL-pooled,NULL-pooled planned %d row(s) and said "
                  "%r -- one name is one row, and the collapse is announced"
                  % (len(plans), r10.stdout.strip()[-300:]))
            bad += 1
        elif "seed0=" in r10.stdout:
            print("  *** a --dry-run printed a seed base: it runs nothing, so the "
                  "base it printed was never used")
            bad += 1
        elif not quiet:
            print("      a test named twice is scheduled once; a --dry-run draws "
                  "no base")
        r11 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--tests", "GHOST,GHOST",
             "--state", os.path.join(tmp, "ghost2.csv")],
            capture_output=True, text=True)
        if r11.returncode != 2 or r11.stderr.count("GHOST") != 1:
            print("  *** --tests GHOST,GHOST exited %d naming GHOST %d time(s), want "
                  "2 and once: the duplicate is collapsed before the corpus is "
                  "checked" % (r11.returncode, r11.stderr.count("GHOST")))
            bad += 1

        # Fail closed: a named test with no harness dir kills the campaign (rc=2).
        r4 = subprocess.run(
            [sys.executable, CAMPAIGN, "--corpus", corpus, "--tests", "GHOST",
             "--state", os.path.join(tmp, "ghost.csv")],
            capture_output=True, text=True)
        if r4.returncode != 2:
            print("  *** a test with no harness dir exited %d, want 2 (fail closed: "
                  "there is nothing to run)" % r4.returncode)
            bad += 1
        elif not quiet:
            print("      a test with no harness dir fails the campaign closed (rc=2)")

        # A harness dir the build never reached: the row ends ERROR naming the
        # path it looked for, and the driver does NOT raise.
        noexe = _mk_corpus(tmp, "noexe", ["UNBUILT"], body=None)
        st5 = os.path.join(tmp, "noexe.csv")
        r5 = _run_campaign(noexe, st5, [])
        want_path = os.path.join(noexe, "UNBUILT", "UNBUILT")
        note5 = _state_notes(st5).get("UNBUILT", "") if os.path.exists(st5) else ""
        if "Traceback" in r5.stderr:
            print("  *** a dir with no harness binary CRASHED the campaign:\n%s"
                  % r5.stderr[-800:])
            bad += 1
        elif r5.returncode != 1 or want_path not in note5:
            print("  *** a dir with no harness binary exited %d with note %r, want "
                  "1 and a note naming %s -- a row nothing ran is an ERROR row, not "
                  "a reading" % (r5.returncode, note5, want_path))
            bad += 1
        elif not quiet:
            print("      a dir with no harness binary ends ERROR naming the path")

        # A harness that outlives --timeout: the row ends ERROR saying so, and the
        # partial transcript is still in the log dir.
        slow = _mk_corpus(tmp, "slow", ["SLOW"], body=STUB_SLEEPER)
        st6 = os.path.join(tmp, "slow.csv")
        logs = os.path.join(tmp, "slow-logs")
        r6 = _run_campaign(slow, st6, ["--timeout", "1", "--log-dir", logs])
        note6 = _state_notes(st6).get("SLOW", "") if os.path.exists(st6) else ""
        tr = os.path.join(logs, "SLOW.log")
        got_tr = open(tr).read() if os.path.exists(tr) else ""
        if r6.returncode != 1 or "timeout after 1 s" not in note6:
            print("  *** the harness that outlived --timeout 1 exited %d with note "
                  "%r, want 1 and 'timeout after 1 s'" % (r6.returncode, note6))
            bad += 1
        elif "mode=stub" not in got_tr:
            print("  *** the timed-out invocation left no partial transcript in %s: "
                  "%r -- what the harness DID print before the kill is the only "
                  "evidence of how far it got" % (tr, got_tr[-200:]))
            bad += 1
        elif not quiet:
            print("      a harness outliving --timeout ends ERROR, partial "
                  "transcript kept")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if bad:
        print("\nSCHEDULER FAILED: %d problem(s)." % bad)
        return 1
    print("\nSCHEDULER OK -- campaign.py applies het_verdict.h's rule at the pooled "
          "scale, the confirmation window outranks the budget, --rate disables the "
          "sighting stop alone, a row nothing ran and a row that measured nothing "
          "both end ERROR, a base drawn afresh per campaign and the transcripts "
          "are kept without being asked for, and the mirror rejects a moved bar, "
          "a renamed stop, a moved window origin, a "
          "dropped define or an unreadable header.")
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
