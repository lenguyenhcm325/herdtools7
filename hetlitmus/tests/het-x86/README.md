# `tests/het-x86` — the committed (x86_64, hip) pair fixture

Het tests with an x86-64 CPU column. It exists so that gates and cram tests
which need the **(x86_64, hip) pair** do not have to generate the whole x86
corpus first — `tests/het/generate.sh --cpu-arch x86_64` resolves `$BIN/hetgen7` from
`_build/install/default/bin` through `paths.sh`, which the cram sandbox does
not stage (the stanzas in `tests/cram/dune` declare `%{bin:litmus7}` only).

**`corpus-gate.sh`'s het-x86 label keeps it honest.** Everything here is an
extract, so it could go stale in silence while every gate that reads it kept
passing; the gate compares the fixture as a subset of a fresh `generate.sh --cpu-arch
x86_64` run and reports any extra, missing or differing file as DRIFT. If it reddens,
re-cut with `make hetlitmus-promote` — **do not edit these files to match.**

It is **not** a corpus. The census phase of `corpus-gate.sh` counts `tests/het`
and `tests/gpu-only` only, against `verify/census.py`'s pins; this fixture is
compared as a subset of the x86_64 rendering and never against the committed
corpus.

Its readers: the cram tests `gpu-target.t`, `shared-alloc.t`, `coop-launch.t`,
`stress.t`, `cpu-stress.t` and `slot-readout.t` (every `.hip` render they emit
comes from here), `smoke.sh`'s two `.hip` reps, `runcheck.py`'s x86 fixture,
`recfields.py`'s hip lane and `verdictcheck.py`'s `(X86_64, hip)` frame.

Every `.litmus` file here is copied verbatim from a `generate.sh --cpu-arch
x86_64` run, so
it is the same rendering the real x86 lane emits:

* `MP-cg-sys-relaxed-x86_64.litmus` — the fully relaxed het-MP floor: two procs,
  no ordering annotation on either side. It is the plain render the cram tests
  reach for when the subject is the harness rather than an annotation.
* `MP-cg-sys-acqrel-2s-x86_64.litmus`, `S-cg-sys-fence-x86_64.litmus` — the two
  annotated renders the cram tests emit to `.hip`, so between them those tests
  see both GPU annotation shapes: acquire loads on the first, a system-scope
  seq_cst fence between the GPU's load and its store on the second.
* `CoRR-cg-sys-fence-2s-x86_64.litmus` — the same-location CPU fence:
  `render_2s_x86_64` spells the `Pos<XY>` edge `MFence<L><XY>` with `L=s`, and
  this is the only committed artifact that pins that spelling. Its CPU column is
  `movl (x),%eax` / `mfence` / `movl (x),%ebx`.
