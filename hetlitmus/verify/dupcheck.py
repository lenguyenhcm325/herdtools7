#!/usr/bin/env python3
"""dupcheck.py -- the isomorphism (duplicate-test) gate.

`hetlitmus/tests/het/generate.sh' loops shape x device-cut x scope x order and
dedups only by byte-comparing a variant against one designated sibling
(generate.sh:87-92, :128-133).  That filter cannot see duplicates of the second
kind: two different names whose programs are the same experiment up to
(permutation of procs) x (renaming of locations), device tag travelling with the
proc.  The corpus carried 39 such classes -- every one the `cg'/`gc' mirror pair
of a rotation-invariant shape (SB / LB / 2+2W), where swapping P0 and P1 gives
back the same cycle with the labels exchanged.  Measurement and analysis:
env-research/Q10-corpus-coverage.md sect 2.1 and 2.3.

Those 39 were REMOVED on 2026-08-01 (450 files -> 411, all distinct), reversing
the earlier decision to keep and allowlist them.  Their verdicts agreed with
their mirrors, so nothing was wrong -- but they were not independent samples, and
some sat inside the Disallowed rows that carry the falsification claim.  The fix
is at the root: `tests/_grid_lib.sh' SHAPE_HET_CUTS now emits the `cpu,gpu' cut
alone for those three shapes, the rotation rule SHAPE_2S_PAIR_CUTS already
applied.  ALLOWLIST is therefore EMPTY.

The gate still checks both directions, so neither the corpus nor the list can
rot:
  1. every duplicate class found in the corpus is in ALLOWLIST  (new dup -> FAIL)
  2. every ALLOWLIST class is still a real duplicate class      (stale -> FAIL)
Half 1 now rejects every duplicate outright.  Half 2 is what stops the list
becoming a rubber stamp: an entry that is not a real duplicate class -- listed
speculatively, or listed once and since edited, renamed or deleted -- is dead
weight, and the gate says so.  Together they are what makes widening the variant
vocabulary safe: a new annotation axis multiplies across device cuts, so new
duplicates are the expected failure mode and they break the build.

The canonical form is adapted from env-research/Q10-probe/canon.py: parse the Het
test into (proc -> ordered event list, condition atoms), then minimise over every
permutation of procs x every renaming of locations.  Events carry their
annotation (`plain' / `rel' / `acq' / `dmb sy' / `release,sys' / ...), so a
weakening is never canonically equal to the test it weakens, and the device tag
is part of the proc record, so a cpu/gpu swap is not a duplicate.

Usage:  dupcheck.py [--dir D] [-q]   run the gate      (exit 0 = clean)
        dupcheck.py --bite           prove the gate fails when it must
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
# The allowlist: duplicate classes waved through on purpose.  EMPTY since the 39
# `cg'/`gc' mirrors were removed at the source (2026-08-01) -- nothing in the
# corpus is a duplicate any more.  Extend it only with a documented reason:
# adding an entry here is how a real duplicate gets waved through, and half 2 of
# the gate rejects an entry that is not one.
# ---------------------------------------------------------------------------
ALLOWLIST = [
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
        print("  allowlisted  : %d class(es) (the Q10 sect 2.1 SB/LB/2+2W cg==gc "
              "mirrors were removed at the source 2026-08-01)" % len(allow))
        print()
    if errors:
        for e in errors:
            print("  *** %s" % e)
        print("\nDUPCHECK FAILED: %d problem(s)." % len(errors))
        return 1
    if not quiet:
        print("DUPCHECK OK  (%d file(s), %d distinct experiment(s), %d duplicate "
              "class(es))"
              % (n_files, len(groups), len(found)))
    return 0


# ---------------------------------------------------------------------------
# --bite: the gate must be seen to fail, for the RIGHT reason.
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
        # x<->y renaming only -- word-boundary, so `exists' / `X1' are untouched.
        # A pure location rename is by definition the same experiment.
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

    # -- bite 2: a stale allowlist entry.  The list is empty, so the injection
    # ADDS one naming two real tests that are not isomorphic -- exactly the shape
    # of an entry written speculatively, or left behind by a partner that has
    # since been edited or deleted.  Injected by mutating the IMPORTED LIST, not
    # by patching text -- a text patch would also rewrite this very injection
    # string.  The reason string is asserted too: `no longer isomorphic' is the
    # arm under test, `file(s) missing' would be a different one.
    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.join(tmp, "het")
        shutil.copytree(d, work)
        drv = os.path.join(tmp, "rot.py")
        open(drv, "w").write(
            "import sys\n"
            "sys.path.insert(0, %r)\n"
            "import dupcheck as D\n"
            "BAD = ('SB-cg-sys-relaxed', 'MP-cg-sys-relaxed')\n"
            "assert BAD not in D.ALLOWLIST, 'injection is already listed'\n"
            "D.ALLOWLIST = D.ALLOWLIST + [BAD]\n"
            "sys.exit(D.check(%r))\n" % (HERE, work))
        r = subprocess.run([sys.executable, drv], capture_output=True, text=True)
        out = r.stdout + r.stderr
        ok = r.returncode != 0 and "STALE allowlist entry" in out \
            and "they are no longer isomorphic" in out
        print("  [2] allowlist rot (SB-cg-sys-relaxed == MP-cg-sys-relaxed listed "
              "as a duplicate pair)")
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
