# HipLang — the AMD HIP emitter

`litmus/HipLang.ml` is the AMD sibling of `CudaLang` (see `cuda-emitter.md`). It
turns the GPU-only LISA/Bell scoped corpus (`hetlitmus/tests/gpu-only/*.litmus`)
into AMD **HIP** C++ (`.hip`) litmus kernels, one per test, reusing the Bell/LISA
scoped IR as the frontend (no native arch). The `.litmus` layer is
vendor-neutral, so the same corpus feeds both vendors; the vendor difference
lives only in the emitter, and `-gpu-target` is what picks one
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

## Mappings
HIP scoped atomics are Clang builtins. Memory locations are kernel `int*`
parameters, so the pointer is passed directly (no `&`/deref). As the ROCm HIP
header spells them [HipAtomicHeader]:

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
AGENT=4, SYSTEM=5` [HipAtomicHeader]. The cta/gpu/sys ↔ workgroup/agent/system
mapping is the AMD half of the vendor ladder cta↔workgroup, gpu↔agent,
sys↔system.

### Fences

**Fences carry order + scope, and are read under a gate at source level (see
*Compile status* below).**
The `-F` variants do synchronise with release/acquire *atomics*, not fences —
their sources carry no fence intrinsic at all (`gpu-only-corpus.md`, "Why the
synchronised verdicts hold") — but the corpus is not fence-free: the `-fence`
families and the order-pair grid's `acq`/`rel`/`sc` GPU tokens carry
`f[order,scope]`. Every one of those renderings is read under a *gate*: `make
hetlitmus-hipsrc` checks both corpora of the AMD lane at `verify/census.py`'s
pins, plus two synthetic carriers for the fence annotations the corpus lacks
(`f[acq_rel,sys]`, `f[relaxed,sys]`), against their annotations at source level
([`amd-faithfulness.md`](amd-faithfulness.md)). What that settles, and what
`make hetlitmus-hipbuild` compiles, is *Compile status* below.

HipLang lowers a fence to the Clang builtin
**`__builtin_amdgcn_fence(<order>, "<scope-string>")`**, which carries **BOTH**
the memory order and the sync scope [D75917] — the AMD counterpart of CudaLang's
faithful inline-PTX `fence.<order>.<scope>`. `__threadfence{,_block,_system}` is
not used: it carries only the *scope* and is always a full fence, so it would
drop the annotated order (a `release` fence would become a full fence) and
over-synchronise.

| LISA fence annotation | HIP emission |
|-----------------------|--------------|
| `f[release,sys]`  | `__builtin_amdgcn_fence(__ATOMIC_RELEASE, "");`        |
| `f[acquire,cta]`  | `__builtin_amdgcn_fence(__ATOMIC_ACQUIRE, "workgroup");` |
| `f[acq_rel,gpu]`  | `__builtin_amdgcn_fence(__ATOMIC_ACQ_REL, "agent");`  |
| `f[sc,sys]`       | `__builtin_amdgcn_fence(__ATOMIC_SEQ_CST, "");`       |

The **order** reuses the same `__ATOMIC_*` mapping as the atomics. The **scope
string** is the AMDHSA LLVM sync-scope name: `cta → "workgroup"`, `gpu →
"agent"`, and `sys → ""` (`HipLang.hip_fence_scope`). **System scope is the
empty string:** the sync scopes a fence may name are `workgroup`, `agent`,
`wavefront`, `singlethread`, `cluster` and their `-one-as` variants, and the
unnamed default is system scope [AMDGPUUsage "Memory Scopes"] — `"system"` is
not a sync-scope name, and `hipcc` rejects a fence whose scope is spelt that
way. Naming a scope for `sys` would silently *narrow* it, so the `""` is
load-bearing. A `relaxed` fence is meaningless (a no-op in the C11/AMDGPU model;
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

## Compile status
- **HIP compile.** Where `hipcc` is present the emitted `.hip` is
  compile-checked, not merely emitted.
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
  - `make hetlitmus-hipbuild` (`verify/hipbuildcheck.py`; its docstring lists
    the phases) renders `MP-cg-sys-fence-x86_64` (`X86_TEST`; GPU column
    `f[sc,sys]`, CPU column two plain `movl` stores — regenerated by
    `generate-x86.sh` into a temporary directory, not read from the committed
    fixture) once per vendor (the hip render through its `comp.sh hip`/`make
    hip-bin`, the cuda render through its cuda arms), and fails, not skips,
    without `hipcc`. The HIP resolver
    (`het_alloc_hip.inc`, `_het_alloc_mode`) has one refusal branch for a
    spelling — anything but unset/`auto`/`managed` — so one refused spelling
    (`malloc`, `HIP_REFUSED_MODES`) drives it.
  - `make hetlitmus-smoke` (`verify/smoke.sh`) compiles two `.hip` reps from
    `tests/het-x86` through their own `comp.sh hip` (`hipcc -c`):
    `MP-cg-sys-relaxed-x86_64` and `MP-cg-sys-acqrel-2s-x86_64`, so the
    acquire-load builtin (`r[acquire,sys]`) goes through `hipcc`. A missing
    `hipcc` **skips** both loudly and exits 0 — never a pass. The HIP reps are
    guarded rather than dropped because "one template, two renders"
    (`litmus/het-runtime/README.md`, the `het_stress.h` section) is an
    invariant only while something renders the second: a symbol declared in one
    allocator but read by the shared driver template breaks every `.hip` with
    every other gate green.

  What no gate compiles: a HIP render whose x86_64 CPU column carries
  `mfence` — `hipbuildcheck`'s test and both smoke reps have plain `movl`
  columns, and `hipsrccheck.py` reads `mfence` at source level only.

  `compile-hip.sh` sits beside them as a manual convenience: no make target and
  no gate invokes it, and its default INDIR is `hip-out/`, the committed
  `hip-out/*.hip` samples — all fence-free. CUDA has no `compile-cuda.sh` twin;
  neither that absence nor this script's presence is a coverage claim either way.
- **What reads the emission without a compiler.** `make hetlitmus-hipsrc`
  (`verify/hipsrccheck.py`), on the CUDA-free lane: it checks both corpora of
  the AMD lane at `verify/census.py`'s pins, plus the two synthetic fence
  carriers, at source level — each model op's builtin, order-constant,
  scope-constant, traceability comment and operands against its `.litmus` cell,
  the het scaffolding and loop structure, and the x86_64 CPU column's asm block
  ([`amd-faithfulness.md`](amd-faithfulness.md)).
- **Reference verdicts:** the PLDI'23 artifact's are AMD GCN3; MI300A is CDNA3,
  several generations past GCN3, so they do not transfer, no CDNA3 reference
  replaces them, and this project derives none of its own.

## Sources
- The `__hip_atomic_*` builtins and the `__HIP_MEMORY_SCOPE_*` ladder:
  [HipAtomicHeader].
- `__builtin_amdgcn_fence(<order>, "<scope-string>")`, a C11 order constant
  first and an AMDHSA sync-scope string second: [D75917].
- The AMDHSA sync-scope names and the unnamed system default:
  [AMDGPUUsage "Memory Scopes"].
