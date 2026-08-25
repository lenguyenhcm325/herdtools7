#!/usr/bin/env python3
"""faithful-cover.txt covers the corpus: every feature the corpus carries also
appears in the list `tokens.sh all' sweeps.  Features, read with ptxcheck's own
parser: every GPU (kind,order,scope) token, every CPU (mnemonic,option), test
kind, proc count, device-lane pattern, name class, per-column length, first and
last op kind, adjacent-op pair, store-only and load-only CPU columns, and every
distinct GPU and CPU column program.  A miss names the uncovered feature: it is
a shape the short sweep would never compile (hetlitmus/docs/faithfulness.md).
Exit 0 = covered, 1 = uncovered, 2 = error.  --extend adds tests to the list.
"""

import argparse
import glob
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
COVER = os.path.join(HERE, "faithful-cover.txt")
GPU_DIR = os.path.join(REPO, "hetlitmus", "tests", "gpu-only")
HET_DIR = os.path.join(REPO, "hetlitmus", "tests", "het")
EXPECT_CORPUS = census.GPU_ONLY + census.HET
EXPECT_COVER = census.COVER


def _load_ptxcheck():
    spec = importlib.util.spec_from_file_location(
        "ptxcheck", os.path.join(HERE, "ptxcheck.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ptx = _load_ptxcheck()


def corpus():
    """Every .litmus of both corpora, repo-relative, at the pinned census.

    Vacuity guard: a cover is trivially valid against an empty corpus."""
    tests = sorted(glob.glob(os.path.join(GPU_DIR, "*.litmus"))) + \
            sorted(glob.glob(os.path.join(HET_DIR, "*.litmus")))
    if len(tests) != EXPECT_CORPUS:
        raise RuntimeError("corpus census: %d .litmus found, expected %d"
                           % (len(tests), EXPECT_CORPUS))
    return [os.path.relpath(t, REPO) for t in tests]


def features(rel):
    """The feature set of one test (see the module docstring)."""
    path = os.path.join(REPO, rel)
    text = ptx.read_litmus(path)
    procs, _rows = ptx.parse_body(text)
    inst = ptx.instance_of(path)
    devs = [ptx.device_class(d) for _, d in procs]
    pattern = ",".join(devs)
    name = os.path.basename(rel)[:-len(".litmus")]
    f = {("kind", inst['kind']), ("nprocs", len(procs)), ("pattern", pattern),
         ("n_gpu_lanes", devs.count('gpu')),
         ("name_dot", '.' in name), ("name_plus", '+' in name),
         ("name_2s", name.endswith('-2s'))}
    gpu_by_idx, cpu_by_idx = dict(inst['gpu']), dict(inst['cpu'])
    for pidx, dev in procs:
        gpu = ptx.device_class(dev) == 'gpu'
        ops = (gpu_by_idx if gpu else cpu_by_idx)[pidx]
        side = 'gpu' if gpu else 'cpu'
        f |= {(side, o) for o in ops}
        f |= {(side + "_len", len(ops)), (side + "_col", tuple(ops))}
        f |= {(side + "_bigram", a, b) for a, b in zip(ops, ops[1:])}
        if ops:
            f |= {(side + "_first", ops[0][0]), (side + "_last", ops[-1][0])}
        if not gpu:
            mns = [o[0] for o in ops]
            f |= {("cpu_store_only", not {'ldr', 'ldapr'} & set(mns)),
                  ("cpu_load_only", not {'str', 'stlr'} & set(mns))}
    return f


def read_cover():
    with open(COVER) as fh:
        return [ln.strip() for ln in fh if ln.strip() and not ln.startswith('#')]


def extend(feats, tests, cover):
    """Greedily add tests until the list covers the corpus, dropping none of
    the listed ones.  census.COVER is then a hand-edit."""
    chosen = list(cover)
    left = set().union(*(feats[t] for t in tests)) - \
        set().union(*(feats[t] for t in chosen))
    while left:
        best = max(tests, key=lambda t: (len(feats[t] & left), t))
        gain = feats[best] & left
        if not gain:
            break
        chosen.append(best)
        left -= gain
    with open(COVER, "w") as fh:
        fh.write("\n".join(sorted(chosen)) + "\n")
    print("wrote %s: %d tests (was %d); set COVER = %d in census.py"
          % (os.path.relpath(COVER, REPO), len(chosen), len(cover), len(chosen)))


def main():
    ap = argparse.ArgumentParser(description="faithful-cover.txt covers the corpus")
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
    except (ptx.CompletenessError, OSError, RuntimeError, ValueError) as e:
        print("COVER ERROR: %s" % e)
        return 2
    if len(cover) != EXPECT_COVER:
        print("COVER FAIL: %s lists %d tests, expected %d"
              % (os.path.relpath(COVER, REPO), len(cover), EXPECT_COVER))
        return 1
    unknown = [t for t in cover if t not in feats]
    if unknown:
        print("COVER FAIL: %d listed test(s) are not in the corpus: %s"
              % (len(unknown), ", ".join(unknown[:4])))
        return 1
    missing = set().union(*(feats[t] for t in tests)) - \
        set().union(*(feats[t] for t in cover))
    if missing:
        print("COVER FAIL: %d corpus feature(s) reach no listed test:" % len(missing))
        for m in sorted(missing, key=str)[:12]:
            print("  %s" % (m,))
        print("  extend the list with: python3 hetlitmus/verify/covercheck.py --extend")
        return 1
    print("COVER OK: %d tests cover all %d features of the %d-test corpus"
          % (len(cover), len(set().union(*(feats[t] for t in tests))), len(tests)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
