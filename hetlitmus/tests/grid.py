#!/usr/bin/env python3
"""grid.py -- generate a HetLitmus corpus: the het one (shape x device cut x
GPU scope x GPU order x CPU order, through hetgen7) or the gpu-only one (its
all-GPU cut, through diyone7).  Axes, cut reduction, name formats and the
byte-dedup: hetlitmus/docs/corpus-grid.md.

Usage: grid.py --corpus het|gpu-only [--cpu-arch aarch64|x86_64] --out DIR
               --bell FILE --libdir DIR (--hetgen7 PATH | --diyone7 PATH)
Exit: 0 = the corpus is complete; 1 = a tool failed; 2 = bad argument.
"""

import argparse
import itertools
import os
import re
import subprocess
import sys


class GridError(ValueError):
    """A table lookup or a cycle the tables do not admit."""


# --- tables -----------------------------------------------------------------

SHAPES = [                       # name, base cycle (one proc per external edge)
    ("MP",      "PodWW Rfe PodRR Fre"),
    ("SB",      "PodWR Fre PodWR Fre"),
    ("LB",      "PodRW Rfe PodRW Rfe"),
    ("2+2W",    "PodWW Coe PodWW Coe"),
    ("R",       "PodWW Coe PodWR Fre"),
    ("S",       "PodWW Rfe PodRW Coe"),
    ("WRC",     "Rfe PodRW Rfe PodRR Fre"),
    ("RWC",     "Rfe PodRR Fre PodWR Fre"),
    ("ISA2",    "PodWW Rfe PodRW Rfe PodRR Fre"),
    ("IRIW",    "Rfe PodRR Fre Rfe PodRR Fre"),
    ("WRC3",    "Rfe PodRW Rfe PodRW Rfe PodRR Fre"),
    ("3.2W",    "PodWW Coe PodWW Coe PodWW Coe"),
    ("WWC",     "Rfe PodRW Rfe PodRW Coe"),
    ("WRW+2W",  "Rfe PodRW Coe PodWW Coe"),
    ("WRW+WR",  "Rfe PodRW Coe PodWR Fre"),
    ("WRR+2W",  "Rfe PodRR Fre PodWW Coe"),
    ("W+RWC",   "PodWW Rfe PodRR Fre PodWR Fre"),
    ("Z6.0",    "PodWW Rfe PodRW Coe PodWR Fre"),
    ("Z6.1",    "PodWW Coe PodWW Rfe PodRW Coe"),
    ("Z6.2",    "PodWW Rfe PodRW Rfe PodRW Coe"),
    ("Z6.3",    "PodWW Coe PodWW Rfe PodRR Fre"),
    ("Z6.4",    "PodWW Coe PodWR Fre PodWR Fre"),
    ("Z6.5",    "PodWW Coe PodWW Coe PodWR Fre"),
    ("3.SB",    "PodWR Fre PodWR Fre PodWR Fre"),
    ("3.LB",    "PodRW Rfe PodRW Rfe PodRW Rfe"),
    ("CoRR",    "Rfe PosRR Fre"),
    ("CoWR",    "PosWR Fre Coe"),
    ("CoRW2",   "Rfe PosRW Coe"),
]

SCOPES = ["cta", "gpu", "sys"]

# The list order decides which name survives the byte-dedup.
GPU_ORDERS = ["rlx", "acq", "rel", "ra", "sc", "fsc", "facq", "frel", "fra"]

SCOPE_CC = {"cta": "Cta", "gpu": "Gpu", "sys": "Sys"}

ACCESS_ORDERS = {                # order -> (read annotation, write annotation)
    "rlx": ("Relaxed", "Relaxed"),
    "acq": ("Acquire", "Relaxed"),
    "rel": ("Relaxed", "Release"),
    "ra":  ("Acquire", "Release"),
    "sc":  ("Sc", "Sc"),
}

FENCE_ORDERS = {                 # order -> the standalone fence's annotation
    "fsc": "Sc", "facq": "Acquire", "frel": "Release", "fra": "Acqrel",
}

ARM_ATOM = {"R": "Q", "W": "L"}  # ra: LDAPR on a read, STLR on a write
ARM_FENCE = {"sy": "DMB.SY", "st": "DMB.ST", "ld": "DMB.LD"}


# --- renderers --------------------------------------------------------------

def edge_src_dst(edge):
    """-> (src dir, dst dir, location letter, XY) -- the last two "" on an
    external edge; a fence edge is spelled <fence><letter><XY>."""
    m = re.fullmatch(r"Po([ds])([WR])([WR])", edge)
    if m:
        return m.group(2), m.group(3), m.group(1), m.group(2) + m.group(3)
    ext = {"Rfe": ("W", "R"), "Fre": ("R", "W"), "Coe": ("W", "W")}
    if edge in ext:
        return ext[edge] + ("", "")
    raise GridError("unknown base edge: %s" % edge)


def render_gpu(scope, order, cycle):
    """The Bell/LISA edge token list of one cell: every access annotated
    <Order><Scope> on both sides, or every access Relaxed with a standalone
    fence edge on each Po edge at the cell's scope."""
    if scope not in SCOPE_CC:
        raise GridError("bad scope: %s (one of: %s)" % (scope, " ".join(SCOPES)))
    sc = SCOPE_CC[scope]
    out = []
    if order in ACCESS_ORDERS:
        r, w = ACCESS_ORDERS[order]
        ann = {"R": r, "W": w}
        for e in cycle.split():
            src, dst, _, _ = edge_src_dst(e)
            out.append("%s%s%s%s%s" % (e, ann[src], sc, ann[dst], sc))
    elif order in FENCE_ORDERS:
        o = FENCE_ORDERS[order]
        for e in cycle.split():
            _, _, loc, xy = edge_src_dst(e)
            base = "Fence%s%s%s%s" % (o, sc, loc, xy) if loc else e
            out.append("%sRelaxed%sRelaxed%s" % (base, sc, sc))
    else:
        raise GridError("bad gpu order: %s (one of: %s)"
                        % (order, " ".join(GPU_ORDERS)))
    return " ".join(out)


def render_cpu_aarch64(order, cycle):
    """plain: the bare cycle; ra: Q on reads, L on writes; sy|st|ld: the
    barrier edge on each Po edge, external edges bare."""
    out = []
    for e in cycle.split():
        src, dst, loc, xy = edge_src_dst(e)
        if order == "plain":
            out.append(e)
        elif order == "ra":
            out.append(e + ARM_ATOM[src] + ARM_ATOM[dst])
        elif order in ARM_FENCE:
            out.append(ARM_FENCE[order] + loc + xy if loc else e)
        else:
            raise GridError("bad cpu order: %s for aarch64 (one of: %s)"
                            % (order, " ".join(CPU_ISAS["aarch64"]["orders"])))
    return " ".join(out)


def render_cpu_x86_64(order, cycle):
    """plain: the bare cycle; mf: MFence on each Po edge, external edges bare."""
    out = []
    for e in cycle.split():
        _, _, loc, xy = edge_src_dst(e)
        if order == "plain":
            out.append(e)
        elif order == "mf":
            out.append("MFence" + loc + xy if loc else e)
        else:
            raise GridError("bad cpu order: %s for x86_64 (one of: %s)"
                            % (order, " ".join(CPU_ISAS["x86_64"]["orders"])))
    return " ".join(out)


# One profile per CPU ISA: the -cpu-arch tag hetgen7 takes, the file-name
# suffix, the CPU-order list and the renderer.  A new ISA is one row + one
# renderer.
CPU_ISAS = {
    "aarch64": {"tag": "aarch64", "suffix": "",
                "orders": ["plain", "ra", "sy", "st", "ld"],
                "render": render_cpu_aarch64},
    "x86_64":  {"tag": "x86_64", "suffix": "-x86_64",
                "orders": ["plain", "mf"],
                "render": render_cpu_x86_64},
}


def render_cpu(isa, order, cycle):
    if isa not in CPU_ISAS:
        raise GridError("unknown cpu arch: %s (one of: %s)"
                        % (isa, " ".join(CPU_ISAS)))
    return CPU_ISAS[isa]["render"](order, cycle)


def scope_tree(n):
    """The parseable scopes: tree of an n-proc gpu-only test, one CTA per proc."""
    return "(sys (gpu%s))" % "".join(" (cta %d)" % i for i in range(n))


def cut_tag(cut):
    """cpu,gpu -> cg; gpu,cpu,cpu -> gcc (a sequence or a comma list)."""
    if isinstance(cut, str):
        cut = cut.split(",")
    return "".join({"cpu": "c", "gpu": "g"}[d] for d in cut)


def cut_devices(tag):
    """cg -> cpu,gpu: the -devices list of a cut tag."""
    return ",".join({"c": "cpu", "g": "gpu"}[ch] for ch in tag)


# --- cuts and their reduction -----------------------------------------------

def segments(cycle):
    """The cycle as diy's proc list: rotated to its first Po edge, then one
    segment per proc = its run of Po edges plus the external edge leaving it."""
    edges = cycle.split()
    po = [bool(edge_src_dst(e)[2]) for e in edges]
    if not any(po):
        raise GridError("no Po edge in cycle: %s" % cycle)
    k = po.index(True)
    edges, po = edges[k:] + edges[:k], po[k:] + po[:k]
    if po[-1]:
        raise GridError("cycle ends inside a proc: %s" % cycle)
    segs, run = [], []
    for e, is_po in zip(edges, po):
        run.append(e)
        if not is_po:
            segs.append(tuple(run))
            run = []
    return segs


def nprocs(cycle):
    return len(segments(cycle))


def symmetry(cycle):
    """The segment rotations that leave the segment list unchanged."""
    segs = segments(cycle)
    return [k for k in range(len(segs)) if segs[k:] + segs[:k] == segs]


def raw_cuts(n):
    """Every cpu/gpu assignment of n procs but all-cpu and all-gpu, smallest
    tag first."""
    return [c for c in itertools.product(("cpu", "gpu"), repeat=n)
            if len(set(c)) > 1]


def cut_classes(cycle):
    """The cut tags, one per orbit of raw_cuts under symmetry(cycle), each
    orbit represented by its smallest tag."""
    rots = symmetry(cycle)
    seen, classes = set(), []
    for cut in raw_cuts(nprocs(cycle)):
        if cut in seen:
            continue
        seen.update(cut[k:] + cut[:k] for k in rots)
        classes.append(cut_tag(cut))
    return classes


# --- the loops ---------------------------------------------------------------

def run_tool(argv, cwd=None):
    """Run one generator call; its non-zero exit aborts the run with its stderr."""
    r = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.stderr.write("grid.py: %s failed (exit %d):\n%s"
                         % (os.path.basename(argv[0]), r.returncode,
                            r.stderr.decode(errors="replace")))
        sys.exit(1)
    return r.stdout


def gen_het(a):
    isa = CPU_ISAS[a.cpu_arch]
    common = [a.hetgen7, "-set-libdir", a.libdir, "-bell", a.bell, "-oneloc",
              "-cpu-arch", isa["tag"]]
    names, classes = [], []
    for shape, cycle in SHAPES:
        tags = cut_classes(cycle)
        classes.append("%s %d" % (shape, len(tags)))
        for tag in tags:
            for scope in SCOPES:
                for cpu in isa["orders"]:
                    if cpu != "plain" and scope != "sys":
                        continue
                    cpu_toks = render_cpu(a.cpu_arch, cpu, cycle)
                    for gpu in GPU_ORDERS:
                        name = "%s-%s-%s-%s.%s%s" % (shape, tag, scope, cpu,
                                                     gpu, isa["suffix"])
                        text = run_tool(common + [
                            "-devices", cut_devices(tag), "-name", name,
                            "-cpu", cpu_toks,
                            "-gpu", render_gpu(scope, gpu, cycle)])
                        with open(os.path.join(a.out, name + ".litmus"), "wb") as f:
                            f.write(text)
                        names.append(name)
    return names, classes


def gen_gpu_only(a):
    common = [a.diyone7, "-set-libdir", a.libdir, "-bell", a.bell,
              "-arch", "LISA", "-oneloc"]
    names = []
    for shape, cycle in SHAPES:
        tree = scope_tree(nprocs(cycle))
        for scope in SCOPES:
            for gpu in GPU_ORDERS:
                name = "%s-%s-%s" % (shape, scope, gpu)
                run_tool(common + ["-name", name, "-scopes", tree]
                         + render_gpu(scope, gpu, cycle).split(), cwd=a.out)
                if not os.path.isfile(os.path.join(a.out, name + ".litmus")):
                    sys.stderr.write("grid.py: diyone7 wrote no %s.litmus\n" % name)
                    sys.exit(1)
                names.append(name)
    return names, []


def body_key(path):
    """The file from its `{' line on: the test minus its name and comment."""
    with open(path, "rb") as f:
        lines = f.read().split(b"\n")
    return b"\n".join(lines[lines.index(b"{"):])


def dedup(out, names):
    """Delete every test whose body equals an earlier one's; -> survivors."""
    survivor, kept = {}, []
    for name in names:
        path = os.path.join(out, name + ".litmus")
        key = body_key(path)
        if key in survivor:
            os.remove(path)
            print("skip %s: == %s" % (name, survivor[key]))
        else:
            survivor[key] = name
            kept.append(name)
    return kept


def main(argv=None):
    ap = argparse.ArgumentParser(prog="grid.py")
    ap.add_argument("--corpus", required=True, choices=["het", "gpu-only"])
    ap.add_argument("--cpu-arch", choices=sorted(CPU_ISAS))
    ap.add_argument("--out", required=True)
    ap.add_argument("--bell", required=True)
    ap.add_argument("--libdir", required=True)
    ap.add_argument("--hetgen7")
    ap.add_argument("--diyone7")
    a = ap.parse_args(argv)
    if a.corpus == "het":
        a.cpu_arch = a.cpu_arch or "aarch64"
        tool = a.hetgen7
        if not tool or a.diyone7:
            ap.error("--corpus het takes --hetgen7 and no --diyone7")
    else:
        tool = a.diyone7
        if not tool or a.hetgen7 or a.cpu_arch:
            ap.error("--corpus gpu-only takes --diyone7 and no --hetgen7/--cpu-arch")
    for what, path, test in (("tool", tool, os.path.isfile),
                             ("--bell", a.bell, os.path.isfile),
                             ("--libdir", a.libdir, os.path.isdir)):
        if not test(path):
            ap.error("%s %s does not exist" % (what, path))
    # diyone7 runs with cwd = OUT, so every path it is handed is absolute.
    a.out, a.bell, a.libdir = map(os.path.abspath, (a.out, a.bell, a.libdir))
    if a.corpus == "het":
        a.hetgen7 = os.path.abspath(tool)
    else:
        a.diyone7 = os.path.abspath(tool)
    os.makedirs(a.out, exist_ok=True)
    stale = [f for f in os.listdir(a.out) if f.endswith(".litmus") or f == "@all"]
    if stale:
        ap.error("--out %s already holds %d test file(s); name an empty directory"
                 % (a.out, len(stale)))

    names, classes = gen_het(a) if a.corpus == "het" else gen_gpu_only(a)
    kept = dedup(a.out, names)
    with open(os.path.join(a.out, "@all"), "w") as f:
        f.write("".join(n + "\n" for n in sorted(k + ".litmus" for k in kept)))
    label = a.corpus if a.corpus == "gpu-only" else "het %s" % a.cpu_arch
    census = "%s: %d tests written, %d dropped" % (label, len(kept),
                                                    len(names) - len(kept))
    if classes:
        census += "; cut classes " + ", ".join(classes)
    print(census)
    return 0


if __name__ == "__main__":
    sys.exit(main())
