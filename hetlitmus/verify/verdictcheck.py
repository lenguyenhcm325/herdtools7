#!/usr/bin/env python3
"""HetLitmus B6/B6c -- the decision-rule gate.

het_verdict() (het_verdict.h) is what converts a raw target count into a CLAIM
about the compound memory model.  It is THE deliverable of B6, and it has exactly
the shape of a mechanism that can compile, pass every structural gate, and do
nothing -- or worse, do the wrong thing loudly:

  * a rule that always returns COLD discards every null forever;
  * a rule that always returns CREDIBLE-NULL reports every cold run as
    confirmation of the memory model -- the same silent falsification as the
    constant-false `_weak' detector B3 shipped on 266 of 338 tests;
  * a rule that does not know WHAT THE MODEL PREDICTS frames every test as
    should-be-forbidden, and prints "the should-be-FORBIDDEN outcome was OBSERVED
    ... a single sighting REFUTES the model" on the 348 of 386 tests where the
    weak outcome is EXPECTED (307 Allowed) or where the model is SILENT (41
    NO-ORACLE).  That is a LOUD FALSE REFUTATION of the thesis's central claim,
    and it is what B6c fixed.

Structural gates cannot see any of these.  So this gate COMPILES THE REAL HEADER
(the one litmus7 emits into every harness -- not a copy, which would be free to
drift), feeds it synthetic het_obs_records, and asserts, in three phases:

  PHASE 1 -- THE RULE
    1. all SEVEN verdicts are reachable       => the rule is provably not constant
    2. all THREE oracle classes are reachable => the oracle branch is not constant
    3. exhaustive_valid == 0  =>  NEVER CREDIBLE (a count that was not measured is
       not a measured zero, and reading it as one manufactures a false "Never")
    4. every disqualifying liveness field  =>  COLD  (B4/B5: a null from a run
       whose stress was inert is not the same datum as one from a stressed run)
    5. a mechanism that was NOT requested and did no work does NOT disqualify
       (otherwise an intentional no-stress baseline is COLD forever -- which is
       just another way of building a rule that always says the same thing)
    6. the tau_hot boundary actually bites at tau_hot, not near it
    7. ORACLE_UNSET (the memset default) FAILS CLOSED and claims nothing.

  PHASE 2 -- THE PRINTOUT (this is the phase that bites B6c's bug)
    het_verdict_print() is captured for every case and scanned.  The three
    REFUTATION CLAIMS may appear if and only if the record is ORACLE_DISALLOWED:
        "should-be-FORBIDDEN"  "REFUTES the model's prediction"  "Disallowed outcome"
    Checked BOTH WAYS -- they must be ABSENT from every Allowed/NO-ORACLE block AND
    PRESENT in the Disallowed sighting.  A ban that never fires because the text is
    simply gone is not a check.

  PHASE 3 -- THE EMITTED CORPUS
    All 386 het harnesses are emitted and their `_rec.het_oracle = ORACLE_*' is
    cross-checked, PER TEST, against field 2 of tests/het/control-map.csv, with a
    census (38 Disallowed / 307 Allowed / 41 NO-ORACLE / 0 UNSET).  A rule that
    branches correctly on an oracle class the emitter never sets is worthless: the
    unit test would pass and all 386 harnesses would still fail closed.

Usage:  verdictcheck.py [--header PATH] [-q]        run the gate
        verdictcheck.py --bite                      prove the gate FAILS when the
                                                    mechanism it guards is broken
"""

import argparse
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

VERDICTS = ["MISMATCH", "CREDIBLE-NULL", "WEAK-NULL", "COLD-INVALID",
            "ALLOWED-OBSERVED", "ALLOWED-UNOBSERVED", "CHARACTERIZED"]

ORACLES = ["ORACLE_DISALLOWED", "ORACLE_ALLOWED", "ORACLE_NONE"]

# The oracle census the emitted corpus MUST reproduce (expected-nvidia.csv, via
# control-map.csv field 2).  ORACLE_UNSET is not listed because it must never occur.
CENSUS = {"Disallowed": 38, "Allowed": 307, "NO-ORACLE": 41}

CSV_TO_C = {"Disallowed": "ORACLE_DISALLOWED",
            "Allowed": "ORACLE_ALLOWED",
            "NO-ORACLE": "ORACLE_NONE"}

# ---------------------------------------------------------------------------
# THE THREE REFUTATION CLAIMS.  Each is a sentence that only a should-be-FORBIDDEN
# test is entitled to print.  On an oracle-ALLOWED test the very same observation is
# the model working as specified, so printing any of these is a false refutation of
# the compound model -- on 348 of the 386 harnesses, including the canary itself.
#
# These are matched as EXACT SUBSTRINGS, and they are deliberately the *claims*, not
# the word "forbidden": the NO-ORACLE text legitimately contains "neither allowed nor
# forbidden by the model", and the ALLOWED text legitimately contains "refutes
# NOTHING".  Banning a keyword would have banned the honest sentences too.
REFUTATION_CLAIMS = [
    "should-be-FORBIDDEN",
    "REFUTES the model's prediction",
    "Disallowed outcome",
]

# ---------------------------------------------------------------------------
# A "live, hot, credible" baseline: a DISALLOWED test whose mutant fired.  Every
# case below is this record with a few fields perturbed, so each isolates ONE reason.
BASE = dict(
    het_oracle="ORACLE_DISALLOWED",
    exhaustive_valid=1,
    target_count_exhaustive=0,
    target_count_heuristic=0,
    interleavings_detected=1000,
    # DR1-A2/F2: the baseline is a READER (sync-channel) test -- 364 of the 386, and
    # 36 of the 38 Disallowed (the 2 exceptions are the store-only 2+2W rows).  The verdict is now CHANNEL-AWARE, so a record with
    # neither channel flag set fails closed; the store-only cases below flip to the
    # observer channel (sync_valid=0, obs_valid=1) explicitly.
    sync_valid=1,
    control_compiled_in=1,
    canary_compiled_in=1,
    control_target_count=30,          # == HET_TAU_HOT
    canary_target_count=500,
    control_exhaustive_valid=1,
    canary_exhaustive_valid=1,
    stress_truncated=0,
    spin_rendezvous=900, spin_cap=100,
    gpu_stress_rounds=64,             # B6b: het_do_stress actually ran
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
    # 1. THE DISALLOWED FRAME (38 tests).  Unchanged by B6c: the null IS the
    #    evidence, so it has to be earned.
    # =======================================================================
    case("credible-null", "CREDIBLE-NULL"),

    case("mismatch-exhaustive", "MISMATCH", target_count_exhaustive=1),

    # A sighting refutes even on a run we would otherwise DISCARD: an inert-stress
    # run that nevertheless SAW the forbidden outcome still saw it.  No control is
    # needed to believe a positive (falsification is one-sided).
    case("mismatch-beats-every-disqualifier", "MISMATCH",
         target_count_exhaustive=1, control_compiled_in=0, canary_compiled_in=0,
         interleavings_detected=0, stress_truncated=99,
         cpu_enemy_rounds=0, noise_cpu_rounds=0, noise_gpu_blocks=0),

    # The heuristic count is a SUBSET of the exhaustive scan's (same predicate,
    # narrower search range), so a heuristic hit is a real recovered cycle.  For a
    # T_L>=2 shape at production N the exhaustive scan never runs, so keying
    # MISMATCH off it alone -- as Q4 3.3 literally says -- would silently drop a
    # genuine falsification.  We count it, and flag it.
    case("mismatch-heuristic-only", "MISMATCH", cv=["HEURISTIC_SIGHT"],
         target_count_heuristic=1, target_count_exhaustive=0, exhaustive_valid=0),

    case("weak-null-canary-only", "WEAK-NULL", cv=["CANARY_ONLY"],
         control_target_count=0, canary_target_count=500),

    case("cold-no-control-built", "COLD-INVALID", dq=["NO_CONTROL_BUILT"],
         control_compiled_in=0, canary_compiled_in=0,
         control_target_count=0, canary_target_count=0),

    # ---- exhaustive_valid == 0  =>  NEVER credible ------------------------
    # The harness is hot (mu(T) fired 500x) and everything is live -- but the
    # ground-truth scan did not run, so the zero is NOT a measured zero.
    case("no-exhaustive-cannot-be-credible", "WEAK-NULL", cv=["NO_EXHAUSTIVE"],
         exhaustive_valid=0, control_target_count=500),

    # =======================================================================
    # 2. B6c -- THE ALLOWED FRAME (307 tests).  Here the SIGHTING is the
    #    evidence, and it is evidence FOR the model, not against it.
    # =======================================================================
    # THE BUG B6c EXISTS TO KILL.  Before B6c this record -- an oracle-ALLOWED test
    # that saw its permitted weak outcome -- returned MISMATCH and printed "the
    # should-be-FORBIDDEN outcome was OBSERVED ... A single sighting REFUTES the
    # model's prediction".  It is the EXPECTED result.  Phase 2 proves the text is
    # gone, not merely that the enum changed.
    case("allowed-observed-is-NOT-a-refutation", "ALLOWED-OBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         target_count_exhaustive=412, target_count_heuristic=412),

    # THE SHARPEST INSTANCE.  MP-cg-sys-relaxed is oracle-Allowed AND is the Layer-B
    # canary for 265 rows of control-map.csv.  It co-runs no canary (it IS one:
    # control-map.csv says `self'), so BOTH compiled-in flags are 0.  The one test
    # whose entire job is to FIRE would, run standalone, have printed a refutation of
    # the compound memory model.  A firing Allowed test is its own control.
    case("the-canary-itself-firing-is-not-a-refutation", "ALLOWED-OBSERVED",
         het_oracle="ORACLE_ALLOWED",
         control_compiled_in=0, canary_compiled_in=0,
         control_target_count=0, canary_target_count=0,
         target_count_exhaustive=412, target_count_heuristic=412),

    # Permitted, harness demonstrably hot (the canary fired), still not seen.  An
    # OBSERVABILITY result -- Iorga's taxonomy, Alglave's GTX-280 honesty -- NOT a
    # model result.  This verdict is why the 307 needed a canary at all: without one
    # it is indistinguishable from a dead harness.
    case("allowed-unobserved-is-observability-not-model", "ALLOWED-UNOBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0),

    # DR1-A2/F2: THE STORE-ONLY (2+2W) CHANNEL SWITCH.  A store-only shape has NO
    # reader, so interleavings_detected is structurally 0 and its ONLY liveness
    # channel is the OBSERVER (sync_valid=0, obs_valid=1).  Before F2 the verdict read
    # interleavings_detected==0 blindly and forced all 22 of these to COLD-INVALID
    # forever -- 18 ALLOWED + 4 NO-ORACLE that could never report a clean null.
    #
    # (a) LIVE observer (>= HET_THETA_DISTINCT distinct GPU store-values) + hot canary,
    #     nothing seen  ->  a clean ALLOWED-UNOBSERVED (the bound-carrying null path).
    case("store-only-observer-live-is-ALLOWED-UNOBSERVED", "ALLOWED-UNOBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=500,
         interleavings_detected=0),

    # (b) COLD observer (< HET_THETA_DISTINCT -- EXACTLY what F1's hoist produced,
    #     observer_unique_count<=1)  ->  COLD-INVALID, and the printout must name the
    #     OBSERVER channel, not the meaningless "interleavings_detected==0".
    case("store-only-observer-cold-is-COLD", "COLD-INVALID", dq=["OBSERVER_COLD"],
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=1,
         interleavings_detected=0),

    # (c) A store-only SIGHTING is still a sighting: the observer channel must never
    #     block a genuinely recovered outcome (falsification is one-sided).
    case("store-only-observer-sighting-is-ALLOWED-OBSERVED", "ALLOWED-OBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         sync_valid=0, obs_valid=1, observer_unique_count=500,
         interleavings_detected=0,
         target_count_exhaustive=7, target_count_heuristic=7),

    # ... and with a COLD canary it must fall back to COLD-INVALID, not quietly
    # report "we did not see it" as though that meant something.
    case("allowed-cold-canary-is-still-COLD", "COLD-INVALID", dq=["CONTROLS_COLD"],
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0,
         control_target_count=0, canary_target_count=0),

    # =======================================================================
    # 3. B6c -- THE NO-ORACLE FRAME (41 tests).  Q4 R5: characterization, NEVER
    #    validation.  There is no prediction here to confirm or refute.
    # =======================================================================
    case("no-oracle-fired-is-characterized", "CHARACTERIZED",
         het_oracle="ORACLE_NONE", control_compiled_in=0, control_target_count=0,
         target_count_exhaustive=3, target_count_heuristic=3),

    # Not fired, but the canary was hot: "GH200 exhibited it in 0 of N frames on a
    # demonstrably hot harness" IS the characterization.  Z may be 0.
    case("no-oracle-unfired-hot-is-still-characterized", "CHARACTERIZED",
         het_oracle="ORACLE_NONE", control_compiled_in=0, control_target_count=0),

    # THE ANTI-CONSTANT CASE FOR NO-ORACLE.  Q4 R5 says these rows are
    # "characterization, always" -- but a verdict that is ALWAYS the same value is a
    # constant detector wearing a third hat, and characterizing a DEAD harness is a
    # fabrication, not a finding ("under a harness where the canary fired 0 times,
    # GH200 exhibited the outcome 0 times" is not a datum).  So COLD-INVALID stays
    # reachable here.  What the 41 can never produce is a MODEL claim -- Phase 2
    # enforces that.
    case("no-oracle-cold-harness-is-COLD-not-characterized", "COLD-INVALID",
         dq=["CONTROLS_COLD"], het_oracle="ORACLE_NONE",
         control_compiled_in=0, control_target_count=0, canary_target_count=0),

    # =======================================================================
    # 4. B6c -- ORACLE_UNSET FAILS CLOSED.
    # =======================================================================
    # het_obs_record is memset(0) before it is filled, so ORACLE_UNSET == 0 is what an
    # emitter that FORGOT the tag produces.  Had DISALLOWED been 0, that omission would
    # silently restore the false-refutation bug.  The rule must claim NOTHING -- not
    # even on a sighting, because it does not know what the sighting MEANS.
    case("oracle-unset-fails-closed", "COLD-INVALID", dq=["ORACLE_UNSET"],
         het_oracle="ORACLE_UNSET"),
    case("oracle-unset-fails-closed-even-on-a-sighting", "COLD-INVALID",
         dq=["ORACLE_UNSET"], het_oracle="ORACLE_UNSET",
         target_count_exhaustive=99),

    # =======================================================================
    # 5. Every disqualifier drives the verdict to COLD (B4/B5 liveness).
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

    # B6b: the gap B6a stated plainly and left open.  het_do_stress now has a
    # runtime tally (HET_TALLY_STRESS_ROUNDS), so "the GPU scratchpad stress was
    # requested and completed ZERO rounds" is finally a check that can FAIL.  It has
    # to be, because a co-run harness reserves 3x-5x the test blocks and the stress
    # population is the first thing the co-residency cap squeezes to zero.
    case("cold-gpu-stress-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         gpu_stress_rounds=0),

    # The liveness disqualifiers are CLASS-BLIND: an Allowed test whose stress was
    # inert is not a usable observability datum either.
    case("allowed-cold-when-stress-is-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         gpu_stress_rounds=0),

    # =======================================================================
    # 6. NOT-requested mechanisms must NOT disqualify.
    # =======================================================================
    # THE ANTI-CONSTANT-COLD CASE.  A deliberately unstressed baseline run has
    # every stress counter at zero.  If "counter == 0" alone disqualified, this
    # run -- and every run of a no-stress config -- would be COLD forever, and the
    # rule would be constant in practice while looking perfectly reasonable in
    # source.  It must stay reportable, and carry the Kirkham caveat instead.
    case("unstressed-baseline-still-reportable", "CREDIBLE-NULL", cv=["UNSTRESSED"],
         stress_requested=0,
         spin_rendezvous=0, spin_cap=0, cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 7. The tau_hot boundary bites exactly at tau_hot.
    # =======================================================================
    case("tau-boundary-just-below", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_target_count=29, canary_target_count=29),
    case("tau-boundary-exactly-at", "CREDIBLE-NULL",
         control_target_count=30, canary_target_count=0),

    # B6c: the canary's OWN tau boundary, on a canary-only (Allowed) harness -- the
    # 320 tests where the canary is the ONLY liveness evidence there is.
    case("allowed-canary-tau-just-below", "COLD-INVALID", dq=["CONTROLS_COLD"],
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         canary_target_count=29),
    case("allowed-canary-tau-exactly-at", "ALLOWED-UNOBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         canary_target_count=30),

    # =======================================================================
    # 8. Caveats travel with the number, but do not invalidate.
    # =======================================================================
    case("credible-but-pinning-is-fiction", "CREDIBLE-NULL", cv=["AFF_FAILED"],
         cpu_aff_failures=3),
    case("credible-but-placement-refused", "CREDIBLE-NULL", cv=["PLACE_REFUSED"],
         place_failures=1),
    case("credible-but-spin-is-a-delay-loop", "CREDIBLE-NULL", cv=["SPIN_CAP"],
         spin_rendezvous=100, spin_cap=900),

    # =======================================================================
    # 9. B6b: A MISMATCH MUST CARRY ITS STRESS PROVENANCE.
    # =======================================================================
    # The caveats used to be computed BELOW the MISMATCH return, so the single most
    # valuable outcome the campaign can produce -- an observed weak behaviour that
    # REFUTES the CMCM -- was reported with no record of the config it was seen
    # under.  Alglave (ASPLOS'15 4.3) requires the incantations to travel with the
    # sighting or it is not reproducible, and an unreproducible refutation is a much
    # weaker result than a reproducible one.
    case("mismatch-carries-its-caveats", "MISMATCH",
         cv=["AFF_FAILED", "PLACE_REFUSED", "SPIN_CAP"],
         target_count_exhaustive=1,
         cpu_aff_failures=3, place_failures=1,
         spin_rendezvous=100, spin_cap=900),
    case("mismatch-on-an-unstressed-run-says-so", "MISMATCH", cv=["UNSTRESSED"],
         target_count_exhaustive=1, stress_requested=0,
         spin_rendezvous=0, spin_cap=0, gpu_stress_rounds=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 10. B6b: THE CONTROL'S OWN exhaustive_valid MUST NOT GATE THE NULL.
    # =======================================================================
    # mu(SB-*-sys-fence-2s) IS SB-*-sys-acqrel-2s -- itself a T_L>=2 shape -- so at
    # production N its exhaustive scan does not run and control_exhaustive_valid is
    # 0.  Its count then comes from the WINDOWED scan, whose hits are a strict
    # subset of the exhaustive scan's under the same predicate: a windowed hit is a
    # genuine recovered cycle.  If the rule refused to trust it, the control would
    # be structurally cold on 2 of the 16 control harnesses and their nulls would be
    # COLD-INVALID forever -- a positive control that cannot fire is not a control.
    # T's OWN exhaustive_valid still gates the null; the control's does not.
    case("control-count-from-the-window-still-vouches", "CREDIBLE-NULL",
         control_exhaustive_valid=0, control_target_count=500),

    # =======================================================================
    # 11. B6c: CANARY_ONLY is a DIAGNOSTIC, not boilerplate.
    # =======================================================================
    # "Layer B fired, Layer A did not" is only meaningful where a Layer A EXISTS to
    # have not fired.  Raised on the 348 tests that have no mutant by construction, it
    # would fire on 95% of the corpus and tell a reader nothing.  It must NOT be set
    # on a canary-only harness.
    case("canary-only-caveat-is-not-raised-without-a-mutant", "ALLOWED-UNOBSERVED",
         het_oracle="ORACLE_ALLOWED", control_compiled_in=0, control_target_count=0,
         canary_target_count=500),

    # =======================================================================
    # 12. B6c: A WINDOWED ZERO IS NOT A MEASURED ZERO -- IN EVERY CLASS.
    # =======================================================================
    # On a T_L>=2 shape at production N the O(N^T_L) scan does not run, so the zero
    # comes from the WINDOWED search over [c-W, c+W] and HET_WINDOW is an uncalibrated
    # placeholder.  HET_CV_NO_EXHAUSTIVE was computed for all three classes but PRINTED
    # only on the Disallowed path -- so an ALLOWED-UNOBSERVED ("we could not expose it")
    # or a CHARACTERIZED rate would have been stated without disclosing that the effort
    # behind it was a window, not the full range.  Overstating the effort is a quieter
    # error than the false refutation, but it is the same kind.
    case("allowed-windowed-zero-must-say-so", "ALLOWED-UNOBSERVED",
         cv=["NO_EXHAUSTIVE"], het_oracle="ORACLE_ALLOWED",
         exhaustive_valid=0, control_compiled_in=0, control_target_count=0),
    case("no-oracle-windowed-zero-must-say-so", "CHARACTERIZED",
         cv=["NO_EXHAUSTIVE"], het_oracle="ORACLE_NONE",
         exhaustive_valid=0, control_compiled_in=0, control_target_count=0),
]

# Cases whose PRINTOUT must disclose that the count came from the window, not the
# ground-truth scan (Phase 2).  The cv flag being set is not the deliverable -- the
# sentence reaching the reader is.
MUST_PRINT_SCAN_CAVEAT = {"allowed-windowed-zero-must-say-so",
                          "no-oracle-windowed-zero-must-say-so"}
SCAN_CAVEAT_TEXT = "rests on the WINDOWED heuristic"

# DR1-A2/F2: a store-only COLD null must NAME the observer channel that failed, not
# print the generic "interleavings_detected==0" (meaningless for a shape with no
# reader).  Setting the dq bit is not the deliverable; the sentence reaching the
# reader is (the B6c lesson).
MUST_NAME_OBSERVER_CHANNEL = {"store-only-observer-cold-is-COLD"}
OBSERVER_CHANNEL_TEXT = "OBSERVER channel was COLD"

# Cases that must NOT carry CV_CANARY_ONLY (checked negatively -- see above).
NO_CANARY_ONLY_CV = {"canary-only-caveat-is-not-raised-without-a-mutant",
                     "allowed-unobserved-is-observability-not-model",
                     "no-oracle-unfired-hot-is-still-characterized"}

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
  printf("CASE|%s|%s|%s|0x%x|0x%x|%d|%s\n", name, want, got, dq, cv, ok,
         het_oracle_name(r.het_oracle));
  /* PHASE 2: capture what the harness would ACTUALLY PRINT.  The verdict enum
     changing is not the deliverable -- the SENTENCE changing is. */
  printf("PRINT-BEGIN|%s\n", name);
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
        # het_oracle is an ENUM: emit the symbol, not an int.  Spelling it as a
        # number here would let the gate keep passing if the enum were renumbered.
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
    subprocess.run(["litmus7", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
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
# PHASE 3 -- the emitted corpus really does carry its oracle class.
# ---------------------------------------------------------------------------
def read_control_map():
    """test -> oracle verdict (field 2), from the committed map."""
    want = {}
    with open(CONTROL_MAP) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = line.split(",")
            if len(f) < 8 or f[0] == "Test":
                continue
            want[f[0]] = f[1]
    return want


ORACLE_RE = re.compile(r"_rec\.het_oracle\s*=\s*(ORACLE_[A-Z]+)\s*;")


def check_corpus(quiet, tamper=None):
    """tamper: (test, src) -> src.  Used ONLY by --bite, to prove this phase FAILS
    when an emitted harness carries the wrong oracle class.  A census that has never
    been seen to reject anything is not a census."""
    print("\n===== PHASE 3: does the EMITTED CORPUS carry its oracle class? =====")
    want = read_control_map()
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    print("  het corpus  : %d .litmus" % len(tests))
    print("  control-map : %d rows" % len(want))

    tmp = tempfile.mkdtemp(prefix="verdictcorpus.")
    bad, got_census = 0, {}
    tampered = 0
    try:
        # One litmus7 invocation for the whole corpus (~20 ms each).
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
                if new != src:            # cmp: the injection must really have hit
                    tampered += 1
                src = new
            found = ORACLE_RE.findall(src)
            if len(found) != 1:
                print("  *** %-26s emits %d het_oracle assignments (want exactly 1)"
                      % (t, len(found)))
                bad += 1
                continue
            got = found[0]
            got_census[got] = got_census.get(got, 0) + 1
            exp = CSV_TO_C.get(want.get(t, "?"), "ORACLE_UNSET")
            if got != exp:
                print("  *** %-26s emits %s, control-map.csv says %s (%s)"
                      % (t, got, exp, want.get(t, "MISSING")))
                bad += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if tamper is not None and tampered == 0:
        # A bite that changed nothing "passes" for free.  That has happened here.
        print("  *** VACUOUS BITE: the corpus injection matched NOTHING")
        return 2

    print()
    for csv_name, n in sorted(CENSUS.items()):
        c = CSV_TO_C[csv_name]
        seen = got_census.get(c, 0)
        mark = "    " if seen == n else " ***"
        print("%s  %-18s %3d emitted  (expect %3d)" % (mark, c, seen, n))
        if seen != n:
            bad += 1
    unset = got_census.get("ORACLE_UNSET", 0)
    mark = "    " if unset == 0 else " ***"
    print("%s  %-18s %3d emitted  (expect   0 -- an untagged harness claims nothing)"
          % (mark, "ORACLE_UNSET", unset))
    if unset:
        bad += 1

    if bad:
        print("\nCORPUS FAILED: %d problem(s).  A rule that branches on an oracle "
              "class the emitter never sets is a rule nobody runs." % bad)
        return 1
    print("\nCORPUS OK (%d harnesses, every one tagged, census matches "
          "control-map.csv)" % len(tests))
    return 0


# ---------------------------------------------------------------------------
def scan_prints(blocks, cases_by_name, quiet):
    """PHASE 2 -- the refutation claims appear IFF the test is ORACLE_DISALLOWED."""
    print("\n===== PHASE 2: can a non-Disallowed test print a REFUTATION? =====")
    bad = 0
    leaked, asserted = [], []
    for name, (oracle, text) in sorted(blocks.items()):
        hits = [c for c in REFUTATION_CLAIMS if c in text]
        if oracle == "Disallowed":
            if hits:
                asserted.append((name, hits))
            continue
        if hits:
            leaked.append((name, oracle, hits))
            bad += 1

    for name, oracle, hits in leaked:
        print("  *** FALSE REFUTATION: %s (oracle=%s) printed %s"
              % (name, oracle, ", ".join(repr(h) for h in hits)))

    # BOTH WAYS.  A ban that passes because the text vanished entirely is not a
    # check -- it is the constant-false detector again, in the gate this time.
    if not asserted:
        print("  *** THE REFUTATION TEXT IS UNREACHABLE FROM EVERY CASE.  The ban "
              "above is passing for free: a Disallowed sighting must STILL print "
              "\"REFUTES the model's prediction\", or the campaign has lost its "
              "single most valuable output.")
        bad += 1
    elif not quiet:
        for name, hits in asserted:
            print("      %-46s prints the refutation (correctly): %s"
                  % (name, ", ".join(repr(h) for h in hits)))

    # The 41 NO-ORACLE rows must never make a MODEL claim in either direction.
    for name, (oracle, text) in sorted(blocks.items()):
        if oracle != "NO-ORACLE":
            continue
        if "CHARACTERIZATION, NEVER VALIDATION" not in text \
           and "DISCARD this null" not in text:
            print("  *** %s (NO-ORACLE) printed neither the characterization "
                  "disclaimer nor a DISCARD -- it is making a model claim" % name)
            bad += 1

    # A windowed zero must SAY it is a windowed zero, in every class.  Setting the cv
    # flag is not the deliverable; the sentence reaching the reader is.
    for name in sorted(MUST_PRINT_SCAN_CAVEAT):
        text = blocks.get(name, ("", ""))[1]
        if SCAN_CAVEAT_TEXT not in text:
            print("  *** %s did NOT disclose that its zero came from the WINDOW and "
                  "not from the ground-truth scan -- it overstates the effort behind "
                  "a non-observation" % name)
            bad += 1
        elif not quiet:
            print("      %-46s discloses its windowed zero (correctly)" % name)

    # DR1-A2/F2: a store-only COLD null must NAME the observer channel, not print the
    # generic interleaving disqualifier that is meaningless for a shape with no reader.
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
        print("\nPRINT FAILED: %d problem(s).  This is the B6c bug: 348 of the 386 "
              "harnesses are not should-be-forbidden tests, and a refutation printed "
              "on one of them is a false refutation of the compound model." % bad)
        return 1
    print("\nPRINT OK (the refutation claims are reachable ONLY from "
          "ORACLE_DISALLOWED, and they ARE reachable from it)")
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
    if cc.returncode != 0:
        print(cc.stdout + cc.stderr)
        print("\nVERDICT FAILED: the rule does not compile")
        return 1

    run = subprocess.run([exe], capture_output=True, text=True)
    lines = run.stdout.splitlines()

    tau = int(re.match(r"TAU_HOT=(\d+)", lines[0]).group(1))
    print("  tau_hot: %d\n" % tau)

    cases_by_name = {c["name"]: c for c in CASES}
    seen_v, seen_o, bad = set(), set(), 0
    blocks, cur, buf = {}, None, []

    for l in lines[1:]:
        if l.startswith("CASE|"):
            _, name, want, got, dq, cv, ok, oracle = l.split("|")
            seen_v.add(got)
            seen_o.add(oracle)
            blocks[name] = [oracle, ""]
            if ok != "1":
                bad += 1
                print("  *** %-46s want %-19s got %-19s (dq=%s cv=%s)"
                      % (name, want, got, dq, cv))
            elif not quiet:
                print("      %-46s %-19s dq=%-6s cv=%s" % (name, got, dq, cv))
        elif l.startswith("PRINT-BEGIN|"):
            cur, buf = l.split("|", 1)[1], []
        elif l.startswith("PRINT-END|"):
            blocks[cur][1] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(l)

    print()
    # THE not-constant assertions.  A rule that only ever returns one verdict is not
    # a decision, however plausible its source reads -- and a three-way oracle branch
    # keyed off a field that is always the same value is the same bug in a new place.
    missing_v = [v for v in VERDICTS if v not in seen_v]
    print("  verdicts reached      : %d/%d  (%s)"
          % (len(seen_v), len(VERDICTS), ", ".join(sorted(seen_v))))
    if missing_v:
        print("  *** UNREACHABLE VERDICT: %s -- the rule is not a decision, it is a "
              "constant on this input space" % ", ".join(missing_v))
        bad += 1

    want_o = {"Disallowed", "Allowed", "NO-ORACLE", "UNSET"}
    print("  oracle classes reached: %d/%d  (%s)"
          % (len(seen_o), len(want_o), ", ".join(sorted(seen_o))))
    missing_o = [o for o in want_o if o not in seen_o]
    if missing_o:
        print("  *** UNEXERCISED ORACLE CLASS: %s -- the oracle branch is untested "
              "and may be constant" % ", ".join(missing_o))
        bad += 1

    blocks = {k: (v[0], v[1]) for k, v in blocks.items()}
    if bad:
        print("\nVERDICT FAILED: %d case(s) wrong." % bad)
        return 1, blocks
    print("\nVERDICT OK (%d cases; all %d verdicts and all oracle classes reachable; "
          "exhaustive_valid==0 never credible; every disqualifier bites)"
          % (len(CASES), len(VERDICTS)))
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
        rc |= scan_prints(blocks, {c["name"]: c for c in CASES}, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= check_corpus(a.quiet)

    print("\n" + "=" * 70)
    if rc:
        print("VERDICTCHECK: FAIL")
    else:
        print("VERDICTCHECK: PASS  (rule + printout + emitted corpus)")
    return 1 if rc else 0


# ---------------------------------------------------------------------------
# --bite: THE GATE MUST BITE.
#
# A gate never seen to FAIL is not evidence.  Each injection below breaks exactly
# one thing this gate claims to guard; each is `cmp'-verified to have actually
# CHANGED the file (an injection that silently matched nothing "passes" for free --
# that has happened in this project); and each must drive the gate to a NONZERO exit.
# ---------------------------------------------------------------------------
def _bite_one(label, tmp, header, mutate, quiet):
    """mutate: str -> str.  Returns True if the gate correctly FAILED."""
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
    try:
        rc, blocks = run_rule(mut, sub, quiet=True)
        rc |= scan_prints(blocks, {c["name"]: c for c in CASES}, quiet=True)
    finally:
        shutil.rmtree(sub, ignore_errors=True)

    if rc:
        print("  BITES (gate failed, as it must)   [%s]" % label)
        return True
    print("  *** DID NOT BITE: the gate PASSED on a broken rule   [%s]" % label)
    return False


def bite():
    print("===== B6c BITE TEST: does this gate actually FAIL when the rule breaks? ====")
    tmp = tempfile.mkdtemp(prefix="verdictbite.")
    ok = True
    try:
        header = emit_header(tmp)

        # (1) THE ORACLE BRANCH MADE CONSTANT.  Force every record to be read as
        # Disallowed -- exactly the pre-B6c behaviour, and exactly what a memset'd
        # record would do if ORACLE_UNSET were not 0.  The Allowed and NO-ORACLE cases
        # must then take the forbidden frame and the gate must catch it.
        ok &= _bite_one(
            "het_oracle forced CONSTANT (every test read as Disallowed)",
            tmp, header,
            lambda s: s.replace("switch (r->het_oracle) {",
                                "switch (ORACLE_DISALLOWED) {"),
            quiet=True)

        # (2) THE REFUTATION TEXT LEAKED INTO THE ALLOWED FRAME.  The verdict enum is
        # still right; only the SENTENCE is wrong.  Phase 1 cannot see this -- it is
        # precisely why Phase 2 reads the printout.
        ok &= _bite_one(
            "the refutation SENTENCE leaked into the ALLOWED branch",
            tmp, header,
            lambda s: s.replace(
                '"  This is the EXPECTED result.  The oracle PERMITS this outcome',
                '"  ** A single sighting REFUTES the model\'s prediction for this test.\\n"\n'
                '      "  This is the EXPECTED result.  The oracle PERMITS this outcome'),
            quiet=True)

        # (3) ORACLE_UNSET NO LONGER FAILS CLOSED.  An untagged harness would silently
        # pick the forbidden frame again -- the B6c bug restored through the back door.
        ok &= _bite_one(
            "ORACLE_UNSET no longer fails closed (untagged => treated as Disallowed)",
            tmp, header,
            lambda s: s.replace("if (r->het_oracle == ORACLE_UNSET) {",
                                "if (0) {"),
            quiet=True)

        # (4) THE WINDOWED-ZERO DISCLOSURE IS DROPPED FROM THE NON-DISALLOWED PATHS.
        # The cv flag is still set and Phase 1 still passes -- only the SENTENCE is
        # gone, so "we could not expose it" would be printed with no hint that the
        # effort behind it was a window and not the full range.
        ok &= _bite_one(
            "the windowed-zero caveat dropped from the ALLOWED/NO-ORACLE printouts",
            tmp, header,
            lambda s: s.replace("  het_print_scan_caveat(_ch, _r, cv);\n", ""),
            quiet=True)

        # (5) THE EMITTER MIS-TAGS AN ALLOWED TEST AS DISALLOWED.  The rule is
        # perfect; the harness lies to it.  This is the drift Phase 3 exists to catch,
        # and it is invisible to Phases 1 and 2 (which never look at a real harness).
        print("\n-- corpus injections --")
        rc = check_corpus(quiet=True, tamper=lambda t, s: (
            s.replace("_rec.het_oracle = ORACLE_ALLOWED;",
                      "_rec.het_oracle = ORACLE_DISALLOWED;")
            if t == "S-cg-sys-fence" else s))
        if rc == 1:
            print("  BITES (gate failed, as it must)   "
                  "[an ALLOWED harness emitted as ORACLE_DISALLOWED]")
        else:
            print("  *** DID NOT BITE (rc=%d)   "
                  "[an ALLOWED harness emitted as ORACLE_DISALLOWED]" % rc)
            ok = False

        # (6) A HARNESS SHIPS UNTAGGED.  het_verdict() would fail closed -- but only
        # if it is ever RUN.  The census is what stops 1 of 386 quietly claiming
        # nothing while the other 337 look fine.
        rc = check_corpus(quiet=True, tamper=lambda t, s: (
            s.replace("_rec.het_oracle = ORACLE_NONE;",
                      "_rec.het_oracle = ORACLE_UNSET;")
            if t == "IRIW-cgcg-sys-fence-2s" else s))
        if rc == 1:
            print("  BITES (gate failed, as it must)   "
                  "[a harness shipped with ORACLE_UNSET]")
        else:
            print("  *** DID NOT BITE (rc=%d)   [a harness shipped with ORACLE_UNSET]"
                  % rc)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 70)
    if ok:
        print("BITE OK: all 6 injections were caught -- 4 against the RULE (het_verdict.h)")
        print("         and 2 against the EMITTED CORPUS.  The gate is live, both ways:")
        print("         it passes on the shipped code and fails on every way of breaking it.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


if __name__ == "__main__":
    sys.exit(main())
