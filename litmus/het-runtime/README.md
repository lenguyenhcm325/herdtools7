# het-runtime — the embedded runtime sources of the het harness

These files are the C/CUDA/HIP runtime that litmus7's het emitter emits
**verbatim**.  The `.h` payloads become their own file in every emitted harness
directory; the `.inc` payloads are pasted into the body of the per-dialect `.cu`
/ `.hip` render, which is why they carry no include guard.  They are real source
files, so they can be edited with C tooling: a rule in `litmus/dune` wraps them
into the generated module `HetPayloads` at build time, so the OCaml string cannot
drift from the file — and the raw-string delimiter `|het_payload}` must NEVER
appear in a payload.

`outs.h` / `outs.c` are not stored here.  litmus7's own outcome histogram, reused
to tally the merged CPU+GPU register readback, is cat'ed straight from
`litmus/libdir/_outs.{h,c}` by the same rule.  Everything is embedded rather than
read from a libdir at run time so that an emitted harness directory is
self-contained: the emission takes whatever `-set-libdir` the caller names, and
no libdir has to carry litmus7's C runtime.

These notes are for the **maintainer** of these files.  They live here rather
than in the payloads because the payload bytes land in every emitted harness
directory and these notes need not; what a reader on a GPU box needs is in the
payload headers themselves, and the design rationale is in `hetlitmus/docs/`.

## het_stress.h — the GPU memory-stress layer

`#include`'d by BOTH renders, as one shared C header rather than a per-dialect
fragment: `HetGpuFile.dump` then still emits test-specific code through
`gpu_dialect` fields alone, and every line of reused code keeps its attribution
in one place, which is what the reuse licence condition needs.  Its one dialect
divergence is a preprocessor selection of the vendor runtime header its
scratchpad counters need.

Design: `hetlitmus/docs/00-environment-design.md` sec 3.5.

## het_cpu_stress.h — CPU-side + interconnect stress

The sibling of `het_stress.h`.  The GPU scratchpad stress widens the
INTRA-device window; the heterogeneous weak behaviour lives in the cross-device
window — a store in flight across the interconnect but not yet globally visible
— and this file is what loads that path.  Design:
`hetlitmus/docs/00-environment-design.md` sec 3.6.

Two constraints force it into a header of its own instead of into the `.cu`:

* The preload primitives are host-ISA inline asm the nvcc translation unit must
  never meet, so they sit behind `HET_CPU_STRESS_IMPL`; the split, and the units
  on either side of it, are stated in `het_cpu_stress.h` itself.
* NO `<pthread.h>` in that file.  `<sched.h>`, `<stdio.h>`, `<stdlib.h>`,
  `<string.h>` and `<unistd.h>` all survive `clang --target=aarch64-linux-gnu
  -c`; `<pthread.h>` does not, because it reaches x86 glibc's
  `bits/pthreadtypes-arch.h`, whose `__cleanup_fct_attribute` is
  `__attribute__((__regparm__(1)))`, and regparm is not valid for AArch64.  The
  thread bodies need only the pthread entry-point signature (a void-pointer
  function of one void pointer), never a pthread primitive; `pthread_create` is
  called from the `.cu`, which is compiled for the native host and already
  includes `<pthread.h>`.

The two-sided (`-2s`) invariants the stress layer holds by construction are in
`hetlitmus/docs/00-environment-design.md` sec 3.6.

## het_rdv.h — the cross-device rendezvous and the slot layout

`#include`'d by the `.cu` / `.hip` render alone, because both sides of the
rendezvous are compiled there: `cpu_thread_P<n>` lives in that translation unit
and `<test>_cpu.c` holds only the tested body.  It carries `het_rdv_device` (a
`cuda::atomic_ref` pair on the CUDA side, `__hip_atomic_fetch_add` / `_load` with
`__builtin_amdgcn_s_sleep(1)` on the HIP side), `het_rdv_host` (GCC `__atomic_*`
plus an optional poke into the vendor runtime), `het_rdv_jitter` and
`HET_SLOT_STRIDE_WORDS`.

Design — why the rendezvous writes no ordering and sits around the tested group
rather than between two of its accesses, what each arm's arrival lowers to, what
an iteration whose partner misses its cap costs, and how the slot stride is
sized:
`hetlitmus/docs/00-environment-design.md` sec 3.3 and sec 3.4.

## het_verdict.h — `het_obs_record` + the outcome rule

The record and the rule live in ONE header, so no second declaration can drift
away from the one that ships.

Design: `hetlitmus/docs/harness-reporting.md`.

## het_alloc_{cuda,hip}.inc, het_noise_{cuda,hip}.inc — the two allocators

The `gd_shared_mem_defs` and `gd_noise_mem_defs` fields of `gpu_dialect`
(`litmus/hetDialect.ml`).  Each pair is one object class in one dialect:

* `het_alloc_*` — the shared litmus vars + the rendezvous counter
  (`gd_alloc_shared` / `gd_free_shared`).
  Design: `hetlitmus/docs/00-environment-design.md` sec 3.2.
* `het_noise_*` — the interconnect-stress buffers (`gd_alloc_noise` /
  `gd_free_noise`).  Design: `hetlitmus/docs/00-environment-design.md` sec 3.6.

They are per-dialect because the two targets differ in kind, not in spelling
(`hetlitmus/docs/00-environment-design.md` sec 3.6).  Each is a fragment pasted
into the render, not a header: the surrounding `.cu` / `.hip` supplies
`HET_PLACE`, `_het_place_failures` and `het_cpu_first_touch`.

External sources cited by these payloads resolve in
`hetlitmus/docs/REFERENCES.md`.
