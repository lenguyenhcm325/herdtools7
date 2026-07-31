#!/usr/bin/env python3
"""dupcheck.py -- Q10 step 0 -- the ISOMORPHISM (duplicate-test) gate.

WHY THIS GATE EXISTS.  `hetlitmus/tests/het/generate.sh' loops
shape x device-cut x scope x order and dedups only by BYTE-COMPARING a variant
against one designated sibling (generate.sh:97-102 and :150-155).  That filter
cannot see the duplicates that actually dominate the corpus: two DIFFERENT names
whose programs are the same experiment up to (permutation of procs) x (renaming
of locations), with the device tag travelling with the proc.

Measured 2026-07-30 (env-research/Q10-corpus-coverage.md sect 2.1): 338 committed
het tests are only **299 distinct** experiments.  All 39 redundant files are
`SB' / `LB' / `2+2W' -- the three shapes whose cycle is invariant under
rotation-by-two, which swaps P0 and P1, so the `cg' and `gc' device cuts emit the
SAME experiment with the labels exchanged (e.g. SB-cg-sys-relaxed is
SB-gc-sys-relaxed under P0<->P1, x<->y).  Their verdicts agree, so nothing is
wrong -- but they are not independent samples, and 3 of them sit inside the 16
`Disallowed' rows that carry the whole falsification claim.

WHY THE 39 ARE NOT DELETED.  The number 338 is pinned across corpus-gate.sh,
emit-all.sh, verdictcheck.py, statscheck.py, histcheck.py, the cram goldens and
expected-nvidia.csv; removing files is a wide-ripple change with no scientific
payoff (the verdicts are correct).  So they are ALLOWLISTED here, by exact class,
and this gate FAILS on any duplicate class that is not in the allowlist.  That
makes the widening of the two-sided variant vocabulary (Q10 steps 1-3) safe: a
new annotation axis multiplies across device cuts, so new duplicates are the
expected failure mode, and they now break the build instead of inflating the
census.

THE CANONICAL FORM is taken from env-research/Q10-probe/canon.py (the measured
basis of the Q10 analysis), adapted -- not rewritten: parse the Het test into
(proc -> ordered event list, condition atoms), then minimise the representation
over every permutation of procs x every renaming of locations.  Events carry
their annotation (`plain' / `rel' / `acq' / `dmb sy' / `release,sys' / ...), so a
weakening is NEVER canonically equal to the test it weakens; the device tag is
part of the proc record, so a cpu/gpu swap is NOT a duplicate.

WHAT IT CHECKS (both directions -- an allowlist that cannot rot):
  1. every duplicate class found in the corpus is in ALLOWLIST   (new dup -> FAIL)
  2. every ALLOWLIST class is still a real duplicate class       (stale -> FAIL)
The second half is what stops the allowlist becoming a rubber stamp: if a listed
partner is edited, renamed or deleted so the pair is no longer isomorphic, the
entry is dead weight and the gate says so.

Usage:  dupcheck.py [--dir D] [-q]   run the gate      (exit 0 = clean)
        dupcheck.py --bite           prove the gate FAILS when it must
"""

import argparse
import collections
import glob
import itertools
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "tests", "het")

# ---------------------------------------------------------------------------
# THE ALLOWLIST: the 39 duplicate classes measured at Q10 time (2026-07-30) and
# kept deliberately.  Every one is a `cg' cut and its `gc' mirror of a
# rotation-invariant shape (SB / LB / 2+2W).  Regenerate ONLY with a documented
# reason -- adding an entry here is how a real duplicate gets waved through.
# ---------------------------------------------------------------------------
ALLOWLIST = [
    ("2+2W-cg-cta-fence",      "2+2W-gc-cta-fence"),
    ("2+2W-cg-cta-relaxed",    "2+2W-gc-cta-relaxed"),
    ("2+2W-cg-cta-release",    "2+2W-gc-cta-release"),
    ("2+2W-cg-gpu-fence",      "2+2W-gc-gpu-fence"),
    ("2+2W-cg-gpu-relaxed",    "2+2W-gc-gpu-relaxed"),
    ("2+2W-cg-gpu-release",    "2+2W-gc-gpu-release"),
    ("2+2W-cg-sys-acqrel-2s",  "2+2W-gc-sys-acqrel-2s"),
    ("2+2W-cg-sys-fence",      "2+2W-gc-sys-fence"),
    ("2+2W-cg-sys-fence-2s",   "2+2W-gc-sys-fence-2s"),
    ("2+2W-cg-sys-relaxed",    "2+2W-gc-sys-relaxed"),
    ("2+2W-cg-sys-release",    "2+2W-gc-sys-release"),
    ("LB-cg-cta-acquire",      "LB-gc-cta-acquire"),
    ("LB-cg-cta-fence",        "LB-gc-cta-fence"),
    ("LB-cg-cta-relaxed",      "LB-gc-cta-relaxed"),
    ("LB-cg-cta-release",      "LB-gc-cta-release"),
    ("LB-cg-gpu-acquire",      "LB-gc-gpu-acquire"),
    ("LB-cg-gpu-fence",        "LB-gc-gpu-fence"),
    ("LB-cg-gpu-relaxed",      "LB-gc-gpu-relaxed"),
    ("LB-cg-gpu-release",      "LB-gc-gpu-release"),
    ("LB-cg-sys-acqrel-2s",    "LB-gc-sys-acqrel-2s"),
    ("LB-cg-sys-acquire",      "LB-gc-sys-acquire"),
    ("LB-cg-sys-fence",        "LB-gc-sys-fence"),
    ("LB-cg-sys-fence-2s",     "LB-gc-sys-fence-2s"),
    ("LB-cg-sys-relaxed",      "LB-gc-sys-relaxed"),
    ("LB-cg-sys-release",      "LB-gc-sys-release"),
    ("SB-cg-cta-acquire",      "SB-gc-cta-acquire"),
    ("SB-cg-cta-fence",        "SB-gc-cta-fence"),
    ("SB-cg-cta-relaxed",      "SB-gc-cta-relaxed"),
    ("SB-cg-cta-release",      "SB-gc-cta-release"),
    ("SB-cg-gpu-acquire",      "SB-gc-gpu-acquire"),
    ("SB-cg-gpu-fence",        "SB-gc-gpu-fence"),
    ("SB-cg-gpu-relaxed",      "SB-gc-gpu-relaxed"),
    ("SB-cg-gpu-release",      "SB-gc-gpu-release"),
    ("SB-cg-sys-acqrel-2s",    "SB-gc-sys-acqrel-2s"),
    ("SB-cg-sys-acquire",      "SB-gc-sys-acquire"),
    ("SB-cg-sys-fence",        "SB-gc-sys-fence"),
    ("SB-cg-sys-fence-2s",     "SB-gc-sys-fence-2s"),
    ("SB-cg-sys-relaxed",      "SB-gc-sys-relaxed"),
    ("SB-cg-sys-release",      "SB-gc-sys-release"),
]


# ---------------------------------------------------------------------------
# Canonical form.  Adapted from env-research/Q10-probe/canon.py (Q10 sect 7).
# ---------------------------------------------------------------------------
def _rk(r):
    """W0 and X0 are the same AArch64 register -- key by the number."""
    m = re.match(r"[WXwx](\d+)$", r)
    return m.group(1) if m else r


def parse(path):
    L = open(path).read().splitlines()[2:]        # skip `Het <name>' + comment
    i, j = L.index("{"), L.index("}")
    init = [l.strip().rstrip(";") for l in L[i + 1:j] if l.strip()]
    rest = L[j + 1:]
    rows = [[c.strip() for c in l.rstrip().rstrip(";").split("|")]
            for l in rest if "|" in l]
    cond = next(l for l in rest
                if l.startswith(("exists", "forall", "~exists")))
    n = max(len(r) for r in rows)
    cols = [[r[k] for r in rows if k < len(r) and r[k]] for k in range(n)]
    return init, cols, cond


def events(path):
    """-> ([(device, [(kind, loc, value, annotation), ...]), ...], cond atoms)"""
    init, cols, cond = parse(path)
    regvar = {}
    for a in init:
        m = re.match(r"(\d+):(\w+)=(\w+)$", a)
        if m:
            regvar[(int(m.group(1)), _rk(m.group(2)))] = m.group(3)
    procs, dest = [], {}
    for p, col in enumerate(cols):
        imm, evs = {}, []
        for ins in col[1:]:
            ins = " ".join(ins.split())
            m = re.match(r"MOV (\w+),#(\d+)$", ins)
            if m:
                imm[m.group(1)] = int(m.group(2)); continue
            m = re.match(r"(STR|STLR) (\w+),\[(\w+)\]$", ins)
            if m:
                evs.append(("W", regvar[(p, _rk(m.group(3)))], imm[m.group(2)],
                            "rel" if m.group(1) == "STLR" else "plain")); continue
            m = re.match(r"(LDR|LDAPR) (\w+),\[(\w+)\]$", ins)
            if m:
                dest[(p, _rk(m.group(2)))] = (p, len(evs))
                evs.append(("R", regvar[(p, _rk(m.group(3)))], None,
                            "acq" if m.group(1) == "LDAPR" else "plain")); continue
            if ins.startswith(("DMB", "DSB", "ISB")):
                evs.append(("F", None, None, ins.lower())); continue
            m = re.match(r"w\[([^\]]*)\] (\w+) (\d+)$", ins)
            if m:
                evs.append(("W", m.group(2), int(m.group(3)), m.group(1))); continue
            m = re.match(r"r\[([^\]]*)\] (\w+) (\w+)$", ins)
            if m:
                dest[(p, _rk(m.group(2)))] = (p, len(evs))
                evs.append(("R", m.group(3), None, m.group(1))); continue
            m = re.match(r"f\[([^\]]*)\]$", ins)
            if m:
                evs.append(("F", None, None, m.group(1))); continue
            raise SystemExit("%s: unparsed instruction %r" % (path, ins))
        procs.append((col[0].split(":")[1], evs))
    body = cond[cond.index("(") + 1: cond.rindex(")")]
    atoms = []
    for a in re.split(r"/\\", body):
        a = a.strip()
        m = re.match(r"(\d+):(\w+)=(\d+)$", a)
        if m:
            atoms.append(("reg", dest[(int(m.group(1)), _rk(m.group(2)))],
                          int(m.group(3)))); continue
        m = re.match(r"\[(\w+)\]=(\d+)$", a)
        if m:
            atoms.append(("loc", m.group(1), int(m.group(2)))); continue
        raise SystemExit("%s: unparsed cond atom %r" % (path, a))
    return procs, atoms


def _apply(procs, atoms, perm, locmap):
    new_of = {o: n for n, o in enumerate(perm)}
    out = [(n, procs[o][0],
            tuple((k, locmap.get(l, l), v, ann) for (k, l, v, ann) in procs[o][1]))
           for n, o in enumerate(perm)]
    A = []
    for a in atoms:
        if a[0] == "reg":
            p, k = a[1]; A.append(("reg", new_of[p], k, a[2]))
        else:
            A.append(("loc", locmap.get(a[1], a[1]), a[2]))
    return repr((tuple(out), tuple(sorted(A))))


def canonical(path):
    procs, atoms = events(path)
    locs = sorted({l for _, evs in procs for (_, l, _, _) in evs if l} |
                  {a[1] for a in atoms if a[0] == "loc"})
    best = None
    for perm in itertools.permutations(range(len(procs))):
        for tgt in itertools.permutations(locs):
            c = _apply(procs, atoms, list(perm), dict(zip(locs, tgt)))
            if best is None or c < best:
                best = c
    return best


# ---------------------------------------------------------------------------
def classes(d):
    """-> (n_files, {canonical -> [names...]})"""
    groups = collections.defaultdict(list)
    files = sorted(glob.glob(os.path.join(d, "*.litmus")))
    for f in files:
        groups[canonical(f)].append(os.path.basename(f)[: -len(".litmus")])
    return len(files), groups


def check(d, quiet=False):
    n_files, groups = classes(d)
    found = sorted(tuple(sorted(v)) for v in groups.values() if len(v) > 1)
    allow = sorted(tuple(sorted(c)) for c in ALLOWLIST)
    redundant = sum(len(c) - 1 for c in found)

    errors = []
    for c in found:
        if c not in allow:
            errors.append("UNALLOWLISTED duplicate class: %s -- these are the "
                          "SAME experiment up to proc permutation x location "
                          "renaming; drop one, or (with a reason) allowlist it"
                          % "  ==  ".join(c))
    for c in allow:
        if c not in found:
            missing = [n for n in c if not os.path.exists(
                os.path.join(d, n + ".litmus"))]
            why = ("file(s) missing: %s" % " ".join(missing)) if missing \
                else "they are no longer isomorphic"
            errors.append("STALE allowlist entry: %s -- %s.  A rotting "
                          "allowlist silently stops guarding." % (
                              "  ==  ".join(c), why))

    if not quiet:
        print("===== DUPCHECK: is any het test a duplicate of another? =====")
        print("  corpus       : %d .litmus in %s" % (n_files, d))
        print("  distinct     : %d up to (proc permutation x location renaming)"
              % len(groups))
        print("  duplicates   : %d class(es), %d redundant file(s)"
              % (len(found), redundant))
        print("  allowlisted  : %d class(es) (Q10 sect 2.1: SB/LB/2+2W cg==gc, "
              "rotation-invariant shapes)" % len(allow))
        print()
    if errors:
        for e in errors:
            print("  *** %s" % e)
        print("\nDUPCHECK FAILED: %d problem(s)." % len(errors))
        return 1
    if not quiet:
        print("DUPCHECK OK  (%d distinct experiments; the %d known duplicate "
              "classes are exactly the allowlisted ones)"
              % (len(groups), len(allow)))
    return 0


# ---------------------------------------------------------------------------
# --bite: the gate must be SEEN to fail, for the RIGHT reason.
# ---------------------------------------------------------------------------
def _run_on(d):
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--dir", d],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def bite(d):
    print("===== DUPCHECK BITE: does the gate fail when it must? =====")
    rc = 0

    # -- bite 1: a NEW duplicate (copy a test under a new name, rename locations)
    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.join(tmp, "het")
        shutil.copytree(d, work)
        src = os.path.join(work, "MP-cg-sys-relaxed.litmus")
        txt = open(src).read()
        # x<->y renaming ONLY -- word-boundary so `exists' / `X1' are untouched.
        # A pure location rename is BY DEFINITION the same experiment.
        body = re.sub(r"\b([xy])\b", lambda m: "y" if m.group(1) == "x" else "x",
                      txt)
        body = body.replace("MP-cg-sys-relaxed", "MP-cg-sys-relaxed-CLONE")
        assert body.count("=x;") == 1 and body.count("=y;") == 1 \
            and "exists" in body, "injection corrupted the test"
        assert body != txt, "injection was vacuous"
        dst = os.path.join(work, "MP-cg-sys-relaxed-CLONE.litmus")
        open(dst, "w").write(body)
        c, out = _run_on(work)
        ok = c != 0 and "UNALLOWLISTED duplicate class" in out \
            and "MP-cg-sys-relaxed-CLONE" in out
        print("  [1] synthetic duplicate (MP-cg-sys-relaxed copied with x<->y renamed)")
        print("      rc=%d  %s" % (c, "BITES" if ok else "*** DID NOT BITE"))
        for l in out.splitlines():
            if "***" in l:
                print("      | " + l.strip())
        rc |= 0 if ok else 1

    # -- bite 2: a STALE allowlist entry (partner replaced by a non-duplicate).
    # Injected by MUTATING THE IMPORTED LIST, not by patching text -- a text
    # patch would also rewrite this very injection string.
    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.join(tmp, "het")
        shutil.copytree(d, work)
        drv = os.path.join(tmp, "rot.py")
        open(drv, "w").write(
            "import sys\n"
            "sys.path.insert(0, %r)\n"
            "import dupcheck as D\n"
            "GOOD = ('SB-cg-sys-relaxed', 'SB-gc-sys-relaxed')\n"
            "BAD  = ('SB-cg-sys-relaxed', 'MP-cg-sys-relaxed')\n"
            "assert GOOD in D.ALLOWLIST, 'injection target vanished'\n"
            "D.ALLOWLIST = [BAD if c == GOOD else c for c in D.ALLOWLIST]\n"
            "assert BAD in D.ALLOWLIST and GOOD not in D.ALLOWLIST\n"
            "sys.exit(D.check(%r))\n" % (HERE, work))
        r = subprocess.run([sys.executable, drv], capture_output=True, text=True)
        out = r.stdout + r.stderr
        ok = r.returncode != 0 and "STALE allowlist entry" in out \
            and "UNALLOWLISTED duplicate class" in out
        print("  [2] allowlist rot (partner SB-gc-sys-relaxed -> MP-cg-sys-relaxed)")
        print("      rc=%d  %s" % (r.returncode,
                                   "BITES" if ok else "*** DID NOT BITE"))
        for l in out.splitlines():
            if "***" in l:
                print("      | " + l.strip())
        rc |= 0 if ok else 1

    print()
    if rc:
        print("BITE FAILED: the gate did not fail where it must.")
        return 1
    print("BITE OK: the gate has teeth (new duplicate AND allowlist rot both fail it)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true")
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    return bite(d) if a.bite else check(d, a.quiet)


if __name__ == "__main__":
    sys.exit(main())
