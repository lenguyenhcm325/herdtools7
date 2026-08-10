#!/usr/bin/env python3
"""HetLitmus -- the EMITTER/RUNTIME SKEW tripwire.

het_obs_record and the HET_* knob defaults live in litmus/het-runtime/*.h; the
lines that fill them live in litmus/hetEmit.ml.  Nothing but a compiler binds the
two, so on the CPU-only lanes a rename, a typo'd stamp or a dropped default is
invisible until an nvcc or hipcc build runs -- which is why this gate exists and
why it needs no GPU.  Four properties, over real emissions of both pairs:

  A FIELDS   every `_rec.<name>' the render writes is a member of het_obs_record.
  B STAMP    every render writes `_rec.rec_magic = HET_REC_MAGIC;' exactly once,
             by the SYMBOL: het_verdict() reads no field of a record without it.
  C LIVE     every `#define HET_*' the renders stamp is READ somewhere -- by
             some lane's code or by a staged runtime header.  A stamp nobody
             reads is a stamp whose name drifted.
  D DEFAULT  every stamped define that het_verdict.h READS has an `#ifndef'
             default there, so a lane that stamps nothing still compiles and
             still prints the mechanism rather than a vendor.

Usage:  recfields.py [-q]      run the gate
        recfields.py --bite    prove it FAILS when the binding breaks
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

# (corpus dir, test, -gpu-target, render extension) -- one shape per decode
# channel and one per pair, because different shapes write different fields.
LANES = [
    (HET_DIR, "MP-cg-sys-fence-2s", "cuda", "cu"),   # reader + mu(T) + canary
    (HET_DIR, "MP-cg-sys-relaxed", "cuda", "cu"),    # the `self' canary, no co-run
    (HET_DIR, "2+2W-cg-sys-fence", "cuda", "cu"),    # store-only: observer channel
    (HET_DIR, "S-cg-sys-fence", "cuda", "cu"),       # observer + reader
    # A T_L>=2 shape: the only one whose scan reads HET_WINDOW and
    # HET_EXHAUSTIVE_MAX at all, so without it those two stamps look dead.
    (HET_DIR, "IRIW-cgcg-sys-fence-2s", "cuda", "cu"),
    (X86_DIR, "MP-cg-sys-relaxed-x86_64", "hip", "hip"),   # the (X86_64, hip) pair
]
HEADERS = ["het_verdict.h", "het_stress.cuh", "het_cpu_stress.h"]

FIELD_RE = re.compile(r"_rec\.([A-Za-z_][A-Za-z0-9_]*)")
DEFINE_RE = re.compile(r"^#define (HET_[A-Za-z0-9_]+)", re.M)
IFNDEF_RE = re.compile(r"^#ifndef (HET_[A-Za-z0-9_]+)", re.M)
STAMP_RE = re.compile(r"_rec\.rec_magic\s*=\s*HET_REC_MAGIC\s*;")

# Stamped defines whose reader is a GATE, not C code: they are the emitted record
# of which control this harness names, pinned by hetlitmus/tests/cram/
# positive-control.t and by nothing the compiler sees.  Named here so a genuinely
# dead stamp is still caught, rather than the whole check being loosened.
GREP_ONLY = {"HET_MU_NAME", "HET_CANARY_NAME"}


def code_only(text):
    """Drop /*...*/ comments, //-comments and string literals: an identifier that
    survives is one the preprocessor or the compiler actually sees.  het_verdict.h
    NAMES half these knobs in its prose and in its printf strings, and reading
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


def check_lane(d, test, ext, quiet, tamper=None, seen=None,
               header_tamper=None):
    bad = []
    if seen is None:
        seen = {}
    render = os.path.join(d, test + "." + ext)
    with open(render) as fh:
        src = fh.read()
    if tamper is not None:
        src = tamper(src)
    heads = {}
    for h in HEADERS:
        with open(os.path.join(d, h)) as fh:
            text = fh.read()
        if header_tamper is not None:
            text = header_tamper(text)
        heads[h] = code_only(text)
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
    # C/D -- the defines.  Collected here, JUDGED over the union of lanes: a knob
    # the emitter stamps unconditionally may be consumed only by the shapes that
    # need it (HET_WINDOW is read by the windowed scan alone), and calling that
    # drift would make the check fire on every lane that does not use it.
    stamped = sorted(set(DEFINE_RE.findall(src)))
    guarded = set()
    for h in HEADERS:
        guarded |= set(IFNDEF_RE.findall(heads[h]))
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
    if not quiet and not bad:
        print("      %-28s %2d field(s), %2d stamped define(s), stamp x1"
              % (test, len(set(FIELD_RE.findall(src))), len(stamped)))
    return bad


def run(quiet, tamper=None, header_tamper=None, silent=False):
    if not silent:
        print("===== recfields: do the emitted harnesses bind to the runtime "
              "headers? =====")
    tmp = tempfile.mkdtemp(prefix="recfields.")
    bad = []
    seen = {}
    try:
        for corpus, test, target, ext in LANES:
            d = emit(tmp, corpus, test, target)
            bad += check_lane(d, test, ext, quiet, tamper=tamper, seen=seen,
                              header_tamper=header_tamper)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for name in sorted(n for n, live in seen.items()
                       if not live and n not in GREP_ONLY):
        bad.append("#define %s is stamped and NO lane's code and no runtime header "
                   "reads it -- a stamp whose name drifted is a default that "
                   "silently stands" % name)
    if silent:
        return bad
    for m in bad:
        print("  *** %s" % m)
    if bad:
        print("\nRECFIELDS FAILED: %d problem(s).  The emitter and the runtime "
              "headers are bound by nothing but a compiler, and on the CPU-only "
              "lanes there is no compiler." % len(bad))
        return 1
    print("\nRECFIELDS OK (%d lane(s): every field is a member, every render stamps "
          "rec_magic once, every stamped define is read and defaulted)" % len(LANES))
    return 0


BITES = [
    ("a field the record does not have", "_rec.nwn",
     lambda s: s.replace("_rec.nwin = (uint32_t)HET_NWIN;",
                         "_rec.nwn = (uint32_t)HET_NWIN;")),
    ("the record stamp dropped", "0 time(s)",
     lambda s: s.replace("    _rec.rec_magic = HET_REC_MAGIC;\n", "")),
    ("the record stamped with a literal instead of the symbol", "0 time(s)",
     lambda s: s.replace("_rec.rec_magic = HET_REC_MAGIC;",
                         "_rec.rec_magic = 0x48455431u;")),
    ("a machine define stamped under a drifted name", "HET_LINK_NAM ",
     lambda s: s.replace("#define HET_LINK_NAME", "#define HET_LINK_NAM")),
    ("a knob loses its #ifndef default in het_verdict.h", "no #ifndef default",
     None, lambda s: s.replace("#ifndef HET_PAIR_NAME", "#if 0")),
]


def bite():
    """Each injection runs through the WHOLE lane set, because the define checks
    are judged over their union, and must produce a diagnostic NAMING what broke --
    a red for another lane's reason proves nothing about this injection."""
    print("===== BITE: does recfields FAIL when the binding breaks? =====")
    ok = True
    for row in BITES:
        what, want = row[0], row[1]
        mutate = row[2]
        hmut = row[3] if len(row) > 3 else None
        bad = run(quiet=True, tamper=mutate, header_tamper=hmut, silent=True)
        said = [m for m in bad if want in m]
        if said:
            print("  BITES (gate failed, as it must): %s   [%s]" % (said[0][:110], what))
        else:
            print("  *** DID NOT BITE for its own reason (%d finding(s), none naming "
                  "%r)   [%s]" % (len(bad), want, what))
            ok = False
    print("\n" + "=" * 70)
    if ok:
        print("BITE OK: all %d injections were caught, each by NAME." % len(BITES))
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true",
                    help="prove this gate FAILS when the binding breaks")
    a = ap.parse_args()
    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("recfields: litmus7 not built (run 'make all')")
    return bite() if a.bite else run(a.quiet)


if __name__ == "__main__":
    sys.exit(main())
