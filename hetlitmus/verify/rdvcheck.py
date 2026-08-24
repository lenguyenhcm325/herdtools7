#!/usr/bin/env python3
"""HetLitmus -- the rendezvous gate: every iteration begins at one, and it
orders nothing.

The harness pairs an outcome to an iteration by ADDRESSING it (slot n on both
sides), and that addressing means nothing unless the two sides are actually
running iteration n at the same time.  The rendezvous is what makes them, so
where it sits and what it is made of are correctness properties no other gate
reads: ptxcheck sees the PTX ops, hipsrccheck the HIP source stream, and neither
of them reads the CPU thread, the host readout or the runtime primitive itself.

Five properties, over every emitted het render of both pairs and over the
runtime header they all stage:

  1 Primitive  het_rdv.h's three rendezvous bodies arrive and poll RELAXED and
               at SYSTEM scope, and neither they nor the release delay beside
               them carries an acquire, a release, a seq_cst or a fence of any
               kind.  An acquire poll self-invalidates the GPU L1 [Bagchi26 sec
               5.3] and a system-scope fence flushes it, so a strengthened
               rendezvous erases the cache state the tested iteration is about
               to race on; a device or agent scope is the opposite failure, a
               counter the host participant cannot see at all.
  2 GPU lane   one het_rdv_device() per GPU lane, INSIDE that lane's iteration
               loop, ahead of every tested access and never between two of them
               (litmus/het-runtime/README.md invariant (ii)); the release jitter
               follows it and the tested ops follow that.
  3 CPU thread one het_rdv_host() per cpu_thread_P<n>, inside its loop, ahead of
               the het_run_P<n> call the tested body lives in.
  4 Readout    exactly one add_outcome_outs() site and one discard site, both
               inside the readout loop, so an iteration reaches the histogram
               once and only after its rendezvous flags were read -- and one
               those flags reject is COUNTED, since that count is the whole
               input to the discard-rate disqualifier.
  5 Knobs      every rendezvous knob a render uses is defined by the staged
               het_rdv.h, and _dump_one prints every column as a number.

Usage:  rdvcheck.py [-q]
"""

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LITMUS7 = os.path.join(ROOT, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(ROOT, "litmus", "libdir")
HIPSRCCHECK = os.path.join(HERE, "hipsrccheck.py")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


hip = _load("hipsrccheck", HIPSRCCHECK)
GateError = hip.GateError

# The two het lanes, as (label, corpus dir or None to generate, -gpu-target,
# render extension, census).  Both pairs are read because the rendezvous is
# written once per dialect: the CUDA lane's primitive is a cuda::atomic_ref and
# the HIP lane's is a __hip_atomic_* pair, and a lane read by nothing is a lane
# whose primitive can drift.
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")
HET_N = 471
LANES = [("aarch64 het x cuda", HET_DIR, "cuda", "cu", HET_N),
         ("x86_64 het x hip", None, "hip", "hip", hip.X86_HET_N)]

# ---------------------------------------------------------------------------
# 1. The primitive, in litmus/het-runtime/het_rdv.h.
# ---------------------------------------------------------------------------
# The functions whose bodies are read: two device definitions (one per vendor,
# behind the __HIP_PLATFORM_AMD__ split) and the host one.  The header read is
# the one the harness dir STAGES, never a copy of its text.
# het_rdv_jitter is read with them: it runs INSIDE the window the rendezvous
# opens, between the release and the first tested access, so an ordering
# construct there would sit in the tested group even though no rendezvous op
# does.
RDV_BODIES = ("het_rdv_device", "het_rdv_host", "het_rdv_jitter")
# The two the counter is arrived at and polled with; the jitter carries no
# atomic and is read for the forbidden tokens alone.
RDV_ATOMIC_BODIES = ("het_rdv_device", "het_rdv_host")
# An order token that is not `relaxed', and every construct that carries an
# ordering effect of its own.  Matched case-insensitively so __ATOMIC_ACQUIRE and
# cuda::memory_order_acquire are the same finding.
FORBIDDEN = ("acquire", "release", "acq_rel", "seq_cst", "consume",
             "fence", "syncthreads", "s_barrier", "threadfence")
RELAXED = ("__ATOMIC_RELAXED", "cuda::memory_order_relaxed")
# The scope of the device arms, which no other check in this gate reads and
# which the order tokens above say nothing about: a relaxed atomic at device or
# agent scope is invisible to the CPU participant, so the counter it arrives at
# is not the one the host is polling and the two sides never meet.  One entry
# per vendor: the system spelling its arm must carry, and the narrower spellings
# that must appear in neither.
DEV_SCOPES = (
    ("CUDA", "cuda::thread_scope_system",
     ("cuda::thread_scope_device", "cuda::thread_scope_block",
      "cuda::thread_scope_thread")),
    ("HIP", "__HIP_MEMORY_SCOPE_SYSTEM",
     ("__HIP_MEMORY_SCOPE_AGENT", "__HIP_MEMORY_SCOPE_WORKGROUP",
      "__HIP_MEMORY_SCOPE_WAVEFRONT", "__HIP_MEMORY_SCOPE_SINGLETHREAD")),
)
# The release delay spins on nothing: an empty asm template costs no memory
# operation, and a spin that touched memory would add traffic to the very window
# the delay exists to sweep.
JITTER_ASM = re.compile(r'__asm__\s+__volatile__\(\s*""')
# What the caller must be able to reach, and what a harness that stages this
# header must therefore find in it.
KNOBS = ("HET_SLOT_STRIDE_WORDS", "HET_CAP_GPU", "HET_CAP_CPU",
         "HET_CAP_CALIBRATED", "HET_RELEASE_JITTER")


def function_bodies(text, names):
    """{name: [body lines]} for each C function whose signature names one of
    [names], from its opening brace to the closing brace in column 0.

    One entry per DEFINITION, so the vendor split (#if __HIP_PLATFORM_AMD__)
    yields both device bodies and neither hides behind the other."""
    out = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        hit = [n for n in names if re.search(r'\b%s\s*\(' % re.escape(n), lines[i])]
        if hit and "{" in "".join(lines[i:i + 3]):
            j, depth, body = i, 0, []
            while j < len(lines):
                body.append(lines[j])
                depth += lines[j].count("{") - lines[j].count("}")
                if depth <= 0 and "{" in "".join(body):
                    break
                j += 1
            out.setdefault(hit[0], []).append(body)
            i = j + 1
            continue
        i += 1
    return out


def check_primitive(path):
    """Property 1, plus property 5's half that lives in the header."""
    bad = []
    with open(path) as fh:
        text = fh.read()
    for knob in KNOBS:
        if not re.search(r'^#define %s\b' % re.escape(knob), text, re.M):
            bad.append("het_rdv.h defines no %s -- a harness that stages this "
                       "header does not compile" % knob)
    bodies = function_bodies(text, RDV_BODIES)
    for name in RDV_BODIES:
        got = bodies.get(name, [])
        if not got:
            bad.append("het_rdv.h carries no %s body at all" % name)
            continue
        for k, body in enumerate(got):
            who = "%s%s" % (name, "" if len(got) == 1 else " (definition %d)" % (k + 1))
            joined = "\n".join(body)
            low = joined.lower()
            for tok in FORBIDDEN:
                if tok in low:
                    bad.append(
                        "%s carries %r: the rendezvous must ORDER NOTHING, and an "
                        "acquire, a release or a fence in it erases the cache "
                        "state the tested iteration is about to race on" % (who, tok))
            if name not in RDV_ATOMIC_BODIES:
                if JITTER_ASM.search(joined) is None:
                    bad.append(
                        "%s does not spin on an EMPTY asm template: the release "
                        "delay must issue no instruction and touch no memory, or "
                        "it adds traffic to the window it exists to sweep" % who)
                continue
            n_relaxed = sum(joined.count(t) for t in RELAXED)
            if n_relaxed < 2:
                bad.append(
                    "%s spells %d relaxed memory order(s), not the arrival and "
                    "the poll -- the gate cannot see what order its two accesses "
                    "carry" % (who, n_relaxed))
    # The device arms' scope, one definition per vendor: each must spell its own
    # system scope and no narrower one, and between them both vendors must be
    # covered -- an arm that lost its dialect is an arm nothing here reads.
    dev = bodies.get("het_rdv_device", [])
    covered = set()
    for k, body in enumerate(dev):
        who = "het_rdv_device (definition %d)" % (k + 1)
        joined = "\n".join(body)
        mine = [v for v, sysscope, _ in DEV_SCOPES if sysscope in joined]
        for vendor, sysscope, narrower in DEV_SCOPES:
            for tok in narrower:
                if tok in joined:
                    bad.append(
                        "%s arrives or polls at %s: the counter is shared with a "
                        "CPU participant, so a rendezvous narrower than %s is one "
                        "the host half cannot see" % (who, tok, sysscope))
        if not mine:
            bad.append(
                "%s names no system memory scope at all (neither %s): a scopeless "
                "device atomic is not a cross-device rendezvous"
                % (who, " nor ".join(s for _, s, _ in DEV_SCOPES)))
        covered.update(mine)
    for vendor, sysscope, _ in DEV_SCOPES:
        if vendor not in covered:
            bad.append("no het_rdv_device definition spells %s, so the %s lane "
                       "stages a header whose rendezvous this gate never read"
                       % (sysscope, vendor))
    return bad


# ---------------------------------------------------------------------------
# 2-5. The renders.
# ---------------------------------------------------------------------------
LANE_HEAD = re.compile(r'^  if \(blockIdx\.x == \d+ && threadIdx\.x == \d+\) \{$')
CPU_HEAD = re.compile(r'^static void\* cpu_thread_P(\d+)\(void\* _a\) \{$')
LOOP_HEAD = re.compile(r'^\s*for \(int _n=0; _n<SIZE_OF_TEST; \+\+_n\) \{$')
RDV_DEV = re.compile(r'^\s*(_rdvG_P\d+)\[_n\] = het_rdv_device\(barrier, '
                     r'\(uint64_t\)NPART\*\(uint64_t\)\(_n\+1\), _cap_gpu\);$')
RDV_HOST = re.compile(r'^\s*a->_rdv\[_n\] = het_rdv_host\(a->barrier, '
                      r'\(uint64_t\)NPART\*\(uint64_t\)\(_n\+1\), a->_cap, .+\);$')
JITTER = re.compile(r'^\s*het_rdv_jitter\(&\w+, HET_RELEASE_JITTER\);$')
# The traceability comment both dialects write ahead of every tested access
# (litmus/cudaLang.ml, litmus/hipLang.ml): the ONE anchor that says "a tested op
# is here" without knowing which vendor rendered it.
MODEL_OP = re.compile(r'//\s*[wrf]\[')
RUN_CALL = re.compile(r'^\s*het_run_P(\d+)\(')
ADD_OUT = re.compile(r'\badd_outcome_outs\(')
SCORED = re.compile(r'^\s*_rec\.iters_scored\+\+;$')
DISCARDED = re.compile(r'^\s*if \(!_ok\) \{ _rec\.iters_discarded\+\+; continue; \}$')
DUMP_ONE = re.compile(r'^static void _dump_one\(')


def block_span(lines, i):
    """[i, j] of the brace-delimited block opening on line i, or None."""
    depth = 0
    for j in range(i, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth <= 0 and j > i:
            return (i, j)
    return None


def one_loop(lines, span, who, bad):
    """The single iteration loop of a lane or a CPU thread, as a (first, last)
    line span, or None with the finding already recorded."""
    heads = [i for i in range(span[0] + 1, span[1]) if LOOP_HEAD.match(lines[i])]
    if len(heads) != 1:
        bad.append("%s carries %d iteration loop(s), not one -- there is no one "
                   "place a rendezvous could open every iteration"
                   % (who, len(heads)))
        return None
    inner = block_span(lines, heads[0])
    if inner is None:
        bad.append("%s: its iteration loop has no closing brace" % who)
    return inner


def check_render(label, name, text):
    """Properties 2-5 over one emitted render."""
    bad = []
    lines = text.splitlines()
    who0 = "%s %s" % (label, name)

    # ---- 2. every GPU lane opens its iteration at the rendezvous ----------
    lanes = [i for i, ln in enumerate(lines) if LANE_HEAD.match(ln)]
    flags = []
    for i in lanes:
        span = block_span(lines, i)
        who = "%s lane at line %d" % (who0, i + 1)
        if span is None:
            bad.append("%s: the lane block has no closing brace" % who)
            continue
        inner = one_loop(lines, span, who, bad)
        if inner is None:
            continue
        rdv = [j for j in range(*span) if RDV_DEV.match(lines[j])]
        jit = [j for j in range(*span) if JITTER.match(lines[j])]
        ops = [j for j in range(*span) if MODEL_OP.search(lines[j])]
        if len(rdv) != 1 or len(jit) != 1:
            bad.append("%s carries %d rendezvous and %d release jitter(s), not "
                       "one of each" % (who, len(rdv), len(jit)))
            continue
        flags.append(RDV_DEV.match(lines[rdv[0]]).group(1))
        if not (inner[0] < rdv[0] < inner[1]):
            bad.append("%s: its rendezvous sits OUTSIDE the iteration loop, so "
                       "the two sides meet once and every iteration after the "
                       "first runs unsynchronised" % who)
        if ops and rdv[0] > min(ops):
            bad.append("%s: its rendezvous sits AFTER a tested access (line %d "
                       "follows line %d) -- the rendezvous goes AROUND the "
                       "tested group, never between two of its accesses"
                       % (who, rdv[0] + 1, min(ops) + 1))
        if jit[0] < rdv[0] or (ops and jit[0] > min(ops)):
            bad.append("%s: its release jitter does not sit between the "
                       "rendezvous and the first tested access" % who)
    if len(set(flags)) != len(flags):
        bad.append("%s: two GPU lanes record their arrivals in the same flag "
                   "buffer (%s), so one lane's rendezvous is read as another's"
                   % (who0, ", ".join(sorted(flags))))
    n_dev = sum(1 for ln in lines if "het_rdv_device(" in ln)
    if n_dev != len(lanes):
        bad.append("%s calls het_rdv_device %d time(s) for %d GPU lane(s)"
                   % (who0, n_dev, len(lanes)))

    # ---- 3. every CPU thread opens its iteration at the rendezvous --------
    cpus = [i for i, ln in enumerate(lines) if CPU_HEAD.match(ln)]
    for i in cpus:
        span = block_span(lines, i)
        who = "%s cpu_thread_P%s" % (who0, CPU_HEAD.match(lines[i]).group(1))
        if span is None:
            bad.append("%s: the thread body has no closing brace" % who)
            continue
        inner = one_loop(lines, span, who, bad)
        if inner is None:
            continue
        rdv = [j for j in range(*span) if RDV_HOST.match(lines[j])]
        jit = [j for j in range(*span) if JITTER.match(lines[j])]
        run = [j for j in range(*span) if RUN_CALL.match(lines[j])]
        if len(rdv) != 1 or len(jit) != 1 or len(run) != 1:
            bad.append("%s carries %d rendezvous, %d release jitter(s) and %d "
                       "call(s) to its tested body, not one of each"
                       % (who, len(rdv), len(jit), len(run)))
            continue
        if not (inner[0] < rdv[0] < inner[1]):
            bad.append("%s: its rendezvous sits OUTSIDE the iteration loop, so "
                       "the two sides meet once and every iteration after the "
                       "first runs unsynchronised" % who)
        if not (rdv[0] < jit[0] < run[0]):
            bad.append("%s: its iteration does not run rendezvous, then jitter, "
                       "then the tested body (lines %d, %d, %d)"
                       % (who, rdv[0] + 1, jit[0] + 1, run[0] + 1))
    n_host = sum(1 for ln in lines if "het_rdv_host(" in ln)
    if n_host != len(cpus):
        bad.append("%s calls het_rdv_host %d time(s) for %d CPU thread(s) -- a "
                   "thread that never arrives holds every other participant at "
                   "the cap" % (who0, n_host, len(cpus)))

    # ---- 4. one histogram site, inside the readout -----------------------
    adds = [i for i, ln in enumerate(lines) if ADD_OUT.search(ln)]
    scored = [i for i, ln in enumerate(lines) if SCORED.match(ln)]
    if len(adds) != 1 or len(scored) != 1:
        bad.append("%s carries %d add_outcome_outs site(s) and %d scoring "
                   "site(s), not one of each -- an iteration reaches the "
                   "histogram once" % (who0, len(adds), len(scored)))
    else:
        heads = [i for i in range(scored[0]) if LOOP_HEAD.match(lines[i])]
        readout = block_span(lines, heads[-1]) if heads else None
        if readout is None or not (readout[0] < adds[0] < readout[1]):
            bad.append("%s: its add_outcome_outs site is not inside the readout "
                       "loop, so an outcome reaches the histogram without its "
                       "iteration's rendezvous flags being read" % who0)

    # ... and the iteration those flags rejected, which is counted and not merely
    # skipped: iters_discarded is the whole input to the discard-rate rule, so a
    # readout that stopped counting would read a run the two sides never shared as
    # a clean null.
    disc = [i for i, ln in enumerate(lines) if DISCARDED.match(ln)]
    if len(disc) != 1:
        bad.append("%s carries %d discard site(s), not one -- an iteration whose "
                   "rendezvous timed out is counted, and that count is what "
                   "disqualifies the run" % (who0, len(disc)))
    elif len(scored) == 1 and disc[0] > scored[0]:
        bad.append("%s scores an iteration before it discards one, so an iteration "
                   "its rendezvous flags rejected reaches the histogram too" % who0)

    # ---- 5. the outcome dump prints numbers ------------------------------
    dump = [i for i, ln in enumerate(lines) if DUMP_ONE.match(ln)]
    if len(dump) != 1:
        bad.append("%s carries %d _dump_one definition(s), not one" % (who0, len(dump)))
    else:
        span = block_span(lines, dump[0])
        if span and any("=?" in lines[j] for j in range(*span)):
            bad.append("%s: _dump_one prints `=?' for a column -- every column "
                       "is measured per iteration and prints a number" % who0)
    for knob in KNOBS:
        if knob not in text:
            bad.append("%s uses no %s at all" % (who0, knob))
    return bad


# ---------------------------------------------------------------------------
# Emission.
# ---------------------------------------------------------------------------
def emit_corpus(files, target, out):
    """Emit a whole corpus in one litmus7 invocation, into [out]."""
    os.makedirs(out, exist_ok=True)
    r = subprocess.run([LITMUS7, "-gpu-target", target, "-set-libdir", LIBDIR,
                        "-o", out] + files,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        raise GateError("litmus7 -gpu-target %s refused the corpus (exit %d):\n%s"
                        % (target, r.returncode, r.stdout[-2000:]))
    return out


def lane_renders(tmp, label, corpus, target, ext, expect):
    """[(name, render path, harness dir)] for one lane, census asserted first."""
    if corpus is None:
        corpus = hip.regen_x86(os.path.join(tmp, "x86-corpus"))
    files = hip.corpus_files(corpus, label, expect)
    out = emit_corpus(files, target, os.path.join(tmp, target + "-out"))
    got = []
    for f in files:
        name = os.path.basename(f)[:-len(".litmus")]
        d = os.path.join(out, name)
        render = os.path.join(d, name + "." + ext)
        if not os.path.exists(render):
            raise GateError("%s: litmus7 wrote no %s for %s" % (label, ext, name))
        got.append((name, render, d))
    return got


def run(quiet=False):
    print("===== rdvcheck: does every iteration begin at a rendezvous, and "
          "does it order nothing? =====")
    bad = []
    tmp = tempfile.mkdtemp(prefix="rdvcheck.")
    try:
        header_seen = 0
        for label, corpus, target, ext, expect in LANES:
            renders = lane_renders(tmp, label, corpus, target, ext, expect)
            for name, render, _d in renders:
                with open(render) as fh:
                    text = fh.read()
                bad += check_render(label, name, text)
            if renders:
                hdr = os.path.join(renders[0][2], "het_rdv.h")
                bad += check_primitive(hdr)
                header_seen += 1
            if not quiet:
                print("      %-22s %3d render(s) read, the staged het_rdv.h with "
                      "them" % (label, len(renders)))
        if header_seen != len(LANES):
            bad.append("only %d of %d lane(s) staged a het_rdv.h to read"
                       % (header_seen, len(LANES)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for m in bad:
        print("  *** %s" % m)
    if bad:
        print("\nRDVCHECK FAILED: %d problem(s).  A slot readout pairs an outcome "
              "to an iteration only while both sides are running that iteration."
              % len(bad))
        return 1
    print("\nRDVCHECK OK (%d + %d render(s): one rendezvous per participant per "
          "iteration, ahead of every tested access, relaxed and fence-free, and "
          "one histogram site and one discard site inside the readout)"
          % (HET_N, hip.X86_HET_N))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    if not os.access(LITMUS7, os.X_OK):
        raise SystemExit("rdvcheck: litmus7 not built (run 'make all')")
    try:
        return run(a.quiet)
    except GateError as e:
        print("RDVCHECK CANNOT RUN: %s" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
