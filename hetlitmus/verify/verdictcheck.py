#!/usr/bin/env python3
"""HetLitmus -- the decision-rule gate for het_verdict() (het_verdict.h).

het_verdict() turns a raw target count into one of three outcomes, and every one
of them is a shape a constant can impersonate.  So this gate compiles the REAL
emitted header -- not a copy, which would be free to drift -- feeds it synthetic
het_obs_records, and proves:

  1 the rule      it decides.  Every outcome and every liveness disqualifier is
                  reachable; an unstamped record fails closed.
  2 the printout  each outcome's sentences are reachable from THAT outcome and
                  from no other, checked both ways.  The enum changing is not
                  the deliverable; the sentence is.
  3 the corpus    every emitted harness stamps rec_magic exactly once.
  4 the pair      the printout names the pair the emitter stamped and no
                  other, and an unstamped harness prints the header's own
                  defaults.

The rule and its reporting frames: hetlitmus/docs/harness-reporting.md.

Usage:  verdictcheck.py [-q]
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

VERDICTS = ["OBSERVED", "NOT-OBSERVED", "COLD-INVALID"]

# The liveness disqualifiers and the caveats, read off the header's own #defines
# rather than listed here.  A list kept by hand grows only when someone remembers
# to grow it, and each case below carries its own expected dq/cv word, so a bit
# that no case sets is a branch nothing here drives and no per-case comparison can
# see.  A retired bit carries no #define, so the vacancies are not read.
FLAG_DEFINE_RE = re.compile(r"^#define (HET_(?:DQ|CV)_\w+)\s+\(1u << (\d+)\)", re.M)


def flag_bits(header):
    """{"DISQUALIFIER": {name: bit}, "CAVEAT": {...}} off the header."""
    out = {"DISQUALIFIER": {}, "CAVEAT": {}}
    with open(header) as fh:
        for name, bit in FLAG_DEFINE_RE.findall(fh.read()):
            out["DISQUALIFIER" if name.startswith("HET_DQ_")
                else "CAVEAT"][name] = int(bit)
    return out


# The census the emitted corpus MUST reproduce: one harness per corpus test.
CENSUS = {"tests": 471}

# ---------------------------------------------------------------------------
# Frame exclusivity.  Each outcome's own sentences, checked BOTH ways: reachable
# from that outcome (a ban that passes because the text vanished is not a check),
# and printed by no other.  The strings are spliced back together across the C
# string concatenations they are written in.
FRAME_CLAIMS = {
    "OBSERVED": ["the weak outcome was OBSERVED",
                 "Report it as what "],
    # A null's whole entitlement, in one frame: what was not seen, that no rate
    # and no probability rides on it, that nothing certifies the harness, and
    # that the result is about reach and not about a model.  A discarded run
    # gets none of these -- saying any of them on one would report a dead
    # harness as reach.
    "NOT-OBSERVED": [
        "NOT OBSERVED under this effort",
        "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
        "NOTHING VOUCHES FOR THE HARNESS THAT DID NOT SEE IT",
        "OBSERVABILITY result about this harness",
        "has precedent: Alglave et al., ASPLOS'15, fn.7, p.577",
    ],
    "COLD-INVALID": ["DISCARD this null"],
}
# Printed by every NON-sighting outcome, the cold one included: a discarded null
# still says what was not seen.
NON_SIGHTING_CLAIMS = ["the weak outcome was NOT observed"]

# ---------------------------------------------------------------------------
# A "live, stressed, reportable" baseline: a record every requested mechanism was
# measured alive in.  Every case below is this record with a few fields perturbed,
# so each isolates ONE reason.
BASE = dict(
    # The stamp, written as the SYMBOL so a rename in the header is a compile
    # error here too.  A zeroed record is what an emitter that skipped a field
    # produces, and it must never read as a live one.
    rec_magic="HET_REC_MAGIC",
    N=100000,
    # The readout: every iteration scored, none of them matching, and the
    # outcome vector varying across them -- the shape of a live null.
    iters_scored=100000,
    iters_discarded=0,
    target_count=0,
    outcomes_vary=1,
    # The rendezvous: it ran, it lost nothing, and its caps are a measurement --
    # so every case below isolates ONE reason there too.  The SHIPPED caps are
    # uncalibrated; a baseline that carried that would put the caveat on every
    # case and leave the sentence owned by nobody.
    rdv_valid=1,
    rdv_cap_cpu=0,
    rdv_cap_gpu=0,
    cap_cpu=262144,
    cap_gpu=4096,
    cap_calibrated=1,
    stress_truncated=0,
    gpu_stress_rounds=64,             # het_do_stress actually ran
    cpu_enemy_rounds=1000,
    cpu_preload_ops=1000,
    noise_cpu_rounds=1000,
    noise_gpu_blocks=8,
    cpu_aff_failures=0,
    place_failures=0,
    # every mechanism requested (GPU_STRESS|CPU_ENEMY|CPU_PRELOAD|NOISE_CPU|NOISE_GPU)
    stress_requested=0x3D,
)


def case(name, verdict, dq=(), cv=(), **kw):
    r = dict(BASE)
    r.update(kw)
    return dict(name=name, verdict=verdict, dq=list(dq), cv=list(cv), rec=r)


CASES = [
    # =======================================================================
    # 1. The null: nothing was seen, on a run whose every requested mechanism
    #    was measured alive.  It reports the effort and the liveness, and
    #    nothing certifies either.
    # =======================================================================
    case("live-null", "NOT-OBSERVED"),

    case("observed", "OBSERVED", target_count=1),

    # A sighting is believed even on a run we would otherwise DISCARD:
    # falsification is one-sided, so nothing has to vouch for a positive.
    case("observed-beats-every-disqualifier", "OBSERVED",
         target_count=1, stress_truncated=99,
         cpu_enemy_rounds=0, noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 2. MP-cg-sys-relaxed is the most observable het shape the corpus has, and
    #    het_verdict() reads no field naming the test, so BOTH of its readings
    #    are the ones every other row gets.  Pinned in both directions, because
    #    a reader who knows the shape could expect its null to be refused rather
    #    than reported.
    # =======================================================================
    case("MP-cg-sys-relaxed-firing-is-a-plain-sighting", "OBSERVED",
         test_name="MP-cg-sys-relaxed", target_count=412),

    case("MP-cg-sys-relaxed-null-is-a-plain-null", "NOT-OBSERVED",
         test_name="MP-cg-sys-relaxed"),

    # =======================================================================
    # 3. The readout that never varied.  Every scored iteration read back one
    #    outcome vector, which is the constant-read artefact -- caveated on both
    #    outcomes and suppressing neither, because falsification is one-sided.
    # =======================================================================
    case("one-outcome-null-caveated", "NOT-OBSERVED", cv=["ONE_OUTCOME"],
         outcomes_vary=0),
    case("one-outcome-sighting-caveated", "OBSERVED", cv=["ONE_OUTCOME"],
         target_count=1, outcomes_vary=0),
    # ... and a run that scored NOTHING is not a run whose outcome never varied:
    # the caveat is keyed on iters_scored > 0, so an empty readout stays silent
    # here and is caught where emptiness belongs -- at the rendezvous, which is
    # what an empty readout means.
    case("nothing-scored-raises-no-one-outcome-caveat", "COLD-INVALID",
         dq=["RDV_DEAD"], iters_scored=0, iters_discarded=100000,
         rdv_cap_cpu=100000, rdv_cap_gpu=100000, outcomes_vary=0),

    # =======================================================================
    # 4. An unstamped record fails closed.  het_obs_record is memset(0), so a
    #    zeroed rec_magic is what an emitter that skipped the stamp produces; the
    #    rule must claim NOTHING then, not even on a sighting, because every field
    #    it would read is a memset zero.
    # =======================================================================
    case("unstamped-record-fails-closed", "COLD-INVALID", dq=["REC_UNSTAMPED"],
         rec_magic=0),
    case("unstamped-record-fails-closed-even-on-a-sighting", "COLD-INVALID",
         dq=["REC_UNSTAMPED"], rec_magic=0, target_count=99),
    # ... and the test is EQUALITY, not "nonzero": a record carrying some other
    # stamp is a record written by something that is not this header.
    case("wrong-stamp-fails-closed", "COLD-INVALID", dq=["REC_UNSTAMPED"],
         rec_magic=0x48455432),

    # =======================================================================
    # 5. Every liveness disqualifier drives the outcome to COLD: a null from a run
    #    whose stress was inert is not the same datum as one from a stressed run
    #    (harness-reporting.md S3).
    # =======================================================================
    case("cold-stress-truncated", "COLD-INVALID", dq=["STRESS_TRUNCATED"],
         stress_truncated=1),
    case("cold-cpu-enemy-dead", "COLD-INVALID", dq=["CPU_ENEMY_DEAD"],
         cpu_enemy_rounds=0),
    case("cold-cpu-preload-dead", "COLD-INVALID", dq=["CPU_PRELOAD_DEAD"],
         cpu_preload_ops=0),
    case("cold-noise-cpu-dead", "COLD-INVALID", dq=["NOISE_CPU_DEAD"],
         noise_cpu_rounds=0),
    case("cold-noise-gpu-dead", "COLD-INVALID", dq=["NOISE_GPU_DEAD"],
         noise_gpu_blocks=0),

    # het_do_stress carries a runtime tally, so "requested and completed zero rounds"
    # is a check that can fail -- and must be: HET_TEST_BLOCKS is the one instance's
    # block count and stressing blocks fill only what the co-residency cap leaves
    # over.
    case("cold-gpu-stress-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         gpu_stress_rounds=0),

    # =======================================================================
    # 5b. The rendezvous, which no stress tally covers.  A run whose iterations
    #     mostly ended at the cap is a run whose two sides mostly did not meet:
    #     its empty histogram is about the rendezvous, not about the memory
    #     model, so it is DISCARDED rather than reported as reach.
    # =======================================================================
    case("rdv-dead-by-rate", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=40000, iters_discarded=60000,
         rdv_cap_cpu=60000, rdv_cap_gpu=1),
    case("rdv-dead-zero-scored", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=0, iters_discarded=100000,
         rdv_cap_cpu=100000, rdv_cap_gpu=100000),
    # The readout never ran, so the three counts above are memset zeros rather
    # than measurements -- the same fail-closed shape as the record stamp, one
    # level down.
    case("rdv-unstamped", "COLD-INVALID", dq=["RDV_DEAD"], rdv_valid=0),
    # ... and the budget is a THRESHOLD, not "any discard at all": a run that
    # spent exactly its budget is still a run.
    case("rdv-discards-within-budget-still-reportable", "NOT-OBSERVED",
         iters_scored=50000, iters_discarded=50000, rdv_cap_gpu=50000),

    # =======================================================================
    # 5c. The caps those discards were priced against.  The shipped pair are
    #     placeholders, so a run under them says so on every outcome: a shorter
    #     cap discards iterations the two sides would have shared, a longer one
    #     spends the run waiting for a partner that is not coming.
    # =======================================================================
    case("uncalibrated-cap-caveat", "NOT-OBSERVED", cv=["RDV_UNCALIBRATED"],
         cap_calibrated=0),

    # =======================================================================
    # 6. A mechanism that was not requested must NOT disqualify.  A deliberately
    #    unstressed baseline has every stress counter at zero, so disqualifying on
    #    "counter == 0" alone would make every no-stress config COLD forever.  It
    #    stays reportable and carries the unstressed caveat instead
    #    (harness-reporting.md S3: requested-but-dead, not merely zero).
    # =======================================================================
    case("unstressed-baseline-still-reportable", "NOT-OBSERVED",
         cv=["UNSTRESSED"], stress_requested=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 8. Caveats travel with the number, but do not invalidate.
    # =======================================================================
    case("null-but-pinning-is-fiction", "NOT-OBSERVED", cv=["AFF_FAILED"],
         cpu_aff_failures=3),
    case("null-but-placement-refused", "NOT-OBSERVED",
         cv=["PLACE_REFUSED"], place_failures=1),

    # =======================================================================
    # 9. A sighting must carry the stress it was seen under.  Test parameters have
    #    a large impact on how often an outcome appears, and the observed frequency
    #    is sensitive to the machine and its operating system besides
    #    [Alglave11 sec 4], so a result reported without its configuration is not
    #    reproducible.
    # =======================================================================
    case("sighting-carries-its-caveats", "OBSERVED",
         cv=["AFF_FAILED", "PLACE_REFUSED"],
         target_count=1, cpu_aff_failures=3, place_failures=1),
    case("sighting-on-an-unstressed-run-says-so", "OBSERVED", cv=["UNSTRESSED"],
         target_count=1, stress_requested=0, gpu_stress_rounds=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # =======================================================================
    # 12. The CPU-only cycle.  The emitter sets cpu_only when every proc carries
    #     the `cpu' tag, and both outcome frames then say what was under test: no
    #     cross-device path carried the cycle, so what a sighting shows is the host
    #     ISA on the shared allocation and what a null probes is that allocation's
    #     memory type.  The set carrying it comes from
    #     hetlitmus/tests/het/generate-cpuonly.sh.
    # =======================================================================
    case("cpu-only-sighting-names-what-fired", "OBSERVED",
         cpu_only=1, target_count=3),
    case("cpu-only-null-probes-the-allocation", "NOT-OBSERVED", cpu_only=1),
]

# Cases whose PRINTOUT must disclose that every scored iteration read back one
# outcome vector, and the ones that must not (phase 2, both ways).
MUST_PRINT_ONE_OUTCOME = {"one-outcome-null-caveated",
                          "one-outcome-sighting-caveated"}
ONE_OUTCOME_TEXT = "read back the SAME outcome vector"

# A sentence a FLAG owns: printed by exactly the cases whose expected flag word
# carries it, and by no other.  The owner set is read off CASES rather than kept
# by hand, so a case that acquires the flag without the sentence is caught here
# instead of needing a second list to be remembered.
FLAG_SENTENCES = [
    ("dq", "RDV_DEAD", "A timed-out rendezvous is a DEAD PARTNER",
     "a run whose two sides did not meet, reported as reach"),
    # The same sentence's second half: rdv_cap_cpu/rdv_cap_gpu are per-participant
    # cap expiries, so a reader who takes them for the two halves of
    # iters_discarded reads a number that can exceed it.
    ("dq", "RDV_DEAD", "counted per participant per iteration",
     "two tallies that neither partition nor bound the discards, printed as if "
     "they did"),
    ("cv", "RDV_UNCALIBRATED", "the rendezvous caps are PLACEHOLDERS",
     "a discard count priced against a wait nobody measured"),
]


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
# banner's tag and the field on the machine-readable HetObs record.
CPU_ONLY_BANNER = " CPU-ONLY"
CPU_ONLY_FIELD = "cpu_only=%d"

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
  printf("MAX_CELLS=%d\n", (int)HET_STATS_MAX_CELLS);
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
    # The test name is a field like any other, and a case may set it: nothing in
    # the rule reads it, and a case that names a real corpus row pins that.
    r = dict(r)
    name = r.pop("test_name", "synthetic")
    return ("(het_obs_record){ .test_name=\"%s\", " % name
            + ", ".join(".%s=%s" % (k, val(k, v)) for k, v in sorted(r.items()))
            + " }")


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
# PHASE 4 -- which pair the printout names.
#
# The pair a printout names comes from a define the emitter stamps, with the
# header's own defaults where nothing is stamped.  Three properties, all read off
# the printout rather than off the defines (the enum changing is not the
# deliverable, the sentence is): with no defines the frame is the unstamped one;
# with the (AArch64, cuda) defines every sentence names that pair and its
# dialect's placement lever; with the (x86_64, hip) defines that pair and no
# lever.  The defines are scraped from real emissions, never typed here, so the
# phase tests what the emitter stamps.
# ---------------------------------------------------------------------------
PAIR_DEFINE_RE = re.compile(
    r"^#define HET_(?:PLACE_LEVER|PAIR_NAME)\b.*$", re.M)

# (label, corpus dir, test, -gpu-target, render extension)
PAIR_EMISSIONS = [
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
    "CAVEAT: the page-placement lever was REFUSED -- HET_PLACE placed nothing.",
    # The sentence that has to NAME the target.  Each frame asserts its own name,
    # so a constant fails here.
    "Report it as what (unstamped CPU ISA x GPU dialect pair) exhibited under "
    "this harness, this stress and this host-device interconnect path.",
    # ... and the null frame's own, which is the other half of the same pin: a
    # frame that names the pair on a sighting and nowhere else leaves every null
    # unattributed.
    "liveness (unstamped CPU ISA x GPU dialect pair) measured on its own counters.",
]
CUDA_PAIR_MUST = [
    "- the host half of the host-device interconnect noise did NOT run",
    "- the device half of the host-device interconnect noise did NOT run",
    "CAVEAT: cudaMemAdvise was REFUSED -- HET_PLACE placed nothing.",
    "Report it as what (AArch64, cuda) exhibited under this harness, this stress "
    "and this host-device interconnect path.",
    "liveness (AArch64, cuda) measured on its own counters.",
]
HIP_PAIR_MUST = [
    "Report it as what (X86_64, hip) exhibited under this harness, this stress "
    "and this host-device interconnect path.",
    "- the host half of the host-device interconnect noise did NOT run",
    "- the device half of the host-device interconnect noise did NOT run",
    # No placement lever on this render, so the mechanism is named instead.
    "CAVEAT: the page-placement lever was REFUSED -- HET_PLACE placed nothing.",
    "liveness (X86_64, hip) measured on its own counters.",
]
# The lever is a DIALECT fact, so it is forbidden in the HIP frame beside the
# CUDA pair's own name.
CUDA_PAIR_WORDS = ["(AArch64, cuda)", "cudaMemAdvise"]
HIP_PAIR_WORDS = ["(X86_64, hip)"]
# Forbidden in EVERY frame: a constant standing in for the pair the binary was
# built for.  There is no stamp for which it is right.
BLOB_WORDS = ["the target this harness was tagged for"]

PAIR_FRAMES = [
    ("no defines (an unstamped harness)", None,
     GENERIC_MUST, CUDA_PAIR_WORDS + HIP_PAIR_WORDS + BLOB_WORDS),
    ("(AArch64, cuda)", "(AArch64, cuda)", CUDA_PAIR_MUST,
     HIP_PAIR_WORDS + BLOB_WORDS),
    ("(x86_64, hip)", "(x86_64, hip)", HIP_PAIR_MUST,
     CUDA_PAIR_WORDS + BLOB_WORDS),
]


def scrape_pair_defines(tmp, label, corpus, test, target, ext):
    """The HET_* build defines the emitter really stamps for one pair."""
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
        return PAIR_DEFINE_RE.findall(fh.read())


def printout_with(header, tmp, defines, tag):
    """Compile the rule with [defines] prepended; return its whole printout."""
    sub = tempfile.mkdtemp(prefix="verdictpair.", dir=tmp)
    shutil.copy(header, os.path.join(sub, "het_verdict.h"))
    pre = os.path.join(sub, "stamped.h")
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


def check_pair_prose(header, tmp, quiet):
    print("\n===== PHASE 4: which PAIR does the printout name? =====")
    defines_by_pair = {}
    for label, corpus, test, target, ext in PAIR_EMISSIONS:
        defines_by_pair[label] = \
            scrape_pair_defines(tmp, label, corpus, test, target, ext)
    for label, defs in sorted(defines_by_pair.items()):
        print("  %-16s stamps %d build define(s)" % (label, len(defs)))
        if not quiet:
            for d in defs:
                print("      %s" % d)

    bad = 0
    for label, pair, must, forbid in PAIR_FRAMES:
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
                print("  *** %-46s printed %r -- a pair this harness was not "
                      "built for, or a word only that pair's frame may use"
                      % (label, banned))
                bad += 1

    if bad:
        print("\nPAIR PROSE FAILED: %d problem(s).  A run that names the wrong "
              "pair reports a measurement of a build that never ran." % bad)
        return 1
    print("\nPAIR PROSE OK (the header's own defaults without stamps; each pair's "
          "own name with them; no frame names another's)")
    return 0


# ---------------------------------------------------------------------------
# PHASE 3 -- the emitted corpus stamps its record.
# ---------------------------------------------------------------------------
MAGIC_RE = re.compile(r"_rec\.rec_magic\s*=\s*HET_REC_MAGIC\s*;")


def emit_corpus(tests):
    """{test: .cu source, or None if the harness did not appear}, from ONE litmus7
    invocation over the whole corpus; the scratch dir is dropped as soon as it has
    been read.  None on an emitter failure, already reported."""
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
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_corpus():
    print("\n===== PHASE 3: does the EMITTED CORPUS stamp its record? =====")
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    print("  het corpus  : %d .litmus" % len(tests))

    bad = 0
    sources = emit_corpus(tests)
    if sources is None:
        return 1
    for t in tests:
        src = sources.get(t)
        if src is None:
            print("  *** %-26s no .cu emitted" % t)
            bad += 1
            continue
        # (a) The stamp, exactly once and by its symbol.  het_verdict() reads no
        # field of an unstamped record, so a harness that lost this line reports
        # a build bug for every run it will ever make.
        n_magic = len(MAGIC_RE.findall(src))
        if n_magic != 1:
            print("  *** %-26s stamps rec_magic %d time(s) (want exactly 1)"
                  % (t, n_magic))
            bad += 1

    print()
    for label, seen, expect in (("harnesses", len(tests), CENSUS["tests"]),):
        mark = "    " if seen == expect else " ***"
        print("%s  %-16s %3d  (expect %3d)" % (mark, label, seen, expect))
        if seen != expect:
            bad += 1

    if bad:
        print("\nCORPUS FAILED: %d problem(s).  A rule that fails closed on an "
              "unstamped record only helps if the emitter stamps." % bad)
        return 1
    print("\nCORPUS OK (%d harnesses, every one stamped once)" % len(tests))
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
             {"NOT-OBSERVED", "COLD-INVALID"},
             "every non-sighting outcome"),):
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

    # A readout that never varied must SAY so, on both outcomes -- and no case
    # whose readout did vary may say it.
    for name in sorted(blocks):
        text = blocks[name][1]
        owns = name in MUST_PRINT_ONE_OUTCOME
        if owns and ONE_OUTCOME_TEXT not in text:
            print("  *** %s scored only ONE distinct outcome vector and never said "
                  "so -- a constant readout reported as a measurement" % name)
            bad += 1
        if not owns and ONE_OUTCOME_TEXT in text:
            print("  *** %s printed the one-outcome caveat, but its readout varied"
                  % name)
            bad += 1
    if not quiet:
        print("      %-46s disclose their one-outcome readout, and only they do"
              % ("%d case(s)" % len(MUST_PRINT_ONE_OUTCOME)))

    # The flag-owned sentences, both ways: exactly the cases whose flag word
    # carries the bit print it.
    for key, flag, text, why in FLAG_SENTENCES:
        owners = set(c["name"] for c in CASES if flag in c[key])
        if not owners:
            print("  *** no case expects HET_%s_%s, so its sentence is checked "
                  "against nothing" % (key.upper(), flag))
            bad += 1
        for name in sorted(blocks):
            has = text in blocks[name][1]
            if name in owners and not has:
                print("  *** %s carries HET_%s_%s and never printed %r -- %s"
                      % (name, key.upper(), flag, text, why))
                bad += 1
            if name not in owners and has:
                print("  *** %s printed %r, which belongs to HET_%s_%s"
                      % (name, text, key.upper(), flag))
                bad += 1
        if not quiet and owners:
            print("      %-46s print %r, and only they do"
                  % ("%d case(s)" % len(owners), text))

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
    # files the whole row under, and the HetObs field is the same flag on the
    # machine-readable per-run record.
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
    # Every exit from here returns the (rc, blocks) pair its caller unpacks: a
    # bare int turns a non-compiling header into a TypeError traceback in place of
    # the diagnostic.
    if cc.returncode != 0:
        print(cc.stdout + cc.stderr)
        print("\nVERDICT FAILED: the rule does not compile")
        return 1, {}

    run = subprocess.run([exe], capture_output=True, text=True)
    lines = run.stdout.splitlines()

    # The driver prints MAX_CELLS before the first case, so a missing first line
    # means the binary died before it ran anything.  That is reported, NEVER
    # indexed into: an empty list here raises in place of the diagnostic.
    m = re.match(r"MAX_CELLS=(\d+)", lines[0]) if lines else None
    if m is None:
        print(run.stdout + run.stderr)
        print("\nVERDICT FAILED: the compiled rule produced no MAX_CELLS line "
              "(exit %d, %d line(s) of stdout) -- it did not reach the first case"
              % (run.returncode, len(lines)))
        return 1, {}
    print("  max_cells: %d\n" % int(m.group(1)))

    seen_v, seen_dq, seen_cv, bad = set(), 0, 0, 0
    blocks, cur, buf = {}, None, []

    for l in lines[1:]:
        if l.startswith("CASE|"):
            _, name, want, got, dq, cv, ok = l.split("|")
            seen_v.add(got)
            seen_dq |= int(dq, 16)
            seen_cv |= int(cv, 16)
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

    # ... and the same assertion on the two flag words, whose bits the header
    # declares and the cases have to reach.  Read off the header, so a bit added
    # there arrives with no case setting it and is named here.
    defs = flag_bits(header)
    for kind, word in (("DISQUALIFIER", seen_dq), ("CAVEAT", seen_cv)):
        names = defs[kind]
        if not names:
            print("  *** the header declares no %s bit at all -- this coverage "
                  "assertion read NOTHING" % kind)
            bad += 1
            continue
        missing = sorted(n for n, b in names.items() if not (word >> b) & 1)
        print("  %-22s: %d/%d" % (kind.lower() + "s reached",
                                  len(names) - len(missing), len(names)))
        if missing:
            print("  *** UNREACHED %s: %s -- a bit no case sets is a branch this "
                  "gate never drives" % (kind, ", ".join(missing)))
            bad += 1

    blocks = {k: (v[0], v[1]) for k, v in blocks.items()}
    if bad:
        print("\nVERDICT FAILED: %d case(s) wrong." % bad)
        return 1, blocks
    print("\nVERDICT OK (%d cases; all %d outcomes reachable; an unstamped record "
          "fails closed; every disqualifier and caveat the header declares is "
          "reached)" % (len(CASES), len(VERDICTS)))
    return 0, blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    print("===== PHASE 1: is het_verdict() actually a decision? =====")
    tmp = tempfile.mkdtemp(prefix="verdictcheck.")
    try:
        header = emit_header(tmp)
        rc, blocks = run_rule(header, tmp, a.quiet)
        rc |= scan_prints(blocks, a.quiet)
        rc |= check_pair_prose(header, tmp, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rc |= check_corpus()

    print("\n" + "=" * 70)
    if rc:
        print("VERDICTCHECK: FAIL")
    else:
        print("VERDICTCHECK: PASS  (rule + printout + pair prose + emitted corpus)")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
