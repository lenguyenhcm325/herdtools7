#!/usr/bin/env python3
"""HetLitmus -- the decision-rule gate for het_verdict() (het_verdict.h).

Compiles the REAL emitted header with synthetic het_obs_records and pins:
  1 the rule      every outcome and every dq/cv bit the header declares is
                  reached, each case's word EXACTLY, a memset-zeroed record
                  fails closed -- a miss means the rule stopped deciding.
  2 the printout  each outcome's sentences print from that outcome and from no
                  other, and each frame names the pair the emitter stamped -- a
                  miss means a sentence reports what nothing measured.
Rule and frames: hetlitmus/docs/harness-reporting.md.  Usage: [-q]
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
X86_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het-x86")

VERDICTS = ["OBSERVED", "NOT-OBSERVED", "COLD-INVALID"]

# The dq/cv bits are read off the header's own #defines rather than listed here, so
# a bit added there arrives with no case setting it.  A retired bit carries none.
FLAG_DEFINE_RE = re.compile(r"^#define (HET_(?:DQ|CV)_\w+)\s+\(1u << (\d+)\)", re.M)
# The build defines the emitter stamps for one (CPU ISA x GPU dialect) pair.
PAIR_DEFINE_RE = re.compile(r"^#define HET_(?:PLACE_LEVER|PAIR_NAME)\b.*$", re.M)


def flag_bits(header):
    """{"DISQUALIFIER": {name: bit}, "CAVEAT": {...}} off the header."""
    out = {"DISQUALIFIER": {}, "CAVEAT": {}}
    with open(header) as fh:
        for name, bit in FLAG_DEFINE_RE.findall(fh.read()):
            out["DISQUALIFIER" if name.startswith("HET_DQ_")
                else "CAVEAT"][name] = int(bit)
    return out


# The frames the printout is read in, as (tag, HET_PAIR_NAME, HET_PLACE_LEVER):
# the header's own defaults with nothing stamped, then a real cuda emission's.
DEFAULT_FRAME = ("no defines (an unstamped harness)",
                 "(unstamped CPU ISA x GPU dialect pair)",
                 "the page-placement lever")
CUDA_FRAME = ("the scraped (AArch64, cuda) defines", "(AArch64, cuda)",
              "cudaMemAdvise")
HIP_FRAME = ("the scraped (X86_64, hip) defines", "(X86_64, hip)",
             "the page-placement lever")
FRAMES = [DEFAULT_FRAME, CUDA_FRAME, HIP_FRAME]

# ---------------------------------------------------------------------------
# Frame exclusivity: each outcome's own sentences, checked BOTH ways -- reachable
# from that outcome, and printed by no other.  {pair} is filled from the frame.
FRAME_CLAIMS = {
    "OBSERVED": ["the weak outcome was OBSERVED",
                 "Report it as what {pair} exhibited under this harness and this "
                 "stress."],
    # A null's frame: what was not seen, and whose reach it was.
    "NOT-OBSERVED": [
        "NOT OBSERVED under this effort on {pair}; the counts above are this "
        "run's reach.",
    ],
    "COLD-INVALID": ["DISCARD this null"],
}
# Printed by every NON-sighting outcome, the cold one included: a discarded null
# still says what was not seen.
NON_SIGHTING_CLAIMS = ["the weak outcome was NOT observed"]

# ---------------------------------------------------------------------------
# A "live, stressed, reportable" baseline: every case below is this record with a
# few fields perturbed, so each isolates ONE reason.
BASE = dict(
    N=100000,
    # The readout: every iteration scored, none of them matching, and the
    # outcome vector varying across them -- the shape of a live null.
    iters_scored=100000,
    iters_discarded=0,
    target_count=0,
    outcomes_vary=1,
    # The rendezvous ran, lost nothing, and its caps are a measurement: the
    # SHIPPED caps are placeholders, which would caveat every case at once.
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
    # A GPU test lane exists, so the structural-absence caveat is owned by the one
    # case that drops it: unset, it would fire on every record.
    gpu_lanes=1,
    # every mechanism requested (GPU_STRESS|CPU_ENEMY|CPU_PRELOAD|NOISE_CPU|NOISE_GPU)
    stress_requested=0x3D,
)


def case(name, verdict, dq=(), cv=(), **kw):
    r = dict(BASE)
    r.update(kw)
    return dict(name=name, verdict=verdict, dq=list(dq), cv=list(cv), rec=r)


CASES = [
    case("live-null", "NOT-OBSERVED"),

    case("observed", "OBSERVED", target_count=1),

    # A sighting is believed even on a run we would otherwise DISCARD:
    # falsification is one-sided, so nothing has to vouch for a positive.
    case("observed-beats-every-disqualifier", "OBSERVED",
         target_count=1, stress_truncated=99,
         cpu_enemy_rounds=0, noise_cpu_rounds=0, noise_gpu_blocks=0),

    # The constant-read artefact, caveated on both outcomes and suppressing
    # neither, because falsification is one-sided.
    case("one-outcome-null-caveated", "NOT-OBSERVED", cv=["ONE_OUTCOME"],
         outcomes_vary=0),
    case("one-outcome-sighting-caveated", "OBSERVED", cv=["ONE_OUTCOME"],
         target_count=1, outcomes_vary=0),
    # ... and a run that scored NOTHING is not a run whose outcome never varied:
    # the caveat is keyed on iters_scored > 0, so an empty readout stays silent.
    case("nothing-scored-raises-no-one-outcome-caveat", "COLD-INVALID",
         dq=["RDV_DEAD"], iters_scored=0, iters_discarded=100000,
         rdv_cap_cpu=100000, rdv_cap_gpu=100000, outcomes_vary=0),

    # Memset residue is NEVER read as a run that looked and saw nothing: the
    # liveness step reads rdv_valid and iters_scored, both zero here.
    case("zeroed-record-fails-closed", "COLD-INVALID", dq=["RDV_DEAD"],
         cv=["RDV_UNCALIBRATED", "UNSTRESSED", "NO_GPU_LANES"],
         **{k: 0 for k in BASE}),

    # Every liveness disqualifier drives the outcome to COLD: a null from a run
    # whose stress was inert is not a stressed run's null.
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
    # The stress blocks fill what the co-residency cap leaves over the test lanes,
    # so a requested layer that completed zero rounds is a layer nobody ran.
    case("cold-gpu-stress-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         gpu_stress_rounds=0),

    # The rendezvous, which no stress tally covers, on each of its three
    # disjuncts: the budget, an empty readout, and a readout that never ran.
    case("rdv-dead-by-rate", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=40000, iters_discarded=60000,
         rdv_cap_cpu=60000, rdv_cap_gpu=1),
    # Nothing scored and nothing discarded either: the budget disjunct cannot
    # fire here, so this case is the only reader of the zero-scored one.
    case("rdv-dead-zero-scored", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=0, iters_discarded=0),
    # The readout never ran, so the three counts above are memset zeros rather
    # than measurements.
    case("rdv-readout-never-ran", "COLD-INVALID", dq=["RDV_DEAD"], rdv_valid=0),
    # ... and the budget is a THRESHOLD, not "any discard at all": a run that
    # spent exactly its budget is still a run.
    case("rdv-discards-within-budget-still-reportable", "NOT-OBSERVED",
         iters_scored=50000, iters_discarded=50000, rdv_cap_gpu=50000),

    # The shipped caps are placeholders, so a run under them says so on every
    # outcome: the discards it counts price a wait nobody measured.
    case("uncalibrated-cap-caveat", "NOT-OBSERVED", cv=["RDV_UNCALIBRATED"],
         cap_calibrated=0),

    # A mechanism that was not requested must NOT disqualify, or every no-stress
    # baseline is COLD forever (harness-reporting.md sec 3).
    case("unstressed-baseline-still-reportable", "NOT-OBSERVED",
         cv=["UNSTRESSED"], stress_requested=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # A build with no GPU test lane: the emitter withholds the GPU-stress request
    # there, so the zero tally disqualifies nothing and the run says so instead.
    case("no-gpu-lane-caveat", "NOT-OBSERVED", cv=["NO_GPU_LANES"],
         gpu_lanes=0, gpu_stress_rounds=0, stress_requested=0x3C),

    # Caveats travel with the number, but do not invalidate.
    case("null-but-pinning-is-fiction", "NOT-OBSERVED", cv=["AFF_FAILED"],
         cpu_aff_failures=3),
    case("null-but-placement-refused", "NOT-OBSERVED",
         cv=["PLACE_REFUSED"], place_failures=1),

    # A sighting carries the stress it was seen under: the observed frequency is
    # sensitive to the machine and its parameters [Alglave11 sec 4].
    case("sighting-carries-its-caveats", "OBSERVED",
         cv=["AFF_FAILED", "PLACE_REFUSED"],
         target_count=1, cpu_aff_failures=3, place_failures=1),
    case("sighting-on-an-unstressed-run-says-so", "OBSERVED", cv=["UNSTRESSED"],
         target_count=1, stress_requested=0, gpu_stress_rounds=0,
         cpu_enemy_rounds=0, cpu_preload_ops=0,
         noise_cpu_rounds=0, noise_gpu_blocks=0),

    # The CPU-only cycle, which no cross-device path carried: a sighting names the
    # host ISA on the shared allocation and a null probes that allocation.
    case("cpu-only-sighting-names-what-fired", "OBSERVED",
         cpu_only=1, target_count=3),
    case("cpu-only-null-probes-the-allocation", "NOT-OBSERVED", cpu_only=1),
]

# A sentence a FLAG owns, printed by exactly the cases whose expected flag word
# carries it: the owner set is read off CASES rather than kept by hand.
FLAG_SENTENCES = [
    ("dq", "RDV_DEAD", "A timed-out rendezvous is a DEAD PARTNER",
     "a run whose two sides did not meet, reported as reach"),
    # rdv_cap_cpu/rdv_cap_gpu are per-participant cap expiries, so a reader who
    # takes them for the two halves of iters_discarded reads a number over it.
    ("dq", "RDV_DEAD", "counted per participant per iteration",
     "two tallies that neither partition nor bound the discards"),
    ("cv", "RDV_UNCALIBRATED", "the rendezvous caps are PLACEHOLDERS",
     "a discard count priced against a wait nobody measured"),
    ("cv", "ONE_OUTCOME", "read back the SAME outcome vector",
     "a constant readout reported as a measurement"),
    ("cv", "NO_GPU_LANES",
     "A mechanism with 0 lanes is STRUCTURALLY ABSENT, not dead",
     "a stress layer no build could run, read as a dead one"),
    # The lever is a DIALECT fact, so the sentence is filled from the frame.
    ("cv", "PLACE_REFUSED", "{lever} was REFUSED -- HET_PLACE placed nothing.",
     "a placement lever this build does not drive"),
]

# The CPU-only sentences, owner case -> the fragment only that case may print:
# both ways, so a flag read as a constant is caught whichever way it froze.
CPU_ONLY_TEXT = {
    "cpu-only-sighting-names-what-fired":
        "CPU-ONLY CYCLE: every proc of this test is a CPU proc",
    "cpu-only-null-probes-the-allocation":
        "SHARED-ALLOCATION PROBE: this is a CPU-only shape",
}

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
  /* EQUALITY on both words: a subset test passes a caveat that fires on every
     record, which is a bit driven by nothing. */
  int ok = (strcmp(got, want) == 0) && dq == want_dq && cv == want_cv;
  printf("CASE|%s|%s|%s|0x%x|0x%x|%d\n", name, want, got, dq, cv, ok);
  /* What the harness would ACTUALLY PRINT, in the order the emitted driver
     writes it: the machine-readable record, then the human block. */
  printf("PRINT-BEGIN|%s\n", name);
  het_obs_record_print(stdout, &r);
  het_verdict_print(stdout, &r);
  printf("PRINT-END|%s\n", name);
  if (!ok) failures++;
}

int main(void) {
__CASES__
  printf("FAILURES=%d\n", failures);
  return failures ? 1 : 0;
}
"""


def c_record(r):
    # The rule reads no field naming the test, so the name is a constant here.
    r = dict(r)
    r.pop("test_name", None)
    return ("(het_obs_record){ .test_name=\"synthetic\", "
            + ", ".join(".%s=%s" % (k, v) for k, v in sorted(r.items()))
            + " }")


def build_c():
    body = []
    for c in CASES:
        dq = " | ".join("HET_DQ_" + d for d in c["dq"]) or "0u"
        cv = " | ".join("HET_CV_" + d for d in c["cv"]) or "0u"
        body.append('  run_case("%s", %s, "%s", %s, %s);'
                    % (c["name"], c_record(c["rec"]), c["verdict"], dq, cv))
    return C_MAIN.replace("__CASES__", "\n".join(body))


def _env():
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    return env


def _emit_pair(tmp, sub, target, src_dir, test, ext):
    """(harness dir, the pair defines its render stamps) for one -gpu-target."""
    out = os.path.join(tmp, sub)
    os.makedirs(out, exist_ok=True)
    subprocess.run(["litmus7", "-gpu-target", target,
                    "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, os.path.join(src_dir, test + ".litmus")],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = os.path.join(out, test)
    render = os.path.join(d, test + ext)
    if not os.path.exists(render):
        raise SystemExit("verdictcheck: litmus7 emitted no harness for " + test)
    with open(render) as fh:
        defines = PAIR_DEFINE_RE.findall(fh.read())
    # A render that stamps nothing would make its frame a copy of the unstamped one.
    if not defines:
        raise SystemExit("verdictcheck: the %s render stamps no pair define" % target)
    return d, defines


def emit(tmp):
    """The REAL het_verdict.h litmus7 writes into a harness, and the pair defines
    each dialect stamps -- all from live emissions, never typed here."""
    d, cuda = _emit_pair(tmp, "emit", "cuda", HET_DIR, "MP-cg-sys-fence-2s", ".cu")
    h = os.path.join(d, "het_verdict.h")
    if not os.path.exists(h):
        raise SystemExit("verdictcheck: the cuda harness carries no het_verdict.h")
    _, hip = _emit_pair(tmp, "emit-hip", "hip", X86_DIR,
                        "MP-cg-sys-relaxed-x86_64", ".hip")
    return h, cuda, hip


def compile_and_run(header, tmp, defines, tag):
    """Compile the case set against the real header, `defines' prepended for a
    stamped frame; (stdout, "") or (None, diagnostic)."""
    sub = tempfile.mkdtemp(prefix="frame.", dir=tmp)
    shutil.copy(header, os.path.join(sub, "het_verdict.h"))
    cmd = ["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function"]
    if defines:
        pre = os.path.join(sub, "stamped.h")
        with open(pre, "w") as fh:
            fh.write("/* scraped from %s */\n" % tag)
            fh.write("\n".join(defines) + "\n")
        cmd += ["-include", pre]
    src = os.path.join(sub, "vt.c")
    with open(src, "w") as fh:
        fh.write(build_c())
    exe = os.path.join(sub, "vt")
    cc = subprocess.run(cmd + ["-I", sub, src, "-o", exe, "-lm"],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        return None, cc.stdout + cc.stderr
    run = subprocess.run([exe], capture_output=True, text=True)
    return run.stdout, ""


def parse_blocks(text):
    """{case name: (verdict, printout)} off the driver's stdout."""
    blocks, cur, buf = {}, None, []
    for l in text.splitlines():
        if l.startswith("CASE|"):
            f = l.split("|")
            blocks[f[1]] = [f[3], ""]
        elif l.startswith("PRINT-BEGIN|"):
            cur, buf = l.split("|", 1)[1], []
        elif l.startswith("PRINT-END|"):
            blocks[cur][1] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(l)
    return {k: (v[0], v[1]) for k, v in blocks.items()}


def run_rule(header, text, quiet):
    """PHASE 1 -- the per-case verdict and flag words, and their coverage."""
    lines = text.splitlines()
    # A driver that died before the first case is reported, NEVER indexed into.
    if not lines:
        print("\nVERDICT FAILED: the compiled rule printed nothing -- it did not "
              "reach the first case")
        return 1

    seen_v, seen_dq, seen_cv, bad = set(), 0, 0, 0
    for l in lines:
        if not l.startswith("CASE|"):
            continue
        _, name, want, got, dq, cv, ok = l.split("|")
        seen_v.add(got)
        seen_dq |= int(dq, 16)
        seen_cv |= int(cv, 16)
        if ok != "1":
            bad += 1
            print("  *** %-46s want %-24s got %-24s (dq=%s cv=%s)"
                  % (name, want, got, dq, cv))
        elif not quiet:
            print("      %-46s %-24s dq=%-6s cv=%s" % (name, got, dq, cv))

    print()
    # Coverage is ASSERTED, not merely reported: an outcome no case reaches is an
    # outcome the rule may never return, and the per-case checks cannot see it.
    print("  outcomes reached      : %d/%d  (%s)"
          % (len(seen_v), len(VERDICTS), ", ".join(sorted(seen_v))))
    missing_v = [v for v in VERDICTS if v not in seen_v]
    if missing_v:
        print("  *** UNREACHABLE OUTCOME: %s" % ", ".join(missing_v))
        bad += 1

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

    if bad:
        print("\nVERDICT FAILED: %d case(s) wrong." % bad)
        return 1
    print("\nVERDICT OK (%d cases; all %d outcomes reachable; a memset-zeroed "
          "record fails closed; every disqualifier and caveat the header declares "
          "is reached)" % (len(CASES), len(VERDICTS)))
    return 0


def scan_prints(blocks, frame, quiet):
    """PHASE 2 -- each outcome's sentences and the pair they name, both ways."""
    tag, pair, lever = frame

    def fill(s):
        return s.replace("{pair}", pair).replace("{lever}", lever)

    print("\n===== PHASE 2 (%s): does each outcome print ITS OWN sentences, and "
          "only those? =====" % tag)
    bad = 0

    # (a) Frame exclusivity, both ways.  A ban that passes because the sentence
    # vanished is not a check, so each claim must ALSO be reachable.
    for verdict, claims in sorted(FRAME_CLAIMS.items()):
        for claim in (fill(c) for c in claims):
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

    # (c) The flag-owned sentences, both ways: exactly the cases whose flag word
    # carries the bit print it.
    for key, flag, text, why in FLAG_SENTENCES:
        text = fill(text)
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

    # (d) The CPU-only sentences, both ways: the owner prints its own and nobody
    # else prints either.
    for owner, text in sorted(CPU_ONLY_TEXT.items()):
        if text not in blocks.get(owner, ("", ""))[1]:
            print("  *** %s carries cpu_only=1 but never printed %r -- a CPU-only "
                  "cycle that does not say so reads as a het one" % (owner, text))
            bad += 1
        for name in sorted(n for n in blocks if n != owner):
            if text in blocks[name][1]:
                print("  *** %s printed %r, which belongs to a CPU-only cycle"
                      % (name, text))
                bad += 1
        if not quiet:
            print("      %-46s prints its CPU-only sentence, and only it does" % owner)

    # (e) Every OTHER frame's pair name is forbidden here: a printout naming a pair
    # this binary was not built for reports a build that never ran.
    for _, other, _ in FRAMES:
        if other == pair:
            continue
        for name in sorted(blocks):
            if other in blocks[name][1]:
                print("  *** %s names %r, and this harness was built for %r"
                      % (name, other, pair))
                bad += 1
    if not quiet:
        print("      %-46s names %s and no other pair"
              % ("%d case(s)" % len(blocks), pair))

    if bad:
        print("\nPRINT FAILED: %d problem(s).  The enum changing is not the "
              "deliverable; the sentence is." % bad)
        return 1
    print("\nPRINT OK (every outcome prints its own sentences and no other's)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    print("===== PHASE 1: is het_verdict() actually a decision? =====")
    tmp = tempfile.mkdtemp(prefix="verdictcheck.")
    try:
        header, defines, hip_defines = emit(tmp)
        print("  header : %s" % header)
        print("  stamped: %s" % ", ".join(defines + hip_defines))
        rc = 0
        for frame, defs in ((DEFAULT_FRAME, []), (CUDA_FRAME, defines),
                            (HIP_FRAME, hip_defines)):
            text, err = compile_and_run(header, tmp, defs, frame[0])
            if text is None:
                print("  *** %s did not compile:\n%s" % (frame[0], err[-800:]))
                rc = 1
                continue
            # The rule is one function of one record, so it is driven once; the
            # defines move the printout and nothing else.
            if frame is DEFAULT_FRAME:
                rc |= run_rule(header, text, a.quiet)
            rc |= scan_prints(parse_blocks(text), frame, a.quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 70)
    if rc:
        print("VERDICTCHECK: FAIL")
    else:
        print("VERDICTCHECK: PASS  (rule + printout, unstamped and stamped)")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
