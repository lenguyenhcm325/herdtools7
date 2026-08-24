# HipLang — the AMD HIP emitter

`litmus/HipLang.ml` is the AMD sibling of `CudaLang` (see `cuda-emitter.md`). It
turns the GPU-only LISA/Bell scoped corpus (`hetlitmus/tests/gpu-only/*.litmus`)
into AMD **HIP** C++ (`.hip`) litmus kernels, one per test — **Route B** of the
frontend decision (reuse the Bell/LISA scoped IR; no native arch). The `.litmus`
layer is vendor-neutral, so the same corpus feeds both vendors; the vendor
difference lives only in the emitter, and `-gpu-target` is what picks one
(`litmus/hetDialect.ml`).

## What ships
- **`litmus/HipLang.ml`** — the emitter. Consumes the *parsed* `BellBase`
  scoped program (not the litmus7 `Out` template, which would flatten the
  order+scope annotation into an opaque `memo`), exactly as CudaLang does. The
  `BellBase` accessors, the launch layout and the whole-test driver come from
  `litmus/gpuLang.ml`, which both emitters instantiate; this file holds the HIP
  lowering and the emitted HIP tokens.
- **`litmus/hetGpuOnly.ml`** — the `` `LISA `` arm emits the render
  `-gpu-target` names, `.hip` (HipLang) or `.cu` (CudaLang), from the parsed
  test, then returns `Absent` (DumpRun does not try to compile/tar it).
- **`hetlitmus/emit-hip.sh`** — regenerates all `.hip` from the corpus into
  `hetlitmus/hip-out/` (`hip-out/.gitignore` keeps only `*.hip`). It is the
  HIP-side entry point of `hetlitmus/emit-gpu.sh`, which it calls with
  `-gpu-target hip`: one vendor per pass, so filling both trees is two passes.

Build: `make all` in the repo root. Emit: `./hetlitmus/emit-hip.sh`.

## Mappings (grounded)
HIP scoped atomics are Clang builtins. Memory locations are kernel `int*`
parameters, so the pointer is passed directly (no `&`/deref). Grounded against
the ROCm HIP headers (ROCm/clr `hipamd/include/hip/amd_detail/amd_hip_atomic.h`):

```
__hip_atomic_store(ptr, val, memorder, scope);
v = __hip_atomic_load(ptr, memorder, scope);
// also __hip_atomic_exchange / _compare_exchange_strong / _fetch_add ...
```

| LISA annotation | HIP token |
|-----------------|-----------|
| order `relaxed` | `__ATOMIC_RELAXED` |
| order `acquire` | `__ATOMIC_ACQUIRE` |
| order `release` | `__ATOMIC_RELEASE` |
| order `acq_rel` | `__ATOMIC_ACQ_REL` |
| order `sc`      | `__ATOMIC_SEQ_CST` |
| scope `cta`     | `__HIP_MEMORY_SCOPE_WORKGROUP` (=3) |
| scope `gpu`     | `__HIP_MEMORY_SCOPE_AGENT` (=4) |
| scope `sys`     | `__HIP_MEMORY_SCOPE_SYSTEM` (=5) |

The `__HIP_MEMORY_SCOPE_*` ladder is `SINGLETHREAD=1, WAVEFRONT=2, WORKGROUP=3,
AGENT=4, SYSTEM=5` (verbatim from `amd_hip_atomic.h`). The cta/gpu/sys ↔
workgroup/agent/system mapping is the AMD half of the vendor ladder
cta↔workgroup, gpu↔agent, sys↔system.

**Fences (order + scope; read under a gate at source level — see *Compile
status* below).**
The `-F` variants do synchronise with release/acquire *atomics*, not fences —
their sources carry no fence intrinsic at all (`gpu-only-corpus.md`, "Why the
synchronised verdicts hold") — but the corpus is not fence-free: the
`-fence` families carry `f[order,scope]` in **42 of the 173** gpu-only and
**180 of the 471** het `.litmus`. Every one of those renderings is read under a
*gate*: `make hetlitmus-hipsrc` checks all 644 of the AMD lane's renders (173
gpu-only + 471 x86_64 het), plus two synthetic carriers for the fence annotations
the corpus lacks (`f[acq_rel,sys]`, `f[relaxed,sys]`), against their annotations
at source level ([`amd-faithfulness.md`](amd-faithfulness.md)), and `make hetlitmus-hipbuild`'s
`fence-lowering` phase compiles one of them as the harness itself ships it,
failing outright where `hipcc` is absent. What each settles is *Compile status*
below.
HipLang lowers a fence to the Clang builtin
**`__builtin_amdgcn_fence(<order>, "<scope-string>")`**, which carries **BOTH**
the memory order and the sync scope — the AMD counterpart of CudaLang's faithful
inline-PTX `fence.<order>.<scope>`.

This **supersedes** the old `__threadfence{,_block,_system}` lowering, which
carried only the *scope* and was always a **full fence**: it silently dropped the
annotated order (a `release` fence became a full fence) and over-synchronised.

| LISA fence annotation | HIP emission |
|-----------------------|--------------|
| `f[release,sys]`  | `__builtin_amdgcn_fence(__ATOMIC_RELEASE, "");`        |
| `f[acquire,cta]`  | `__builtin_amdgcn_fence(__ATOMIC_ACQUIRE, "workgroup");` |
| `f[acq_rel,gpu]`  | `__builtin_amdgcn_fence(__ATOMIC_ACQ_REL, "agent");`  |
| `f[sc,sys]`       | `__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "");`       |

The **order** reuses the same `__ATOMIC_*` mapping as the atomics. The **scope
string** is the AMDHSA LLVM sync-scope name: `cta → "workgroup"`, `gpu →
"agent"`, and `sys → ""` — **system scope is the empty string** (the default sync
scope; naming a scope here would silently *narrow* it, so the `""` is
load-bearing). A `relaxed` fence is meaningless (a no-op in the C11/AMDGPU model;
`__builtin_amdgcn_fence` accepts only acquire/release/acq_rel/seq_cst), so HipLang
emits **nothing executable** for it, only a `// f[relaxed,scope] (relaxed fence =
no-op; ...)` comment. Each emitted fence keeps a trailing `// f[order,scope]`
traceability comment.

## Launch geometry
Same as CudaLang: a *workgroup* (block) = a maximal subtree rooted at a `cta`
node in the scope tree, numbered in DFS order; each proc is guarded by
`if (blockIdx.x == B && threadIdx.x == L)`. Every corpus test places each proc in
its own workgroup, so `MP-cta-F` puts the two threads in *distinct* workgroups —
the moral-strength / scope-mismatch demonstration. Host launch uses
`hipLaunchKernelGGL(litmus_X, dim3(nblocks), dim3(blockdim), 0, 0, ...)`.

## Compile status & next steps
- **HIP compile:** ROCm/`hipcc` is installed, so the emitted
  `.hip` *can* be compile-checked rather than merely emitted.
  `hetlitmus/compile-hip.sh [INDIR] [OUTDIR]` cross-compiles every `.hip` in
  INDIR for the MI300A ISA (`gfx942`) with `hipcc --offload-arch=gfx942
  -std=c++17 <test>.hip -o <test>`, a by-hand build of one host binary per
  render; the gated compiles (next bullet) each build one render, not all of
  them. `amdclang++` accepts the
  `__hip_atomic_*` / `__HIP_MEMORY_SCOPE_*` builtins (nvcc does **not**, so this
  requires the HIP-Clang stack, not HIP-over-CUDA). A clean build proves the
  scope/order lowering is valid for the target ISA; it does NOT validate
  memory-model behaviour. The host `main()` is illustrative scaffolding (launch
  geometry + result-buffer layout), as on the CUDA side.
- **What a target actually compiles.** Two *gated* AMD compile paths, both
  under the `hetlitmus-test-toolchain` umbrella:
  - `make hetlitmus-hipbuild` (`verify/hipbuildcheck.py`) compiles, links and
    re-builds one emitted x86 harness, `MP-cg-sys-acqrel-2s-x86_64`, and
    **fails** when `hipcc` is absent; its `hip-compile` phase also requires
    `comp.sh hip` to fail on a scratch copy that does not compile, since the
    script's closing `HetLitmus: compile OK` echo is unconditional and only its
    `set -e` guards it. Its `fence-lowering` phase renders the fence-carrying
    `MP-cg-sys-fence-x86_64`, builds it through the harness's own `comp.sh hip`
    (`litmus/HipLang.ml`, `hip_fence_scope`), and requires `hipcc` to refuse the
    same fence with its scope spelt `"system"`.
  - `make hetlitmus-smoke` (`verify/smoke.sh` rep 7,
    `MP-cg-sys-relaxed-x86_64`, `hipcc -c` only) **skips with exit 0** when
    `hipcc` is absent — never a pass.

  `compile-hip.sh` sits beside them as a manual convenience: no make target and
  no gate invokes it, and its default INDIR is `hip-out/`, the 10 committed
  goldens — all fence-free. CUDA has no `compile-cuda.sh` twin; neither that absence nor this script's presence is a
  coverage claim either way.
- **What reads the emission without a compiler.** `make hetlitmus-hipsrc`
  (`verify/hipsrccheck.py`), on the CUDA-free lane: it checks the same 644
  renders, plus the two synthetic fence carriers, at source level — each model
  op's builtin, order-constant, scope-constant, traceability comment and
  operands against its `.litmus` cell,
  the het scaffolding and loop structure, and the x86_64 CPU column's asm block
  ([`amd-faithfulness.md`](amd-faithfulness.md)).
- **Hardware runs (deferred):** MI300A runs + stressing + tallying `__out`
  against the `condition` line.
- **Reference verdicts:** the PLDI'23 artifact's are AMD GCN3; MI300A is CDNA3,
  several generations past GCN3, so they do not transfer, no CDNA3 reference
  replaces them, and this project derives none of its own.

## Grounding sources
- HIP scoped-atomic builtins + `__HIP_MEMORY_SCOPE_*` ladder: ROCm/clr
  `hipamd/include/hip/amd_detail/amd_hip_atomic.h` (fetched from the ROCm
  GitHub source).
- Faithful fence builtin `__builtin_amdgcn_fence(<order>, "<scope>")`: LLVM
  review **D75917** ("Expose llvm fence instruction as clang intrinsic",
  `reviews.llvm.org/D75917`) — first arg is a C11 order constant
  (`__ATOMIC_{ACQUIRE,RELEASE,ACQ_REL,SEQ_CST}`), second arg is an AMDHSA LLVM
  sync-scope string; the clang builtin tests use `"workgroup"`, `"agent"`, and
  `""` (system). The exact sync-scope string names come from the LLVM
  `AMDGPUUsage` "AMDHSA LLVM Sync Scopes" table, among them `"workgroup"`,
  `"agent"`, `"wavefront"`, `"singlethread"`, and **system = the default =
  empty string**. (This
  **replaces** the earlier `__threadfence{,_block,_system}` lowering, which
  carried scope but not order.)
