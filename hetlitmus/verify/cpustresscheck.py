#!/usr/bin/env python3
"""The CPU-side and interconnect stress layer of one het harness, which
reaches no PTX (hetlitmus/docs/faithfulness.md "CPU-side stress liveness"):
  preload-prims  litmus7's three cache primitives are in the -O2 AArch64 asm
  stress-loop    het_cpu_stress's -O2 body keeps its discarded loads and stores
  stress-live    a native probe against the emitted het_cpu_stress.h counts
                 stress rounds and accesses, preload hints and noise rounds
A miss means a null was scored on a layer the optimiser removed or that never
ran.  Exit 0 PASS, 1 FAIL, 2 error.
"""

import argparse
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ptxcheck as ptx

# The _cpu.c of the AArch64 tree, read through clang --target; the preload is
# litmus7's own primitives (libdir/_aarch64/_cache.h).
TRIPLE = "aarch64-linux-gnu"
PRIMS = (("dc civac", r"\bdc\s+civac\b"), ("prfm pldl1keep", r"\bprfm\s+pldl1keep\b"),
         ("prfm pstl1keep", r"\bprfm\s+pstl1keep\b"))
STRESS_BODY = re.compile(r"^het_cpu_stress:.*?\n(.*?)^\s*\.size\s+het_cpu_stress",
                         re.S | re.M)
# `(void)*l' lowers to a zero-register load; the sigma arms declare 2+1+1+0
# stores, and a non-volatile build lands under both.
DISCARD_LOAD = re.compile(r"^\s+ldr\s+[xw]zr\s*,", re.M)
STORE = re.compile(r"^\s+str\b", re.M)
MIN_STORES = 4
LIVE = ("stress_rounds", "stress_accesses", "preload_ops", "noise_rounds")

# Built native against the harness's own header, which may not include
# <pthread.h>; the flag is up before the spawn, as the emitted driver has it.
PROBE_C = r"""
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define HET_CPU_STRESS_IMPL
#include "het_cpu_stress.h"

#define WORDS (1u << 16)
#define STRESS_THREADS 2
#define NOISE_THREADS 4

int main(void) {
  het_cpu_tally t;
  int go = 1;
  uint32_t nreg = WORDS / HET_CPU_WORDS_PER_REGION;
  uint32_t spread = HET_CPU_SPREAD < nreg ? (uint32_t)HET_CPU_SPREAD : nreg;
  uint64_t *scratch = calloc(WORDS, sizeof *scratch);
  uint64_t *nbuf = calloc(WORDS, sizeof *nbuf);
  uint32_t *idx = malloc(nreg * sizeof *idx);
  het_cpu_stress_args sa[STRESS_THREADS];
  het_cpu_noise_args na[NOISE_THREADS];
  pthread_t sth[STRESS_THREADS], nth[NOISE_THREADS];
  uint64_t x = 0, y = 0, ops = 0;
  void *const pl[2] = { &x, &y };

  memset(&t, 0, sizeof t);
  if (!scratch || !idx || !nbuf) return 3;
  het_cpu_shuffle(idx, nreg, 1u);
  for (int e = 0; e < STRESS_THREADS; e++) {
    sa[e] = (het_cpu_stress_args){ .scratch = scratch, .idx = idx, .nidx = spread,
      .words_per_region = HET_CPU_WORDS_PER_REGION, .pattern = HET_CPU_STRESS_PATTERN,
      .core = -1, .go = &go, .tally = &t };
    pthread_create(&sth[e], NULL, het_cpu_stress, &sa[e]);
  }
  for (int n = 0; n < NOISE_THREADS; n++) {
    na[n] = (het_cpu_noise_args){ .buf = nbuf + n * (WORDS / NOISE_THREADS),
      .words = WORDS / NOISE_THREADS, .words_per_round = 256, .stride = 1,
      .core = -1, .go = &go, .tally = &t };
    pthread_create(&nth[n], NULL, het_cpu_noise, &na[n]);
  }
  for (int i = 0; i < 10000; i++)
    ops += het_cpu_preload(pl, 2, 1u, HET_WHO_CPU(0), (uint64_t)i * 5u + 1u, 100);
  nanosleep(&(struct timespec){ 0, 50L * 1000L * 1000L }, NULL);
  __atomic_store_n(&go, 0, __ATOMIC_RELAXED);
  for (int e = 0; e < STRESS_THREADS; e++) pthread_join(sth[e], NULL);
  for (int n = 0; n < NOISE_THREADS; n++) pthread_join(nth[n], NULL);
  printf("stress_rounds=%llu stress_accesses=%llu preload_ops=%llu "
         "noise_rounds=%llu noise_words=%llu stress_threads=%u\n",
         (unsigned long long)t.stress_rounds, (unsigned long long)t.stress_accesses,
         (unsigned long long)ops, (unsigned long long)t.cpu_noise_rounds,
         (unsigned long long)t.cpu_noise_words, t.stress_threads_realised);
  return 0;
}
"""


def asm_of(cpu_c):
    """The -O2 AArch64 assembly of <test>_cpu.c: what survived the optimiser."""
    r = ptx.run(["clang", "--target=" + TRIPLE, "-std=gnu11", "-O2", "-S",
                 "-o", "-", cpu_c])
    if r.returncode != 0:
        raise RuntimeError("clang --target=%s failed:\n%s" % (TRIPLE, r.stdout))
    return r.stdout


def probe(d):
    """{counter: value} of one 50 ms run of the layer, on this host."""
    src, exe = os.path.join(d, "_probe.c"), os.path.join(d, "_probe")
    with open(src, "w") as fh:
        fh.write(PROBE_C)
    for cmd in (["gcc", "-std=gnu11", "-O2", "-pthread", src, "-o", exe], [exe]):
        r = ptx.run(cmd)
        if r.returncode != 0:
            raise RuntimeError("%s failed:\n%s" % (os.path.basename(cmd[0]), r.stdout))
    print("  probe: " + r.stdout.strip())
    return dict(kv.split("=") for kv in r.stdout.split())


def check(litmus_path):
    """The FAIL lines of one test."""
    bad = []
    tmp = tempfile.mkdtemp(prefix="cpustresscheck_")
    try:
        cu, cpu_c = ptx.emit_harness(litmus_path, tmp)
        if cpu_c is None:
            return ["FAIL: %s emits no _cpu.c: no CPU stress layer to read"
                    % os.path.basename(litmus_path)]
        asm = asm_of(cpu_c)
        bad += ["FAIL: preload-prims: no `%s' in the -O2 asm" % label
                for label, rx in PRIMS if not re.search(rx, asm)]
        m = STRESS_BODY.search(asm)
        if not m:
            bad.append("FAIL: stress-loop: het_cpu_stress is not in the -O2 asm")
        else:
            body = m.group(1)
            ld, st = len(DISCARD_LOAD.findall(body)), len(STORE.findall(body))
            if ld < 1:
                bad.append("FAIL: stress-loop: no discarded load (`ldr xzr') survives "
                           "-O2 in het_cpu_stress")
            if st < MIN_STORES:
                bad.append("FAIL: stress-loop: %d store(s) survive -O2 in "
                           "het_cpu_stress, expected >= %d" % (st, MIN_STORES))
        tally = probe(os.path.dirname(cu))
        bad += ["FAIL: stress-live: %s=%s with the layer on" % (k, tally[k])
                for k in LIVE if int(tally[k]) <= 0]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("litmus", nargs="+")
    a = ap.parse_args()
    if not os.path.exists(ptx.LITMUS7):
        print("error: litmus7 not built (%s)" % ptx.LITMUS7, file=sys.stderr)
        return 2
    rc = 0
    for p in a.litmus:
        print("=== cpu+interconnect stress liveness: %s ===" % os.path.basename(p))
        try:
            bad = check(p)
        except (RuntimeError, OSError, KeyError, ValueError) as e:
            print("ERROR: %s" % e)
            return 2
        for b in bad:
            print(b)
        print("RESULT: %s\n" % ("FAIL" if bad else "PASS"))
        rc |= bool(bad)
    return rc


if __name__ == "__main__":
    sys.exit(main())
