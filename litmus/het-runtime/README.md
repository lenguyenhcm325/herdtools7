# het-runtime — the embedded runtime sources of the het harness

These files are the C/CUDA runtime that litmus7's het emitter emits **verbatim**
— with one exception, the machine-word holes described below.
The `.h`/`.cuh` payloads become their own file in every emitted harness directory
(`hetEmit.ml`, the `write "..."` calls); the `.inc` payloads are pasted into the
body of the per-dialect `.cu` / `.hip` render, which is why they carry no include
guard.  They are real source files so they can be edited with C tooling.  A rule
in `litmus/dune` wraps them into the generated module `HetPayloads` at build time
— the OCaml string can never drift from the file, and an accidental
`|het_payload}` in the content fails the OCaml build loudly rather than
corrupting the payload silently.

Two payloads are **not** stored here: `outs.h`/`outs.c` (litmus7's own outcome
histogram, reused to tally the merged CPU+GPU register readback) are cat'ed
straight from `litmus/libdir/_outs.{h,c}`, so the old comment-enforced invariant
"keep these byte-identical to libdir" now holds by construction.  They are
embedded (rather than copied from a libdir at run time) so a het harness
directory is self-contained: the repro command uses `-set-libdir herd/libdir`,
which ships the herd `.cat` models, not litmus7's C runtime.

The design notes below moved with the payloads out of `HetArch.ml`.  They are
kept here (not inside the `.h` files) because the payload bytes are what lands
in every emitted harness dir — the notes are for the *maintainer* of these
files, not for every harness copy.

## het_stress.cuh — B4: GPU memory-stress layer

Emitted verbatim into every het harness directory and `#include`'d by BOTH the
`.cu` and the `.hip` render.  It is a SHARED C header (like `outs.h`), not a
per-dialect render, so the "one template, two renders" invariant of the OCaml
driver template is untouched: `dump_gpu_file` still emits only test-specific
code through `gpu_dialect` FIELDS, and every line of reused cuda-litmus code —
with its mandatory attributions — stays in this one auditable place, which is
what the reuse licence condition (citation) actually needs.

Its ONE dialect divergence (the scoped atomics behind `het_spin`) is a
preprocessor selection, because CUDA and HIP genuinely spell device-scope
atomics differently and there is no dialect-neutral spelling.

See `env-research/Q5-gpu-stress.md` sections 2 (knob catalog), 3.1 (`do_stress`
/ scratchpad / `StressParams`), 3.3 (the device-scope spin window-opener) and
3.4 (host→device seeded RNG).

## het_cpu_stress.h — B5: CPU-side + interconnect (C2C) stress

The sibling of `het_stress.cuh`, and it exists for a reason that is worth
stating once, at the top: B4's GPU scratchpad stress widens the INTRA-DEVICE
window.  The heterogeneous weak behaviour does not live there.  It lives in
the CROSS-DEVICE window — a store in flight across NVLink-C2C but not yet
globally visible — and nothing in the harness loaded that path deliberately
until this file.  Q6 (`env-research/Q6-cpu-interconnect-stress.md`) is the spec.

WHY IT IS A SEPARATE HEADER FROM het_stress.cuh, AND NOT PART OF THE .cu.
This is not tidiness; it is forced, and getting it wrong breaks a gate:

* the emitted CPU thread wrapper (`cpu_thread_P<n>`) and the driver `main()`
  both live in the `.cu` — i.e. in the NVCC translation unit.  The M3 preload
  primitives are HOST-ISA inline asm (`dc civac` / `prfm` on AArch64, `clflush`
  / `prefetcht0` on x86_64).  Put them in the `.cu` and nvcc must swallow
  AArch64 asm on an x86 build host.  So the asm lives HERE, in a header that
  only `<test>_cpu.c` (the gcc / `clang --target=aarch64-linux-gnu` TU)
  compiles, behind `HET_CPU_STRESS_IMPL`; the `.cu` sees the declarations and
  the argument structs, and NOT ONE LINE of host ISA.

* NO `<pthread.h>` IN THIS FILE.  VERIFIED, not assumed: `<sched.h>`,
  `<stdio.h>`, `<stdlib.h>`, `<string.h>` and `<unistd.h>` all survive
  `clang --target=aarch64-linux-gnu -c`, but `<pthread.h>` does NOT — it
  reaches x86 glibc's `bits/pthreadtypes-arch.h`, whose
  `__cleanup_fct_attribute` is `__attribute__((__regparm__(1)))`, and regparm
  "is not valid on this platform" for AArch64.  That cross-assembly step is
  `comp.sh`'s, and `hetlitmus/verify/smoke.sh` gates on it, so a stray
  `#include <pthread.h>` here fails the smoke gate on every het test in the
  corpus.  The thread bodies need only the pthread entry-point signature (a
  void-pointer function of one void pointer), never a pthread primitive;
  `pthread_create` is called from the `.cu`, which is compiled for the native
  host and already includes `<pthread.h>`.  Keep it that way.

THE -2s INVARIANTS (Q6 2.4).  For a two-sided test the CPU issues the ordering
instructions UNDER TEST (STLR / LDAPR / DMB.SY).  They are the hypothesis.  So
the stress layer holds two invariants, and both hold BY CONSTRUCTION here:

  (i)  enemy and noise traffic touches ONLY a disjoint scratchpad / noise
       buffer — never X, Y or the barrier.  An enemy that WRITES a test
       variable injects co/rf edges and the run stops being a test of the
       CPU-GPU order.  S&D PLDI'16, verbatim: "Because the stressing threads
       and memory are disjoint from application threads and data, the set of
       possible behaviours a program can exhibit remains the same."
  (ii) nothing is ever injected INSIDE `het_run_P<n>`.  A fence or atomic
       between the two tested accesses adds ordering the test does not have.
       The tested order is an opaque compiled unit in `<test>_cpu.c`; the
       emitter only injects AROUND it (preload before the call, enemies beside
       it).  A cache HINT changes residency, not program order, so preloading
       the test variables before the body is -2s-safe.

See also: `hetlitmus/docs/00-environment-design.md` 3.6.

## het_verdict.h — B6/B7: het_obs_record + the outcome rule

This is the EPISTEMIC CORE of the campaign, not bookkeeping.  Every "Never"
the harness prints is otherwise uninterpretable: a cold harness and a
genuinely unreachable behaviour produce the IDENTICAL empty histogram.  The
rule says whether the outcome was seen and, where it was not, what vouched for
the harness that did not see it -- it holds no prediction and prints none.

> "When testing, it is impossible to tell if an unobserved illegal execution
> is not allowed or if it is simply rare and was not exposed by the tests."
> — MC Mutants (Levine et al., ASPLOS'23) 1.1, p.474.

The record and the rule live in ONE header, included by `<test>.cu`/`.hip` AND
by the verdictcheck unit test, so the gate exercises the exact struct and the
exact rule the harness runs.  A re-declared copy in the test would be free to
drift away from the one that ships — which is how you end up gating a rule
nobody executes.

See `env-research/Q4-positive-control.md` (2.3 the corpus grid as a lattice,
2.4 the two-layer design, 3.2 the record fields, 3.3 the decision rule, 5 the
reporting stance) and `hetlitmus/docs/positive-control.md`.

## het_alloc_{cuda,hip}.inc, het_noise_{cuda,hip}.inc — B1/B5: the two allocators

The `gd_shared_mem_defs` and `gd_noise_mem_defs` fields of `gpu_dialect`
(`litmus/hetDialect.ml`).  Each pair is one object class in one dialect:

* `het_alloc_*` — the shared litmus vars + the rendezvous barrier
  (`gd_alloc_shared` / `gd_free_shared`).  The allocator selects the property
  under test, so the banner inside the CUDA file states the modes and the
  fail-closed guards; `env-research/Q8-allocation.md` is the spec.
* `het_noise_*` — the interconnect-stress buffers (`gd_alloc_noise` /
  `gd_free_noise`), a fourth object class disjoint from the test locations;
  `env-research/Q6-cpu-interconnect-stress.md` sections 3.2/3.4 is the spec.

They are per-dialect because the two targets differ in kind, not in spelling:
GH200 places pages across an LPDDR/HBM split, MI300A has one HBM pool and gets
its interconnect pressure from cross-chiplet contention instead.  A fragment
pasted into the render, not a header: the surrounding `.cu`/`.hip` supplies
`HET_PLACE`, `_het_place_failures` and `het_cpu_first_touch`.

### `@NAME@` — the machine-word holes

A payload is written once and pasted into every lane that renders its dialect,
and the lanes do **not** all name the same machine: the `(X86_64, cuda)` dev
box and any pair in no row of `litmus/hetMachine.ml` name none at all.  So a
printed sentence that needs a machine noun spells it `@NAME@`, and the emitter
fills it from the row that resolved (`HetMachine.fill`, `mc_words`).  Filling is
textual and happens at paste time, so an entitled lane gets exactly the words
its row owns and a nameless lane gets the mechanism instead — the same rule the
`#ifndef` defaults in `het_verdict.h` follow, applied to text that is pasted
rather than compiled.

Two consequences worth knowing before editing one of these files:

* a hole no machine row has a word for **refuses the emission** (exit 3), so a
  new hole must be given a word in `generic_machine` too — that is the row a
  nameless render prints from;
* holes belong in **printed** text, not in comments.  A comparative comment or
  a citation names the part it is about and must keep doing so: de-branding
  “Fusco et al.: a Grace and a Hopper noise kernel…” would falsify the
  citation.  `hetlitmus/verify/brandscan.py` enforces exactly that split.
