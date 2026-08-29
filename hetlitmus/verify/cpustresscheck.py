#!/usr/bin/env python3
"""HetLitmus -- the CPU + interconnect stress-liveness gate, sibling of
stresscheck.py (hetlitmus/docs/faithfulness.md, "CPU-side stress liveness").
The cache preload, the CPU enemies and the interconnect noise reach no PTX, so a
miss here means a null was scored on a layer the optimiser removed or that never
ran.  Static, off the -O2 asm of each host ISA's own rendering of the rep:
preload-prims-aarch64, preload-prims-x86, enemy-loop, enemy-seq-runtime.  A rep
with no x86_64 rendering FAILS rather than skipping its arm.  Dynamic, on this
host:
stress-live, stress-off-zero, first-touch.  Structural, on the emitted driver:
preload-guard-field and preload-guard-term.

Exit 0 = PASS, 1 = FAIL, 2 = usage/toolchain error.
"""

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

# Each arm reads, through clang --target, a render of its OWN ISA: a <t>_cpu.c
# stops at an #error for any other, so the x86 arm takes HETX86_DIR's rendering.
AARCH64_TRIPLE = "aarch64-linux-gnu"
X86_TRIPLE = "x86_64-linux-gnu"
HETX86_DIR = os.path.join(REPO, "hetlitmus", "tests", "het-x86")
SEQS = (0, 1, 2, 3)

# The cache primitives, per ISA: litmus7's own (libdir/_<isa>/_cache.h) and the
# whole of the preload -- absent from the object, the preload is inert.
AARCH64_PRIMS = {
    "dc civac":       re.compile(r"\bdc\s+civac\b"),
    "prfm pldl1keep": re.compile(r"\bprfm\s+pldl1keep\b"),
    "prfm pstl1keep": re.compile(r"\bprfm\s+pstl1keep\b"),
}
X86_PRIMS = {
    "clflush":    re.compile(r"\bclflush\b"),
    "prefetcht0": re.compile(r"\bprefetcht0\b"),
}

# The enemy's discarded loads ONLY (`(void)*l' lowers to a zero-register load);
# every `ldr' stays nonzero from the argument struct (faithfulness.md).
A64_DISCARD_LOAD = re.compile(r"^\s+ldr\s+(xzr|wzr)\s*,")
A64_STORE = re.compile(r"^\s+str\b")

# A BACK edge, not any branch: the sigma arms supply forward branches of their
# own.  Direction = the target label is defined earlier in the same body.
A64_LABEL_DEF = re.compile(r"^(\.[\w$.]+):")
# `b .L', `b.ne .L', `cbz w8, .L', `tbnz w8, #0, .L': the target is the LAST
# operand, so everything before the final comma is skipped.
A64_BRANCH = re.compile(r"^\s+(b|b\.[a-z]+|cbn?z|tbn?z)\s+(?:.*,\s*)?(\.[\w$.]+)$")

# The four sigma branches declare 2+1+1+0 scratchpad stores between them; a
# non-volatile build lands under that (faithfulness.md, "CPU-side stress liveness").
MIN_ENEMY_STORES = 4

# The preload term of the emitted driver's stress_requested word
# (hetDriverMain.ml).
PRELOAD_REQ_TERM = ("((HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) "
                    "? HET_REQ_CPU_PRELOAD : 0u)")

# The dynamic probe, built against the harness's OWN emitted het_cpu_stress.h.  It
# may include <pthread.h>, which that header may not: this builds NATIVE only.
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
  het_cpu_shuffle(idx, nreg, 1u);

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
    ea[e].core    = -1;   /* the probe does NOT pin: a cgroup may forbid it, and a
                             refused pin says nothing about liveness */
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

  /* The preload, driven as cpu_thread_P<n> drives it: this thread's own test
     variables, before the (absent) tested body, accumulated locally. */
  {
    uint64_t x = 0, y = 0;
    void* const pl[2] = { (void*)&x, (void*)&y };
    uint64_t ops = 0;
    for (int i = 0; i < 10000; i++)
      ops += het_cpu_preload(pl, 2, 1u, HET_WHO_CPU(0), (uint64_t)i * 5u + 1u,
                             pct);
    __atomic_fetch_add(&t.preload_ops, ops, __ATOMIC_RELAXED);
  }

  struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = 50L * 1000L * 1000L;  /* 50 ms */
  nanosleep(&ts, NULL);

  __atomic_store_n(&go, 0, __ATOMIC_RELAXED);
  for (int e = 0; e < nEnemy; e++) pthread_join(eth[e], NULL);
  if (noise) pthread_join(nth, NULL);

  /* First-touch, both halves through RSS: reading the buffer leaves it on the
     shared ZERO page, het_cpu_first_touch faults it in (het_cpu_stress.h). */
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


def x86_rep_for(litmus_path):
    """The committed x86_64 rendering of this rep, whose _cpu.c the x86 arm reads."""
    name = os.path.splitext(os.path.basename(litmus_path))[0]
    return os.path.join(HETX86_DIR, name + "-x86_64.litmus")


def emit_harness(litmus_path, outdir):
    """litmus7-emit the harness; return its (dir, _cpu.c, .cu, het_cpu_stress.h)."""
    name = os.path.splitext(os.path.basename(litmus_path))[0]
    r = run([LITMUS7, "-gpu-target", "cuda", "-set-libdir", LIBDIR, "-o", outdir,
             os.path.abspath(litmus_path)])
    if r.returncode != 0:
        raise RuntimeError("litmus7 failed:\n" + r.stdout)
    return harness_paths(os.path.join(outdir, name), name)


def asm_of(cpu_c, triple, extra=()):
    """Compile <test>_cpu.c to -O2 assembly for [triple] and return it.  The
    COMPILED output is read, never the source: what survived the optimiser."""
    cc = ["clang", "--target=" + triple]
    cmd = cc + ["-std=gnu11", "-O2", "-S"] + list(extra) + \
        [os.path.basename(cpu_c), "-o", "-"]
    r = run(cmd, cwd=os.path.dirname(os.path.abspath(cpu_c)))
    if r.returncode != 0:
        raise RuntimeError("%s failed:\n%s" % (" ".join(cc), r.stdout))
    return r.stdout


def enemy_body(asm_text):
    """The assembly of het_cpu_enemy only: a load elsewhere in the file must not
    make a deleted enemy loop look alive."""
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
    """Back edges in `body' that ENCLOSE a discarded load or a scratchpad store;
    a body with both stress loops gone still carries branches of its own."""
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
    """(discarded loads, stores, traffic loops) in het_cpu_enemy's compiled body;
    see A64_DISCARD_LOAD and count_traffic_loops for what each counts."""
    body = enemy_body(asm_text)
    if body is None:
        return None
    ld = sum(1 for ln in body if A64_DISCARD_LOAD.match(ln))
    st = sum(1 for ln in body if A64_STORE.match(ln))
    br = count_traffic_loops(body)
    return ld, st, br


def check(litmus_path):
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
        d, cpu_c, cu, hdr = emit_harness(litmus_path, tmp)

        # Never pass vacuously on a harness with no CPU stress layer at all.
        with open(cu) as f:
            cu_src = f.read()
        if "het_cpu_preload" not in cu_src or "het_cpu_enemy" not in cu_src:
            fail("%s carries NO CPU stress layer (no het_cpu_preload / het_cpu_enemy "
                 "call): per-device stress alone does not widen the CROSS-device "
                 "window the het weak behaviour lives in." % name)
            return ok[0], lines

        # ---- preload-prims-aarch64: they survive -O2 on the AArch64 host ISA
        a64 = asm_of(cpu_c, AARCH64_TRIPLE)
        for prim, rx in AARCH64_PRIMS.items():
            n = len(rx.findall(a64))
            if n < 1:
                fail("preload-prims-aarch64: no `%s' in the -O2 asm -- litmus7's "
                     "cache preload is exactly these three primitives "
                     "(libdir/_aarch64/_cache.h), so it is INERT." % prim)
        if ok[0]:
            note("  preload-prims-aarch64: dc civac, prfm pldl1keep, prfm "
                 "pstl1keep all present in the -O2 asm")

        # ---- preload-prims-x86: and on the x86_64 host ISA -----------------
        x86_litmus = x86_rep_for(litmus_path)
        if not os.path.exists(x86_litmus):
            fail("preload-prims-x86: no %s, so this rep has no x86_64 rendering "
                 "whose _cpu.c an x86_64 compiler can read"
                 % os.path.relpath(x86_litmus, REPO))
            return ok[0], lines
        _, x86_cpu_c, _, _ = emit_harness(x86_litmus, tmp)
        x86 = asm_of(x86_cpu_c, X86_TRIPLE)
        for prim, rx in X86_PRIMS.items():
            if len(rx.findall(x86)) < 1:
                fail("preload-prims-x86: no `%s' in the -O2 asm -- the cache "
                     "preload is INERT on the x86_64 host ISA." % prim)
        if ok[0]:
            note("  preload-prims-x86: clflush and prefetcht0 present in the -O2 "
                 "asm of the x86_64 rendering")

        # ---- enemy-loop: it survived the optimiser -------------------------
        got = count_enemy_ops(a64)
        if got is None:
            fail("enemy-loop: het_cpu_enemy is not in the compiled AArch64 object "
                 "at all")
            return ok[0], lines
        ld, st, br = got
        if ld < 1:
            fail("enemy-loop: het_cpu_enemy's -O2 body performs NO discarded load "
                 "(no `ldr xzr'), so the read side of every access pattern was "
                 "optimised away.  Restore `volatile' on het_cpu_enemy_args.scratch "
                 "and on the local pointer.")
        if st < MIN_ENEMY_STORES:
            fail("enemy-loop: het_cpu_enemy's -O2 body carries only %d store(s), "
                 "expected at least %d (the sigma branches declare 2+1+1+0).  The "
                 "scratchpad must be both READ and WRITTEN: the most effective "
                 "access sequences mix loads and stores [Sorensen16 sec 3.3]."
                 % (st, MIN_ENEMY_STORES))
        if br < 1:
            fail("enemy-loop: het_cpu_enemy's -O2 body has NO back edge around its "
                 "scratchpad traffic -- an enemy that touches the scratchpad once is "
                 "not a stressor.")
        if ok[0]:
            note("  enemy-loop: het_cpu_enemy survives -O2 -- %d discarded load(s), "
                 "%d store(s), %d traffic loop(s)" % (ld, st, br))

        # ---- enemy-seq-runtime: sigma is never a compile-time constant -----
        per_seq = {}
        for q in SEQS:
            a = asm_of(cpu_c, AARCH64_TRIPLE,
                       extra=["-DHET_CPU_ENEMY_SEQ=%d" % q])
            per_seq[q] = count_enemy_ops(a)
        if len({per_seq[q] for q in SEQS}) != 1:
            fail("enemy-seq-runtime: het_cpu_enemy's op count MOVES with "
                 "-DHET_CPU_ENEMY_SEQ %s.  A compile-time sigma folds the switch to "
                 "the one branch -D named; it must arrive in het_cpu_enemy_args as a "
                 "RUNTIME field." % {q: per_seq[q] for q in SEQS})
        else:
            note("  enemy-seq-runtime: het_cpu_enemy's op count is INVARIANT over "
                 "-DHET_CPU_ENEMY_SEQ=0..3 (%d ld + %d st)"
                 % (per_seq[0][0], per_seq[0][1]))

        # ---- stress-live/stress-off-zero: it runs, and stops when switched off --
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

        # BOTH halves of the first touch through RSS: reading alone must not
        # back the pages, first-touching must back nearly all of them.
        ft_bytes = int(on["ft_bytes"])
        ft_read = int(on["ft_rss_after_read"])
        ft_touch = int(on["ft_rss_after_touch"])
        want_kb = ft_bytes // 1024
        if ft_read < 0 or ft_touch < 0:
            fail("first-touch: no /proc/self/statm on this host, so the zero-page "
                 "hazard is unmeasured -- and this gate is Linux-only already "
                 "(het_cpu_stress.h pins threads with sched_setaffinity).")
        elif ft_touch < (want_kb * 9) // 10:
            fail("first-touch: het_cpu_first_touch grew RSS by only %d KB for a %d "
                 "KB buffer.  It is NOT faulting the pages in, so the noise buffer "
                 "stays on the shared zero page: one cache line, no interconnect "
                 "traffic however large it is." % (ft_touch, want_kb))
        elif ft_read > want_kb // 10:
            note("  first-touch works (RSS +%d KB / %d KB), though on this host "
                 "reading alone already backed %d KB, so the zero-page hazard may be "
                 "absent here (huge pages? pre-faulted allocator?)"
                 % (ft_touch, want_kb, ft_read))
        else:
            note("  first-touch: the noise buffer is REAL memory -- reading %d KB "
                 "of it backs only %d KB (the shared zero page), while "
                 "het_cpu_first_touch backs %d KB"
                 % (want_kb, ft_read, ft_touch))

        live = ("enemy_rounds", "enemy_accesses", "preload_ops", "noise_rounds")
        for k in live:
            if int(on[k]) <= 0:
                fail("stress-live: with the CPU stress ON, %s is %s.  The mechanism "
                     "compiled, linked, and did NOTHING at run time." % (k, on[k]))
        for k in live:
            if int(off[k]) != 0:
                fail("stress-off-zero: with the CPU stress OFF, %s is %s, not 0: "
                     "the counter is wired to something unconditional, and a tally "
                     "that cannot go to zero is not evidence." % (k, off[k]))
        if int(on.get("preload_live", "0")) != 1:
            fail("stress-live: HET_CPU_PRELOAD_LIVE is 0 on this host -- the cache "
                 "preload has no primitives here and is a no-op.")
        if ok[0]:
            note("  stress-live    (on) : enemy_rounds=%s accesses=%s "
                 "preload_hints=%s noise_rounds=%s (enemies realised: %s)"
                 % (on["enemy_rounds"], on["enemy_accesses"], on["preload_ops"],
                    on["noise_rounds"], on["enemies"]))
            note("  stress-off-zero(off): enemy_rounds=%s accesses=%s "
                 "preload_hints=%s noise_rounds=%s"
                 % (off["enemy_rounds"], off["enemy_accesses"], off["preload_ops"],
                    off["noise_rounds"]))

        # Left unwritten, preload_inert stays memset-0 (= live) on a host with NO
        # cache primitives, and every null there goes COLD-INVALID.
        if "_ct.preload_inert = !het_cpu_preload_live();" not in cu_src:
            fail("preload-guard-field: the emitted driver does NOT write "
                 "`_ct.preload_inert = !het_cpu_preload_live();', so on a "
                 "no-primitive host every null goes COLD-INVALID.")
        else:
            note("  preload-guard-field: the driver writes _ct.preload_inert = "
                 "!het_cpu_preload_live()")
        # preload-guard-term: the request, dropped when the field says the
        # preload is inert, so no null on such a host goes COLD-INVALID.
        if PRELOAD_REQ_TERM not in cu_src:
            fail("preload-guard-term: the emitted driver does NOT compute the "
                 "preload request as `%s'.  Raised unconditionally, it disqualifies "
                 "every null on a host whose preload issues zero hints."
                 % PRELOAD_REQ_TERM)
        else:
            note("  preload-guard-term: the preload request is guarded by "
                 "_ct.preload_inert")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return ok[0], lines


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("litmus", nargs="+")
    a = ap.parse_args()

    if not os.path.exists(LITMUS7):
        print("error: litmus7 not built (%s)" % LITMUS7, file=sys.stderr)
        return 2

    allok = True
    for p in a.litmus:
        try:
            ok, lines = check(p)
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
