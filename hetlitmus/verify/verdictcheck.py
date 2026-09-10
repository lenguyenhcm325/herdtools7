#!/usr/bin/env python3
"""het_verdict.h, the real emitted header, compiled with synthetic records:
  1 the rule       het_verdict(): each case's outcome and dq/cv words EXACTLY;
                   every outcome and every flag the header declares is reached
  2 the printout   each sentence prints from exactly the cases that own it, and
                   the frame names the pair the emitter stamped
  3 the aggregate  het_stats_compute() per record stream, a Never's effort
                   clause, and the HetStats keys campaign.py reads
A miss means the rule stopped deciding, or a sentence reports what nothing
measured (hetlitmus/docs/00-environment-design.md "Reporting", "Aggregate").
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census
import ptxcheck as ptx

CAMPAIGN = os.path.join(ptx.REPO, "hetlitmus", "campaign.py")
VERDICTS = ("OBSERVED", "NOT-OBSERVED", "COLD-INVALID")
# Every flag the header declares, whatever its bit expression: the compiled
# driver prints each one's value.
FLAG_RE = re.compile(r"^#define (HET_(?:DQ|CV)_\w+)", re.M)
PAIR_RE = re.compile(r'^#define HET_PAIR_NAME "(.*)"$', re.M)

# A live, stressed, reportable null; every case perturbs a few fields of it.
BASE = dict(
    N=100000, iters_scored=100000, iters_discarded=0, target_count=0,
    outcomes_vary=1, rdv_valid=1, rdv_cap_cpu=0, rdv_cap_gpu=0,
    cap_cpu=262144, cap_gpu=4096, cap_calibrated=1, stress_truncated=0,
    gpu_stress_rounds=64, cpu_stress_rounds=1000, cpu_preload_ops=1000,
    cpu_noise_rounds=1000, gpu_noise_blocks=8, cpu_aff_failures=0,
    stress_requested=0x3D,          # every HET_REQ_* mechanism
)
DEAD = dict(gpu_stress_rounds=0, cpu_stress_rounds=0, cpu_preload_ops=0,
            cpu_noise_rounds=0, gpu_noise_blocks=0)


def case(name, verdict, dq=(), cv=(), **kw):
    return dict(name=name, verdict=verdict, dq=set(dq), cv=set(cv),
                rec=dict(BASE, **kw))


CASES = [
    case("live-null", "NOT-OBSERVED"),
    case("observed", "OBSERVED", target_count=1),
    # A sighting is believed under every disqualifier, and carries every caveat.
    case("observed-beats-every-disqualifier", "OBSERVED", target_count=1,
         stress_truncated=99, rdv_valid=0, **DEAD),
    case("observed-with-every-caveat", "OBSERVED",
         cv=["ONE_OUTCOME", "RDV_UNCALIBRATED", "AFF_FAILED", "UNSTRESSED"],
         target_count=1, outcomes_vary=0, cap_calibrated=0, cpu_aff_failures=3,
         stress_requested=0),
    case("one-outcome", "NOT-OBSERVED", cv=["ONE_OUTCOME"], outcomes_vary=0),
    case("uncalibrated-caps", "NOT-OBSERVED", cv=["RDV_UNCALIBRATED"],
         cap_calibrated=0),
    case("pin-refused", "NOT-OBSERVED", cv=["AFF_FAILED"], cpu_aff_failures=3),
    # Not requested is not dead, or every no-stress baseline is COLD.
    case("unstressed-baseline", "NOT-OBSERVED", cv=["UNSTRESSED"],
         stress_requested=0, **DEAD),
    # Memset residue fails closed.
    case("zeroed-record", "COLD-INVALID", dq=["RDV_DEAD"],
         cv=["RDV_UNCALIBRATED", "UNSTRESSED"], **{k: 0 for k in BASE}),
    case("cold-stress-truncated", "COLD-INVALID", dq=["STRESS_TRUNCATED"],
         stress_truncated=1),
    case("cold-gpu-stress-dead", "COLD-INVALID", dq=["GPU_STRESS_DEAD"],
         gpu_stress_rounds=0),
    case("cold-cpu-stress-dead", "COLD-INVALID", dq=["CPU_STRESS_DEAD"],
         cpu_stress_rounds=0),
    case("cold-cpu-preload-dead", "COLD-INVALID", dq=["CPU_PRELOAD_DEAD"],
         cpu_preload_ops=0),
    case("cold-cpu-noise-dead", "COLD-INVALID", dq=["CPU_NOISE_DEAD"],
         cpu_noise_rounds=0),
    case("cold-gpu-noise-dead", "COLD-INVALID", dq=["GPU_NOISE_DEAD"],
         gpu_noise_blocks=0),
    # The rendezvous disjuncts: the budget, nothing scored (which raises no
    # one-outcome caveat), a readout that never ran; the budget is a threshold.
    case("rdv-dead-by-rate", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=40000, iters_discarded=60000,
         rdv_cap_cpu=60000, rdv_cap_gpu=1),
    case("rdv-dead-zero-scored", "COLD-INVALID", dq=["RDV_DEAD"],
         iters_scored=0, iters_discarded=0, outcomes_vary=0),
    case("rdv-readout-never-ran", "COLD-INVALID", dq=["RDV_DEAD"], rdv_valid=0),
    case("rdv-discards-within-budget", "NOT-OBSERVED",
         iters_scored=50000, iters_discarded=50000, rdv_cap_gpu=50000),
]

# (owner, sentence): the cases of those outcomes, or the cases whose expected
# flag word carries that bit, print the sentence and no other case does.
SENTENCES = [
    ("OBSERVED", "the weak outcome was OBSERVED on {pair}"),
    ("NOT-OBSERVED,COLD-INVALID", "the weak outcome was NOT observed"),
    ("NOT-OBSERVED", "NOT OBSERVED under this effort on {pair}; the counts above "
                     "are this run's reach."),
    ("COLD-INVALID", "DISCARD this null"),
    ("dq:RDV_DEAD", "A timed-out rendezvous is a DEAD PARTNER"),
    ("dq:STRESS_TRUNCATED", "stress STOPPED while tested lanes were still running"),
    ("dq:CPU_STRESS_DEAD",
     "the CPU stress threads were requested but completed ZERO rounds"),
    ("dq:CPU_PRELOAD_DEAD", "the cache preload was requested but issued ZERO hints"),
    ("dq:CPU_NOISE_DEAD", "the host half of the host-device interconnect noise"),
    ("dq:GPU_NOISE_DEAD", "the device half of the host-device interconnect noise"),
    ("dq:GPU_STRESS_DEAD", "the GPU scratchpad stress"),
    ("cv:RDV_UNCALIBRATED", "the rendezvous caps are PLACEHOLDERS"),
    ("cv:ONE_OUTCOME", "read back the SAME outcome vector"),
    ("cv:AFF_FAILED", "sched_setaffinity call(s) FAILED"),
    ("cv:UNSTRESSED",
     "no stress was requested; an unstressed null is weak evidence"),
]


def owns(owner, c):
    key, _, flag = owner.partition(":")
    return flag in c[key] if flag else c["verdict"] in owner.split(",")


# The aggregate's record streams, one record per run, each with its statistics
# written out as (obs, k, k_eff, n_degen, R, R_usable, scored, discarded).
RUNS = 10
N = BASE["N"]
STREAM_FIELDS = ("obs", "k", "k_eff", "n_degen", "R", "R_usable", "scored",
                 "discarded")


def stream(n=RUNS, **kw):
    return [dict(BASE, run_id=i, **kw) for i in range(n)]


def observed(recs, k, clean=True):
    """The first k runs see the target; not clean: in a constant readout."""
    for r in recs[:k]:
        r["target_count"] = 1
        if not clean:
            r["outcomes_vary"] = 0
    return recs


def cold(recs, start=0):
    """Runs from `start' on are COLD: their stress stopped mid-run."""
    for r in recs[start:]:
        r["stress_truncated"] = 1
    return recs


_dead_readout = observed(stream(), 1)
_dead_readout[0]["rdv_valid"] = 0
_none_scored = observed(stream(), 1)
_none_scored[0]["iters_scored"] = 0

STREAMS = [
    ("never-over-ten-live-runs", stream(),
     ("Never", 0, 0, 0, RUNS, RUNS, RUNS * N, 0)),
    ("sometimes-3-of-10-runs", observed(stream(), 3),
     ("Sometimes", 3, 3, 0, RUNS, RUNS, RUNS * N, 0)),
    ("always", observed(stream(), RUNS),
     ("Always", RUNS, RUNS, 0, RUNS, RUNS, RUNS * N, 0)),
    # Not one usable run is no reading at all, which is NOT a Never.
    ("void-when-every-run-is-cold", cold(stream()),
     ("VOID", 0, 0, 0, RUNS, 0, RUNS * N, 0)),
    # The decode guard's three disjuncts: reported in k, counted nowhere in k_eff.
    ("degenerate-sightings-reported-not-counted",
     observed(stream(), 3, clean=False),
     ("Sometimes", 3, 0, 3, RUNS, RUNS, RUNS * N, 0)),
    ("sighting-from-a-readout-that-never-ran", _dead_readout,
     ("Sometimes", 1, 0, 1, RUNS, RUNS, RUNS * N, 0)),
    ("sighting-from-a-run-that-scored-nothing", _none_scored,
     ("Sometimes", 1, 0, 1, RUNS, RUNS, (RUNS - 1) * N, 0)),
    # The runs that fired are usable BECAUSE they fired; the denominator is R.
    ("fired-3-of-10-cold-is-sometimes", observed(cold(stream()), 3),
     ("Sometimes", 3, 3, 0, RUNS, 3, RUNS * N, 0)),
    ("never-over-three-live-runs-of-ten", cold(stream(), 3),
     ("Never", 0, 0, 0, RUNS, 3, RUNS * N, 0)),
    ("never-with-part-of-every-run-discarded",
     stream(iters_scored=60000, iters_discarded=40000),
     ("Never", 0, 0, 0, RUNS, RUNS, RUNS * 60000, RUNS * 40000)),
]

# The HetStats line is campaign.py's whole interface: a key it reads that the
# line never prints reads back 0.
CONSUMER_KEY_RE = re.compile(r'\bfnum\(\s*kv\s*,\s*"(\w+)"')
LINE_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
STATS_LINE = re.compile(r"HetStats \S+ obs=\S+ ")

C_MAIN = r"""
#include "het_verdict.h"
#include <string.h>

static void run_case(const char *name, het_obs_record r,
                     const char *want, uint32_t want_dq, uint32_t want_cv) {
  uint32_t dq = 0, cv = 0;
  const char *got = het_verdict_name(het_verdict(&r, &dq, &cv));
  int ok = strcmp(got, want) == 0 && dq == want_dq && cv == want_cv;
  printf("CASE|%s|%s|%s|0x%x|0x%x|%d\n", name, want, got, dq, cv, ok);
  printf("PRINT-BEGIN|%s\n", name);
  het_verdict_print(stdout, &r);
  printf("PRINT-END|%s\n", name);
}

static void run_stream(const char *name, const het_obs_record *recs, int n) {
  het_stats_t st;
  het_stats_compute(recs, n, &st);
  printf("STREAM|%s|%s|%d|%d|%d|%d|%d|%llu|%llu\n", name,
         het_obs_class_name(st.obs), st.k, st.k_eff, st.n_degen, st.R,
         st.R_usable, (unsigned long long)st.iters_scored,
         (unsigned long long)st.iters_discarded);
  printf("PRINT-BEGIN|%s\n", name);
  het_stats_print(stdout, &st);
  printf("PRINT-END|%s\n", name);
}

int main(void) {
__BODY__
  return 0;
}
"""


def c_fields(r):
    return ".test_name=\"synthetic\", " + ", ".join(
        ".%s=%s" % (k, v) for k, v in sorted(r.items()))


def build_c(pair, flags):
    body = ['  printf("FLAG|%s|0x%%x\\n", %s);' % (f, f) for f in flags]
    for c in CASES:
        dq = " | ".join("HET_DQ_" + d for d in sorted(c["dq"])) or "0u"
        cv = " | ".join("HET_CV_" + d for d in sorted(c["cv"])) or "0u"
        body.append('  run_case("%s", (het_obs_record){ %s }, "%s", %s, %s);'
                    % (c["name"], c_fields(c["rec"]), c["verdict"], dq, cv))
    for i, (name, recs, _want) in enumerate(STREAMS):
        body.append('  { het_obs_record s%d[%d] = { %s };\n'
                    '    run_stream("%s", s%d, %d); }'
                    % (i, len(recs), ", ".join("{ %s }" % c_fields(r) for r in recs),
                       name, i, len(recs)))
    return ('#define HET_PAIR_NAME "%s"\n' % pair
            + C_MAIN.replace("__BODY__", "\n".join(body)))


def compile_and_run(d, pair, flags):
    """The driver's stdout, compiled in the harness dir against its header."""
    src, exe = os.path.join(d, "vt.c"), os.path.join(d, "vt")
    with open(src, "w") as fh:
        fh.write(build_c(pair, flags))
    cc = ptx.run(["gcc", "-std=c99", "-O2", "-Wall", "-Wno-unused-function",
                  "-I", d, src, "-o", exe])
    if cc.returncode != 0:
        raise RuntimeError("the driver did not compile:\n" + cc.stdout[-800:])
    return ptx.run([exe]).stdout


def parse(text):
    """({flag: value}, {case: (want, got, dq, cv, ok)}, {stream: statistics},
    {case or stream: printout}) off the driver's stdout."""
    flags, cases, streams, prints, cur = {}, {}, {}, {}, None
    for l in text.splitlines():
        f = l.split("|")
        if f[0] == "FLAG":
            flags[f[1]] = int(f[2], 16)
        elif f[0] == "CASE":
            cases[f[1]] = (f[2], f[3], int(f[4], 16), int(f[5], 16), f[6] == "1")
        elif f[0] == "STREAM":
            streams[f[1]] = (f[2],) + tuple(int(x) for x in f[3:])
        elif f[0] == "PRINT-BEGIN":
            cur, prints[f[1]] = f[1], []
        elif f[0] == "PRINT-END":
            cur = None
        elif cur is not None:
            prints[cur].append(l)
    return flags, cases, streams, {k: "\n".join(v) for k, v in prints.items()}


def check_rule(cases, flags):
    """PHASE 1: the per-case words, and every outcome and flag reached."""
    bad = ["%s produced no CASE line" % c["name"]
           for c in CASES if c["name"] not in cases]
    bad += ["%s: want %s, got %s dq=0x%x cv=0x%x" % (n, want, got, dq, cv)
            for n, (want, got, dq, cv, ok) in cases.items() if not ok]
    seen = {"DQ": 0, "CV": 0, "V": set()}
    for _want, got, dq, cv, _ok in cases.values():
        seen["DQ"] |= dq
        seen["CV"] |= cv
        seen["V"].add(got)
    bad += ["no case reaches %s" % v for v in VERDICTS if v not in seen["V"]]
    if not flags:
        bad.append("the header declares no HET_DQ_/HET_CV_ flag: nothing was read")
    bad += ["no case sets %s" % f for f, v in flags.items()
            if not v or seen[f.split("_")[1]] & v != v]
    print("rule: %d cases, %d outcomes, %d flags"
          % (len(cases), len(seen["V"]), len(flags)))
    return bad


def check_prints(prints, pair):
    """PHASE 2: each sentence from exactly the cases that own it."""
    bad = []
    for owner, text in SENTENCES:
        text = text.replace("{pair}", pair)
        want = {c["name"] for c in CASES if owns(owner, c)}
        got = {n for n in prints if text in prints[n]}
        if not want:
            bad.append("no case owns %r" % text)
        bad += ["%s never printed %r" % (n, text) for n in sorted(want - got)]
        bad += ["%s printed %r, which is %s's" % (n, text, owner)
                for n in sorted(got - want)]
    print("printout: %d sentences on %s" % (len(SENTENCES), pair))
    return bad


def check_aggregate(streams, prints):
    """PHASE 3: the statistics as written out, a Never's effort clause, and
    the keys campaign.py reads."""
    bad = []
    for name, _recs, want in STREAMS:
        if name not in streams:
            bad.append("%s produced no STREAM line" % name)
            continue
        bad += ["%s: %s is %s, want %s" % (name, f, g, w)
                for f, g, w in zip(STREAM_FIELDS, streams[name], want) if g != w]
        if want[0] == "Never":
            bad += ["%s: the printout lacks %r" % (name, frag) for frag in
                    ("effort: %d run(s)" % want[4], "%d scored" % want[6],
                     "%d discarded" % want[7]) if frag not in prints.get(name, "")]
    with open(CAMPAIGN) as fh:
        keys = sorted(set(CONSUMER_KEY_RE.findall(fh.read())))
    line = next((l for n in sorted(streams) for l in prints.get(n, "").splitlines()
                 if STATS_LINE.match(l)), "")
    printed = LINE_KEY_RE.findall(line.split("HetStats ", 1)[-1])
    if not keys or not line or [k for k in keys if k not in printed]:
        bad.append("campaign.py reads %s; the HetStats line prints %s"
                   % (keys, printed))
    print("aggregate: %d streams; campaign.py reads %d of the line's %d keys"
          % (len(streams), len(keys), len(printed)))
    return bad


def main():
    tmp = tempfile.mkdtemp(prefix="verdictcheck.")
    try:
        cu, _ = ptx.emit_harness(
            os.path.join(census.HET_DIR, "MP-cg-sys-sy.fsc.litmus"), tmp)
        d = os.path.dirname(cu)
        with open(cu) as fh:
            m = PAIR_RE.search(fh.read())
        if not m:
            raise RuntimeError("the render stamps no HET_PAIR_NAME")
        with open(os.path.join(d, "het_verdict.h")) as fh:
            names = FLAG_RE.findall(fh.read())
        flags, cases, streams, prints = parse(compile_and_run(d, m.group(1), names))
    except (RuntimeError, OSError) as e:
        print("VERDICTCHECK: ERROR: %s" % e)
        return 2
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    bad = check_rule(cases, flags)
    bad += check_prints({n: prints[n] for n in cases}, m.group(1))
    bad += check_aggregate(streams, prints)
    for b in bad:
        print("  FAIL: " + b)
    print("VERDICTCHECK: %s" % ("FAIL (%d)" % len(bad) if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
