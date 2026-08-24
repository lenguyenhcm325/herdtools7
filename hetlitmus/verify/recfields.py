#!/usr/bin/env python3
"""HetLitmus -- the emitter/runtime skew tripwire.

het_obs_record and the HET_* knob defaults live in litmus/het-runtime/*.h; the
lines that fill them live in litmus/hetEmit.ml.  Nothing but a compiler binds the
two, so on the CPU-only lanes a rename, a typo'd stamp or a dropped default is
invisible until an nvcc or hipcc build runs -- which is why this gate exists and
why it needs no GPU.  Five properties, over real emissions of both pairs:

  A Fields   every `_rec.<name>' the render writes is a member of het_obs_record.
  B Stamp    every render writes `_rec.rec_magic = HET_REC_MAGIC;' exactly once,
             by the symbol: het_verdict() reads no field of a record without it.
  C Live     every `#define HET_*' the renders stamp is read somewhere -- by
             some lane's code or by a staged runtime header.  A stamp nobody
             reads is a stamp whose name drifted.
  D Default  every stamped define that het_verdict.h reads has an `#ifndef'
             default there, so a lane that stamps nothing still compiles.
  E Resolve  every `HET_*' name a render USES is either stamped by that render or
             declared by a header the harness dir stages.  A slot stride the
             render addresses through, or a rendezvous cap it waits under, that
             no staged header declares is a harness that does not compile.  Both
             sides are read through code_only(), so a name that survives only in
             a header's prose resolves nothing.

Usage:  recfields.py [-q]
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
X86_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het-x86")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# (corpus dir, test, -gpu-target, render extension) -- one shape per kind of
# outcome column and one per pair, because different shapes write different
# fields.
LANES = [
    (HET_DIR, "MP-cg-sys-fence-2s", "cuda", "cu"),   # register columns only
    (HET_DIR, "2+2W-cg-sys-fence", "cuda", "cu"),    # location columns only
    (HET_DIR, "S-cg-sys-fence", "cuda", "cu"),       # both kinds of column
    (X86_DIR, "MP-cg-sys-relaxed-x86_64", "hip", "hip"),   # the (X86_64, hip) pair
]
HEADERS = ["het_verdict.h", "het_stress.h", "het_cpu_stress.h", "het_rdv.h"]

FIELD_RE = re.compile(r"_rec\.([A-Za-z_][A-Za-z0-9_]*)")
DEFINE_RE = re.compile(r"^#define (HET_[A-Za-z0-9_]+)", re.M)
IFNDEF_RE = re.compile(r"^#ifndef (HET_[A-Za-z0-9_]+)", re.M)
STAMP_RE = re.compile(r"_rec\.rec_magic\s*=\s*HET_REC_MAGIC\s*;")
USE_RE = re.compile(r"\bHET_[A-Za-z0-9_]+\b")

def code_only(text):
    """Drop /*...*/ comments, //-comments and string literals: an identifier that
    survives is one the preprocessor or the compiler actually sees.  het_verdict.h
    names many of these knobs in its prose and in its printf strings, and reading
    those as uses would call every one of them read."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', ' "" ', text)


def env():
    e = dict(os.environ)
    e["PATH"] = BIN + os.pathsep + e["PATH"]
    return e


def members(header_text):
    """The member names of het_obs_record, from the emitted header itself."""
    m = re.search(r"typedef struct het_obs_record \{(.*?)\n\} het_obs_record;",
                  header_text, re.S)
    if m is None:
        raise SystemExit("recfields: het_verdict.h has no het_obs_record struct")
    body = re.sub(r"/\*.*?\*/", " ", m.group(1), flags=re.S)
    return set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*[,;]", body))


def emit(tmp, corpus, test, target):
    out = os.path.join(tmp, "%s-%s" % (test, target))
    os.makedirs(out, exist_ok=True)
    r = subprocess.run(["litmus7", "-gpu-target", target, "-set-libdir",
                        os.path.join(ROOT, "litmus", "libdir"), "-o", out,
                        os.path.join(corpus, test + ".litmus")],
                       cwd=ROOT, env=env(), capture_output=True, text=True)
    d = os.path.join(out, test)
    if r.returncode != 0 or not os.path.isdir(d):
        raise SystemExit("recfields: litmus7 emitted no harness for %s/%s:\n%s"
                         % (test, target, r.stderr[-1500:]))
    return d


def check_lane(d, test, ext, quiet, seen):
    bad = []
    render = os.path.join(d, test + "." + ext)
    with open(render) as fh:
        src = fh.read()
    heads = {}
    for h in HEADERS:
        with open(os.path.join(d, h)) as fh:
            heads[h] = code_only(fh.read())
    code = code_only(src)

    # A -- every field written is a real member.
    known = members(heads["het_verdict.h"])
    for f in sorted(set(FIELD_RE.findall(src))):
        if f not in known:
            bad.append("%s writes _rec.%s, which het_obs_record has no member of"
                       % (test, f))
    # B -- the stamp, exactly once and by symbol.
    n = len(STAMP_RE.findall(src))
    if n != 1:
        bad.append("%s stamps `_rec.rec_magic = HET_REC_MAGIC;' %d time(s), want 1 "
                   "-- an unstamped record is discarded by het_verdict()" % (test, n))
    # C/D -- the defines.  Collected here, judged over the union of lanes: a knob
    # the emitter stamps unconditionally may be consumed only by the shapes that
    # need it, and calling that drift would make the check fire on every lane
    # that does not use it.
    stamped = sorted(set(DEFINE_RE.findall(src)))
    guarded = set()
    declared = set()
    for h in HEADERS:
        guarded |= set(IFNDEF_RE.findall(heads[h]))
        # Every HET_* the header carries, not only its #defines: the enum
        # constants of the campaign stop rule are names a render uses too.
        declared |= set(USE_RE.findall(heads[h]))
    for name in stamped:
        readers = [h for h in HEADERS
                   if re.search(r"\b%s\b" % re.escape(name), heads[h])]
        # The render defines it before including the headers, so a define the
        # render itself uses is read even if no header names it.  The #define line
        # and any #ifndef guard of the same name are not uses.
        uses_here = len(re.findall(r"\b%s\b" % re.escape(name), code)) \
            - len(re.findall(r"^\s*#\s*(?:define|ifndef|undef)\s+%s\b"
                             % re.escape(name), code, re.M))
        seen.setdefault(name, False)
        if readers or uses_here > 0:
            seen[name] = True
        if "het_verdict.h" in readers and name not in guarded:
            bad.append("%s stamps #define %s and het_verdict.h READS it, but no "
                       "#ifndef default exists for it -- a lane that stamps nothing "
                       "would not compile" % (test, name))
    # E -- every HET_* name the render's code uses resolves.  The render defines
    # its own stamps before including anything, so those count; everything else
    # must come from a header this harness dir stages beside it.
    resolvable = set(stamped) | declared
    for name in sorted(set(USE_RE.findall(code))):
        if name not in resolvable:
            bad.append("%s uses %s and neither the render nor any staged runtime "
                       "header defines it -- the harness does not compile"
                       % (test, name))
    if not quiet and not bad:
        print("      %-28s %2d field(s), %2d stamped define(s), %2d HET_* use(s), "
              "stamp x1"
              % (test, len(set(FIELD_RE.findall(src))), len(stamped),
                 len(set(USE_RE.findall(code)))))
    return bad


def run(quiet):
    print("===== recfields: do the emitted harnesses bind to the runtime "
          "headers? =====")
    bad = []
    seen = {}
    tmp = tempfile.mkdtemp(prefix="recfields.")
    try:
        for corpus, test, target, ext in LANES:
            bad += check_lane(emit(tmp, corpus, test, target), test, ext, quiet,
                              seen)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for name in sorted(n for n, live in seen.items() if not live):
        bad.append("#define %s is stamped and NO lane's code and no runtime header "
                   "reads it -- a stamp whose name drifted is a default that "
                   "silently stands" % name)
    for m in bad:
        print("  *** %s" % m)
    if bad:
        print("\nRECFIELDS FAILED: %d problem(s).  The emitter and the runtime "
              "headers are bound by nothing but a compiler, and on the CPU-only "
              "lanes there is no compiler." % len(bad))
        return 1
    print("\nRECFIELDS OK (%d lane(s): every field is a member, every render stamps "
          "rec_magic once, every stamped define is read and defaulted, every HET_* "
          "use resolves)" % len(LANES))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("recfields: litmus7 not built (run 'make all')")
    return run(a.quiet)


if __name__ == "__main__":
    sys.exit(main())
