# Static PTX/ASM faithfulness check

**Question answered:** does every emitted GPU (and, for het tests, CPU) harness
carry *exactly* the memory **order + scope + op-kind** that its `.litmus`
annotation specifies — with no weakening, strengthening, miscount,
misplacement, or missing qualifier?

This is a *static, hardware-free* check. It emits the harness, compiles
it to PTX, and inspects the text. **It never launches a kernel.** It is not a
herd re-check, a mutation campaign, or a differential test — it is one thing:
token-level lowering faithfulness of the chain

```
.litmus annotation  --(litmus7/CudaLang)-->  .cu
                    --(nvcc --ptx)-------->  PTX
                    --(ptxcheck.py)------->  expected (kind,order,scope) profile  ==  observed?
```

The AMD lane's twin of this document is
[`amd-faithfulness.md`](amd-faithfulness.md). The HIP path carries no inline
assembly, so its one gate reads the emitted source rather than generated code
(`hipsrccheck.py`, `make hetlitmus-hipsrc`, base lane), over its own 644
renders — the 173 gpu-only plus the **x86_64** het 471, not the AArch64 471 read
here. What `hipcc` lowers that source to is unverified.

## Why this is the right guard

The bug this exists to catch is real and documented in
[`cuda-emitter.md`](cuda-emitter.md) ("Fence lowering"): libcu++'s
`cuda::atomic_thread_fence` **collapses** `acquire`/`release` →
`fence.acq_rel`, *losing the order*. `CudaLang` therefore bypasses it and emits
faithful inline PTX. This check proves that faithfulness **end-to-end through
nvcc**, and
would FAIL the day a collapse/weakening/narrowing returns — whether introduced
by `CudaLang`, by a libcu++ upgrade, or by a toolkit change.

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
  qualifier, so it is unambiguously ignored.
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
| RMW           | `atom` (returns old value) / `red` (no-return reduction) |

> The corpus (`ptx.bell` declares only `R`/`W`/`F`) contains **no** RMW and no
> `acq_rel`/`sc`-on-access. Those rows are kept so the completeness
> guard *recognizes* such a token rather than skipping it.

### CPU (AArch64) — het column

| LISA mnemonic | semantics | not-weakened means |
|---------------|-----------|--------------------|
| `STLR`        | store-release        | stays `STLR`, never `STR` |
| `LDAR`        | load-acquire (RCsc)  | stays `LDAR`, never `LDR` |
| `LDAPR`       | load-acquire (RCpc)  | stays `LDAPR`, never `LDR` |
| `DMB SY`      | full system barrier  | stays `DMB SY`, never dropped/narrowed (e.g. `DMB ISH`) |
| `STR`/`LDR`   | plain store/load     | — |
| `MOV`         | absorbed by the tagged-body classifier; the value reaches the asm block as an input operand (not a memory op) | — |

## Sources

* **NVIDIA PTX ISA** (the toolkit nvcc here is CUDA **12.9**, which emits
  `.version 8.8`): `ld` §9.7.9.8, `st` §9.7.9.11, `membar`/`fence` §9.7.14.4,
  `atom` §9.7.14.5, `red` §9.7.14.6 —
  <https://docs.nvidia.com/cuda/parallel-thread-execution/index.html>.
  These ground the qualifier vocabulary: `ld{.relaxed,.acquire}`,
  `st{.relaxed,.release}`, `fence{.sc,.acq_rel,.acquire,.release}`, scope
  `{.cta,.gpu,.sys}`, sem-before-scope; `atom` is an RMW returning the
  old value, `red` a reduction with no return.
* **The strongest primary evidence is nvcc itself.** Every token in the table
  was *emitted and assembled exit 0* by `nvcc -std=c++17 -arch=sm_86/90 --ptx`:
  `ld.relaxed.sys`, `st.release.sys`, `ld.acquire.gpu`, `st.relaxed.cta`,
  `fence.sc.sys`, `atom.add.acquire.sys`. An assembler that accepts and lowers a
  token is the ground truth for what that token is and means.
* **Fence availability** (`fence.{acq_rel,sc}` PTX ISA 6.0/SM_70;
  `fence.{acquire,release}` 8.6/SM_90) is already grounded
  in [`cuda-emitter.md`](cuda-emitter.md) against the cccl headers
  (`__ptx/instructions/generated/fence.h`).
* **Annotation vocabulary:** [`../bells/ptx.bell`](../bells/ptx.bell)
  (`enum memory_order`, `enum scopes`, `instructions R/W/F`).
* **CPU mapping:** the *Arm Architecture Reference Manual* is the source of the whole
  map — STLR = Store-Release; LDAR = Load-Acquire RCsc; LDAPR = Load-AcquirePC RCpc,
  FEAT_LRCPC; DMB SY = full-system Data Memory Barrier. [Bagchi26 Fig. 1] is cited for
  what it depicts, and for that alone: an unscoped ARM release store (`STLR`) pairing
  with a system-scoped PTX acquire load (`ld.acquire.sys.b32`) — the compound question
  the het column poses. The RCpc(`LDAPR`) choice is the one the emitter makes
  (`litmus/hetCpuBodyA64.ml`).

## What is checked, for every op, both directions

For each test the checker builds the **expected profile** from the `.litmus` and the
**observed profile** from the PTX (and `_cpu.c`), then asserts:

1. **ORDERED equality** of the model-op streams — element-wise
   `(kind, order, scope)` equality. This subsumes order/scope/kind exactness
   **and placement** (a fence between the right accesses; load/store order
   preserved). A strengthening (`relaxed`→`acquire`) or weakening
   (`release`→`relaxed`) shows up as a positional mismatch.
2. **PER-PROC localization** — a diagnostic, **not** a second detector. An
   order-blind multiset test is strictly weaker than item 1: if the ordered
   comparison passes the two streams are identical, so no multiset test could
   differ and a global one would detect nothing at all. What slicing the
   observed stream by the expected per-proc op counts and comparing `Counter`s
   adds is the instance and proc a mismatch sits in, which a flat index diff
   cannot name — so it runs only after item 1 has failed, and only reports
   (`ptxcheck.py:604-620`).
3. **(het) barrier whitelist** — the system-scope rendezvous barrier(s) must
   stay strong: every barrier op `sys`-scoped (never narrowed), one `fetch_add`
   (`atom`/`red`) **per GPU proc** at `sys`, and a seq_cst fence present.
4. **(het) CPU column** — the ordered memory/ordering mnemonics of the `.litmus`
   CPU column must reproduce in the emitted `_cpu.c` real-asm block (under
   `#if defined(__aarch64__)`), catching `STLR`→`STR`, `LDAPR`→`LDR`,
   `DMB SY` drop/narrowing.

### Het barrier/model separation

Each GPU proc is emitted as its own guarded block `{ barrier; model… }` (every
GPU thread must rendezvous), so the barrier is **not** a single prologue — there
is one barrier instance per GPU proc. The barrier's `fetch_add` is the unique
anchor: the corpus model has **no** `atom`/`red`, so every `atom`/`red` in the
kernel is a barrier fetch_add. The checker segments the op stream at each fetch_add and
strips the fixed barrier template
`[leading fence.sc][atom.sys][spin fence.sc][spin ld.sys]` from each segment's
front; the remainder is that proc's model ops, in proc order. This correctly
keeps a *model* `fence.sc.sys` (`f[sc,sys]`) distinct from the barrier's seq_cst
fences.

## Completeness guard (never silently skip)

The mapping table **is** the guard. Building the expected profile looks up every
order, scope, op-kind, and CPU mnemonic in the table; a token that is not a key
raises `CompletenessError`, which **hard-fails the test with exit 2** — it is
never skipped. `tokens.sh guard` enumerates every *distinct* annotation in the
corpus, confirms each is `MAPPED`, and then feeds a deliberately-unknown
annotation (`w[consume,sys]`) to show the hard-fail.

Distinct annotations in the corpus (all MAPPED):

```
GPU: w/r[relaxed,{cta,gpu,sys}]  w[release,{cta,gpu,sys}]  r[acquire,{cta,gpu,sys}]
     f[sc,{cta,gpu,sys}]  f[release,sys]  f[acquire,sys]
CPU: MOV STR LDR STLR LDAPR DMB
```

## How to run

```
# full corpus: per-test PASS/FAIL table + tally (173 gpu-only, 471 het)
JOBS=8 bash hetlitmus/verify/tokens.sh            # both
JOBS=8 bash hetlitmus/verify/tokens.sh gpu-only   # 173
JOBS=8 bash hetlitmus/verify/tokens.sh het        # 471

# completeness-guard report (distinct annotations + unknown hard-fail)
bash hetlitmus/verify/tokens.sh guard

# weaken/strengthen self-test on a copied PTX
bash hetlitmus/verify/tokens.sh selftest

# a single test (full pipeline: emit -> nvcc --ptx -> check)
python3 hetlitmus/verify/ptxcheck.py hetlitmus/tests/gpu-only/MP-sys-F.litmus
```

`ptxcheck.py` exits **0 = PASS**, **1 = FAIL** (with an exact per-position diff),
**2 = completeness hard-fail**, **3 = tool/emit error**. Requirements: `litmus7`
built in `_build` (`make all` at the repo root) and `nvcc` on `PATH`
(`/usr/local/cuda/bin`; CUDA 12.9). Default arch `sm_90`.

## Result

```
TALLY gpu-only: 173/173 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
TALLY het: 471/471 PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
```

* **Self-test:** a copied `MP-sys-F.ptx` mutated `st.release.sys`→`st.relaxed.sys`
  (weakening) and `ld.relaxed.sys`→`ld.acquire.sys` (strengthening) each FAIL
  with an exact `[idx] expected … observed …` diff (exit 1); the unmutated
  control PASSes. Scope-narrowing (`.sys`→`.cta`) also FAILs.
* **Completeness:** all 17 distinct GPU annotations + 6 CPU mnemonics MAPPED; an
  unknown `w[consume,sys]` hard-fails (exit 2).

### Triage log (every FAIL accounted for)

The first full het run reported **18 FAIL** — all the multi-GPU-proc IRIW het
tests (`IRIW-cgcg-*`, `IRIW-gcgc-*`). Root cause was a **checker bug**, not an
emitter mismatch: the het barrier/model separator assumed a single barrier
*prologue*, but a kernel with two GPU procs correctly emits **one barrier per GPU
proc guard block** (`[barrier][model]` × 2). The fix (segment on the fetch_add
anchor, strip the barrier template per segment) was applied **in the checker
only**; the emitter, `.litmus` corpus, and `ptx.bell` were not touched. After the
fix, every het test PASSed. No emitter mismatch was found — the lowering is
faithful across the whole corpus.

## Scope / limits

* This check proves **static lowering** faithfulness (annotation → emitted PTX/asm
  token).
  Runtime reordering by ptxas/hardware is the *behaviour under test* on real
  hardware, not a concern of this check.
* It is hardware-free: `nvcc --ptx`/`-c` and reading text only; no kernel runs.
* `MOV` is absorbed by the tagged-body classifier (`HetCpuPlan.Consumed`) — the
  store value it set is replaced by the runtime tag, which reaches the asm block
  as an input operand — so it is intentionally excluded from the CPU comparison;
  only memory/ordering mnemonics are compared.
* No `acq_rel`/RMW/`sc`-on-access appears in the 173+471 corpus; the
  mapping covers them so the guard recognizes (never skips) them if added.
* **ptxcheck is BLIND to the stress layer, by design — and that blind spot has
  already cost us.** Stress is scaffolding, not a tested op: it carries no
  order/scope qualifier and sits outside the inline-asm markers, so it can never
  enter the op stream this checker compares. Correct — but it means *no gate here
  can tell whether the stress layer exists at all*. The pre-stress incantation
  once shipped in a form whose traffic nvcc had **hoisted away** (a compile-time
  access pattern folds `do_stress`'s if-chain to `ld;ld`, whose loads feed only a
  `break` and so leave the loop — measured under "What a compile-time access
  pattern costs" below), beside a device-scope window-opener that released on
  its deadlock cap 99.6% of the time. Both passed every gate in this suite.
  The other half of the static check is therefore **`hetlitmus/verify/stresscheck.py`**
  (`make hetlitmus-stress`), which counts scratchpad ops in the emitted PTX per
  lane class and asserts the count is *invariant* under `-DHET_*_PATTERN` — i.e.
  that no stress configuration can silently switch it off. Bite-tested in
  `tokens.sh selftest` section [7]. **A mechanism no gate can observe must be
  assumed dead**: if you add scaffolding here, add the gate that watches it.

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
`ld/st.global.u32` — stresscheck's own signature — inside one test lane's
perpetual loop:

| how the pattern reaches `het_do_stress` | pattern | scratchpad ops |
|---|---|---|
| compile-time constant | 3 = `ld;ld` (the pre-stress default) | **2**, no store |
| compile-time constant, `HET_PRE_STRESS_PCT=100` | 3 | **2**, no store |
| compile-time constant | 1 = `st;ld` | 13 |
| compile-time constant | 2 = `ld;st` | 12 |
| compile-time constant | 0 = `st;st` | 228 |
| runtime kernel argument (the shipped shape) | dispatched at run time | 49 |
| compile-time constant, `volatile` scratchpad | 3 | 1, plus 8 `ld.volatile.global.u32` |

Asking harder does not help: the count stays at 2 with `HET_PRE_STRESS_PCT=100`,
because raising how *often* a lane calls a hoisted loop adds nothing. `volatile`
is not the fix either — it holds the accesses inside the loop by changing what
they are, and this stress is meant to be plain, non-volatile, ordinary cacheable
traffic (`litmus/het-runtime/het_stress.h` carries that constraint and its
source). The same fold reaches mem-stress, where a stress block's 49 ops become
16, 13, 12 or 2 as the compile-time pattern moves 0 → 1 → 2 → 3. That is what a
sweep over `pattern ∈ {0,1,2,3}` would be scoring — a knob deciding how much
stress exists rather than which stress it is, and no other gate in this suite can
tell those configurations apart — which is why `stresscheck.py`'s invariance
assertion (5) is the load-bearing one rather than a formality.

## Proving the GPU stress ran, not just that it exists

`stresscheck.py`'s first five checks are **structural**: the scratchpad accesses
are in the emitted PTX and their count is invariant under the `-D` pattern
knobs. Nothing static can say the loop ever *executed*.

**The runtime tally is the other half.** `het_stress.h` counts rounds through
`HET_TALLY_STRESS_ROUNDS` — an `atomicMax` of the rounds any single
`het_do_stress` call completed, overflow-free like `NOISE_ROUNDS` — the emitted
driver reads it back into `het_obs_record.gpu_stress_rounds`, and
`het_verdict()` raises `HET_DQ_GPU_STRESS_DEAD` when the stress was requested
and that tally is zero (`harness-reporting.md` §3). A counter is evidence only
if it can be shown to move **and** to stay at zero, so `stresscheck.py`'s
`device-probe` check drives `het_do_stress` on a real device over every access
pattern and asserts both directions: nonzero when the loop is asked for, exactly
zero when it is not.

**The two halves are not redundant.** The tally proves the loop *ran*; the
structural checks prove it still *contains* its scratchpad accesses and that no
`-D` can switch them off. The blind spot recorded under "Scope / limits" above —
a layer present in the source, gone from the emitted PTX, and green on every
gate — is exactly what neither half alone would have caught.

The tally also watches a failure the compiler is not responsible for. Stress
blocks fill what the co-residency cap leaves over the test lanes, so the stress
population is the first thing that cap squeezes to zero: the code present,
requested, and executed by nobody. The emitted driver warns about that case
explicitly *before* the run, rather than leaving it to the tally afterwards
(`litmus/hetEmit.ml`).

## CPU-side stress liveness

`hetlitmus/verify/cpustresscheck.py` is the CPU/interconnect sibling of
`stresscheck.py`. The cache preload, the CPU enemy threads and the interconnect
noise pair are invisible to *both* PTX checkers — the preload emits host cache
hints (no order, no scope, not a model op), the enemies are host code that
never reaches the PTX, and
the noise streams a disjoint buffer — so that layer is unguarded without it. It
asks two questions the structural gates cannot: did the mechanisms survive the
optimiser (static, on the **compiled** `-O2` asm), and do they do anything at run
time (dynamic, proved live *both* ways: nonzero when on, exactly zero when off)?

**The grep must be scoped: count `ldr xzr` / `ldr wzr`, never every `ldr`.** The
enemy's read half is `(void)*l`, a load whose value is discarded. `volatile` forces
the compiler to perform it and it lowers to a load into the zero register; without
`volatile` the load is provably useless and is deleted. Measured on the emitted
code (`clang --target=aarch64-linux-gnu -O2`), inside `het_cpu_enemy` only:

| | `volatile` (shipped) | `volatile` dropped |
|---|---|---|
| loads into `xzr` | 3 | **0** — all read traffic deleted |
| stores | 5 | **2** — `st;st` collapsed to one store |

So sigma 3 (`ld;ld`) becomes a complete no-op, sigma 1 and 2 lose their read half,
and sigma 0's `*l = i; *l = i+1;` collapses into a single store — while the loop
still exists, so a naive "is there a loop with a load and a store?" check waves it
through, and a count of *all* `ldr` stays comfortably nonzero from the
`a->scratch` / `a->idx` / `a->nidx` argument-struct loads alone. `MIN_ENEMY_STORES`
= 4 for the same reason: the four sigma branches declare 2+1+1+0 scratchpad stores
between them, and a non-volatile build lands well under that.

Bite-tested in `tokens.sh selftest` section [8], which is why the checker takes
`--harness-dir`: it re-emits from source on every normal run, so a negative control
has nothing to land on unless it can be pointed at an already-emitted (mutated)
harness dir.
