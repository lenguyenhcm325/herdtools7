# PTX/AArch64 lowering faithfulness

**The property:** every emitted GPU (and, for het tests, CPU) harness carries
*exactly* the memory **order + scope + op-kind** that its `.litmus` annotation
specifies — with no weakening, strengthening, miscount, misplacement, or missing
qualifier.

Faithfulness here is a *static, hardware-free* property of the emitted text,
settled before any kernel runs. It is not a herd re-check and not a
differential test — it is one thing: token-level lowering faithfulness of the
chain

```
.litmus annotation  --(litmus7/CudaLang)-->  .cu
                    --(nvcc --ptx)-------->  PTX, one (kind,order,scope) token per model op
```

This document is the mapping that property is stated against — what each
annotation must lower to on each ISA — with its sources, the argument for why
the `nvcc --ptx` text is a sound witness of what the emitter wrote, the limits
of what that text can witness, and the run-time side of the stress layers the
text is blind to.

The AMD lane's twin of this document is
[`amd-faithfulness.md`](amd-faithfulness.md). The HIP path carries no inline
assembly, so its faithfulness is a property of the emitted source rather than
of generated code, over its own two corpora — the gpu-only corpus plus the
**x86_64** rendering of the het corpus, not the AArch64 rendering this document
is about. What `hipcc` lowers that source to is unverified.

## Why the property is stated on the PTX

libcu++'s `cuda::atomic_thread_fence` cannot express a release-only or
acquire-only fence [CCCL], so `CudaLang` emits faithful inline PTX instead
([`cuda-emitter.md`](cuda-emitter.md), "Fence lowering"). The property is
therefore stated on the PTX nvcc produces, **end-to-end through nvcc**: a
collapse/weakening/narrowing can enter from `CudaLang`, from a libcu++
upgrade, or from a toolkit change, and only the PTX text carries all three.

## Why inspecting `nvcc --ptx` is sound (not luck)

* libcu++ scoped atomics are themselves implemented as
  `asm volatile(... : : : "memory")`. In the PTX they appear wrapped in
  `// begin inline asm` / `// end inline asm` markers. An `asm volatile` with a
  `"memory"` clobber is a **hard compiler-ordering barrier**, so nvcc cannot
  reorder model ops relative to one another *even when they are relaxed*.
  ⇒ the textual order of inline-asm ops **equals** source program order — a
  consequence of the inline-asm contract, not an empirical accident.
* Harness scaffolding (`ld.param`, `st.global`, `cvta`, the `__out` readback)
  sits **outside** the inline-asm markers and carries **no** memory-order
  qualifier, so it is unambiguously scaffolding, never a model op.
* `CudaLang` emits procs in column order, cells in row order ⇒ the flattened PTX
  op stream equals the flattened expected stream.

## The mapping table (grounded)

PTX uses the **same spelling** as the LISA/Bell tag for both order and scope, and
nvcc emits the order **before** the scope (`ld.relaxed.gpu`, `fence.sc.cta`).

### GPU — order

| LISA/Bell order | PTX semantics | valid on |
|-----------------|---------------|----------|
| `relaxed`       | `.relaxed`    | ld, st, atom/red |
| `acquire`       | `.acquire`    | ld, atom/red, fence (PTX ISA 8.6) |
| `release`       | `.release`    | st, atom/red, fence (PTX ISA 8.6) |
| `acq_rel`       | `.acq_rel`    | atom/red, fence |
| `sc`            | `.sc`         | fence |

### GPU — scope

| LISA/Bell scope | PTX scope | thread_scope |
|-----------------|-----------|--------------|
| `cta`           | `.cta`    | `thread_scope_block`  |
| `gpu`           | `.gpu`    | `thread_scope_device` |
| `sys`           | `.sys`    | `thread_scope_system` |

### GPU — op kind

| LISA mnemonic | PTX opcode |
|---------------|------------|
| `w` (store)   | `st`       |
| `r` (load)    | `ld`       |
| `f` (fence)   | `fence`    |

> These three are the corpus vocabulary (`ptx.bell` declares only `R`/`W`/`F`),
> and the corpus holds no RMW. An RMW cell has no row, and an `rmw` row would
> need more than a fourth key: `atom` and `red` are two opcodes a
> `(kind, order, scope)` triple cannot tell apart. The `acq_rel`/`sc` orders
> are rows though no corpus access carries them.

### CPU (AArch64) — het column

| LISA mnemonic | semantics | not-weakened means |
|---------------|-----------|--------------------|
| `STLR`        | store-release        | stays `STLR`, never `STR` |
| `LDAR`        | load-acquire (RCsc)  | stays `LDAR`, never `LDR` |
| `LDAPR`       | load-acquire (RCpc)  | stays `LDAPR`, never `LDR` |
| `DMB SY`      | full barrier, orders {WW,RR,WR,RW} | stays `DMB SY`, never dropped or narrowed |
| `DMB ST`      | store barrier, orders {WW}         | stays `DMB ST` |
| `DMB LD`      | load barrier, orders {RR,RW}       | stays `DMB LD` |
| `STR`/`LDR`   | plain store/load     | — |
| `MOV`         | neither a memory nor an ordering op; litmus7's lowering emits it to materialise a store value in a register | — |

`DMB SY`, `DMB ST` and `DMB LD` are three distinct instructions (encodings
`d5033fbf` / `d5033ebf` / `d5033dbf`), and a barrier's ordered-pair set lives
in its option, so a CPU op's identity is the pair (mnemonic, barrier option):
`sy` is the full barrier, `st` orders {WW}, `ld` orders {RR,RW}. `DMB ST` where
`DMB SY` is expected is therefore a different instruction in that position, not
a spelling variant, and an option outside those three (`ish`, say) or a `DMB`
with no option has no row. All three reach the corpus: the generator's
`st`/`ld` order-pair tokens render an intra-proc edge as `DMB ST`/`DMB LD`
(`_grid_lib.sh`, `render_cpu_cycle` with `fence-st`/`fence-ld`).

### Annotations the corpus carries

Every one of them is a row above:

```
GPU: w/r[relaxed,{cta,gpu,sys}]  w[release,{cta,gpu,sys}]  r[acquire,{cta,gpu,sys}]
     f[sc,{cta,gpu,sys}]  f[release,sys]  f[acquire,sys]
CPU: MOV STR LDR STLR LDAPR DMB{SY,ST,LD}
```

## Sources

* **NVIDIA PTX ISA** (CUDA **12.9** nvcc emits `.version 8.8`): `ld` §9.7.9.8,
  `st` §9.7.9.11, `membar`/`fence` §9.7.14.4, `atom` §9.7.14.5, `red` §9.7.14.6 —
  <https://docs.nvidia.com/cuda/parallel-thread-execution/index.html>.
  These ground the qualifier vocabulary: `ld{.relaxed,.acquire}`,
  `st{.relaxed,.release}`, `fence{.sc,.acq_rel,.acquire,.release}`, scope
  `{.cta,.gpu,.sys}`, sem-before-scope; `atom` is an RMW returning the
  old value, `red` a reduction with no return. The ISA lets a `fence` elide
  its order (`fence{.sem}.scope`, `.acq_rel` assumed) and spells the legacy
  form `membar.level`; the emitter writes neither — every fence it emits is
  `fence.<order>.<scope>` — so a `fence` or `membar` line with no order token
  is scaffolding, and either form in a model fence's place is a missing op.
* **nvcc itself is the strongest primary evidence.** Every token in the table
  assembles exit 0 under `nvcc -std=c++17 -arch=sm_90` (`--ptx`, and `-c`
  through `ptxas`): `ld.relaxed.sys`, `st.release.sys`, `ld.acquire.gpu`,
  `st.relaxed.cta`, `fence.sc.sys`, `fence.acquire.sys`, `fence.release.sys`,
  `atom.add.acquire.sys`. An assembler that accepts and lowers a token is the
  ground truth for what that token is and means — but not for the floors it
  needs: `ptxas` 12.9 accepts `fence.release.sys` at `.version 6.0` /
  `.target sm_70`, enforcing neither, so for ISA-version and SM-target floors
  the spec is authoritative and the assembler is not.
* **Fence availability:** [CCCL], stated in [`cuda-emitter.md`](cuda-emitter.md)
  ("Fence lowering").
* **Annotation vocabulary:** [`../bells/ptx.bell`](../bells/ptx.bell)
  (`enum memory_order`, `enum scopes`, `instructions R/W/F`).
* **CPU mapping:** the *Arm Architecture Reference Manual* is the source of the whole
  map — STLR = Store-Release; LDAR = Load-Acquire RCsc; LDAPR = Load-AcquirePC RCpc,
  FEAT_LRCPC; DMB SY/ST/LD = Data Memory Barrier, full / store / load. [Bagchi26 Fig. 1]
  is cited for what it depicts, and for that alone: an unscoped ARM release store
  (`STLR`) pairing with a system-scoped PTX acquire load (`ld.acquire.sys.b32`) — the
  compound question the het column poses. The RCpc (`LDAPR`) choice is the **corpus
  generator's**, not the emitter's: `hetgen7`'s two-sided acquire CPU token is
  upstream's `ReadAcqPc`, which `gen/AArch64Compile_gen.ml` emits as `LDAPR`, and it is
  already spelled that way in the committed `.litmus`. litmus7 then reproduces it
  verbatim, which is why the emitted build files compile `<t>_cpu.c` with
  `-march=armv8.3-a` (`litmus/hetCpuFront.ml`).

## The property, op by op

The `.litmus` fixes an **expected profile**; the emitted PTX (and, for het
tests, `_cpu.c`) carries an **observed** one. The harness is faithful when:

1. **The model-op streams are equal in order** — element-wise
   `(kind, order, scope)` equality of the flattened streams. Equality of
   ordered streams subsumes kind, order, scope, multiplicity **and placement**
   (a fence between the right accesses; load/store order preserved; a missing
   or extra op shifts every position after it), and a strengthening
   (`relaxed`→`acquire`) or weakening (`release`→`relaxed`) is a positional
   difference.
2. **(het) Nothing ahead of the rendezvous** — no model op precedes the first
   rendezvous arrival: an op ahead of it sits outside every lane segment and
   belongs to no lane.
3. **(het) The rendezvous orders nothing** — the system-scope rendezvous spans
   both devices and **orders nothing**: every op `sys`-scoped (never narrowed),
   every op **relaxed**, **no fence anywhere in it**, and one arrival
   (`atom`/`red`) per joining GPU lane. Relaxed and fence-free is a correctness
   property, not a preference: `00-environment-design.md` §3.3
   ([Bagchi26 §5.3]).
4. **No stray system-scope op** — no `sys`-scoped op outside the inline-asm
   markers, where it would sit outside the model-op stream. A builtin op of
   narrower scope outside the markers is outside the property altogether,
   which is why the stress layer is built from builtins and plain accesses that
   never enter the model-op stream (`het_stress.h`'s scaffolding counters lower
   to bare `atom.global.*` with no order token).
5. **(het) The CPU column reproduces** — the ordered memory/ordering mnemonics
   of the `.litmus` CPU column, barrier option included, reproduce in the
   emitted `_cpu.c` real-asm block (under `#if defined(__aarch64__)`): `STLR`
   never `STR`, `LDAPR` never `LDR`, no `DMB` dropped, and `DMB ST` never in
   `DMB SY`'s place. The block is litmus7's own (`#START _litmus_P<n>` …
   `#END`), with `%w[x0]`/`%[x]`-style operands.

### Het rendezvous/model separation

Each GPU proc is emitted as its own guarded block whose iteration loop runs
`{ rendezvous; release jitter; model… }`, so the rendezvous is **not** a single
prologue — there is one arrival per GPU proc, and it recurs every iteration
while the text carries it once. The arrival is the unique anchor: the corpus
model has **no** `atom`/`red`, so every system-scoped `atom`/`red` in the kernel
is a rendezvous arrival. The op stream therefore falls into one segment per
arrival, each opening with the template `[arrival][optional fence][poll]` and
continuing with that lane's model ops, in lane order. A fence directly after an
arrival belongs to the template (and, under property 3, is a fault of the
rendezvous), while a fence after the poll is a model op, so a lane whose column
begins or ends in a fence (`f[sc,sys]`, say) is unambiguous.

## Scope / limits

* Faithfulness here is **static lowering** faithfulness (annotation → emitted
  PTX/asm token). Runtime reordering by ptxas/hardware is the *behaviour under
  test* on real hardware, not part of this property.
* It is a property of the `nvcc --ptx` text alone — hardware-free; no kernel is
  involved.
* `MOV` is neither a memory nor an ordering op — litmus7's lowering emits it to
  materialise a store value in a register — so it is not a CPU model op; only
  memory/ordering mnemonics are.
* No `acq_rel`/RMW/`sc`-on-access appears in the corpus (the op-kind table's
  note above).
* **The property is BLIND to the stress layer, by design.** Stress is
  scaffolding, not a tested op: it carries no order/scope qualifier and sits
  outside the inline-asm markers, so it never enters the model-op stream —
  correct, but it means *faithfulness alone cannot tell whether the stress
  layer exists at all*. The hazard is concrete: a compile-time access pattern
  lets nvcc fold `het_do_stress`'s if-chain and hoist its loads while every
  model op stays faithful (measured under "What a compile-time access pattern
  costs" below); the shipped pattern is a runtime kernel argument. Whether the
  stress is in the emitted PTX and whether it ran are therefore properties of
  their own ("GPU stress liveness at run time" below): **a mechanism whose
  execution is not observable must be assumed dead**, which is why the stress
  layers report run-time tallies.

### What a compile-time access pattern costs

`het_do_stress` takes its access pattern as a **runtime kernel argument**: the
emitter reads `HET_PRE_STRESS_PATTERN` / `HET_MEM_STRESS_PATTERN` into host
variables and passes them in (`litmus/hetEmit.ml`), so the if-chain lowers to a
four-way dispatch and the scratchpad traffic survives whatever the `-D` says.
Hand the same body a compile-time constant instead and nvcc folds the chain to
the one named branch. The loop is not deleted outright — its round count reaches
the liveness tally, so the trip count is observable — but branch 3 (`ld;ld`, the
shipped pre-stress default) writes nothing, which makes both of its loads
loop-invariant: nvcc hoists them out and leaves one peeled iteration's two
loads, the `break` test on the first of them, and an empty counting loop feeding
the tally. The bookkeeping survives; the stress does not.

Measured on the emitted PTX (`nvcc -std=c++17 -arch=sm_90 --ptx`), plain
`ld/st.global.u32` inside one test lane's iteration loop:

| how the pattern reaches `het_do_stress` | pattern | scratchpad ops |
|---|---|---|
| compile-time constant | 3 = `ld;ld` (the pre-stress default) | **2**, no store |
| compile-time constant, `HET_PRE_STRESS_PCT=100` | 3 | **2**, no store |
| compile-time constant | 1 = `st;ld` | 13 |
| compile-time constant | 2 = `ld;st` | 12 |
| compile-time constant | 0 = `st;st` | 228 |
| runtime kernel argument (the shipped shape) | dispatched at run time | 49 |
| compile-time constant, `volatile` scratchpad | 3 | 1, plus 8 `ld.volatile.global.u32` |

Those rows are a record of the folding experiment, and reproducing one needs the
source variant its first column names — the shipped pattern is a runtime kernel
argument, so a `-D` cannot fold it any more. What the shipped shape costs is
re-measurable directly, and on `MP-cg-sys-relaxed` at `-arch=sm_90` it is **100**
plain-u32 scratchpad ops (66 `ld`, 34 `st`), **invariant** under
`-DHET_PRE_STRESS_PATTERN=0..3` and `-DHET_MEM_STRESS_PATTERN=0..3`, over an
isolation baseline of exactly the **2** read-buffer stores that render writes
(`-DHET_PRE_STRESS_PCT=0 -DHET_MEM_STRESS_PCT=0`). Those two stores are plain u32
because a model location is an `int`, so a stress count is a difference from
that baseline rather than an absolute.

Asking harder does not help: the count stays at 2 with `HET_PRE_STRESS_PCT=100`,
because raising how *often* a lane calls a hoisted loop adds nothing. `volatile`
is not the fix either — it holds the accesses inside the loop by changing what
they are, and this stress is meant to be plain, non-volatile, ordinary cacheable
traffic (`litmus/het-runtime/het_stress.h` carries that constraint and its
source). The same fold reaches mem-stress, where a stress block's 49 ops become
16, 13, 12 or 2 as the compile-time pattern moves 0 → 1 → 2 → 3. Under a
compile-time pattern a sweep over `pattern ∈ {0,1,2,3}` would be scoring a knob
deciding how much stress exists rather than which stress it is; the runtime
argument is what keeps each lane class's scratchpad load **and** store in the
emitted PTX at every pattern, at a count that does not move.

## GPU stress liveness at run time

The emitted PTX carries the scratchpad accesses at a count invariant under the
`-D` pattern knobs, and the device half of the interconnect noise pair with
them (the volatile 64-bit noise loads outlive nvcc, at a count invariant over
`-DHET_NOISE_GPU_BLOCKS`). Nothing static can say the loop ever *executed*.

**The runtime tally is the other half.** `het_stress.h` counts rounds through
`HET_TALLY_STRESS_ROUNDS` — an `atomicMax` of the rounds any single
`het_do_stress` call completed, overflow-free like `NOISE_ROUNDS` — the emitted
driver reads it back into `het_obs_record.gpu_stress_rounds`, and
`het_verdict()` raises `HET_DQ_GPU_STRESS_DEAD` when the stress was requested
and that tally is zero (`harness-reporting.md` §3). A counter is evidence only
if it can be shown to move **and** to stay at zero — nonzero when the loop is
asked for, exactly zero when it is not — and one access pattern decides that
for all four, because `rounds++` sits after the pattern if-chain in
`het_do_stress` (`het_stress.h`), inside the loop and outside every branch, so
the tally counts rounds whichever branch runs.

**The two halves are not redundant.** The tally says the loop *ran*; the emitted
text says it still *contains* its scratchpad accesses and that no `-D` can
switch them off. The blind spot recorded under "Scope / limits" above — a layer
present in the source and gone from the emitted PTX while every model op stays
faithful — is exactly what neither half alone shows.

The tally also watches a failure the compiler is not responsible for. Stress
blocks fill what the co-residency cap leaves over the test lanes, so the stress
population is the first thing that cap squeezes to zero: the code present,
requested, and executed by nobody. The emitted driver warns about that case
explicitly *before* the run, rather than leaving it to the tally afterwards
(`litmus/hetEmit.ml`).

## CPU-side stress liveness

The cache preload, the CPU enemy threads and the CPU half of the interconnect
noise pair reach no PTX: the preload emits host cache hints (no order, no scope,
not a model op), the enemies are host code, and the noise streams a disjoint
buffer. Their liveness is therefore two properties of the host side, neither of
which the PTX text carries: the mechanisms survive the optimiser (static, on
the compiled `-O2` asm of both host ISAs), and they do something at run time
(dynamic: the CPU tally is nonzero when a mechanism is on and exactly zero when
it is off).

**`volatile` on the enemy's discarded load is load-bearing.** The enemy's read
half is `(void)*l`, a load whose value is discarded. `volatile` forces the
compiler to perform it and it lowers to a load into the zero register; without
`volatile` the load is provably useless and is deleted. Measured on the emitted
code (`clang --target=aarch64-linux-gnu -O2`), inside `het_cpu_enemy` only:

| | `volatile` (shipped) | `volatile` dropped |
|---|---|---|
| loads into `xzr` | 3 | **0** — all read traffic deleted |
| stores | 5 | **2** — `st;st` collapsed to one store |

So sigma 3 (`ld;ld`) becomes a complete no-op, sigma 1 and 2 lose their read
half, and sigma 0's `*l = i; *l = i+1;` collapses into a single store — while
the loop still exists, and a count of *all* `ldr` stays comfortably nonzero
from the `a->scratch` / `a->idx` / `a->nidx` argument-struct loads alone: the
enemy's read traffic is its `ldr xzr` / `ldr wzr` loads and nothing else. The
four sigma branches declare 2+1+1+0 scratchpad stores between them, and a
non-volatile build lands well under those four.
