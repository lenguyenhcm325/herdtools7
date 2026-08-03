#!/usr/bin/env python3
"""
provcheck.py -- the P2d gate: is the PRINTED CLAIM capped by the oracle row's
PROVENANCE, and is the AMD lane wired to its own oracle at all?

TWO DEFECTS, both MEASURED on 2026-08-03 before this landed.

(1) The x86 lane read NO oracle.  litmus/hetCpuFront.X86_64 named no control map
    and no oracle CSV, so `HetControlMap.load' looked for control-map.csv next to
    a .litmus that has none.  All 411 x86 renderings emitted
        _rec.het_oracle = ORACLE_UNSET;
    and their harnesses printed "THIS HARNESS CARRIES NO ORACLE CLASS ... This is
    a BUILD BUG, not a result."  411 of 411.

(2) het_verdict.h was PROVENANCE-BLIND.  Its three reporting frames keyed on the
    4-valued het_oracle_t alone, so a row derived from one declared chain of
    reasoning printed the identical sentence as a two-key artifact-anchored row:
        "A single sighting REFUTES the model's prediction for this test."
    On expected-amd.csv that sentence is licensed by 32 of the 146 Disallowed
    rows and overstates the other 114.  PORT2-R2-amd-oracle.md sect 9.2:

      "the verdict printer must switch its mismatch sentence on the Provenance
       grade -- a mismatch on a full-strength (artifact) Disallowed row is
       reported as a candidate CMCM refutation, while a mismatch on a declared
       single-chain row (derived, or decision per 5.4.1) must be reported as
       indicting THIS ORACLE ROW first, never the CMCM."

THE DELIVERABLE IS THE SENTENCE, NOT THE ENUM (the B6c lesson, and this gate is
fixing that very class of defect, so phases 4 and 5 read the PRINTOUT of the real
emitted header compiled and run, never the source and never the enum).

Nine phases:

  P1 the enum        het_prov_t exists in the EMITTED header, PROV_UNSET is 0 and
                     first, and the strength order is UNSET < CAPPED < ARTIFACT
  P2 the AMD lane    the x86 corpus is tagged: census of oracle class x grade over
                     all 411, derived live from expected-amd.csv
  P3 the NVIDIA lane fails closed at PROV_UNSET/NO-COLUMN and its oracle CLASS
                     census is UNCHANGED (non-regression)
  P4 the sentences   four mutually exclusive mismatch texts, per-run AND campaign
  P5 blanking bites  blank the Provenance column, re-emit, recompile, and the
                     PRINTED SENTENCE changes from refutation to UNGRADED
  P6 D10 oracle      herd7 + x86tso.cat reproduces the D10 verdicts cell-for-cell,
                     and matches the PLDI'23 artifact's four CPU-Only rows
  P7 D10 reporting   cpu_only reaches the emitted harness and outranks the grade
  P8 B6c for AMD     Disallowed harnesses co-run their control; the 16 `none' rows
                     are canary-only BY DERIVATION; the control counts the WINDOWED
                     detector
  P9 fail-closed     unknown grade, absent row, and a wrong-vendor oracle

Every phase counts its assertions and FAILS if it made none -- the B6a
`exhaustive_valid'-constant-0 failure mode.  `--bite' injects into all nine, on
CORRUPTION and on OMISSION, and requires the phase that owns the injected object
to redden naming it.
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
GEN_X86 = os.path.join(HET_DIR, "generate-x86.sh")
GEN_D10 = os.path.join(HET_DIR, "generate-d10.sh")
EXPECTED_AMD = os.path.join(HET_DIR, "expected-amd.csv")
EXPECTED_NV = os.path.join(HET_DIR, "expected-nvidia.csv")
CONTROL_AMD = os.path.join(HET_DIR, "control-map-amd.csv")
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
HERD7 = os.path.join(ROOT, "_build", "install", "default", "bin", "herd7")
DIYONE7 = os.path.join(ROOT, "_build", "install", "default", "bin", "diyone7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")
HERDLIB = os.path.join(ROOT, "herd", "libdir")

# ---------------------------------------------------------------------------
# Census pins.  MEASURED, and every one is recomputed live from the CSVs at run
# time as well, so a pin can go stale only if someone changes both.
# ---------------------------------------------------------------------------
N_CORPUS = 411
# expected-amd.csv grade histogram (memo sect 2.3: 15 + 32 + 46 + 318 = 411)
GRADES = {"artifact": 32, "decision": 15, "herd7-checked": 46, "derived": 318}
# oracle class census, AMD lattice
AMD_CLASS = {"Allowed": 258, "Disallowed": 146, "NO-ORACLE": 7}
# the split that IS the defect: of the 146 Disallowed rows, how many report at
# full strength and how many are capped (memo sect 2.3, "32 of the 146 report at
# full strength and 114 report capped")
DIS_FULL, DIS_CAPPED = 32, 114
# NVIDIA lattice, unchanged by P2d (verdictcheck.py's own CENSUS)
NV_CLASS = {"Disallowed": 50, "Allowed": 319, "NO-ORACLE": 42}
# control-map-amd.csv: Disallowed rows whose Mu is the `none' sentinel
N_MU_NONE = 16
# D10: the six CPU-only shapes and their x86-TSO verdicts
D10 = {"MP": "Disallowed", "LB": "Disallowed", "SB": "Allowed",
       "2+2W": "Disallowed", "R": "Allowed", "IRIW": "Disallowed"}
D10_CYCLE = {
    "MP": "PodWW Rfe PodRR Fre",
    "LB": "PodRW Rfe PodRW Rfe",
    "SB": "PodWR Fre PodWR Fre",
    "2+2W": "PodWW Coe PodWW Coe",
    "R": "PodWW Coe PodWR Fre",
    "IRIW": "Rfe PodRR Fre Rfe PodRR Fre",
}
# The artifact's own CPU-Only rows (PLDI23_Compound_Simulation/expected.csv).
# Four shapes; the other two D10 rows have no artifact anchor and are graded
# `derived' / `herd7-checked' accordingly.
ARTIFACT_CPU_ONLY = {"MP": "Disallowed", "LB": "Disallowed",
                     "SB": "Allowed", "IRIW": "Disallowed"}

# ---------------------------------------------------------------------------
# THE FOUR MISMATCH SENTENCES.  Matched as exact substrings of the PRINTOUT.
# They are the deliverable: every other phase exists to get one of these four,
# and only one of them, in front of a reader.
# ---------------------------------------------------------------------------
S_FULL = "CANDIDATE CMCM REFUTATION"
S_CAPPED = "indicts THIS ORACLE ROW FIRST"
S_UNGRADED = "UNGRADED (provenance"
# The D10 marker both printers share.  The per-run printer expands it into the
# x86-TSO / memory-type reading; the campaign block states it in one line.  The
# marker is asserted in BOTH, the expansion only where it belongs -- MEASURED:
# keying the shared assertion on the per-run wording reddened all three D10
# cases against a campaign block that was in fact correct.
S_D10 = "CPU-ONLY CYCLE (D10)"
S_D10_LONG = "COMPOUND MODEL IS NOT UNDER TEST HERE"
SENTENCES = {"FULL": S_FULL, "CAPPED": S_CAPPED,
             "UNGRADED": S_UNGRADED, "D10": S_D10}

FAILS = []
NASSERT = {}


def fail(phase, msg):
    FAILS.append((phase, msg))
    print("  FAIL [%s] %s" % (phase, msg))


def ck(phase, cond, msg):
    NASSERT[phase] = NASSERT.get(phase, 0) + 1
    if not cond:
        fail(phase, msg)
    return cond


def run(cmd, **kw):
    kw.setdefault("stdout", subprocess.PIPE)
    kw.setdefault("stderr", subprocess.PIPE)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def read_csv(path, want_prov=True):
    """name -> (verdict, model, grade).  Header-detected, like the emitter."""
    rows, has_prov = {}, False
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = [x.strip() for x in line.split(",")]
        if f[0] == "Litmus":
            has_prov = len(f) >= 4 and f[3] == "Provenance"
            continue
        rows[f[0]] = (f[1], f[2] if len(f) > 2 else "?",
                      f[3] if (has_prov and len(f) > 3) else None)
    return rows, has_prov


# ===========================================================================
# The C driver: the REAL emitted header, compiled, fed synthetic records, and
# its PRINTOUT captured.  Nothing here reads het_verdict.h as text.
# ===========================================================================
C_MAIN = r"""
/* GENERATED by hetlitmus/verify/provcheck.py -- do not edit. */
#include "het_verdict.h"
#include <string.h>

static void one(const char *name, het_obs_record r) {
  printf("PRINT-BEGIN|%s\n", name);
  het_verdict_print(stdout, &r);
  printf("PRINT-END|%s\n", name);
  /* The CAMPAIGN-level block too: it is the one that gets pasted into a report,
     and before P2d it asserted "REFUTATION OF THE CMCM's PREDICTION" on every
     Disallowed row whatever its grade. */
  printf("STATS-BEGIN|%s\n", name);
  { het_obs_record cells[3]; het_stats_t st; int i;
    for (i = 0; i < 3; i++) { cells[i] = r; cells[i].run_id = i; }
    het_stats_compute(cells, 3, &st);
    het_stats_print(stdout, &st); }
  printf("STATS-END|%s\n", name);
}

/* Strength order, checked at COMPILE time so it cannot be re-sorted quietly. */
typedef char _prov_order_check[(PROV_UNSET == 0
                                && PROV_UNSET < PROV_CAPPED
                                && PROV_CAPPED < PROV_ARTIFACT) ? 1 : -1];

int main(void) {
  printf("PROV_UNSET=%d PROV_CAPPED=%d PROV_ARTIFACT=%d\n",
         (int)PROV_UNSET, (int)PROV_CAPPED, (int)PROV_ARTIFACT);
__CASES__
  return 0;
}
"""

# A live, hot, credible DISALLOWED record that SAW the forbidden outcome.  Every
# case is this with a couple of fields moved, so each isolates one reason.
BASE = dict(
    het_oracle="ORACLE_DISALLOWED",
    exhaustive_valid=1,
    target_count_exhaustive=1, target_count_heuristic=1,
    interleavings_detected=1000, sync_valid=1,
    control_compiled_in=1, canary_compiled_in=1,
    control_target_count=30, canary_target_count=500,
    control_exhaustive_valid=1, canary_exhaustive_valid=1,
    spin_rendezvous=900, spin_cap=100, gpu_stress_rounds=64,
    cpu_enemy_rounds=1000, cpu_preload_ops=1000,
    noise_cpu_rounds=1000, noise_gpu_blocks=8,
    stress_requested=0x3F, N=1000, frames_examined=1000,
    # The per-window sub-tallies must SUM to the totals or het_stats_print raises
    # HET_ST_WIN_DESYNC and stops before the block this gate exists to read; and
    # distinct_decoded_iters must clear HET_THETA_DISTINCT or every cell is
    # DEGENERATE and the sighting never reaches the tier.  Both MEASURED here by
    # watching this driver stop one line short of the sentence.
    control_win="{30}", canary_win="{500}",
    distinct_decoded_iters=64,
)

CASES = [
    ("full", dict(het_prov="PROV_ARTIFACT", het_prov_name='"artifact"')),
    ("capped-derived", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"')),
    ("capped-decision", dict(het_prov="PROV_CAPPED", het_prov_name='"decision"')),
    ("ungraded", dict(het_prov="PROV_UNSET", het_prov_name='"NO-COLUMN"')),
    ("ungraded-absent", dict(het_prov="PROV_UNSET", het_prov_name='"ABSENT"')),
    # D10 outranks the grade: even a full-strength CPU-only row must not print
    # the refutation sentence.
    ("d10-full", dict(het_prov="PROV_ARTIFACT", het_prov_name='"artifact"',
                      cpu_only=1, obs_ws_via_cpu=1)),
    ("d10-capped", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"',
                        cpu_only=1, obs_ws_via_cpu=1)),
    # ...and a CPU-only sighting carried ONLY by the GPU observer is not even an
    # x86-TSO statement.
    ("d10-gpu-observer", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"',
                              cpu_only=1, obs_ws_via_gpu=1, obs_ws_via_cpu=0)),
]


def c_record(extra):
    r = dict(BASE)
    r.update(extra)
    r.setdefault("oracle_source", '"expected-amd.csv:AMD-CDNA3-x86"')
    return ('(het_obs_record){ .test_name="synthetic", '
            + ", ".join(".%s=%s" % (k, v) for k, v in sorted(r.items())) + " }")


def build_driver(cases):
    body = "\n".join('  one("%s", %s);' % (n, c_record(e)) for n, e in cases)
    return C_MAIN.replace("__CASES__", body)


def emit_header(tmp, test=None, srcdir=None):
    """The REAL het_verdict.h -- the one litmus7 writes into every harness."""
    out = os.path.join(tmp, "hdr")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    test = test or "MP-cg-sys-fence-2s.litmus"
    srcdir = srcdir or HET_DIR
    r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", out, test], cwd=srcdir)
    h = os.path.join(out, test[:-len(".litmus")], "het_verdict.h")
    if not os.path.exists(h):
        raise SystemExit("provcheck: litmus7 emitted no het_verdict.h\n"
                         + r.stdout + r.stderr)
    return h


def compile_and_run(tmp, header, cases, tag="drv"):
    d = os.path.join(tmp, tag)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copy(header, os.path.join(d, "het_verdict.h"))
    src = os.path.join(d, "main.c")
    open(src, "w").write(build_driver(cases))
    exe = os.path.join(d, "drv")
    cc = run(["gcc", "-std=c99", "-O1", "-Wall", "-Wno-unused-function",
              "-I", d, src, "-o", exe, "-lm"])
    if cc.returncode != 0:
        return None, cc.stdout + cc.stderr
    r = run([exe])
    return r.stdout, r.stdout + r.stderr


def blocks(out, kind="PRINT"):
    """name -> printed text, from the driver's delimited blocks."""
    res, cur, buf = {}, None, []
    for line in (out or "").splitlines():
        if line.startswith(kind + "-BEGIN|"):
            cur, buf = line.split("|", 1)[1], []
        elif line.startswith(kind + "-END|"):
            if cur is not None:
                res[cur] = "\n".join(buf)
            cur = None
        elif cur is not None:
            buf.append(line)
    return res


# ===========================================================================
# corpora
# ===========================================================================
def gen_x86(tmp, gen=None):
    out = os.path.join(tmp, "x86")
    shutil.rmtree(out, ignore_errors=True)
    r = run(["bash", gen or GEN_X86, out])
    if r.returncode != 0:
        raise SystemExit("provcheck: generate-x86.sh failed\n" + r.stdout + r.stderr)
    return out


def gen_d10(tmp, gen=None):
    out = os.path.join(tmp, "d10")
    shutil.rmtree(out, ignore_errors=True)
    r = run(["bash", gen or GEN_D10, out])
    if r.returncode != 0:
        raise SystemExit("provcheck: generate-d10.sh failed\n" + r.stdout + r.stderr)
    return out


REC = re.compile(r"_rec\.(het_oracle|het_prov|het_prov_name|oracle_source|cpu_only)"
                 r"\s*=\s*([^;]+);")


def emit_corpus(tmp, srcdir, tag, tests=None):
    """Emit every .litmus of [srcdir]; return name -> {field: value}."""
    out = os.path.join(tmp, "out-" + tag)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    got, refused = {}, []
    names = tests if tests is not None else sorted(
        f for f in os.listdir(srcdir) if f.endswith(".litmus"))
    for t in names:
        n = t[:-len(".litmus")]
        r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", out, t], cwd=srcdir)
        cu = os.path.join(out, n, n + ".cu")
        if r.returncode != 0 or "HetLitmus REFUSED" in (r.stdout + r.stderr) \
           or not os.path.exists(cu):
            refused.append((n, (r.stdout + r.stderr).strip().splitlines()[-1:]))
            continue
        d = {}
        for m in REC.finditer(open(cu).read()):
            d.setdefault(m.group(1), m.group(2).strip())
        got[n] = d
    return out, got, refused


# ===========================================================================
# PHASES
# ===========================================================================
def phase1(tmp, header):
    print("== P1  the enum: PROV_UNSET is 0 and the order is the strength order ==")
    out, blob = compile_and_run(tmp, header, CASES[:1], "p1")
    if not ck("P1", out is not None,
              "the emitted het_verdict.h does not compile against the "
              "provenance driver (the _prov_order_check static assert is in it, so "
              "a re-sorted enum lands here):\n" + (blob or "")[-1200:]):
        return
    if out is None:
        fail("P1", "the emitted het_verdict.h does not compile against the "
                   "provenance driver (the _prov_order_check static assert is in "
                   "it, so a re-sorted enum lands here):\n" + blob[-1200:])
        return
    m = re.search(r"PROV_UNSET=(\d+) PROV_CAPPED=(\d+) PROV_ARTIFACT=(\d+)", out)
    if not ck("P1", m, "the driver printed no PROV_* values"):
        return
    u, c, a = (int(x) for x in m.groups())
    ck("P1", u == 0, "PROV_UNSET is %d, not 0 -- het_obs_record is memset(0), so "
                     "the value an untagged emitter produces MUST be the weakest" % u)
    ck("P1", u < c < a, "the enum is not in strength order: UNSET=%d CAPPED=%d "
                        "ARTIFACT=%d" % (u, c, a))
    print("     PROV_UNSET=%d < PROV_CAPPED=%d < PROV_ARTIFACT=%d" % (u, c, a))


def phase2(tmp, x86dir):
    print("== P2  the AMD lane: all 411 x86 renderings carry class AND grade ==")
    rows, has_prov = read_csv(EXPECTED_AMD)
    ck("P2", has_prov, "expected-amd.csv has no `Provenance' header column")
    ck("P2", len(rows) == N_CORPUS,
       "expected-amd.csv has %d rows, pinned at %d" % (len(rows), N_CORPUS))
    live_grades = {}
    live_class = {}
    for _, (v, _m, g) in rows.items():
        live_grades[g] = live_grades.get(g, 0) + 1
        live_class[v] = live_class.get(v, 0) + 1
    ck("P2", live_grades == GRADES,
       "expected-amd.csv grade histogram %r != pinned %r" % (live_grades, GRADES))
    ck("P2", live_class == AMD_CLASS,
       "expected-amd.csv class histogram %r != pinned %r" % (live_class, AMD_CLASS))

    out, got, refused = emit_corpus(tmp, x86dir, "x86")
    ck("P2", not refused,
       "%d x86 rendering(s) did not emit a harness, e.g. %r" % (len(refused), refused[:2]))
    ck("P2", len(got) == N_CORPUS,
       "%d x86 harnesses emitted, expected %d" % (len(got), N_CORPUS))

    want_enum = {"artifact": "PROV_ARTIFACT"}
    n_unset = n_full = n_capped = 0
    dis_full = dis_capped = 0
    for n, d in got.items():
        base = n[:-len("-x86_64")]
        if base not in rows:
            fail("P2", "%s has no expected-amd.csv row" % n)
            continue
        verdict, _model, grade = rows[base]
        NASSERT["P2"] = NASSERT.get("P2", 0) + 1
        exp = want_enum.get(grade, "PROV_CAPPED")
        if d.get("het_prov") != exp:
            fail("P2", "%s: grade %r should emit %s, emitted %r"
                 % (n, grade, exp, d.get("het_prov")))
        if d.get("het_prov_name") != '"%s"' % grade:
            fail("P2", "%s: het_prov_name is %r, the CSV grade is %r"
                 % (n, d.get("het_prov_name"), grade))
        if d.get("oracle_source") != '"expected-amd.csv:AMD-CDNA3-x86"':
            fail("P2", "%s: oracle_source is %r, not the AMD oracle"
                 % (n, d.get("oracle_source")))
        if d.get("het_oracle") == "ORACLE_UNSET":
            n_unset += 1
        if d.get("het_prov") == "PROV_ARTIFACT":
            n_full += 1
        if d.get("het_prov") == "PROV_CAPPED":
            n_capped += 1
        if d.get("het_oracle") == "ORACLE_DISALLOWED":
            if d.get("het_prov") == "PROV_ARTIFACT":
                dis_full += 1
            else:
                dis_capped += 1
    ck("P2", n_unset == 0,
       "%d x86 harnesses still emit ORACLE_UNSET (it was %d of %d before P2d)"
       % (n_unset, N_CORPUS, N_CORPUS))
    ck("P2", n_full == GRADES["artifact"],
       "%d harnesses emit PROV_ARTIFACT, the CSV has %d `artifact' rows"
       % (n_full, GRADES["artifact"]))
    ck("P2", n_capped == N_CORPUS - GRADES["artifact"],
       "%d harnesses emit PROV_CAPPED, expected %d"
       % (n_capped, N_CORPUS - GRADES["artifact"]))
    ck("P2", (dis_full, dis_capped) == (DIS_FULL, DIS_CAPPED),
       "the Disallowed split is %d full / %d capped, memo sect 2.3 says %d / %d"
       % (dis_full, dis_capped, DIS_FULL, DIS_CAPPED))
    print("     411 emitted, 0 ORACLE_UNSET; grades %d FULL / %d CAPPED; "
          "Disallowed %d full / %d capped" % (n_full, n_capped, dis_full, dis_capped))
    return out, got


def phase3(tmp):
    print("== P3  the NVIDIA lane fails closed, and its CLASS census is untouched ==")
    rows, has_prov = read_csv(EXPECTED_NV)
    ck("P3", not has_prov,
       "expected-nvidia.csv now HAS a Provenance column -- NV-PROV landed and this "
       "phase (and P2d's fail-closed reading of the NVIDIA lane) must be revisited")
    tests = sorted(f for f in os.listdir(HET_DIR) if f.endswith(".litmus"))
    _out, got, refused = emit_corpus(tmp, HET_DIR, "nv", tests)
    ck("P3", not refused, "%d aarch64 test(s) refused: %r" % (len(refused), refused[:2]))
    cls = {}
    bad_prov = bad_src = bad_name = 0
    for n, d in got.items():
        NASSERT["P3"] = NASSERT.get("P3", 0) + 1
        cls[d.get("het_oracle")] = cls.get(d.get("het_oracle"), 0) + 1
        if d.get("het_prov") != "PROV_UNSET":
            bad_prov += 1
        if d.get("oracle_source") != '"expected-nvidia.csv:NVIDIA-PTX-AArch64"':
            bad_src += 1
        # WHICH KIND of unset: the NVIDIA oracle HAS the row and has no grade
        # column, which is not the same as the row being missing.  Without this
        # the harness could print `provenance artifact' next to PROV_UNSET and
        # nothing would notice.
        if d.get("het_prov_name") != '"NO-COLUMN"':
            bad_name += 1
    ck("P3", bad_prov == 0,
       "%d aarch64 harnesses do NOT emit PROV_UNSET -- the NVIDIA oracle carries no "
       "grade, so every one of them must claim least (rule 8)" % bad_prov)
    ck("P3", bad_src == 0,
       "%d aarch64 harnesses name the wrong oracle source" % bad_src)
    ck("P3", bad_name == 0,
       "%d aarch64 harnesses do not report their unset reason as NO-COLUMN -- the "
       "printout must distinguish `this oracle has no grade column' from `this row "
       "is missing'" % bad_name)
    want = {"ORACLE_" + k.upper().replace("-ORACLE", "_NONE").replace("NO_NONE", "NONE"): v
            for k, v in ()}  # (placeholder, replaced below)
    want = {"ORACLE_DISALLOWED": NV_CLASS["Disallowed"],
            "ORACLE_ALLOWED": NV_CLASS["Allowed"],
            "ORACLE_NONE": NV_CLASS["NO-ORACLE"]}
    ck("P3", cls == want,
       "the NVIDIA oracle-class census changed: %r != %r (P2d must not regrade "
       "NVIDIA)" % (cls, want))
    print("     %d aarch64 harnesses, all PROV_UNSET/NO-COLUMN, class census %r"
          % (len(got), cls))


def phase4(tmp, header):
    print("== P4  THE SENTENCES: four mismatch texts, mutually exclusive, "
          "per-run AND campaign ==")
    out, blob = compile_and_run(tmp, header, CASES, "p4")
    if not ck("P4", out is not None,
              "driver did not compile:\n" + (blob or "")[-1200:]):
        return
    want = {
        "full": "FULL", "capped-derived": "CAPPED", "capped-decision": "CAPPED",
        "ungraded": "UNGRADED", "ungraded-absent": "UNGRADED",
        "d10-full": "D10", "d10-capped": "D10", "d10-gpu-observer": "D10",
    }
    for kind in ("PRINT", "STATS"):
        b = blocks(out, kind)
        ck("P4", set(b) == set(want),
           "%s blocks %r != cases %r" % (kind, sorted(b), sorted(want)))
        for name, w in want.items():
            txt = b.get(name, "")
            NASSERT["P4"] = NASSERT.get("P4", 0) + 1
            if SENTENCES[w] not in txt:
                fail("P4", "%s/%s does not print the %s sentence %r; it printed:\n%s"
                     % (kind, name, w, SENTENCES[w], txt[:600]))
            for other, s in SENTENCES.items():
                if other == w:
                    continue
                NASSERT["P4"] = NASSERT.get("P4", 0) + 1
                if s in txt:
                    fail("P4", "%s/%s prints the %s sentence %r as well as its own -- "
                               "the frames are not mutually exclusive" % (kind, name, other, s))
    # The GRADE STRING must appear, not only the class: a reader has to be able to
    # look the row up in memo sect 2.3.
    b = blocks(out, "PRINT")
    for name, grade in (("capped-derived", "derived"), ("capped-decision", "decision"),
                        ("full", "artifact"), ("ungraded", "NO-COLUMN")):
        NASSERT["P4"] = NASSERT.get("P4", 0) + 1
        if "provenance %s" % grade not in b.get(name, ""):
            fail("P4", "%s does not NAME its grade (`provenance %s') in the printout"
                 % (name, grade))
    # The campaign block must no longer assert the CMCM unconditionally.
    for name in ("capped-derived", "ungraded"):
        NASSERT["P4"] = NASSERT.get("P4", 0) + 1
        if "REFUTATION OF THE CMCM" in blocks(out, "STATS").get(name, ""):
            fail("P4", "the CAMPAIGN block still calls %s a REFUTATION OF THE CMCM" % name)
    # ...and the GPU-observer case must add its own disclaimer on top of D10.
    for name in ("d10-full", "d10-capped", "d10-gpu-observer"):
        NASSERT["P4"] = NASSERT.get("P4", 0) + 1
        if S_D10_LONG not in b.get(name, ""):
            fail("P4", "the PER-RUN printer does not spell out %r on %s -- the "
                       "one-line marker alone does not tell a reader why" % (S_D10_LONG, name))
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "GPU IS NOT AN x86 AGENT" not in b.get("d10-gpu-observer", ""):
        fail("P4", "a CPU-only sighting carried ONLY by the GPU observer does not say "
                   "the GPU is not an x86 agent -- it would read as an x86-TSO violation")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "GPU IS NOT AN x86 AGENT" in b.get("d10-capped", ""):
        fail("P4", "the GPU-observer disclaimer is printed on a run the x86 observer "
                   "decoded -- it would excuse a real x86-TSO violation")
    print("     4 sentences x 8 cases x 2 printers, mutually exclusive; grades named")


def phase5(tmp, x86dir, header):
    print("== P5  BLANKING the Provenance column changes the PRINTED SENTENCE ==")
    # A real `artifact' Disallowed row, emitted twice: once from the shipped CSV,
    # once from a CSV whose Provenance column has been blanked.
    victim = None
    rows, _ = read_csv(EXPECTED_AMD)
    for n, (v, _m, g) in sorted(rows.items()):
        if v == "Disallowed" and g == "artifact":
            victim = n
            break
    if not ck("P5", victim, "no Disallowed/artifact row to use as the victim"):
        return
    t = victim + "-x86_64"

    def emit_with(csv_text, tag):
        d = os.path.join(tmp, "p5-" + tag)
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(x86dir, d)
        open(os.path.join(d, "expected-amd.csv"), "w").write(csv_text)
        o = os.path.join(tmp, "p5out-" + tag)
        shutil.rmtree(o, ignore_errors=True)
        os.makedirs(o)
        r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", o, t + ".litmus"], cwd=d)
        cu = os.path.join(o, t, t + ".cu")
        if not os.path.exists(cu):
            return None, None, (r.stdout + r.stderr)
        src = open(cu).read()
        prov = re.search(r"_rec\.het_prov\s*=\s*(\w+);", src)
        pname = re.search(r'_rec\.het_prov_name\s*=\s*"([^"]*)";', src)
        return (prov.group(1) if prov else None,
                pname.group(1) if pname else None,
                os.path.join(o, t, "het_verdict.h"))

    orig = open(os.path.join(x86dir, "expected-amd.csv")).read()
    good_prov, good_name, good_hdr = emit_with(orig, "good")
    ck("P5", good_prov == "PROV_ARTIFACT",
       "%s emits %r from the shipped CSV, expected PROV_ARTIFACT" % (t, good_prov))
    ck("P5", good_name == "artifact", "%s: grade name is %r" % (t, good_name))

    blanked = []
    for line in orig.splitlines(True):
        f = line.split(",")
        if line.startswith(t + ",") and len(f) >= 5:
            f[3] = ""
            line = ",".join(f)
        blanked.append(line)
    bad_prov, bad_name, bad_hdr = emit_with("".join(blanked), "blank")
    ck("P5", bad_prov == "PROV_UNSET",
       "with the Provenance cell BLANKED, %s emits %r -- an unreadable grade must "
       "fall to PROV_UNSET, never keep the old one" % (t, bad_prov))
    ck("P5", bad_name == "UNKNOWN:",
       "with the cell blanked the grade name is %r, expected `UNKNOWN:'" % bad_name)

    # ...and now the part that is the actual deliverable: THE TEXT.
    case = [("victim", dict(het_prov=good_prov or "PROV_UNSET",
                            het_prov_name='"%s"' % (good_name or "")))]
    got_good, _ = compile_and_run(tmp, good_hdr, case, "p5g")
    case = [("victim", dict(het_prov=bad_prov or "PROV_UNSET",
                            het_prov_name='"%s"' % (bad_name or "")))]
    got_bad, _ = compile_and_run(tmp, bad_hdr, case, "p5b")
    tg = blocks(got_good).get("victim", "")
    tb = blocks(got_bad).get("victim", "")
    ck("P5", S_FULL in tg,
       "with the grade present the printout does NOT claim a candidate refutation")
    ck("P5", S_FULL not in tb,
       "with the grade BLANKED the printout STILL claims a candidate CMCM refutation "
       "-- the sentence did not follow the column")
    ck("P5", S_UNGRADED in tb,
       "with the grade blanked the printout does not say UNGRADED; it said:\n" + tb[:600])
    ck("P5", tg != tb, "blanking the Provenance column did not change the printout")
    print("     %s: grade present -> %r; blanked -> %r; the SENTENCE follows"
          % (t, S_FULL, S_UNGRADED))


def phase6(tmp, d10dir):
    print("== P6  the D10 oracle is machine-checked (herd7 + x86tso.cat) ==")
    rows, has_prov = read_csv(os.path.join(d10dir, "expected-amd.csv"))
    ck("P6", has_prov, "the D10 oracle has no Provenance column")
    ck("P6", len(rows) == len(D10),
       "the D10 oracle has %d rows, expected %d" % (len(rows), len(D10)))
    w = os.path.join(tmp, "p6herd")
    shutil.rmtree(w, ignore_errors=True)
    os.makedirs(w)
    for shape, want in sorted(D10.items()):
        NASSERT["P6"] = NASSERT.get("P6", 0) + 1
        r = run([DIYONE7, "-set-libdir", HERDLIB, "-arch", "X86",
                 "-name", shape + "-x86"] + D10_CYCLE[shape].split(), cwd=w)
        f = os.path.join(w, shape + "-x86.litmus")
        if not os.path.exists(f):
            fail("P6", "diyone7 produced no %s test: %s" % (shape, (r.stdout + r.stderr)[-200:]))
            continue
        h = run([HERD7, "-set-libdir", HERDLIB, "-model", "x86tso.cat", f])
        obs = [l for l in h.stdout.splitlines() if l.startswith("Observation")]
        if not obs:
            fail("P6", "herd7 gave no Observation for %s: %s"
                 % (shape, (h.stdout + h.stderr)[-300:]))
            continue
        seen = obs[0].split()[2] != "Never"
        got = "Allowed" if seen else "Disallowed"
        if got != want:
            fail("P6", "herd7 + x86tso.cat says %s is %s, the D10 oracle says %s (%s)"
                 % (shape, got, want, obs[0]))
        name = "%s-cpuonly-x86_64" % shape
        NASSERT["P6"] = NASSERT.get("P6", 0) + 1
        if name not in rows:
            fail("P6", "%s is missing from the generated D10 oracle" % name)
        elif rows[name][0] != want:
            fail("P6", "the D10 oracle says %s is %s, x86-TSO says %s"
                 % (name, rows[name][0], want))
    # ...and against the PLDI'23 artifact's own CPU-Only rows.
    for shape, want in sorted(ARTIFACT_CPU_ONLY.items()):
        NASSERT["P6"] = NASSERT.get("P6", 0) + 1
        if D10.get(shape) != want:
            fail("P6", "artifact expected.csv says CPU-Only %s-sys is %s, the D10 "
                       "table says %s" % (shape, want, D10.get(shape)))
        NASSERT["P6"] = NASSERT.get("P6", 0) + 1
        if rows.get("%s-cpuonly-x86_64" % shape, ("", "", ""))[2] != "artifact":
            fail("P6", "%s has an artifact CPU-Only anchor but is not graded "
                       "`artifact'" % shape)
    print("     6 shapes: herd7+x86tso.cat == the D10 oracle, cell for cell; "
          "the 4 artifact shapes are graded `artifact'")


def phase7(tmp, d10dir, x86got):
    print("== P7  D10 reaches the harness, and cpu_only outranks the grade ==")
    _out, got, refused = emit_corpus(tmp, d10dir, "d10")
    ck("P7", not refused, "D10 test(s) refused: %r" % (refused[:3],))
    ck("P7", len(got) == len(D10),
       "%d D10 harnesses emitted, expected %d" % (len(got), len(D10)))
    for n, d in sorted(got.items()):
        NASSERT["P7"] = NASSERT.get("P7", 0) + 1
        if d.get("cpu_only") != "1":
            fail("P7", "%s is a CPU-only test but emits cpu_only=%r"
                 % (n, d.get("cpu_only")))
    # ...and the het corpus must NOT be flagged: a flag that is always 1 says
    # nothing, and one that is always 0 would silently disable D10.
    n1 = sum(1 for d in x86got.values() if d.get("cpu_only") == "1")
    ck("P7", n1 == 0,
       "%d of the %d heterogeneous x86 harnesses claim cpu_only=1" % (n1, len(x86got)))
    print("     %d D10 harnesses cpu_only=1, %d het harnesses cpu_only=0"
          % (len(got), len(x86got)))


def phase8(tmp, x86dir, x86got, x86out):
    print("== P8  B6c for AMD: the Disallowed harnesses co-run their control ==")
    cm = {}
    for line in open(CONTROL_AMD):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split(",")
        if len(f) < 8 or f[0] == "Test":
            continue
        cm[f[0]] = (f[1], f[2], f[7])
    n_none = sum(1 for v in cm.values() if v[1] == "none")
    ck("P8", n_none == N_MU_NONE,
       "control-map-amd.csv has %d `none' Mu rows, pinned at %d" % (n_none, N_MU_NONE))
    ck("P8", all(cm[k][0] == "Disallowed" for k in cm if cm[k][1] == "none"),
       "a `none' Mu row is not Disallowed -- the sentinel means `this Disallowed "
       "row has no Layer-A mutant', not `no mu is called for'")
    n_corun = n_canary_only = 0
    for n in sorted(x86got):
        base = n[:-len("-x86_64")]
        if base not in cm or cm[base][0] != "Disallowed":
            continue
        NASSERT["P8"] = NASSERT.get("P8", 0) + 1
        src = open(os.path.join(x86out, n, n + ".cu")).read()
        m = re.search(r"#define HET_CONTROL_COMPILED_IN (\d)", src)
        built = m.group(1) if m else "?"
        if cm[base][1] == "none":
            if built != "0":
                fail("P8", "%s has no Layer-A mutant but HET_CONTROL_COMPILED_IN=%s"
                     % (n, built))
            n_canary_only += 1
        else:
            if built != "1":
                fail("P8", "%s names mu(T)=%s but HET_CONTROL_COMPILED_IN=%s -- the "
                           "control was NOT compiled in" % (n, cm[base][1], built))
            # ...and the mutant must really be a THIRD instance in the source.
            NASSERT["P8"] = NASSERT.get("P8", 0) + 1
            if "mu_" not in src:
                fail("P8", "%s claims a control but emits no mu_ instance" % n)
            n_corun += 1
        # The control has to count the WINDOWED detector, not only the exhaustive
        # scan: at production N a T_L>=2 shape never runs the O(N^T_L) scan, so a
        # control keyed on it alone is cold forever (the B6b lesson).
        # The control has to count the WINDOWED detector, not only the exhaustive
        # scan: at production N a T_L>=2 shape never runs the O(N^T_L) scan, so a
        # control keyed on it alone is cold forever (the B6b lesson).  MEASURED
        # spelling, from S-cg-sys-release-x86_64.cu:1051.
        NASSERT["P8"] = NASSERT.get("P8", 0) + 1
        bumps = "_rec.control_target_count++" in src
        wins = "_rec.control_win[het_win_of(" in src
        if cm[base][1] == "none":
            if bumps or wins:
                fail("P8", "%s has NO Layer-A mutant yet its scan bumps the control "
                           "tally -- a control that cannot exist must not count" % n)
        elif not (bumps and wins):
            fail("P8", "%s: control tally bumped=%s windowed=%s -- the control must "
                       "count the WINDOWED detector or it is cold forever at "
                       "production N" % (n, bumps, wins))
    ck("P8", n_corun == AMD_CLASS["Disallowed"] - N_MU_NONE,
       "%d Disallowed harnesses co-run a mutant, expected %d"
       % (n_corun, AMD_CLASS["Disallowed"] - N_MU_NONE))
    ck("P8", n_canary_only == N_MU_NONE,
       "%d Disallowed harnesses are canary-only, expected %d"
       % (n_canary_only, N_MU_NONE))
    print("     %d Disallowed co-run mu(T); %d are canary-only BY DERIVATION"
          % (n_corun, n_canary_only))


def phase9(tmp, x86dir):
    print("== P9  fail-closed: unknown grade, absent row, wrong-vendor oracle ==")
    rows, _ = read_csv(EXPECTED_AMD)
    victim = next(n for n, (v, _m, g) in sorted(rows.items())
                  if v == "Disallowed" and g == "artifact")
    t = victim + "-x86_64"
    orig = open(os.path.join(x86dir, "expected-amd.csv")).read()

    def emit_with(text, tag, expect_ok=True):
        d = os.path.join(tmp, "p9-" + tag)
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(x86dir, d)
        open(os.path.join(d, "expected-amd.csv"), "w").write(text)
        o = os.path.join(tmp, "p9out-" + tag)
        shutil.rmtree(o, ignore_errors=True)
        os.makedirs(o)
        r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", o, t + ".litmus"], cwd=d)
        cu = os.path.join(o, t, t + ".cu")
        src = open(cu).read() if os.path.exists(cu) else ""
        return r, src

    # (a) an unrecognised grade string
    mangled = orig.replace("," + "artifact" + ",", ",kinda-anchored,")
    _r, src = emit_with(mangled, "unknown")
    ck("P9", "_rec.het_prov = PROV_UNSET;" in src,
       "an UNRECOGNISED grade did not fall to PROV_UNSET")
    ck("P9", '_rec.het_prov_name = "UNKNOWN:kinda-anchored";' in src,
       "an unrecognised grade is not NAMED in the harness (a silent UNSET reads "
       "like a missing row)")
    # (b) the row deleted outright -- OMISSION, not corruption
    dropped = "".join(l for l in orig.splitlines(True) if not l.startswith(t + ","))
    _r, src = emit_with(dropped, "absent")
    ck("P9", "_rec.het_prov = PROV_UNSET;" in src,
       "a test ABSENT from the oracle did not fall to PROV_UNSET")
    ck("P9", '_rec.het_prov_name = "ABSENT";' in src,
       "an absent row is not reported as ABSENT")
    # (c) the wrong vendor's Model -- must REFUSE, not tag
    wrong = orig.replace("AMD-CDNA3-x86", "NVIDIA-PTX-AArch64")
    r, src = emit_with(wrong, "vendor")
    ck("P9", r.returncode != 0 and "HetLitmus REFUSED" in (r.stdout + r.stderr),
       "an oracle carrying the OTHER vendor's Model did not make litmus7 refuse "
       "(exit %d)" % r.returncode)
    ck("P9", src == "", "a refused test still left a harness behind")
    print("     unknown grade -> UNSET/UNKNOWN:, absent row -> UNSET/ABSENT, "
          "wrong Model -> REFUSED")


# ===========================================================================
def main_run(quiet=False):
    del quiet
    tmp = tempfile.mkdtemp(prefix="provcheck.")
    try:
        header = emit_header(tmp)
        x86dir = gen_x86(tmp)
        d10dir = gen_d10(tmp)
        phase1(tmp, header)
        x86out, x86got = phase2(tmp, x86dir)
        phase3(tmp)
        phase4(tmp, header)
        phase5(tmp, x86dir, header)
        phase6(tmp, d10dir)
        phase7(tmp, d10dir, x86got)
        phase8(tmp, x86dir, x86got, x86out)
        phase9(tmp, x86dir)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # NON-VACUITY: a phase that compared nothing is not a phase that passed.
    for p in ("P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "P9"):
        if NASSERT.get(p, 0) == 0:
            fail(p, "made ZERO assertions -- a phase that checked nothing cannot pass")
    print("\n      %d assertions (%s)"
          % (sum(NASSERT.values()),
             " ".join("%s=%d" % (p, NASSERT.get(p, 0)) for p in sorted(NASSERT))))
    return FAILS


# ===========================================================================
# --bite.  Each injection must redden ITS OWN phase, naming the object.
# ===========================================================================
def _reset():
    del FAILS[:]
    NASSERT.clear()


def _bite(label, phase, mutate, want, abort=None):
    """Run the gate with [mutate] applied to the tree; require [phase] to fail.

    [abort] names the OTHER acceptable outcome, and it is spelled out per
    injection rather than allowed globally: some corruptions are caught by a
    detector that stands EARLIER than this gate -- generate-x86.sh's own
    key-coverage check, or litmus7's Model guard -- and abort the run before the
    phase can be reached.  That is the detector firing, not the gate failing, but
    it is only accepted where the injection says so and only if the abort message
    matches, so a crash from anywhere else still reads as a failed bite.
    """
    print("  -- bite [%s] %s" % (phase, label))
    _reset()
    undo = mutate()
    aborted = None
    try:
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            try:
                main_run()
            except SystemExit as e:
                aborted = str(e)
                print("SystemExit: %s" % e)
            except Exception as e:                     # noqa: BLE001
                aborted = repr(e)
                print("EXCEPTION: %r" % e)
        out = buf.getvalue()
    finally:
        undo()
    if abort is not None and aborted is not None:
        if re.search(abort, aborted):
            print("     OK (refused upstream): %s"
                  % " ".join(aborted.split())[:150])
            return True
        print("     BITE FAILED: aborted, but not with /%s/:\n       %s"
              % (abort, aborted[:400]))
        return False
    mine = [m for (p, m) in FAILS if p == phase]
    hit = [m for m in mine if re.search(want, m)]
    if not mine:
        print("     BITE FAILED: %s did not fail at all.\n%s" % (phase, out[-2000:]))
        return False
    if not hit:
        print("     BITE FAILED: %s failed, but for the wrong reason "
              "(wanted /%s/):\n       %s" % (phase, want, "\n       ".join(mine[:3])))
        return False
    print("     OK: %s" % hit[0][:150])
    return True


def _patch(path, old, new):
    """Return a mutate() that replaces [old] with [new] in [path]."""
    def go():
        orig = open(path).read()
        if old not in orig:
            raise SystemExit("provcheck --bite: %r not found in %s" % (old[:60], path))
        open(path, "w").write(orig.replace(old, new, 1))
        return lambda: open(path, "w").write(orig)
    return go


def _drop_line(path, pred):
    """Return a mutate() that DELETES the first line matching [pred] (OMISSION)."""
    def go():
        orig = open(path).read()
        lines = orig.splitlines(True)
        for i, l in enumerate(lines):
            if pred(l):
                del lines[i]
                open(path, "w").write("".join(lines))
                return lambda: open(path, "w").write(orig)
        raise SystemExit("provcheck --bite: no line to drop in %s" % path)
    return go


VERDICT_H = os.path.join(ROOT, "litmus", "het-runtime", "het_verdict.h")
EMIT_ML = os.path.join(ROOT, "litmus", "hetEmit.ml")
FRONT_ML = os.path.join(ROOT, "litmus", "hetCpuFront.ml")
ORACLE_ML = os.path.join(ROOT, "litmus", "hetOracle.ml")


def rebuild():
    r = run(["make", "-s", "all"], cwd=ROOT)
    if r.returncode != 0:
        raise SystemExit("provcheck --bite: rebuild failed\n" + r.stdout + r.stderr)


def _rebuilt(mutate):
    """Wrap a source mutation so the tree is rebuilt before AND after."""
    def go():
        undo = mutate()
        rebuild()

        def back():
            undo()
            rebuild()
        return back
    return go


def bite():
    ok = True
    # ---- P1: the enum's fail-closed value -------------------------------------
    ok &= _bite("PROV_UNSET renumbered off 0", "P1",
                _rebuilt(_patch(VERDICT_H, "PROV_UNSET = 0,", "PROV_UNSET = 7,")),
                r"PROV_UNSET|does not compile")
    # ---- P2: the AMD lane ------------------------------------------------------
    ok &= _bite("the x86 lane pointed back at the NVIDIA control map", "P2",
                _rebuilt(_patch(FRONT_ML, 'let control_map_csv = "control-map-amd.csv"',
                                'let control_map_csv = "control-map.csv"')),
                r"did not emit|ORACLE_UNSET|no expected-amd")
    ok &= _bite("the grade -> enum map made `derived' full strength", "P2",
                _rebuilt(_patch(ORACLE_ML,
                                '  | "artifact" -> "PROV_ARTIFACT"',
                                '  | "artifact" | "derived" -> "PROV_ARTIFACT"')),
                r"should emit PROV_CAPPED|Disallowed split|emit PROV_ARTIFACT")
    ok &= _bite("OMISSION: an expected-amd.csv row deleted", "P2",
                _drop_line(EXPECTED_AMD,
                           lambda l: l.startswith("IRIW-cgcc-sys-acqrel-2s,")),
                r"has no expected-amd.csv row|rows, pinned at|histogram",
                abort=r"generate-x86\.sh failed")
    # ---- P3: the NVIDIA lane ---------------------------------------------------
    ok &= _bite("a column-less oracle graded FULL instead of UNSET", "P3",
                _rebuilt(_patch(
                    ORACLE_ML, "  | Some g -> enum_of_grade g",
                    '  | Some g ->\n'
                    '     if t.has_prov then enum_of_grade g else "PROV_ARTIFACT"')),
                r"do NOT emit PROV_UNSET")
    ok &= _bite("OMISSION: the NO-COLUMN reason dropped", "P3",
                _rebuilt(_patch(ORACLE_ML, 'if not t.has_prov then "NO-COLUMN"',
                                'if not t.has_prov then "artifact"')),
                r"NO-COLUMN")
    # ---- P4: THE SENTENCES -----------------------------------------------------
    ok &= _bite("the capped sentence given the full-strength text", "P4",
                _rebuilt(_patch(VERDICT_H,
                                '"  ** CAPPED (provenance %s): this run DISAGREES WITH THE ARGUED ORACLE "',
                                '"  ** CANDIDATE CMCM REFUTATION (provenance %s): "')),
                r"prints the FULL sentence|does not print the CAPPED")
    ok &= _bite("OMISSION: the D10 branch deleted from the mismatch printer", "P4",
                _rebuilt(_patch(VERDICT_H, "    if (_r->cpu_only) {\n",
                                "    if (0 && _r->cpu_only) {\n")),
                r"does not print the D10 sentence|prints the (FULL|CAPPED) sentence")
    ok &= _bite("the CAMPAIGN block's grade switch removed", "P4",
                _rebuilt(_patch(VERDICT_H,
                                "    else if (_s->prov == PROV_ARTIFACT)",
                                "    else if (1 || _s->prov == PROV_ARTIFACT)")),
                r"STATS/.*does not print|prints the FULL sentence")
    # ---- P5: blanking --------------------------------------------------------
    ok &= _bite("an unreadable grade kept as full strength", "P5",
                _rebuilt(_patch(ORACLE_ML, '  | _ -> "PROV_UNSET"',
                                '  | _ -> "PROV_ARTIFACT"')),
                r"must fall to PROV_UNSET|STILL claims a candidate|does not say UNGRADED")
    # ---- P6: the D10 oracle ----------------------------------------------------
    ok &= _bite("a D10 verdict flipped against x86-TSO", "P6",
                _patch(GEN_D10, "SB:2:PodWR Fre PodWR Fre:Allowed:artifact",
                       "SB:2:PodWR Fre PodWR Fre:Disallowed:artifact"),
                r"the D10 oracle says SB-cpuonly")
    ok &= _bite("OMISSION: a D10 shape dropped from the generator", "P6",
                _drop_line(GEN_D10, lambda l: l.startswith("IRIW:4:")),
                r"missing from the generated D10 oracle|D10 oracle has \d+ rows",
                abort=r"generate-d10\.sh failed")
    # ---- P7: cpu_only ----------------------------------------------------------
    ok &= _bite("cpu_only forced to 0 in the emitter", "P7",
                _rebuilt(_patch(EMIT_ML, "(if cpu_only then 1 else 0)) ;",
                                "(if false && cpu_only then 1 else 0)) ;")),
                r"emits cpu_only")
    # ---- P8: B6c wiring --------------------------------------------------------
    ok &= _bite("the `none' sentinel read as a test name again", "P2",
                _rebuilt(_patch(os.path.join(ROOT, "litmus", "hetControlMap.ml"),
                                'when mu <> "-" && mu <> "none"', 'when mu <> "-"')),
                r"did not emit a harness|harnesses emitted")
    # Not "deleted" but MIS-INDEXED, which is the shape HET_ST_WIN_DESYNC exists
    # for and the one a structural grep is likeliest to miss: the bump is still
    # there, still writes the right array, and every window but 0 stays empty.
    ok &= _bite("the control's windowed sub-tally pinned to window 0", "P8",
                _rebuilt(_patch(EMIT_ML,
                                "_rec.%s[het_win_of(_f, SIZE_OF_TEST)]++",
                                "_rec.%s[0]++")),
                r"windowed=False|control must count the WINDOWED")
    ok &= _bite("OMISSION: a `none' row's Mu emptied in control-map-amd.csv", "P8",
                _patch(CONTROL_AMD,
                       "IRIW-cgcc-sys-relaxed,Disallowed,none,",
                       "IRIW-cgcc-sys-relaxed,Disallowed,-,"),
                r"pinned at 16|canary-only|co-run a mutant")
    # ---- P9: fail-closed -------------------------------------------------------
    ok &= _bite("the aarch64 lane pointed at the AMD oracle", "P9",
                _rebuilt(_patch(FRONT_ML, 'let oracle_csv = "expected-nvidia.csv"',
                                'let oracle_csv = "expected-amd.csv"')),
                r"", abort=r"carries Model|emitted no het_verdict\.h")
    ok &= _bite("the Model guard removed", "P9",
                _rebuilt(_patch(ORACLE_ML, "if mdl <> model then",
                                "if false && mdl <> model then")),
                r"did not make litmus7 refuse")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    if a.bite:
        ok = bite()
        print("\nPROVCHECK BITE %s" % ("OK (every injection reddened its own phase)"
                                       if ok else "FAILED"))
        return 0 if ok else 1
    f = main_run(a.quiet)
    print("\nPROVCHECK: %s" % ("PASS" if not f else "FAIL (%d)" % len(f)))
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
