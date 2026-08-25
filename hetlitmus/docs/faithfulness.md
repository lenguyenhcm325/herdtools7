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
(`hipsrccheck.py`, `make hetlitmus-hipsrc`, base lane), over its own two
corpora — the gpu-only corpus plus the **x86_64** rendering of the het corpus,
not the AArch64 rendering read here — and two synthetic fence carriers; the
censuses are `verify/census.py`'s. What `hipcc` lowers that source to is
unverified.

## Why this is the right guard

libcu++'s `cuda::atomic_thread_fence` cannot express a release-only or
acquire-only fence [CCCL], so `CudaLang` emits faithful inline PTX instead
([`cuda-emitter.md`](cuda-emitter.md), "Fence lowering"). This check proves
that faithfulness **end-to-end through nvcc**, and FAILs the day a
collapse/weakening/narrowing returns — whether introduced by `CudaLang`, by a
libcu++ upgrade, or by a toolkit change.

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

> These three are the table's keys (`GPU_KIND`) and the corpus vocabulary
> (`ptx.bell` declares only `R`/`W`/`F`). An RMW cell is a completeness
> hard-fail, not a table row: `GPU_CELL` accepts only a `w`/`r`/`f` cell and
> refuses any other as `unrecognized GPU cell` (exit 2). An `rmw` row would
> first need `GPU_CELL` extended, and `atom`/`red` are two opcodes the compared
> `(kind, order, scope)` tuple cannot express. The `acq_rel`/`sc` orders stay
> table keys (`GPU_ORDER`) though no corpus access carries them.

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
in its option, so the compared CPU tuple is (mnemonic, barrier option):
`CPU_BARRIER_OPTION` maps `sy` → the full barrier, `st` → {WW}, `ld` →
{RR,RW}. `DMB ST` where `DMB SY` is expected is therefore a positional
mismatch, and an option outside that table (`ish`, say) or a `DMB` with no
option is a completeness hard-fail (`barrier_option`). All three reach the
corpus: the generator's `st`/`ld` order-pair tokens render an intra-proc edge
as `DMB ST`/`DMB LD` (`_grid_lib.sh`, `render_cpu_cycle` with
`fence-st`/`fence-ld`).

## Sources

* **NVIDIA PTX ISA** (CUDA **12.9** nvcc, the toolkit version CI pins in
  `hetlitmus-ci.yml`, emits `.version 8.8`): `ld` §9.7.9.8, `st` §9.7.9.11,
  `membar`/`fence` §9.7.14.4, `atom` §9.7.14.5, `red` §9.7.14.6 —
  <https://docs.nvidia.com/cuda/parallel-thread-execution/index.html>.
  These ground the qualifier vocabulary: `ld{.relaxed,.acquire}`,
  `st{.relaxed,.release}`, `fence{.sc,.acq_rel,.acquire,.release}`, scope
  `{.cta,.gpu,.sys}`, sem-before-scope; `atom` is an RMW returning the
  old value, `red` a reduction with no return. The ISA lets a `fence` elide
  its order (`fence{.sem}.scope`, `.acq_rel` assumed) and spells the legacy
  form `membar.level`; the emitter writes neither — every fence it emits is
  `fence.<order>.<scope>` — and `classify_ptx_op` reads a `fence` or `membar`
  line with no order token as scaffolding, so either form in a model fence's
  place surfaces as a missing op. The qualifiers are read order-agnostically
  (`CudaLang` emits `fence.<order>.<scope>`, libcu++ `fence.<scope>.<order>`).
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

## What is checked, for every op, both directions

For each test the checker builds the **expected profile** from the `.litmus` and the
**observed profile** from the PTX (and `_cpu.c`), then asserts:

1. **ORDERED equality** of the model-op streams (`check_gpu`) — element-wise
   `(kind, order, scope)` equality. The one compare subsumes kind, order,
   scope, multiplicity **and placement** (a fence between the right accesses;
   load/store order preserved; a missing or extra op shifts every position
   after it). A strengthening (`relaxed`→`acquire`) or weakening
   (`release`→`relaxed`) shows up as a positional mismatch, printed as
   `[i] expected … observed …`.
2. **(het) nothing ahead of the rendezvous** (`check_no_pre_barrier_ops`) — no
   model op may precede the first rendezvous arrival: an op ahead of it sits
   outside every lane segment and would be compared against nothing, so it is
   a FAIL in its own right.
3. **(het) rendezvous whitelist** (`check_barrier_whitelist`) — the
   system-scope rendezvous must span both devices and **order nothing**: every
   op `sys`-scoped (never narrowed), every op **relaxed**, **no fence anywhere
   in it**, and one arrival (`atom`/`red`) per joining GPU lane. Relaxed and
   fence-free is a correctness property, not a preference:
   `00-environment-design.md` §3.3 ([Bagchi26 §5.3]).
4. **No stray system-scope op** (`check_no_stray_sys`) — no `sys`-scoped op
   outside the inline-asm markers, where the model-op compare cannot see it (a
   builtin sys-scope op is invisible to it). This is the only text the checker
   reads outside the markers, so a builtin op of narrower scope there is not
   seen — which is why the stress layer is built from builtins and plain
   accesses that never enter the model-op stream (`het_stress.h`'s scaffolding
   counters lower to bare `atom.global.*` with no order token).
5. **(het) CPU column** (`check_cpu`) — the ordered memory/ordering mnemonics
   of the `.litmus` CPU column, barrier option included, must reproduce in the
   emitted `_cpu.c` real-asm block (under `#if defined(__aarch64__)`), catching
   `STLR`→`STR`, `LDAPR`→`LDR`, a `DMB` dropped, and `DMB ST` for `DMB SY` as
   a positional mismatch. The block is litmus7's own
   (`#START _litmus_P<n>` … `#END`), so the reader skips those markers and reads
   `%w[x0]`/`%[x]`-style operands.

### Het rendezvous/model separation

Each GPU proc is emitted as its own guarded block whose iteration loop runs
`{ rendezvous; release jitter; model… }`, so the rendezvous is **not** a single
prologue — there is one arrival per GPU proc, and it recurs every iteration
while the text carries it once. The arrival is the unique anchor: the corpus
model has **no** `atom`/`red`, so every system-scoped `atom`/`red` in the kernel
is a rendezvous arrival. `split_het_segments` cuts the op stream at each
arrival and takes the template `[arrival][optional fence][poll]` off each
segment's front; the remainder is that lane's model ops, in lane order. A
fence directly after an arrival belongs to the template — it is scored into
the whitelist and named there as a finding — while a fence after the poll is a
model op, so a lane whose column begins or ends in a fence (`f[sc,sys]`, say)
is compared, not refused.

## Completeness guard (never silently skip)

The mapping table **is** the guard. Building the expected profile looks up every
order, scope, op-kind, CPU mnemonic and barrier option in the table; a token
that is not a key raises `CompletenessError`, which **hard-fails the test with
exit 2** — it is never skipped. `tokens.sh` scores that exit as `GUARD-FAIL` in
`run_one`, and `run_paths` turns it into a nonzero exit, in `all` (the cover)
and `full` (both corpora) alike.

A het column with no device tag (`P<n>` without `:cpu`/`:gpu`) is the same
hard-fail, in `parse_body`, never defaulted to gpu: defaulting would send a CPU
column through `gpu_ops_of_column` and compare AArch64 mnemonics against PTX —
a wrong answer rather than a refusal. A gpu-only (`LISA`) test omits the tag,
and its columns are gpu.

Distinct annotations in the corpus (every one a table key):

```
GPU: w/r[relaxed,{cta,gpu,sys}]  w[release,{cta,gpu,sys}]  r[acquire,{cta,gpu,sys}]
     f[sc,{cta,gpu,sys}]  f[release,sys]  f[acquire,sys]
CPU: MOV STR LDR STLR LDAPR DMB{SY,ST,LD}
```

## How to run

```
# the gate (= make hetlitmus-faithful): covercheck.py, then ptxcheck.py over
# every test verify/faithful-cover.txt lists
bash hetlitmus/verify/tokens.sh all

# both corpora entire, or one of them
bash hetlitmus/verify/tokens.sh full
bash hetlitmus/verify/tokens.sh gpu-only
bash hetlitmus/verify/tokens.sh het
JOBS=4 bash hetlitmus/verify/tokens.sh full   # worker count; default nproc, capped at 12

# a single test (full pipeline: emit -> nvcc --ptx -> check); -q drops the per-check lines
python3 hetlitmus/verify/ptxcheck.py hetlitmus/tests/gpu-only/MP-sys-F.litmus

# the one required rejection: a frozen corrupted PTX, no nvcc (pinned in
# hetlitmus/tests/cram/ptx-negatives.t)
python3 hetlitmus/verify/ptxcheck.py hetlitmus/tests/gpu-only/MP-sys-F.litmus \
        --ptx hetlitmus/tests/cram/corrupt-strengthen.ptx
```

`ptxcheck.py` exits **0 = PASS**, **1 = FAIL** (with an exact per-position diff),
**2 = completeness hard-fail**, **3 = tool/emit error**. Requirements: `litmus7`
built in `_build` (`make all` at the repo root) and `nvcc` on `PATH`
(`tokens.sh` prepends `/usr/local/cuda/bin`). It compiles at `sm_90`, the arch
the emitted `Makefile`/`comp.sh` build the same `.cu` with
(`litmus/hetDialect.ml`, `gd_arch_default`); it takes no arch flag.

**The cover.** `faithful-cover.txt` is a repo-relative list of tests drawn from
both corpora, `census.COVER` long. `covercheck.py` recomputes every feature of
both corpora with ptxcheck's own parsers (its docstring is the feature list of
record) and fails if a feature reaches no listed test, if a listed test is not
in the corpus, or if the list length is not `census.COVER`. `--extend` adds
tests greedily and never drops one; afterwards `COVER` in `census.py` and
`CENSUS_COVER` in `census.sh` are hand-edited (`README-tests.md`, Notice 10).

## Result

`tokens.sh all` prints, with the pins of `census.py`/`census.sh` in place of the
angle brackets:

```
COVER OK: <COVER> tests cover all <n> features of the <GPU_ONLY+HET>-test corpus
TALLY cover: <COVER>/<COVER> PASS  (FAIL=0  GUARD-FAIL=0  ERROR=0)
```

`tokens.sh full` prints `TALLY gpu-only: <GPU_ONLY>/<GPU_ONLY> PASS …` and
`TALLY het: <HET>/<HET> PASS …` instead, each sweep censused against
`census.sh`'s pin in `run_paths`, so an empty or misnamed corpus directory is a
`CENSUS FAIL`, not a vacuous pass.

* **Rejection:** the frozen `corrupt-strengthen.ptx` — `MP-sys-F` with its one
  `ld.relaxed.sys` strengthened to `ld.acquire.sys` — fed through `--ptx` FAILs
  (exit 1, with the exact `[idx] expected … observed …` diff), pinned byte for
  byte in `hetlitmus/tests/cram/ptx-negatives.t`.
* **Completeness:** every annotation listed above, every CPU mnemonic and every
  barrier option is a table key; one that is not raises `CompletenessError`
  (exit 2).

## Scope / limits

* This check proves **static lowering** faithfulness (annotation → emitted PTX/asm
  token).
  Runtime reordering by ptxas/hardware is the *behaviour under test* on real
  hardware, not a concern of this check.
* It is hardware-free: `nvcc --ptx` and reading text only; no kernel runs.
* `MOV` is neither a memory nor an ordering op — litmus7's lowering emits it to
  materialise a store value in a register — so it is intentionally excluded from
  the CPU comparison; only memory/ordering mnemonics are compared.
* No `acq_rel`/RMW/`sc`-on-access appears in the corpus (what an RMW cell does
  to the guard: the op-kind table's note above).
* **ptxcheck is BLIND to the stress layer, by design.** Stress is scaffolding,
  not a tested op: it carries no order/scope qualifier and sits outside the
  inline-asm markers, so it never enters the op stream this checker compares —
  correct, but it means *no check here can tell whether the stress layer exists
  at all*. The hazard is concrete: a compile-time access pattern lets nvcc fold
  `het_do_stress`'s if-chain and hoist its loads while every check here stays
  green (measured under "What a compile-time access pattern costs" below); the
  shipped pattern is a runtime kernel argument. The other half of the static
  check is therefore **`hetlitmus/verify/stresscheck.py`** (`make
  hetlitmus-stress`), which counts scratchpad ops in the emitted PTX per lane
  class and asserts the count is *invariant* under `-DHET_*_PATTERN` — i.e.
  that no stress configuration can silently switch it off. **A mechanism no
  gate can observe must be assumed dead**: if you add scaffolding here, add the
  gate that watches it.

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
iteration loop:

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
because a model location is an `int`, which is why `stresscheck.py` pins the
baseline and reads every stress count as a difference from it rather than as an
absolute.

Asking harder does not help: the count stays at 2 with `HET_PRE_STRESS_PCT=100`,
because raising how *often* a lane calls a hoisted loop adds nothing. `volatile`
is not the fix either — it holds the accesses inside the loop by changing what
they are, and this stress is meant to be plain, non-volatile, ordinary cacheable
traffic (`litmus/het-runtime/het_stress.h` carries that constraint and its
source). The same fold reaches mem-stress, where a stress block's 49 ops become
16, 13, 12 or 2 as the compile-time pattern moves 0 → 1 → 2 → 3. That is what a
sweep over `pattern ∈ {0,1,2,3}` would be scoring — a knob deciding how much
stress exists rather than which stress it is, and no other gate in this suite can
tell those configurations apart — which is why `stresscheck.py`'s `pre`/`mem`
pattern-invariance checks (each lane class keeps ≥ 1 scratchpad load **and**
store at every `-DHET_{PRE,MEM}_STRESS_PATTERN=0..3`, and the count does not
move) are the load-bearing ones rather than a formality.

## Proving the GPU stress ran, not just that it exists

`stresscheck.py`'s static checks — `anchor`, `pre`, `mem`, `gpu-noise-live`,
`gpu-noise-runtime` — read the emitted PTX: the scratchpad accesses are there
and their count is invariant under the `-D` pattern knobs, and the device half
of the interconnect noise pair survives too (the volatile 64-bit noise loads
outlive nvcc, and their count is invariant over `-DHET_NOISE_GPU_BLOCKS`).
Nothing static can say the loop ever *executed*.

**The runtime tally is the other half.** `het_stress.h` counts rounds through
`HET_TALLY_STRESS_ROUNDS` — an `atomicMax` of the rounds any single
`het_do_stress` call completed, overflow-free like `NOISE_ROUNDS` — the emitted
driver reads it back into `het_obs_record.gpu_stress_rounds`, and
`het_verdict()` raises `HET_DQ_GPU_STRESS_DEAD` when the stress was requested
and that tally is zero (`harness-reporting.md` §3). A counter is evidence only
if it can be shown to move **and** to stay at zero, so `stresscheck.py`'s
`device-probe` check drives `het_do_stress` on the device present (compiled
`-arch=native`) at one access pattern, pattern 0, × {iters=64, iters=0} and
asserts both directions: nonzero when the loop is asked for, exactly zero when
it is not. One pattern suffices because `rounds++` sits after the pattern
if-chain in `het_do_stress` (`het_stress.h`), inside the loop and outside every
branch, so the tally counts rounds whichever branch runs. `--no-device` (`make
hetlitmus-stress-static`) drops that check alone, and the gate prints that it
did (`device-probe SKIPPED`).

**The two halves are not redundant.** The tally proves the loop *ran*; the
structural checks prove it still *contains* its scratchpad accesses and that no
`-D` can switch them off. The blind spot recorded under "Scope / limits" above —
a layer present in the source, gone from the emitted PTX, and green on every
gate — is exactly what neither half alone catches.

The tally also watches a failure the compiler is not responsible for. Stress
blocks fill what the co-residency cap leaves over the test lanes, so the stress
population is the first thing that cap squeezes to zero: the code present,
requested, and executed by nobody. The emitted driver warns about that case
explicitly *before* the run, rather than leaving it to the tally afterwards
(`litmus/hetEmit.ml`).

## CPU-side stress liveness

`hetlitmus/verify/cpustresscheck.py` is the CPU/interconnect sibling of
`stresscheck.py`, and needs no nvcc. The cache preload, the CPU enemy threads
and the CPU half of the interconnect noise pair are invisible to *both* PTX
checkers — the preload emits host cache hints (no order, no scope, not a model
op), the enemies are host code that never reaches the PTX, and the noise
streams a disjoint buffer — so that layer is unguarded without it (the pair's
device half is `stresscheck.py`'s `gpu-noise-live`/`gpu-noise-runtime`). It
asks two questions the structural gates cannot: did the mechanisms survive the
optimiser (static, on the **compiled** `-O2` asm), and do they do anything at
run time (dynamic, proved live *both* ways: nonzero when on, exactly zero when
off)? Its checks: static, off the `-O2` asm of both host ISAs —
`preload-prims-aarch64`, `enemy-loop` and `enemy-seq-runtime` on the AArch64
asm, `preload-prims-x86` on the x86_64 asm (each through
`clang --target=<triple>`, so the x86 arm reads x86 asm on any host); dynamic,
on the host running the gate (`gcc`) — `stress-live`, `stress-off-zero`,
`first-touch` (a host without `/proc/self/statm` is a FAIL, not a skip);
structural, on the emitted driver — `preload-guard-field`,
`preload-guard-term`.

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
