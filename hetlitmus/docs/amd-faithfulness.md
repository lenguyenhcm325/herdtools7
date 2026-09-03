# AMD faithfulness: the HIP source mapping

**The property:** every emitted AMD harness carries exactly the memory
**order + scope + op kind** its `.litmus` annotation specifies, in the HIP
source `HipLang` writes: the builtin, its constants, its comment and its
operands. It is stated on the source alone, with no AMD device and no
compiler. The
NVIDIA twin, stated on the PTX, is [`faithfulness.md`](faithfulness.md); it
covers the gpu-only corpus and the AArch64 rendering of the het corpus, this
document the same gpu-only corpus and the **x86_64** rendering: one set of
shapes over two CPU renderings.

## Why faithfulness is stated at source level

The HIP path carries no inline assembly: every memory primitive is a
compiler-owned construct (`__hip_atomic_load`/`_store`,
`__builtin_amdgcn_fence`). That splits the failure surface in two, and only
the first half is visible in this tree:

* the emitter writes the wrong builtin, order, scope or operand, drops an op
  or reorders a lane — a per-test defect, fully visible in the source;
* a right-looking builtin lowers to something narrower or weaker — what
  `hipcc` makes of the emitted constants is UNVERIFIED ("Scope and limits").

Because the defect class is per test, the property is stated over the whole
AMD lane: the gpu-only corpus, and the het corpus in the x86_64 rendering
that `hetlitmus/tests/het/generate-x86.sh OUTDIR` writes on demand (its
names match the committed corpus: `corpus-grid.md`, "(D) Matched two-sided").

## The mapping

Each op appears in `.litmus` column order as its mapped builtin, agreeing
with its constants, its comment and the cell's operands. The comment is the
only tie from an emitted call back to the column that produced it: a store
or load carries a leading `// w[o,s] <var> <value>` / `// r[o,s] <dst> <var>`,
a fence a trailing `// f[o,s]`.

A het lane's body is one `#pragma unroll 1` loop over `SIZE_OF_TEST`
(`litmus/hetGpuFile.ml`) carrying, in order: the pre-stress call; the
rendezvous arrival `het_rdv_device`, whose relaxed system-scope
`__hip_atomic_fetch_add`/`__hip_atomic_load` live in `het_rdv.h`; the release
jitter; the model ops; the result stores; and in the lane at `(0,0)` alone
the `_gpu_iter` bump. No jump can skip the ops, and nothing is
emitted outside the loop: a rendezvous lifted out would join the devices once
and leave every later iteration unsynchronised, and `SIZE_OF_TEST` is a
compile-time constant, so the pragma is what keeps one copy of the tested ops
in the body. The gpu-only path has no loop (`litmus/gpuLang.ml`, `dump_test`
emits each proc's ops once).

Inside a lane every access is one of the above: no other atomic-, fence- or
asm-shaped token (the no-inline-assembly premise) and no `volatile` access.
Outside the lanes only the device helpers of `het_stress.h` and `het_rdv.h`
appear, plus the `__syncthreads()` the stress and noise blocks broadcast the
iteration clock across (`00-environment-design.md` §3.3); inside a lane it
would be a barrier a test block reaches.

The x86_64 CPU half is the column as litmus7 prints it (`ASMLang.dump_fun`,
between `#START _litmus_P<n>` and `#END`, operands in `%[x]`/`%k[r]`
spelling): `MOV <imm>,(loc)` is a store, `movl` on an `int` location,
`MOV (loc),<reg>` a load, and a bare `MFENCE` a fence.

## Scope and limits

* **What `hipcc` makes of the emitted constants is UNVERIFIED.**
  [AMDGPUUsage] spells the memory model per GPU generation (one "Memory
  Model GFX*" section and code-sequence table each) and no per-generation
  lowering profile is kept here, so a render says which builtin, order and
  scope the emitter wrote, never what the compiler lowered them to.
* **The loop placement is a source-level statement.** A lane's ops sit
  unguarded in the loop body with no jump able to skip them; that they run
  once per iteration is not something a source read establishes.
* **The CPU half is the column's rendering only.** The per-iteration
  `clflush`/`prefetcht0` preload touches the same locations outside the
  column (`litmus/het-runtime/het_cpu_stress.h`).
* An `f[relaxed,·]` is refused before rendering
  ([`het-emission.md`](het-emission.md), "Scope / limits").
