#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# cpustresscheck.py  --  HetLitmus CPU + interconnect stress LIVENESS gate
#                        (sibling of stresscheck.py, which does the same job for
#                         the GPU scratchpad layer)
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# Every other gate in this suite is STRUCTURAL: it asks "does the emitted code have
# the right shape?".  None of them can see whether a mechanism does any work at run
# time, and that hole has already swallowed mechanisms that compiled, passed every
# gate, and did nothing.
#
# The CPU + interconnect layer is invisible to ptxcheck and stresscheck alike:
#
#   * the M3 preload emits host cache hints -- no order, no scope, not a model op;
#   * the CPU enemies hammer a private host scratchpad -- they never enter the PTX
#     at all, because they are not GPU code;
#   * the C2C noise streams a disjoint buffer with plain 64-bit loads.
#
# So that layer is UNGUARDED unless this file exists.  It asks the two questions
# the structural gates cannot:
#
#     1. did the mechanisms survive the OPTIMISER?   (static, on the COMPILED asm)
#     2. do they actually DO anything at run time?   (dynamic, both ways)
#
# Spec: env-research/Q6-cpu-interconnect-stress.md and impl-briefs/B5-impl-brief.md.
#
# ---------------------------------------------------------------------------
# WHAT IT ASSERTS
#
# STATIC (reads the compiled -O2 assembly, never the source: source text survives
# an optimisation that removes the mechanism it describes):
#
#   S1  AArch64 (the GH200 host ISA, via `clang --target=aarch64-linux-gnu -O2 -S'):
#       the M3 primitives are PRESENT -- dc civac, prfm pldl1keep, prfm pstl1keep.
#   S2  x86_64 (via `gcc -O2 -S'; the MI300A host ISA and this dev box):
#       clflush and prefetcht0 are PRESENT.
#   S3  het_cpu_enemy's LOOP SURVIVES -O2: its body still carries loads AND stores
#       (the scratchpad must be both read and written -- store traffic forces
#       ownership transfer and is the strong coherence stressor, S&D 3.3), and a
#       backward branch (it is still a loop, not a straight line).
#   S4  THE ACCESS SEQUENCE IS A RUNTIME VALUE.  het_cpu_enemy's memory-op count is
#       INVARIANT under -DHET_CPU_ENEMY_SEQ=0..3.  This is the sharp one: a
#       compile-time sigma lets the optimiser fold the switch to one branch and, if
#       that branch has no stores, delete the loop -- the same failure the GPU
#       stresser had.  Invariance IS the property "no autotuner config can silently
#       switch the CPU stress off".
#
# DYNAMIC (actually RUNS the layer on this host -- see the note on substrate below):
#
#   D1  ON:  enemy rounds > 0, enemy accesses > 0, preload hints > 0, noise rounds > 0.
#   D2  OFF: with the enemies at 0, the preload at 0% and the noise off, ALL of the
#       above are EXACTLY ZERO.
#
#   D1 without D2 is worthless: a counter that reads nonzero because it is wired to
#   something unconditional proves nothing about the mechanism.  The pair is the
#   proof.
#
# GPU NOISE (needs nvcc; skipped without it):
#
#   G1  the Hopper noise blocks SURVIVE nvcc: the emitted PTX carries volatile
#       64-bit global loads.
#   G2  that count is INVARIANT under -DHET_NOISE_GPU_BLOCKS, because the block
#       count reaches the kernel as a RUNTIME argument.  A compile-time one would
#       let nvcc delete the noise for a config the autotuner might well pick.
#
# ---------------------------------------------------------------------------
# ON RUNNING THINGS ON THE DEV BOX
#
# The dev box (RTX 3060 / WSL2 / x86) is the WRONG SUBSTRATE for the science: it
# has no CPU-GPU coherence, no ATS and no C2C, so no memory-model result may ever
# be read off it.  The dynamic checks here are NOT memory-model results.  They are
# PLUMBING probes: they run the CPU stress layer's own code on the host CPU and ask
# whether its counters move -- which is what the shared charge permits for
# plumbing/ABI, and the only way to prove a mechanism live both ways before
# hardware.  The x86 path is genuinely exercised (clflush / prefetcht0 really run);
# the AArch64 path is checked statically, in its compiled asm.
#
# Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
# ---------------------------------------------------------------------------

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))       # herdtools7
LITMUS7 = os.path.join(REPO, "_build", "install", "default", "bin", "litmus7")
LIBDIR = os.path.join(REPO, "litmus", "libdir")
NVCC = shutil.which("nvcc") or "/usr/local/cuda/bin/nvcc"

AARCH64_TRIPLE = "aarch64-linux-gnu"
SEQS = (0, 1, 2, 3)

# The M3 cache primitives, per ISA.  These are litmus7's own (libdir/_aarch64/
# _cache.h, libdir/_x86_64/_cache.h) and they are the whole of the preload
# incantation -- if they are not in the object, M3 is inert.
AARCH64_PRIMS = {
    "dc civac":       re.compile(r"\bdc\s+civac\b"),
    "prfm pldl1keep": re.compile(r"\bprfm\s+pldl1keep\b"),
    "prfm pstl1keep": re.compile(r"\bprfm\s+pstl1keep\b"),
}
X86_PRIMS = {
    "clflush":    re.compile(r"\bclflush\b"),
    "prefetcht0": re.compile(r"\bprefetcht0\b"),
}

# ---------------------------------------------------------------------------
# AArch64 memory ops inside het_cpu_enemy.
#
# SCOPE THE GREP: count LOADS INTO THE ZERO REGISTER (`ldr xzr, [...]'), never
# every `ldr'.  The enemy's read patterns are `(void)*l' -- a load whose value is
# discarded.  With `volatile' the compiler must perform it and lowers it to a load
# into the zero register; without `volatile' the load is provably useless and is
# deleted outright, so sigma 3 (ld;ld) becomes a complete no-op, sigma 1 and 2 lose
# their read half, and sigma 0's `*l = i; *l = i+1;' collapses into a single store.
# The loop still exists, so a naive "is there a loop with a load and a store?"
# check waves it through; and a count of ALL `ldr' stays comfortably nonzero from
# the a->scratch / a->idx / a->nidx argument-struct loads alone.  Counting
# discarded loads tests the property directly: zero of them means the read side of
# every access pattern was optimised away.  (Measured before/after in
# hetlitmus/docs/verify-l0.md, "CPU-side stress liveness".)
# ---------------------------------------------------------------------------
A64_DISCARD_LOAD = re.compile(r"^\s+ldr\s+(xzr|wzr)\s*,")
A64_STORE = re.compile(r"^\s+str\b")

# A BACK edge, not any branch.  Counting every `b*' to any `.LBB' label counted
# forward branches too -- the `switch (a->seq)' arms alone supply several -- so
# the "still a loop" test could not fail on a straight-line body, which is
# precisely the shape it exists to reject.  Direction is decided the way
# obscheck._loops decides it: the branch target must be a label DEFINED EARLIER
# in the same function body.
A64_LABEL_DEF = re.compile(r"^(\.[\w$.]+):")
# `b .L', `b.ne .L', `cbz w8, .L', `tbnz w8, #0, .L' -- the target is the LAST
# operand, so everything before the final comma is skipped.
A64_BRANCH = re.compile(r"^\s+(b|b\.[a-z]+|cbn?z|tbn?z)\s+(?:.*,\s*)?(\.[\w$.]+)$")

# The four sigma branches declare 4 scratchpad stores between them (st;st = 2,
# st;ld = 1, ld;st = 1, ld;ld = 0).  A non-volatile build collapses the double store
# and lands well under this.
MIN_ENEMY_STORES = 4

# ---------------------------------------------------------------------------
# The DYNAMIC probe.  Compiled against the harness's OWN emitted het_cpu_stress.h,
# so it always tests the shipped header rather than a copy that could drift.
#
# It may include <pthread.h> even though het_cpu_stress.h may not: the probe is
# only ever built for the NATIVE host, whereas the header is also cross-assembled
# for AArch64, where x86 glibc's <pthread.h> does not compile.
# ---------------------------------------------------------------------------
PROBE_C = r"""
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#define HET_CPU_STRESS_IMPL
#include "het_cpu_stress.h"

#define PROBE_WORDS (1u << 16)
#define PROBE_ENEMIES 2
#define PROBE_NOISE_BYTES (256ull * 1024ull * 1024ull)   /* 256 MiB */

/* resident set size, in KB (/proc/self/statm field 2 = resident pages) */
static long probe_rss_kb(void) {
  FILE* f = fopen("/proc/self/statm", "r");
  long total, res;
  if (!f) return -1;
  if (fscanf(f, "%ld %ld", &total, &res) != 2) res = -1;
  fclose(f);
  return (res < 0) ? -1 : res * (sysconf(_SC_PAGESIZE) / 1024);
}

int main(int argc, char** argv) {
  int on = (argc > 1 && argv[1][0] == '1');
  int nEnemy = on ? PROBE_ENEMIES : 0;
  int pct    = on ? 100 : 0;
  int noise  = on ? 1 : 0;

  het_cpu_tally t;
  memset(&t, 0, sizeof t);
  int go = 0;

  uint32_t nreg = PROBE_WORDS / HET_CPU_STRIDE;
  uint32_t spread = (HET_CPU_SPREAD < nreg) ? (uint32_t)HET_CPU_SPREAD : nreg;
  uint64_t* scratch = (uint64_t*)calloc(PROBE_WORDS, sizeof(uint64_t));
  uint32_t* idx = (uint32_t*)malloc(nreg * sizeof(uint32_t));
  uint64_t* nbuf = (uint64_t*)calloc(PROBE_WORDS, sizeof(uint64_t));
  if (!scratch || !idx || !nbuf) return 3;
  srand(1);
  het_cpu_shuffle(idx, nreg);

  het_cpu_enemy_args ea[PROBE_ENEMIES];
  pthread_t eth[PROBE_ENEMIES];
  het_cpu_noise_args na;
  pthread_t nth;

  /* Raise the flag BEFORE spawning -- the emitted driver does the same, and the
     opposite order is one of the ways an enemy population never runs. */
  __atomic_store_n(&go, 1, __ATOMIC_RELAXED);
  for (int e = 0; e < nEnemy; e++) {
    ea[e].scratch = scratch;
    ea[e].idx     = idx;
    ea[e].nidx    = spread;
    ea[e].stride  = (uint32_t)HET_CPU_STRIDE;
    ea[e].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;
    ea[e].core    = -1;   /* the probe does NOT pin: a CI cgroup may forbid it, and
                             a refused pin would count an aff_failure that says
                             nothing about liveness.  Affinity is checked statically. */
    ea[e].go      = &go;
    ea[e].tally   = &t;
    pthread_create(&eth[e], NULL, het_cpu_enemy, &ea[e]);
  }
  if (noise) {
    na.buf    = (volatile const uint64_t*)nbuf;
    na.words  = PROBE_WORDS;
    na.chunk  = 256;
    na.stride = 1;
    na.core   = -1;
    na.go     = &go;
    na.tally  = &t;
    pthread_create(&nth, NULL, het_cpu_noise, &na);
  }

  /* M3, driven exactly as cpu_thread_P<n> drives it: on this thread's own test
     variables, before the (absent) tested body, accumulated locally, flushed once. */
  {
    uint64_t x = 0, y = 0;
    void* const pl[2] = { (void*)&x, (void*)&y };
    uint32_t rng = het_cpu_rng_init(1u, 0u);
    uint64_t ops = 0;
    for (int i = 0; i < 10000; i++) ops += het_cpu_preload(pl, 2, &rng, pct);
    __atomic_fetch_add(&t.preload_ops, ops, __ATOMIC_RELAXED);
  }

  struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = 50L * 1000L * 1000L;  /* 50 ms */
  nanosleep(&ts, NULL);

  __atomic_store_n(&go, 0, __ATOMIC_RELAXED);
  for (int e = 0; e < nEnemy; e++) pthread_join(eth[e], NULL);
  if (noise) pthread_join(nth, NULL);

  /* ---- FIRST-TOUCH: the hazard, and the fix, both measured -----------------
     An untouched malloc'd buffer is backed by a single shared ZERO PAGE, so a noise
     buffer that is never written stresses NOTHING however large it is -- every read
     hits one cache line and is served from L1.  Prove BOTH halves on this host:
     (a) merely READING the buffer leaves it unbacked (the hazard is real), and
     (b) het_cpu_first_touch actually faults the pages in (the fix works).
     RSS is the witness. */
  {
    volatile uint64_t* nb2 = (volatile uint64_t*)malloc(PROBE_NOISE_BYTES);
    long r0 = probe_rss_kb(), r1 = -1, r2 = -1;
    unsigned long long a2 = 0;
    if (nb2) {
      for (size_t i = 0; i < PROBE_NOISE_BYTES / 8; i += 8) a2 += nb2[i];
      r1 = probe_rss_kb();
      het_cpu_first_touch((void*)nb2, PROBE_NOISE_BYTES);
      r2 = probe_rss_kb();
      free((void*)nb2);
    }
    printf("ft_bytes=%llu ft_rss_after_read=%ld ft_rss_after_touch=%ld ft_sink=%llu\n",
           (unsigned long long)PROBE_NOISE_BYTES,
           (r1 >= 0 && r0 >= 0) ? (r1 - r0) : -1,
           (r2 >= 0 && r1 >= 0) ? (r2 - r1) : -1,
           a2);
  }

  printf("enemy_rounds=%llu enemy_accesses=%llu preload_ops=%llu "
         "noise_rounds=%llu noise_words=%llu enemies=%u preload_live=%d\n",
         (unsigned long long)t.enemy_rounds,
         (unsigned long long)t.enemy_accesses,
         (unsigned long long)t.preload_ops,
         (unsigned long long)t.noise_cpu_rounds,
         (unsigned long long)t.noise_cpu_words,
         t.enemies_realised,
         (int)HET_CPU_PRELOAD_LIVE);
  free(scratch); free(idx); free(nbuf);
  return 0;
}
"""


# The CPU-preload liveness guard, exercised against the REAL het_dead() and
# HET_REQ_CPU_PRELOAD from het_verdict.h.  It emulates the emitted driver's two
# lines under test -- the preload_inert WRITE and the stress_requested TERM -- for
# both HET_CPU_PRELOAD_LIVE values, and for the guarded form (preload_inert = !live)
# as well as the unguarded one (the field never written, so 0), so the contrast is
# never vacuous.  It runs the preprocessor-independent LOGIC with a runtime `live';
# check() P1 separately pins the emitted driver to the `het_cpu_preload_live()'
# write, so `live' tracks the macro.
PRELOAD_INERT_TU = r"""
#include <stdint.h>
#include <stdio.h>
#include "het_verdict.h"   /* HET_REQ_CPU_PRELOAD, het_dead(); self-includes its deps */

/* the emitted stress_requested preload term (hetEmit.ml):
     (HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) ? HET_REQ_CPU_PRELOAD : 0u */
static uint32_t preload_req(int preload_inert, int pct) {
  return (pct > 0 && !preload_inert) ? HET_REQ_CPU_PRELOAD : 0u;
}

int main(void) {
  int pct = 50;   /* HET_CPU_PRELOAD_PCT > 0 */
  for (int live = 0; live <= 1; live++) {
    uint32_t fix_req = preload_req(!live, pct);   /* F10: preload_inert = !live      */
    uint32_t old_req = preload_req(0, pct);       /* the bug: field never written    */
    int fix_dead = het_dead(fix_req, HET_REQ_CPU_PRELOAD, 0);   /* preload_ops == 0  */
    int old_dead = het_dead(old_req, HET_REQ_CPU_PRELOAD, 0);
    printf("fix_req_live%d=%d fix_dead_live%d=%d old_req_live%d=%d old_dead_live%d=%d\n",
           live, !!(fix_req & HET_REQ_CPU_PRELOAD), live, fix_dead,
           live, !!(old_req & HET_REQ_CPU_PRELOAD), live, old_dead);
  }
  return 0;
}
"""


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, **kw)


def harness_paths(d, name):
    cpu_c = os.path.join(d, name + "_cpu.c")
    cu = os.path.join(d, name + ".cu")
    hdr = os.path.join(d, "het_cpu_stress.h")
    for p in (cpu_c, cu, hdr):
        if not os.path.exists(p):
            raise RuntimeError("no %s in the harness dir" % p)
    return d, cpu_c, cu, hdr


def emit_harness(litmus_path, outdir, harness_dir=None):
    """Emit the harness -- or, when [harness_dir] is given, check the one already
    sitting there.

    The second mode exists so this checker can be BITTEN.  Without it a negative
    control cannot exist at all: the checker re-emits from source on every run, so
    a mutation has nothing to land on and the gate itself would be untestable --
    and this is the one gate able to catch a regression that preserves the source
    text while killing the compiled mechanism.
    See l0_tokens.sh selftest section [8]. """
    name = os.path.splitext(os.path.basename(litmus_path))[0]
    if harness_dir:
        return harness_paths(harness_dir, name)
    r = run([LITMUS7, "-set-libdir", LIBDIR, "-o", outdir,
             os.path.abspath(litmus_path)])
    if r.returncode != 0:
        raise RuntimeError("litmus7 failed:\n" + r.stdout)
    return harness_paths(os.path.join(outdir, name), name)


def asm_of(cpu_c, cross, extra=()):
    """Compile <test>_cpu.c to -O2 assembly and return it.  We read the COMPILED
    output, never the source: the whole point is what survived the optimiser."""
    cc = ["clang", "--target=" + AARCH64_TRIPLE] if cross else ["gcc"]
    cmd = cc + ["-std=gnu11", "-O2", "-S"] + list(extra) + \
        [os.path.basename(cpu_c), "-o", "-"]
    r = run(cmd, cwd=os.path.dirname(os.path.abspath(cpu_c)))
    if r.returncode != 0:
        raise RuntimeError("%s failed:\n%s" % (" ".join(cc), r.stdout))
    return r.stdout


def enemy_body(asm_text):
    """The assembly of het_cpu_enemy only (so a load elsewhere in the file cannot
    make a deleted enemy loop look alive)."""
    lines = asm_text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^het_cpu_enemy:", ln):
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        if re.match(r"^\s*\.size\s+het_cpu_enemy", lines[j]):
            return lines[start:j]
        # a following global label ends the body on toolchains without .size
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", lines[j]) and \
           not lines[j].startswith(".L"):
            return lines[start:j]
    return lines[start:]


def count_traffic_loops(body):
    """Back edges in `body' that ENCLOSE scratchpad traffic.

    Two refinements over "is there a branch", each one measured on a straight-line
    enemy built for the purpose:

      DIRECTION  the target label must be defined EARLIER in the body.  Counting
                 every `b*' to any `.LBB' also counted forward branches, and the
                 four `switch (a->seq)' arms supply plenty: 16 of them survive in
                 a body with both loops removed, so the old test could not fail.
      CONTENT    an __atomic_fetch_add lowers to an ldxr/stxr RETRY loop, which is
                 a genuine back edge and is still there when the stress loops are
                 gone (4 of them, from the affinity and tally bumps).  So a back
                 edge counts only if the traffic it is supposed to be repeating --
                 a discarded load or a scratchpad store -- lies inside it.

    Together: >=1 means the enemy's read/write traffic is inside a loop, which is
    the property S3 claims and the only one that distinguishes a stressor from a
    function that touches the scratchpad once."""
    label_idx = {}
    for i, ln in enumerate(body):
        m = A64_LABEL_DEF.match(ln.strip())
        if m:
            label_idx[m.group(1)] = i
    n = 0
    for j, ln in enumerate(body):
        m = A64_BRANCH.match(ln.split("//")[0].rstrip())
        if not m:
            continue
        i = label_idx.get(m.group(2))
        if i is None or i >= j:
            continue
        if any(A64_DISCARD_LOAD.match(body[k]) or A64_STORE.match(body[k])
               for k in range(i + 1, j + 1)):
            n += 1
    return n


def count_enemy_ops(asm_text):
    """(discarded loads, stores, traffic loops) in het_cpu_enemy's compiled body.

    `discarded loads' -- not "loads" -- is deliberate: see A64_DISCARD_LOAD; and
    `traffic loops' -- not "branches" -- likewise, see count_traffic_loops."""
    body = enemy_body(asm_text)
    if body is None:
        return None
    ld = sum(1 for ln in body if A64_DISCARD_LOAD.match(ln))
    st = sum(1 for ln in body if A64_STORE.match(ln))
    br = count_traffic_loops(body)
    return ld, st, br


def ptx_of(cu_path, flags, arch, tmp):
    out = os.path.join(tmp, "n.ptx")
    cmd = [NVCC, "-std=c++17", "-arch=" + arch, "--ptx"] + list(flags) + \
        ["-o", out, os.path.basename(cu_path)]
    r = run(cmd, cwd=os.path.dirname(os.path.abspath(cu_path)))
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError("nvcc --ptx failed (%s):\n%s" % (" ".join(flags), r.stdout))
    with open(out) as f:
        return f.read()


NOISE_OP = re.compile(r"^\s*ld\.volatile\.global\.u64\b")


def count_noise_ops(ptx_text):
    return sum(1 for ln in ptx_text.splitlines() if NOISE_OP.match(ln))


def check(litmus_path, arch="sm_90", harness_dir=None):
    lines, ok = [], [True]

    def fail(msg):
        ok[0] = False
        lines.append("FAIL: " + msg)

    def note(msg):
        lines.append(msg)

    name = os.path.basename(litmus_path)
    note("=== cpu+interconnect stress liveness: %s ===" % name)

    tmp = tempfile.mkdtemp(prefix="cpustresscheck_")
    try:
        d, cpu_c, cu, hdr = emit_harness(litmus_path, tmp, harness_dir)

        # Never pass vacuously on a harness with no CPU stress layer at all.
        with open(cu) as f:
            cu_src = f.read()
        if "het_cpu_preload" not in cu_src or "het_cpu_enemy" not in cu_src:
            fail("%s carries NO CPU stress layer (no het_cpu_preload / het_cpu_enemy "
                 "call).  Per-device GPU stress alone does not widen the CROSS-device "
                 "window, which is where the het weak behaviour lives (Q6)." % name)
            return ok[0], lines

        # ---- S1: the M3 primitives survive -O2 on AArch64 (the GH200 host ISA) --
        a64 = asm_of(cpu_c, cross=True)
        for prim, rx in AARCH64_PRIMS.items():
            n = len(rx.findall(a64))
            if n < 1:
                fail("AArch64 -O2 asm carries NO `%s' -- the M3 preload incantation "
                     "is INERT on the GH200 host ISA.  litmus7's preload is exactly "
                     "these three primitives (libdir/_aarch64/_cache.h); without them "
                     "there is no cache stress on the CPU side at all." % prim)
        if ok[0]:
            note("  S1 AArch64 M3 primitives present in -O2 asm "
                 "(dc civac, prfm pldl1keep, prfm pstl1keep)")

        # ---- S2: and on x86_64 (the MI300A host ISA, and this dev box) ----------
        x86 = asm_of(cpu_c, cross=False)
        for prim, rx in X86_PRIMS.items():
            if len(rx.findall(x86)) < 1:
                fail("x86_64 -O2 asm carries NO `%s' -- the M3 preload is INERT on "
                     "the x86 host ISA (the MI300A host)." % prim)
        if ok[0]:
            note("  S2 x86_64 M3 primitives present in -O2 asm (clflush, prefetcht0)")

        # ---- S3: the enemy loop survived the optimiser --------------------------
        got = count_enemy_ops(a64)
        if got is None:
            fail("het_cpu_enemy is not in the compiled AArch64 object at all")
            return ok[0], lines
        ld, st, br = got
        if ld < 1:
            fail("het_cpu_enemy's -O2 body performs NO discarded load (no `ldr xzr'): "
                 "the READ side of every access pattern was optimised away.  The "
                 "enemy's reads are `(void)*l', which the compiler must perform only "
                 "if the pointer is `volatile'; without it sigma 3 (ld;ld) becomes a "
                 "complete no-op and sigma 1/2 lose their read half.  The loop may "
                 "still be there -- it is not issuing the traffic it claims to.  "
                 "Restore `volatile' on het_cpu_enemy_args.scratch and on the local "
                 "pointer.")
        if st < MIN_ENEMY_STORES:
            fail("het_cpu_enemy's -O2 body carries only %d store(s), expected at least "
                 "%d (the four sigma branches declare 2+1+1+0 scratchpad stores).  A "
                 "non-volatile scratchpad lets the compiler collapse sigma 0's "
                 "`*l = i; *l = i+1;' into ONE store.  The scratchpad must be both READ "
                 "and WRITTEN: store traffic invalidates lines and forces ownership "
                 "transfer, which is the strong coherence stressor (S&D 3.3)."
                 % (st, MIN_ENEMY_STORES))
        if br < 1:
            fail("het_cpu_enemy's -O2 body has NO back edge around its scratchpad "
                 "traffic: the loads and stores are there, but nothing repeats them, "
                 "so the body runs once.  An enemy that touches the scratchpad once "
                 "is not a stressor.")
        if ok[0]:
            note("  S3 het_cpu_enemy survives -O2 (%d discarded load(s) + %d store(s), "
                 "%d traffic loop(s): still a loop, and still issuing BOTH the read and the "
                 "write traffic every sigma branch declares)" % (ld, st, br))

        # ---- S4: sigma is a RUNTIME value (the B4 bug, on the CPU side) ---------
        per_seq = {}
        for q in SEQS:
            a = asm_of(cpu_c, cross=True, extra=["-DHET_CPU_ENEMY_SEQ=%d" % q])
            per_seq[q] = count_enemy_ops(a)
        distinct = {per_seq[q] for q in SEQS}
        if len(distinct) != 1:
            fail("het_cpu_enemy's op count MOVES with -DHET_CPU_ENEMY_SEQ %s.  The "
                 "access sequence is reaching the enemy as a COMPILE-TIME constant, "
                 "so the optimiser can fold the switch to one branch -- and if that "
                 "branch has no stores, delete the loop.  That is B4's bug, on the CPU "
                 "side.  sigma must arrive in het_cpu_enemy_args as a RUNTIME field."
                 % {q: per_seq[q] for q in SEQS})
        else:
            note("  S4 sigma is a RUNTIME value: het_cpu_enemy's op count is INVARIANT "
                 "over -DHET_CPU_ENEMY_SEQ=0..3 (%d ld + %d st)"
                 % (per_seq[0][0], per_seq[0][1]))

        # ---- S5/S6: the DRIVER's two stress invariants --------------------------
        # S1-S4 and D1-D3 all exercise het_cpu_stress.h -- the header -- because the
        # dynamic probe compiles its OWN main() against it.  These two look at the
        # emitted <test>.cu DRIVER, where the remaining ways to silently destroy the
        # CPU/interconnect layer live: give the noise a buffer that fits in cache, or
        # point the enemies at the locations under test.  Both leave every other
        # check green.  (cu_src was read above, and nothing rewrites the .cu.)

        # S5: the noise WORKING SET decides whether the C2C noise crosses anything
        # at all.  Below the last-level cache (Grace L3 = 114 MB) the buffer is
        # served from cache and generates NO interconnect traffic, so a config that
        # "scored well" at 8 MB scored a stressor that was not running.  The
        # allocation must therefore DERIVE from HET_NOISE_MB (so the autotuner and
        # het_obs_record's noise_ws_mb describe the buffer really allocated), and
        # the below-LLC guard must still be there.
        m = re.search(r"_noise_words\s*=\s*([^;]+);", cu_src)
        if not m:
            fail("S5: the driver does not compute _noise_words at all -- the C2C "
                 "noise buffer is not sized by anything.")
        elif "HET_NOISE_MB" not in m.group(1):
            fail("S5: the C2C noise working set is NOT derived from HET_NOISE_MB "
                 "(_noise_words = %s).  A hard-coded buffer silently decouples the "
                 "noise from the knob B8 tunes and from noise_ws_mb in the record, "
                 "and a buffer below the LLC (%s) is served from cache and stresses "
                 "NOTHING while every counter still moves."
                 % (m.group(1).strip(), "Grace L3 = 114 MB"))
        elif "HET_LLC_MB" not in cu_src:
            fail("S5: the below-last-level-cache guard is gone.  A noise buffer that "
                 "fits in cache generates no interconnect traffic, and nothing else "
                 "in the run would say so.")
        else:
            note("  S5 the C2C noise working set derives from HET_NOISE_MB and the "
                 "below-LLC guard is present (a cache-resident buffer stresses nothing)")

        # S6: THE DISJOINT-SCRATCHPAD INVARIANT (S&D PLDI'16 3.3).  The enemies must
        # hammer a PRIVATE buffer.  An enemy pointed at a tested location does not
        # merely add noise -- it writes the variable under test, so it can MANUFACTURE
        # the very weak behaviour we are trying to observe, or destroy it.  That is
        # not a weaker experiment, it is a fabricated one.
        scratch_assigns = re.findall(r"\.scratch\s*=\s*([A-Za-z_]\w*)", cu_src)
        if not scratch_assigns:
            fail("S6: no enemy .scratch assignment found in the driver -- the enemies "
                 "have no scratchpad.")
        elif any(v != "_cpu_scratch" for v in scratch_assigns):
            fail("S6: an enemy scratchpad is assigned from %s, not the private "
                 "_cpu_scratch.  The enemies must hammer a buffer DISJOINT from the "
                 "test variables (S&D PLDI'16 3.3): an enemy writing a tested "
                 "location can manufacture or destroy the weak behaviour outright."
                 % sorted({v for v in scratch_assigns if v != "_cpu_scratch"}))
        else:
            note("  S6 the enemy scratchpad is the private _cpu_scratch, disjoint "
                 "from every test variable (%d enemy arg(s))" % len(scratch_assigns))

        # ---- D1/D2: the layer actually runs, and stops when switched off --------
        probe_c = os.path.join(d, "_probe.c")
        with open(probe_c, "w") as f:
            f.write(PROBE_C)
        probe_bin = os.path.join(d, "_probe")
        r = run(["gcc", "-std=gnu11", "-O2", "-pthread",
                 os.path.basename(probe_c), "-o", os.path.basename(probe_bin)],
                cwd=d)
        if r.returncode != 0:
            fail("could not build the liveness probe:\n" + r.stdout)
            return ok[0], lines

        def probe(on):
            r = run([probe_bin, "1" if on else "0"], cwd=d)
            if r.returncode != 0:
                raise RuntimeError("probe failed:\n" + r.stdout)
            out = {}
            for line in r.stdout.strip().splitlines():
                out.update(dict(kv.split("=") for kv in line.split()))
            return out

        on = probe(True)
        off = probe(False)

        # ---- D3: the noise buffer is REAL MEMORY, not the shared zero page -----
        # An unwritten malloc'd buffer is backed by ONE shared zero page, so a noise
        # thread reading it crosses nothing however large it is -- see the
        # het_cpu_first_touch declaration in het_cpu_stress.h for why.  gd_alloc_noise
        # therefore calls het_cpu_first_touch, and this asserts BOTH halves through
        # RSS: reading alone must NOT back the pages (so the hazard is real on this
        # host, and the check is not vacuous), and first-touching must back
        # essentially all of them (so the fix works).
        ft_bytes = int(on["ft_bytes"])
        ft_read = int(on["ft_rss_after_read"])
        ft_touch = int(on["ft_rss_after_touch"])
        want_kb = ft_bytes // 1024
        if ft_read < 0 or ft_touch < 0:
            note("  D3 SKIPPED (no /proc/self/statm on this host)")
        elif ft_touch < (want_kb * 9) // 10:
            fail("D3: het_cpu_first_touch grew RSS by only %d KB for a %d KB buffer.  "
                 "It is NOT faulting the pages in, so a noise buffer stays on the "
                 "shared zero page -- one physical cache line, served from L1, "
                 "generating NO interconnect traffic however large the buffer is."
                 % (ft_touch, want_kb))
        elif ft_read > want_kb // 10:
            note("  D3 first-touch works (RSS +%d KB / %d KB), though on this host "
                 "reading alone already backed %d KB -- the zero-page hazard may be "
                 "absent (huge pages? pre-faulted allocator?).  The fix is still "
                 "correct and required on Linux/GH200." % (ft_touch, want_kb, ft_read))
        else:
            note("  D3 the noise buffer is REAL memory: reading %d KB of it backs only "
                 "%d KB (the shared zero page -- the hazard is real on this host), "
                 "while het_cpu_first_touch backs %d KB.  Without it the C2C noise "
                 "would stream ONE cache line out of L1 and stress nothing."
                 % (want_kb, ft_read, ft_touch))

        live = ("enemy_rounds", "enemy_accesses", "preload_ops", "noise_rounds")
        for k in live:
            if int(on[k]) <= 0:
                fail("D1: with the CPU stress ON, %s is %s.  The mechanism compiled, "
                     "linked, and did NOTHING at run time -- which is precisely what "
                     "B4 shipped through five green gates." % (k, on[k]))
        for k in live:
            if int(off[k]) != 0:
                fail("D2: with the CPU stress OFF, %s is %s, not 0.  The counter is "
                     "wired to something unconditional, so its nonzero value under D1 "
                     "proves nothing about the mechanism.  A tally that cannot go to "
                     "zero is not evidence of liveness." % (k, off[k]))
        if int(on.get("preload_live", "0")) != 1:
            fail("D1: HET_CPU_PRELOAD_LIVE is 0 on this host -- the M3 incantation "
                 "has no cache primitives here and is a no-op.")
        if ok[0]:
            note("  D1 LIVE when on : enemy_rounds=%s accesses=%s preload_hints=%s "
                 "noise_rounds=%s (enemies realised: %s)"
                 % (on["enemy_rounds"], on["enemy_accesses"], on["preload_ops"],
                    on["noise_rounds"], on["enemies"]))
            note("  D2 ZERO when off: enemy_rounds=%s accesses=%s preload_hints=%s "
                 "noise_rounds=%s  <- this half is what makes D1 mean anything"
                 % (off["enemy_rounds"], off["enemy_accesses"], off["preload_ops"],
                    off["noise_rounds"]))

        # ---- G1/G2: the Hopper noise blocks survive nvcc ------------------------
        if not os.path.exists(NVCC):
            note("  G1/G2 SKIPPED (no nvcc): the GPU noise is unchecked here")
        else:
            n_on = count_noise_ops(ptx_of(cu, [], arch, tmp))
            if n_on < 1:
                fail("G1: the emitted PTX carries NO volatile 64-bit global load -- "
                     "nvcc DELETED the Hopper noise stream.  Its accumulator must be "
                     "kept alive (volatile reads + a sink), or the interconnect "
                     "stressor is not there at all.  B4's stress loop died this way.")
            else:
                note("  G1 the Hopper noise survives nvcc (%d volatile 64-bit global "
                     "load(s) in the PTX)" % n_on)
            counts = {b: count_noise_ops(ptx_of(cu, ["-DHET_NOISE_GPU_BLOCKS=%d" % b],
                                                arch, tmp))
                      for b in (0, 4, 16)}
            if len({n_on, *counts.values()}) != 1:
                fail("G2: the noise-op count MOVES with -DHET_NOISE_GPU_BLOCKS (%s vs "
                     "%d by default).  The block count is reaching the kernel as a "
                     "COMPILE-TIME constant, so nvcc can delete the noise entirely for "
                     "a config the autotuner may well pick.  It must be a RUNTIME "
                     "kernel argument." % (counts, n_on))
            else:
                note("  G2 the noise block count is a RUNTIME argument: the PTX op "
                     "count is INVARIANT over -DHET_NOISE_GPU_BLOCKS=0/4/16")

        # ---- P1/P2: the CPU-preload liveness guard is a LIVE field (DR1) --------
        # preload_inert is read by stress_requested (`!_ct.preload_inert').  Left
        # unwritten it stays memset-0 (= live) even on a host with NO cache
        # primitives (HET_CPU_PRELOAD_LIVE==0), where het_cpu_preload issues zero
        # hints: HET_REQ_CPU_PRELOAD would then be raised for a mechanism that
        # cannot run, het_dead() would fire, and every null would go COLD-INVALID.
        # P1 (structural): the emitted driver WRITES the field, read from the
        # artifact.  It calls het_cpu_preload_live() rather than naming
        # HET_CPU_PRELOAD_LIVE, which is host-only (#ifdef HET_CPU_STRESS_IMPL) and
        # so undefined in the .cu that nvcc parses.
        if "_ct.preload_inert = !het_cpu_preload_live();" not in cu_src:
            fail("P1: the emitted driver does NOT write `_ct.preload_inert = "
                 "!het_cpu_preload_live();' -- the F10 guard field is dead again; on a "
                 "no-primitive host the preload request is raised for a mechanism that "
                 "issues zero hints and every null goes COLD-INVALID.")
        else:
            note("  P1 the driver writes _ct.preload_inert = !het_cpu_preload_live()")
        # P2 (behavioural): the request is DROPPED when LIVE=0 and HET_DQ_CPU_PRELOAD_
        # DEAD does not false-fire -- proved against the REAL het_dead() /
        # HET_REQ_CPU_PRELOAD, for the guarded form (preload_inert = !live) AND, as
        # the non-vacuous contrast, the unwritten field (0) that still false-COLDs a
        # host with no cache primitives.
        p2c = os.path.join(tmp, "preload_inert.c")
        with open(p2c, "w") as fh:
            fh.write(PRELOAD_INERT_TU)
        rb = run(["gcc", "-std=gnu11", "-O2", "-I", d, os.path.basename(p2c),
                  "-o", "preload_inert", "-lm"], cwd=tmp)
        if rb.returncode != 0:
            fail("P2: the preload-inert probe did not compile:\n" + rb.stdout)
        else:
            rr = run([os.path.join(tmp, "preload_inert")], cwd=tmp)
            res = dict(kv.split("=") for kv in rr.stdout.split())
            if res.get("fix_req_live1") != "1":
                fail("P2: with HET_CPU_PRELOAD_LIVE=1 the preload request is NOT raised "
                     "(fix_req_live1=%s) -- the live path regressed."
                     % res.get("fix_req_live1"))
            elif res.get("fix_req_live0") != "0" or res.get("fix_dead_live0") != "0":
                fail("P2: with HET_CPU_PRELOAD_LIVE=0 the request is still raised "
                     "(fix_req_live0=%s) or het_dead still fires (fix_dead_live0=%s) -- "
                     "the F10 guard does not drop the dead mechanism, so a no-primitive "
                     "host false-COLDs every null."
                     % (res.get("fix_req_live0"), res.get("fix_dead_live0")))
            elif res.get("old_dead_live0") != "1":
                fail("P2: the OLD unwritten-preload_inert path does NOT false-fire "
                     "HET_DQ_CPU_PRELOAD_DEAD at LIVE=0 (old_dead_live0=%s) -- the "
                     "contrast is vacuous, so this check would pass even if the fix did "
                     "nothing." % res.get("old_dead_live0"))
            else:
                note("  P2 LIVE=1 -> request raised; LIVE=0 -> request DROPPED, "
                     "het_dead() silent (no false COLD); the OLD unwritten field would "
                     "have false-COLDed a dead host (het_dead=1) -- the fix bites")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return ok[0], lines


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("litmus", nargs="+")
    ap.add_argument("--arch", default="sm_90")
    ap.add_argument("--harness-dir", default=None,
                    help="check an ALREADY-emitted (possibly mutated) harness "
                         "dir instead of emitting a fresh one -- this is what "
                         "lets the gate be bitten (l0_tokens.sh selftest [8])")
    a = ap.parse_args()

    if not os.path.exists(LITMUS7):
        print("error: litmus7 not built (%s)" % LITMUS7, file=sys.stderr)
        return 2

    allok = True
    for p in a.litmus:
        try:
            ok, lines = check(p, arch=a.arch, harness_dir=a.harness_dir)
        except Exception as e:                                 # toolchain problems
            print("ERROR on %s: %s" % (p, e), file=sys.stderr)
            return 2
        for ln in lines:
            print(ln)
        print("RESULT: %s\n" % ("PASS" if ok else "FAIL"))
        allok = allok and ok
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
