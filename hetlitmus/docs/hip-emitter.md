# HipLang — the AMD HIP emitter (Tier-1)

`litmus/HipLang.ml` is the AMD sibling of `CudaLang` (see `cuda-emitter.md`). It
turns the GPU-only LISA/Bell scoped corpus (`hetlitmus/tests/gpu-only/*.litmus`)
into AMD **HIP** C++ (`.hip`) litmus kernels, one per test — **Route B** of the
frontend decision (reuse the Bell/LISA scoped IR; no native arch), memory
`hetlitmus-route-b-frontend`. The `.litmus` layer is vendor-neutral, so the
same corpus feeds both vendors; the vendor difference lives only in the emitter
(memory `hetlitmus-amd-oracle-task7`).

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

Build: `make all` (branch `hetlitmus-work`). Emit: `./hetlitmus/emit-hip.sh`.

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
cta↔workgroup, gpu↔agent, sys↔system (memory `hetlitmus-amd-oracle-task7`).

**Fences (order + scope; compiled by no target — see *Compile status* below).**
The `-F` variants do synchronise with release/acquire *atomics*, not fences
(memory `hetlitmus-amd-oracle-task7`), but the corpus is not fence-free: the
`-fence` families carry `f[order,scope]` in **33 of the 137** gpu-only and
**171 of the 411** het `.litmus`. HipLang lowers a fence to the Clang builtin
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
| `f[*,cluster]`    | `__builtin_amdgcn_fence(<order>, "agent");` (degraded — see below) |

The **order** reuses the same `__ATOMIC_*` mapping as the atomics. The **scope
string** is the AMDHSA LLVM sync-scope name: `cta → "workgroup"`, `gpu →
"agent"`, and `sys → ""` — **system scope is the empty string** (the default sync
scope; naming a scope here would silently *narrow* it, so the `""` is
load-bearing). A `relaxed` fence is meaningless (a no-op in the C11/AMDGPU model;
`__builtin_amdgcn_fence` accepts only acquire/release/acq_rel/seq_cst), so HipLang
emits **nothing executable** for it, only a `// f[relaxed,scope] (relaxed fence =
no-op; ...)` comment. Each emitted fence keeps a trailing `// f[order,scope]`
traceability comment.

## Cluster scope → AGENT (grounded degradation)
AMD **does** have a cluster synchronization scope: the LLVM AMDGPU memory model
defines `syncscope("cluster")` / `"cluster-one-as"`, sitting **between
`workgroup` and `agent`**, and **degrading to `agent` on targets without
workgroup-cluster launch support** (LLVM `AMDGPUUsage`, "Memory Model" / sync
scopes). So the vendor ladders align: cta↔workgroup, **cluster↔cluster**,
gpu↔agent, sys↔system.

**But HIP source cannot name it** from the *atomics* side. `amd_hip_atomic.h`
defines **no** `__HIP_MEMORY_SCOPE_CLUSTER` (only
SINGLETHREAD/WAVEFRONT/WORKGROUP/AGENT/SYSTEM); the cluster sync scope is
reachable only at the LLVM-IR level (`syncscope("cluster")`). This is the mirror
image of the CUDA side: there libcu++'s `enum thread_scope` also lacks cluster,
but NVIDIA could drop to inline PTX `.cluster`; AMD source has **no** equivalent
token. (The *fence* builtin `__builtin_amdgcn_fence` does accept a `"cluster"`
syncscope string, but HipLang keeps fences and atomics on the **same** scope
ladder so a cluster test degrades consistently rather than mixing a true
`"cluster"` fence with an agent-scoped atomic; both go to **agent**.)

HipLang therefore lowers a cluster-scoped op to the nearest **source-expressible
scope that is never weaker** — `__HIP_MEMORY_SCOPE_AGENT` for atomics, the
`"agent"` syncscope string for `__builtin_amdgcn_fence` — which is exactly the
documented hardware degradation, and **flags every such op inline**
(`// cluster -> AGENT (HIP has no __HIP_MEMORY_SCOPE_CLUSTER; see hip-emitter.md)`).
Caveat: agent is *wider* than cluster, so on a true cluster-capable target this
**over-synchronises** and may mask the weak behaviour a cluster litmus test is
meant to expose. A faithful cluster HIP test would need the LLVM-IR sync scope
(or a future `__HIP_MEMORY_SCOPE_CLUSTER`); flagged for when AMD cluster launch
is actually targeted (MI300A `gfx942` cluster-launch support is unconfirmed —
memory `hetlitmus-amd-oracle-task7`).

## Launch geometry
Same as CudaLang: a *workgroup* (block) = a maximal subtree rooted at a `cta`
node in the scope tree, numbered in DFS order; each proc is guarded by
`if (blockIdx.x == B && threadIdx.x == L)`. Every corpus test places each proc in
its own workgroup, so `MP-cta-F` puts the two threads in *distinct* workgroups —
the moral-strength / scope-mismatch demonstration. Host launch uses
`hipLaunchKernelGGL(litmus_X, dim3(nblocks), dim3(blockdim), 0, 0, ...)`.

## Compile status & next steps (HIP analog of CUDA Task 8/9)
- **HIP compile (Task 8 — DONE):** ROCm/`hipcc` is installed, so the emitted
  `.hip` *can* be compile-checked rather than merely emitted.
  `hetlitmus/compile-hip.sh [INDIR] [OUTDIR]` cross-compiles every `.hip` in
  INDIR for the MI300A ISA (`gfx942`) with `hipcc --offload-arch=gfx942
  -std=c++17 <test>.hip -o <test>`. Measured 2026-08-11 under HIP version
  7.2.53211: **10/10** on the default INDIR (`hip-out/`, the committed goldens)
  and **137/137** on a full `emit-hip.sh` of the gpu-only corpus into a temp
  dir, the 33 `-fence` renders included. `amdclang++` accepts the
  `__hip_atomic_*` / `__HIP_MEMORY_SCOPE_*` builtins (nvcc does **not**, so this
  requires the HIP-Clang stack, not HIP-over-CUDA). A clean build proves the
  scope/order lowering is valid for the target ISA; it does NOT validate
  memory-model behaviour. The host `main()` is illustrative scaffolding (launch
  geometry + result-buffer layout), as on the CUDA side.
- **What a target actually compiles.** `compile-hip.sh` is a manual
  convenience: no make target and no gate invokes it, and its default INDIR is
  `hip-out/`, the 10 committed goldens — all fence-free. The two *gated* AMD
  compile paths are `make hetlitmus-hipbuild` (`verify/hipbuildcheck.py`:
  compiles, links and re-builds one emitted x86 harness,
  `MP-cg-sys-acqrel-2s-x86_64`, and **fails** when `hipcc` is absent) and
  `make hetlitmus-smoke` (`verify/smoke.sh` rep 8,
  `MP-cg-sys-relaxed-x86_64`, `hipcc -c` only, and it **skips with exit 0**
  when `hipcc` is absent), both under the `hetlitmus-test-toolchain` umbrella. Both
  of those tests are fence-free, so no target ever compiles a fence — the
  numbers above come from a hand-run, not from a gate
  (`litmus/HipLang.ml`, `hip_fence_scope`). CUDA has no `compile-cuda.sh` twin;
  neither that absence nor this script's presence is a coverage claim either
  way.
- **Task 9 (hardware):** deferred — MI300A runs + stressing + tallying `__out`
  against the `condition` line.
- **Reference verdicts:** the PLDI'23 artifact's are AMD GCN3; MI300A is CDNA3,
  several generations past GCN3, so they do not transfer, no CDNA3 reference
  replaces them, and this project derives none of its own.

## Grounding sources
- HIP scoped-atomic builtins + `__HIP_MEMORY_SCOPE_*` ladder: ROCm/clr
  `hipamd/include/hip/amd_detail/amd_hip_atomic.h` (fetched from the ROCm
  GitHub source).
- AMDGPU `cluster` synchronization scope + agent degradation: LLVM
  `AMDGPUUsage` documentation (`llvm.org/docs/AMDGPUUsage.html`, memory model /
  sync scopes).
- Faithful fence builtin `__builtin_amdgcn_fence(<order>, "<scope>")`: LLVM
  review **D75917** ("Expose llvm fence instruction as clang intrinsic",
  `reviews.llvm.org/D75917`) — first arg is a C11 order constant
  (`__ATOMIC_{ACQUIRE,RELEASE,ACQ_REL,SEQ_CST}`), second arg is an AMDHSA LLVM
  sync-scope string; the clang builtin tests use `"workgroup"`, `"agent"`, and
  `""` (system). The exact sync-scope string names (`"workgroup"`, `"agent"`,
  `"wavefront"`, `"singlethread"`, `"cluster"`, and **system = the default =
  empty string**) are from the LLVM `AMDGPUUsage` "AMDHSA LLVM Sync Scopes"
  table. (This **replaces** the earlier `__threadfence{,_block,_system}`
  lowering, which carried scope but not order.)
