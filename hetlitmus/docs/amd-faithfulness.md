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

The source gate sweeps all 644 renders — 173 gpu-only + 471 x86_64 het — because
its defect class is per test: a right builtin in one render says nothing about
the next. It then sweeps two synthetic carriers, `F-acqrel-sys` (`f[acq_rel,sys]`)
and `F-relaxed-sys` (`f[relaxed,sys]`): no corpus test carries either fence
annotation, so they are the only renders through which `HipLang.ml`'s `acq_rel`
row and its relaxed-fence arm are read.

> Every count in this document names its corpus. The het half of the AMD lane is
> the **x86_64** rendering that `hetlitmus/tests/het/generate-x86.sh` writes on
> demand, not the AArch64 471 `ptxcheck.py` reads: same 471 shapes, different CPU
> column. It is deliberately not committed, so every run regenerates it.

## The HIP source gate (`hetlitmus/verify/hipsrccheck.py`)

### What it checks

The **mapping table is `HipLang.ml`'s own**, restated as the expected side rather
than re-derived: `relaxed/acquire/release/acq_rel/sc → __ATOMIC_*`
[`HipAtomicHeader`], [`D75917`]; `cta/gpu/sys →
__HIP_MEMORY_SCOPE_{WORKGROUP,AGENT,SYSTEM}` [`HipAtomicHeader`]; and, for
`__builtin_amdgcn_fence`'s second argument, `cta → "workgroup"`, `gpu →
"agent"`, `sys → ""`, where the *unnamed* scope is system scope and naming one
there would narrow the fence ([`AMDGPUUsage` "Memory Scopes"]).

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
`#END` markers, operands are read in litmus7's `%[x]` / `%w[x0]` spelling, a store
is the `movl` the column lowers to on an `int` location, `MFENCE`/`SFENCE`/`LFENCE`
keep their own spelling, and an immediate `MOV` into a register is *consumed* —
it materialises a value rather than touching memory. Every asm string literal is
read and each must be one instruction closed by the newline escape, so an
instruction spliced into a tested body as its own literal cannot hide.

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
every lane only the whitelisted device helpers of
`litmus/het-runtime/het_stress.h` may appear.

**Exit 2 vs exit 1.** Exit 2 is the completeness code and fires on anything the
gate has no model for: an unknown annotation, an unmapped `__ATOMIC_*` or
`__HIP_MEMORY_SCOPE_*` constant, an AMDHSA sync-scope string outside
`{workgroup, agent, ""}`, an x86_64 mnemonic or operand shape outside the table this
gate carries for litmus7's own X86_64 lowering, a kernel guard the lane plan
cannot be matched against, and an atomic-or-fence construct with no model. Exit 1 is a *known*
construct in the wrong place: an ordered diff of the lane's anchors. Exit 3 is
a gate error (a corpus that is missing, empty or short of its census; a worker
that died).

### How to run

```
# both corpora (173 gpu-only + 471 x86_64 het) + the 2 synthetic carriers; per-test table + a TALLY each
python3 hetlitmus/verify/hipsrccheck.py --all [--jobs N] [--gpu-dir D] [--x86-dir D]

# one test (emits the render itself), or a render already on disk
python3 hetlitmus/verify/hipsrccheck.py hetlitmus/tests/gpu-only/MP-sys-fence.litmus
python3 hetlitmus/verify/hipsrccheck.py TEST.litmus --hip-src F [--cpu-c F]

```

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

**HIP source gate** (`make hetlitmus-hipsrc`, base lane, no toolchain):

```
TALLY gpu-only: 173/173 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
TALLY x86_64 het: 471/471 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
TALLY synthetic carriers: 2/2 PASS
HIP SOURCE GATE: PASS -- gpu-only 173/173, x86_64 het 471/471 (the x86_64 rendering of the het corpus, not the AArch64 one) + 2/2 synthetic carriers
```

The sweep runs up to 12 workers (`--jobs`; the default is the CPU count, capped
at 12).

### Triage log

**The gate was 644/644 with zero reds on its first full run**, and no full run
recorded on this branch has reported an emitter mismatch. There is therefore no
red here that was an emitter finding, and none that had to be explained away.

What *was* found, by reviewing the checker rather than by running it, were
defects in the checker itself, each since repaired:

* a comment-only fence arm took its order and its scope from the comment and
  never asserted the order was relaxed, so a render whose real fence had been
  replaced by the no-op comment passed;
* an asm-literal parse matched only literals closed by a newline escape, so an
  instruction spliced in as its own unterminated literal was dropped silently;
* "the HIP path carries no inline assembly" was the premise of the whole
  source-level read and nothing asserted it;
* the gpu-only result stores were discarded unchecked, while `__out` is the only
  channel by which a gpu-only read reaches an outcome;
* the loop check asked textual span membership, which a guarded op walks straight
  through — it reads each line's guard chain now.

## Scope and limits

Each limit below is stated where it lives in the code, so it cannot be softened
in one place and kept in the other.

* **What `hipcc` makes of the emitted constants is UNVERIFIED.** AMD publishes
  no stable specified virtual ISA, and `AMDGPUUsage` spells the memory model
  once per GPU generation: six separate "Memory Model GFX*" sections with a
  code-sequence table each. A gate that read the generated code back against
  those tables would be only as generic as its per-generation lowering profile,
  and none is kept here. All 644 renders therefore rest on the source gate,
  which says which builtin, order and scope the emitter wrote — never what the
  compiler lowered them to.
* **The source gate's loop check is a source-level read**
  (`hipsrccheck.check_lane_loop`). What it establishes is that a lane's ops sit
  unguarded in the loop body with no jump able to skip them — not that they
  "run once per iteration", which no source-level read can establish.
* **An unknown construct is exit 2; a known construct in the wrong place is exit
  1** (the exit contract in `hipsrccheck.py`'s module docstring). Completeness and correctness are different verdicts
  on purpose: a gate that skipped what it did not recognize would be green on
  exactly the change that most needs a reader.

## Relation to the NVIDIA gate

[`faithfulness.md`](faithfulness.md) documents the NVIDIA pair (`ptxcheck.py`
via `tokens.sh`, `make hetlitmus-faithful`) over its own 644 renders — 173
gpu-only plus the **AArch64** het 471. The AMD lane's het 471 is the x86_64
rendering of the same shapes, so the two "471"s are different corpora and every
count on either side says which. `hipsrccheck.py` imports `ptxcheck.py` and
never modifies it: its `.litmus` parsers, its GPU mapping table and its lane
plan are the expected side here too.

One heads-up for a reader moving between the two documents: **a multiset is a
localizer wherever an ordered comparison already covers the same stream**, and
both gates are written that way. An order-blind multiset test is strictly weaker
than an ordered one, so on a green stream it can detect nothing — which is why
`ptxcheck.py`'s per-proc `Counter` comparison runs only after the ordered check
has failed (`ptxcheck.check_gpu`'s post-failure localizer, `faithfulness.md` item 2)
and so does the source gate's (`hipsrccheck.check_stream`).