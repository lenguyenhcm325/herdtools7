# AMD faithfulness: the HIP source mapping

**Question answered:** does every emitted AMD harness carry *exactly* the memory
**order + scope + op-kind** its `.litmus` annotation specifies, in the HIP source
the emitter writes?

For AMD the question is answered at the level of the emitted source, and only
there:

```
.litmus annotation --(litmus7/HipLang)--> .hip : the emitted builtin, its constants,
                                                 its traceability comment, its operands
```

Stating it launches no kernel and needs no AMD device. The NVIDIA twin of this
document is [`faithfulness.md`](faithfulness.md).

## Why faithfulness is stated at source level, and what that leaves open

The CUDA side states its faithfulness on *generated* code, because `CudaLang`
emits **inline PTX**: what the emitter writes is, token for token, what the
assembler sees. The HIP path has no inline assembly at all — every memory
primitive is a compiler-owned source construct
(`__hip_atomic_load/_store/_fetch_add`, `__builtin_amdgcn_fence`). That splits
the failure surface in two, and only the first half is visible in this tree:

* **The emitter picks the wrong builtin, order or scope.** This is a *per test*
  defect: a `release` store emitted as a relaxed one, a `sys` scope narrowed to
  `agent`, a fence dropped, a lane's ops out of column order. It is fully
  visible in the source, and reading the source needs no compiler and names no
  GPU generation.
* **A right-looking builtin lowers to something narrower or weaker.** Nothing in
  this tree reads that back: **what `hipcc` makes of the emitted constants is
  UNVERIFIED.** "Scope and limits" below states what that costs.

Because the defect class is per test — a right builtin in one render says
nothing about the next — the statement is made over both corpora of the AMD
lane entire: the gpu-only corpus and the het corpus in its x86_64 rendering.

> The het half of the AMD lane is the **x86_64** rendering that
> `hetlitmus/tests/het/generate-x86.sh OUTDIR` writes on demand (why its names
> match the committed corpus: `corpus-grid.md`, "(D) Matched two-sided") — not
> the committed AArch64 rendering: the same shapes, a different CPU column.

## The mapping

The mapping is `HipLang.ml`'s own: `relaxed/acquire/release/acq_rel/sc →
__ATOMIC_*` [HipAtomicHeader], [D75917]; `cta/gpu/sys →
__HIP_MEMORY_SCOPE_{WORKGROUP,AGENT,SYSTEM}` [HipAtomicHeader]; and, for
`__builtin_amdgcn_fence`'s second argument, `cta → "workgroup"`, `gpu →
"agent"`, `sys → ""` — why the empty string, and why `"system"` is refused, is
stated once in [`hip-emitter.md`](hip-emitter.md) ("Fences").

Per proc (gpu-only) or per rendezvous-joining lane (het), the ops appear in
`.litmus` column order, each as its mapped builtin, and each agreeing **three
ways** — with its constants, with its traceability comment, and with the
`.litmus` cell's own operands. The comment is the only thing tying an emitted
call back to the column that produced it. There are two comment shapes:

| shape | written for | example |
|---|---|---|
| leading `// w[o,s] <var> <value>` / `// r[o,s] <dst> <var>` | a store or a load | `// w[release,sys] x 1` |
| trailing `// f[o,s]` on the call | an emitted fence | `__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, ""); // f[sc,sys]` |

On a het render each lane carries, in this order:

* the **rendezvous arrival** — `_rdvG_P<n>[_n] = het_rdv_device(barrier, …, _cap_gpu)`,
  one per lane, whose own relaxed system-scope `__hip_atomic_fetch_add`/`__hip_atomic_load`
  live in `het_rdv.h` — followed by the **release jitter** `het_rdv_jitter`, then
* the **model ops** in column order, carrying the store values the `.litmus` writes,
* the **result stores** (one per read register, into iteration `_n`'s own buffer slot)
  and the completion bump on `_gpu_done`.

The **x86_64 CPU half** is the `.litmus` CPU column's rendering: the `_cpu.c`
real-asm block that litmus7's own `ASMLang.dump_fun` prints between its
`#START _litmus_P<n>` and `#END` markers, its operands in litmus7's `%[x]` /
`%k[r]` spelling, a store the `movl` the column lowers to on an `int` location,
and `MFENCE`/`SFENCE`/`LFENCE` in their own spelling. The column vocabulary is
closed: `MOV <imm>,(loc)` is a store, `MOV (loc),<reg>` a load, and a bare fence
mnemonic a fence. Every asm string literal is one instruction closed by the
newline escape.

In a het render a lane's ops sit *unguarded* in the body of one `#pragma unroll
1` loop over `SIZE_OF_TEST` (`litmus/hetGpuFile.ml`), with no `break`/`continue`/
`goto`/`return` able to skip them — and the rendezvous and its jitter sit
*inside* it, ahead of every tested op, because a copy lifted out of the loop joins
the two devices once and leaves every iteration after the first unsynchronised.
`SIZE_OF_TEST` is a compile-time constant, so without the pragma the compiler
unrolls the loop and the lane body carries many copies of the tested
instructions — not the program the `.litmus` names.
What is emitted once per lane is the completion bump alone. The gpu-only path has
no such loop by design (`litmus/gpuLang.ml` `dump_test` emits each proc's ops once).

Inside a lane every access is one of the above: the emission carries no further
atomic-, fence- or asm-shaped token — `asm`/`__asm__` included, since "the HIP
path carries no inline assembly" is the premise the whole source-level statement
rests on — and no `volatile` access. Outside every lane only the device helpers
appear: `litmus/het-runtime/het_stress.h`'s scaffolding plus `het_rdv.h`'s
`het_rdv_device`/`het_rdv_jitter`.

## Scope and limits

* **What `hipcc` makes of the emitted constants is UNVERIFIED.** AMD publishes
  no stable specified virtual ISA, and `AMDGPUUsage` spells the memory model
  once per GPU generation: six separate "Memory Model GFX*" sections with a
  code-sequence table each. A reading of the generated code back against those
  tables would be only as generic as its per-generation lowering profile, and
  none is kept here. Every render therefore rests on its source, which says
  which builtin, order and scope the emitter wrote — never what the compiler
  lowered them to.
* **The loop placement is a source-level statement.** What it establishes is
  that a lane's ops sit unguarded in the loop body with no jump able to skip
  them — not that they "run once per iteration", which no source-level read can
  establish.
* **The CPU half is the `.litmus` CPU column's rendering only.** The
  per-iteration `clflush`/`prefetcht0` preload touches the same locations and is
  outside that column by design (`litmus/het-runtime/het_cpu_stress.h`).
* **No corpus test carries an `f[acq_rel,·]` annotation**, so `HipLang.ml`'s
  `acq_rel` row is reached by no corpus render. An `f[relaxed,·]` is not a gap
  in the corpus but a form litmus7 refuses
  ([`het-emission.md`](het-emission.md), "Scope / limits").

## Relation to the NVIDIA mapping

[`faithfulness.md`](faithfulness.md) documents the NVIDIA pair over its own
renders: the gpu-only corpus and the **AArch64** rendering of the het corpus.
The AMD lane's het half is the x86_64 rendering of the same shapes, so the two
het corpora are one set of shapes over two different CPU renderings, and every
statement on either side says which.
