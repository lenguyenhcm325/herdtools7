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
  `BellBase` accessors are mirrored from CudaLang so the two emitters stay
  independent.
- **`litmus/top_litmus.ml`** — the `` `LISA `` arm now emits a `.hip` (HipLang)
  right after the `.cu` (CudaLang) from the same parsed test, then returns
  `Absent` (DumpRun does not try to compile/tar it).
- **`hetlitmus/emit-hip.sh`** — regenerates all `.hip` from the corpus into
  `hetlitmus/hip-out/` (the same litmus7 run also drops a sibling `.cu`;
  `hip-out/.gitignore` keeps only `*.hip`).

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

**Fences.** The corpus uses none (the `-F` variants synchronise with
release/acquire *atomics*, not fences — memory `hetlitmus-amd-oracle-task7`); the
fence path exists only for hand-written tests. HipLang emits the HIP scoped
thread-fence device functions (ROCm HIP C++ language extensions): `cta →
__threadfence_block()`, `gpu → __threadfence()`, `sys → __threadfence_system()`.
These carry a **scope but not a memory order** (they are full fences at that
scope), so the annotated order is preserved only in a trailing comment.

## Cluster scope → AGENT (grounded degradation)
AMD **does** have a cluster synchronization scope: the LLVM AMDGPU memory model
defines `syncscope("cluster")` / `"cluster-one-as"`, sitting **between
`workgroup` and `agent`**, and **degrading to `agent` on targets without
workgroup-cluster launch support** (LLVM `AMDGPUUsage`, "Memory Model" / sync
scopes). So the vendor ladders align: cta↔workgroup, **cluster↔cluster**,
gpu↔agent, sys↔system.

**But HIP source cannot name it.** `amd_hip_atomic.h` defines **no**
`__HIP_MEMORY_SCOPE_CLUSTER` (only SINGLETHREAD/WAVEFRONT/WORKGROUP/AGENT/SYSTEM);
the cluster sync scope is reachable only at the LLVM-IR level
(`syncscope("cluster")`). This is the mirror image of the CUDA side: there
libcu++'s `enum thread_scope` also lacks cluster, but NVIDIA could drop to inline
PTX `.cluster`; AMD source has **no** equivalent token.

HipLang therefore lowers a cluster-scoped op to the nearest **source-expressible
scope that is never weaker — `__HIP_MEMORY_SCOPE_AGENT`** — which is exactly the
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

## Out of scope / next steps (the HIP analog of CUDA Task 8/9)
- **HIP compile (deferred):** ROCm/`hipcc` is **not installed** here, so the
  `.hip` are **emit-only** (not compiled). This is the HIP counterpart of CUDA
  Task 8. First step on a ROCm box (target MI300A, `gfx942`):
  `hipcc -std=c++17 --offload-arch=gfx942 <test>.hip -o <test>` and fix any
  surface issues. The host `main()` is illustrative scaffolding (launch geometry
  + result-buffer layout), as on the CUDA side.
- **Task 9 (hardware):** deferred — MI300A runs + stressing + tallying `__out`
  against the `condition` line.
- **Oracle:** `expected-amd-gcn3.csv` is the AMD GCN3 reference; MI300A is CDNA3
  (past GCN3) so confirm-don't-assume (memory `hetlitmus-amd-oracle-task7`).

## Grounding sources
- HIP scoped-atomic builtins + `__HIP_MEMORY_SCOPE_*` ladder: ROCm/clr
  `hipamd/include/hip/amd_detail/amd_hip_atomic.h` (fetched from the ROCm
  GitHub source).
- AMDGPU `cluster` synchronization scope + agent degradation: LLVM
  `AMDGPUUsage` documentation (`llvm.org/docs/AMDGPUUsage.html`, memory model /
  sync scopes).
- Scoped thread fences: ROCm HIP C++ language extensions
  (`__threadfence{,_block,_system}`).
