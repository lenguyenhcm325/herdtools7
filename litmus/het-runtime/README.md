# het-runtime — the embedded runtime sources of the het harness

These files are the C/CUDA runtime that litmus7's het emitter emits **verbatim**.
The `.h` payloads become their own file in every emitted harness directory
(`hetEmit.ml`, the `write "..."` calls); the `.inc` payloads are pasted into the
body of the per-dialect `.cu` / `.hip` render, which is why they carry no include
guard.  They are real source files so they can be edited with C tooling.  A rule
in `litmus/dune` wraps them into the generated module `HetPayloads` at build time
— the OCaml string can never drift from the file, and an accidental
`|het_payload}` in the content fails the OCaml build loudly rather than
corrupting the payload silently.

Two payloads are **not** stored here: `outs.h`/`outs.c` (litmus7's own outcome
histogram, reused to tally the merged CPU+GPU register readback) are cat'ed
straight from `litmus/libdir/_outs.{h,c}` by the same rule, so "byte-identical to
libdir" holds by construction rather than by anyone remembering it.  They are
embedded (rather than copied from a libdir at run time) so a het harness
directory is self-contained: the repro command uses `-set-libdir herd/libdir`,
which ships the herd `.cat` models, not litmus7's C runtime.

These notes are for the **maintainer** of these files, and they live here rather
than inside the `.h` payloads because the payload bytes land in every emitted
harness directory and these notes need not.  What a reader on a GPU box needs is
in the payload headers themselves.

## het_stress.h — the GPU memory-stress layer

Emitted verbatim into every het harness directory and `#include`'d by BOTH the
`.cu` and the `.hip` render.  It is a SHARED C header (like `outs.h`), not a
per-dialect render, so the "one template, two renders" invariant of the OCaml
driver template is untouched: `dump_gpu_file` still emits only test-specific code
through `gpu_dialect` FIELDS.  Keeping it one file also keeps every line of
reused code, with its mandatory attributions, in one auditable place — which is
what the reuse licence condition (citation) actually needs.  The header states
that condition and carries the citation table; do not restate it here.

Its ONE dialect divergence (the scoped atomics behind `het_spin`) is a
preprocessor selection, because CUDA and HIP genuinely spell device-scope atomics
differently and there is no dialect-neutral spelling.

Design: `hetlitmus/docs/00-environment-design.md` sec 3.5.

## het_cpu_stress.h — CPU-side + interconnect stress

The sibling of `het_stress.h`.  The GPU scratchpad stress widens the
INTRA-DEVICE window; the heterogeneous weak behaviour does not live there.  It
lives in the CROSS-DEVICE window — a store in flight across the interconnect but
not yet globally visible — and this file is what loads that path.  Design:
`hetlitmus/docs/00-environment-design.md` sec 3.6.

WHY IT IS A SEPARATE HEADER FROM `het_stress.h`, AND NOT PART OF THE `.cu`.
This is not tidiness; it is forced, and getting it wrong breaks a gate:

* the emitted CPU thread wrapper (`cpu_thread_P<n>`) and the driver `main()`
  both live in the `.cu` — i.e. in the NVCC translation unit.  The preload
  primitives are HOST-ISA inline asm (`dc civac` / `prfm` on AArch64, `clflush`
  / `prefetcht0` on x86_64).  Put them in the `.cu` and nvcc must swallow
  AArch64 asm on an x86 build host.  So the asm lives in that header, which only
  `<test>_cpu.c` (the gcc / `clang --target=aarch64-linux-gnu` TU) compiles,
  behind `HET_CPU_STRESS_IMPL`; the `.cu` sees the declarations and the argument
  structs, and NOT ONE LINE of host ISA.

* NO `<pthread.h>` IN THAT FILE.  `<sched.h>`, `<stdio.h>`, `<stdlib.h>`,
  `<string.h>` and `<unistd.h>` all survive `clang --target=aarch64-linux-gnu
  -c`, but `<pthread.h>` does NOT — it reaches x86 glibc's
  `bits/pthreadtypes-arch.h`, whose `__cleanup_fct_attribute` is
  `__attribute__((__regparm__(1)))`, and regparm "is not valid on this platform"
  for AArch64.  That cross-assembly step is `comp.sh`'s, and
  `hetlitmus/verify/smoke.sh` gates on it, so a stray `#include <pthread.h>`
  there fails the smoke gate on every het test in the corpus.  The thread bodies
  need only the pthread entry-point signature (a void-pointer function of one
  void pointer), never a pthread primitive; `pthread_create` is called from the
  `.cu`, which is compiled for the native host and already includes
  `<pthread.h>`.  Keep it that way.

THE `-2s` INVARIANTS.  For a two-sided test the CPU issues the ordering
instructions UNDER TEST (STLR / LDAPR / DMB.SY).  They are the hypothesis.  So
the stress layer holds two invariants, and both hold BY CONSTRUCTION:

  (i)  enemy and noise traffic touches ONLY a disjoint scratchpad / noise
       buffer — never X, Y or the barrier.  An enemy that WRITES a test
       variable injects co/rf edges and the run stops being a test of the
       CPU-GPU order.  Verbatim, [Sorensen16 sec 1]: "Because the stressing
       threads and memory are disjoint from application threads and data, the
       set of possible behaviours a program can exhibit remains the same."
  (ii) nothing is ever injected INSIDE `het_run_P<n>`.  A fence or atomic
       between the two tested accesses adds ordering the test does not have.
       The tested order is an opaque compiled unit in `<test>_cpu.c`; the
       emitter only injects AROUND it (preload before the call, enemies beside
       it).  A cache HINT changes residency, not program order, so preloading
       the test variables before the body is `-2s`-safe.

## het_verdict.h — `het_obs_record` + the outcome rule

This is the EPISTEMIC CORE of the campaign, not bookkeeping.  Every "Never"
the harness prints is otherwise uninterpretable: a cold harness and a
genuinely unreachable behaviour produce the IDENTICAL empty histogram.  The
rule says whether the outcome was seen and, where it was not, what this
harness reached — the effort it spent and the liveness its own counters
measured, with NOTHING vouching for either.  It holds no prediction and
prints none.

> "When testing, it is impossible to tell if an unobserved illegal execution
> is not allowed or if it is simply rare and was not exposed by the tests."
> — [MCMutants23 sec 1.1, p.474].

The record and the rule live in ONE header, included by `<test>.cu`/`.hip` AND
by the verdict unit test, so the gate exercises the exact struct and the exact
rule the harness runs.  A re-declared copy in the test would be free to drift
away from the one that ships — which is how you end up gating a rule nobody
executes.

Design: `hetlitmus/docs/harness-reporting.md`.

## het_alloc_{cuda,hip}.inc, het_noise_{cuda,hip}.inc — the two allocators

The `gd_shared_mem_defs` and `gd_noise_mem_defs` fields of `gpu_dialect`
(`litmus/hetDialect.ml`).  Each pair is one object class in one dialect:

* `het_alloc_*` — the shared litmus vars + the rendezvous barrier
  (`gd_alloc_shared` / `gd_free_shared`).  The allocator selects the property
  under test, so the banner inside the CUDA file states the modes and the
  fail-closed guards; design: `hetlitmus/docs/00-environment-design.md` sec 3.2.
* `het_noise_*` — the interconnect-stress buffers (`gd_alloc_noise` /
  `gd_free_noise`), a fourth object class disjoint from the test locations;
  design: `hetlitmus/docs/00-environment-design.md` sec 3.6.

They are per-dialect because the two targets differ in kind, not in spelling:
GH200 places pages across an LPDDR/HBM split, MI300A has one HBM pool and gets
its interconnect pressure from cross-chiplet contention instead.  A fragment
pasted into the render, not a header: the surrounding `.cu`/`.hip` supplies
`HET_PLACE`, `_het_place_failures` and `het_cpu_first_touch`.

External sources cited by these payloads resolve in
`hetlitmus/docs/REFERENCES.md`.
