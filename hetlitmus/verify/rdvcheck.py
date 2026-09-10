#!/usr/bin/env python3
"""HetLitmus -- the rendezvous gate (hetlitmus/docs/environment-design.md
"Rendezvous"), over one rep render per shape of the emitted template:
  1 Placement  every GPU lane and CPU thread opens its one iteration loop at
               the rendezvous, then the release jitter, then the tested body;
               the readout discards, scores, then banks, once each
  2 Primitive  het_rdv.h arrives and polls relaxed at system scope on both
               vendors and the host, with no fence; the jitter spins on an
               empty asm template
A miss means a slot pairs an outcome to an iteration the two sides were not
running together.  Usage: rdvcheck.py
"""

import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census
import ptxcheck as ptx

# (-gpu-target, corpus, test): one lane and one thread, two lanes, two
# threads, and the HIP dialect.
REPS = (("cuda", census.HET_DIR, "MP-cg-sys-sy.fsc"),
        ("cuda", census.HET_DIR, "3.2W-cgg-sys-plain.fsc"),
        ("cuda", census.HET_DIR, "3.2W-ccg-sys-plain.frel"),
        ("hip", census.X86_DIR, "MP-cg-sys-plain.rlx-x86_64"))

# ---- 1. placement: one letter per anchor line, in file order; E is the
# closing brace of the last L's loop.  The render's word must spell GRAMMAR.
EVENTS = (
    ("H", re.compile(r'^  if \(blockIdx\.x == \d+ && threadIdx\.x == \d+\) \{$')),
    ("C", re.compile(r'^static void\* cpu_thread_P\d+\(void\* _a\) \{$')),
    ("L", re.compile(r'^(\s*)for \(int _n=0; _n<SIZE_OF_TEST; \+\+_n\) \{$')),
    ("R", re.compile(r'^\s*(_rdvG_P\d+)\[_n\] = het_rdv_device\(barrier, '
                     r'\(uint64_t\)NPART\*\(uint64_t\)\(_n\+1\), _cap_gpu\);$')),
    ("r", re.compile(r'^\s*a->_rdv\[_n\] = het_rdv_host\(a->barrier, '
                     r'\(uint64_t\)NPART\*\(uint64_t\)\(_n\+1\), a->_cap, .+\);$')),
    ("J", re.compile(r'^\s*het_rdv_jitter\(het_draw\(.+\), '
                     r'HET_RELEASE_JITTER_SPINS\);$')),
    ("O", re.compile(r'//\s*[wrf]\[')),
    ("K", re.compile(r'^\s*het_run_P\d+\(')),
    ("D", re.compile(r'^\s*if \(!_ok\) \{ _rec\.iters_discarded\+\+; continue; \}$')),
    ("S", re.compile(r'^\s*_rec\.iters_scored\+\+;$')),
    ("A", re.compile(r'\badd_outcome_outs\(')),
)
# A site in any other form is a `?', which the grammar never accepts.
LOOSE = re.compile(r'het_rdv_device\(|het_rdv_host\(|het_rdv_jitter\(|'
                   r'add_outcome_outs\(|iters_scored\+\+|iters_discarded\+\+')
GRAMMAR = re.compile(r'^(HLRJO+E)+(CLrJKE)+LDSAE$')


def events(text):
    """[(letter, line number, match)] over the render."""
    out, end = [], None
    for i, ln in enumerate(text.splitlines(), 1):
        if ln == end:
            out.append(("E", i, None))
            end = None
            continue
        hit = next(((c, m) for c, r in EVENTS for m in [r.search(ln)] if m), None)
        if hit:
            if hit[0] == "L":
                end = hit[1].group(1) + "}"
            out.append((hit[0], i) + hit[1:])
        elif LOOSE.search(ln):
            out.append(("?", i, None))
    return out


def check_placement(name, text):
    ev = events(text)
    bad = []
    if not GRAMMAR.match("".join(c for c, _, _ in ev)):
        bad.append("%s spells %s, not %s"
                   % (name, " ".join("%s%d" % (c, i) for c, i, _ in ev),
                      GRAMMAR.pattern))
    flags = [m.group(1) for c, _, m in ev if c == "R"]
    if len(set(flags)) != len(flags):
        bad.append("%s: two GPU lanes share a flag buffer (%s)"
                   % (name, ", ".join(flags)))
    return bad


# ---- 2. primitive: each body from its signature to the brace in column 0.
BODY = r'^[^\n]*\b%s\s*\(.*?^\}'
FORBIDDEN = re.compile(r'acquire|release|acq_rel|seq_cst|consume|fence|'
                       r'syncthreads|s_barrier|threadfence')
RELAXED = re.compile(r'__ATOMIC_RELAXED|cuda::memory_order_relaxed')
EMPTY_ASM = re.compile(r'__asm__\s+__volatile__\(\s*""')
# Per vendor: the system scope a device body names, and the narrower
# spellings it must not.
SCOPES = (("cuda::thread_scope_system",
           re.compile(r'cuda::thread_scope_(?!system)\w+')),
          ("__HIP_MEMORY_SCOPE_SYSTEM",
           re.compile(r'__HIP_MEMORY_SCOPE_(?!SYSTEM)\w+')))


def check_primitive(path):
    with open(path) as fh:
        text = fh.read()
    found = {n: re.findall(BODY % n, text, re.S | re.M)
             for n in ("het_rdv_device", "het_rdv_host", "het_rdv_jitter")}
    bad = ["het_rdv.h carries no %s body" % n for n, b in found.items() if not b]
    for name, bodies in found.items():
        for body in bodies:
            for tok in sorted(set(FORBIDDEN.findall(body.lower()))):
                bad.append("%s carries %r" % (name, tok))
            if name == "het_rdv_jitter":
                if not EMPTY_ASM.search(body):
                    bad.append("het_rdv_jitter does not spin on an empty asm template")
            elif len(RELAXED.findall(body)) < 2:
                bad.append("%s spells %d relaxed order(s), not the arrival and "
                           "the poll" % (name, len(RELAXED.findall(body))))
    covered = set()
    for body in found["het_rdv_device"]:
        mine = [s for s, _ in SCOPES if s in body]
        covered.update(mine)
        if not mine:
            bad.append("a het_rdv_device body names no system scope")
        for _, narrower in SCOPES:
            for tok in sorted(set(narrower.findall(body))):
                bad.append("het_rdv_device names %s, narrower than system" % tok)
    bad += ["no het_rdv_device body names %s" % s
            for s, _ in SCOPES if s not in covered]
    return bad


def main():
    if not os.access(ptx.LITMUS7, os.X_OK):
        raise SystemExit("rdvcheck: litmus7 not built (run 'make all')")
    bad, hdr = [], None
    tmp = tempfile.mkdtemp(prefix="rdvcheck.")
    try:
        for target, corpus, test in REPS:
            render, _ = ptx.emit_harness(os.path.join(corpus, test + ".litmus"),
                                         tmp, target)
            with open(render) as fh:
                text = fh.read()
            print("placement: %s spells %s" % (os.path.basename(render),
                                              "".join(c for c, _, _ in events(text))))
            bad += check_placement(os.path.basename(render), text)
            hdr = hdr or os.path.join(os.path.dirname(render), "het_rdv.h")
        print("primitive: het_rdv.h as staged beside %s" % REPS[0][2])
        bad += check_primitive(hdr)
    except (RuntimeError, OSError) as e:
        print("RDVCHECK: ERROR: %s" % e)
        return 2
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for m in bad:
        print("  FAIL: %s" % m)
    print("RDVCHECK: %s" % ("PASS" if not bad else "FAIL (%d)" % len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
