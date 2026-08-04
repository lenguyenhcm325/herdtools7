#!/usr/bin/env python3
"""amdordercheck.py -- the machine-check behind tests/het/expected-amd.csv.

`build-amd-oracle.sh' DERIVES the AMD MI300A oracle: 19 Disallowed rows plus
the 127-row D26 toggle set (NO-ORACLE at the shipping default).  A wrong
Disallowed row manufactures a FALSE REFUTATION of the compound memory model, so
the generator ships its own structural gates (G0 G1 G2 G12 G13 G14 G15) and this
file carries the ones that need an external instrument -- herd7, the recorded
gfx942 assembly, or a second independent computation over the corpus.

Specification: env-research/PORT2-R2-amd-oracle.md sect 9.4, as amended by
env-research/PORT2-P2-0-addendum.md sect 7.  Phase numbering follows the memo's
gate names, NOT the phase order, because the memo names gates.

  Phase 1  G3   CPU projection: 11 shapes x {plain, MFENCE-per-proc} under
                herd7 -cat x86tso.cat, against ord_x86.  Also pins the header
                requirement: an X86_64 header is REFUSED by x86tso.cat and would
                silently default to x86tso-mixed.cat, whose `lob' subtraction
                lets ANY intervening non-load/non-store restore W->R.
  Phase 2  G4   GPU projection per cell, WITH THE INSTRUMENT NAMED PER CELL.
                amd-gcn3.cat decides `acc-release@WW' and `acc-acquire@RR' and
                NOTHING else (its fence and 'sc axioms are unanchored -- memo
                2.1, addendum sect 3); the other ten cells are decided by the
                recorded gfx942 assembly indexed in g3-cell-instruments.json.
  Phase 3  G5   Read the CSV back: row count, verdict census, per-class census,
                and the class -> verdict function ROW BY ROW.  ASSERTED, never
                merely printed.
  Phase 4  G6   x86-image collapse consistency (memo 5.3): 45 classes, 321
                distinct x86 programs, 0 inconsistent.
  Phase 5  G7   K-CPU necessary condition -- NOT a decision.  The 17 rows must
           G8   not be `Sometimes' under T_x86; and one-directionally, any row
                whose T_x86 is `Sometimes' MUST be labelled Allowed.  Includes
                the soundness assertion that T_x86 is a STRENGTHENING.
  Phase 6  G12  S_CUT_MCA is exactly 8 rows, by memo 5.2's structural predicate
           G13  re-derived here from the corpus; 0 GPU->GPU external edges;
           G14  the unreachable primitives really do not occur.
  Phase 7  G15  the !SWMR hook split, re-derived independently of the builder.
  Phase 8  G10  the downstream census pins, as a fail-closed ledger.
  Phase 9  G11  the mu-map, fail-closed at SELECTION time, on the x86 strength
                lattice (memo 7.D11): every Disallowed row either carries a real
                Layer-A mutant or is one of 16 PINNED rows for which the corpus
                provably has none.

`--bite' corrupts the rule / the corpus / the CSV nine ways and requires each to
redden the phase it names, on CORRUPTION and on OMISSION both.  A gate never
seen to fail is not evidence.

Needs: a built tree (_build/install/default/bin/{herd7,diyone7}) and, for
Phase 2 only, the recorded gfx942 artefacts, which live OUTSIDE this repo at
env-research/g3-artifacts (override with HET_G3_ARTIFACTS).  Every phase fails
CLOSED if its instrument is missing -- "instrument absent" is never "OK".
"""

import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HET = ROOT / "hetlitmus" / "tests" / "het"
GPUONLY = ROOT / "hetlitmus" / "tests" / "gpu-only"
GRIDLIB = ROOT / "hetlitmus" / "tests" / "_grid_lib.sh"
BUILDER = HET / "build-amd-oracle.sh"
CSVPATH = Path(os.environ.get("HET_AMD_ORACLE", HET / "expected-amd.csv"))
BIN = ROOT / "_build" / "install" / "default" / "bin"
HERD7 = BIN / "herd7"
DIYONE7 = BIN / "diyone7"
LIBDIR = ROOT / "herd" / "libdir"
GCN3CAT = ROOT / "hetlitmus" / "cats" / "amd-gcn3.cat"
PTXBELL = ROOT / "hetlitmus" / "bells" / "ptx.bell"
G3ART = Path(os.environ.get("HET_G3_ARTIFACTS",
                            ROOT.parent / "env-research" / "g3-artifacts"))
MEMO = Path(os.environ.get("HET_R2_MEMO",
                           ROOT.parent / "env-research" / "PORT2-R2-amd-oracle.md"))

# --- the memo's pins.  Every one of these is a target, not a measurement: if the
# --- tree disagrees the TREE is wrong until proven otherwise (memo 5.1/5.2).
EXPECT_ORACLE_ROWS = 411
CENSUS_VERDICT = {"Allowed": 258, "Disallowed": 19, "NO-ORACLE": 134}
CENSUS_CLASS = {"S_RELAXED": 60, "S_SCOPE": 104, "S_ROLE": 44, "S_PPO_C": 46,
                "S_RF_NOCUM": 4, "S_NTA": 19, "S_CUT_UNKEYED": 119,
                "S_CUT_MCA_UNKEYED": 8,
                "S_WS_FENCE": 3, "S_WS_FREL": 1, "S_WS_REL": 3}
# The class DETERMINES the verdict, and both are in the CSV.  Checking them row
# by row is what catches a CENSUS-PRESERVING corruption -- MEASURED 2026-08-02:
# swapping the verdicts of one Allowed row and one NO-ORACLE row leaves every
# aggregate in Phase 3 AND Phase 4 unchanged, and shipped.
CLASS_VERDICT = {"S_RELAXED": "Allowed", "S_SCOPE": "Allowed", "S_ROLE": "Allowed",
                 "S_PPO_C": "Allowed", "S_RF_NOCUM": "Allowed",
                 "S_NTA": "Disallowed", "S_CUT_UNKEYED": "NO-ORACLE",
                 "S_CUT_MCA_UNKEYED": "NO-ORACLE",
                 "S_WS_FENCE": "NO-ORACLE", "S_WS_FREL": "NO-ORACLE",
                 "S_WS_REL": "NO-ORACLE"}
MODEL = "AMD-CDNA3-x86"
EXPECT_EXT_EDGES = 1092            # memo sect 6, "1092 external edges, 0 GPU->GPU"
EXPECT_COLLAPSE_CLASSES = 45       # memo 5.3
EXPECT_DISTINCT_X86 = 321          # memo 5.3
EXPECT_TX86_SOMETIMES = 101        # memo 9.4 G8, weakest sound mapping
EXPECT_G3_CELLS = 35               # 11 shapes + one MFENCE variant per 2-access proc
MCA_ROWS = sorted("""
IRIW-gccc-sys-acquire IRIW-gccc-sys-fence IRIW-gccc-sys-acqrel-2s IRIW-gccc-sys-fence-2s
IRIW-gcgc-sys-acquire IRIW-gcgc-sys-fence IRIW-gcgc-sys-acqrel-2s
RWC-gcc-sys-fence-2s
""".split())
KCPU_ROWS = sorted("""
IRIW-cgcc-sys-relaxed IRIW-cgcc-sys-release IRIW-cgcc-sys-acqrel-2s IRIW-cgcc-sys-fence-2s
IRIW-cgcg-sys-relaxed IRIW-cgcg-sys-release IRIW-cgcg-sys-acqrel-2s IRIW-cgcg-sys-fence-2s
WRC-ccg-sys-relaxed   WRC-ccg-sys-release   WRC-ccg-sys-acqrel-2s   WRC-ccg-sys-fence-2s
WRC3-cccg-sys-relaxed WRC3-cccg-sys-release WRC3-cccg-sys-acqrel-2s WRC3-cccg-sys-fence-2s
RWC-ccg-sys-fence-2s
""".split())
# memo 5.4.1 as UPDATED by the addendum (sect 7 item 1): twelve cells, every one
# carrying a recorded gfx942 emission, and the "no instrument" set EMPTY.
CELLS_12 = ["acc-acquire@RR", "acc-release@WW", "fence-sc@RW", "fence-sc@RR",
            "fence-sc@WW", "acc-release@RW", "fence-release@RW", "fence-release@WW",
            "fence-acquire@RW", "fence-sc@WR", "fence-acquire@RR", "acc-acquire@RW"]
# G4 clause (a): amd-gcn3.cat decides these two cells and NO others.  R-3's
# repair does NOT widen this -- the new fence/'sc axioms are unanchored.
GCN3_DECIDES = {"acc-release@WW", "acc-acquire@RR"}

FAIL = []
# checker-side injections in bite(), counted so the printed total is MEASURED
# rather than transcribed (an earlier hand-off said 33 when the run did 35).
NCHECKER = 21


def fail(phase, msg):
    FAIL.append("%s: %s" % (phase, msg))
    print("  *** %s FAIL: %s" % (phase, msg))


def need(cond, phase, msg):
    if not cond:
        fail(phase, msg)
    return cond


# ===========================================================================
# INPUTS
# ===========================================================================
def read_shape_cycle():
    """SHAPE_CYCLE from _grid_lib.sh -- the corpus generator's own table."""
    txt = GRIDLIB.read_text()
    blk = re.search(r"declare -A SHAPE_CYCLE=\((.*?)\n\)", txt, re.S)
    if not blk:
        sys.exit("amdordercheck: SHAPE_CYCLE not found in %s" % GRIDLIB)
    out = {}
    for m in re.finditer(r'\[([^\]]+)\]="([^"]+)"', blk.group(1)):
        out[m.group(1)] = m.group(2).split()
    return out


def read_builder_rot():
    """SHAPE_ROT as the GENERATOR has it, so the two cannot drift apart."""
    txt = BUILDER.read_text()
    blk = re.search(r"declare -A SHAPE_ROT=\((.*?)\n\)", txt, re.S)
    if not blk:
        sys.exit("amdordercheck: SHAPE_ROT not found in %s" % BUILDER)
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"\[([^\]]+)\]=(\d+)", blk.group(1))}


def read_builder_sources():
    """The ten S_* justification strings, keyed by class name.  The CSV's Source
    column is the only place the class survives, so this is how a row's class is
    recovered without trusting a second copy of the table."""
    txt = BUILDER.read_text()
    out = {}
    for m in re.finditer(r'^\[(S_[A-Z_]+)\]="(.*)"$', txt, re.M):
        out[m.group(2)] = m.group(1)
    return out


def edge_kind(e):
    if e.startswith("Pod"):
        return ("po", e[3], e[4])
    return {"Rfe": ("rf", "W", "R"), "Fre": ("fr", "R", "W"),
            "Coe": ("co", "W", "W")}[e]


def cycle_of(spec, rot):
    """-> (per-proc direction strings, external edges, per-event (proc,idx))."""
    es = [edge_kind(x) for x in spec]
    k = len(es)
    E = [es[(rot + i) % k] for i in range(k)]
    procs, cur = [], [0]
    for i in range(k - 1):
        if E[i][0] == "po":
            cur.append(i + 1)
        else:
            procs.append(cur)
            cur = [i + 1]
    procs.append(cur)
    ev2p = {}
    for pi, p in enumerate(procs):
        for li, e in enumerate(p):
            ev2p[e] = (pi, li)
    edges = []
    for i, (kind, _s, _d) in enumerate(E):
        if kind == "po":
            continue
        a, b = ev2p[i], ev2p[(i + 1) % k]
        edges.append((kind, a[0], a[1], b[0], b[1]))
    dirs = ["".join(E[j][1] for j in p) for p in procs]
    return dirs, edges, E


CPU_R = re.compile(r"^(LDR|LDAPR|LDAR)[ \t]")
CPU_W = re.compile(r"^(STR|STLR)[ \t]")
CPU_SY = re.compile(r"^DMB[ .]SY")
CPU_LDST = re.compile(r"^DMB[ .](ST|LD)")
CPU_MOV = re.compile(r"^MOV[ \t]")
GPU_EV = re.compile(r"^([rwf])\[([a-z_]+),([a-z]+)\]")


def parse_litmus(path):
    """-> [{'dev':..,'ev':[(DIR,annot,scope)]}] with the CPU column already
    projected to x86 exactly as memo 3.1 specifies (ra/st/ld collapse to a plain
    MOV; DMB SY becomes MFENCE; DMB ST / DMB LD are DROPPED).  Fails closed on an
    instruction form it does not know -- a silently ignored instruction is how a
    projection stops projecting."""
    txt = path.read_text()
    m = re.search(r"^\s*(P0:.*?);\s*$", txt, re.M)
    if not m:
        sys.exit("amdordercheck: no proc header in %s" % path)
    hdr = [c.strip() for c in m.group(1).split("|")]
    devs = [c.split(":")[1] for c in hdr]
    procs = [{"dev": d, "ev": [], "raw": []} for d in devs]
    for line in txt[m.end():].splitlines():
        line = line.strip()
        if not line:
            continue
        if re.match(r"^(scopes:|exists|locations|forall)", line):
            break
        if not line.endswith(";"):
            break
        cols = [c.strip() for c in line[:-1].split("|")]
        for i, c in enumerate(cols):
            if i >= len(procs) or not c:
                continue
            procs[i]["raw"].append(c)
            if devs[i] == "cpu":
                if CPU_R.match(c):
                    procs[i]["ev"].append(("R", "x86", "-"))
                elif CPU_W.match(c):
                    procs[i]["ev"].append(("W", "x86", "-"))
                elif CPU_SY.match(c):
                    procs[i]["ev"].append(("F", "MFENCE", "-"))
                elif CPU_LDST.match(c) or CPU_MOV.match(c):
                    pass
                else:
                    sys.exit("amdordercheck: unknown CPU instruction %r in %s"
                             % (c, path.name))
            else:
                g = GPU_EV.match(c)
                if not g:
                    sys.exit("amdordercheck: unknown GPU op %r in %s" % (c, path.name))
                d = {"r": "R", "w": "W", "f": "F"}[g.group(1)]
                procs[i]["ev"].append((d, g.group(2), g.group(3)))
    return procs


class Corpus(object):
    def __init__(self):
        self.cyc = read_shape_cycle()
        self.rot_builder = read_builder_rot()
        self.tests = {}
        for f in sorted(HET.glob("*.litmus")):
            self.tests[f.stem] = parse_litmus(f)
        self.rot = {}
        self._fit_rotations()

    def shape(self, name):
        return name.split("-")[0]

    def _fit_rotations(self):
        """Re-derive the rotation from the FILES, independently of the builder's
        table, then assert the two agree (memo 3.0's rotation fact).

        Some shapes are rotationally SYMMETRIC (SB is `PodWR Fre PodWR Fre', so
        rotations 0 and 2 fit equally).  Where more than one rotation fits, the
        ambiguity is only harmless if every fit gives the SAME cycle structure --
        that is asserted here rather than assumed, and the builder's own choice
        must be among the fits."""
        self.rot_fits = {}
        for shape, spec in self.cyc.items():
            es = [edge_kind(x) for x in spec]
            k = len(es)
            cands = [r for r in range(k) if es[(r - 1) % k][0] != "po"]
            names = [n for n in self.tests if self.shape(n) == shape]
            if not names:
                continue
            fits = []
            for r in cands:
                dirs, _e, _E = cycle_of(spec, r)
                if all(dirs == [self.dirs_of(n, i)
                                for i in range(len(dirs))] for n in names):
                    fits.append(r)
            if not fits:
                sys.exit("amdordercheck: no rotation of %s matches the corpus" % shape)
            sig = {r: (tuple(cycle_of(spec, r)[0]),
                       tuple(sorted(cycle_of(spec, r)[1]))) for r in fits}
            if len({v for v in sig.values()}) != 1:
                sys.exit("amdordercheck: rotations %s of %s fit the corpus but give "
                         "DIFFERENT cycle structures %s -- the rotation is not "
                         "determined and the memo's fact is wrong" % (fits, shape, sig))
            self.rot_fits[shape] = fits
            br = self.rot_builder.get(shape)
            self.rot[shape] = br if br in fits else fits[0]

    def dirs_of(self, name, i):
        pr = self.tests[name]
        if i >= len(pr):
            return None
        return "".join(d for d, _a, _s in pr[i]["ev"] if d in "RW")

    def structure(self, name):
        shape = self.shape(name)
        return cycle_of(self.cyc[shape], self.rot[shape])

    def shared(self, name, i):
        return [(d, a, s) for d, a, s in self.tests[name][i]["ev"] if d in "RW"]

    def fences_between(self, name, i, a, b):
        """fences strictly between shared accesses a and b of proc i"""
        ev = self.tests[name][i]["ev"]
        idx = [j for j, (d, _a, _s) in enumerate(ev) if d in "RW"]
        return [e for e in ev[idx[a] + 1:idx[b]] if e[0] == "F"]


def read_csv():
    rows = {}
    if not CSVPATH.exists():
        sys.exit("amdordercheck: %s does not exist -- run build-amd-oracle.sh" % CSVPATH)
    for line in CSVPATH.read_text().splitlines():
        if not line or line.startswith("#") or line.startswith("Litmus,"):
            continue
        f = line.split(",")
        if len(f) != 4:
            sys.exit("amdordercheck: row %r has %d fields not 4 -- a comma leaked "
                     "into the Source string (memo 9.2 makes that FATAL)"
                     % (f[0], len(f)))
        rows[f[0]] = dict(verdict=f[1], model=f[2], src=f[3])
    return rows


def herd(path, cat, bell=None, extra=()):
    cmd = [str(HERD7), "-set-libdir", str(LIBDIR), "-cat", cat]
    if bell:
        cmd += ["-bell", str(bell)]
    cmd += list(extra) + [str(path)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    m = re.search(r"^Observation \S+ (Never|Sometimes|Always)", out, re.M)
    return (m.group(1) if m else None), out


# ===========================================================================
# PHASE 1 -- G3.  CPU projection under x86tso.cat.
# ===========================================================================
ORD_X86_PLAIN = frozenset(("WW", "RR", "RW"))
ORD_X86_MFENCE = frozenset(("WW", "RR", "WR", "RW"))


def emit_x86(tmp, name, spec):
    p = subprocess.run([str(DIYONE7), "-arch", "X86", "-name", name] + spec,
                       cwd=tmp, capture_output=True, text=True)
    f = Path(tmp) / (name + ".litmus")
    if p.returncode != 0 or not f.exists():
        sys.exit("amdordercheck: diyone7 -arch X86 %s failed:\n%s%s"
                 % (" ".join(spec), p.stdout, p.stderr))
    return f


def phase1(C):
    print("== Phase 1 -- G3: CPU projection, 11 shapes x {plain, MFENCE-per-proc},"
          " herd7 -cat x86tso.cat ==")
    if not HERD7.exists() or not DIYONE7.exists():
        fail("G3", "herd7/diyone7 not built at %s -- refusing to skip" % BIN)
        return
    tmp = tempfile.mkdtemp(prefix="amdorder-g3-")
    cells = 0
    try:
        for shape in sorted(C.cyc):
            spec, rot = C.cyc[shape], C.rot[shape]
            k = len(spec)
            rspec = [spec[(rot + i) % k] for i in range(k)]
            dirs, _edges, _E = cycle_of(spec, rot)
            # which rotated-spec index carries proc p's po edge
            poidx, pi = {}, 0
            for i, e in enumerate(rspec[:-1]):
                if e.startswith("Pod"):
                    poidx.setdefault(pi, i)
                else:
                    pi += 1
            variants = [("plain", set())]
            for p in sorted(poidx):
                variants.append(("mfence-P%d" % p, {p}))
            for tag, mf in variants:
                s2 = list(rspec)
                for p in mf:
                    s2[poidx[p]] = "MFenced" + rspec[poidx[p]][3:]
                nm = ("%s_%s" % (shape, tag)).replace("+", "p").replace("-", "_")
                f = emit_x86(tmp, nm, s2)
                head = f.read_text().splitlines()[0]
                if not need(head.startswith("X86 "), "G3",
                            "%s carries header %r -- the projection must be X86 "
                            "(an X86_64 header silently defaults to x86tso-mixed.cat)"
                            % (nm, head)):
                    continue
                body = f.read_text()
                need("SFENCE" not in body and "LFENCE" not in body, "G3",
                     "%s emits SFENCE/LFENCE; memo 3.1 forbids them in the CPU "
                     "projection (CACM p.93 models both as no-ops on WB)" % nm)
                got, _o = herd(f, "x86tso.cat")
                # the prediction READS the ord_x86 table -- inlining `d != WR'
                # here would leave the table decorative and unbiteable
                ordered = all(
                    len(d) < 2 or d[:2] in (ORD_X86_MFENCE if p in mf
                                            else ORD_X86_PLAIN)
                    for p, d in enumerate(dirs))
                want = "Never" if ordered else "Sometimes"
                cells += 1
                if got != want:
                    fail("G3", "%s: herd7 says %s but ord_x86 predicts %s "
                               "(proc pairs %s; MFENCE on %s)"
                         % (nm, got, want, dirs, sorted(mf) or "none"))
        # the header bite, run every time: an X86_64 header must be REFUSED
        f = emit_x86(tmp, "hdrprobe", ["PodWW", "Rfe", "PodRR", "Fre"])
        g = Path(tmp) / "hdrprobe64.litmus"
        g.write_text(f.read_text().replace("X86 hdrprobe", "X86_64 hdrprobe", 1))
        got, out = herd(g, "x86tso.cat")
        need(got is None and "Architecture mismatch" in out, "G3",
             "an X86_64-headered fixture was MODELLED (%s) instead of refused by "
             "x86tso.cat -- G3's header requirement is a syntax translation, not "
             "a copy" % got)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # the het corpus itself must never contain an x86 store/load fence
    bad = [f.name for f in HET.glob("*.litmus")
           if "SFENCE" in f.read_text() or "LFENCE" in f.read_text()]
    need(not bad, "G3", "SFENCE/LFENCE appears in %s" % bad[:3])
    # ASSERT the cell count, do not merely print it: a half-blind phase that
    # checked 12 of 35 cells would otherwise report OK (Q10b sect 7.4's lesson).
    need(cells == EXPECT_G3_CELLS, "G3",
         "only %d projection cells were checked but the 11 shapes x "
         "{plain, MFENCE-per-proc} grid has %d -- the phase went half blind"
         % (cells, EXPECT_G3_CELLS))
    print("   %d projection cells checked against ord_x86; X86_64 header refused"
          % cells)


# ===========================================================================
# PHASE 2 -- G4.  GPU projection, per cell, INSTRUMENT NAMED PER CELL.
# ===========================================================================
def phase2(C):
    print("== Phase 2 -- G4: GPU projection per cell (addendum sect 7 item 2) ==")
    idx = G3ART / "g3-cell-instruments.json"
    if not idx.exists():
        fail("G4", "the recorded gfx942 instrument index is missing at %s "
                   "(set HET_G3_ARTIFACTS) -- refusing to report OK without it" % idx)
        return
    J = json.loads(idx.read_text())
    if "cells" not in J or not isinstance(J["cells"], list):
        fail("G4", "%s has no `cells' list -- the index schema changed under this "
                   "gate" % idx.name)
        return
    cells = {}
    for rec in J["cells"]:
        c = rec.get("cell")
        if c in cells:
            fail("G4", "cell %s appears twice in the index" % c)
        cells[c] = rec
    req = J.get("_required", {}).get("cells")
    need(req is not None and sorted(req) == sorted(CELLS_12), "G4",
         "the index's own _required.cells inventory is %s not memo 5.4.1's twelve"
         % (sorted(req) if req else None))
    named = 0
    print("   %-20s %-22s %-18s %s" % ("cell", "probe", "kernel", "recorded asm"))
    for cell in CELLS_12:
        rec = cells.get(cell)
        if rec is None:
            fail("G4", "cell %s is absent from %s" % (cell, idx.name))
            continue
        probe = str(rec.get("probe", "") or "")
        kern = str(rec.get("kernel", "") or "")
        asm = str(rec.get("asm", "") or "")
        print("   %-20s %-22s %-18s %s" % (cell, probe or "<BLANK>",
                                           kern or "<BLANK>", asm or "<BLANK>"))
        if not (probe and kern and asm):
            fail("G4", "cell %s names no instrument (probe=%r kernel=%r asm=%r) -- "
                       "the addendum's re-specification requires a NAMED "
                       "instrument per cell" % (cell, probe, kern, asm))
            continue
        if not (G3ART / probe).exists():
            fail("G4", "cell %s cites probe %s which does not exist" % (cell, probe))
            continue
        if not (G3ART / asm).exists():
            fail("G4", "cell %s cites asm %s which does not exist" % (cell, asm))
            continue
        if kern not in (G3ART / asm).read_text():
            fail("G4", "cell %s cites kernel %s but %s does not contain it"
                 % (cell, kern, asm))
            continue
        named += 1
    need(named == 12, "G4",
         "instrumented cells = %d but memo 5.4.1 as updated pins 12" % named)
    need(len(cells) == 12, "G4",
         "the index carries %d cells not 12 (%s)" % (len(cells), sorted(cells)))
    print("   instrumented cells: %d (must be 12)" % named)

    # memo 5.4.1 as amended (addendum sect 7 item 1) is NORMATIVE and the
    # generator transcribes it as numbers it RE-DERIVES.  Read its printout --
    # the deliverable is the table, not the exit code.
    p = subprocess.run(["bash", str(BUILDER), "--cells"], cwd=str(HET),
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    need(p.returncode == 0, "G4",
         "build-amd-oracle.sh --cells exited %d:\n%s" % (p.returncode, out[-600:]))
    got = dict(re.findall(r"^   (\S+@\S+)\s+(\d+)\s+\d+$", out, re.M))
    need(sorted(got) == sorted(CELLS_12), "G4",
         "--cells reported %d cells (%s) not memo 5.4.1's twelve"
         % (len(got), sorted(got)))
    need(re.search(r"anchors alone: 45 / 146 covered", out), "G4",
         "--cells did not print `anchors alone: 45 / 146 covered'; it printed:\n%s"
         % out[-400:])
    need(re.search(r"anchors \+ the recorded gfx942 emissions: 146 / 146 covered "
                   r"; uninstrumented 0", out), "G4",
         "--cells did not print the 146/146 coverage with gap 0 that the addendum "
         "measured; it printed:\n%s" % out[-400:])
    print("   memo 5.4.1 re-derived by the generator: 12 cells, anchors 45/146, "
          "anchors+emissions 146/146, uninstrumented 0")

    # clause (a): amd-gcn3.cat decides EXACTLY the two anchored cells.  Decided
    # by RUNNING it, and bitten structurally: ablate the annotation the cell
    # names and the verdict must move.
    if not (HERD7.exists() and GCN3CAT.exists() and PTXBELL.exists()):
        fail("G4", "herd7 / amd-gcn3.cat / ptx.bell missing -- cannot decide the "
                   "two anchored cells")
        return
    fixture = GPUONLY / "MP-sys-F.litmus"
    if not fixture.exists():
        fail("G4", "%s missing" % fixture)
        return
    tmp = tempfile.mkdtemp(prefix="amdorder-g4-")
    try:
        base, _o = herd(fixture, str(GCN3CAT), bell=PTXBELL)
        need(base == "Never", "G4",
             "amd-gcn3.cat gives %s for GPU-Only MP-sys-F; the two cells it is "
             "cited for (acc-release@WW acc-acquire@RR) must forbid it" % base)
        for cell, pat, repl in (("acc-release@WW", "w[release,sys]", "w[relaxed,sys]"),
                                ("acc-acquire@RR", "r[acquire,sys]", "r[relaxed,sys]")):
            src = fixture.read_text()
            need(pat in src, "G4", "fixture %s does not contain %s" % (fixture.name, pat))
            g = Path(tmp) / ("ablate-%s.litmus" % cell.replace("@", "-"))
            g.write_text(src.replace(pat, repl))
            got, _o = herd(g, str(GCN3CAT), bell=PTXBELL)
            need(got == "Sometimes", "G4",
                 "ablating %s from MP-sys-F leaves amd-gcn3.cat at %s -- the cell "
                 "is NOT load-bearing there so the instrument does not decide it"
                 % (cell, got))
        print("   amd-gcn3.cat decides %s (MP-sys-F Never; each ablation -> Sometimes)"
              % sorted(GCN3_DECIDES))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # and it must NOT be cited for anything else
    cited = {c for c in CELLS_12 if str(cells.get(c, {}).get("gcn3_decides", "")) == "yes"}
    need(cited <= GCN3_DECIDES, "G4",
         "the index claims amd-gcn3.cat decides %s; R-3's repair does NOT license "
         "the fence or 'sc cells (addendum sect 3)" % sorted(cited - GCN3_DECIDES))


# ===========================================================================
# PHASE 3 -- G5.  Read the CSV back and ASSERT (never merely print) the censuses.
# ===========================================================================
def read_memo_sources():
    """the eleven normative S_* strings as the memo's 5.2 table holds them"""
    if not MEMO.exists():
        return None
    out = {}
    for line in MEMO.read_text().splitlines():
        m = re.match(r"^\| `(S_\w+)` \| .* \| `(.*)` \|$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def _memo_sources_agree(srcmap):
    memo = read_memo_sources()
    if memo is None:
        fail("G5", "the R2 memo is not at %s -- the 5.2 byte-comparison cannot "
                   "run and the normative strings are UNGATED (set HET_R2_MEMO)"
             % MEMO)
        return
    shipped = {cls: txt for txt, cls in srcmap.items()
               # the two ablation-branch strings (X2A_TRANSFERS=1) are normative
               # in the builder but deliberately absent from memo 5.2's table,
               # which documents the SHIPPING file
               if cls not in ("S_CUT", "S_CUT_MCA")}
    if not need(len(memo) == 11, "G5",
                "the memo's 5.2 table yields %d S_* strings not 11 -- the parse "
                "has gone half-blind or the table was reshaped" % len(memo)):
        return
    if not need(set(memo) == set(shipped), "G5",
                "memo 5.2 names %s; the generator ships %s"
                % (sorted(set(memo) - set(shipped)), sorted(set(shipped) - set(memo)))):
        return
    for k in sorted(memo):
        if memo[k] != shipped[k]:
            i = next((j for j in range(min(len(memo[k]), len(shipped[k])))
                      if memo[k][j] != shipped[k][j]), min(len(memo[k]), len(shipped[k])))
            fail("G5", "S_%s: memo 5.2 and the generator have DRIFTED at offset %d\n"
                       "        memo : ...%s...\n        ships: ...%s..."
                 % (k[2:], i, memo[k][max(0, i - 30):i + 40],
                    shipped[k][max(0, i - 30):i + 40]))


def phase3(C, rows, srcmap):
    print("== Phase 3 -- G5: CSV read-back ==")
    need(len(rows) == EXPECT_ORACLE_ROWS, "G5",
         "the CSV carries %d data rows but EXPECT_ORACLE_ROWS = %d"
         % (len(rows), EXPECT_ORACLE_ROWS))
    need(set(rows) == set(C.tests), "G5",
         "CSV row set != corpus: only-in-CSV %s only-in-corpus %s"
         % (sorted(set(rows) - set(C.tests))[:3], sorted(set(C.tests) - set(rows))[:3]))
    bad = [n for n in rows if rows[n]["model"] != MODEL]
    need(not bad, "G5", "%d row(s) carry a Model other than %s (%s)"
         % (len(bad), MODEL, bad[:3]))
    cv = collections.Counter(rows[n]["verdict"] for n in rows)
    need(dict(cv) == CENSUS_VERDICT, "G5",
         "verdict census %s != %s" % (dict(cv), CENSUS_VERDICT))
    unknown = [n for n in rows if rows[n]["src"] not in srcmap]
    need(not unknown, "G5",
         "%d row(s) carry a Source string that is not one of the generator's ten "
         "S_* strings (%s)" % (len(unknown), unknown[:3]))
    cc = collections.Counter(srcmap.get(rows[n]["src"], "??") for n in rows)
    need(dict(cc) == CENSUS_CLASS, "G5",
         "class census %s != %s" % (dict(cc), CENSUS_CLASS))
    need(len(rows) and all("," not in rows[n]["src"] for n in rows), "G5",
         "a Source string contains a comma")
    mism = sorted((n, rows[n]["verdict"], srcmap[rows[n]["src"]]) for n in rows
                  if rows[n]["src"] in srcmap
                  and rows[n]["verdict"] != CLASS_VERDICT[srcmap[rows[n]["src"]]])
    need(not mism, "G5",
         "%d row(s) carry a verdict their own S_* class does not license "
         "(class -> verdict is a function; both are in the CSV): %s"
         % (len(mism), ["%s is %s but %s is always %s"
                        % (n, v, c, CLASS_VERDICT[c]) for n, v, c in mism[:3]]))
    # --- memo 5.2 vs the shipped strings -----------------------------------
    # The memo declares its 5.2 justification strings NORMATIVE and "byte-stable
    # once landed"; the generator holds the same ten in its SRC array.  They were
    # allowed to drift once already (the R-5 re-key landed in the generator and
    # not in the memo, and the S_ROLE wording correction was never registered),
    # so the two texts are byte-compared here and neither is allowed to move
    # alone.  Fails CLOSED if the memo is not on this box.
    _memo_sources_agree(srcmap)
    print("   %d rows; verdicts %s; classes OK; class -> verdict holds row by row"
          % (len(rows), dict(cv)))


# ===========================================================================
# PHASE 4 -- G6.  x86-image collapse consistency (memo 5.3).
# ===========================================================================
def x86_image(C, name):
    """the program the harness actually runs once the CPU column is projected:
    CPU side collapsed to {plain, MFENCE}, GPU side verbatim."""
    return (C.shape(name),
            tuple((p["dev"], tuple(p["ev"])) for p in C.tests[name]))


def phase4(C, rows):
    print("== Phase 4 -- G6: x86-image collapse consistency (memo 5.3) ==")
    g = collections.defaultdict(list)
    for n in C.tests:
        g[x86_image(C, n)].append(n)
    # A row the CSV does not carry gets an explicit sentinel rather than a
    # KeyError.  MEASURED 2026-08-02: deleting one CSV row made this phase die in
    # a traceback AFTER G5's six diagnostics had printed -- exit 1 either way, so
    # never a false green, but the run ended without the
    # "AMDORDERCHECK FAILED: N assertion(s)" summary a reader is told to look for.
    def verdict(x):
        return rows.get(x, {}).get("verdict", "<ABSENT-FROM-CSV>")

    classes = [v for v in g.values() if len(v) > 1]
    inconsistent = [v for v in classes if len({verdict(x) for x in v}) > 1]
    for v in inconsistent:
        fail("G6", "collapse class %s carries verdicts %s -- the harness runs the "
                   "IDENTICAL x86 program for all of them"
             % (sorted(v), sorted({verdict(x) for x in v})))
    need(len(classes) == EXPECT_COLLAPSE_CLASSES, "G6",
         "%d collapse classes but memo 5.3 measured %d" % (len(classes), EXPECT_COLLAPSE_CLASSES))
    need(len(g) == EXPECT_DISTINCT_X86, "G6",
         "%d distinct x86 programs but memo 5.3 measured %d" % (len(g), EXPECT_DISTINCT_X86))
    print("   x86-image collapse classes: %d ; distinct x86 programs: %d / %d ; "
          "INCONSISTENT: %d" % (len(classes), len(g), len(C.tests), len(inconsistent)))


# ===========================================================================
# PHASE 5 -- G7 + G8.  The T_x86 rendering, run through herd7.
# ===========================================================================
# T_x86 (memo 9.4 G8): the WEAKEST SOUND strengthening.  Every proc is rendered on
# x86; the only thing that survives is an MFENCE, and it survives only where the
# modelled primitive orders W->R toward a cross-proc observer.
TX86_KEEP_MFENCE = {("F", "sc", "sys"), ("F", "MFENCE", "-")}
# the modelled `ord' of each GPU primitive, for the strengthening assertion
PRIM_ORD = {"relaxed": frozenset(), "release": frozenset(("WW", "RW")),
            "acquire": frozenset(("RR", "RW")), "sc": frozenset(("WW", "RR", "WR", "RW"))}


def tx86_mfenced_procs(C, name):
    """which procs carry an MFENCE between their two accesses under T_x86"""
    out = set()
    for i, p in enumerate(C.tests[name]):
        sh = [j for j, (d, _a, _s) in enumerate(p["ev"]) if d in "RW"]
        if len(sh) < 2:
            continue
        between = p["ev"][sh[0] + 1:sh[1]]
        if any((d, a, s) in TX86_KEEP_MFENCE for d, a, s in between):
            out.add(i)
    return frozenset(out)


def assert_strengthening(C, name):
    """rendered-ord must be a SUPERSET of modelled-ord for every proc, else T_x86
    is not a strengthening and G8's one-directional argument collapses."""
    mf = tx86_mfenced_procs(C, name)
    bad = []
    for i, p in enumerate(C.tests[name]):
        sh = [(d, a, s) for d, a, s in p["ev"] if d in "RW"]
        if len(sh) < 2:
            continue
        rendered = ORD_X86_MFENCE if i in mf else ORD_X86_PLAIN
        modelled = set()
        if p["dev"] == "cpu":
            modelled = set(ORD_X86_MFENCE if i in mf else ORD_X86_PLAIN)
        else:
            pair = sh[0][0] + sh[1][0]
            for d, a, s in p["ev"]:
                if s != "sys":
                    continue          # sub-system scope constrains no observer
                if d in "RW":
                    modelled |= PRIM_ORD.get(a, frozenset())
                elif d == "F":
                    modelled |= PRIM_ORD.get(a, frozenset())
            modelled &= {pair}
        if not modelled <= rendered:
            bad.append((i, sorted(modelled - rendered)))
    return bad


def phase5(C, rows):
    print("== Phase 5 -- G7 + G8: the T_x86 rendering under herd7 -cat x86tso.cat ==")
    if not (HERD7.exists() and DIYONE7.exists()):
        fail("G7/G8", "herd7/diyone7 not built -- refusing to skip")
        return
    # (0) soundness: T_x86 must be a strengthening on every row
    nonstr = []
    for n in sorted(C.tests):
        b = assert_strengthening(C, n)
        if b:
            nonstr.append((n, b))
    need(not nonstr, "G8",
         "T_x86 is NOT a strengthening on %d row(s) -- e.g. %s.  The whole "
         "one-directional argument rests on rendered-ord superset modelled-ord"
         % (len(nonstr), nonstr[:2]))
    # (1) herd7 on each distinct (shape, mfenced-proc-set)
    tmp = tempfile.mkdtemp(prefix="amdorder-g8-")
    cache = {}
    try:
        for n in sorted(C.tests):
            shape = C.shape(n)
            key = (shape, tx86_mfenced_procs(C, n))
            if key in cache:
                continue
            spec, rot = C.cyc[shape], C.rot[shape]
            k = len(spec)
            rspec = [spec[(rot + i) % k] for i in range(k)]
            poidx, pi = {}, 0
            for i, e in enumerate(rspec[:-1]):
                if e.startswith("Pod"):
                    poidx.setdefault(pi, i)
                else:
                    pi += 1
            s2 = list(rspec)
            for p in key[1]:
                if p not in poidx:
                    fail("G8", "%s: MFENCE on proc %d which has no program-order "
                               "pair" % (n, p))
                    continue
                s2[poidx[p]] = "MFenced" + rspec[poidx[p]][3:]
            nm = ("tx86_%s_%s" % (shape, "".join(str(x) for x in sorted(key[1])) or "n")
                  ).replace("+", "p").replace("-", "_")
            f = emit_x86(tmp, nm, s2)
            cache[key], _o = herd(f, "x86tso.cat")
        sometimes = [n for n in C.tests
                     if cache[(C.shape(n), tx86_mfenced_procs(C, n))] != "Never"]
        # G8 -- one-directional: T_x86 Sometimes => the row MUST be Allowed
        viol = [n for n in sometimes
                if rows.get(n, {}).get("verdict", "<ABSENT-FROM-CSV>") != "Allowed"]
        need(not viol, "G8",
             "%d row(s) are `Sometimes' under T_x86 -- a STRENGTHENING -- yet are "
             "not labelled Allowed: %s" % (len(viol), viol[:5]))
        need(len(sometimes) == EXPECT_TX86_SOMETIMES, "G8",
             "%d rows are Sometimes under T_x86 but memo 9.4 G8 measured %d"
             % (len(sometimes), EXPECT_TX86_SOMETIMES))
        # G7 -- necessary condition, NOT a decision
        badk = [n for n in KCPU_ROWS
                if cache[(C.shape(n), tx86_mfenced_procs(C, n))] != "Never"]
        need(not badk, "G7",
             "K-CPU row(s) %s are `Sometimes' under T_x86.  G7's premise is that "
             "T_x86 is a STRENGTHENING so a Never merely FAILS TO REFUTE the "
             "Disallowed; a Sometimes refutes it outright." % badk)
        need(sorted(KCPU_ROWS) == sorted(kcpu_derived(C, rows)), "G7",
             "the pinned K-CPU list is not the set the corpus derives")
        print("   %d distinct T_x86 programs; %d rows Sometimes (0 G8 violations); "
              "all %d K-CPU rows Never (necessary condition only)"
              % (len(cache), len(sometimes), len(KCPU_ROWS)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def kcpu_derived(C, rows):
    """memo 5.4's K-CPU, re-derived: a row of the pre-strike Disallowed set --
    since D26 that is Disallowed OR the UNKEYED toggle set (all 17 K-CPU rows
    are S_CUT_UNKEYED / NO-ORACLE on the shipping branch) -- where every GPU
    proc has exactly one shared access, so no GPU proc supplies ordering."""
    out = []
    for n in sorted(C.tests):
        r = rows.get(n, {})
        if r.get("verdict") != "Disallowed" and "UNKEYED" not in r.get("src", ""):
            continue
        if all(len(C.shared(n, i)) <= 1
               for i, p in enumerate(C.tests[n]) if p["dev"] == "gpu"):
            out.append(n)
    return out


# ===========================================================================
# PHASE 6 -- G12 + G13 + G14.  Structural, re-derived from the corpus.
# ===========================================================================
def mca_derived(C, rows, use_rr=True, use_shape=True):
    """memo 5.2's structural S_CUT_MCA predicate, re-derived here.  The two
    optional clauses exist so the gate can MEASURE that each is load-bearing."""
    out = []
    for n in sorted(C.tests):
        r = rows.get(n, {})
        if r.get("verdict") != "Disallowed" and "UNKEYED" not in r.get("src", ""):
            continue
        if use_shape and C.shape(n) not in ("IRIW", "RWC"):
            continue
        _dirs, edges, _E = C.structure(n)
        for k, sp, _si, _dp, _di in edges:
            if k != "fr" or C.tests[n][sp]["dev"] != "gpu":
                continue
            if use_rr and C.dirs_of(n, sp) != "RR":
                continue
            out.append(n)
            break
    return out


def phase6(C, rows, srcmap):
    print("== Phase 6 -- G12 + G13 + G14: structural assertions over the corpus ==")
    # --- G12 ---------------------------------------------------------------
    mca = mca_derived(C, rows)
    csvmca = sorted(n for n in rows if srcmap.get(rows[n]["src"]) == "S_CUT_MCA_UNKEYED")
    need(len(mca) == 8, "G12",
         "the structural predicate finds %d S_CUT_MCA rows not 8: %s" % (len(mca), mca))
    need(sorted(mca) == MCA_ROWS, "G12",
         "the derived S_CUT_MCA set is not memo 5.2's list; only-derived %s "
         "only-memo %s" % (sorted(set(mca) - set(MCA_ROWS)), sorted(set(MCA_ROWS) - set(mca))))
    need(csvmca == MCA_ROWS, "G12",
         "the CSV labels %s as S_CUT_MCA_UNKEYED, not memo 5.2's 8 rows" % csvmca)
    # both clauses of the predicate must be load-bearing, and this MEASURES it
    n_norr = len(mca_derived(C, rows, use_rr=False))
    n_noshape = len(mca_derived(C, rows, use_shape=False))
    need(n_norr == 10, "G12",
         "dropping the R;R clause yields %d rows; memo 5.2 measured 10, so the "
         "clause is not doing what the memo says" % n_norr)
    need(n_noshape == 35, "G12",
         "dropping the shape clause yields %d rows; memo 5.2 measured 35" % n_noshape)
    print("   G12 S_CUT_MCA = %d (memo list matched; drop-R;R -> %d, drop-shape -> %d)"
          % (len(mca), n_norr, n_noshape))
    # --- G13 ---------------------------------------------------------------
    ext = gg = 0
    for n in sorted(C.tests):
        _dirs, edges, _E = C.structure(n)
        for k, sp, _si, dp, _di in edges:
            ext += 1
            if C.tests[n][sp]["dev"] == "gpu" and C.tests[n][dp]["dev"] == "gpu":
                gg += 1
                fail("G13", "GPU->GPU %s edge in %s (P%d -> P%d)" % (k, n, sp, dp))
    need(ext == EXPECT_EXT_EDGES, "G13",
         "%d external edges but memo sect 6 measured %d" % (ext, EXPECT_EXT_EDGES))
    print("   G13 external edges: %d  GPU->GPU: %d (must be 0)" % (ext, gg))
    # --- G14 ---------------------------------------------------------------
    scacc = lock = 0
    for n in sorted(C.tests):
        for p in C.tests[n]:
            for d, a, _s in p["ev"]:
                if d in "RW" and a == "sc":
                    scacc += 1
                if d in "RW" and a in ("lock", "xchg"):
                    lock += 1
            for raw in p["raw"]:
                if re.search(r"\b(LOCK|XCHG|CAS|SWP|LDADD|LDXR|STXR)\b", raw):
                    lock += 1
    need(scacc == 0, "G14",
         "PRIM_GPU's acc-sc row is declared UNREACHABLE but w/r[sc,*] occurs %d "
         "time(s)" % scacc)
    need(lock == 0, "G14",
         "PRIM_CPU's lock row is declared UNREACHABLE but a locked RMW occurs %d "
         "time(s)" % lock)
    print("   G14 unreachable primitives: w/r[sc;*] %d  locked RMW %d (both must be 0)"
          % (scacc, lock))


# ===========================================================================
# PHASE 7 -- G15.  The !SWMR hook split (addendum sect 7 items 3 and 4).
# ===========================================================================
def phase7(C, rows):
    print("== Phase 7 -- G15: the !SWMR hook split ==")
    src = BUILDER.read_text()
    # (i) structural: two clauses, and clause (ii) guarded by the model
    need("CLASS=S_NOSWMR" in src and src.count("CLASS=S_NOSWMR") >= 2, "G15",
         "the !SWMR hook does not have two clauses in %s" % BUILDER.name)
    need(re.search(r'\[ "\$model" = "\$HOOK_II_GUARD_MODEL" \] && has_second_observer',
                   src), "G15",
         "clause (ii) is not guarded by the M == CDNA3 parameter -- "
         "the transfer refusal of D3 has been lost")
    need(re.search(r'^HOOK_II_GUARD_MODEL="\$\{HOOK_II_GUARD_MODEL:-CDNA3\}"', src, re.M),
         "G15", "HOOK_II_GUARD_MODEL does not default to CDNA3")
    need(re.search(r'^HOOK_III_GUARD_MODEL="\$\{HOOK_III_GUARD_MODEL:-CDNA3\}"', src, re.M),
         "G15", "HOOK_III_GUARD_MODEL (clause iii, R2 A-9) does not default to CDNA3")
    need(re.search(r'\[ "\$model" = "\$HOOK_III_GUARD_MODEL" \]', src),
         "G15", "clause (iii) is not guarded by its own model parameter")
    # (ii)/(iii)/(iv): run the generator's own G15 and READ ITS PRINTOUT.  The
    # deliverable is the sentence, not the exit code (B6c's lesson).
    p = subprocess.run(["bash", str(BUILDER), "--g15"], cwd=str(HET),
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    need(p.returncode == 0, "G15", "build-amd-oracle.sh --g15 exited %d:\n%s"
         % (p.returncode, out[-800:]))
    for pat, what in (
            (r"\(iv\) anchor gate under the NARROW hook: 34/34", "narrow-hook 34/34"),
            (r"\(i\)  guard dropped -> anchor gate 33/34 breaking exactly "
             r"'no-SWMR IRIW1-sys'", "guard-dropped 33/34 on no-SWMR IRIW1-sys"),
            (r"\(ii\) !SWMR rows moved \(X2A_TRANSFERS=1 branch\): narrow 48  wide 68  "
             r"delta 20", "48/68/20"),
            (r"\(iii\) wide \\ narrow == 17 K-CPU rows \(memo 5\.4\) \+ 3 fr-only rows",
             "delta == K-CPU + FR3")):
        need(re.search(pat, out), "G15",
             "build-amd-oracle.sh --g15 did not print %s; it printed:\n%s"
             % (what, out[-800:]))
    # independent re-derivation of the K-CPU set from the corpus + the CSV.
    # The failure must NAME the rows, not just say the sets differ.
    der = sorted(kcpu_derived(C, rows))
    if der != KCPU_ROWS:
        need(False, "G15",
             "the K-CPU set re-derived from the corpus is not memo 5.4's 17 rows: "
             "pinned-but-not-derived %s ; derived-but-not-pinned %s"
             % (sorted(set(KCPU_ROWS) - set(der)), sorted(set(der) - set(KCPU_ROWS))))
    if not [f for f in FAIL if f.startswith("G15")]:
        print("   G15 (i)-(iv) OK; K-CPU re-derived independently and matches")


# ===========================================================================
# PHASE 8 -- G10.  The downstream census pins, as a LEDGER.
#
# memo 9.4 G10 wants every downstream census recomputed from first principles.
# Today those pins are the NVIDIA oracle's (50 / 319 / 42) and the AMD run lane
# does not exist yet, so flipping them here would break a live gate for a lane
# nothing runs.  What this phase does instead is FAIL CLOSED on drift in either
# direction: each pin is read from its file, asserted to still be the NVIDIA
# value, and the AMD value it must become is printed beside it.  G11 (the mu-map)
# is NOT implemented -- see the note below.
# ===========================================================================
DOWNSTREAM = [
    ("hetlitmus/verify/corpus-gate.sh", r"^EXPECT_HET=(\d+)", "411", "411",
     "shared by both oracles -- the corpus is one corpus"),
    ("hetlitmus/verify/verdictcheck.py",
     r'^CENSUS = \{"Disallowed": (\d+), "Allowed": (\d+), "NO-ORACLE": (\d+)\}',
     "50/319/42", "19/258/134", "verdictcheck.CENSUS"),
    ("hetlitmus/verify/controlmap.py", r"^N_DISALLOWED = (\d+)", "50", "19",
     "controlmap.N_DISALLOWED -- and its lattice is AArch64 (memo 7.D11)"),
]


def phase8(rows, root=None):
    root = Path(root or ROOT)
    print("== Phase 8 -- G10: downstream census pins (ledger; fails closed on drift) ==")
    for rel, rx, nv, amd, note in DOWNSTREAM:
        p = root / rel
        if not p.exists():
            fail("G10", "downstream file %s is missing" % rel)
            continue
        m = re.search(rx, p.read_text(), re.M)
        if not m:
            fail("G10", "the pin in %s no longer matches %r -- G10 has gone blind "
                        "on it" % (rel, rx))
            continue
        got = "/".join(m.groups())
        need(got == nv, "G10",
             "%s pins %s; this ledger records the NVIDIA value %s and the AMD "
             "value %s.  Either the pin moved without updating the ledger or the "
             "AMD run lane landed -- resolve it, do not adjust the target."
             % (rel, got, nv, amd))
        print("   %-38s now %-9s AMD needs %-9s (%s)" % (rel, got, amd, note))
    a = "%d/%d/%d" % (CENSUS_VERDICT["Disallowed"], CENSUS_VERDICT["Allowed"],
                      CENSUS_VERDICT["NO-ORACLE"])
    need(a == "19/258/134", "G10", "the AMD census this ledger promises is %s" % a)
    print("   G11 is Phase 9 (landed by P2a 2026-08-02); the mu-map it gates is "
          "hetlitmus/tests/het/control-map-amd.csv")


# ===========================================================================
# PHASE 9 -- G11.  The mu-map, FAIL-CLOSED AT SELECTION TIME (memo 9.4 G11,
# memo 1.2 deliverable 4, memo 7.D11).
#
# Every Disallowed row needs a Layer-A positive control: an existing corpus test
# that is oracle-Allowed, STRUCTURALLY IDENTICAL and STRICTLY WEAKER
# componentwise -- on the x86 lattice, not the AArch64 one.  D11's point is that
# the AMD map must be REGENERATED: on x86 the CPU lattice loses its middle rung
# (STLR / LDAPR / DMB.ST / DMB.LD all image to a plain MOV), so a candidate that
# only moves within {ra, st, ld} runs the IDENTICAL program on MI300A and vouches
# for nothing.  That is measured below, not asserted.
#
# The derivation lives in controlmap.py behind `--lattice x86' so there is ONE
# implementation of `weakening_of' for both vendors; this phase runs it, audits
# the committed file against a fresh derivation, and PINS the 16 rows for which
# the corpus has no mutant at all -- which is the number a silently-missing
# control would hide (B6a's lesson: a mu-map that cannot fire is worse than no
# control).
# ===========================================================================
# The Disallowed rows with NO Layer-A mutant, MEASURED and pinned: EMPTY since
# D26.  Pre-strike it was 16 of memo 5.4's 17 K-CPU rows (a K-CPU verdict is
# carried by the CPU procs, so no GPU-axis weakening reaches an Allowed
# neighbour); those 16 left the Disallowed set with the D26 demotion, and every
# surviving S_NTA row has LB-cg-sys-relaxed-style Allowed siblings.  The pin is
# what notices if a future re-key returns a row whose positive control cannot
# fire (B6a's lesson).
NO_MU_ROWS = []
AMD_MAP = HET / "control-map-amd.csv"
# MEASURED 2026-08-02: candidate (T, mu) pairs the x86 lattice admits and the
# AArch64 one refuses.  See the two-directional assertion in phase9.
# Pre-strike this was 47.  D26 emptied the discriminating population: every
# {ra,st,ld}-internal candidate pair had its T in the demoted 127, and the 19
# surviving LB rows admit the same pairs on both lattices.  The lost==0 half
# still bites (it is population-independent); this pin returns to a positive
# value if the toggle set is ever re-armed.
EXPECT_D11_GAINED = 0


def phase9(rows, root=None):
    print("== Phase 9 -- G11: the mu-map on the x86 lattice (memo 7.D11) ==")
    sys.path.insert(0, str(ROOT / "hetlitmus" / "verify"))
    try:
        import controlmap as cm
    except Exception as e:                                   # fail closed
        fail("G11", "cannot import controlmap.py (%s) -- the mu-map is UNGATED" % e)
        return
    saved = cm.LATTICE
    try:
        cm.set_lattice("x86")
        tests, oracle = cm.load(str(HET), str(CSVPATH))
        need(len(tests) == EXPECT_ORACLE_ROWS, "G11",
             "controlmap parsed %d corpus tests not %d" % (len(tests), EXPECT_ORACLE_ROWS))
        mrows, errors = cm.derive(tests, oracle)
        for e in errors:
            fail("G11", e)
        dis = [r for r in mrows if r[1] == "Disallowed"]
        need(len(dis) == CENSUS_VERDICT["Disallowed"], "G11",
             "the map holds %d Disallowed rows not %d"
             % (len(dis), CENSUS_VERDICT["Disallowed"]))
        nomu = sorted(r[0] for r in dis if r[2] == "none")
        need(nomu == NO_MU_ROWS, "G11",
             "the set with NO Layer-A mutant is not the pinned 16: only-derived "
             "%s only-pinned %s" % (sorted(set(nomu) - set(NO_MU_ROWS)),
                                    sorted(set(NO_MU_ROWS) - set(nomu))))
        withmu = [r for r in dis if r[2] not in ("none", "-")]
        need(len(withmu) == len(dis) - len(NO_MU_ROWS), "G11",
             "%d rows carry a mutant; expected %d"
             % (len(withmu), len(dis) - len(NO_MU_ROWS)))
        # every crowned mu is Allowed IN THE AMD ORACLE (not the NVIDIA one)
        badmu = [r[0] for r in withmu if rows.get(r[2], {}).get("verdict") != "Allowed"]
        need(not badmu, "G11",
             "%d mu(T) are not Allowed in expected-amd.csv: %s" % (len(badmu), badmu[:3]))
        # the COMMITTED file must be what this derivation produces
        if not AMD_MAP.exists():
            fail("G11", "%s does not exist -- regenerate with "
                        "controlmap.py --lattice x86 --emit" % AMD_MAP.name)
        else:
            fresh = cm.render(mrows)
            need(AMD_MAP.read_text() == fresh, "G11",
                 "%s is STALE: it is not what controlmap.py --lattice x86 --emit "
                 "produces from this corpus and this oracle" % AMD_MAP.name)
            for e in cm.audit_map(AMD_MAP.read_text(), tests, oracle):
                fail("G11", "committed map: %s" % e)
        # D11 MEASURED, not asserted: how much the lattice change actually moves.
        # A candidate pair (T, M) that is a strict weakening on AArch64 but NOT
        # on x86 is a control that would have been crowned by a TRANSLATION of
        # the NVIDIA map and would run the identical program on MI300A.
        x86pairs = _mu_pairs(cm, tests, oracle)
        cm.set_lattice("aarch64")
        tests_a, _ = cm.load(str(HET), str(CSVPATH))
        aapairs = _mu_pairs(cm, tests_a, oracle)
        lost, gained = aapairs - x86pairs, x86pairs - aapairs
        print("   %d Disallowed: %d carry a mutant / %d have none (pinned EMPTY since D26)"
              % (len(dis), len(withmu), len(nomu)))
        print("   D11 measured over the AMD oracle: %d admissible (T mu) pairs on "
              "the x86 lattice vs %d on AArch64 -- gained %d lost %d"
              % (len(x86pairs), len(aapairs), len(gained), len(lost)))
        # The two directions say different things and BOTH are asserted.
        #  * `lost' > 0 would be the dangerous one: a pair that is a strict
        #    weakening on AArch64 but NOT on x86 differs ONLY within {ra,st,ld},
        #    so on MI300A the "control" would run the IDENTICAL program.  It is
        #    ZERO on this corpus -- measured, not assumed -- and the pin is what
        #    keeps it that way as the corpus grows.
        #  * `gained' > 0 is what makes the re-derivation NOT a translation: the
        #    x86 collapse makes 47 further candidates admissible, every one of
        #    which an AArch64-lattice map would have refused.  If the collapse
        #    ever stops applying this goes to 0 and the phase reddens.
        need(not lost, "G11",
             "%d (T mu) pair(s) are a strict weakening on AArch64 but NOT on x86 "
             "-- on MI300A those controls run the IDENTICAL program as their test "
             "and vouch for nothing: %s" % (len(lost), sorted(lost)[:3]))
        need(len(gained) == EXPECT_D11_GAINED, "G11",
             "the x86 lattice admits %d candidate pairs the AArch64 one refuses; "
             "P2a measured %d.  If this is 0 the x86 collapse has stopped applying "
             "and `regenerated not translated' (D11) is measuring nothing"
             % (len(gained), EXPECT_D11_GAINED))
        print("   committed %s matches a fresh derivation" % AMD_MAP.name)
    finally:
        cm.set_lattice(saved)


def _mu_pairs(cm, tests, oracle):
    """{(T, M)} : M is an admissible mu of T under the lattice cm is set to."""
    out = set()
    for t in tests:
        if oracle.get(t) != "Disallowed":
            continue
        for m in tests:
            if m != t and oracle.get(m) == "Allowed" \
               and tests[m].scopes == tests[t].scopes \
               and cm.weakening_of(tests[t], tests[m]) is None:
                out.add((t, m))
    return out


# ===========================================================================
# BITE.  Each injection names the phase it MUST redden.  Corruption AND OMISSION.
# ===========================================================================
def _scratch_tree():
    tmp = tempfile.mkdtemp(prefix="amdorder-bite-")
    (Path(tmp) / "het").mkdir()
    shutil.copy(GRIDLIB, Path(tmp) / "_grid_lib.sh")
    shutil.copy(BUILDER, Path(tmp) / "het" / BUILDER.name)
    for f in HET.glob("*.litmus"):
        os.symlink(f, Path(tmp) / "het" / f.name)
    return tmp


BUILD_INJECTIONS = [
    # NB the ord+ / role mutations are on the FENCE rows, not the access rows.
    # MEASURED: giving `acc-release' the WR pair, or `acc-acquire' the rel role,
    # changes NOTHING -- gpu_annot only ever puts `release' on a W and `acquire'
    # on an R, so acc-release@WR and an A-cumulative acquire LOAD are structurally
    # unreachable.  Those two injections are inert, which is a property of the
    # corpus and not of the gate; the reachable form of each is the fence row,
    # and that is what memo 3.2.1's WR caveat (D16) is about anyway.
    ("G9/ord+", "PRIM_GPU fence-acquire GAINS the WR pair -- the D16 reading this "
                "memo refuses (it would flip 5 rows Allowed -> Disallowed)",
     '[fence-acquire]="RR RW|acq|', '[fence-acquire]="RR RW WR|acq|'),
    ("G9/ord-", "PRIM_GPU acc-acquire LOSES the RW pair (an acquire that leaves "
                "load;store free)",
     '[acc-acquire]="RR RW|acq|', '[acc-acquire]="RR|acq|'),
    ("G9/ms", "the morally-strong clause is dropped -- per-side ordering alone "
              "would then cut every cycle",
     'ms() {                             # ms <pa> <ia> <pb> <ib>\n'
     '  local pa="$1" ia="$2" pb="$3" ib="$4" s',
     'ms() {                             # ms <pa> <ia> <pb> <ib>\n'
     '  MS_WHY=dropped; return 0\n'
     '  local pa="$1" ia="$2" pb="$3" ib="$4" s'),
    # MEASURED: every "role GAINS" mutation is inert on this corpus -- `rel' is
    # read only by cum() and `acq' only by fresh(), no cum-relevant write has an
    # acquire fence po-before it, and S_FR_STALE is EMPTY (0 of 411).  The
    # reachable direction is loss, and that is what proves the column is live.
    ("G9/role", "PRIM_GPU acc-release LOSES the `rel' ROLE -- a release store "
                "that is no longer A-cumulative",
     '[acc-release]="WW RW|rel|', '[acc-release]="WW RW||'),
    ("G9/role2", "PRIM_GPU acc-acquire LOSES the `acq' ROLE -- must trip the "
                 "fail-closed src_of accessor on the unregistered class S_FR_STALE",
     '[acc-acquire]="RR RW|acq|', '[acc-acquire]="RR RW||'),
    ("G9/token", "gpu_annot mis-maps the corpus token `acquire' to relaxed",
     "    acquire) if [ \"$1\" = R ]; then GA=acquire; else GA=relaxed; fi;;",
     "    acquire) GA=relaxed;;"),
    ("G9/cum", "`cum' always true -- must redden the 4 S_RF_NOCUM rows",
     'cum() {                            # cum <proc-idx> <shared-idx> <model> <need>\n'
     '  load_proc "$1"',
     'cum() {                            # cum <proc-idx> <shared-idx> <model> <need>\n'
     '  return 0\n  load_proc "$1"'),
    ("G9/ws", "`ws' always true -- must redden the 7 S_WS_FENCE + S_WS_REL rows",
     'ws() {                             # ws <proc-idx> <model>\n  load_proc "$1"',
     'ws() {                             # ws <proc-idx> <model>\n'
     '  return 0\n  load_proc "$1"'),
    ("G15/guard", "OMISSION: the M == CDNA3 guard on !SWMR clause (ii) is DELETED",
     '[ "$model" = "$HOOK_II_GUARD_MODEL" ] && has_second_observer',
     'has_second_observer'),
    ("G15/clause2", "OMISSION: !SWMR clause (ii) is deleted outright",
     '''          if [ "$model" = "$HOOK_II_GUARD_MODEL" ] && has_second_observer "$sp" "$si" "$dp"; then
            VERDICT=Allowed; CLASS=S_NOSWMR; return
          fi
''', ''),
    ("G12/mcaclause", "OMISSION: the R;R clause of the S_CUT_MCA predicate is "
                      "deleted -- the set silently grows to 10",
     '      [ "$LP_DIRS" = RR ] && return 0', '      return 0'),
    ("G14/scacc", "PRIM_GPU's unreachable acc-sc row is declared REACHABLE",
     '[acc-sc]="WW RR WR RW|rel acq sc|w/r[sc;S]|no"',
     '[acc-sc]="WW RR WR RW|rel acq sc|w/r[sc;S]|yes"'),
    ("G0/rot", "SHAPE_ROT[MP] is perturbed 0 -> 1.  MEASURED: this aborts in the "
               "ANCHOR LOADER (bad device char in anchor cut) BEFORE it reaches "
               "G0's own assertion, because cycle() applies the rotation to the "
               "edge word list before grouping events into procs, so a rotation "
               "change can change the derived proc count.  Fail-closed either "
               "way -- but memo 9.4 G0's stated bite does NOT exercise G0 and "
               "G0/blank below is the one that does",
     "  [MP]=0 [SB]=0", "  [MP]=1 [SB]=0"),
    ("A_PROV/relabel", "an anchor row is relabelled artifact-csv-corrected -> "
                       "artifact; memo 9.4 G1 requires the gate to CARRY the two "
                       "corrected values and it used to parse them into a dead "
                       "variable",
     '"Compound|MP1-cta-F|Allowed|MP|gc|W:relaxed:cta W:release:cta;R:x86:- R:x86:-|1|artifact-csv-corrected"',
     '"Compound|MP1-cta-F|Allowed|MP|gc|W:relaxed:cta W:release:cta;R:x86:- R:x86:-|1|artifact"'),
    ("G1/anchor", "one anchor expectation is flipped (Compound MP1-sys-F "
                  "Disallowed -> Allowed)",
     '"Compound|MP1-sys-F|Disallowed|MP|gc|',
     '"Compound|MP1-sys-F|Allowed|MP|gc|'),
    # G1 used to be bitten ONLY by corruption.  MEASURED 2026-08-02 (P2a
    # reconciliation): deleting a row instead of flipping one made `--anchors'
    # and `--g15' print "anchor gate: 33/33" and exit 0 -- a silently truncated
    # table read as green in exactly the two modes a reviewer runs standalone.
    # The size assert now lives on the ANCHORS array at top level; these two
    # injections keep it honest, in the default mode and in the mode that was
    # blind.  Delete the assert and both of these go green again.
    ("G1/omit", "OMISSION: one whole anchor row is DELETED (34 -> 33)",
     ' "GPU-Only|MP-sys-F|Disallowed|MP|gg|W:relaxed:sys W:release:sys;'
     'R:acquire:sys R:relaxed:sys|1|artifact"\n', ''),
    ("G1/omit-anchors-mode", "OMISSION: an anchor row is DELETED and the gate is "
                             "run through `--anchors' -- the mode that used to "
                             "report a truncated table as 33/33 and exit 0",
     ' "GPU-Only|MP-sys-F|Disallowed|MP|gg|W:relaxed:sys W:release:sys;'
     'R:acquire:sys R:relaxed:sys|1|artifact"\n', '', "--anchors"),
    ("G12/shape", "OMISSION: the shape clause of the S_CUT_MCA predicate is "
                  "deleted -- the set silently grows to 35",
     '  case "$PROG_SHAPE" in IRIW|RWC) :;; *) return 1;; esac\n', ''),
    ("G4/cellcnt", "memo 5.4.1's transcribed load-bearing count for fence-sc@RW "
                   "is changed 18 -> 17",
     "fence-sc@RW:18", "fence-sc@RW:17", "--cells"),
    ("G4/celldrop", "OMISSION: a whole cell is dropped from the transcribed "
                    "5.4.1 table -- the remaining eleven must not still cover 146",
     "fence-sc@WW:12 ", "", "--cells"),
]

# corpus-side bites: a FILE added to the corpus, not an edit to the rule.
GG_FIXTURE = """Het MP-gg-sys-relaxed
"probe: both procs on the GPU -- G13 must refuse it"
{
}
 P0:gpu              | P1:gpu              ;
 w[relaxed,sys] x 1  | r[relaxed,sys] r0 y ;
 w[relaxed,sys] y 1  | r[relaxed,sys] r1 x ;
scopes: (sys (gpu (cta P0) (cta P1)))
exists (1:r0=1 /\\ 1:r1=0)
"""
SCACC_FIXTURE = """Het MP-gg-sys-release
"probe: an sc ACCESS -- G14 must refuse it"
{
}
 P0:gpu              | P1:gpu              ;
 w[relaxed,sys] x 1  | r[relaxed,sys] r0 y ;
 w[sc,sys] y 1       | r[relaxed,sys] r1 x ;
scopes: (sys (gpu (cta P0) (cta P1)))
exists (1:r0=1 /\\ 1:r1=0)
"""
def _g0_blanked_body():
    """MP-cg-sys-relaxed with one shared CPU access DELETED.

    This is the bite memo 9.4 G0 ought to have specified.  Perturbing SHAPE_ROT
    -- what it does specify -- aborts in the anchor loader or on the proc-count
    check before G0 runs, and mutating the RULE (a token map, a gpu_annot arm)
    reddens G15 first because G15 runs before G0 and re-classifies the whole
    corpus.  Deleting an access from a .litmus BODY leaves the rule untouched, so
    every earlier gate passes and G0's own program comparison is what fires."""
    src = (HET / "MP-cg-sys-relaxed.litmus").read_text()
    out, dropped = [], False
    for line in src.splitlines(True):
        if not dropped and line.lstrip().startswith("STR W2,"):
            # keep the column count intact: blank the CPU cell, keep the `;'
            cols = line.rstrip("\n").rstrip(";").split("|")
            cols[0] = " " * len(cols[0])
            out.append("|".join(cols) + ";\n")
            dropped = True
            continue
        out.append(line)
    if not dropped:                       # fail closed rather than bite nothing
        return None
    return "".join(out)


CORPUS_INJECTIONS = [
    ("G13/gpugpu", "a GPU-GPU-adjacent fixture is added to the corpus",
     "MP-gg-sys-relaxed.litmus", GG_FIXTURE, "G13"),
    ("G14/scfile", "a fixture carrying a w[sc,sys] ACCESS is added to the corpus",
     "MP-gg-sys-release.litmus", SCACC_FIXTURE, "G14"),
    ("G0/blank", "OMISSION inside a corpus BODY: one shared CPU access of "
                 "MP-cg-sys-relaxed is blanked, so the name-derived program "
                 "stops being the corpus program (the bite that actually "
                 "reaches G0 -- see the note in _g0_blanked_body)",
     "MP-cg-sys-relaxed.litmus", _g0_blanked_body(), "G0"),
]


def bite():
    print("===== AMDORDERCHECK BITE: does each gate FAIL when its object is wrong? =====")
    rc = 0
    for inj in BUILD_INJECTIONS:
        tag, desc, old, new = inj[:4]
        mode = inj[4] if len(inj) > 4 else None
        tmp = _scratch_tree()
        try:
            f = Path(tmp) / "het" / BUILDER.name
            s = f.read_text()
            if old not in s:
                print("  *** %-14s BITE BROKEN: the injection site %r is gone"
                      % (tag, old[:48]))
                rc = 1
                continue
            f.write_text(s.replace(old, new, 1))
            p = subprocess.run(["bash", str(f)] + ([mode] if mode else []),
                               cwd=str(Path(tmp) / "het"),
                               capture_output=True, text=True)
            out = (p.stdout + p.stderr).strip().splitlines()
            why = [l for l in out if "FAILED" in l or l.startswith("build-amd-oracle:")]
            syntax = [l for l in out if "syntax error" in l or "command not found" in l]
            if p.returncode == 0:
                print("  *** %-14s DID NOT BITE (exit 0) -- %s" % (tag, desc))
                rc = 1
            elif syntax:
                # A bite that reddens because the SHELL choked is not evidence
                # that the gate caught the mutation.
                print("  *** %-14s reddened on a SHELL ERROR not the gate: %s"
                      % (tag, syntax[0][:110]))
                rc = 1
            elif not why:
                print("  *** %-14s exited %d with no gate message: %s"
                      % (tag, p.returncode, out[-1][:110] if out else ""))
                rc = 1
            else:
                print("  ok  %-14s reddens: %s" % (tag, why[-1][:140]))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    for tag, desc, fname, body, want in CORPUS_INJECTIONS:
        if body is None:
            print("  *** %-14s BITE BROKEN: the injection could not be built "
                  "(its site is gone from the corpus)" % tag)
            rc = 1
            continue
        tmp = _scratch_tree()
        try:
            # _scratch_tree SYMLINKS the corpus, so an injection that names an
            # EXISTING test must replace the link, never write through it.
            # (Measured the hard way on 2026-08-02: the first version of the
            # G0/blank injection wrote through the symlink and blanked a line of
            # the real hetlitmus/tests/het/MP-cg-sys-relaxed.litmus.)
            victim = Path(tmp) / "het" / fname
            if victim.is_symlink() or victim.exists():
                victim.unlink()
            victim.write_text(body)
            p = subprocess.run(["bash", str(Path(tmp) / "het" / BUILDER.name)],
                               cwd=str(Path(tmp) / "het"),
                               capture_output=True, text=True)
            out = (p.stdout + p.stderr).strip().splitlines()
            why = [l for l in out if want in l and ("FAIL" in l or "die" in l
                                                    or l.startswith("build-amd-oracle:"))]
            if p.returncode == 0:
                print("  *** %-14s DID NOT BITE (exit 0) -- %s" % (tag, desc))
                rc = 1
            elif not why:
                print("  *** %-14s reddened but not on %s: %s"
                      % (tag, want, out[-1][:110] if out else ""))
                rc = 1
            else:
                print("  ok  %-14s reddens: %s" % (tag, why[-1][:140]))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # --- checker-side bites: the phases this file owns ---------------------
    C = Corpus()
    srcmap = read_builder_sources()
    rows = read_csv()

    def run_isolated(fn, *a):
        global FAIL
        keep, FAIL = FAIL, []
        try:
            fn(*a)
            return list(FAIL)
        finally:
            FAIL = keep

    # G5 corruption: flip one verdict
    r2 = {k: dict(v) for k, v in rows.items()}
    r2["MP-cg-sys-relaxed"]["verdict"] = "Disallowed"
    got = run_isolated(phase3, C, r2, srcmap)
    print("  %s G5/corrupt  %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G5 OMISSION: drop a row
    r3 = {k: v for k, v in rows.items() if k != "MP-cg-sys-relaxed"}
    got = run_isolated(phase3, C, r3, srcmap)
    print("  %s G5/omit     %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G5 half-blind regex: the classic "phase stopped reading half its rows".
    # Targets S_CUT_UNKEYED -- the largest class IN THE SHIPPING FILE.  It used
    # to name S_CUT, and after D26 demoted those 119 rows that injection blinded
    # the phase on a class no shipping row carries and SILENTLY STOPPED BITING:
    # exactly the failure this suite exists to catch, caught by its own bite.
    keep = dict(srcmap)
    sm2 = {k: v for k, v in srcmap.items() if v != "S_CUT_UNKEYED"}
    got = run_isolated(phase3, C, rows, sm2)
    print("  %s G5/blind    %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    srcmap = keep
    # G6 corruption: perturb one collapse-class member's verdict
    g = collections.defaultdict(list)
    for n in C.tests:
        g[x86_image(C, n)].append(n)
    victim = sorted(v for v in g.values() if len(v) > 1)[0]
    r4 = {k: dict(v) for k, v in rows.items()}
    r4[victim[0]]["verdict"] = ("Allowed" if r4[victim[0]]["verdict"] != "Allowed"
                                else "Disallowed")
    got = run_isolated(phase4, C, r4)
    print("  %s G6/corrupt  %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G12 corruption: relabel one S_CUT_MCA row's CLASS (its Source string) to
    # the ordinary S_CUT one.  The structural predicate still finds the 8 rows;
    # the CSV then labels only 7, which is the disagreement G12 exists to catch.
    r5 = {k: dict(v) for k, v in rows.items()}
    r5[MCA_ROWS[0]]["src"] = next(s for s, c in srcmap.items() if c == "S_CUT")
    got = run_isolated(phase6, C, r5, srcmap)
    print("  %s G12/corrupt %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G15/G7 OMISSION: corrupt the pinned K-CPU list by ONE row
    global KCPU_ROWS
    keepk = list(KCPU_ROWS)
    KCPU_ROWS = sorted(set(KCPU_ROWS) - {"RWC-ccg-sys-fence-2s"} | {"MP-cg-sys-relaxed"})
    got = run_isolated(phase7, C, rows)
    named = any("RWC-ccg-sys-fence-2s" in x or "K-CPU" in x for x in got)
    print("  %s G15/kcpu    %s" % ("ok " if got and named else "***",
                                   got[0][:140] if got else "DID NOT BITE"))
    rc |= 0 if (got and named) else 1
    KCPU_ROWS = keepk
    # G3 corruption: give ord_x86 the WR cell it must not have
    global ORD_X86_PLAIN
    keepo = ORD_X86_PLAIN
    ORD_X86_PLAIN = frozenset(("WW", "RR", "RW", "WR"))
    got = run_isolated(phase1, C)
    ORD_X86_PLAIN = keepo
    print("  %s G3/corrupt  %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G3 OMISSION: half-blind the shape list -- the cell count must catch it
    keepc = dict(C.cyc)
    C.cyc = {k: v for k, v in C.cyc.items() if k in ("MP", "SB")}
    got = run_isolated(phase1, C)
    C.cyc = keepc
    named = any("half blind" in x for x in got)
    print("  %s G3/omit     %s" % ("ok " if (got and named) else "***",
                                   got[-1][:130] if got else "DID NOT BITE"))
    rc |= 0 if (got and named) else 1
    # G8 corruption: label a T_x86-`Sometimes' row Disallowed
    r6 = {k: dict(v) for k, v in rows.items()}
    r6["SB-cg-sys-relaxed"]["verdict"] = "Disallowed"
    got = run_isolated(phase5, C, r6)
    print("  %s G8/corrupt  %s" % ("ok " if got else "***",
                                   got[0][:120] if got else "DID NOT BITE"))
    rc |= 0 if got else 1
    # G7/G8 OMISSION: make T_x86 stop being a strengthening (drop the MFENCE the
    # sys-scope sc fence must render as).  Both the soundness assertion and the
    # K-CPU necessary condition must abort.
    global TX86_KEEP_MFENCE
    keept = TX86_KEEP_MFENCE
    TX86_KEEP_MFENCE = frozenset()
    got = run_isolated(phase5, C, rows)
    TX86_KEEP_MFENCE = keept
    named = any(x.startswith("G7") for x in got)
    print("  %s G7/nonstr   %s" % ("ok " if (got and named) else "***",
                                   [x for x in got if x.startswith("G7")][:1] or got[:1]))
    rc |= 0 if (got and named) else 1
    # G10 corruption + omission: move a downstream pin / delete it
    for label, rel, old, new in (
            ("G10/corrupt", "hetlitmus/verify/verdictcheck.py",
             'CENSUS = {"Disallowed": 50', 'CENSUS = {"Disallowed": 146'),
            ("G10/omit   ", "hetlitmus/verify/controlmap.py",
             "N_DISALLOWED = 50", "# N_DISALLOWED removed")):
        tmp = tempfile.mkdtemp(prefix="amdorder-g10-")
        try:
            (Path(tmp) / "hetlitmus" / "verify").mkdir(parents=True)
            for rel2, _rx, _a, _b, _n in DOWNSTREAM:
                shutil.copy(ROOT / rel2, Path(tmp) / rel2)
            f = Path(tmp) / rel
            s = f.read_text()
            if old not in s:
                print("  *** %-11s BITE BROKEN: site %r gone" % (label, old))
                rc = 1
                continue
            f.write_text(s.replace(old, new, 1))
            got = run_isolated(phase8, rows, tmp)
            print("  %s %-11s %s" % ("ok " if got else "***", label,
                                     got[0][:130] if got else "DID NOT BITE"))
            rc |= 0 if got else 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    # G4 OMISSION: blank one cell's instrument name
    idx = G3ART / "g3-cell-instruments.json"
    if idx.exists():
        J = json.loads(idx.read_text())
        tmp = tempfile.mkdtemp(prefix="amdorder-g4bite-")
        try:
            for f in G3ART.iterdir():
                if f.is_file():
                    shutil.copy(f, tmp)
            old = globals()["G3ART"]
            for label, mutate in (
                    ("G4/blank", lambda J2: [rec.update(kernel="")
                                             for rec in J2["cells"]
                                             if rec.get("cell") == "fence-sc@WW"]),
                    ("G4/omit ", lambda J2: J2.__setitem__(
                        "cells", [r for r in J2["cells"]
                                  if r.get("cell") != "fence-sc@WW"]))):
                J2 = json.loads(idx.read_text())
                mutate(J2)
                (Path(tmp) / "g3-cell-instruments.json").write_text(json.dumps(J2))
                globals()["G3ART"] = Path(tmp)
                got = run_isolated(phase2, C)
                globals()["G3ART"] = old
                named = any("fence-sc@WW" in x for x in got)
                print("  %s %-11s %s" % ("ok " if (got and named) else "***", label,
                                         got[0][:130] if got else "DID NOT BITE"))
                rc |= 0 if (got and named) else 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("  *** G4/blank    SKIPPED -- %s absent" % idx)
        rc = 1
    # G5 CENSUS-PRESERVING corruption: swap an Allowed and a NO-ORACLE verdict.
    # Every aggregate is unchanged; only the per-row class/verdict check sees it.
    r8 = {k: dict(v) for k, v in rows.items()}
    r8["MP-cg-sys-relaxed"]["verdict"] = "NO-ORACLE"
    r8["2+2W-cg-sys-fence"]["verdict"] = "Allowed"
    got = run_isolated(phase3, C, r8, srcmap)
    named = any("class does not license" in x for x in got)
    print("  %s G5/swap     %s" % ("ok " if (got and named) else "***",
                                   (got or ["DID NOT BITE"])[0][:150]))
    rc |= 0 if (got and named) else 1
    # --- G5: memo 5.2 vs the shipped strings, corruption AND omission --------
    global MEMO
    keepm = MEMO
    if MEMO.exists():
        tmp = tempfile.mkdtemp(prefix="amdorder-memobite-")
        try:
            base = MEMO.read_text()
            victim = re.search(r"^\| `S_ROLE` \| .* \| `(.*)` \|$", base, re.M)
            for label, mutated, want in (
                    ("G5/memoedit", base.replace(victim.group(1),
                                                 "TAMPERED " + victim.group(1), 1),
                     "DRIFTED"),
                    ("G5/memodrop", "\n".join(l for l in base.splitlines()
                                              if not l.startswith("| `S_NTA` |")),
                     "not 11"),
                    ("G5/memogone", None, "UNGATED")):
                f = Path(tmp) / "memo.md"
                if mutated is None:
                    MEMO = Path(tmp) / "absent.md"
                else:
                    f.write_text(mutated)
                    MEMO = f
                got = run_isolated(phase3, C, rows, srcmap)
                MEMO = keepm
                named = any(want in x for x in got)
                print("  %s %-11s %s" % ("ok " if (got and named) else "***", label,
                                         (got or ["DID NOT BITE"])[0][:130]))
                rc |= 0 if (got and named) else 1
        finally:
            MEMO = keepm
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("  *** G5/memoedit SKIPPED -- %s absent" % MEMO)
        rc = 1
    # --- G11: the mu-map, corruption AND omission ---------------------------
    global AMD_MAP
    keepa = AMD_MAP
    if AMD_MAP.exists():
        tmp = tempfile.mkdtemp(prefix="amdorder-g11bite-")
        try:
            base = AMD_MAP.read_text().splitlines(True)
            def _rows_with_mu():
                return [i for i, l in enumerate(base)
                        if not l.startswith("#") and len(l.split(",")) > 3
                        and l.split(",")[1] == "Disallowed"
                        and l.split(",")[2] not in ("none", "-", "Mu")]
            victims = _rows_with_mu()
            muts = []
            # CORRUPTION: point one mu at a Disallowed test
            v = victims[0]
            f = base[v].split(",")
            muts.append(("G11/corrupt", [l if i != v else
                                         ",".join([f[0], f[1], "MP-cg-sys-acquire"] + f[3:])
                                         for i, l in enumerate(base)], "MP-cg-sys-acquire"))
            # CORRUPTION 2: hand-write `none' on a row that HAS a mutant
            f2 = base[victims[1]].split(",")
            muts.append(("G11/none   ", [l if i != victims[1] else
                                         ",".join([f2[0], f2[1], "none", "-"] + f2[4:])
                                         for i, l in enumerate(base)], "is an existing Allowed"))
            # OMISSION: delete a row outright
            muts.append(("G11/omit   ", [l for i, l in enumerate(base) if i != v], "STALE"))
            for label, lines, want in muts:
                fpath = Path(tmp) / "control-map-amd.csv"
                fpath.write_text("".join(lines))
                AMD_MAP = fpath
                got = run_isolated(phase9, rows)
                AMD_MAP = keepa
                named = any(want in x for x in got)
                print("  %s %-11s %s" % ("ok " if (got and named) else "***", label,
                                         (got or ["DID NOT BITE"])[0][:140]))
                rc |= 0 if (got and named) else 1
        finally:
            AMD_MAP = keepa
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("  *** G11/corrupt SKIPPED -- %s absent" % AMD_MAP)
        rc = 1
    print("BITE %s (%s injections)" % ("OK (every injection reddened its phase)"
                                       if rc == 0 else "INCOMPLETE -- see *** above",
                                       len(BUILD_INJECTIONS) + len(CORPUS_INJECTIONS) + NCHECKER))
    return rc


# ===========================================================================
def main():
    args = sys.argv[1:]
    if "--bite" in args:
        return bite()
    only = None
    if "--phase" in args:
        only = int(args[args.index("--phase") + 1])
    C = Corpus()
    drift = {s: f for s, f in C.rot_fits.items()
             if C.rot_builder.get(s) not in f}
    if drift:
        fail("G0", "SHAPE_ROT drift: the corpus fits %s but build-amd-oracle.sh "
                   "has %s" % (drift, {s: C.rot_builder.get(s) for s in drift}))
    srcmap = read_builder_sources()
    if len(srcmap) != 13:
        fail("G5", "build-amd-oracle.sh defines %d S_* strings not 13 (11 shipping "
                   "+ S_CUT/S_CUT_MCA for the X2A_TRANSFERS=1 branch)" % len(srcmap))
    rows = read_csv()
    for i, fn in ((1, lambda: phase1(C)), (2, lambda: phase2(C)),
                  (3, lambda: phase3(C, rows, srcmap)), (4, lambda: phase4(C, rows)),
                  (5, lambda: phase5(C, rows)), (6, lambda: phase6(C, rows, srcmap)),
                  (7, lambda: phase7(C, rows)), (8, lambda: phase8(rows)),
                  (9, lambda: phase9(rows))):
        if only in (None, i):
            fn()
    if FAIL:
        print("\nAMDORDERCHECK FAILED: %d assertion(s)." % len(FAIL))
        for f in FAIL:
            print("  *** %s" % f)
        return 1
    print("\nAMDORDERCHECK OK -- expected-amd.csv (%d rows) agrees with every "
          "instrument this gate can reach.  NOTE: not one line of it is a "
          "hardware measurement, and preconditions P1/P2/P3 of memo sect 8 are "
          "UNRESOLVED." % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
