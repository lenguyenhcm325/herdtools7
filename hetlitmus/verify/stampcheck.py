#!/usr/bin/env python3
"""HetLitmus -- the emitter/runtime skew tripwire.  Usage: stampcheck.py [-q]

Nothing but a compiler binds the `#define HET_*' stamps (litmus/hetGpuFile.ml)
to litmus/het-runtime/*.h, and a stamp nobody reads still compiles.  Over one
real emission per (CPU ISA, GPU dialect) pair:

  C Live     every stamped `#define HET_*' is read by a header or the render.
  D Default  every stamped define het_verdict.h reads has an `#ifndef' default.
  E Resolve  every `HET_*' the render's code USES is stamped or header-declared.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = census.HET_DIR
X86_DIR = census.X86_DIR
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# (corpus dir, test, -gpu-target, render extension), one per pair: the names a
# render stamps and uses do not vary with the test's shape.
LANES = [
    (HET_DIR, "MP-cg-sys-sy.fsc", "cuda", "cu"),
    (X86_DIR, "MP-cg-sys-plain.rlx-x86_64", "hip", "hip"),
]
HEADERS = ["het_verdict.h", "het_stress.h", "het_cpu_stress.h", "het_rdv.h"]

DEFINE_RE = re.compile(r"^#define (HET_[A-Za-z0-9_]+)", re.M)
IFNDEF_RE = re.compile(r"^#ifndef (HET_[A-Za-z0-9_]+)", re.M)
USE_RE = re.compile(r"\bHET_[A-Za-z0-9_]+\b")

def code_only(text):
    """Drop comments and string literals, so a surviving identifier is one the
    compiler sees -- het_verdict.h names many knobs in prose and printf text."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', ' "" ', text)


def env():
    e = dict(os.environ)
    e["PATH"] = BIN + os.pathsep + e["PATH"]
    return e


def emit(tmp, corpus, test, target):
    out = os.path.join(tmp, "%s-%s" % (test, target))
    os.makedirs(out, exist_ok=True)
    r = subprocess.run(["litmus7", "-gpu-target", target, "-set-libdir",
                        os.path.join(ROOT, "litmus", "libdir"), "-o", out,
                        os.path.join(corpus, test + ".litmus")],
                       cwd=ROOT, env=env(), capture_output=True, text=True)
    d = os.path.join(out, test)
    if r.returncode != 0 or not os.path.isdir(d):
        raise SystemExit("stampcheck: litmus7 emitted no harness for %s/%s:\n%s"
                         % (test, target, r.stderr[-1500:]))
    return d


def check_lane(d, test, ext, quiet):
    bad = []
    render = os.path.join(d, test + "." + ext)
    with open(render) as fh:
        src = fh.read()
    heads = {}
    for h in HEADERS:
        with open(os.path.join(d, h)) as fh:
            heads[h] = code_only(fh.read())
    code = code_only(src)

    stamped = sorted(set(DEFINE_RE.findall(src)))
    guarded = set()
    declared = set()
    for h in HEADERS:
        guarded |= set(IFNDEF_RE.findall(heads[h]))
        # Every HET_* the header carries, not only its #defines: the enum
        # constants of the campaign stop rule are names a render uses too.
        declared |= set(USE_RE.findall(heads[h]))
    # C/D -- a define the render itself uses is read even if no header names
    # it; its #define/#ifndef/#undef lines are not uses.
    for name in stamped:
        readers = [h for h in HEADERS
                   if re.search(r"\b%s\b" % re.escape(name), heads[h])]
        uses_here = len(re.findall(r"\b%s\b" % re.escape(name), code)) \
            - len(re.findall(r"^\s*#\s*(?:define|ifndef|undef)\s+%s\b"
                             % re.escape(name), code, re.M))
        if not readers and uses_here <= 0:
            bad.append("%s stamps #define %s and NO runtime header and none of "
                       "its own code reads it -- a stamp whose name drifted is "
                       "a default that silently stands" % (test, name))
        if "het_verdict.h" in readers and name not in guarded:
            bad.append("%s stamps #define %s and het_verdict.h READS it, but no "
                       "#ifndef default exists for it -- a lane that stamps nothing "
                       "would not compile" % (test, name))
    # E -- every HET_* the render's code uses resolves: its own stamps count,
    # everything else must come from a header staged in the harness dir.
    resolvable = set(stamped) | declared
    for name in sorted(set(USE_RE.findall(code))):
        if name not in resolvable:
            bad.append("%s uses %s and neither the render nor any staged runtime "
                       "header defines it -- the harness does not compile"
                       % (test, name))
    if not quiet and not bad:
        print("      %-28s %2d stamped define(s), %2d HET_* use(s)"
              % (test, len(stamped), len(set(USE_RE.findall(code)))))
    return bad


def run(quiet):
    print("===== stampcheck: do the emitted harnesses bind to the runtime "
          "headers? =====")
    bad = []
    tmp = tempfile.mkdtemp(prefix="stampcheck.")
    try:
        for corpus, test, target, ext in LANES:
            bad += check_lane(emit(tmp, corpus, test, target), test, ext, quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for m in bad:
        print("  *** %s" % m)
    if bad:
        print("\nSTAMPCHECK FAILED: %d problem(s)." % len(bad))
        return 1
    print("\nSTAMPCHECK OK (%d lane(s): C live, D default, E resolve)"
          % len(LANES))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("stampcheck: litmus7 not built (run 'make all')")
    return run(a.quiet)


if __name__ == "__main__":
    sys.exit(main())
