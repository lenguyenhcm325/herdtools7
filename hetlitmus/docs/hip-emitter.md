# HIP emitter (HipLang)

`litmus/HipLang.ml` is the AMD sibling of `CudaLang` (`cuda-emitter.md`): the
same scoped LISA/Bell corpus rendered as HIP C++ (`.hip`) kernels over Clang's
`__hip_atomic_*` builtins and `__builtin_amdgcn_fence`. The `.litmus` layer is
vendor-neutral; the vendor lives in the emitter, and `-gpu-target` picks one
(`litmus/hetDialect.ml`).

## What ships
- `litmus/HipLang.ml` — the HIP lowering and the emitted tokens; it consumes
  the parsed `BellBase` program, not the `Out` template (`cuda-emitter.md`,
  "How it works (and why this shape)"), and everything else is
  `litmus/gpuLang.ml`'s.
- `litmus/hetGpuOnly.ml` — the `` `LISA `` dispatch arm; under
  `-gpu-target hip` it writes `<name>.hip` and returns `Absent`.
- `hetlitmus/emit-hip.sh [OUTDIR]` — renders the corpus (default
  `hetlitmus/hip-out/`) through `hetlitmus/emit-gpu.sh hip OUTDIR`.
- `hetlitmus/compile-hip.sh [INDIR] [OUTDIR]` — compiles every render
  ("Compile status" below).

## Mappings
HIP scoped atomics are Clang builtins over a kernel `int*` parameter passed as
is: `__hip_atomic_store(ptr, val, order, scope)`,
`v = __hip_atomic_load(ptr, order, scope)` [HipAtomicHeader]; the
`__HIP_MEMORY_SCOPE_*` ladder is `SINGLETHREAD 1` … `SYSTEM 5`
[HipAtomicHeader]. Launch geometry is `gpuLang.ml`'s, as for CUDA
(`cuda-emitter.md`, "Mappings"), launched with `hipLaunchKernelGGL`.

## Fences
A fence lowers to `__builtin_amdgcn_fence(<order>, "<sync scope>")`, which
carries both the order and the scope [D75917] — the AMD counterpart of
CudaLang's `fence.<order>.<scope>`; `__threadfence{,_block,_system}` takes no
order and is not used. The order reuses the atomics' `__ATOMIC_*` map; the
scope string is the AMDHSA LLVM sync-scope name, `cta → "workgroup"`,
`gpu → "agent"`, `sys → ""` (`hip_fence_scope`).

**System scope is the empty string**: the nameable sync scopes are `agent`,
`cluster`, `workgroup`, `wavefront`, `singlethread` and their `-one-as`
variants, and the unnamed default is system [AMDGPUUsage "Memory Scopes"].
`"system"` is not a sync-scope name and `hipcc` rejects it ("Unsupported atomic
synchronization scope"); `"agent"` in its place would compile and silently
NARROW the fence. A relaxed fence is refused before rendering
(`het-emission.md`, "Scope / limits"). Each emitted fence carries a trailing
`// f[order,scope]` comment, the tie back to its `.litmus` column that
`amd-faithfulness.md` reads.

## Compile status
`hetlitmus/compile-hip.sh` compiles each `.hip` in INDIR (default `hip-out/`)
with `$HIPCC --offload-arch=$HIP_ARCH -std=c++17` into OUTDIR (default
`$RESULTS/hip-compile`; `het-emission.md`, "From a corpus to a results dir"),
`HIP_ARCH` defaulting to `gfx942`, the MI300A ISA. The render needs the
HIP-Clang stack: `__hip_atomic_*` and `__builtin_amdgcn_fence` are Clang
builtins, absent from HIP over nvcc. Nothing is launched; running a kernel needs
an AMD device.

A clean compile establishes that the builtin, order and scope the emitter wrote
are accepted for the target ISA — not what `hipcc` lowers them to, and not
memory-model behaviour (`amd-faithfulness.md`, "Scope and limits"). The host
`main()` is the same scaffolding as the CUDA render's (`cuda-emitter.md`,
"Limits"). No expected verdicts: the artifact's are AMD GCN3
(`gpu-only-corpus.md`, "Vendor scope") and do not transfer
to CDNA3 (MI300A); this project derives none.
