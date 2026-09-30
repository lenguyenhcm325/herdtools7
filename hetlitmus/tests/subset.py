#!/usr/bin/env python3
"""subset.py -- select the device-run subset of a het tree grid.py built: every
experiment at its unordered and its fully fenced cell, and the full grid of
FULL_GRID_SHAPES.  Rationale: hetlitmus/docs/corpus-grid.md "Device-run subset".

Usage: subset.py --corpus DIR [--cpu-arch aarch64|x86_64] --out FILE
Output: one test name per line, sorted.
Exit: 0 = the subset is written; 2 = bad argument or a tree grid.py did not write whole.
"""

import argparse
import os
import sys

import grid

FULL_GRID_SHAPES = ["MP", "SB", "LB", "CoRR", "CoWR", "CoRW2"]
PARTS = ["unordered-end", "fenced-end", "full-grid"]


class SubsetError(ValueError):
    """A tree that is not grid.py's whole output for this ISA."""


def read_tree(d):
    """-> (survivor names, dropped name -> survivor)."""
    try:
        with open(os.path.join(d, "@all")) as f:
            listed = set(l.strip() for l in f if l.strip())
        with open(os.path.join(d, "@dedup")) as f:
            alias = dict(l.split() for l in f if l.strip())
    except (OSError, ValueError) as e:
        raise SubsetError("%s is not a grid.py tree: %s" % (d, e))
    present = set(f for f in os.listdir(d) if f.endswith(".litmus"))
    if present != listed:
        name = min(present ^ listed)
        raise SubsetError("%s holds %s, its @all does not" % (d, name)
                          if name in present else
                          "%s lacks %s, its @all names it" % (d, name))
    return set(f[:-len(".litmus")] for f in present), alias


def select(isa, survivors, alias):
    """-> {test: part}; a test keeps the first part that takes it."""
    def resolve(name):
        s = alias.get(name, name)
        if s not in survivors:
            raise SubsetError("cell %s has no test in the tree" % name)
        return s

    parts = {}
    for part, cpu, gpu in (("unordered-end", "plain", "rlx"),
                           ("fenced-end", grid.CPU_ISAS[isa]["barrier"], "fsc")):
        for shape, cycle in grid.SHAPES:
            for tag in grid.cut_classes(cycle):
                name = grid.het_name(isa, shape, tag, "sys", cpu, gpu)
                parts.setdefault(resolve(name), part)
    # Every cell resolves, so a tree of another ISA is refused.
    for shape, _, tag, scope, cpu, gpu in grid.het_cells(isa):
        name = resolve(grid.het_name(isa, shape, tag, scope, cpu, gpu))
        if shape in FULL_GRID_SHAPES:
            parts.setdefault(name, "full-grid")
    return parts


def main(argv=None):
    ap = argparse.ArgumentParser(prog="subset.py")
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--cpu-arch", choices=sorted(grid.CPU_ISAS), default="aarch64")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    shapes = set(s for s, _ in grid.SHAPES)
    if not set(FULL_GRID_SHAPES) <= shapes:
        ap.error("full-grid shape(s) not in grid.SHAPES: %s"
                 % " ".join(sorted(set(FULL_GRID_SHAPES) - shapes)))
    try:
        survivors, alias = read_tree(a.corpus)
        parts = select(a.cpu_arch, survivors, alias)
    except SubsetError as e:
        sys.stderr.write("subset.py: %s\n" % e)
        return 2
    with open(a.out, "w") as f:
        f.write("".join(n + "\n" for n in sorted(parts)))
    counts = {}
    for p in parts.values():
        counts[p] = counts.get(p, 0) + 1
    print("het-subset %s: %d tests; %s" % (
        a.cpu_arch, len(parts),
        ", ".join("%s %d" % (p, counts[p]) for p in PARTS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
