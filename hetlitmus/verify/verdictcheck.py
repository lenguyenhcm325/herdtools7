#!/usr/bin/env python3
"""HetLitmus -- the decision-rule gate for het_verdict() (het_verdict.h).

het_verdict() turns a raw target count into one of four outcomes, and every one
of them is a shape a constant can impersonate.  So this gate compiles the REAL
emitted header -- not a copy, which would be free to drift -- feeds it synthetic
het_obs_records, and proves:

  1 the rule      it decides.  Every outcome and every liveness disqualifier is
                  reachable; an unstamped record fails closed.
  2 the printout  each outcome's sentences are reachable from THAT outcome and
                  from no other, checked both ways.  The enum changing is not
                  the deliverable; the sentence is.
  3 the corpus    every emitted harness stamps rec_magic exactly once and carries
                  the mu(T) / canary population control-map.csv gives it.
  4 the machine   the printout names only the machine the pair's row in
                  litmus/hetMachine.ml entitles it to, and a harness stamped
                  with no row names none.

The rule and its reporting frames: hetlitmus/docs/positive-control.md S4/S11.

Usage:  verdictcheck.py [--header PATH] [-q]   run the gate
        verdictcheck.py --bite                 prove it FAILS on a broken rule
"""

import argparse
import contextlib
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
CONTROL_MAP = os.path.join(HET_DIR, "control-map.csv")

VERDICTS = ["OBSERVED", "NOT-OBSERVED-MU-HOT", "NOT-OBSERVED-CANARY-ONLY",
            "COLD-INVALID"]

# The co-run census the emitted corpus MUST reproduce, re-derived from
# control-map.csv rather than typed: a mu(T) instance is built for every row whose
# Mu column names a test, a canary instance for every row whose Canary column names
# one ("self" rows ARE the canary and cannot co-run themselves).
CENSUS = {"mu": 375, "canary": 469, "tests": 471}

# ---------------------------------------------------------------------------
# Frame exclusivity.  Each outcome's own sentences, checked BOTH ways: reachable
# from that outcome (a ban that passes because the text vanished is not a check),
# and printed by no other.  The strings are spliced back together across the C
# string concatenations they are written in.
FRAME_CLAIMS = {
    "OBSERVED": ["the weak outcome was OBSERVED",
                 "Report it as what "],
    "NOT-OBSERVED-MU-HOT": ["NOT OBSERVED, MU HOT"],
    "NOT-OBSERVED-CANARY-ONLY": ["NOT OBSERVED, CANARY ONLY"],
    "COLD-INVALID": ["DISCARD this null"],
}
# Printed by every NON-sighting outcome, the cold one included: a discarded null
# still says what was not seen.
NON_SIGHTING_CLAIMS = ["the weak outcome was NOT observed"]
# Printed by BOTH null tiers and by neither the sighting nor the cold one: a
# discarded run is not an observability result, and saying so on one would report
# a dead harness as reach.
NULL_TIER_CLAIMS = [
    "OBSERVABILITY result about this harness",
    "has precedent: Alglave et al., ASPLOS'15, fn.7, p.577",
]

# ---------------------------------------------------------------------------
# A "live, hot, credible" baseline: a record whose mu(T) fired.  Every case below
# is this record with a few fields perturbed, so each isolates ONE reason.
BASE = dict(
    # The stamp, written as the SYMBOL so a rename in the header is a compile
    # error here too.  A zeroed record is what an emitter that skipped a field
    # produces, and it must never read as a live one.
    rec_magic="HET_REC_MAGIC",
    exhaustive_valid=1,
    target_count_exhaustive=0,
    target_count_heuristic=0,
    interleavings_detected=1000,
    # The decode channel, stated once.  The verdict is channel-aware: the sync
    # channel's liveness evidence is interleavings_detected, the observer channel's
    # is observer_unique_count, and a record with NEITHER flag fails closed.  The
    # baseline is a reader; the store-only 2+2W rows have none and flip to
    # sync_valid=0, obs_valid=1 below.  (The reader / store-only split is pinned as
    # statscheck.py's CENSUS_SYNC and histcheck.py's N_STORE_ONLY.)
    sync_valid=1,
    control_compiled_in=1,
    canary_compiled_in=1,
    control_target_count=30,          # == HET_TAU_HOT
    canary_target_count=500,
    control_exhaustive_valid=1,
    canary_exhaustive_valid=1,
    stress_truncated=0,
    spin_rendezvous=900, spin_cap=100,
    gpu_stress_rounds=64,             # het_do_stress actually ran
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    cpu_aff_failures=0,
    place_failures=0,
    # every mechanism requested (GPU_STRESS|SPIN|CPU_ENEMY|CPU_PRELOAD|NOISE_CPU|NOISE_GPU)
    stress_requested=0x3F,
)


def case(name, verdict, dq=(), cv=(), **kw):
    r = dict(BASE)
    r.update(kw)
    return dict(name=name, verdict=verdict, dq=list(dq), cv=list(cv), rec=r)


CASES = [
    # =======================================================================
    # 1. The strong null: mu(T) -- a strictly weaker structural sibling -- fired
    #    on the same launch, and the ground-truth scan ran.
    # =======================================================================
    case("mu-hot-null", "NOT-OBSERVED-MU-HOT"),

    case("observed-exhaustive", "OBSERVED", target_count_exhaustive=1),

    # A sighting is believed even on a run we would otherwise DISCARD:
    # falsification is one-sided, so no control is needed to believe a positive.
    case("observed-beats-every-disqualifier", "OBSERVED",
         target_count_exhaustive=1, control_compiled_in=0, canary_compiled_in=0,
         interleavings_detected=0, stress_truncated=99,
         cpu_enemy_rounds=0, noise_cpu_rounds=0, noise_gpu_blocks=0),

    # A windowed hit is a strict subset of the exhaustive scan's under the same
    # predicate, so it is a genuine recovered cycle; at production N a T_L>=2 shape
    # never runs the exhaustive scan, so keying the sighting off that field alone
    # would drop real observations.  Counted, and flagged; the deviation from the
    # rule as written is in hetlitmus/docs/positive-control.md S4.
    case("observed-heuristic-only", "OBSERVED", cv=["HEURISTIC_SIGHT"],
         target_count_heuristic=1, target_count_exhaustive=0, exhaustive_valid=0),

    # =======================================================================
    # 2. The weaker null: the harness is alive, but not through THIS shape.
    # =======================================================================
    case("canary-only-when-mu-is-cold", "NOT-OBSERVED-CANARY-ONLY",
         cv=["CANARY_ONLY"], control_target_count=0, canary_target_count=500),

    # The rows that co-run no mu at all are the lattice floor (CENSUS: tests minus
    # mu), so no strictly weaker structural sibling of them exists.  Their null is
    # the weaker tier for a different reason, and CV_CANARY_ONLY -- "Layer B fired,
    # Layer A did not" -- must NOT be raised where no Layer A was compiled in, or a
    # real diagnostic becomes boilerplate on every floor row.
    case("canary-only-when-no-mu-is-compiled-in", "NOT-OBSERVED-CANARY-ONLY",
         control_compiled_in=0, control_target_count=0, canary_target_count=500),

    case("cold-no-control-built", "COLD-INVALID", dq=["NO_CONTROL_BUILT"],
         control_compiled_in=0, canary_compiled_in=0,
         control_target_count=0, canary_target_count=0),

    # ---- exhaustive_valid == 0  =>  NEVER the strong null --------------------
    # Hot harness, everything live -- but the ground-truth scan did not run, so the
    # zero is not a measured zero and may never be read as one.
    case("no-exhaustive-is-never-mu-hot", "NOT-OBSERVED-CANARY-ONLY",
         cv=["NO_EXHAUSTIVE"], exhaustive_valid=0, control_target_count=500),

    # =======================================================================
    # 3. The sharpest instance: MP-cg-sys-relaxed is the Layer-B canary for most of
    #    the corpus, so it co-runs nothing (control-map.csv says `self') and BOTH
    #    compiled-in flags are 0.  The one test whose whole job is to fire must
    #    still be readable when it does.
    # =======================================================================
    case("the-canary-itself-firing-is-a-plain-sighting", "OBSERVED",
         control_compiled_in=0, canary_compiled_in=0,
         control_target_count=0, canary_target_count=0,
         target_count_exhaustive=412, target_count_heuristic=412),

    # The store-only (2+2W) arm: no reader, so interleavings_detected is
    # structurally 0 and the observer is their ONLY liveness channel.  All three
    # outcomes stay reachable, or the channel goes constant on those rows.
    # (a) live observer (>= HET_THETA_DISTINCT distinct GPU store-values) + hot
    #     canary, nothing seen -> the reportable-null path.
    case("store-only-observer-live-is-a-null", "NOT-OBSERVED-CANARY-ONLY",
         control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=500,
         interleavings_detected=0),

    # (b) cold observer (< HET_THETA_DISTINCT) -> COLD-INVALID, and the printout must
    #     name the OBSERVER channel: "interleavings_detected==0" is meaningless here.
    case("store-only-observer-cold-is-COLD", "COLD-INVALID", dq=["OBSERVER_COLD"],
         control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=1,
         interleavings_detected=0),

    # (c) a store-only SIGHTING is still a sighting: the observer channel must never
    #     block a recovered outcome.
    case("store-only-observer-sighting-is-OBSERVED", "OBSERVED",
         control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=500,
         interleavings_detected=0,
         target_count_exhaustive=7, target_count_heuristic=7),

    # ... and with a COLD canary it falls back to COLD-INVALID: "we did not see it"
    # from a dead harness is not a result.
    case("cold-canary-with-no-mu-is-COLD", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_compiled_in=0, control_target_count=0, canary_target_count=0),

    # =======================================================================
    # 4. An unstamped record fails closed.  het_obs_record is memset(0), so a
    #    zeroed rec_magic is what an emitter that skipped the stamp produces; the
    #    rule must claim NOTHING then, not even on a sighting, because every field
    #    it would read is a memset zero.
    # =======================================================================
    case("unstamped-record-fails-closed", "COLD-INVALID", dq=["REC_UNSTAMPED"],
         rec_magic=0),
    case("unstamped-record-fails-closed-even-on-a-sighting", "COLD-INVALID",
         dq=["REC_UNSTAMPED"], rec_magic=0, target_count_exhaustive=99),
    # ... and the test is EQUALITY, not "nonzero": a record carrying some other
    # stamp is a record written by something that is not this header.
    case("wrong-stamp-fails-closed", "COLD-INVALID", dq=["REC_UNSTAMPED"],
         rec_magic=0x48455432),

    # =======================================================================
    # 5. Every liveness disqualifier drives the outcome to COLD: a null from a run
    #    whose stress was inert is not the same datum as one from a stressed run
    #    (positive-control.md S4).
    # =======================================================================
    case("cold-no-interleaving", "COLD-INVALID", dq=["NO_INTERLEAVING"],
         interleavings_detected=0),
    case("cold-controls-below-tau", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_target_count=0, canary_target_count=0),
    case("cold-stress-truncated", "COLD-INVALID", dq=["STRESS_TRUNCATED"],
         stress_truncated=1),
    case("cold-window-opener-never-spun", "COLD-INVALID", dq=["SPIN_DEAD"],
         spin_rendezvous=0, spin_cap=0),
    case("cold-cpu-enemy-dead", "COLD-INVALID", dq=["CPU_ENEMY_DEAD"],
         cpu_enemy_rounds=0),
    case("cold-cpu-preload-dead", "COLD-INVALID", dq=["CPU_PRELOAD_DEAD"],
         cpu_preload_ops=0),
    case("cold-noise-cpu-dead", "COLD-INVALID", dq=["NOISE_CPU_DEAD"],
         noise_cpu_rounds=0),
    case("cold-noise-gpu-dead", "COLD-INVALID", dq=["NOISE_GPU_DEAD"],
         noise_gpu_blocks=0),

    # het_do_stress carries a runtime tally, so "requested and completed zero rounds"
    # is a check that can fail -- and must be: HET_TEST_BLOCKS is a sum over the
    # co-run instances, and stressing blocks fill only what the co-residency cap
    # leaves over (hetlitmus/docs/positive-control.md S9).
    case("cold-gpu-stress-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         gpu_stress_rounds=0),

    # The liveness disqualifiers do not care which tier the null would have been:
    # a canary-only harness whose stress was inert is not a usable datum either.
    case("canary-only-goes-cold-when-stress-is-dead", "COLD-INVALID",
         dq=["GPU_STRESS_DEAD"], control_compiled_in=0, control_target_count=0,
         gpu_stress_rounds=0),

    # =======================================================================
    # 6. A mechanism that was not requested must NOT disqualify.  A deliberately
    #    unstressed baseline has every stress counter at zero, so disqualifying on
    #    "counter == 0" alone would make every no-stress config COLD forever.  It
    #    stays reportable and carries the unstressed caveat instead
    #    (positive-control.md S4: requested-but-dead, not merely zero).
    # =======================================================================
    case("unstressed-baseline-still-reportable", "NOT-OBSERVED-MU-HOT",
         cv=["UNSTRESSED"], stress_requested=0,
         spin_rendezvous=0, spin_cap=0, cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 7. The tau_hot boundary bites exactly at tau_hot.
    # =======================================================================
    case("tau-boundary-just-below", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_target_count=29, canary_target_count=29),
    case("tau-boundary-exactly-at", "NOT-OBSERVED-MU-HOT",
         control_target_count=30, canary_target_count=0),

    # The canary's OWN tau boundary, on a canary-only harness: for every test at the
    # lattice floor the canary is the only liveness evidence there is.
    case("canary-tau-just-below", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_compiled_in=0, control_target_count=0, canary_target_count=29),
    case("canary-tau-exactly-at", "NOT-OBSERVED-CANARY-ONLY",
         control_compiled_in=0, control_target_count=0, canary_target_count=30),

    # =======================================================================
    # 8. Caveats travel with the number, but do not invalidate.
    # =======================================================================
    case("mu-hot-but-pinning-is-fiction", "NOT-OBSERVED-MU-HOT", cv=["AFF_FAILED"],
         cpu_aff_failures=3),
    case("mu-hot-but-placement-refused", "NOT-OBSERVED-MU-HOT",
         cv=["PLACE_REFUSED"], place_failures=1),
    case("mu-hot-but-spin-is-a-delay-loop", "NOT-OBSERVED-MU-HOT", cv=["SPIN_CAP"],
         spin_rendezvous=100, spin_cap=900),

    # =======================================================================
    # 9. A sighting must carry the stress it was seen under.  Test parameters have
    #    a large impact on how often an outcome appears, and the observed frequency
    #    is sensitive to the machine and its operating system besides
    #    [Alglave11 sec 4], so a result reported without its configuration is not
    #    reproducible.
    # =======================================================================
    case("sighting-carries-its-caveats", "OBSERVED",
         cv=["AFF_FAILED", "PLACE_REFUSED", "SPIN_CAP"],
         target_count_exhaustive=1,
         cpu_aff_failures=3, place_failures=1,
         spin_rendezvous=100, spin_cap=900),
    case("sighting-on-an-unstressed-run-says-so", "OBSERVED", cv=["UNSTRESSED"],
         target_count_exhaustive=1, stress_requested=0,
         spin_rendezvous=0, spin_cap=0, gpu_stress_rounds=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 10. The control's own exhaustive_valid must NOT gate the null.  A mutant can
    #     itself be a T_L>=2 shape (mu(SB-*-sys-fence-2s) IS SB-*-sys-acqrel-2s), so
    #     its exhaustive scan does not run at production N and its count comes from
    #     the windowed detector -- which under-counts but cannot invent a cycle.
    #     Gating on it would leave those controls structurally cold, and a positive
    #     control that cannot fire is not a control (positive-control.md S5).  T's
    #     OWN exhaustive_valid still gates the null; the control's does not.
    # =======================================================================
    case("control-count-from-the-window-still-vouches", "NOT-OBSERVED-MU-HOT",
         control_exhaustive_valid=0, control_target_count=500),

    # =======================================================================
    # 11. A windowed zero is NOT a measured zero, and the printout must say so or
    #     it overstates the effort behind a non-observation.
    # =======================================================================
    case("windowed-zero-must-say-so", "NOT-OBSERVED-CANARY-ONLY",
         cv=["NO_EXHAUSTIVE"], exhaustive_valid=0,
         control_compiled_in=0, control_target_count=0),

    # =======================================================================
    # 12. The CPU-only cycle.  The emitter sets cpu_only when every proc carries
    #     the `cpu' tag, and both outcome frames then say what was under test: no
    #     cross-device path carried the cycle, so what a sighting shows is the host
    #     ISA on the shared allocation and what a null probes is that allocation's
    #     memory type.  The set carrying it comes from
    #     hetlitmus/tests/het/generate-cpuonly.sh, whose map writes `none' in the Mu
    #     column of every row, so both cases here co-run none either.
    # =======================================================================
    case("cpu-only-sighting-names-what-fired", "OBSERVED",
         cpu_only=1, target_count_exhaustive=3, target_count_heuristic=3,
         control_compiled_in=0, control_target_count=0),
    case("cpu-only-null-probes-the-allocation", "NOT-OBSERVED-CANARY-ONLY",
         cpu_only=1, control_compiled_in=0, control_target_count=0),
]

# Cases whose PRINTOUT must disclose that the count came from the window, not the
# ground-truth scan (phase 2).
MUST_PRINT_SCAN_CAVEAT = {"windowed-zero-must-say-so",
                          "no-exhaustive-is-never-mu-hot"}
SCAN_CAVEAT_TEXT = "rests on the WINDOWED heuristic"

# A store-only COLD null must NAME the observer channel that failed; the generic
# "interleavings_detected==0" is meaningless for a shape with no reader.
MUST_NAME_OBSERVER_CHANNEL = {"store-only-observer-cold-is-COLD"}
OBSERVER_CHANNEL_TEXT = "OBSERVER channel was COLD"

# Cases that must NOT carry CV_CANARY_ONLY (checked negatively -- see above).
NO_CANARY_ONLY_CV = {"canary-only-when-no-mu-is-compiled-in",
                     "store-only-observer-live-is-a-null",
                     "canary-tau-exactly-at"}

# The CPU-only sentences, owner case -> the fragment only that case may print.
# Both are keyed on `_r->cpu_only' in het_verdict.h, and every reader of that
# flag is checked both ways: the owner must print its sentence and every other
# case must print neither, so a flag read as constant is caught whichever
# constant it froze to.  A name here that no case carries reddens too, rather
# than dropping its half of the pair silently.
CPU_ONLY_TEXT = {
    "cpu-only-sighting-names-what-fired":
        "CPU-ONLY CYCLE: every proc of this test is a CPU proc",
    "cpu-only-null-probes-the-allocation":
        "SHARED-ALLOCATION PROBE: this is a CPU-ONLY shape",
}
# The two other readers of the same flag, which say nothing in prose: the verdict
# banner's tag and the machine-readable field hetlitmus/campaign.py schedules off.
CPU_ONLY_BANNER = " CPU-ONLY"
CPU_ONLY_FIELD = "cpu_only=%d"

C_MAIN = r"""
/* GENERATED by hetlitmus/verify/verdictcheck.py -- do not edit. */
#include "het_verdict.h"
#include <string.h>

static int failures = 0;

static void run_case(const char *name, het_obs_record r,
                     const char *want, uint32_t want_dq, uint32_t want_cv,
                     uint32_t forbid_cv) {
  uint32_t dq = 0, cv = 0;
  het_verdict_t v = het_verdict(&r, &dq, &cv);
  const char *got = het_verdict_name(v);
  int ok = (strcmp(got, want) == 0)
        && ((dq & want_dq) == want_dq)
        && ((cv & want_cv) == want_cv)
        && ((cv & forbid_cv) == 0);
  printf("CASE|%s|%s|%s|0x%x|0x%x|%d\n", name, want, got, dq, cv, ok);
  /* Phase 2 reads this: what the harness would ACTUALLY PRINT.  Both lines, in
     the order the emitted driver writes them (hetEmit.ml): the machine-readable
     record and then the human block.  A field only the first one carries is
     still a field a downstream tool parses. */
  printf("PRINT-BEGIN|%s\n", name);
  het_obs_record_print(stdout, &r);
  het_verdict_print(stdout, &r);
  printf("PRINT-END|%s\n", name);
  if (!ok) failures++;
}

int main(void) {
  printf("TAU_HOT=%d\n", (int)HET_TAU_HOT);
__CASES__
  printf("FAILURES=%d\n", failures);
  return failures ? 1 : 0;
}
"""


def c_record(r):
    def val(k, v):
        # rec_magic is emitted as the SYMBOL, not as its numeric value: spelling
        # the constant here would let the gate keep passing if the header changed
        # it, which is the one thing the stamp exists to prevent.
        return v if isinstance(v, str) else str(v)
    return ("(het_obs_record){ .test_name=\"synthetic\", "
            + ", ".join(".%s=%s" % (k, val(k, v)) for k, v in sorted(r.items()))
            + " }")


def build_c():
    body = []
    for c in CASES:
        dq = " | ".join("HET_DQ_" + d for d in c["dq"]) or "0u"
        cv = " | ".join("HET_CV_" + d for d in c["cv"]) or "0u"
        forbid = ("HET_CV_CANARY_ONLY" if c["name"] in NO_CANARY_ONLY_CV else "0u")
        body.append('  run_case("%s", %s, "%s", %s, %s, %s);'
                    % (c["name"], c_record(c["rec"]), c["verdict"], dq, cv, forbid))
    return C_MAIN.replace("__CASES__", "\n".join(body))


def emit_header(tmp):
    """Get the REAL het_verdict.h -- the one litmus7 writes into every harness."""
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    test = os.path.join(HET_DIR, "MP-cg-sys-fence-2s.litmus")
    subprocess.run(["litmus7", "-gpu-target", "cuda", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, test],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h = os.path.join(out, "MP-cg-sys-fence-2s", "het_verdict.h")
    if not os.path.exists(h):
        raise SystemExit("verdictcheck: litmus7 did not emit het_verdict.h")
    return h


def _env():
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    return env


# ---------------------------------------------------------------------------
# PHASE 4 -- which machine the printout names.
#
# Every machine word het_verdict.h prints comes from a define the emitter stamps
# out of the machine-table row (litmus/hetMachine.ml), with generic defaults when
# none are stamped.  Three properties, all read off the printout rather than off
# the defines (the enum changing is not the deliverable, the sentence is): with no
# defines the frame is the generic one, naming the mechanism and NEVER a vendor;
# with the (AArch64, cuda) defines it is the GH200 machine; with the (x86_64, hip)
# defines it is that pair's own machine, carrying no Grace/Hopper/NVLink and none
# of the NVIDIA-only measurements.  The defines are scraped from real emissions,
# never typed here, so the phase tests what the emitter stamps.
# ---------------------------------------------------------------------------
MACHINE_DEFINE_RE = re.compile(
    r"^#define HET_(?:LINK_NAME|HOST_HALF|DEV_HALF|ALGLAVE_ZERO_MEASURED"
    r"|PLACE_LEVER|PAIR_NAME)\b.*$", re.M)

# (label, corpus dir, test, -gpu-target, render extension)
MACHINE_PAIRS = [
    ("(AArch64, cuda)", HET_DIR, "MP-cg-sys-fence-2s", "cuda", "cu"),
    ("(x86_64, hip)", os.path.join(ROOT, "hetlitmus", "tests", "het-x86"),
     "MP-cg-sys-relaxed-x86_64", "hip", "hip"),
]

# What each frame MUST print, and what it must NEVER print.  The `must' strings
# are the sentences themselves, spliced back together across the C string
# concatenations they are written in.
GENERIC_MUST = [
    "- the host half of the host-device interconnect noise did NOT run",
    "- the device half of the host-device interconnect noise did NOT run",
    "same host-device interconnect path.",
    "the host-device interconnect path is alive",
    "CAVEAT: the page-placement lever was REFUSED -- HET_PLACE placed nothing.",
    "(Alglave ASPLOS'15 Tab. 6's zero without memory stress is an NVIDIA GTX Titan "
    "measurement and is NOT claimed for this target",
    # The sentence that has to NAME the target, and the only one carrying BOTH
    # stamped strings.  Each frame asserts its own name, so a constant fails here.
    "Report it as what (unstamped CPU ISA x GPU dialect pair) exhibited under "
    "this harness, this stress and this host-device interconnect path.",
]
NVIDIA_MUST = [
    "- the Grace half of the NVLink-C2C noise did NOT run",
    "- the Hopper half of the NVLink-C2C noise did NOT run",
    "same NVLink-C2C path.",
    "the NVLink-C2C path is alive",
    "CAVEAT: cudaMemAdvise was REFUSED -- HET_PLACE placed nothing.",
    "On the NVIDIA GTX Titan the inter-CTA lb and sb tests were observed 0 per 100k "
    "without memory stress, while mp and coRR were observed (Alglave ASPLOS'15 "
    "Tab. 6)",
    "Report it as what (AArch64, cuda) exhibited under this harness, this stress "
    "and this NVLink-C2C path.",
]
AMD_MUST = [
    "- the x86 half of the Infinity Fabric noise did NOT run",
    "- the MI300A device half of the Infinity Fabric noise did NOT run",
    "same Infinity Fabric path.",
    "the Infinity Fabric path is alive",
    # No placement lever on this render, and no [Alglave15 Tab. 6] figure covers
    # this part.
    "CAVEAT: the page-placement lever was REFUSED -- HET_PLACE placed nothing.",
    "(Alglave ASPLOS'15 Tab. 6's zero without memory stress is an NVIDIA GTX Titan "
    "measurement and is NOT claimed for this target",
    "Report it as what (X86_64, hip) exhibited under this harness, this stress "
    "and this Infinity Fabric path.",
]
NVIDIA_WORDS = ["Grace", "Hopper", "NVLink", "cudaMemAdvise",
                "the inter-CTA lb and sb tests were observed 0 per 100k",
                "(AArch64, cuda)"]
AMD_WORDS = ["Infinity Fabric", "MI300A", "the x86 half", "(X86_64, hip)"]
# Forbidden in EVERY frame: a constant standing in for the pair the binary was
# built for.  There is no stamp for which it is right.
BLOB_WORDS = ["the target this harness was tagged for"]

MACHINE_FRAMES = [
    ("no defines (an unregistered pair)", None,
     GENERIC_MUST, NVIDIA_WORDS + AMD_WORDS + BLOB_WORDS),
    ("(AArch64, cuda)", "(AArch64, cuda)", NVIDIA_MUST, AMD_WORDS + BLOB_WORDS),
    ("(x86_64, hip)", "(x86_64, hip)", AMD_MUST, NVIDIA_WORDS + BLOB_WORDS),
]


def scrape_machine_defines(tmp, label, corpus, test, target, ext):
    """The HET_* machine defines the emitter really stamps for one pair."""
    out = os.path.join(tmp, "pair-" + target + "-" + os.path.basename(corpus))
    os.makedirs(out, exist_ok=True)
    subprocess.run(["litmus7", "-gpu-target", target,
                    "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, os.path.join(corpus, test + ".litmus")],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    render = os.path.join(out, test, test + "." + ext)
    if not os.path.exists(render):
        raise SystemExit("verdictcheck: no %s emitted for the %s pair"
                         % (os.path.basename(render), label))
    with open(render) as fh:
        return MACHINE_DEFINE_RE.findall(fh.read())


def printout_with(header, tmp, defines, tag):
    """Compile the rule with [defines] prepended; return its whole printout."""
    sub = tempfile.mkdtemp(prefix="verdictmachine.", dir=tmp)
    shutil.copy(header, os.path.join(sub, "het_verdict.h"))
    pre = os.path.join(sub, "machine.h")
    with open(pre, "w") as fh:
        fh.write("/* scraped from the %s emission */\n" % tag)
        fh.write("\n".join(defines) + "\n")
    src = os.path.join(sub, "vt.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(sub, "vt")
    cc = subprocess.run(
        ["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
         "-include", pre, "-I", sub, src, "-o", exe, "-lm"],
        capture_output=True, text=True)
    if cc.returncode != 0:
        return None, cc.stdout + cc.stderr
    run = subprocess.run([exe], capture_output=True, text=True)
    return run.stdout, ""


def check_machine_prose(header, tmp, quiet, defines_by_pair=None):
    """defines_by_pair: {label: [define lines]}.  --bite passes a tampered map."""
    print("\n===== PHASE 4: which MACHINE does the printout name? =====")
    if defines_by_pair is None:
        defines_by_pair = {}
        for label, corpus, test, target, ext in MACHINE_PAIRS:
            defines_by_pair[label] = \
                scrape_machine_defines(tmp, label, corpus, test, target, ext)
    for label, defs in sorted(defines_by_pair.items()):
        print("  %-16s stamps %d machine define(s)" % (label, len(defs)))
        if not quiet:
            for d in defs:
                print("      %s" % d)

    bad = 0
    for label, pair, must, forbid in MACHINE_FRAMES:
        defs = [] if pair is None else defines_by_pair[pair]
        text, err = printout_with(header, tmp, defs, label)
        if text is None:
            print("  *** %-46s did not compile:\n%s" % (label, err[-800:]))
            bad += 1
            continue
        for want in must:
            if want not in text:
                print("  *** %-46s never printed %r" % (label, want))
                bad += 1
            elif not quiet:
                print("      %-16s prints %r" % (label, want))
        for banned in forbid:
            if banned in text:
                print("  *** %-46s printed %r -- a claim about a machine this "
                      "harness is not" % (label, banned))
                bad += 1

    if bad:
        print("\nMACHINE PROSE FAILED: %d problem(s).  A run that names the wrong "
              "silicon reports a measurement of a machine that never ran." % bad)
        return 1
    print("\nMACHINE PROSE OK (generic without defines; each pair's own machine "
          "with them; no frame names another pair's)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 3 -- the emitted corpus stamps its record and co-runs what the map says.
# ---------------------------------------------------------------------------
def read_control_map():
    """test -> (mu, canary), from the committed map (fields 2 and 6)."""
    want = {}
    with open(CONTROL_MAP) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = line.split(",")
            if len(f) != 6 or f[0] == "Test":
                continue
            want[f[0]] = (f[1], f[5])
    return want


MAGIC_RE = re.compile(r"_rec\.rec_magic\s*=\s*HET_REC_MAGIC\s*;")
CTRL_RE = re.compile(r"^#define HET_CONTROL_COMPILED_IN (\d)$", re.M)
CAN_RE = re.compile(r"^#define HET_CANARY_COMPILED_IN (\d)$", re.M)


_CORPUS = None


def emit_corpus(tests):
    """{test: .cu source, or None if the harness did not appear}, from ONE litmus7
    invocation over the whole corpus, held for the life of the process.  An
    injection rewrites the source it is handed and never the file, so the same
    emission serves the phase and every corpus bite; the scratch dir is dropped as
    soon as it has been read.  None on an emitter failure, already reported."""
    global _CORPUS
    if _CORPUS is None:
        tmp = tempfile.mkdtemp(prefix="verdictcorpus.")
        try:
            r = subprocess.run(
                ["litmus7", "-gpu-target", "cuda",
                 "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                 "-o", tmp] + [os.path.join(HET_DIR, t + ".litmus") for t in tests],
                cwd=ROOT, env=_env(), capture_output=True, text=True)
            if r.returncode != 0:
                print("  *** litmus7 failed to emit the corpus:\n" + r.stderr[-2000:])
                return None
            out = {}
            for t in tests:
                cu = os.path.join(tmp, t, t + ".cu")
                if not os.path.exists(cu):
                    out[t] = None
                    continue
                with open(cu) as fh:
                    out[t] = fh.read()
            _CORPUS = out
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return _CORPUS


def check_corpus(tamper=None):
    """tamper: (test, src) -> src.  Used ONLY by --bite, to prove this phase FAILS
    when an emitted harness loses its stamp or its co-run population."""
    print("\n===== PHASE 3: does the EMITTED CORPUS stamp and co-run what it "
          "must? =====")
    want = read_control_map()
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    print("  het corpus  : %d .litmus" % len(tests))
    print("  control-map : %d rows" % len(want))

    bad, n_mu, n_can = 0, 0, 0
    tampered = 0
    sources = emit_corpus(tests)
    if sources is None:
        return 1
    for t in tests:
        src = sources.get(t)
        if src is None:
            print("  *** %-26s no .cu emitted" % t)
            bad += 1
            continue
        if tamper is not None:
            new = tamper(t, src)
            if new != src:            # cmp: the injection must really have hit
                tampered += 1
            src = new
        # (a) The stamp, exactly once and by its symbol.  het_verdict() reads no
        # field of an unstamped record, so a harness that lost this line reports
        # a build bug for every run it will ever make.
        n_magic = len(MAGIC_RE.findall(src))
        if n_magic != 1:
            print("  *** %-26s stamps rec_magic %d time(s) (want exactly 1)"
                  % (t, n_magic))
            bad += 1
        # (b) The co-run population, against the map that named it.  A flag set
        # without the instance behind it turns a structural zero into a control.
        mu, can = want.get(t, ("?", "?"))
        exp_mu = 1 if mu not in ("none", "?") else 0
        exp_can = 1 if can not in ("-", "self", "?") else 0
        got_mu = CTRL_RE.search(src)
        got_can = CAN_RE.search(src)
        got_mu = int(got_mu.group(1)) if got_mu else -1
        got_can = int(got_can.group(1)) if got_can else -1
        n_mu += 1 if got_mu == 1 else 0
        n_can += 1 if got_can == 1 else 0
        if got_mu != exp_mu or got_can != exp_can:
            print("  *** %-26s co-runs mu=%d canary=%d, control-map.csv says "
                  "mu=%d canary=%d (Mu=%s Canary=%s)"
                  % (t, got_mu, got_can, exp_mu, exp_can, mu, can))
            bad += 1

    if tamper is not None and tampered == 0:
        # An injection that matched nothing would "pass" for free.
        print("  *** VACUOUS BITE: the corpus injection matched NOTHING")
        return 2

    print()
    for label, seen, expect in (("mu(T) co-run", n_mu, CENSUS["mu"]),
                                ("canary co-run", n_can, CENSUS["canary"]),
                                ("harnesses", len(tests), CENSUS["tests"])):
        mark = "    " if seen == expect else " ***"
        print("%s  %-16s %3d  (expect %3d)" % (mark, label, seen, expect))
        if seen != expect:
            bad += 1

    if bad:
        print("\nCORPUS FAILED: %d problem(s).  A rule that fails closed on an "
              "unstamped record only helps if the emitter stamps; a co-run flag "
              "without its instance makes a structural zero read as a control."
              % bad)
        return 1
    print("\nCORPUS OK (%d harnesses, every one stamped once, co-run population "
          "matches control-map.csv)" % len(tests))
    return 0


# ---------------------------------------------------------------------------
def scan_prints(blocks, quiet):
    """PHASE 2 -- each outcome's sentences, both ways."""
    print("\n===== PHASE 2: does each outcome print ITS OWN sentences, and only "
          "those? =====")
    bad = 0

    # (a) Frame exclusivity, both ways.  A ban that passes because the sentence
    # vanished is not a check, so each claim must ALSO be reachable.
    for verdict, claims in sorted(FRAME_CLAIMS.items()):
        for claim in claims:
            here = sorted(n for n, (v, t) in blocks.items()
                          if v == verdict and claim in t)
            elsewhere = sorted(n for n, (v, t) in blocks.items()
                               if v != verdict and claim in t)
            if not here:
                print("  *** UNREACHABLE: no %s case prints %r -- the ban below it "
                      "is passing for free" % (verdict, claim))
                bad += 1
            elif not quiet:
                print("      %-26s prints %r (%d case(s))"
                      % (verdict, claim, len(here)))
            if elsewhere:
                print("  *** LEAKED: %r is the %s frame's sentence but %s printed "
                      "it" % (claim, verdict, ", ".join(elsewhere)))
                bad += 1

    # (b) The sentences shared by a GROUP of outcomes, same discipline.
    for claims, want_in, label in (
            (NON_SIGHTING_CLAIMS,
             {"NOT-OBSERVED-MU-HOT", "NOT-OBSERVED-CANARY-ONLY", "COLD-INVALID"},
             "every non-sighting outcome"),
            (NULL_TIER_CLAIMS,
             {"NOT-OBSERVED-MU-HOT", "NOT-OBSERVED-CANARY-ONLY"},
             "both null tiers")):
        for claim in claims:
            saw = set(v for _, (v, t) in blocks.items() if claim in t)
            missing = want_in - saw
            extra = saw - want_in
            if missing:
                print("  *** %r is meant to be printed by %s but %s never does"
                      % (claim, label, ", ".join(sorted(missing))))
                bad += 1
            if extra:
                print("  *** %r leaked into %s" % (claim, ", ".join(sorted(extra))))
                bad += 1
            if not missing and not extra and not quiet:
                print("      %-26s prints %r" % (label, claim))

    # A windowed zero must SAY it is a windowed zero.
    for name in sorted(MUST_PRINT_SCAN_CAVEAT):
        text = blocks.get(name, ("", ""))[1]
        if SCAN_CAVEAT_TEXT not in text:
            print("  *** %s did NOT disclose that its zero came from the WINDOW and "
                  "not from the ground-truth scan -- it overstates the effort behind "
                  "a non-observation" % name)
            bad += 1
        elif not quiet:
            print("      %-46s discloses its windowed zero (correctly)" % name)

    # The CPU-only sentences, both ways: the owner prints its own and nobody else
    # prints either (see CPU_ONLY_TEXT).
    for owner, text in sorted(CPU_ONLY_TEXT.items()):
        if text not in blocks.get(owner, ("", ""))[1]:
            print("  *** %s carries cpu_only=1 but never printed its CPU-only "
                  "sentence %r -- a CPU-only cycle that does not say so is "
                  "reported as a compound-model result" % (owner, text))
            bad += 1
        for name in sorted(n for n in blocks if n != owner):
            if text in blocks[name][1]:
                print("  *** %s printed the CPU-only sentence %r, which belongs to a "
                      "CPU-only cycle" % (name, text))
                bad += 1
        if not quiet:
            print("      %-46s prints its CPU-only sentence, and only it does" % owner)

    # ... and the same flag's two readers that print no sentence at all, each
    # against the case's own record rather than a list of names.  A constant in
    # either is invisible to the sentences above: the banner tag is what a reader
    # files the whole row under, and the HetObs field is what campaign.py and
    # oracle-compare.sh parse.
    want_flag = {c["name"]: int(c["rec"].get("cpu_only", 0)) for c in CASES}
    for name in sorted(blocks):
        lines = blocks[name][1].splitlines()
        banner = next((l for l in lines if l.startswith("HetVerdict ")), "")
        obs = next((l for l in lines if l.startswith("HetObs ")), "")
        flag = want_flag.get(name, 0)
        if (CPU_ONLY_BANNER in banner) != bool(flag):
            print("  *** %s carries cpu_only=%d and its verdict banner %s"
                  % (name, flag, "drops the CPU-ONLY tag" if flag
                     else "claims the CPU-ONLY tag"))
            bad += 1
        if (CPU_ONLY_FIELD % flag) not in obs:
            print("  *** %s carries cpu_only=%d and its HetObs line does not say "
                  "so (%r)" % (name, flag, obs[:56]))
            bad += 1
    if not quiet:
        print("      %-46s banner tag and HetObs field agree with the record"
              % ("%d case(s)" % len(blocks)))

    # A store-only COLD null must NAME the observer channel (see
    # MUST_NAME_OBSERVER_CHANNEL).
    for name in sorted(MUST_NAME_OBSERVER_CHANNEL):
        text = blocks.get(name, ("", ""))[1]
        if OBSERVER_CHANNEL_TEXT not in text:
            print("  *** %s did NOT name the OBSERVER channel as the cold reason -- a "
                  "store-only shape has no reader, so a generic interleaving "
                  "disqualifier misreports why its null was discarded" % name)
            bad += 1
        elif not quiet:
            print("      %-46s names the observer channel (correctly)" % name)

    if bad:
        print("\nPRINT FAILED: %d problem(s).  The enum changing is not the "
              "deliverable; the sentence is, and a sentence in the wrong frame "
              "reports something this harness never measured." % bad)
        return 1
    print("\nPRINT OK (every outcome prints its own sentences and no other's)")
    return 0


def run_rule(header, tmp, quiet):
    shutil.copy(header, os.path.join(tmp, "het_verdict.h"))
    print("  header : %s" % header)

    src = os.path.join(tmp, "vt.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(tmp, "vt")
    cc = subprocess.run(
        ["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
         "-I", tmp, src, "-o", exe, "-lm"],
        capture_output=True, text=True)
    # Every exit from here returns the (rc, blocks) pair both call sites unpack: a
    # bare int turns a non-compiling header into a TypeError traceback in place of
    # the diagnostic, which under --bite abandons every injection after it.
    if cc.returncode != 0:
        print(cc.stdout + cc.stderr)
        print("\nVERDICT FAILED: the rule does not compile")
        return 1, {}

    run = subprocess.run([exe], capture_output=True, text=True)
    lines = run.stdout.splitlines()

    # The driver prints TAU_HOT before the first case, so a missing first line
    # means the binary died before it ran anything.  That is reported, NEVER
    # indexed into: an empty list here raises in place of the diagnostic.
    m = re.match(r"TAU_HOT=(\d+)", lines[0]) if lines else None
    if m is None:
        print(run.stdout + run.stderr)
        print("\nVERDICT FAILED: the compiled rule produced no TAU_HOT line "
              "(exit %d, %d line(s) of stdout) -- it did not reach the first case"
              % (run.returncode, len(lines)))
        return 1, {}
    tau = int(m.group(1))
    print("  tau_hot: %d\n" % tau)

    seen_v, seen_dq, bad = set(), set(), 0
    blocks, cur, buf = {}, None, []

    for l in lines[1:]:
        if l.startswith("CASE|"):
            _, name, want, got, dq, cv, ok = l.split("|")
            seen_v.add(got)
            if int(dq, 16):
                seen_dq.add(int(dq, 16))
            blocks[name] = [got, ""]
            if ok != "1":
                bad += 1
                print("  *** %-46s want %-24s got %-24s (dq=%s cv=%s)"
                      % (name, want, got, dq, cv))
            elif not quiet:
                print("      %-46s %-24s dq=%-6s cv=%s" % (name, got, dq, cv))
        elif l.startswith("PRINT-BEGIN|"):
            cur, buf = l.split("|", 1)[1], []
        elif l.startswith("PRINT-END|"):
            blocks[cur][1] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(l)

    print()
    # Outcome coverage is ASSERTED, not merely reported: a rule whose fourth
    # outcome no case can reach is a rule with three, and the per-case comparisons
    # cannot see that on their own if a case was deleted with it.
    print("  outcomes reached      : %d/%d  (%s)"
          % (len(seen_v), len(VERDICTS), ", ".join(sorted(seen_v))))
    missing_v = [v for v in VERDICTS if v not in seen_v]
    if missing_v:
        print("  *** UNREACHABLE OUTCOME: %s -- an outcome no case reaches is an "
              "outcome the rule may never return" % ", ".join(missing_v))
        bad += 1

    blocks = {k: (v[0], v[1]) for k, v in blocks.items()}
    if bad:
        print("\nVERDICT FAILED: %d case(s) wrong." % bad)
        return 1, blocks
    print("\nVERDICT OK (%d cases; all %d outcomes reachable; an unstamped record "
          "fails closed; exhaustive_valid==0 is never the strong null; every "
          "disqualifier bites)" % (len(CASES), len(VERDICTS)))
    return 0, blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", default=None)
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true",
                    help="prove this gate FAILS when the mechanism it guards breaks")
    a = ap.parse_args()

    if a.bite:
        return bite()

    print("===== PHASE 1: is het_verdict() actually a decision? =====")
    tmp = tempfile.mkdtemp(prefix="verdictcheck.")
    try:
        header = a.header or emit_header(tmp)
        rc, blocks = run_rule(header, tmp, a.quiet)
        rc |= scan_prints(blocks, a.quiet)
        rc |= check_machine_prose(header, tmp, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= check_corpus()

    print("\n" + "=" * 70)
    if rc:
        print("VERDICTCHECK: FAIL")
    else:
        print("VERDICTCHECK: PASS  (rule + printout + machine prose + emitted corpus)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: a gate never seen to FAIL is not evidence.  Each injection breaks exactly
# one thing this gate claims to guard, is verified to have actually CHANGED the file
# (one that matched nothing would pass for free), and must drive the gate nonzero.
# ---------------------------------------------------------------------------
def _bite_one(label, tmp, header, mutate, quiet, expect=None):
    """mutate: str -> str.  Returns True if the gate correctly FAILED.

    [expect] is a fragment of a diagnostic the run must produce.  Without it a
    nonzero return counts as a bite whatever reddened, which on a rule with
    several readers is not the same claim as "this injection was caught"."""
    with open(header) as fh:
        orig = fh.read()
    new = mutate(orig)
    if new == orig:
        print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
        return False
    mut = os.path.join(tmp, "bitten.h")
    with open(mut, "w") as fh:
        fh.write(new)

    sub = tempfile.mkdtemp(prefix="verdictbite.")
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc, blocks = run_rule(mut, sub, quiet=True)
            rc |= scan_prints(blocks, quiet=True)
    finally:
        shutil.rmtree(sub, ignore_errors=True)

    said = [l for l in buf.getvalue().splitlines() if l.startswith("  ***")]
    if not rc:
        print("  *** DID NOT BITE: the gate PASSED on a broken rule   [%s]" % label)
        return False
    if expect is not None and not any(expect in l for l in said):
        print("  *** WRONG DIAGNOSTIC: nothing said %r   [%s]" % (expect, label))
        for l in said[:5]:
            print("      %s" % l.strip())
        return False
    print("  BITES (gate failed, as it must)%s   [%s]"
          % ("" if expect is None else ": " + expect, label))
    return True


def _bite_report(label, header, mutate, want):
    """A bite on a REPORTING path: the gate must SAY what went wrong.

    Distinct from _bite_one, which reads the exit status alone.  The two paths
    bitten through this helper cannot be checked that way, because a run_rule that
    raises -- on a header that does not compile, or on a binary that printed
    nothing -- exits nonzero too, with a traceback in place of the sentence.  The
    sentence is the deliverable, so the sentence is what is asserted: no
    exception, rc == 1, and `want' in what the gate printed.  Each bite gets a
    fresh scratch dir, so a write that failed cannot hand run_rule a previous
    bite's header."""
    with open(header) as fh:
        orig = fh.read()
    new = mutate(orig)
    if new == orig:
        print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
        return False

    sub = tempfile.mkdtemp(prefix="verdictbite.")
    mut = os.path.join(sub, "bitten.h")
    with open(mut, "w") as fh:
        fh.write(new)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc, _ = run_rule(mut, sub, quiet=True)
    except Exception as e:
        print("  *** DID NOT REPORT: run_rule RAISED %s (%s) instead of returning a "
              "diagnostic   [%s]" % (type(e).__name__, e, label))
        return False
    finally:
        shutil.rmtree(sub, ignore_errors=True)

    said = [l for l in buf.getvalue().splitlines() if want in l]
    if rc != 1 or not said:
        print("  *** DID NOT BITE: rc=%r and the gate never printed %r   [%s]"
              % (rc, want, label))
        return False
    print("  BITES (reported, as it must): %s   [%s]" % (said[0].strip(), label))
    return True


def _bite_machine(label, tmp, header, mutate=None, defines=None, expect=None):
    """Break the MACHINE PROSE path; check_machine_prose must fail.

    Two injection sites, because the prose has two: the header's #ifndef
    defaults (what an unstamped harness prints) and the defines the emitter
    stamps (what a stamped one prints).  [defines] injects at the second.

    [expect] is a fragment of the first diagnostic, which is what says which of
    the two directions caught the injection -- a `must' that stopped printing or
    a forbidden word that started.  Without it a rc of 1 counts as a bite
    whatever reddened, and a whole direction can go unbitten while every arm
    reports a bite."""
    hdr = header
    if mutate is not None:
        with open(header) as fh:
            orig = fh.read()
        new = mutate(orig)
        if new == orig:
            print("  *** VACUOUS BITE: the injection changed nothing   [%s]" % label)
            return False
        hdr = os.path.join(tmp, "machine-bitten.h")
        with open(hdr, "w") as fh:
            fh.write(new)

    sub = tempfile.mkdtemp(prefix="verdictmachinebite.")
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = check_machine_prose(hdr, sub, quiet=True, defines_by_pair=defines)
    finally:
        shutil.rmtree(sub, ignore_errors=True)
    if not rc:
        print("  *** DID NOT BITE: the gate PASSED on wrong machine prose   [%s]"
              % label)
        return False
    said = [l for l in buf.getvalue().splitlines() if l.startswith("  ***")]
    first = said[0].strip() if said else "(no diagnostic)"
    if expect is not None and expect not in first:
        print("  *** WRONG DIAGNOSTIC: %s\n      wanted %r first   [%s]"
              % (first, expect, label))
        return False
    print("  BITES (gate failed, as it must): %s   [%s]" % (first, label))
    return True


def bite():
    print("===== BITE TEST: does this gate actually FAIL when the rule breaks? ====")
    tmp = tempfile.mkdtemp(prefix="verdictbite.")
    ok = True
    try:
        header = emit_header(tmp)

        # (1) The sighting branch made CONSTANT: every record reads as OBSERVED, so
        # every null case takes the sighting frame.
        ok &= _bite_one(
            "the sighting test forced CONSTANT (every record read as OBSERVED)",
            tmp, header,
            lambda s: s.replace(
                "if (r->target_count_exhaustive > 0 || r->target_count_heuristic > 0) {",
                "if (1) {"),
            quiet=True)

        # (2) The two null tiers collapsed: mu(T)'s own liveness stops selecting the
        # strong null, so a canary-only harness reports a mu-hot null.  The record
        # fields are untouched, so only the outcome comparison sees it.
        ok &= _bite_one(
            "the two null tiers collapsed (canary-only reads as MU HOT)",
            tmp, header,
            lambda s: s.replace("} else if (hot_control && r->exhaustive_valid) {",
                                "} else if (1) {"),
            quiet=True)

        # (3) rec_magic stops failing closed: a memset-zeroed record is read as a
        # live one, which is the whole property the stamp exists for.
        ok &= _bite_one(
            "rec_magic no longer fails closed (an unstamped record is read)",
            tmp, header,
            lambda s: s.replace("if (r->rec_magic != HET_REC_MAGIC) {",
                                "if (0) {"),
            quiet=True)

        # (4) The windowed-zero disclosure dropped: the cv flag is still set, so ONLY
        # phase 2 can see that the sentence is gone.
        ok &= _bite_one(
            "the windowed-zero caveat dropped from every printout",
            tmp, header,
            lambda s: s.replace("  het_print_scan_caveat(_ch, _r, cv);\n", ""),
            quiet=True)

        # (4b) The cpu_only flag read as a CONSTANT, both ways.  The CPU-only
        # sentences are the only place the printout says that no cross-device path
        # carried the cycle, so a frozen flag either hides that on the CPU-only set
        # or claims it about every het test in the corpus.
        ok &= _bite_one(
            "the cpu_only branches forced OFF (no CPU-only sentence anywhere)",
            tmp, header,
            lambda s: s.replace("if (_r->cpu_only)", "if (0)"),
            quiet=True,
            expect="never printed its CPU-only sentence")
        ok &= _bite_one(
            "the cpu_only branches forced ON (every cycle claims to be CPU-only)",
            tmp, header,
            lambda s: s.replace("if (_r->cpu_only)", "if (1)"),
            quiet=True,
            expect="which belongs to a CPU-only cycle")

        # (4c) ... and the same flag's two silent readers, one injection each,
        # keyed on its negation so one arm drives both halves of its assertion.
        # Neither prints a sentence, so the two arms above cannot see either of
        # them freeze: the tag rides the banner line and the field rides the
        # machine-readable one.
        ok &= _bite_one(
            "the banner's CPU-ONLY tag keyed on the negation of the flag",
            tmp, header,
            lambda s: s.replace('_r->cpu_only ? " CPU-ONLY" : ""',
                                '!_r->cpu_only ? " CPU-ONLY" : ""'),
            quiet=True,
            expect="its verdict banner")
        ok &= _bite_one(
            "the HetObs line's cpu_only field keyed on the negation of the flag",
            tmp, header,
            lambda s: s.replace("    _r->cpu_only,\n", "    !_r->cpu_only,\n"),
            quiet=True,
            expect="its HetObs line does not say so")

        # (5) The header does not compile.  Not a broken rule -- a broken report of
        # one.  A gate that answers a non-compiling header with a traceback has
        # stopped saying which part of what it guards is wrong, and under --bite it
        # stops running at all.  The flavour of the syntax error carries no
        # meaning; `@' is simply not a C token.
        print("\n-- reporting-path injections --")
        ok &= _bite_report(
            "a header that DOES NOT COMPILE must be REPORTED, not raised",
            header,
            lambda s: s + "\nstatic int _het_bite_does_not_compile(void) "
                          "{ return @; }\n",
            "VERDICT FAILED: the rule does not compile")

        # (6) The compiled rule prints nothing.  The driver prints TAU_HOT before
        # the first case, so an empty stdout means the binary died before it ran
        # one -- which the gate must say, NEVER index into.  A constructor that
        # _Exit()s is the shortest way to produce that: it is what a header
        # carrying a broken static initialiser does in the wild, one step earlier.
        ok &= _bite_report(
            "a compiled rule that produces NO TAU_HOT line must be REPORTED",
            header,
            lambda s: s + "\n__attribute__((constructor)) static void "
                          "_het_bite_die_before_main(void) { _Exit(97); }\n",
            "produced no TAU_HOT line")

        # (7) A harness ships unstamped: het_verdict() fails closed, but ONLY if it
        # is ever run, so the corpus census is what stops one harness quietly
        # discarding every run it will ever make.
        print("\n-- corpus injections --")
        rc = check_corpus(tamper=lambda t, s: (
            s.replace("_rec.rec_magic = HET_REC_MAGIC;", "_rec.rec_magic = 0;")
            if t == "S-cg-sys-fence" else s))
        if rc == 1:
            print("  BITES (gate failed, as it must)   "
                  "[a harness shipped with an unstamped record]")
        else:
            print("  *** DID NOT BITE (rc=%d)   "
                  "[a harness shipped with an unstamped record]" % rc)
            ok = False

        # (8) A co-run flag without its instance: the harness claims a canary is
        # running, so a structural zero would be read as a cold control.
        rc = check_corpus(tamper=lambda t, s: (
            s.replace("#define HET_CANARY_COMPILED_IN 1",
                      "#define HET_CANARY_COMPILED_IN 0")
            if t == "IRIW-cgcg-sys-fence-2s" else s))
        if rc == 1:
            print("  BITES (gate failed, as it must)   "
                  "[a harness dropped the canary the map names for it]")
        else:
            print("  *** DID NOT BITE (rc=%d)   "
                  "[a harness dropped the canary the map names for it]" % rc)
            ok = False

        # (9) The fail-safe default made a vendor claim: an unstamped harness --
        # an unregistered pair, and every future pair before its row exists --
        # would then print a machine it is not.  The direction matters: a missing
        # define may ONLY weaken a claim.
        print("\n-- machine-prose injections --")
        ok &= _bite_machine(
            "the #ifndef DEFAULT names a vendor (unstamped => \"NVLink-C2C\")",
            tmp, header,
            mutate=lambda s: s.replace('#define HET_LINK_NAME "host-device interconnect"',
                                       '#define HET_LINK_NAME "NVLink-C2C"'),
            expect="never printed '- the host half of the host-device "
                   "interconnect noise did NOT run'")

        # (10) One sentence goes back to a literal, which is the defect the stamped
        # defines exist to stop in its simplest form: a sentence naming Grace
        # whatever the harness was built for.  The generic frame catches it as a
        # must it stopped printing, before any frame's forbidden list reaches the
        # word `Grace' -- so this arm holds the must direction and (13) the other.
        ok &= _bite_machine(
            "one sentence hardcodes \"the Grace half\" again",
            tmp, header,
            mutate=lambda s: s.replace("              HET_HOST_HALF, HET_LINK_NAME);",
                                       "              \"the Grace half\", HET_LINK_NAME);"),
            expect="never printed '- the host half of the host-device "
                   "interconnect noise did NOT run'")

        # (11) The emitter stamps the wrong pair's machine.  The header is correct
        # here and the harness lies to it, which is what the pair table exists to
        # stop; nothing in phases 1-3 looks at a define.
        real = {}
        for lbl, corpus, test, target, ext in MACHINE_PAIRS:
            real[lbl] = scrape_machine_defines(tmp, lbl, corpus, test, target, ext)
        crossed = dict(real)
        crossed["(x86_64, hip)"] = list(real["(AArch64, cuda)"])
        ok &= _bite_machine(
            "the (x86_64, hip) emission stamps the GH200 machine",
            tmp, header, defines=crossed,
            expect="never printed '- the x86 half of the Infinity Fabric "
                   "noise did NOT run'")

        # (12) The target name goes back to a constant.  The sentence still names
        # something, so ONLY a frame that knows its own pair name can see that it
        # is naming the wrong object; BLOB_WORDS pins that constant's wording.
        ok &= _bite_machine(
            "the report sentence names a constant instead of the pair",
            tmp, header,
            mutate=lambda s: s.replace(
                "      HET_PAIR_NAME, HET_LINK_NAME);",
                '      "the target this harness was tagged for", HET_LINK_NAME);'),
            expect="never printed 'Report it as what (unstamped CPU ISA x GPU "
                   "dialect pair)")

        # (13) A sentence names another vendor and every `must' still prints.  The
        # verdict banner gains an "[Infinity Fabric]" tag, which no frame's must
        # list mentions and which no parameterised sentence loses, so the ONLY
        # thing that can see it is the forbidden-word list.  Injections (9)-(12)
        # each redden on a must first, so without this arm the forbidden-word
        # direction is unbitten.
        ok &= _bite_machine(
            "the verdict banner tags every run with another vendor's fabric",
            tmp, header,
            mutate=lambda s: s.replace(
                '  fprintf(_ch, "HetVerdict %s [%s]%s run=%d: %s\\n",',
                '  fprintf(_ch, "HetVerdict %s [%s]%s run=%d: %s'
                '  [Infinity Fabric]\\n",'),
            expect="printed 'Infinity Fabric' -- a claim about a machine this "
                   "harness is not")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 70)
    if ok:
        print("BITE OK: 17/17 injections caught, each by the diagnostic it named --")
        print("         rule + printouts 8, reporting paths 2, emitted corpus 2,")
        print("         machine prose 5.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


if __name__ == "__main__":
    sys.exit(main())
