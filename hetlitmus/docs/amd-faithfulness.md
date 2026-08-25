# AMD faithfulness: the HIP source gate

**Question answered:** does every emitted AMD harness carry *exactly* the memory
**order + scope + op-kind** its `.litmus` annotation specifies, in the HIP source
the emitter writes?

One gate answers it, and it answers the source half of the question:

```
.litmus annotation --(litmus7/HipLang)--> .hip  --(hipsrccheck.py)-->  the emitted
                                                 builtin, its constants, its
                                                 traceability comment, its operands
```

It launches no kernel and needs no AMD device. The NVIDIA twin of it is
[`faithfulness.md`](faithfulness.md) (`ptxcheck.py`, `tokens.sh`).

## Why the gate reads source, and what that leaves open

The CUDA side gets its faithfulness from a gate that reads *generated* code,
because `CudaLang` emits **inline PTX**: what the emitter writes is, token for
token, what the assembler sees. The HIP path has no inline assembly at all —
every memory primitive is a compiler-owned source construct
(`__hip_atomic_load/_store/_fetch_add`, `__builtin_amdgcn_fence`). That splits
the failure surface in two, and only the first half is gated:

* **The emitter picks the wrong builtin, order or scope.** This is a *per test*
  defect: a `release` store emitted as a relaxed one, a `sys` scope narrowed to
  `agent`, a fence dropped, a lane's ops out of column order. It is fully
  visible in the source, and reading the source needs no compiler and names no
  GPU generation — so the check that owns it runs on the CUDA-free lane over the
  whole corpus. That is **`hipsrccheck.py`**.
* **A right-looking builtin lowers to something narrower or weaker.** Nothing in
  this tree reads that back: **what `hipcc` makes of the emitted constants is
  UNVERIFIED.** "Scope and limits" below states what that costs and why no gate
  is kept for it.

The source gate sweeps both corpora entire — the gpu-only corpus and the het
corpus in its x86_64 rendering, at `verify/census.py`'s pins (`GPU_ONLY`,
`HET`) — because its defect class is per test: a right builtin in one render
says nothing about the next. It then sweeps the synthetic carriers
(`census.SYNTHETIC`), `F-acqrel-sys` (`f[acq_rel,sys]`) and `F-relaxed-sys`
(`f[relaxed,sys]`): no corpus test carries either fence annotation, so they are
the only renders through which `HipLang.ml`'s `acq_rel` row and its
relaxed-fence arm are read.

> Every count in this document names its corpus. The het half of the AMD lane is
> the **x86_64** rendering that `hetlitmus/tests/het/generate-x86.sh` writes into
> a temporary directory on every run (why its names match the committed corpus:
> `corpus-grid.md`, "(D) Matched two-sided") — not the AArch64 rendering
> `ptxcheck.py` reads: the same shapes, a different CPU column.

## The HIP source gate (`hetlitmus/verify/hipsrccheck.py`)

### What it checks

The **mapping table is `HipLang.ml`'s own**, restated as the expected side rather
than re-derived: `relaxed/acquire/release/acq_rel/sc → __ATOMIC_*`
[HipAtomicHeader], [D75917]; `cta/gpu/sys →
__HIP_MEMORY_SCOPE_{WORKGROUP,AGENT,SYSTEM}` [HipAtomicHeader]; and, for
`__builtin_amdgcn_fence`'s second argument, `cta → "workgroup"`, `gpu →
"agent"`, `sys → ""` — why the empty string, and why `"system"` is refused, is
stated once in [`hip-emitter.md`](hip-emitter.md) ("Fences").

Per proc (gpu-only) or per rendezvous-joining lane (het), the ops must appear in
`.litmus` column order, each as its mapped builtin, and each agreeing **three
ways** — with its constants, with its traceability comment, and with the
`.litmus` cell's own operands. The comment matters because a stream built from
the constants alone would let an edit to the comment pass unseen, and that
comment is the only thing tying an emitted call back to the column that produced
it. There are three comment shapes:

| shape | written for | example |
|---|---|---|
| leading `// w[o,s] <var> <value>` / `// r[o,s] <dst> <var>` | a store or a load | `// w[release,sys] x 1` |
| trailing `// f[o,s]` on the call | an emitted fence | `__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, ""); // f[sc,sys]` |
| `// f[relaxed,s] (relaxed fence = no-op; nothing emitted)` | a relaxed fence | nothing executable is emitted, so the comment is both the claim and the whole evidence — the gate accepts that form for `relaxed` and **for no other order**; the converse, an executable `__builtin_amdgcn_fence` with a relaxed order, is a completeness hard-fail (exit 2), since `HipLang` never writes one and `hipcc` rejects it |

On a het render it further asks, per lane:

* the **rendezvous arrival** — `_rdvG_P<n>[_n] = het_rdv_device(barrier, …, _cap_gpu)`,
  one per lane, whose own relaxed system-scope `__hip_atomic_fetch_add`/`__hip_atomic_load`
  live in `het_rdv.h` — followed by the **release jitter** `het_rdv_jitter`, then
* the **model ops** in column order, carrying the store values the `.litmus` writes,
* the **result stores** (one per read register, into iteration `_n`'s own buffer slot)
  and the completion bump on `_gpu_done`, and
* the **lane count** against the lane plan — a kernel with more or fewer
  rendezvous-joining lanes than the plan names is running something other than the
  test, and every per-lane compare below it would then be against the wrong lane.

The **x86_64 CPU half** is the `.litmus` CPU column's rendering, compared mnemonic
for mnemonic against the `_cpu.c` real-asm block that litmus7's own
`ASMLang.dump_fun` prints: the block is read between its `#START _litmus_P<n>` and
`#END` markers, operands are read in litmus7's `%[x]` / `%k[r]` spelling, a store
is the `movl` the column lowers to on an `int` location, and
`MFENCE`/`SFENCE`/`LFENCE` keep their own spelling. The vocabulary is closed on
both sides. The `.litmus` parser (`x86_ops_of_column`) accepts `MOV <imm>,(loc)`
as a store, `MOV (loc),<reg>` as a load, a bare fence mnemonic, and the bare `nop`
that `X86_CONSUMED` names as the one consumed mnemonic; the asm reader
(`x86_bodies`) accepts the `A_STORE` / `A_LOAD` shapes and the three fences.
Anything else on either side — an immediate `MOV` into a register included — is
a completeness hard-fail (exit 2), never a skipped cell. Every asm string literal
is read and each must be one instruction closed by the newline escape, so an
instruction spliced into a tested body as its own literal cannot hide.

The x86_64 column parser is this gate's own because `ptxcheck.cpu_ops_of_column`
reads the AArch64 mnemonics of the committed corpus; `ptxcheck.py` is imported
unmodified for everything else the two gates share — the `.litmus` body parser,
the GPU mapping table and the lane plan.

The **loop structure** is checked because it is placement no anchor stream can
see: a het lane's ops must sit *unguarded* in the body of one `#pragma unroll 1`
loop over `SIZE_OF_TEST` (`litmus/hetEmit.ml`), with no `break`/`continue`/
`goto`/`return` able to skip them — and the rendezvous and its jitter must sit
*inside* it, ahead of every tested op, because a copy lifted out of the loop joins
the two devices once and leaves every iteration after the first unsynchronised.
What is emitted once per lane is the completion bump alone. The gpu-only path has
no such loop by design (`litmus/gpuLang.ml` `dump_test` emits each proc's ops once).

Finally the **stray rule**: inside a lane every access is accounted for by an
anchor, so any further atomic-, fence- or asm-shaped token — `asm`/`__asm__`
included, since "the HIP path carries no inline assembly" is the premise the
whole source-level read rests on — and any `volatile` access is refused. Outside
every lane only the whitelisted device helpers (`hipsrccheck.py`'s
`DEVICE_HELPERS`: `litmus/het-runtime/het_stress.h`'s scaffolding plus
`het_rdv.h`'s `het_rdv_device`/`het_rdv_jitter`) may appear.

**Exit 2 vs exit 1.** Exit 2 is the completeness code and fires on anything the
gate has no model for: an unknown annotation, an unmapped `__ATOMIC_*` or
`__HIP_MEMORY_SCOPE_*` constant, an AMDHSA sync-scope string outside
`{workgroup, agent, ""}`, an x86_64 mnemonic or operand shape outside the table this
gate carries for litmus7's own X86_64 lowering, a kernel guard the lane plan
cannot be matched against, and an atomic-or-fence construct with no model. Exit 1
is a *known* construct in the wrong place: an ordered diff of the lane's anchors.
Exit 3 is a gate error: a corpus directory that is missing or short of its
census, a generator or an emission that failed. Inside a sweep a test whose own
check raised is the `ERROR` column of its TALLY, and the gate exits 1 on it.

### How to run

```
# both corpora at verify/census.py's pins (the het half regenerated by generate-x86.sh
# into a temporary directory) + the synthetic carriers; per-test table + a TALLY each
python3 hetlitmus/verify/hipsrccheck.py --all [--jobs N] [--gpu-dir D] [--x86-dir D]

# one test (emits the render itself), or a render already on disk
python3 hetlitmus/verify/hipsrccheck.py hetlitmus/tests/gpu-only/MP-sys-fence.litmus
python3 hetlitmus/verify/hipsrccheck.py TEST.litmus --hip-src F [--cpu-c F]

```

`--all` asserts both censuses before a single test runs — a corpus that is
missing or short is refused (exit 3), never swept as if it were the whole one —
and `--x86-dir` names an x86_64 corpus to sweep in place of regenerating one.
`--hip-src F` reads a render on disk instead of emitting one; without `--cpu-c`,
the `<name>_cpu.c` beside it is read when present.

`make hetlitmus-hipsrc` runs `--all`. It is on the **base lane**
(`hetlitmus-test`): it emits with `litmus7` and reads text, so it needs neither
`hipcc` nor a device.

### What it does not prove

Nothing about what a compiler makes of those constructs: no ISA is read, no code
is generated, no kernel runs. It is also a parser of the `.litmus` CPU column's
*rendering* only — the per-iteration `clflush`/`prefetcht0` preload touches the
same locations and is outside its vocabulary by design
(`litmus/het-runtime/het_cpu_stress.h`).

## Results

The gate reads text and runs no compiler, so nothing below is pinned to a
toolchain version.

**HIP source gate** (`make hetlitmus-hipsrc`, base lane, no toolchain), with
`<GPU_ONLY>`, `<HET>` and `<SYNTHETIC>` standing for `verify/census.py`'s pins:

```
===== HIP SOURCE GATE: <GPU_ONLY> gpu-only + <HET> x86_64 het renders + <SYNTHETIC> synthetic carriers =====
...
TALLY gpu-only: <GPU_ONLY>/<GPU_ONLY> PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
...
TALLY x86_64 het: <HET>/<HET> PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
...
TALLY synthetic carriers: <SYNTHETIC>/<SYNTHETIC> PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)

HIP SOURCE GATE: PASS -- gpu-only <GPU_ONLY>/<GPU_ONLY>, x86_64 het <HET>/<HET> (the x86_64 rendering of the het corpus, not the AArch64 one) + <SYNTHETIC>/<SYNTHETIC> synthetic carriers
```

Each corpus and the carriers print as one `sweep_dir` table (`===== HIP source
faithfulness: <label> =====`, one row per test) closed by its TALLY line; every
non-PASS row's output is echoed and saved.

The sweep runs up to 12 workers (`JOBS_CAP`; `--jobs` overrides, and the default
is the CPU count capped there).

## Scope and limits

Each limit below is stated where it lives in the code, so it cannot be softened
in one place and kept in the other.

* **What `hipcc` makes of the emitted constants is UNVERIFIED.** AMD publishes
  no stable specified virtual ISA, and `AMDGPUUsage` spells the memory model
  once per GPU generation: six separate "Memory Model GFX*" sections with a
  code-sequence table each. A gate that read the generated code back against
  those tables would be only as generic as its per-generation lowering profile,
  and none is kept here. Every render therefore rests on the source gate,
  which says which builtin, order and scope the emitter wrote — never what the
  compiler lowered them to.
* **The source gate's loop check is a source-level read**
  (`hipsrccheck.check_lane_loop`). What it establishes is that a lane's ops sit
  unguarded in the loop body with no jump able to skip them — not that they
  "run once per iteration", which no source-level read can establish.
* **An unknown construct is exit 2; a known construct in the wrong place is exit
  1** (the exit contract in `hipsrccheck.py`'s module docstring). Completeness
  and correctness are different verdicts on purpose: a gate that skipped what it
  did not recognize would be green on exactly the change that most needs a
  reader.

## Relation to the NVIDIA gate

[`faithfulness.md`](faithfulness.md) documents the NVIDIA pair (`ptxcheck.py`
via `tokens.sh`, `make hetlitmus-faithful`) over its own renders: the gpu-only
corpus and the **AArch64** rendering of the het corpus. The AMD lane's het half
is the x86_64 rendering of the same shapes, so the two het censuses are the same
number (`census.HET`) over two different renderings, and every count on either
side says which. `hipsrccheck.py` imports `ptxcheck.py` and never modifies it:
its `.litmus` body parser, its GPU mapping table and its lane plan are the
expected side here too; only the CPU-column parser is this gate's own ("What it
checks").

One heads-up for a reader moving between the two documents: **a multiset is a
localizer wherever an ordered comparison already covers the same stream.** An
order-blind multiset test is strictly weaker than an ordered one, so on a green
stream it can detect nothing. `hipsrccheck.check_stream` keeps one as a
post-failure localizer — it runs only after the ordered compare has failed, and
says whether the lane carries the right anchors in the wrong order or which
anchors the two multisets differ by — while `ptxcheck.check_gpu` prints the
positional diff alone.
