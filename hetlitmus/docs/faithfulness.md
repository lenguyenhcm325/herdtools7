# PTX/AArch64 lowering faithfulness

**The property:** every emitted GPU harness, and the CPU harness of a het
test, carries exactly the memory **order + scope + op kind** its `.litmus`
annotation specifies: no weakening, strengthening, miscount, misplacement or
missing qualifier. It is a static property of the emitted text, settled with
no kernel launched:

```
.litmus annotation  --(litmus7/CudaLang)-->  .cu
                    --(nvcc --ptx)-------->  PTX, one (kind,order,scope) token per model op
```

This document covers the CUDA renders: the gpu-only corpus and the AArch64
rendering of the het corpus. The AMD lane states the same property on the
emitted HIP source, over the gpu-only corpus and the x86_64 rendering of the
het corpus: [`amd-faithfulness.md`](amd-faithfulness.md).

## Why the property is stated on the PTX

`cuda::atomic_thread_fence` cannot express a release-only or acquire-only
fence [CCCL], so `CudaLang` emits every fence as inline PTX
([`cuda-emitter.md`](cuda-emitter.md), "Fence lowering"). Stating the
property on the PTX nvcc produces covers every point where a collapse can
enter: the emitter, a libcu++ upgrade, a toolkit change.

The `nvcc --ptx` text is a witness of the emitted order because:

* libcu++ scoped accesses are `asm volatile(... ::: "memory")` [CCCL], and
  the emitted fence is the same form. nvcc keeps such statements in program
  order and brackets each with `// begin inline asm` / `// end inline asm`,
  so the textual order of the inline-asm ops is the source order, relaxed
  ops included.
* Harness scaffolding (`ld.param`, `st.global`, `cvta`, the readout stores)
  sits outside the markers and carries no order qualifier.
* `CudaLang` emits procs in column order and cells in row order, so the
  flattened PTX op stream corresponds cell for cell to the `.litmus`.

## The mapping

PTX spells order and scope as the LISA/Bell tag does, order before scope
(`ld.relaxed.gpu`, `fence.sc.cta`).

| annotation | PTX | emitted on |
|---|---|---|
| `relaxed` | `.relaxed` | ld, st |
| `acquire` | `.acquire` | ld, fence |
| `release` | `.release` | st, fence |
| `acq_rel` | `.acq_rel` | fence |
| `sc` | `.sc` | fence |

| scope | PTX | `thread_scope` |
|---|---|---|
| `cta` | `.cta` | `thread_scope_block` |
| `gpu` | `.gpu` | `thread_scope_device` |
| `sys` | `.sys` | `thread_scope_system` |

| LISA mnemonic | PTX opcode |
|---|---|
| `w` | `st` |
| `r` | `ld` |
| `f` | `fence` |

`gpu.bell` declares `R`/`W`/`F` only and the GPU column refuses an RMW
([`het-emission.md`](het-emission.md), "Scope / limits"), so `atom`/`red`
have no row. An `sc` access is admitted by the vocabulary but lowers in
libcu++ to a `fence.sc` followed by an acquire load or a relaxed store
[CCCL]; no corpus test carries one.

### CPU column (AArch64)

litmus7 reproduces the column's mnemonics verbatim in the `_cpu.c` asm block
(`#START _litmus_P<n>` … `#END`, under `#if defined(__aarch64__)`). A CPU
op's identity is the pair (mnemonic, barrier option): `DMB SY` orders reads
and writes on both sides, `DMB ST` writes before against writes after,
`DMB LD` reads before against reads and writes after [ArmA64ISA "DMB"], so
`DMB ST` in `DMB SY`'s place is a different instruction, not a spelling
variant, and a `DMB` with another option or none has no row. `MOV`
materialises a store value in a register and is not a memory or ordering op.

| mnemonic | semantics |
|---|---|
| `STLR` | store-release [ArmA64ISA "STLR"] |
| `LDAPR` | load-acquire, RCpc (FEAT_LRCPC, Armv8.3) [ArmA64ISA "LDAPR"] |
| `DMB SY` / `DMB ST` / `DMB LD` | barrier; the option names the access types it orders |
| `STR` / `LDR` | plain store / load |

The RCpc choice is the corpus generator's: the two-sided acquire atom `Q` is
upstream's `ReadAcqPc` (`gen/common/AArch64Arch_gen.ml`), which
`gen/AArch64Compile_gen.ml` lowers to `LDAPR`, so the emitted build compiles
`<t>_cpu.c` with `-march=armv8.3-a` (`litmus/hetCpuFront.ml`). `DMB ST` and
`DMB LD` come from the `st`/`ld` order-pair tokens (`_grid_lib.sh`,
`render_cpu_cycle`).

## The property, op by op

The `.litmus` fixes an expected profile; the emitted PTX (and, for het
tests, `_cpu.c`) carries an observed one. The harness is faithful when:

1. **The model-op streams are equal in order**: element-wise `(kind, order,
   scope)` equality of the flattened streams. Ordered equality subsumes
   multiplicity and placement, and reads a strengthening or a weakening as a
   positional difference.
2. **(het) No model op precedes the first rendezvous arrival**: an op ahead
   of it belongs to no lane.
3. **(het) The GPU arm of the rendezvous orders nothing**: every op
   `sys`-scoped and relaxed, no fence, one arrival per joining GPU lane. Why
   relaxed and fence-free is a correctness property, and what each arm
   lowers to: `00-environment-design.md` §3.3.
4. **No stray system-scope op** outside the inline-asm markers. A builtin of
   narrower scope outside the markers is outside the property, which is why
   the stress layer is built from builtins and plain accesses
   (`het_stress.h`'s counters lower to bare `atom.global.*` with no order
   token).
5. **(het) The CPU column reproduces**: the column's memory and ordering
   mnemonics, barrier option included, in order.

### Het rendezvous/model separation

A GPU lane's iteration loop runs `{ pre-stress; rendezvous; jitter; model
ops; readout }`, so the arrival recurs every iteration and appears once in
the text. The corpus model has no `atom`/`red`, so every system-scoped
`atom`/`red` in the kernel is an arrival, and the op stream splits into one
segment per arrival: `[arrival][poll]`, then that lane's model ops in lane
order. A fence directly after an arrival belongs to the rendezvous (and
violates property 3); a fence after the poll is a model op, so a lane whose
column begins or ends in a fence is unambiguous.

## Scope / limits

* Static lowering only. Reordering by `ptxas` or the hardware is the
  behaviour under test, not part of this property.
* No `acq_rel`, no RMW and no `sc` on an access appears in the corpus.
* **One scaffolding write sits inside the tested loop.** The lane at `(0,0)`
  bumps `_gpu_iter` once per iteration, after its readout stores; it lowers
  to a bare `atom.global.add.u32` (property 4) and the stress population
  reads the iteration index off it. The rendezvous counter already carries
  the iteration, but it is a `Shared` object in the race surface and the
  word whose latency sets cross-device alignment; `_gpu_iter` is device-only
  and touched by nothing else.
* **The property is blind to the stress layer.** Stress carries no
  order/scope qualifier and sits outside the markers, so faithfulness alone
  cannot tell whether the stress layer exists. Whether it is in the emitted
  PTX and whether it ran are properties of their own (below); a mechanism
  whose execution is not observable is assumed dead, which is why the stress
  layers report run-time tallies.

### What a compile-time access pattern costs

`het_do_stress` takes its access pattern as a runtime kernel argument: the
driver reads `HET_PRE_STRESS_PATTERN`/`HET_MEM_STRESS_PATTERN` into host
variables and passes them in (`litmus/hetDriverMain.ml`). Handed a
compile-time constant instead, nvcc folds the if-chain to the one named
branch, and for `ld;ld` (the pre-stress default) both loads are
loop-invariant: nvcc hoists them, leaving one peeled pair of loads and an
empty counting loop that still feeds the round tally. The bookkeeping
survives; the traffic does not. Raising `HET_PRE_STRESS_PCT` adds nothing,
since calling a hoisted loop more often issues no more loads, and `volatile`
is not the fix, since the stress is meant to be plain cacheable traffic
(`litmus/het-runtime/het_stress.h`). The runtime argument keeps each lane
class's scratchpad load and store in the emitted PTX at every pattern.

## GPU stress liveness at run time

The emitted PTX carries the scratchpad accesses and the noise stream's
volatile 64-bit loads; nothing static says the loop executed. `het_do_stress`
counts its rounds (`rounds++` sits after the pattern if-chain, inside the
loop, so every branch counts) into `HET_TALLY_STRESS_ROUNDS` by `atomicMax`;
the emitted driver reads it into `het_obs_record.gpu_stress_rounds`, and
`het_verdict()` raises `HET_DQ_GPU_STRESS_DEAD` when stress was requested
and the tally is zero (`harness-reporting.md` §3). The two halves are not
redundant: the text says the accesses are present and no `-D` switches them
off; the tally says the loop ran. The tally also catches a failure the
compiler is not responsible for: stress blocks fill what the co-residency
cap leaves over the test lanes, so that cap squeezes them to zero first, and
the driver warns before the run (`litmus/hetDriverMain.ml`).

## CPU-side stress liveness

The cache preload, the CPU enemy threads and the host half of the
interconnect noise pair reach no PTX: the preload issues cache hints, the
enemies are host code, the noise streams a disjoint buffer. Their liveness
is two host-side properties: the mechanisms survive `-O2` on both host ISAs
(static), and the CPU tally is nonzero when a mechanism is on and zero when
it is off (dynamic).

`volatile` on the enemy's discarded load `(void)*l` is load-bearing. It
lowers to a load into the zero register; without it the load is deleted,
`ld;ld` becomes a no-op, `st;ld` and `ld;st` lose their read half and
`st;st` collapses to one store, while the loop and the argument-struct
`ldr`s remain. The enemy's read traffic is therefore its `ldr xzr` /
`ldr wzr` loads and nothing else, and the four sigma branches declare
2+1+1+0 scratchpad stores between them.
