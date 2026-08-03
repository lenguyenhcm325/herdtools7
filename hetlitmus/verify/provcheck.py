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
       indicting this oracle row first, never the CMCM."
      (verbatim from memo 9.2, markdown emphasis and section marks stripped,
       nothing else changed.)

THE DELIVERABLE IS THE SENTENCE, NOT THE ENUM (the B6c lesson, and this gate is
fixing that very class of defect, so phases 4 and 5 read the PRINTOUT of the real
emitted header compiled and run, never the source and never the enum).

FOUR MORE DEFECTS, MEASURED 2026-08-03 with every gate of the day GREEN, which
is why P10-P12 exist and why P4/P7 grew:

(3) The MACHINE-READABLE `prov=<CLASS>/<grade>' field -- the one campaign.py
    reads, and therefore the one that decides what an operator pastes into a
    report -- was asserted by NOTHING.  Making het_prov_class() return "FULL" for
    PROV_CAPPED made a capped row print `prov=FULL/decision', and campaign.py
    then reported "a CANDIDATE CMCM REFUTATION (provenance decision: the oracle
    row is anchored)".  Renaming the key to `xprov=' made campaign.py silently
    degrade every row to UNGRADED.  Both left all four gates green.  (P10)

(4) het_stats_compute's anti-laundering split (HET_ST_PROV_SPLIT) was
    CONSTANT-FALSE in every gate, because the P4 driver built its three cells as
    copies of ONE record.  Replacing the split with exactly the max() its own
    comment calls "the laundering bug" left all four gates green while the pooled
    block printed the full-strength sentence off two capped cells.  (P11)

(5) The prose was NVIDIA's on both lanes.  An AMD-tagged harness was told to
    report a NO-ORACLE row as "what GH200 does", called the interconnect halves
    "the Grace half" / "the Hopper half", said "same C2C path", and cited "On
    NVIDIA silicon an unstressed run observes nothing" as if it applied.  The
    emitted harness's own stderr warnings did the same -- OBSERVED as the first
    two lines of a real 2+2W-cpuonly-x86_64 run.  (P12, plus P2/P3)

(6) The "structurally absent stress" caveat asserted a BUILD fact from a CYCLE
    fact: it was keyed on cpu_only and said "HET_GPU_LANES is 0 ... Neither
    mechanism is counted as requested" -- false on the two D10 harnesses that
    carry a GPU observer lane, one line below their own config line printing
    stress_requested=0xd.  (P4, P7)

Twelve phases:

  P1 the enum        het_prov_t exists in the EMITTED header, PROV_UNSET is 0 and
                     first, and the strength order is UNSET < CAPPED < ARTIFACT
  P2 the AMD lane    the x86 corpus is tagged: census of oracle class x grade over
                     all 411, derived live from expected-amd.csv; and no emitted
                     stderr WARNING of an AMD-tagged harness names an NVIDIA part
  P3 the NVIDIA lane fails closed at PROV_UNSET/NO-COLUMN, its oracle CLASS
                     census is UNCHANGED (non-regression), and it STILL names its
                     own parts (the fix must be target-aware, not target-blind)
  P4 the sentences   four mutually exclusive mismatch texts, per-run AND campaign;
                     and the stress caveat READS the lane counts it asserts
  P5 blanking bites  blank the Provenance column, re-emit, recompile, and the
                     PRINTED SENTENCE changes from refutation to UNGRADED
  P6 D10 oracle      herd7 + x86tso.cat reproduces the D10 verdicts cell-for-cell,
                     and matches the PLDI'23 artifact's four CPU-Only rows
  P7 D10 reporting   cpu_only reaches the emitted harness and outranks the grade;
                     the lane counts are CARRIED into the record, and the D10 set
                     is measurably NOT uniform in them
  P8 B6c for AMD     Disallowed harnesses co-run their control; the 16 `none' rows
                     are canary-only BY DERIVATION; the control counts the WINDOWED
                     detector
  P9 fail-closed     unknown grade, absent row, and a wrong-vendor oracle
  P10 the field      `prov=<CLASS>/<grade>' on HetObs, HetVerdict AND HetStats, as
                     its own whitespace-delimited field; CLASS == f(grade); and
                     round-tripped through campaign.py, which must REFUSE a pair
                     no build can produce and must resolve DOWN when a later
                     invocation carries no grade at all
  P11 the split      a pooled block of DISAGREEING cells resolves DOWNWARD, cells
                     that AGREE do not, and cpu_only resolves upward
  P12 the prose      no other vendor's nouns in a printout tagged for this one,
                     across every reachable verdict arm, in BOTH directions

Every phase counts its assertions and FAILS if it made none -- the B6a
`exhaustive_valid'-constant-0 failure mode.  `--bite' injects into all twelve, on
CORRUPTION and on OMISSION, and requires the phase that owns the injected object
to redden naming it.  The injections edit TRACKED files, so a signal handler and
an atexit hook replay the pending undos: a --bite killed by a harness timeout on
2026-08-03 left the working tree one line short in het_verdict.h and one row
short in expected-amd.csv, and `git status' looked normal.
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
  /* The MACHINE-READABLE per-run line.  hetEmit.ml emits a call to this on every
     run and campaign.py's sibling parser reads the `prov=' field off the HetStats
     one; nothing gated either until P10. */
  printf("OBS-BEGIN|%s\n", name);
  het_obs_record_print(stdout, &r);
  printf("OBS-END|%s\n", name);
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

/* THREE CELLS THAT DO NOT AGREE.  one() above builds its three cells as copies of
   ONE record, so het_stats_compute's downward resolution (HET_ST_PROV_SPLIT) was
   constant-false in every gate: replacing it with the max() its own comment calls
   "the laundering bug" left all four gates green while the pooled block printed
   the full-strength sentence off two capped cells.  This is the driver that makes
   the branch reachable. */
static void pooled(const char *name, het_obs_record a, het_obs_record b,
                   het_obs_record c) {
  het_obs_record cells[3]; het_stats_t st;
  cells[0] = a; cells[0].run_id = 0;
  cells[1] = b; cells[1].run_id = 1;
  cells[2] = c; cells[2].run_id = 2;
  printf("MIXED-BEGIN|%s\n", name);
  het_stats_compute(cells, 3, &st);
  het_stats_print(stdout, &st);
  printf("MIXED-END|%s\n", name);
}

/* Strength order, checked at COMPILE time so it cannot be re-sorted quietly. */
typedef char _prov_order_check[(PROV_UNSET == 0
                                && PROV_UNSET < PROV_CAPPED
                                && PROV_CAPPED < PROV_ARTIFACT) ? 1 : -1];

int main(void) {
  printf("PROV_UNSET=%d PROV_CAPPED=%d PROV_ARTIFACT=%d\n",
         (int)PROV_UNSET, (int)PROV_CAPPED, (int)PROV_ARTIFACT);
__CASES__
__MIXED__
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
    # The BUILD facts behind the "structurally absent stress" caveat.  A het
    # harness has both lanes; the D10 cases below override them, because keying
    # that caveat on cpu_only made it assert HET_GPU_LANES=0 on two harnesses
    # where the emitter wrote 1.
    gpu_lanes=2, spin_lanes=2,
)

CASES = [
    ("full", dict(het_prov="PROV_ARTIFACT", het_prov_name='"artifact"')),
    ("capped-derived", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"')),
    ("capped-decision", dict(het_prov="PROV_CAPPED", het_prov_name='"decision"')),
    ("ungraded", dict(het_prov="PROV_UNSET", het_prov_name='"NO-COLUMN"')),
    ("ungraded-absent", dict(het_prov="PROV_UNSET", het_prov_name='"ABSENT"')),
    # D10 outranks the grade: even a full-strength CPU-only row must not print
    # the refutation sentence.  Lane counts are the MEASURED ones: MP/LB/SB/IRIW
    # -cpuonly emit 0/0, 2+2W/R-cpuonly emit 1/0 (a GPU observer lane).
    ("d10-full", dict(het_prov="PROV_ARTIFACT", het_prov_name='"artifact"',
                      cpu_only=1, obs_ws_via_cpu=1, gpu_lanes=0, spin_lanes=0)),
    ("d10-capped", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"',
                        cpu_only=1, obs_ws_via_cpu=1, gpu_lanes=0, spin_lanes=0)),
    # ...and a CPU-only sighting carried ONLY by the GPU observer is not even an
    # x86-TSO statement.  This is the 2+2W/R shape, so it is also the one whose
    # GPU stress lane is PRESENT while its window-opener is not.
    ("d10-gpu-observer", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"',
                              cpu_only=1, obs_ws_via_gpu=1, obs_ws_via_cpu=0,
                              gpu_lanes=1, spin_lanes=0)),
    # A HET harness (cpu_only=0) that nonetheless lost a stress lane.  This is
    # the case that separates the two possible keys for the structurally-absent
    # -stress caveat: keyed on cpu_only it prints NOTHING here, and the reader is
    # never told the null rests on less stress than the config line suggests --
    # while stress_requested legitimately withholds the request, so het_dead()
    # raises nothing either.  Keyed on the lane counts it says so.
    ("het-no-gpu-lane", dict(het_prov="PROV_CAPPED", het_prov_name='"derived"',
                             gpu_lanes=0, spin_lanes=2, gpu_stress_rounds=0)),
]

# ---------------------------------------------------------------------------
# M4 / P11: three cells that do NOT agree on the grade.  The record fields are
# spelled per cell, so the driver's `pooled()' gets a genuinely mixed block.
# ---------------------------------------------------------------------------
_FULL = dict(het_prov="PROV_ARTIFACT", het_prov_name='"artifact"')
_CAP = dict(het_prov="PROV_CAPPED", het_prov_name='"derived"')
_UNS = dict(het_prov="PROV_UNSET", het_prov_name='"NO-COLUMN"')

MIXED_CASES = [
    # The laundering case that matters: ONE full-strength cell among capped ones
    # must NOT lift the block to full strength.
    ("mix-cap-cap-full", (_CAP, _CAP, _FULL)),
    # ...and the reverse ordering, so the result cannot depend on cells[0].
    ("mix-full-cap-cap", (_FULL, _CAP, _CAP)),
    # An ungraded cell drags a graded block down too.
    ("mix-full-full-unset", (_FULL, _FULL, _UNS)),
    # cpu_only resolves UPWARD (the weaker claim about the compound model), so a
    # single CPU-only cell must put the whole block under the D10 sentence.
    ("mix-cpuonly-upward",
     (_FULL, _FULL, dict(_FULL, cpu_only=1, obs_ws_via_cpu=1,
                         gpu_lanes=0, spin_lanes=0))),
    # CONTROL: three cells that DO agree must NOT be split -- otherwise the
    # phase would pass on a header that split unconditionally.
    ("mix-all-full-agree", (_FULL, _FULL, _FULL)),
]


def c_record(extra):
    r = dict(BASE)
    r.update(extra)
    r.setdefault("oracle_source", '"expected-amd.csv:AMD-CDNA3-x86"')
    return ('(het_obs_record){ .test_name="synthetic", '
            + ", ".join(".%s=%s" % (k, v) for k, v in sorted(r.items())) + " }")


def build_driver(cases, mixed=()):
    body = "\n".join('  one("%s", %s);' % (n, c_record(e)) for n, e in cases)
    mix = "\n".join('  pooled("%s", %s, %s, %s);'
                    % ((n,) + tuple(c_record(e) for e in cells))
                    for n, cells in mixed)
    return C_MAIN.replace("__CASES__", body).replace("__MIXED__", mix)


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


def compile_and_run(tmp, header, cases, tag="drv", mixed=()):
    d = os.path.join(tmp, tag)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copy(header, os.path.join(d, "het_verdict.h"))
    src = os.path.join(d, "main.c")
    open(src, "w").write(build_driver(cases, mixed))
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
    # THE EMITTED HARNESS'S OWN stderr WARNINGS ARE PART OF THE PRINTOUT, and they
    # named the two halves of the interconnect noise after NVIDIA parts on every
    # lane.  MEASURED on a real run of 2+2W-cpuonly-x86_64: its first two lines
    # were "the Hopper half of the C2C noise is DISABLED" and "the Grace half ...
    # is DISABLED" on a harness tagged src=expected-amd.csv.  Scoped to the
    # PRINTED string literals -- source COMMENTS are allowed to name GH200,
    # because they document the emitter, not the run.
    probe = sorted(got)[0]
    cu = os.path.join(out, probe, probe + ".cu")
    src = open(cu).read() if os.path.exists(cu) else ""
    ck("P2", src != "", "no .cu to scan for vendor prose (%s)" % probe)
    prints = [l for l in src.splitlines()
              if ("printf(" in l or "fputs(" in l) and '"' in l]
    for l in prints:
        NASSERT["P2"] = NASSERT.get("P2", 0) + 1
        m = re.search(r"Grace|Hopper|GH200|NVLink|C2C", l)
        if m and "is not claimed for this target" not in l:
            fail("P2", "%s is an AMD-tagged harness but PRINTS %r: %s"
                 % (probe, m.group(0), " ".join(l.split())[:200]))
    NASSERT["P2"] = NASSERT.get("P2", 0) + 1
    if "host-device interconnect" not in src:
        fail("P2", "%s never says `host-device interconnect' -- the vendor noun was "
                   "deleted from the emitted warnings rather than replaced" % probe)
    # THE STRESS CAVEAT MUST STAY A DIAGNOSTIC, NOT BECOME BOILERPLATE.  It is
    # raised whenever a lane count is 0, so if a het harness ever emitted one it
    # would print on the whole corpus and stop meaning anything -- the failure
    # mode the CANARY_ONLY guard three screens up already documents.  MEASURED
    # 2026-08-03: 0 of 411 het harnesses have a zero lane count (all have
    # HET_GPU_LANES >= 2 and HET_SPIN_LANES >= 2), against 6 of 6 in the D10 set.
    nolane = []
    for n in sorted(got):
        f = os.path.join(out, n, n + ".cu")
        if not os.path.exists(f):
            continue
        t = open(f).read()
        g = re.search(r"^#define HET_GPU_LANES (\d+)$", t, re.M)
        p = re.search(r"^#define HET_SPIN_LANES (\d+)$", t, re.M)
        if not g or not p:
            nolane.append((n, "no lane #define at all"))
        elif int(g.group(1)) == 0 or int(p.group(1)) == 0:
            nolane.append((n, "%s/%s" % (g.group(1), p.group(1))))
    ck("P2", not nolane,
       "%d het harness(es) emit a ZERO lane count (%r) -- the D10 "
       "structurally-absent-stress caveat would print on them too, and a caveat "
       "that prints on the whole corpus is boilerplate, not a diagnostic"
       % (len(nolane), nolane[:3]))
    print("     411 emitted, 0 ORACLE_UNSET; grades %d FULL / %d CAPPED; "
          "Disallowed %d full / %d capped; no NVIDIA prose in the emitted warnings"
          % (n_full, n_capped, dis_full, dis_capped))
    return out, got


def _phase3_vendor(out, got):
    """...and the NVIDIA lane must STILL name its own parts.  Without this the
    fix above would pass just as well if the emitter had gone target-BLIND."""
    probe = sorted(got)[0]
    cu = os.path.join(out, probe, probe + ".cu")
    src = open(cu).read() if os.path.exists(cu) else ""
    ck("P3", src != "", "no .cu to scan for vendor prose (%s)" % probe)
    for tok in ("the Grace half", "the Hopper half", "NVLink-C2C"):
        NASSERT["P3"] = NASSERT.get("P3", 0) + 1
        if tok not in src:
            fail("P3", "%s is an NVIDIA-tagged harness but its emitted warnings never "
                       "say %r -- the emitter is target-BLIND, not target-aware"
                 % (probe, tok))
    NASSERT["P3"] = NASSERT.get("P3", 0) + 1
    if "host-device interconnect" in src:
        fail("P3", "%s prints the GENERIC interconnect noun on the NVIDIA lane -- the "
                   "target test is not reaching the emitted warnings" % probe)


def phase3(tmp):
    print("== P3  the NVIDIA lane fails closed, and its CLASS census is untouched ==")
    rows, has_prov = read_csv(EXPECTED_NV)
    ck("P3", not has_prov,
       "expected-nvidia.csv now HAS a Provenance column -- NV-PROV landed and this "
       "phase (and P2d's fail-closed reading of the NVIDIA lane) must be revisited")
    tests = sorted(f for f in os.listdir(HET_DIR) if f.endswith(".litmus"))
    out, got, refused = emit_corpus(tmp, HET_DIR, "nv", tests)
    ck("P3", not refused, "%d aarch64 test(s) refused: %r" % (len(refused), refused[:2]))
    _phase3_vendor(out, got)
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
        "het-no-gpu-lane": "CAPPED",
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
    # ---- THE STRESS CAVEAT MUST STATE THE BUILD, NOT ASSUME IT.  It used to be
    # keyed on cpu_only and to assert "HET_GPU_LANES is 0 ... Neither mechanism is
    # counted as requested" on every CPU-only harness -- false on the two that
    # carry a GPU observer lane, and printed one line below a config line saying
    # stress_requested included HET_REQ_GPU_STRESS.
    both = b.get("d10-full", "")             # gpu_lanes=0 spin_lanes=0
    one = b.get("d10-gpu-observer", "")      # gpu_lanes=1 spin_lanes=0
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "HET_GPU_LANES=0 HET_SPIN_LANES=0" not in both:
        fail("P4", "the D10 stress caveat does not PRINT the lane counts on a 0/0 "
                   "harness -- an unprintable build claim is an unverifiable one")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "HET_GPU_LANES=1 HET_SPIN_LANES=0" not in one:
        fail("P4", "a harness with HET_GPU_LANES=1 does not print that -- the caveat "
                   "is still asserting the count instead of reading it")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the GPU scratchpad stress" not in both:
        fail("P4", "the 0/0 caveat does not name the GPU scratchpad stress as absent")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the GPU scratchpad stress" in one:
        fail("P4", "a harness with a LIVE GPU stress lane is told its GPU scratchpad "
                   "stress is structurally absent -- that excuses a zero tally the "
                   "run has no excuse for")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the OTHER mechanism is present" not in one:
        fail("P4", "the caveat does not say which mechanism IS present on a 1/0 "
                   "harness, so a reader cannot tell what the zero tally excuses")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the OTHER mechanism is present" in both:
        fail("P4", "the 0/0 harness claims a mechanism is present -- both are absent "
                   "there")
    # ...and a het harness (both lanes live) must not get the caveat at all, or it
    # is boilerplate rather than a diagnostic.
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "CAVEAT (D10): HET_GPU_LANES" in b.get("full", ""):
        fail("P4", "a het harness with both lanes live still prints the "
                   "structurally-absent-stress caveat")
    # THE CASE THAT SEPARATES THE TWO KEYS.  cpu_only=0, but a stress lane is
    # gone: keyed on cpu_only nothing is printed and the missing mechanism is
    # invisible; keyed on the lane counts it is named.
    nol = b.get("het-no-gpu-lane", "")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "CAVEAT (D10): HET_GPU_LANES=0 HET_SPIN_LANES=2" not in nol:
        fail("P4", "a harness with HET_GPU_LANES=0 and cpu_only=0 prints NO "
                   "structurally-absent-stress caveat -- the flag is still keyed on "
                   "the CYCLE (cpu_only) instead of on the BUILD (the lane counts), "
                   "so a het harness that lost its GPU lane says nothing about it")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the GPU scratchpad stress" not in nol:
        fail("P4", "the caveat does not name the GPU scratchpad stress as the absent "
                   "mechanism on a 0/2 harness")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if "the OTHER mechanism is present (window-opener" not in nol:
        fail("P4", "the caveat does not name the window-opener as the PRESENT "
                   "mechanism on a 0/2 harness")
    NASSERT["P4"] = NASSERT.get("P4", 0) + 1
    if S_D10 in nol:
        fail("P4", "a harness with cpu_only=0 printed the CPU-ONLY CYCLE sentence -- "
                   "the lane-count caveat has leaked into the D10 frame")
    print("     4 sentences x 8 cases x 2 printers, mutually exclusive; grades named; "
          "the stress caveat reads the lane counts")


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


# The MEASURED lane census of the D10 set (2026-08-03, litmus7 at this HEAD).
# It is NOT uniform, and that is the whole point: the "structurally absent
# stress" caveat used to be keyed on cpu_only and therefore asserted
# "HET_GPU_LANES is 0 ... neither mechanism is counted as requested" on the two
# harnesses that carry a GPU observer lane and DO request GPU stress -- with
# their own config line printing stress_requested=0xd on the next line up.
D10_LANES = {
    "2+2W-cpuonly-x86_64": (1, 0), "R-cpuonly-x86_64": (1, 0),
    "IRIW-cpuonly-x86_64": (0, 0), "LB-cpuonly-x86_64": (0, 0),
    "MP-cpuonly-x86_64": (0, 0), "SB-cpuonly-x86_64": (0, 0),
}


def _phase7_lanes(out, got):
    """The lane counts the caveat asserts must be CARRIED, not inferred."""
    for n in sorted(got):
        cu = os.path.join(out, n, n + ".cu")
        src = open(cu).read() if os.path.exists(cu) else ""
        NASSERT["P7"] = NASSERT.get("P7", 0) + 1
        if "_rec.gpu_lanes = HET_GPU_LANES;" not in src \
           or "_rec.spin_lanes = HET_SPIN_LANES;" not in src:
            fail("P7", "%s does not carry its lane counts into the record -- the "
                       "D10 stress caveat would be asserting a build fact it "
                       "cannot see" % n)
        d = {}
        for k in ("HET_GPU_LANES", "HET_SPIN_LANES"):
            m = re.search(r"^#define %s (\d+)$" % k, src, re.M)
            d[k] = int(m.group(1)) if m else None
        NASSERT["P7"] = NASSERT.get("P7", 0) + 1
        if n in D10_LANES and (d["HET_GPU_LANES"], d["HET_SPIN_LANES"]) != D10_LANES[n]:
            fail("P7", "%s emits HET_GPU_LANES=%r HET_SPIN_LANES=%r, measured %r"
                 % (n, d["HET_GPU_LANES"], d["HET_SPIN_LANES"], D10_LANES[n]))
    # The census must not be uniform, or keying the caveat on cpu_only would be
    # harmless again and this whole check would be decoration.
    nz = sum(1 for n in got if D10_LANES.get(n, (0, 0))[0] > 0)
    ck("P7", nz == 2,
       "%d of the %d D10 harnesses carry a GPU lane, expected 2 -- if this ever "
       "reaches 0 the cpu_only shortcut becomes true by accident and the caveat's "
       "claim stops being checkable" % (nz, len(got)))


def phase7(tmp, d10dir, x86got):
    print("== P7  D10 reaches the harness, and cpu_only outranks the grade ==")
    out, got, refused = emit_corpus(tmp, d10dir, "d10")
    ck("P7", not refused, "D10 test(s) refused: %r" % (refused[:3],))
    ck("P7", len(got) == len(D10),
       "%d D10 harnesses emitted, expected %d" % (len(got), len(D10)))
    _phase7_lanes(out, got)
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


# ---------------------------------------------------------------------------
# P10.  The MACHINE-READABLE `prov=<CLASS>/<grade>' field.
#
# The prose sentences were gated from the start; the field a TOOL reads was not,
# and it is the one that decides what campaign.py prints.  MEASURED 2026-08-03,
# with every other gate green in both cases:
#   * CORRUPTION -- het_prov_class(PROV_CAPPED) returning "FULL" made a capped
#     row print `prov=FULL/decision', and campaign.py then reported "a CANDIDATE
#     CMCM REFUTATION (provenance decision: the oracle row is anchored)".
#   * OMISSION -- renaming `prov=' to `xprov=' in the HetStats format string made
#     campaign.py silently degrade every row to UNGRADED.
# So the field is asserted on ALL THREE printed lines, and then round-tripped
# through campaign.py's own parser, which is the consumer that matters.
# ---------------------------------------------------------------------------
def phase10(tmp, header):
    print("== P10 the MACHINE-READABLE prov=<CLASS>/<grade> field, and its reader ==")
    out, blob = compile_and_run(tmp, header, CASES, "p10")
    if not ck("P10", out is not None,
              "driver did not compile:\n" + (blob or "")[-1200:]):
        return
    want = {
        "full": ("FULL", "artifact"),
        "capped-derived": ("CAPPED", "derived"),
        "capped-decision": ("CAPPED", "decision"),
        "ungraded": ("UNSET", "NO-COLUMN"),
        "ungraded-absent": ("UNSET", "ABSENT"),
        "d10-full": ("FULL", "artifact"),
        "d10-capped": ("CAPPED", "derived"),
        "d10-gpu-observer": ("CAPPED", "derived"),
        "het-no-gpu-lane": ("CAPPED", "derived"),
    }
    # (a) the three printed lines each carry the field, with the RIGHT value.
    lines = {"OBS": "HetObs ", "PRINT": "HetVerdict ", "STATS": "HetStats "}
    for kind, prefix in sorted(lines.items()):
        b = blocks(out, kind)
        for name, (cls, grade) in sorted(want.items()):
            txt = b.get(name, "")
            ln = [l for l in txt.splitlines() if l.startswith(prefix)]
            NASSERT["P10"] = NASSERT.get("P10", 0) + 1
            if not ln:
                fail("P10", "%s block of %s has no %r line at all" % (kind, name, prefix))
                continue
            NASSERT["P10"] = NASSERT.get("P10", 0) + 1
            # DELIMITED, not a bare substring: `xprov=CAPPED/decision' CONTAINS
            # `prov=CAPPED/decision', so a plain `in' test passed the exact
            # OMISSION injection this phase exists to catch (renaming the key).
            # MEASURED: that bite reported "P10 did not fail at all".
            if not re.search(r"(?:^|\s)prov=%s(?:\s|$)"
                             % re.escape("%s/%s" % (cls, grade)), ln[0]):
                fail("P10", "%s line of %s does not carry prov=%s/%s as its own "
                            "whitespace-delimited field -- a tool reading this line "
                            "cannot tell a capped row from a full-strength one.  "
                            "It said: %s"
                     % (prefix.strip(), name, cls, grade, ln[0][:220]))
    # (b) the CLASS is a function of the GRADE.  "FULL" is licensed by `artifact'
    # and by nothing else (hetOracle.ml enum_of_grade), so a line that pairs FULL
    # with any other grade is self-contradictory whatever else is right.
    for kind in sorted(lines):
        for name, txt in sorted(blocks(out, kind).items()):
            for m in re.finditer(r"(?:^|\s)prov=(\w+)/(\S+)", txt):
                NASSERT["P10"] = NASSERT.get("P10", 0) + 1
                if (m.group(1) == "FULL") != (m.group(2) in FULL_GRADES):
                    fail("P10", "%s/%s printed prov=%s/%s: FULL is licensed by %s and "
                                "by nothing else"
                         % (kind, name, m.group(1), m.group(2),
                            "/".join(sorted(FULL_GRADES))))
    # (c) THE CONSUMER.  campaign.py's parser must recover the same pair off the
    # real HetStats line, and must refuse a line whose halves disagree.
    camp = load_campaign()
    if camp is None:
        fail("P10", "hetlitmus/campaign.py did not import (%s) -- the field's only "
                    "consumer cannot be checked, so this phase is not a phase"
             % CAMPAIGN_WHY[0][:200])
        return
    NASSERT["P10"] = NASSERT.get("P10", 0) + 1
    if set(camp.FULL_GRADES) != set(FULL_GRADES):
        fail("P10", "campaign.py mirrors FULL_GRADES=%r, this gate uses %r"
             % (sorted(camp.FULL_GRADES), sorted(FULL_GRADES)))
    for name, (cls, grade) in sorted(want.items()):
        stats = blocks(out, "STATS").get(name, "")
        got = camp.parse_hetstats(stats)
        NASSERT["P10"] = NASSERT.get("P10", 0) + 1
        if got is None:
            fail("P10", "campaign.py could not parse the HetStats line of %s" % name)
            continue
        st = camp.TestState(got[0], "Disallowed")
        st.absorb(got[1])
        NASSERT["P10"] = NASSERT.get("P10", 0) + 1
        if (st.prov, st.grade) != (cls, grade):
            fail("P10", "campaign.py read %s as prov=%s/%s, the line says %s/%s"
                 % (name, st.prov, st.grade, cls, grade))
    # ...and the self-contradictory line must ERROR rather than be believed.  This
    # is the exact shape of the corruption that produced a false refutation.
    liar = blocks(out, "STATS")["capped-decision"].replace(
        "prov=CAPPED/decision", "prov=FULL/decision")
    got = camp.parse_hetstats(liar)
    NASSERT["P10"] = NASSERT.get("P10", 0) + 1
    if got is None:
        fail("P10", "the doctored HetStats line no longer parses -- the refusal "
                    "below would pass for the wrong reason")
    else:
        st = camp.TestState("liar", "Disallowed")
        st.absorb(got[1])
        NASSERT["P10"] = NASSERT.get("P10", 0) + 1
        if st.stop != "ERROR":
            fail("P10", "campaign.py BELIEVED prov=FULL/decision (stop=%r prov=%s/%s) "
                        "-- a class/grade pair that no build can produce must not "
                        "license the strongest sentence" % (st.stop, st.prov, st.grade))
    # ...and a later invocation carrying NO grade must drag a graded row DOWN.
    st = camp.TestState("mixedbin", "Disallowed")
    st.absorb(camp.parse_hetstats(blocks(out, "STATS")["full"])[1])
    st.absorb({"R": "1"})                    # an old binary: no prov= at all
    NASSERT["P10"] = NASSERT.get("P10", 0) + 1
    if (st.prov, st.grade) != ("UNSET", "SPLIT"):
        fail("P10", "an invocation with NO prov= pooled after a graded one left the "
                    "grade at %s/%s -- the ungraded direction must resolve DOWN too"
             % (st.prov, st.grade))
    print("     prov= on HetObs/HetVerdict/HetStats x 8 cases, class==f(grade), "
          "round-tripped through campaign.py (and its refusals bite)")


# ---------------------------------------------------------------------------
# P11.  THE POOLED GRADE RESOLVES DOWNWARD (het_stats_compute HET_ST_PROV_SPLIT).
# Untested until now, and not by accident: the P4 driver builds its three cells
# as copies of ONE record, so the split branch was constant-false.  MEASURED:
# replacing it with the max() its own comment calls "the laundering bug" left all
# four gates green while the pooled block printed "FULL STRENGTH ... CANDIDATE
# CMCM REFUTATION" off two capped cells.
# ---------------------------------------------------------------------------
def phase11(tmp, header):
    print("== P11 a pooled block of DISAGREEING cells resolves DOWNWARD ==")
    out, blob = compile_and_run(tmp, header, CASES[:1], "p11", mixed=MIXED_CASES)
    if not ck("P11", out is not None,
              "driver did not compile:\n" + (blob or "")[-1200:]):
        return
    b = blocks(out, "MIXED")
    ck("P11", set(b) == set(n for n, _ in MIXED_CASES),
       "MIXED blocks %r != cases %r" % (sorted(b), sorted(n for n, _ in MIXED_CASES)))
    for name in ("mix-cap-cap-full", "mix-full-cap-cap", "mix-full-full-unset"):
        txt = b.get(name, "")
        NASSERT["P11"] = NASSERT.get("P11", 0) + 1
        if "prov=UNSET/SPLIT" not in txt:
            fail("P11", "%s pooled cells of DIFFERENT grades but printed no "
                        "prov=UNSET/SPLIT -- the block laundered the cap.  It said: %s"
                 % (name, " | ".join(l for l in txt.splitlines()
                                     if l.startswith("HetStats "))[:220]))
        NASSERT["P11"] = NASSERT.get("P11", 0) + 1
        if S_UNGRADED not in txt:
            fail("P11", "%s does not print the UNGRADED sentence; it printed:\n%s"
                 % (name, txt[:700]))
        NASSERT["P11"] = NASSERT.get("P11", 0) + 1
        if S_FULL in txt:
            fail("P11", "%s STILL prints %r off a block whose cells disagree"
                 % (name, S_FULL))
    # cpu_only resolves UPWARD, and it outranks whatever the grade resolved to.
    txt = b.get("mix-cpuonly-upward", "")
    NASSERT["P11"] = NASSERT.get("P11", 0) + 1
    if "cpu_only=1" not in txt:
        fail("P11", "one CPU-only cell among het cells did not set cpu_only on the "
                    "pooled block -- the D10 sentence would be lost by pooling")
    NASSERT["P11"] = NASSERT.get("P11", 0) + 1
    if S_D10 not in txt:
        fail("P11", "the pooled block of a mix containing a CPU-only cell does not "
                    "print the D10 sentence; it printed:\n%s" % txt[:700])
    NASSERT["P11"] = NASSERT.get("P11", 0) + 1
    if S_FULL in txt:
        fail("P11", "a pooled block containing a CPU-only cell still prints %r"
             % S_FULL)
    # CONTROL: agreeing cells must NOT be split, or the phase would pass on a
    # header that split everything.
    txt = b.get("mix-all-full-agree", "")
    NASSERT["P11"] = NASSERT.get("P11", 0) + 1
    if "prov=FULL/artifact" not in txt:
        fail("P11", "three AGREEING artifact cells did not pool to prov=FULL/artifact "
                    "-- the split is firing on cells that agree, which would cap "
                    "every campaign")
    NASSERT["P11"] = NASSERT.get("P11", 0) + 1
    if S_FULL not in txt:
        fail("P11", "three AGREEING artifact cells do not print the full-strength "
                    "sentence -- the strongest claim has become unreachable")
    print("     3 disagreeing mixes -> UNSET/SPLIT + UNGRADED, cpu_only upward, "
          "agreeing cells still FULL")


# ---------------------------------------------------------------------------
# P12.  NO VENDOR-SPECIFIC PROSE ON THE OTHER VENDOR'S LANE.
# MEASURED on real AMD-tagged runs: the printer told the reader to report a
# NO-ORACLE row as "what GH200 does", named the interconnect halves "the Grace
# half" / "the Hopper half", said "same C2C path", and cited "On NVIDIA silicon
# an unstressed run observes nothing" as if it applied to an MI300A.
#
# SCOPE, stated rather than widened: the search runs over the PRINTOUT of
# het_verdict.h driven with an AMD-tagged record, across every reachable verdict
# arm.  ONE allowance, and it is a literal string, not a loosened pattern:
# Alglave's fn.7 sentence names the GTX 280 inside a VERBATIM QUOTE of a
# published measurement, which is a citation and not a claim about this target.
# Not in scope here (checked at emission instead, and disclosed): the CUDA-only
# allocator/noise includes (het_alloc_cuda.inc, het_noise_cuda.inc), which are
# not compiled into a HIP harness at all.
# ---------------------------------------------------------------------------
NV_TOKENS = re.compile(r"Grace|Hopper|GH200|NVLink|C2C|NVIDIA|Nvidia", re.I)
# THE ONLY ALLOWANCES, enumerated as EXACT literals and each with its reason.
# Both are ATTRIBUTED statements about somebody else's measurement, not claims
# about the target: one is a verbatim quotation, the other exists precisely to
# say the NVIDIA figure does NOT transfer.  A literal list rather than a widened
# pattern, and each entry is required to be PRESENT below -- an allowance that
# stops matching anything is an allowance that has quietly become a hole.
NV_QUOTED_OK = [
    # Alglave et al., ASPLOS'15 fn.7 p.577, quoted verbatim in the
    # ALLOWED-UNOBSERVED arm as the precedent for reporting a null honestly.
    "Nvidia GTX 280 chip they used.",
    # The NON-claim: printed on the NON-NVIDIA lane in place of "On NVIDIA
    # silicon an unstressed run observes nothing", which would have been a
    # borrowed number.
    "was measured on NVIDIA parts and is NOT claimed for this target",
]

# Every verdict arm, reached by moving fields of BASE.  A phase that printed only
# the MISMATCH arm would have missed all five of the strings above.
ARMS = [
    ("mismatch", {}),
    ("allowed-observed", dict(het_oracle="ORACLE_ALLOWED")),
    ("characterized", dict(het_oracle="ORACLE_NONE")),
    ("allowed-unobserved", dict(het_oracle="ORACLE_ALLOWED",
                                target_count_exhaustive=0,
                                target_count_heuristic=0)),
    # COLD-INVALID with EVERY dq bit lit: this is the arm that carried three of
    # the five strings, and it is only reachable with the mechanisms requested
    # and dead at the same time.
    ("cold-all-dead", dict(target_count_exhaustive=0, target_count_heuristic=0,
                           interleavings_detected=0,
                           control_target_count=0, canary_target_count=0,
                           control_win="{0}", canary_win="{0}",
                           spin_rendezvous=0, spin_cap=0, gpu_stress_rounds=0,
                           cpu_enemy_rounds=0, cpu_preload_ops=0,
                           noise_cpu_rounds=0, noise_gpu_blocks=0,
                           stress_truncated=7)),
    # a null on a live harness (CREDIBLE / WEAK), canary-only
    ("weak-null", dict(target_count_exhaustive=0, target_count_heuristic=0,
                       control_target_count=0, control_win="{0}")),
]


def phase12(tmp, header):
    print("== P12 no other vendor's prose on this lane (both directions) ==")
    amd = '"expected-amd.csv:AMD-CDNA3-x86"'
    nv = '"expected-nvidia.csv:NVIDIA-PTX-AArch64"'
    cases_amd = [("amd-" + n, dict(e, oracle_source=amd)) for n, e in ARMS]
    cases_nv = [("nv-" + n, dict(e, oracle_source=nv)) for n, e in ARMS]
    out, blob = compile_and_run(tmp, header, cases_amd + cases_nv, "p12")
    if not ck("P12", out is not None,
              "driver did not compile:\n" + (blob or "")[-1200:]):
        return
    for kind in ("PRINT", "STATS"):
        b = blocks(out, kind)
        for name, _e in cases_amd:
            txt = b.get(name, "")
            NASSERT["P12"] = NASSERT.get("P12", 0) + 1
            if not txt:
                fail("P12", "%s/%s printed NOTHING -- an arm that prints nothing "
                            "cannot be checked for anything" % (kind, name))
                continue
            scan = txt
            for ok in NV_QUOTED_OK:
                scan = scan.replace(ok, "<verbatim-citation>")
            for m in NV_TOKENS.finditer(scan):
                line = scan[scan.rfind("\n", 0, m.start()) + 1:
                            scan.find("\n", m.end()) % (len(scan) + 1) or len(scan)]
                NASSERT["P12"] = NASSERT.get("P12", 0) + 1
                fail("P12", "%s/%s is tagged src=expected-amd.csv but its printout "
                            "says %r: %s"
                     % (kind, name, m.group(0), " ".join(line.split())[:200]))
    # NON-VACUITY, both ways: the NVIDIA lane must STILL name its own parts, or
    # this phase would pass just as well on a printer that says nothing at all.
    nvtxt = "\n".join(blocks(out, "PRINT").get(n, "") for n, _e in cases_nv) \
        + "\n".join(blocks(out, "STATS").get(n, "") for n, _e in cases_nv)
    for tok in ("Grace", "Hopper", "NVLink-C2C", "NVIDIA"):
        NASSERT["P12"] = NASSERT.get("P12", 0) + 1
        if tok not in nvtxt:
            fail("P12", "the NVIDIA-tagged printout never says %r -- the prose has "
                        "been made target-BLIND rather than target-AWARE, and this "
                        "phase would pass on an empty printer" % tok)
    # ...and the AMD lane must positively say the generic thing, not merely omit.
    amdtxt = "\n".join(blocks(out, "PRINT").get(n, "") for n, _e in cases_amd)
    for tok in ("host-device interconnect", "expected-amd.csv:AMD-CDNA3-x86"):
        NASSERT["P12"] = NASSERT.get("P12", 0) + 1
        if tok not in amdtxt:
            fail("P12", "the AMD-tagged printout never says %r -- the vendor noun was "
                        "deleted rather than replaced" % tok)
    # EVERY ALLOWANCE MUST BE EXERCISED.  An entry of NV_QUOTED_OK that matches
    # nothing is not a harmless leftover: it is a standing permission nobody is
    # watching, and the next NVIDIA sentence to drift into that arm inherits it.
    amdall = amdtxt + "\n".join(blocks(out, "STATS").get(n, "") for n, _e in cases_amd)
    for ok in NV_QUOTED_OK:
        NASSERT["P12"] = NASSERT.get("P12", 0) + 1
        if ok not in amdall:
            fail("P12", "the allowance %r matched nothing in the AMD-tagged printout "
                        "-- it is now a blanket permission with no object.  Delete it "
                        "or re-reach the arm that used it." % ok)
    print("     %d verdict arms x 2 printers x 2 lanes; NVIDIA prose only on the "
          "NVIDIA lane, generic prose on the other" % len(ARMS))


CAMPAIGN_WHY = [""]


def load_campaign():
    """hetlitmus/campaign.py as a module -- it is the reader of `prov='.

    BaseException, not Exception: campaign.py's own import-time mirror checks
    call die(), which raises SystemExit.  Letting that escape would abort the
    WHOLE gate at this phase instead of reddening it, which is how an injection
    into hetOracle.ml ended a --bite run early on 2026-08-03.
    """
    try:
        import importlib.util
        p = os.path.join(ROOT, "hetlitmus", "campaign.py")
        spec = importlib.util.spec_from_file_location("het_campaign_probe", p)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m
    except BaseException as e:                            # noqa: BLE001
        CAMPAIGN_WHY[0] = repr(e)
        return None


FULL_GRADES = frozenset(["artifact"])


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
        phase10(tmp, header)
        phase11(tmp, header)
        phase12(tmp, header)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # NON-VACUITY: a phase that compared nothing is not a phase that passed.
    for p in ("P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "P9",
              "P10", "P11", "P12"):
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


# --bite MUTATES TRACKED FILES IN PLACE, including hetlitmus/tests/het/
# expected-amd.csv (the P2 omission injection deletes a row from the committed
# oracle).  The undo lives in a `finally', which covers an exception but NOT a
# signal -- and that is not hypothetical: a 10-minute harness timeout killed a
# --bite run mid-injection on 2026-08-03 and left the oracle one row short in the
# working tree.  So the pending undos are also registered here and replayed from
# a signal handler and from atexit.
_PENDING = []


def _run_undos():
    while _PENDING:
        try:
            _PENDING.pop()()
        except BaseException as e:                        # noqa: BLE001
            # BaseException on purpose: rebuild() raises SystemExit, and a
            # half-done restore must not stop the remaining ones.
            print("provcheck --bite: an undo FAILED (%r) -- CHECK `git status'" % e)


def _install_undo_trap():
    import atexit
    import signal
    atexit.register(_run_undos)

    def onsig(sig, _frm):
        print("\nprovcheck --bite: caught signal %d -- restoring the tree before "
              "exiting (the injections edit TRACKED files)." % sig)
        _run_undos()
        # Re-raise as the default action so the exit status still says "killed".
        signal.signal(sig, signal.SIG_DFL)
        os.kill(os.getpid(), sig)

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(s, onsig)
        except (ValueError, AttributeError, OSError):
            pass


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
    _PENDING.append(undo)
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
        if undo in _PENDING:
            _PENDING.remove(undo)
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
    _install_undo_trap()
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
    # The abort path is the EXPECTED outcome here (litmus7's Model guard stands
    # earlier than this gate), but `want' is spelled out anyway: an empty pattern
    # would have accepted a P9 failure for ANY reason at all if the guard ever
    # stopped aborting.
    ok &= _bite("the aarch64 lane pointed at the AMD oracle", "P9",
                _rebuilt(_patch(FRONT_ML, 'let oracle_csv = "expected-nvidia.csv"',
                                'let oracle_csv = "expected-amd.csv"')),
                r"carries Model|did not make litmus7 refuse|PROV_UNSET",
                abort=r"carries Model|emitted no het_verdict\.h")
    ok &= _bite("the Model guard removed", "P9",
                _rebuilt(_patch(ORACLE_ML, "if mdl <> model then",
                                "if false && mdl <> model then")),
                r"did not make litmus7 refuse")
    # ---- P4: the stress caveat's BUILD claim -----------------------------------
    # The exact defect P2d shipped: the flag keyed on the CYCLE, so it asserted
    # HET_GPU_LANES=0 where the emitter had written 1 and said nothing at all on a
    # het harness that had lost a lane.
    ok &= _bite("the stress caveat keyed back on cpu_only", "P4",
                _rebuilt(_patch(VERDICT_H,
                                "  if (r->gpu_lanes == 0 || r->spin_lanes == 0)\n"
                                "                                    cv |= HET_CV_NO_GPU_LANES;",
                                "  if (r->cpu_only)                  cv |= HET_CV_NO_GPU_LANES;")),
                r"prints NO structurally-absent-stress caveat")
    ok &= _bite("OMISSION: the caveat stops saying what is PRESENT", "P4",
                _rebuilt(_patch(VERDICT_H,
                                "    if (_r->gpu_lanes > 0 || _r->spin_lanes > 0)",
                                "    if (0)")),
                r"does not say which mechanism IS present|does not name the "
                r"window-opener as the PRESENT")
    # ---- P10: the machine-readable field ---------------------------------------
    # CORRUPTION.  MEASURED with every other gate green: a capped row printed
    # prov=FULL/decision and campaign.py called it a CANDIDATE CMCM REFUTATION.
    ok &= _bite("het_prov_class() calls a CAPPED row FULL", "P10",
                _rebuilt(_patch(VERDICT_H, '  case PROV_CAPPED:   return "CAPPED";',
                                '  case PROV_CAPPED:   return "FULL";')),
                r"does not carry prov=CAPPED|FULL is licensed by|read .* as prov=FULL")
    # OMISSION.  The field renamed out of the line a tool reads: every sentence
    # stays right and campaign.py silently degrades every row to UNGRADED.
    ok &= _bite("OMISSION: prov= renamed on the HetStats line", "P10",
                _rebuilt(_patch(VERDICT_H,
                                '    "HetStats %s oracle=%s prov=%s/%s cpu_only=%d obs=%s "',
                                '    "HetStats %s oracle=%s xprov=%s/%s cpu_only=%d obs=%s "')),
                r"HetStats line of .* does not carry prov=|campaign.py read")
    ok &= _bite("OMISSION: prov= renamed on the per-run HetObs line", "P10",
                _rebuilt(_patch(VERDICT_H,
                                '    "HetObs %s oracle=%s prov=%s/%s src=%s cpu_only=%d "',
                                '    "HetObs %s oracle=%s xprov=%s/%s src=%s cpu_only=%d "')),
                r"HetObs line of .* does not carry prov=")
    # ---- P11: the anti-laundering split ----------------------------------------
    # THE LAUNDERING BUG, spelled exactly as the code's own comment names it.
    ok &= _bite("the pooled grade resolved UPWARD (max) instead of down", "P11",
                _rebuilt(_patch(VERDICT_H,
                                "        st->flags |= HET_ST_PROV_SPLIT;\n"
                                "        st->prov = PROV_UNSET;\n"
                                "        st->prov_name = \"SPLIT\";",
                                "        if (recs[_i].het_prov > st->prov) {\n"
                                "          st->prov = recs[_i].het_prov;\n"
                                "          st->prov_name = recs[_i].het_prov_name; }")),
                r"laundered the cap|STILL prints|does not print the UNGRADED")
    ok &= _bite("OMISSION: the split stops downgrading the class", "P11",
                _rebuilt(_patch(VERDICT_H, "        st->prov = PROV_UNSET;\n", "")),
                r"laundered the cap|STILL prints")
    ok &= _bite("OMISSION: cpu_only stops resolving upward across cells", "P11",
                _rebuilt(_patch(VERDICT_H,
                                "        if (recs[_i].cpu_only) st->cpu_only = 1;",
                                "        if (0) st->cpu_only = 1;")),
                r"did not set cpu_only on the pooled block|does not print the D10")
    # ---- P12: the other vendor's prose -----------------------------------------
    ok &= _bite("the interconnect named NVLink-C2C on every lane", "P12",
                _rebuilt(_patch(VERDICT_H,
                                'return het_src_is_nvidia(src) ? "NVLink-C2C" : "host-device interconnect";',
                                'return "NVLink-C2C";')),
                r"its printout says .(C2C|NVLink)")
    ok &= _bite("the CHARACTERIZED row told to report `what GH200 does' again", "P12",
                _rebuilt(_patch(VERDICT_H,
                                '      "  Report it as \\"what the target this harness was tagged for (%s) does "',
                                '      "  Report it as \\"what GH200 does (%s) "')),
                r"its printout says .GH200")
    ok &= _bite("OMISSION: the target test deleted, so NO lane names its parts", "P12",
                _rebuilt(_patch(VERDICT_H,
                                'return src != NULL && strstr(src, "NVIDIA") != NULL;',
                                'return 0;')),
                r"never says .(Grace|Hopper|NVLink-C2C).")
    # ---- P2/P3: the EMITTED harness's own stderr warnings ----------------------
    # het_verdict.h is not the only printer.  The emitted .cu names the two halves
    # of the interconnect noise too, and it named them "Grace"/"Hopper" on the AMD
    # lane -- OBSERVED as the first two lines of a real 2+2W-cpuonly-x86_64 run.
    ok &= _bite("the emitted warnings hardcode the NVIDIA nouns again", "P2",
                _rebuilt(_patch(EMIT_ML,
                                'and dev_half = if is_nv_target then "the Hopper half" else "the device half"',
                                'and dev_half = "the Hopper half"')),
                r"PRINTS 'Hopper'")
    ok &= _bite("OMISSION: the target test in the EMITTER always says non-NVIDIA",
                "P3",
                _rebuilt(_patch(EMIT_ML,
                                "          let is_nv_target =\n",
                                "          let is_nv_target = false in\n"
                                "          let _unused_is_nv_target =\n")),
                r"never say .the (Grace|Hopper) half.|prints the GENERIC interconnect")
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
