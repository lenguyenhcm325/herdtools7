# AMD faithfulness: the HIP source gate and the ISA read-back gate

**Question answered:** does every emitted AMD harness carry *exactly* the memory
**order + scope + op-kind** its `.litmus` annotation specifies — in the HIP
source the emitter writes, and in the gfx942 instructions `hipcc` makes of it?

Two gates answer it, and they answer different halves:

```
.litmus annotation --(litmus7/HipLang)--> .hip  --(hipsrccheck.py)-->  the emitted
                                                 builtin, its constants, its
                                                 traceability comment, its operands

                   --(hipcc -S)---------> gfx942 ISA --(amdisacheck.py, through a
                                                 per-generation lowering profile)-->
                                                 abstract token stream
```

Neither launches a kernel; neither needs an AMD device. The NVIDIA twin of the
pair is [`faithfulness.md`](faithfulness.md) (`ptxcheck.py`, `tokens.sh`).

## Why two gates

The CUDA side gets its faithfulness from one check because `CudaLang` emits
**inline PTX**: what the emitter writes is, token for token, what the assembler
sees. The HIP path has no inline assembly at all — every memory primitive is a
compiler-owned source construct (`__hip_atomic_load/_store/_fetch_add`,
`__builtin_amdgcn_fence`). That splits the failure surface in two, and the two
halves need different instruments:

* **The emitter picks the wrong builtin, order or scope.** This is a *per test*
  defect: a `release` store emitted as a relaxed one, a `sys` scope narrowed to
  `agent`, a fence dropped, a lane's ops out of column order. It is fully
  visible in the source, and reading the source needs no compiler and names no
  GPU generation — so the check that owns it runs on the CUDA-free lane over the
  whole corpus. That is **`hipsrccheck.py`**.
* **A right-looking builtin lowers to something narrower or weaker.** This is a
  *per (kind, order, scope) row* defect: one row of the AMDGPU memory model
  lowering to fewer cache operations than the model asks for is the same defect
  in every test that annotates it, so one compiled representative of a row is as
  informative as 644 of them. It is invisible in the source and needs the real
  toolchain. That is **`amdisacheck.py`**.

Both nevertheless sweep all 644 renders — 173 gpu-only + 471 x86_64 het — because
a per-row argument bounds what a *new* defect can be, not what the corpus
already contains, and because the sweep is cheap enough (below) that
representative-only coverage would buy nothing.

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

Per proc (gpu-only) or per barrier-joining lane (het), the ops must appear in
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
| `// f[relaxed,s] (relaxed fence = no-op; nothing emitted)` | a relaxed fence | nothing executable is emitted, so the comment is both the claim and the whole evidence — the gate accepts that form for `relaxed` and **for no other order** |

On a het render it further asks, per lane:

* the **rendezvous** arrive (`__hip_atomic_fetch_add`, `sc`, `sys`, on the shared
  barrier word, incrementing by 1) and its spin, then
* the **window-opener** `het_spin` on the device-scope spin word,
* the **model ops** in column order,
* the **tagged store values**, derived from `hetEmit.ml`'s own plan rather than
  matched for shape: `mu` runs over the instance's stores (procs in index order,
  stores in column order) and `K` is one past the last, and the numbering is
  shared with the CPU column, so either side gaining a store moves every later
  tag,
* the **result stores** (one per read register) and the completion bump on
  `_gpu_done`,
* an **observer** lane's snoops, one per location it watches, recorded into that
  location's own buffer,
* the **per-instance alias binding**: a co-run harness embeds `T`, its `mu(T)`
  and its canary, and where the map names the same sibling twice the instances
  are told apart by a label, not by name, so an alias bound to another instance's
  global fails, and
* the **lane count** against the lane plan — a missing lane on a control instance
  means the harness reports a positive control it is not running.

The **x86_64 CPU half** is the `.litmus` CPU column's rendering, compared mnemonic
for mnemonic against the tagged asm bodies of the `_cpu.c` real-asm block: a
`MOV` is classified by its operand shape and widens to the emitted `movq` (an
aligned 8-byte access is one access, [`IntelSDM`]), `MFENCE`/`SFENCE`/`LFENCE`
keep their own spelling, and an immediate `MOV` into a register is *consumed* —
the runtime tag replaces the value it set. Every asm string literal is read and
each must be one instruction closed by the newline escape, so an instruction
spliced into a tested body as its own literal cannot hide.

The **loop structure** is checked because it is placement no anchor stream can
see: a het lane's ops must sit *unguarded* in the body of one `#pragma unroll 1`
loop over `SIZE_OF_TEST` (`litmus/hetEmit.ml`), with no `break`/`continue`/
`goto`/`return` able to skip them; the rendezvous and the completion bump must
sit *outside* it, since a rendezvous dragged in is a cross-device barrier around
every tested access. Only the window-opener spin may be guarded, and only by the
barrier roll the emitter writes around it. The gpu-only path has no such loop by
design (`litmus/gpuLang.ml` `dump_test` emits each proc's ops once).

Finally the **stray rule**: inside a lane every access is accounted for by an
anchor, so any further atomic-, fence- or asm-shaped token — `asm`/`__asm__`
included, since "the HIP path carries no inline assembly" is the premise the
whole source-level read rests on — and any `volatile` access is refused. Outside
every lane only the whitelisted device helpers of
`litmus/het-runtime/het_stress.h` may appear.

**Exit 2 vs exit 1.** Exit 2 is the completeness code and fires on anything the
gate has no model for: an unknown annotation, an unmapped `__ATOMIC_*` or
`__HIP_MEMORY_SCOPE_*` constant, an AMDHSA sync-scope string outside
`{workgroup, agent, ""}`, an x86_64 mnemonic or operand shape outside
`hetCpuBodyX86`'s own arms, a kernel guard the lane plan cannot be matched
against, an atomic-or-fence construct with no model, and a control map that is
absent, differently headed or has no row for the test. Exit 1 is a *known*
construct in the wrong place: an ordered diff of the lane's anchors. Exit 3 is
a gate error (a corpus that is missing, empty or short of its census; a worker
that died).

### How to run

```
# both corpora (173 gpu-only + 471 x86_64 het), per-test table + a TALLY per corpus
python3 hetlitmus/verify/hipsrccheck.py --all [--jobs N] [--gpu-dir D] [--x86-dir D]

# one test (emits the render itself), or a render already on disk
python3 hetlitmus/verify/hipsrccheck.py hetlitmus/tests/gpu-only/MP-sys-fence.litmus
python3 hetlitmus/verify/hipsrccheck.py TEST.litmus --hip-src F [--cpu-c F]

# the vocabulary and the paths it resolves; an empty table or a missing path fails
python3 hetlitmus/verify/hipsrccheck.py --guard

# every check reddened on a fresh render
python3 hetlitmus/verify/hipsrccheck.py --bite
```

`make hetlitmus-hipsrc` runs `--all` then `--bite`. It is on the **base lane**
(`hetlitmus-test`): it emits with `litmus7` and reads text, so it needs neither
`hipcc` nor a device.

`--guard` prints both mapping tables, the three comment shapes, the x86_64
operand shapes, the het lane anchors, the loop vocabulary, the device-helper
whitelist, the two stray-construct vocabularies by region, and the exit
contract. `--bite` emits two pristine renders — a gpu-only shape carrying both
fences, both kinds of model op and two `__out` slots, and the het co-run carrying
`T`, `mu(T)`, the canary, two observer lanes and a tagged CPU column with an
`MFENCE` — runs both clean, then makes each injection on a fresh copy. It
defends itself three ways, each seen to fire: an injection whose anchor is absent
hard-exits, one that changes no byte is a vacuous bite, and an assertion nothing
prints is a wrong reason.

### What it does not prove

Nothing about what a compiler makes of those constructs: no ISA is read, no code
is generated, no kernel runs. It is also a parser of the `.litmus` CPU column's
*rendering* only — the per-iteration `clflush`/`prefetcht0` preload and the CPU
observer's plain volatile read touch the same locations and are outside its
vocabulary by design (`litmus/het-runtime/het_cpu_stress.h`).

## The ISA read-back gate (`hetlitmus/verify/amdisacheck.py`)

### Why reading `hipcc -S` is sound

* **Spatially.** Every token is attributed to the kernel's own mangled symbol,
  whose name is derived from the test name; a second `@function` symbol in the
  output — a device helper the compiler did not inline, whose instructions would
  belong to no lane — is a refusal, not a skipped region.
* **For membership.** Every bit-carrying access and cache operation inside that
  symbol is either matched to an expected token or sits in an unmatched block
  that holds loads only. A mnemonic in the profile's memory family that the
  profile cannot classify is exit 2 rather than a silent drop.
* **For order.** The token order inside a basic block is the emitted order.
  A reorder of two model ops is **machine-scheduler-excluded** — an ordered
  memory operand makes the instruction the scheduler's barrier chain, and the
  AMDGPU override of that hook exempts only IGLP pseudo-ops, which a litmus
  kernel never carries [`LLVMSched`] — **IR-optimizer-unverified**, since nothing
  here bounds a mid-level pass, and **probe-unobserved**. It is never stated as a
  probability.
* **Against the object that ships.** `-S` is not what the harness links, so two
  reps per run are cross-checked: the same render is built with
  `hipcc --genco`, the device bundle unpacked with `clang-offload-bundler`, and
  the ELF disassembled with `llvm-objdump -d --mcpu=gfx942`; the flat token
  streams of the two routes must be identical. A disassembly carries neither
  block labels nor assembler directives, so it bounds `-S` against the shipped
  encoding and nothing else.

The compile itself is the flags the harness ships with — the emitted `comp.sh`
runs `hipcc --offload-arch=gfx942 -std=c++17 -c <test>.hip` — plus
`--offload-device-only -S`, which turns that compile into readable device text
and is the only addition. Reading a different flag set would leave the gate
checking another program.

### The gfx942 lowering profile

Every gfx942 literal in the file lives inside one `LoweringProfile` object.
Its rows are read off the **"AMDHSA Memory Model Code Sequences GFX942"** table
of [`AMDGPUUsage`], each keyed by its line in that section's source (a living
document: the section *name* is the durable locator, the line is where it was
read):

| annotation | token sequence | [`AMDGPUUsage` "AMDHSA Memory Model Code Sequences GFX942"] |
|---|---|---|
| `ld[relaxed,cta]` | `[ld(cta)]` | `:11321` |
| `ld[relaxed,gpu]` | `[ld(gpu)]` | `:11328` |
| `ld[relaxed,sys]` | `[ld(sys)]` | `:11330` |
| `ld[acquire,cta]` | `[ld(cta)]` | `:11361` |
| `ld[acquire,gpu]` | `[ld(gpu) wait inv(gpu)]` | `:11436` |
| `ld[acquire,sys]` | `[ld(sys) wait inv(sys)]` | `:11460` |
| `st[relaxed,cta]` | `[st(cta)]` | `:11334` |
| `st[relaxed,gpu]` | `[st(gpu)]` | `:11336` |
| `st[relaxed,sys]` | `[st(sys)]` | `:11338` |
| `st[release,cta]` | `[st(cta)]` | `:11969` |
| `st[release,gpu]` | `[wbl2(gpu) st(gpu)]` | `:12008` |
| `st[release,sys]` | `[wbl2(sys) st(sys)]` | `:12064` |
| `fence[sc,cta]` | `[]` — nothing at all | `:12934` |
| `fence[sc,gpu]` | `[wbl2(gpu) wait inv(gpu)]` | `:13044` |
| `fence[sc,sys]` | `[wbl2(sys) wait inv(sys)]` | `:13148` |
| `fence[acquire,sys]` | `[wait inv(sys)]` | `:11886` |
| `fence[release,sys]` | `[wbl2(sys)]` | `:12392` |
| `ld[sc,sys]` (scaffolding) | `[ld(sys) wait inv(sys)]` | `:13354` |
| `rmw[relaxed,gpu]` (scaffolding) | `[atomic(gpu,ret)]` | `:11345` |
| `rmw[sc,sys]` (scaffolding) | `[wbl2(sys) atomic(sys) wait inv(sys)]` | `:12690` |
| `vld[-,sys]` (a volatile non-atomic access, system-coherent by the table) | `[ld(sys)]` | `:11254` |

The width class is elided above because it is a parameter: the same row is taken
at 32 bits on the gpu-only path and at 64 on the het path, and `--guard` prints
it (`ld32(sys)`, `ld64(sys)`).

Seventeen of those rows are the ones the corpus annotates; the other four are the
orders the runtime scaffolding asks for. The table spells a seq_cst RMW as the
acq_rel RMW of the same scope (`:13452`) and a seq_cst fence as the acq_rel fence
(`:13457`), while a seq_cst load is the acquire load of the same scope behind a
leading wait (`:13354`) that the filter drops with the rest of the glue. An
annotation the profile has **no** row for — an RMW at an unmodelled order,
`f[acq_rel,*]` — is exit 2 naming it, never a comparison against nothing.

Four facts about this generation shape everything above:

* **The atomic asymmetry.** A cache-bit set is a scope — `sc0` workgroup, `sc1`
  agent, both system, none no scope at all — *except on an atomic*, which spends
  `sc0` on "returns the original value" and keeps only `sc1` for scope (`:11154`).
  So a discarded agent-scope RMW carries no bits at all, and workgroup and agent
  are indistinguishable on an RMW.
* **The workgroup (cta) degeneracy.** At workgroup scope the ordering rows
  collapse: `ld[relaxed,cta]` and `ld[acquire,cta]` are the same instruction, so
  are `st[relaxed,cta]` and `st[release,cta]`, and `fence[sc,cta]` emits nothing.
  Their waits and invalidates are the TgSplit branch of the table, which
  `.amdhsa_tg_split 0` excludes.
* **The narrow wait pinning.** A row carries a `wait` token **only** where the
  table requires a wait immediately before an invalidate. Every other wait the
  compiler emits is glue whose mask and position it decides, and no waitcnt mask
  is ever compared. The row-required wait is read off the *unfiltered* token
  stream, so traffic the scope filter drops still separates it from the
  invalidate and the row stops matching.
* **The preconditions**, asserted on every render before its rows mean anything:

  | directive | value | why a violation is a refusal |
  |---|---|---|
  | `.amdgcn_target` | `"amdgcn-amd-amdhsa--gfx942"` | the assembly was generated for another target |
  | `.amdhsa_code_object_version` | `6` | the kernel descriptor has another layout |
  | `.amdhsa_tg_split` | `0` | TgSplit execution mode selects the *other* branch of every workgroup row, adding a wait and an invalidate this profile does not carry |

  `.amdhsa_tg_split` is emitted only for targets carrying the `tgsplit-support`
  feature ([`AMDGPUUsage` "LLVM IR Attributes", the `"amdgpu-tg-split"` row;
  `:2624` in the source the profile was read from]), which is why the
  precondition list is a profile datum rather than a machinery constant.

The **scaffolding signatures** — what a het lane runs around its model ops, as
the `(kind, order, scope, returns)` the runtime source asks for, each turned into
tokens by the same rows:

| scaffolding | asks for | lowers to |
|---|---|---|
| rendezvous arrive (`gd_bar`) | `rmw[sc,sys]` | `[wbl2(sys) atomic(sys) wait inv(sys)]` |
| rendezvous spin | `ld[sc,sys]` | `[ld(sys) wait inv(sys)]` |
| window-opener arrive (`het_spin`) | `rmw[relaxed,gpu]`, returning | `[atomic(gpu,ret)]` |
| window-opener poll | `ld[relaxed,gpu]` | `[ld(gpu)]` |
| observer snoop (`gd_sys_load_u64`) | `ld[relaxed,sys]` | `[ld(sys)]` |
| folded counter read (`het_scratch_read`) | `ld[relaxed,gpu]` | `[ld(gpu)]` |
| discarded counter RMW (`het_scratch_bump`/`_max`) | `rmw[relaxed,gpu]`, discarded | `[atomic(-)]` |
| interconnect-noise read | `vld[-,sys]` | `[ld(sys)]` |

### The machinery / profile split, and why

AMD spells its memory model **once per GPU generation**: `AMDGPUUsage` carries
six separate "Memory Model GFX*" sections with a code-sequence table each, and
only `gfx942` has a profile here. HetLitmus is meant for the *next*
heterogeneous machine, so the split is structural, not stylistic:

* **the profile** owns the mnemonic classes, the cache-bit vocabulary and the
  scope each bit set names, the code-sequence rows, the assembler-directive
  preconditions and the bite mutations;
* **the machinery** emits, compiles, checks the profile's declared
  preconditions, attributes tokens to the kernel's symbol, splits basic blocks,
  filters, matches and counts — and holds no mnemonic, no cache bit and no
  directive of its own.

`--arch` selects a profile; an unknown target is exit 2 naming the section to
derive the next one from. A generation's target name is spelled inside its
profile and nowhere else; the target-name prefix (`gfx`) and the vendor's offload
bundle triple, which every AMD generation shares, are machinery.

### The abstract token

`Token(kind, width, scope, ret)`, where `kind` is `LD`/`ST`/`ATOMIC` (access),
`WBL2` (write the cache back), `INV` (invalidate) or `WAIT`.

* **`width` is a class, and it is emitter-owned rather than compiler-chosen.** A
  model location is one C object per path — `int*` on the gpu-only path
  (`litmus/gpuLang.ml`), `uint64_t*` on the het path so a store can carry its
  writer tag (`litmus/hetEmit.ml`) — and an atomic is never vectorized or split,
  so the width the compiler picks is the width the source names. The profile's
  classifier is what maps `global_load_dwordx2 → (LD, 64)`; a generation that
  spells widths differently changes only its profile.
* **`global_` vs `flat_` is never distinguished.** Which address-space form the
  compiler picks is its business; what an access *means* to the memory model is
  in its cache bits.
* **Registers, offsets and waitcnt masks are never compared.** Neither are the
  positions of blocks, since the compiler lays a lane's block where it likes.

### The rep set and the coverage tripwire

`--reps` is the fast mode: per `(kind, order, scope)` row present in the corpus
it takes the first carrier by test name (a gpu-only test preferred), then adds
one test per fixed het shape — a co-run trio with an observer lane, an IRIW with
more than one GPU proc, a system-scope seq_cst fence carrier, and the degenerate
test that is its own canary and runs a single lane. The set is **derived from the
corpus every run**, never pinned.

"First by name" is not stable under corpus growth, which is why the tripwire
re-reads the annotation rows **off the files** rather than off the rep builder's
own bookkeeping: a row the builder leaves without a carrier, a rep it drops and a
shape it files under the wrong test each fire. It also asks the profile for every
corpus row before a single compile runs, so a row the profile cannot lower is
refused once rather than on whichever rep reaches it first. The tripwire runs
inside `--all` too, off the same generated corpus.

### The two check shapes

A **gpu-only** kernel must account for every basic block that carries a token:
one block per proc, holding that column's model ops in column order, and no
unmatched block is tolerated at all.

A **het** kernel owes, per barrier-joining lane, the rendezvous arrival and its
spin; per test lane the window-opener's arrival, its poll and its model ops; per
observer lane its snoops. Matching is by ordered block *contents*, never by
position, and across all lanes it is therefore a **multiset equality**. An
unmatched block may then hold **loads only** (plus waits) — the tail policy,
which is what makes the interconnect-noise reader and the folded counter reads
legal without letting a store or a cache operation hide beside them.

A whole-kernel **token census** is the second, independent net over what the
block match cannot see — the counts inside tail blocks and every access the scope
filter drops:

* one result store per read register of a test lane and per location an observer
  lane snoops;
* the discarded counter RMWs, as a sum (the abstract token does not name the
  operation an RMW performs);
* two compiler *copy counts*, pinned exactly: **3** folded `het_scratch_read`
  copies (the read guarding both stress-round loops) and **2** volatile
  interconnect-noise loads. These are what this toolchain lays down, not
  memory-model figures;
* and the inlined stress body, pinned only as **positive and a whole number of
  copies** — `het_do_stress` is inlined once per test lane and once in the stress
  region, so its plain traffic is a multiple of that many copies. How many
  accesses one copy holds is a compiler and stress-body figure (18 loads and 8
  stores per copy here), so pinning the figure would redden the gate for a reason
  that is not faithfulness.

### How to run

```
# both corpora (173 gpu-only + 471 x86_64 het), + the tripwire and 2 cross-checks
python3 hetlitmus/verify/amdisacheck.py --all [--jobs N] [--arch gfxNNN]

# the rep set only: 18 reps + 2 cross-checks, derived from the corpus
python3 hetlitmus/verify/amdisacheck.py --reps [--arch gfxNNN]

# one test (emits and compiles it), or a .s already on disk
python3 hetlitmus/verify/amdisacheck.py hetlitmus/tests/gpu-only/MP-sys-fence.litmus
python3 hetlitmus/verify/amdisacheck.py TEST.litmus --asm F

# the tables, the tools, the rep set and the mutations, then exit
python3 hetlitmus/verify/amdisacheck.py --guard

# every check reddened on a fresh artifact
python3 hetlitmus/verify/amdisacheck.py --bite
```

`make hetlitmus-amd-faithful` runs `--all` then `--bite`. It is on the
**toolchain lane** (`hetlitmus-test-toolchain`): it needs `hipcc` and, for the
cross-check, `llvm-objdump` and `clang-offload-bundler`. It needs no device.
An absent toolchain is a refusal (exit 3), never a skipped check.

Exit **0 = PASS**, **1 = FAIL** (a diff naming the block or the count),
**2 = completeness hard-fail** (an unknown target, an unmodelled mnemonic, an
annotation with no row, a cache-bit set naming no scope, an uncovered corpus
row), **3 = error** (toolchain, corpus, compile or worker).

## Results

Measured on this box, `hipcc --version` first line
`HIP version: 7.2.53211-97f5574fe2` (ROCm 7.2.4). The profile's rows were read
against `llvm/docs/AMDGPUUsage.rst` on LLVM `main`, sections **"Memory Model
GFX942"** and its table **"AMDHSA Memory Model Code Sequences GFX942"**.

**HIP source gate** (`make hetlitmus-hipsrc`, base lane, no toolchain):

```
TALLY gpu-only: 173/173 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
TALLY x86_64 het: 471/471 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
HIP SOURCE GATE: PASS -- gpu-only 173/173, x86_64 het 471/471 (the x86_64
  rendering of the het corpus, not the AArch64 one)
HIP SOURCE GATE BITE OK: 58 injections, each reddening its own assertion,
  0 for a wrong reason; 4 clean control(s) green
```

The sweep runs 12 workers; the bite makes 62 assertions — 58 injections, each
reddening its own assertion, and 4 clean controls green first.

**ISA read-back gate** (`make hetlitmus-amd-faithful`, toolchain lane):

```
profile     gfx942, derived from "AMDHSA Memory Model Code Sequences GFX942"
rep set     18 rep(s) carrying all 17 corpus row(s), each row lowered by the profile
TALLY gpu-only: 173/173 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
TALLY x86_64 het: 471/471 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
  2+2W-cta-fence                             OK (4 token(s) identical)
  2+2W-cg-sys-fence-2s-x86_64                OK (59 token(s) identical)
ISA READ-BACK GATE: PASS -- gpu-only 173/173, x86_64 het 471/471 ...,
  2/2 cross-check(s), 17 row(s) covered, 83.4 s
ISA READ-BACK GATE BITE OK: 38 injections, each reddening its own assertion,
  0 for a wrong reason; 6 clean control(s) green
```

44 assertions in the bite (38 injections + 6 clean controls). The sweep is 83.4 s
at 12 workers and the whole target, sweep plus bite, 94.3 s — 78.1 s and 88.9 s
on a less loaded run of the same tree, so read those as an order of magnitude,
not a pin. `--reps` alone is 16.2 s (18/18 reps, 2/2 cross-checks, 17 rows
covered).

### Triage log

**Both gates were 644/644 with zero reds on their first full run**, and no full
run recorded on this branch has reported an emitter mismatch. There is therefore
no red here that was an emitter finding, and none that had to be explained away.

What *was* found, in both cases by reviewing the checker rather than by running
it, were defects in the checkers themselves — each closed with an injection that
reddens the repaired check:

* a comment-only fence arm took its order and its scope from the comment and
  never asserted the order was relaxed, so a render whose real fence had been
  replaced by the no-op comment passed;
* an asm-literal parse matched only literals closed by a newline escape, so an
  instruction spliced in as its own unterminated literal was dropped silently;
* "the HIP path carries no inline assembly" was the premise of the whole
  source-level read and nothing asserted it;
* a tagged store's value was checked for shape only, so a wrong `K` or a `mu`
  collision passed — the plan is derived from `hetEmit.ml` now, and all 1,080
  tagged GPU stores over the 471 het renders agree value for value;
* the gpu-only result stores were discarded unchecked, while `__out` is the only
  channel by which a gpu-only read reaches an outcome;
* the loop check asked textual span membership, which a guarded op walks straight
  through — it reads each line's guard chain now;
* the rep-set tripwire audited the rep builder's own dicts instead of the files;
* two row locators named the wrong rows of the GFX942 table (a seq_cst load has
  its own rows, and the `("rmw","sc","sys")` sequence is the acq_rel system RMW),
  and all locators were re-read against the source they were derived from;
* the row-required wait was pinned against the assembly rather than against the
  compared stream;
* the completeness guard reached only vector-memory mnemonics, so `image_*`,
  `s_store_*`, `s_barrier` and others would have been dropped with no token and
  no refusal;
* and two checks — the inlined-stress count law and the sweep's control-map
  refusal — passed on every input an in-tree path could produce until an
  injection was written that reaches them.

## Scope and limits

Each limit below is stated where it lives in the code, so it cannot be softened
in one place and kept in the other.

* **At workgroup scope the generated code witnesses NO order at all**
  (`amdisacheck.py:27-31`). A relaxed and a release store are the same
  instruction, so are a relaxed and an acquire load, and a seq_cst workgroup
  fence emits nothing: there is no cache operation to look for. **175 ordered
  workgroup-scope annotation cells of the corpus — 52 `f[sc,cta]`, 59
  `r[acquire,cta]`, 64 `w[release,cta]`, spread over 109 of the 644 renders —
  therefore rest on the HIP source gate alone.** The ISA gate still checks that
  the access itself is there and carries `sc0`; it does not, and cannot, witness
  its order.
* **At agent and system scope, order is witnessed as presence and relative
  position, never as attribution** (`amdisacheck.py:32-36`). An acquire load and
  a relaxed load followed by an acquire fence lower identically, as do a release
  store and a release fence followed by a relaxed store. Which annotation
  produced an ordering effect is the source gate's to say.
* **Block matching is a multiset over ALL lanes and procs**
  (`amdisacheck.py:37-46`, `match_blocks` at `:924`). Any permutation of the
  expected sequences passes — not only a swap of two symmetric procs, but an
  ordering effect moved out of the test instance's lane into its `mu(T)`
  control's lane. Lane attribution is the source gate's, which compares each
  lane's ops in order and binds each instance's aliases; a permutation at ISA
  level could only come from one at source level, a compiler having no way to
  move code across mutually exclusive `blockIdx`/`threadIdx` guards. No
  `blockIdx` recovery is attempted.
* **The window-opener poll has only a census witness**
  (`amdisacheck.py:510-517`). Its `[ld32(gpu)]` is exactly what the folded
  counter reads lower to, and those sit in the load-only blocks the tail policy
  admits, so the block match matches one of them in the poll's place; only the
  whole-kernel count sees the poll gone.
* **The tail policy admits unmatched blocks holding loads (and waits) only**
  (`match_blocks`, `amdisacheck.py:924-962`). A store, an atomic or a cache
  operation in an unmatched block fails.
* **Two census constants are compiler copy counts, pinned exactly**
  (`amdisacheck.py:785,787`): 3 folded `het_scratch_read` copies and 2 volatile
  noise loads. A ROCm change that rotates those loops differently reddens them
  for a reason that is **not** faithfulness. The response is a profile
  re-derivation, logged — not a loosened check.
* **One compile, under the shipped flags** (`COMPILE_FLAGS`,
  `amdisacheck.py:574`). `-S` is bounded against the object the harness would
  ship only by the two-rep disassembly cross-check (`crosscheck`,
  `amdisacheck.py:1224`), not render by render.
* **The LLVM reorder status is three-part** (`amdisacheck.py:62-68`):
  machine-scheduler-excluded [`LLVMSched`], IR-optimizer-unverified,
  probe-unobserved. It is never "low probability".
* **The source gate's loop check is a source-level read**
  (`hipsrccheck.py:935-948`). What it establishes is that a lane's ops sit
  unguarded in the loop body with no jump able to skip them — not that they
  "run once per iteration", which no source-level read can establish.
* **An unknown construct is exit 2; a known construct in the wrong place is exit
  1** (`hipsrccheck.py:54`, `amdisacheck.py:68`). Completeness and correctness
  are different verdicts on purpose: a gate that skipped what it did not
  recognize would be green on exactly the change that most needs a reader.
* **The AMD lane faces SIX `AMDGPUUsage` per-generation memory-model tables, and
  only `gfx942` has a profile** (`PROFILES`, `amdisacheck.py:540`) — the other
  five are `GFX6-GFX9`, `GFX90A`, `GFX10-GFX11`, `GFX12` and `GFX125x`. Every
  other target is exit 2 naming the section to derive it from — never a silent
  comparison against the wrong table.

**Toolchain pin.** ROCm **7.2.4** (`HIP version: 7.2.53211-97f5574fe2`). The
gate reads generated code, so a toolchain bump can change what it reads for
reasons that have nothing to do with faithfulness. Drift response, in order:
re-read the target's "Memory Model GFX*" section for changed rows, re-derive the
affected profile rows and the two census copy counts, re-run `--reps` and then
`--all`, and record what moved in the commit that updates the profile. A red
census constant is a profile re-derivation; a red row is a finding.

## Extending to another GPU generation

Executable from this page. Nothing outside step 2 changes.

1. **Ask the gate.** `python3 hetlitmus/verify/amdisacheck.py --arch gfxNNN
   --reps` on the new toolchain. With no profile it exits 2 naming what to read:
   `no lowering profile for gfxNNN -- derive one from the "Memory Model GFXNNN"
   section of the AMDGPU backend user guide (known: gfx942)`.
2. **Fetch that section** of `llvm/docs/AMDGPUUsage.rst` (or the rendered
   `llvm.org/docs/AMDGPUUsage.html`) and write a new `LoweringProfile` subclass
   beside `Gfx942`, filling in exactly five things:
   * `name`/`arch`/`section` — the target name (spelled here and nowhere else)
     and the title of that generation's code-sequence table;
   * `preconditions` — the assembler directives whose values decide which branch
     of that table the compiler took (for gfx942: the target triple, the code
     object version, and TgSplit);
   * the mnemonic classes, the width suffixes, the cache-bit vocabulary and the
     scope each bit set names, plus whatever asymmetry that generation gives an
     atomic;
   * `row(kind, order, scope, width, ret)` — one entry per `(kind, order, scope)`
     the corpus annotates *plus* the four scaffolding orders in the table above,
     each keyed by its line in the section it came from, carrying a `wait` token
     only where the table requires one immediately before an invalidate;
   * `mutations` — the text injections that must redden the gate, each declaring
     the carrier it needs (`("ld","acquire","sys")`, `"het"`, `"het-obs"`).
3. **Register it** by adding the class to `PROFILES`. The registry line names the
   profile class, not a target.
4. **Prove the tables resolve**: `--arch gfxNNN --guard` prints the rows, the
   preconditions, the scaffolding signatures, the rep set and each mutation
   resolved to a carrier; it exits non-zero if any of that is empty or
   unresolvable.
5. **Probe on that toolchain**: `--arch gfxNNN --reps` (18 reps + 2 cross-checks
   here, seconds), then `--arch gfxNNN --bite`, then `--arch gfxNNN --all`.
6. **Log it**: the derivation belongs in the commit that adds the profile, and
   any deviation from the section it was read from belongs in
   [`REFERENCES.md`](REFERENCES.md) under the key that carries it.

## Relation to the NVIDIA gate

[`faithfulness.md`](faithfulness.md) documents the NVIDIA pair (`ptxcheck.py`
via `tokens.sh`, `make hetlitmus-faithful`) over its own 644 renders — 173
gpu-only plus the **AArch64** het 471. The AMD lane's het 471 is the x86_64
rendering of the same shapes, so the two "471"s are different corpora and every
count on either side says which. `amdisacheck.py` and `hipsrccheck.py` import
`ptxcheck.py` and never modify it: its `.litmus` parsers, its GPU mapping table
and its lane plan are the expected side here too.

One heads-up for a reader moving between the two documents: `faithfulness.md`'s
"What is checked" list (items 2 and 3, `:138-142`) describes a **global
multiset** check and a **per-proc multiset** check as detectors. `ptxcheck.py`
performs neither as a detector today — there is no global multiset comparison at
all, and the per-proc `Counter` comparison runs *only after* the ordered check
has already failed, as a localizer that names the instance and proc
(`ptxcheck.py:604-620`). The ordered comparison subsumes both: if it passes, the
two lists are identical and no multiset test could differ. The AMD gates state
the same reasoning where they use a multiset — the source gate's is a
post-failure localizer (`hipsrccheck.py:885-903`), while the ISA gate's block
match is genuinely a multiset and says so.
