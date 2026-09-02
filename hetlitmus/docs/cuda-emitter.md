# CUDA emitter (CudaLang)

`litmus/CudaLang.ml` renders a scoped LISA/Bell test
(`hetlitmus/tests/gpu-only/*.litmus`) as one CUDA C++ kernel (`.cu`) over
libcu++ scoped atomics and inline-PTX fences. The Bell/LISA scoped IR is the
GPU frontend; there is no native PTX architecture.

## What ships
- `litmus/CudaLang.ml` — the CUDA lowering and the emitted tokens.
- `litmus/gpuLang.ml` — the half shared with `HipLang` (vocabulary check,
  launch layout, whole-test driver), parameterised by a `GpuLang.t` record.
- `litmus/hetGpuOnly.ml` — the `` `LISA `` arm of `litmus/top_litmus.ml`'s
  arch dispatch: renders the one dialect `-gpu-target` names
  (`litmus/hetDialect.ml`) into the `-o` directory and returns `Absent`, so
  `DumpRun` neither C-compiles nor tars the output.
- `hetlitmus/emit-cuda.sh [OUTDIR]` — renders the corpus (default
  `hetlitmus/cuda-out/`) through `hetlitmus/emit-gpu.sh`.

## How it works (and why this shape)
Upstream litmus7 has no LISA emission: its `` `LISA `` arm is `assert false`,
and LISA reaches only klitmus7. HetLitmus reuses litmus7's LISA parser but not
its `Skel` harness, which wraps each thread in a pthread — the wrong shape for
a kernel. The emitter consumes the parsed program (`A.pseudo MiscParser.t`),
not the litmus7 `Out` template: the template flattens a scoped access into an
opaque `memo` string and loses the order+scope pair, whereas matching
`BellBase.Pld`/`Pst (_, _, annots)` keeps the mapping exact.

## Mappings
Scoped atomics are libcu++'s [CCCL]: `<cuda/atomic>`,
`cuda::atomic_ref<int, cuda::thread_scope_*> ref(*x)` with `ref.store(v, order)`
/ `ref.load(order)` over kernel `int*` parameters. Every access, relaxed data
included, is an `atomic_ref` op carrying its annotated order and scope, so the
kernel is data-race-free under the CUDA C++ model.

| LISA annotation | libcu++ token |
|-----------------|---------------|
| order `relaxed` / `acquire` / `release` / `acq_rel` / `sc` | `cuda::memory_order_relaxed` / `_acquire` / `_release` / `_acq_rel` / `_seq_cst` |
| scope `cta` / `gpu` / `sys` | `cuda::thread_scope_block` / `_device` / `_system` |

Which orders each op kind admits is `hetlitmus/bells/ptx.bell`'s
(`het-emission.md`, "Scope / limits"); why each token is the faithful one is
`faithfulness.md`, "The mapping". No cluster scope: the vocabulary
declares `cta`/`gpu`/`sys` only, and PTX `.cluster` has no HIP scope.

Launch layout: a block is a maximal subtree rooted at a `cta` node of the scope
tree, numbered in DFS order. Both dispatch arms read the tree through
`GpuLang.scopes_of`, so the compound harness has the same geometry
(`het-emission.md`, "Scope / limits"). Every gpu-only corpus test places each
proc in its own `cta`, so a `cta`-scope release/acquire pair such as `MP-cta-F`
spans two CTAs: a scope-mismatch test, not a same-CTA one.

## Fence lowering
A fence is inline PTX, `fence.<order>.<scope>` (`ptx_fence_sem`, `ptx_scope`),
not `cuda::atomic_thread_fence`: libcu++ lowers acquire, release and acq_rel
alike to `fence.acq_rel.<scope>` and so cannot express the order the annotation
carries [CCCL `cuda/std/__atomic/functions/cuda_ptx_generated.h`]. A relaxed
fence has no PTX form and no place in the vocabulary; litmus7 refuses it before
rendering (`het-emission.md`, "Scope / limits"). Why the property is read off
the PTX, not the source: `faithfulness.md`.

## nvcc compile
A render compiles with `nvcc -std=c++17 -arch=sm_90`; `sm_90` is also the
default of the emitted build files (`hetDialect.ml`, `gd_arch_default`). PTX
floors [CCCL `cuda/__ptx/instructions/generated/fence.h`]: `fence.{sc,acq_rel}`
need PTX ISA 6.0 / sm_70, `fence.{acquire,release}` PTX ISA 8.6 / sm_90.
`ptxas` (CUDA 12.9) accepts both kinds at sm_70 and enforces neither floor, so
the floor is carried by the target the build names and by the trailing
`// requires sm_90` / `// sm_70+` comment on each emitted fence
(`fence_min_arch`), not by a compile error.

## Limits
- The gpu-only host `main()` launches the kernel in a loop and tallies nothing;
  tallying, the per-iteration rendezvous and the stress layers live on the
  heterogeneous path (`het-emission.md`, `00-environment-design.md`).
- No expected verdicts: the tool reports what it observed and derives none.
