#!/usr/bin/env python3
"""faithful-cover.txt covers the corpus: every feature of both CUDA-lane
corpora appears in some test the list names, each entry <tree>/<name>.litmus
relative to census.CORPUS.  A feature is the test kind, the device pattern, a
`+' in the name, or one column's whole op program (ptxcheck's parse), so a
listed test stands in for every test sharing them.  A miss names the
uncovered feature: a shape `tokens.sh all' would never compile
(hetlitmus/docs/faithfulness.md).
Exit 0 = covered, 1 = uncovered, 2 = error.  --extend adds tests to the list.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census
import ptxcheck as ptx

COVER = os.path.join(HERE, "faithful-cover.txt")
COVER_REL = os.path.relpath(COVER, os.path.join(HERE, "..", ".."))


def corpus():
    """Both corpora at their pinned census, relative to census.CORPUS."""
    files = census.corpus_files(census.GPU_DIR, "gpu-only", census.GPU_ONLY) + \
        census.corpus_files(census.HET_DIR, "het", census.HET)
    return [os.path.relpath(f, census.CORPUS) for f in files]


def features(rel):
    """The set a listed test stands in for (module docstring)."""
    inst = ptx.instance_of(os.path.join(census.CORPUS, rel))
    f = {("kind", inst['kind']), ("pattern", inst['pattern']),
         ("name_plus", '+' in os.path.basename(rel))}
    f |= {("gpu_col", tuple(ops)) for _, ops in inst['gpu']}
    f |= {("cpu_col", tuple(ops)) for _, ops in inst['cpu']}
    return f


def read_cover():
    with open(COVER) as fh:
        return [ln.strip() for ln in fh if ln.strip() and not ln.startswith('#')]


def union(feats, tests):
    return set().union(*(feats[t] for t in tests))


def extend(feats, tests, cover):
    """Greedily add tests until the list covers the corpus, dropping none of
    the listed ones.  census.COVER is then a hand-edit."""
    chosen, left = list(cover), union(feats, tests) - union(feats, cover)
    while left:
        best = max(tests, key=lambda t: (len(feats[t] & left), t))
        chosen.append(best)
        left -= feats[best]
    with open(COVER, "w") as fh:
        fh.write("\n".join(sorted(chosen)) + "\n")
    print("wrote %s: %d tests (was %d); set COVER = %d in census.py"
          % (COVER_REL, len(chosen), len(cover), len(chosen)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--extend", action="store_true",
                    help="add tests until the list covers the corpus")
    args = ap.parse_args()
    try:
        tests = corpus()
        feats = {t: features(t) for t in tests}
        cover = read_cover()
        if args.extend:
            extend(feats, tests, cover)
            return 0
    except (ptx.CompletenessError, census.GateError, OSError, ValueError) as e:
        print("COVER ERROR: %s" % e)
        return 2
    if len(cover) != census.COVER:
        print("COVER FAIL: %s lists %d tests, expected %d"
              % (COVER_REL, len(cover), census.COVER))
        return 1
    unknown = [t for t in cover if t not in feats]
    if unknown:
        print("COVER FAIL: %d listed test(s) are not in the corpus: %s"
              % (len(unknown), ", ".join(unknown[:4])))
        return 1
    missing = union(feats, tests) - union(feats, cover)
    if missing:
        print("COVER FAIL: %d corpus feature(s) reach no listed test:" % len(missing))
        for m in sorted(missing, key=str)[:12]:
            print("  %s" % (m,))
        print("  extend the list with: python3 hetlitmus/verify/covercheck.py --extend")
        return 1
    print("COVER OK: %d tests cover all %d features of the %d-test corpus"
          % (len(cover), len(union(feats, tests)), len(tests)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
