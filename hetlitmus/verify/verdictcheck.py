#!/usr/bin/env python3
"""HetLitmus B6 -- the decision-rule gate.

het_verdict() (het_verdict.h) is what converts `target_count = 0' from an
uninterpretable empty histogram into a credible non-observation.  It is THE
deliverable of B6, and it has exactly the shape of a mechanism that can compile,
pass every structural gate, and do nothing:

  * a rule that always returns COLD discards every null forever;
  * a rule that always returns CREDIBLE-NULL reports every cold run as
    confirmation of the memory model -- the same silent falsification as the
    constant-false `_weak' detector B3 shipped on 266 of 338 tests.

Structural gates cannot see either.  So this gate COMPILES THE REAL HEADER (the
one litmus7 emits into every harness -- not a copy, which would be free to
drift), feeds it synthetic het_obs_records, and asserts:

  1. all FOUR branches are reachable          => the rule is provably not constant
  2. exhaustive_valid == 0  =>  NEVER CREDIBLE (Item E.1: a count that was not
     measured is not a measured zero, and reading it as one manufactures a false
     "Never")
  3. every disqualifying liveness field  =>  COLD  (B4/B5: a null from a run
     whose stress was inert is not the same datum as one from a stressed run)
  4. a mechanism that was NOT requested and did no work does NOT disqualify
     (otherwise an intentional no-stress baseline is COLD forever -- which is
     just another way of building a rule that always says the same thing)
  5. the tau_hot boundary actually bites at tau_hot, not near it.

Usage:  verdictcheck.py [--header PATH] [-q]
        (with no --header it emits a harness with litmus7 and uses that one)
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

VERDICTS = ["MISMATCH", "CREDIBLE-NULL", "WEAK-NULL", "COLD-INVALID"]

# ---------------------------------------------------------------------------
# A "live, hot, credible" baseline.  Every case below is this record with a few
# fields perturbed, so each test isolates ONE reason.
BASE = dict(
    exhaustive_valid=1,
    target_count_exhaustive=0,
    target_count_heuristic=0,
    interleavings_detected=1000,
    control_compiled_in=1,
    control_target_count=30,          # == HET_TAU_HOT
    canary_target_count=500,
    stress_truncated=0,
    spin_rendezvous=900, spin_cap=100,
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    cpu_aff_failures=0,
    place_failures=0,
    # every mechanism requested (GPU_STRESS|SPIN|CPU_ENEMY|CPU_PRELOAD|NOISE_CPU|NOISE_GPU)
    stress_requested=0x3F,
)

# NOTE there is no "gpu-stress-dead" case below, and that is not an omission:
# het_do_stress has NO runtime tally (het_stress.cuh counts RDV/CAP/TRUNC/NOISE/
# NOISE_ROUNDS and nothing else), so the record cannot say whether the scratchpad
# loop executed -- only stresscheck.py can say it survived into the PTX.  A case
# asserting a disqualifier we cannot actually evaluate would be a gate that passes
# for free.  Closing it needs a device-side counter (B4/B8).


def case(name, verdict, dq=(), cv=(), **kw):
    r = dict(BASE)
    r.update(kw)
    return dict(name=name, verdict=verdict, dq=list(dq), cv=list(cv), rec=r)


CASES = [
    # ---- 1. the four branches are all reachable ---------------------------
    case("credible-null", "CREDIBLE-NULL"),

    case("mismatch-exhaustive", "MISMATCH", target_count_exhaustive=1),

    # A sighting refutes even on a run we would otherwise DISCARD: an inert-stress
    # run that nevertheless SAW the forbidden outcome still saw it.  No control is
    # needed to believe a positive (falsification is one-sided).
    case("mismatch-beats-every-disqualifier", "MISMATCH",
         target_count_exhaustive=1, control_compiled_in=0,
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
         control_compiled_in=0, control_target_count=0, canary_target_count=0),

    # ---- 2. exhaustive_valid == 0  =>  NEVER credible ---------------------
    # The harness is hot (mu(T) fired 500x) and everything is live -- but the
    # ground-truth scan did not run, so the zero is NOT a measured zero.
    case("no-exhaustive-cannot-be-credible", "WEAK-NULL", cv=["NO_EXHAUSTIVE"],
         exhaustive_valid=0, control_target_count=500),

    # ---- 3. every disqualifier drives the verdict to COLD ------------------
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

    # ---- 4. NOT-requested mechanisms must NOT disqualify -------------------
    # THE ANTI-CONSTANT-COLD CASE.  A deliberately unstressed baseline run has
    # every stress counter at zero.  If "counter == 0" alone disqualified, this
    # run -- and every run of a no-stress config -- would be COLD forever, and the
    # rule would be constant in practice while looking perfectly reasonable in
    # source.  It must stay reportable, and carry the Kirkham caveat instead.
    case("unstressed-baseline-still-reportable", "CREDIBLE-NULL", cv=["UNSTRESSED"],
         stress_requested=0,
         spin_rendezvous=0, spin_cap=0, cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # ---- 5. the tau_hot boundary bites exactly at tau_hot ------------------
    case("tau-boundary-just-below", "COLD-INVALID", dq=["CONTROLS_COLD"],
         control_target_count=29, canary_target_count=29),
    case("tau-boundary-exactly-at", "CREDIBLE-NULL",
         control_target_count=30, canary_target_count=0),

    # ---- 6. caveats travel with the number, but do not invalidate ----------
    case("credible-but-pinning-is-fiction", "CREDIBLE-NULL", cv=["AFF_FAILED"],
         cpu_aff_failures=3),
    case("credible-but-placement-refused", "CREDIBLE-NULL", cv=["PLACE_REFUSED"],
         place_failures=1),
    case("credible-but-spin-is-a-delay-loop", "CREDIBLE-NULL", cv=["SPIN_CAP"],
         spin_rendezvous=100, spin_cap=900),
]

C_MAIN = r"""
/* GENERATED by hetlitmus/verify/verdictcheck.py -- do not edit. */
#include "het_verdict.h"
#include <string.h>

static int failures = 0;

static void run_case(const char *name, het_obs_record r,
                     const char *want, uint32_t want_dq, uint32_t want_cv) {
  uint32_t dq = 0, cv = 0;
  het_verdict_t v = het_verdict(&r, &dq, &cv);
  const char *got = het_verdict_name(v);
  int ok = (strcmp(got, want) == 0)
        && ((dq & want_dq) == want_dq)
        && ((cv & want_cv) == want_cv);
  printf("%s|%s|%s|0x%x|0x%x|%d\n", name, want, got, dq, cv, ok);
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
    return "(het_obs_record){ .test_name=\"synthetic\", " + ", ".join(
        ".%s=%d" % (k, v) for k, v in sorted(r.items())) + " }"


def build_c():
    body = []
    for c in CASES:
        dq = " | ".join("HET_DQ_" + d for d in c["dq"]) or "0u"
        cv = " | ".join("HET_CV_" + d for d in c["cv"]) or "0u"
        body.append('  run_case("%s", %s, "%s", %s, %s);'
                    % (c["name"], c_record(c["rec"]), c["verdict"], dq, cv))
    return C_MAIN.replace("__CASES__", "\n".join(body))


def emit_header(tmp):
    """Get the REAL het_verdict.h -- the one litmus7 writes into every harness."""
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    test = os.path.join(ROOT, "hetlitmus", "tests", "het",
                        "MP-cg-sys-fence-2s.litmus")
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    subprocess.run(["litmus7", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, test],
                   cwd=ROOT, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h = os.path.join(out, "MP-cg-sys-fence-2s", "het_verdict.h")
    if not os.path.exists(h):
        raise SystemExit("verdictcheck: litmus7 did not emit het_verdict.h")
    return h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", default=None)
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    print("===== B6 DECISION RULE: is het_verdict() actually a decision? =====")
    tmp = tempfile.mkdtemp(prefix="verdictcheck.")
    try:
        header = a.header or emit_header(tmp)
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
        lines = run.stdout.strip().splitlines()

        tau = int(re.match(r"TAU_HOT=(\d+)", lines[0]).group(1))
        print("  tau_hot: %d\n" % tau)

        seen, bad = set(), 0
        for l in lines[1:-1]:
            name, want, got, dq, cv, ok = l.split("|")
            seen.add(got)
            if ok != "1":
                bad += 1
                print("  *** %-38s want %-13s got %-13s (dq=%s cv=%s)"
                      % (name, want, got, dq, cv))
            elif not a.quiet:
                print("      %-38s %-13s dq=%-6s cv=%s" % (name, got, dq, cv))

        print()
        # THE not-constant assertion.  A rule that only ever returns one verdict
        # is not a decision, however plausible its source reads.
        missing = [v for v in VERDICTS if v not in seen]
        print("  branches reached: %d/4  (%s)" % (len(seen), ", ".join(sorted(seen))))
        if missing:
            print("  *** UNREACHABLE: %s -- the rule is not a decision, it is a "
                  "constant on this input space" % ", ".join(missing))
            bad += 1

        if bad:
            print("\nVERDICT FAILED: %d case(s) wrong.  A rule that cannot reach "
                  "all four verdicts, or that lets a null through on a cold run, "
                  "is the exact failure this task exists to prevent." % bad)
            return 1
        print("\nVERDICT OK (%d cases, all four branches reachable, "
              "exhaustive_valid==0 never credible, every disqualifier bites)"
              % len(CASES))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
