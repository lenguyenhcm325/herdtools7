#!/usr/bin/env python3
"""dupcheck.py -- the isomorphism gate over hetlitmus/tests/het.

  duplicate  no two tests are the same experiment up to (proc permutation x
             location renaming) -- the class a generator's byte-comparison
             against one sibling cannot see (hetlitmus/docs/corpus-grid.md,
             "Heterogeneous device cuts").
  empty      an empty --dir is a refusal, not a clean corpus.

Usage:  dupcheck.py [--dir D] [-q]   (exit 0 = clean)
"""

import argparse
import collections
import glob
import itertools
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "tests", "het")


# Canonical form: procs (with their device tag) x ordered annotated events,
# minimised over permutation of procs x renaming of locations.

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


def check(d, quiet=False):
    files = sorted(glob.glob(os.path.join(d, "*.litmus")))
    if not files:
        print("DUPCHECK FAILED: no .litmus file in %s -- an empty directory is "
              "not a clean corpus" % d)
        return 1
    groups = collections.defaultdict(list)
    for f in files:
        groups[canonical(f)].append(os.path.basename(f)[: -len(".litmus")])
    n_files = len(files)
    found = sorted(tuple(sorted(v)) for v in groups.values() if len(v) > 1)
    redundant = sum(len(c) - 1 for c in found)

    errors = ["DUPLICATE class: %s -- these are the SAME experiment up to proc "
              "permutation x location renaming; drop one" % "  ==  ".join(c)
              for c in found]

    if not quiet:
        print("===== DUPCHECK: is any het test a duplicate of another? =====")
        print("  corpus       : %d .litmus in %s" % (n_files, d))
        print("  distinct     : %d up to (proc permutation x location renaming)"
              % len(groups))
        print("  duplicates   : %d class(es), %d redundant file(s)"
              % (len(found), redundant))
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    return check(os.path.abspath(a.dir), a.quiet)


if __name__ == "__main__":
    sys.exit(main())
