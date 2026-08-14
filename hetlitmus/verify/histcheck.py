#!/usr/bin/env python3
"""histcheck.py -- the outcome-histogram gate.  It pins two invariants:

  (1) The histogram is fed once per observation.  A shape with a reader has a
      per-frame observable (`int _hot ='), so its add belongs inside the per-frame
      loop; a reader-less store-only shape has only the run-level observer witness,
      which is constant across that loop, so its add belongs at run level.  A
      per-run fact added once per frame multiplies one observation by N.
  (2) A coherence-final `[ell]' column never prints a number, because none is
      measured: that atom is decided by the per-run observer `ws' witness and
      reported through HetObs / HetVerdict (hetlitmus/docs/positive-control.md S6),
      so the slot carries no bits to print.

  PHASE 1 -- shape, over every emitted harness.  Exactly one histogram add each,
    since only T feeds it: inside the frame loop guarded by exactly
    `_hot || _weak' where a per-frame observable exists, and an unconditional
    run-level add shown by an observer `_loc' witness where none does.
  PHASE 2 -- display, over the same corpus.  Register slots print numerically and
    location slots print `?', checked both ways, the print loops partitioning the
    slots exactly.
  PHASE 3 -- arithmetic, on the real emitted tally, compiled and run.  The
    store-only tally region is lifted verbatim out of the emitted .cu, so emission
    drift shows up here, then linked against the harness's own outs.c and driven
    with forced per-run witness patterns: `sum_outs(hist)' must equal R for every
    pattern and must not scale with SIZE_OF_TEST.  The per-frame variant of that
    same tally must then be REJECTED -- an arithmetic check never seen to reject
    anything is not evidence.

Usage:  histcheck.py           run the gate
        histcheck.py --bite    prove the gate FAILS when the mechanism breaks
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

# Corpus censuses, re-derived below from the emitted artifacts.  A mismatch means
# either the corpus changed (update these, deliberately) or the emitter did -- which
# is what this gate is for.
N_TESTS = 411
N_STORE_ONLY = 11           # the 2+2W family: no reader, observer-only
N_WITH_LOC_COLUMN = 117     # the shapes with a ws-location: 2+2W 11 + R 53 + S 53

# The store-only shape whose tally Phase 3 extracts and runs.
TALLY_TEST = "2+2W-cg-sys-fence"

FRAME_LOOP = "for (int _f=0; _f<SIZE_OF_TEST; ++_f) {"
ADD_RE = re.compile(r"hist = add_outcome_outs\(hist, _o, (\d+), 1, ([A-Za-z0-9_]+)\);")
LABELS_RE = re.compile(r'static const char\* _labels\[(\d+)\] = \{ (.*) \};')
NUM_LOOP_RE = re.compile(
    r'for \(int i=(\d+);i<(\d+);i\+\+\) fprintf\(_ch, "%s=%" PRIdMAX "; ", _labels\[i\], o\[i\]\);')
Q_LOOP_RE = re.compile(
    r'for \(int i=(\d+);i<(\d+);i\+\+\) fprintf\(_ch, "%s=\?; ", _labels\[i\]\);')
HOT_RE = re.compile(r"^\s+int _hot = ", re.M)
LOC_DECL_RE = re.compile(r"^\s+int (_?\w*_loc) = ", re.M)


def _env():
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    return env


# ---------------------------------------------------------------------------
# emission
# ---------------------------------------------------------------------------
def emit_corpus(tmp):
    """Emit all het harnesses once.  Returns {test: (src, dir)}."""
    tests = sorted(t[:-len(".litmus")] for t in os.listdir(HET_DIR)
                   if t.endswith(".litmus"))
    r = subprocess.run(
        ["litmus7", "-gpu-target", "cuda", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
         "-o", tmp] + [os.path.join(HET_DIR, t + ".litmus") for t in tests],
        cwd=ROOT, env=_env(), capture_output=True, text=True)
    if r.returncode != 0:
        print("  *** litmus7 failed to emit the corpus:\n" + r.stderr[-2000:])
        raise SystemExit(2)
    out = {}
    for t in tests:
        d = os.path.join(tmp, t)
        cu = os.path.join(d, t + ".cu")
        if not os.path.exists(cu):
            print("  *** %-26s no .cu emitted" % t)
            raise SystemExit(2)
        with open(cu) as fh:
            out[t] = (fh.read(), d)
    return out


# ---------------------------------------------------------------------------
# a very small C block scanner (brace depth, string/char literals removed)
# ---------------------------------------------------------------------------
def _strip_literals(line):
    # No quote opens the scan below, so it copies the line character by character:
    # on a line without one the loop is the identity and the copy is skipped.
    if '"' not in line and "'" not in line:
        return line
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c in "\"'":
            q = c
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == q:
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def line_depths(lines):
    """depth[i] = brace depth BEFORE line i."""
    depths, d = [], 0
    for ln in lines:
        depths.append(d)
        s = _strip_literals(ln)
        d += s.count("{") - s.count("}")
    return depths


def frame_loops(lines, depths):
    """[(header_index, depth_of_body)] for every per-frame recovery loop."""
    out = []
    for i, ln in enumerate(lines):
        if FRAME_LOOP in ln:
            out.append((i, depths[i] + 1))
    return out


def loop_extent(lines, depths, header):
    """Index of the line CLOSING the loop opened on line `header'.  depths[] is the
       depth BEFORE a line, so the closing line is the first one after which the depth
       is back to the header's.  Off by one here would put every statement after the
       loop `inside' it -- the very confusion this gate exists to detect."""
    d0 = depths[header]
    for j in range(header + 1, len(lines)):
        s = _strip_literals(lines[j])
        if depths[j] + s.count("{") - s.count("}") <= d0:
            return j
    return len(lines) - 1


def enclosing_guard(lines, depths, idx):
    """Text of the innermost block header enclosing line `idx' ('' if none)."""
    d = depths[idx]
    for j in range(idx - 1, -1, -1):
        if depths[j] == d - 1 and "{" in _strip_literals(lines[j]):
            return lines[j].strip()
    return ""


# ---------------------------------------------------------------------------
# PHASE 1 -- shape
# ---------------------------------------------------------------------------
def phase1(srcs):
    print("\n===== PHASE 1: is the histogram fed once per OBSERVATION? =====")
    bad, n_store, n_read = 0, 0, 0
    for t in sorted(srcs):
        src, _ = srcs[t]
        lines = src.split("\n")
        depths = line_depths(lines)
        adds = [i for i, ln in enumerate(lines) if "hist = add_outcome_outs(" in ln]
        if len(adds) != 1:
            print("  *** %-26s %d histogram adds (want exactly 1: only T feeds it, "
                  "and a per-run fact must not be added per frame)" % (t, len(adds)))
            bad += 1
            continue
        add = adds[0]
        m = ADD_RE.search(lines[add])
        if m is None:
            print("  *** %-26s unrecognised add: %s" % (t, lines[add].strip()))
            bad += 1
            continue
        show = m.group(2)
        loops = frame_loops(lines, depths)
        if not loops:
            print("  *** %-26s no per-frame recovery loop at all" % t)
            bad += 1
            continue
        inside = None
        for hdr, _bd in loops:
            if hdr < add < loop_extent(lines, depths, hdr):
                inside = hdr
                break
        has_hot = HOT_RE.search(src) is not None

        if has_hot:
            n_read += 1
            if inside is None:
                print("  *** %-26s has a per-frame observable but its histogram add "
                      "is OUTSIDE the frame loop" % t)
                bad += 1
                continue
            g = enclosing_guard(lines, depths, add)
            if g != "if (_hot || _weak) {":
                print("  *** %-26s in-loop add guarded by %r (want 'if (_hot || _weak) {'"
                      " -- the only per-frame predicate)" % (t, g))
                bad += 1
            if show != "_weak":
                print("  *** %-26s in-loop add shown by %r (want '_weak')" % (t, show))
                bad += 1
        else:
            n_store += 1
            if inside is not None:
                print("  *** %-26s HAS NO per-frame observable (no `int _hot =') yet its "
                      "histogram add sits INSIDE the frame loop -- one per-run witness "
                      "would be tallied N times" % t)
                bad += 1
                continue
            locs = LOC_DECL_RE.findall(src)
            if show not in locs:
                print("  *** %-26s per-run add shown by %r, not by an observer `_loc' "
                      "witness %r" % (t, show, locs))
                bad += 1
            hdr = loops[0][0]
            g = enclosing_guard(lines, depths, add)
            # The per-run add lives in a bare `{ intmax_t _o[n]; ... }' block at the
            # frame loop's own level.  The block must be UNCONDITIONAL: an add hidden
            # behind a condition would silently drop runs from the tally -- the same
            # class of error in the other direction.
            if not g.startswith("{ intmax_t _o["):
                print("  *** %-26s per-run add is enclosed by %r, not an unconditional "
                      "outcome block" % (t, g))
                bad += 1
            elif depths[add] != depths[hdr] + 1:
                print("  *** %-26s per-run add at depth %d, frame loop at depth %d "
                      "(the add must be at RUN level)" % (t, depths[add], depths[hdr]))
                bad += 1

    print()
    for label, seen, want in (("reader shapes (add per FRAME)", n_read, N_TESTS - N_STORE_ONLY),
                              ("store-only  (add per RUN)  ", n_store, N_STORE_ONLY)):
        mark = "    " if seen == want else " ***"
        print("%s  %s  %3d  (expect %3d)" % (mark, label, seen, want))
        if seen != want:
            bad += 1
    if len(srcs) != N_TESTS:
        print(" ***  corpus size %d (expect %d)" % (len(srcs), N_TESTS))
        bad += 1

    if bad:
        print("\nPHASE 1 FAILED: %d problem(s)." % bad)
        return 1
    print("\nPHASE 1 OK (%d harnesses; every histogram add is fed once per "
          "observation, never once per frame per run)" % len(srcs))
    return 0


# ---------------------------------------------------------------------------
# PHASE 2 -- display
# ---------------------------------------------------------------------------
def phase2(srcs):
    print("\n===== PHASE 2: does a column ever print a value that was never measured? =====")
    bad, n_loc = 0, 0
    for t in sorted(srcs):
        src, _ = srcs[t]
        m = LABELS_RE.search(src)
        if m is None:
            print("  *** %-26s no _labels array" % t)
            bad += 1
            continue
        nslots = int(m.group(1))
        labels = [x.strip().strip('"') for x in m.group(2).split(",")] if m.group(2).strip() else []
        locs = [i for i, l in enumerate(labels) if l.startswith("[")]
        nloc = len(locs)
        if nloc:
            n_loc += 1
            n_reg = len(labels) - nloc
            if locs != list(range(n_reg, len(labels))):
                print("  *** %-26s location columns are not the trailing slots: %r"
                      % (t, labels))
                bad += 1
                continue
        else:
            n_reg = len(labels)

        num = [(int(a), int(b)) for a, b in NUM_LOOP_RE.findall(src)]
        que = [(int(a), int(b)) for a, b in Q_LOOP_RE.findall(src)]
        # Every numerically printed slot must be a REGISTER slot.
        for lo, hi in num:
            if hi > n_reg:
                print("  *** %-26s prints slots [%d,%d) as numbers, but only [0,%d) are "
                      "measured registers -- an unmeasured location column would print a "
                      "fabricated value" % (t, lo, hi, n_reg))
                bad += 1
        if nloc == 0:
            if que:
                print("  *** %-26s emits a `?' column but has no location slot" % t)
                bad += 1
            if num != [(0, nslots)]:
                print("  *** %-26s register-only test prints %r (want [(0,%d)])"
                      % (t, num, nslots))
                bad += 1
        else:
            if que != [(n_reg, len(labels))]:
                print("  *** %-26s location columns [%d,%d) are not printed as `?': %r"
                      % (t, n_reg, len(labels), que))
                bad += 1
            if n_reg and num != [(0, n_reg)]:
                print("  *** %-26s register columns printed as %r (want [(0,%d)])"
                      % (t, num, n_reg))
                bad += 1
            if n_reg == 0 and num:
                print("  *** %-26s has no register column yet prints %r numerically"
                      % (t, num))
                bad += 1

    mark = "    " if n_loc == N_WITH_LOC_COLUMN else " ***"
    print("\n%s  harnesses with a [ell] column  %3d  (expect %3d)"
          % (mark, n_loc, N_WITH_LOC_COLUMN))
    if n_loc != N_WITH_LOC_COLUMN:
        bad += 1

    if bad:
        print("\nPHASE 2 FAILED: %d problem(s)." % bad)
        return 1
    print("\nPHASE 2 OK (%d harnesses; %d carry a coherence-final column and none of "
          "them prints a number for it)" % (len(srcs), n_loc))
    return 0


# ---------------------------------------------------------------------------
# PHASE 3 -- the arithmetic, on the REAL extracted tally
# ---------------------------------------------------------------------------
PROBE_MAIN = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include "outs.h"

/* outs.c declares this and the harness's .cu defines it; the probe links only
   outs.c, so it supplies the same one-liner. */
void *malloc_check(size_t sz) ;
void *malloc_check(size_t sz) { void *p = malloc(sz); if (!p) abort(); return p; }

#define SIZE_OF_TEST %(N)d

static struct {
  uint64_t frames_examined, target_count_exhaustive, target_count_heuristic;
  uint64_t ws_edges_via_observer;
} _rec;

static count_t g_sum; static int g_rows, g_show;
static void _one(FILE* ch, intmax_t* o, count_t c, int show) {
  (void)ch; (void)o; g_sum += c; g_rows++; g_show |= show;
}

int main(int argc, char** argv) {
  outs_t* hist = NULL;
  int R = argc - 1;
  uint64_t frames = 0;
  for (int _run = 0; _run < R; ++_run) {
    memset(&_rec, 0, sizeof _rec);
    int _t_loc = atoi(argv[_run + 1]);
%(BODY)s
    frames += _rec.frames_examined;
  }
  { intmax_t buf[8];
    dump_outs(stdout, _one, hist, buf, %(NSLOTS)d); }
  printf("R=%%d frames=%%" PRIu64 " sum=%%" PRIu64 " rows=%%d show=%%d\n",
         R, frames, (uint64_t)g_sum, g_rows, g_show);
  free_outs(hist);
  return 0;
}
"""


def extract_tally(src):
    """Pull the store-only tally VERBATIM, from the per-frame loop through the per-run
       histogram add.  Nothing is hand-written, so emission drift shows up here."""
    lines = src.split("\n")
    adds = [i for i, ln in enumerate(lines) if "hist = add_outcome_outs(" in ln]
    if len(adds) != 1:
        return None, "expected exactly 1 histogram add, found %d" % len(adds)
    add = adds[0]
    depths = line_depths(lines)
    hdrs = [i for i, ln in enumerate(lines) if FRAME_LOOP in ln and i < add]
    if not hdrs:
        return None, "no per-frame loop before the histogram add"
    # This phase's premise: a store-only tally is a PER-RUN add following the frame
    # loop.  An add inside the loop is not a toolchain error to report as one; it is
    # invariant (1) breaking, and must be named as such.
    if add < loop_extent(lines, depths, hdrs[0]):
        return None, ("the histogram add sits INSIDE the per-frame loop -- a "
                      "reader-less shape has no per-frame outcome to tally")
    body = "\n".join(lines[hdrs[0]:add + 1])
    if "add_outcome_outs" not in body:
        return None, "extraction lost the add"
    return body, None


def build_probe(tmp, name, body, nslots, n, outs_dir):
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    for f in ("outs.c", "outs.h"):
        shutil.copy(os.path.join(outs_dir, f), os.path.join(d, f))
    with open(os.path.join(d, "probe.c"), "w") as fh:
        fh.write(PROBE_MAIN % {"N": n, "BODY": body, "NSLOTS": nslots})
    r = subprocess.run(["cc", "-O1", "-o", "probe", "probe.c", "outs.c"],
                       cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr[-1500:]
    return d, None


def run_probe(d, pattern):
    r = subprocess.run(["./probe"] + [str(x) for x in pattern],
                       cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    m = re.search(r"R=(\d+) frames=(\d+) sum=(\d+) rows=(\d+) show=(\d+)", r.stdout)
    return tuple(int(x) for x in m.groups()) if m else None


# The per-frame variant of the tally, re-created from the CURRENT extraction.  Phase 3
# must reject it, or its arithmetic assertion has never been seen to reject anything.
def refit_prefix_bug(body):
    lines = body.split("\n")
    out, done = [], False
    for ln in lines:
        if not done and ln.strip().startswith("if (_weak) { _rec.target_count"):
            out.append(ln)
            ind = ln[:len(ln) - len(ln.lstrip())]
            out.append(ind + "if (_weak) {")
            out.append(ind + "  intmax_t _ob[2]; _ob[0] = 0; _ob[1] = 0;")
            out.append(ind + "  hist = add_outcome_outs(hist, _ob, 2, 1, _weak);")
            out.append(ind + "}")
            done = True
            continue
        out.append(ln)
    return ("\n".join(out), done)


def phase3(srcs):
    print("\n===== PHASE 3: the REAL emitted tally, compiled and RUN =====")
    if TALLY_TEST not in srcs:
        print("  *** %s not in the corpus" % TALLY_TEST)
        return 2
    src, d = srcs[TALLY_TEST]
    body, err = extract_tally(src)
    if body is None:
        print("  *** extraction failed on %s: %s" % (TALLY_TEST, err))
        return 1
    print("  extracted %d lines of tally VERBATIM from %s.cu"
          % (len(body.split("\n")), TALLY_TEST))

    N = 1000
    tmp = tempfile.mkdtemp(prefix="histcheck.")
    bad = 0
    try:
        pd, err = build_probe(tmp, "fixed", body, 2, N, d)
        if pd is None:
            print("  *** the extracted tally does not compile:\n" + err)
            return 2
        cases = [([1, 0, 1], 3), ([0, 0, 0], 3), ([1, 1], 2), ([1], 1)]
        for pattern, want in cases:
            got = run_probe(pd, pattern)
            if got is None:
                print("  *** probe failed on pattern %r" % (pattern,))
                bad += 1
                continue
            R, frames, total, rows, show = got
            ok = (total == want == R)
            print("    %s witness pattern %-10s R=%d frames=%d -> sum_outs=%d "
                  "(want %d), rows=%d, show=%d"
                  % ("    " if ok else " ***", str(pattern), R, frames, total, want,
                     rows, show))
            if not ok:
                bad += 1
            # No `total > frames' assertion here: extract_tally admits only a body
            # with exactly one add, executed at most once per frame iteration, so
            # total <= R*SIZE_OF_TEST = frames holds by construction and the check
            # could never fire.  The per-frame arm below is where that inequality
            # is a real assertion.
            want_show = 1 if any(pattern) else 0
            if show != want_show:
                print("     *** show=%d, want %d (the `*' marker must track the "
                      "witness, both ways)" % (show, want_show))
                bad += 1

        # Discriminating power: the same assertion, on the per-frame variant.
        buggy, hit = refit_prefix_bug(body)
        if not hit:
            print("  *** could not re-create the pre-fix tally (nothing matched) -- "
                  "this self-test is VACUOUS")
            bad += 1
        else:
            pd2, err = build_probe(tmp, "prefix", buggy, 2, N, d)
            if pd2 is None:
                print("  *** the pre-fix variant does not compile:\n" + err)
                bad += 1
            else:
                # Two patterns, because they prove different things.  [1,0,1] pins
                # the closed form against a partial witness run; the all-ones one
                # is the ONLY pattern that puts the tally above the frames examined
                # (3*1000+3 > 3*1000), which is the impossible row the diagnostic
                # below names.  Neither may coincide with the fixed tally: an arm
                # whose output is what the fixed variant already prints rejects
                # nothing.
                distinguishing = 0
                gb10 = 0
                for pattern in ([1, 0, 1], [1, 1, 1]):
                    got = run_probe(pd2, pattern)
                    if got is None:
                        print("  *** pre-fix probe failed on pattern %r" % (pattern,))
                        bad += 1
                        continue
                    R, frames, total, rows, show = got
                    expect = sum(pattern) * N + R      # N x (#weak runs) + R
                    ok = (total == expect)
                    print("    %s PRE-FIX tally, pattern %r -> sum_outs=%d "
                          "(the bug's closed form N*weak_runs+R = %d), frames=%d"
                          % ("    " if ok else " ***", pattern, total, expect, frames))
                    if total != expect:
                        print("     *** the pre-fix variant did NOT reproduce the bug's "
                              "closed form; this phase cannot claim to detect it")
                        bad += 1
                    if total != R:
                        distinguishing += 1
                    if total > frames:
                        gb10 += 1
                        print("          the histogram total EXCEEDS the frames "
                              "examined (%d > %d) -- this is exactly the GB10 line"
                              % (total, frames))
                # Vacuity, derived from the patterns actually run rather than
                # assumed of a hard-coded one: a pattern with no witness run gives
                # sum(pattern)*N+R == R, which is what the FIXED tally prints, so
                # an arm made only of such patterns would reject nothing.
                if distinguishing == 0:
                    print("     *** no pre-fix pattern produced a tally different from "
                          "the fixed one (all == R) -- this self-test is VACUOUS")
                    bad += 1
                if gb10 == 0:
                    print("     *** no pre-fix pattern drove sum_outs ABOVE the frames "
                          "examined -- the GB10 symptom is not reproduced, so this "
                          "phase cannot claim to detect it")
                    bad += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if bad:
        print("\nPHASE 3 FAILED: %d problem(s)." % bad)
        return 1
    print("\nPHASE 3 OK (the emitted tally adds exactly one outcome per RUN, at any N; "
          "and the pre-fix tally is rejected)")
    return 0


# ---------------------------------------------------------------------------
def run_gate(srcs):
    rcs = {"P1": phase1(srcs),
           "P2": phase2(srcs),
           "P3": phase3(srcs)}
    return rcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove this gate FAILS when the mechanism it guards breaks")
    a = ap.parse_args()
    if a.bite:
        return bite()

    tmp = tempfile.mkdtemp(prefix="histcorpus.")
    try:
        srcs = emit_corpus(tmp)
        rcs = run_gate(srcs)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    if any(rcs.values()):
        print("HISTCHECK: FAIL  (%s)"
              % ", ".join("%s=%d" % kv for kv in sorted(rcs.items())))
        return 1
    print("HISTCHECK: PASS  (shape + display + arithmetic)")
    return 0


# ---------------------------------------------------------------------------
# --bite: THE GATE MUST BITE.  Each injection rewrites the emitted corpus text (the
# channel verdictcheck.py also mutates), is checked to have really changed something,
# and must drive the NAMED phase red -- not just any phase.  A gate that goes red for
# the wrong reason has not been shown to guard anything.
# ---------------------------------------------------------------------------
def _reinsert_per_frame_add(t, src):
    """The per-run witness tallied once per frame."""
    if not t.startswith("2+2W-"):
        return src
    old = "      if (_weak) { _rec.target_count_exhaustive++; _rec.target_count_heuristic++; }\n"
    new = (old +
           "      if (_weak) {\n"
           "        intmax_t _o[2];\n"
           "        _o[0] = 0;\n"
           "        _o[1] = 0;\n"
           "        hist = add_outcome_outs(hist, _o, 2, 1, _weak);\n"
           "      }\n")
    return src.replace(old, new, 1)


def _drop_per_run_add(t, src):
    """The opposite failure: the 11 store-only shapes tally NOTHING at all."""
    if t != TALLY_TEST:
        return src
    return re.sub(r"\n *hist = add_outcome_outs\(hist, _o, \d+, 1, \w*_loc\); \}",
                  " }", src, count=1)


def _run_constant_guard(t, src):
    """A reader shape whose in-loop add is gated on the RUN-level witness."""
    if not t.startswith("R-cg-sys-"):
        return src
    return src.replace("      if (_hot || _weak) {\n", "      if (_t_loc) {\n", 1)


def _numeric_location_column(t, src):
    """Print the never-measured [ell] column as a number again."""
    if not t.startswith("R-cg-sys-"):
        return src
    return re.sub(r'for \(int i=(\d+);i<(\d+);i\+\+\) fprintf\(_ch, "%s=\?; ", _labels\[i\]\);',
                  lambda m: ('for (int i=%s;i<%s;i++) fprintf(_ch, "%%s=%%" PRIdMAX "; ", '
                             '_labels[i], o[i]);' % (m.group(1), m.group(2))),
                  src, count=1)


def _move_add_into_frame_loop(t, src):
    """The same category error with the add count still 1, so the `no per-frame
       observable' rule is the ONLY thing that can catch it -- and this is the
       injection that drives Phase 1's headline assertion."""
    if t != TALLY_TEST:
        return src
    src2 = _drop_per_run_add(t, src)
    if src2 == src:
        return src
    return _reinsert_per_frame_add(t, src2)


INJECTIONS = [
    ("the per-run witness added per FRAME (2+2W)",         _reinsert_per_frame_add, ("P1", "P3")),
    ("the add MOVED into the frame loop (count still 1)",  _move_add_into_frame_loop, ("P1", "P3")),
    ("store-only shapes tally nothing at all",             _drop_per_run_add,       ("P1", "P3")),
    ("reader shape gated on the RUN-level witness",        _run_constant_guard,     ("P1",)),
    ("[ell] column printed as a number again",             _numeric_location_column, ("P2",)),
]


def bite():
    print("=" * 70)
    print("histcheck --bite: each injection must drive the NAMED phase red.")
    tmp = tempfile.mkdtemp(prefix="histbite.")
    ok = True
    try:
        base = emit_corpus(tmp)
        for label, mutate, want_phases in INJECTIONS:
            srcs, hits = {}, 0
            for t, (src, d) in base.items():
                new = mutate(t, src)
                if new != src:                 # cmp: a no-op injection passes for free
                    hits += 1
                srcs[t] = (new, d)
            print("\n-- %s  (%d harness(es) changed)" % (label, hits))
            if hits == 0:
                print("  *** VACUOUS BITE: the injection matched NOTHING")
                ok = False
                continue
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rcs = run_gate(srcs)
            red = [p for p, rc in rcs.items() if rc]
            for p in want_phases:
                if rcs[p] == 0:
                    print("  *** %s stayed GREEN on an injection it must catch" % p)
                    ok = False
                elif rcs[p] == 2:
                    print("  *** %s exited 2 (toolchain error, not the invariant)" % p)
                    ok = False
            if all(rcs[p] != 0 for p in want_phases):
                print("  BITES: %s red (as they must); phases red = %s"
                      % (", ".join(want_phases), ",".join(sorted(red))))
                for ln in buf.getvalue().split("\n"):
                    if ln.startswith("  ***"):
                        print("    | " + ln.strip())
                        break
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n" + "=" * 70)
    if ok:
        print("BITE OK: every injection was caught by the phase that names it.")
        return 0
    print("BITE FAILED: an injection slipped through -- this gate is decorative.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
