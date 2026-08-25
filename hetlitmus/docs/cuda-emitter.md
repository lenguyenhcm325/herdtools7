# CUDA emitter spine (CudaLang)

The HetLitmus GPU code generator. Turns the GPU‑only LISA/Bell scoped
corpus (`hetlitmus/tests/gpu-only/*.litmus`) into CUDA C++ (`.cu`) litmus
kernels, one per test, reusing the Bell/LISA scoped IR as the frontend (no
native PTX architecture).

## What ships
- **`litmus/CudaLang.ml`** — the emitter. Translates parsed `BellBase` scoped
  loads/stores + the Bell scope tree into libcu++ scoped atomics and a CTA/thread
  launch geometry.
- **`litmus/gpuLang.ml`** — the half CudaLang shares with HipLang: the
  annotation vocabulary, the `BellBase` accessors, the launch layout and the
  whole-test driver, parameterised by a `GpuLang.t` dialect record.
- **`litmus/hetGpuOnly.ml`** — the wiring. The `\`LISA` arm of the arch dispatch
  in `top_litmus.ml`'s `aux` closes this functor, which parses the scoped LISA
  test (`BellLexer`/`LISAParser` → `LISAArch_litmus`) and calls the selected
  dialect's `dump` (`CudaLang.dump` or `HipLang.dump`), writing `<name>.cu` or
  `<name>.hip` via `Tar.outname`.
- **`litmus/option.ml`** — `Option.get_default \`LISA` returns `copt`, so the
  LISA test reaches the dispatch.
- **`hetlitmus/emit-cuda.sh`** — regenerates all `.cu` from the corpus; the
  CUDA-side entry point of `hetlitmus/emit-gpu.sh`, which it calls with
  `-gpu-target cuda` (one vendor per pass; `litmus/hetDialect.ml`).

Build: `make all` in the repo root. Emit:
`./hetlitmus/emit-cuda.sh [OUTDIR]` (default `hetlitmus/cuda-out/`).

## How it works (and why this shape)
Upstream litmus7 has **no** LISA path — its `\`LISA` arm is `assert false`, and
LISA is handled only by *klitmus7* (`top_klitmus.ml`). HetLitmus reuses
litmus7's existing LISA **parser** but not its C‑harness emission: the standard
`Skel` pipeline wraps per‑thread code in a pthread C harness, which is the wrong
shape for a readable, eyeball‑able CUDA kernel.

The emitter consumes the **parsed** program (`A.pseudo MiscParser.t`), not the
litmus7 `Out` template. The template flattens a scoped load/store into an opaque
`memo` string and loses the structured order+scope annotation; pattern‑matching
`BellBase.Pld`/`Pst (_, _, annots)` directly keeps the mapping exact. From the
parsed test we read three things:
- `prog` — the per‑proc `BellBase` instruction lists (the scoped ops),
- `extra_data` → `BellExtra` → `BellInfo.scopes` — the scope tree (CTA placement),
- `condition` — the `exists` clause (emitted as a comment via `ConstrGen`).

The LISA arm returns `Absent` so `DumpRun` does **not** try to C‑compile/tar the
output as a litmus binary; the `.cu` is written directly to the `-o` dir.

## Mappings
Scoped‑atomic syntax is libcu++'s (NVIDIA/cccl): header
`<cuda/atomic>`, `cuda::atomic_ref<int, cuda::thread_scope_*> ref(lvalue);`
with `ref.store(v, order)` / `ref.load(order)`. Memory locations are kernel
`int*` parameters (managed memory), so each access binds `*x`.

| LISA annotation | libcu++ token |
|-----------------|---------------|
| order `relaxed` | `cuda::memory_order_relaxed` |
| order `acquire` | `cuda::memory_order_acquire` |
| order `release` | `cuda::memory_order_release` |
| scope `cta`     | `cuda::thread_scope_block`  |
| scope `gpu`     | `cuda::thread_scope_device` |
| scope `sys`     | `cuda::thread_scope_system` |

**No cluster scope.** PTX `.cluster` (`sm_90`) is NVIDIA-only — HIP source has no
`__HIP_MEMORY_SCOPE_CLUSTER` — and the annotation vocabulary the corpus is
generated over declares only `.cta`/`.gpu`/`.sys`
([`../bells/ptx.bell`](../bells/ptx.bell), `enum scopes`).

CTA layout: a *block* = a maximal subtree rooted at a `cta` node in the scope
tree; CTAs numbered in DFS order, procs guarded by
`if (blockIdx.x == B && threadIdx.x == L)`. Every test in this corpus places each
proc in its **own** CTA — so the two MP threads sit in *distinct* CTAs, which is
exactly what makes `MP-cta-F` (block‑scope rel/acq across distinct CTAs) the
moral‑strength / scope‑mismatch demonstration.

## Eyeball checklist
Each committed `cuda-out/*.cu` sample, checked against the MP, LB and SB shapes
of [Alglave15 Tab. 6], against the standard IRIW and 3‑proc write‑read‑causality
WRC shapes — for which that paper reports no result — and against the scope
mapping above.

| test | scoped-atomic ops emitted | scope → thread_scope | CTA/thread layout | matches shape? |
|------|---------------------------|----------------------|-------------------|--------------------|
| MP-sys     | store rlx + store rlx; load rlx + load rlx¹ | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (MP) |
| MP-sys-F   | store rlx + **store rel**; **load acq** + load rlx | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (MP) |
| MP-cta-F   | store rlx + **store rel**; **load acq** + load rlx | **cta → thread_scope_block** | `<<<2,1>>>` P0=CTA0, P1=CTA1 (distinct) | yes (MP, scope-mismatch) |
| MP-gpu-release | **store rel** + **store rel**; load rlx + load rlx | **gpu → thread_scope_device** | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (MP; device-scope sample²) |
| LB-sys     | load rlx + store rlx (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (LB) |
| SB-sys     | store rlx + load rlx (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (SB) |
| SB-sys-F   | **store rel** + **load acq** (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (SB) |
| WRC-sys-relaxed | P0 load rlx + store rlx; P1 load rlx + load rlx; P2 store rlx | sys → thread_scope_system | `<<<3,1>>>` P0=CTA0, P1=CTA1, P2=CTA2 | yes (WRC; 3-proc sample²) |
| IRIW-sys   | writers store rlx; readers load rlx ×2 | sys → thread_scope_system | `<<<4,1>>>` P0..P3 = CTA0..3 | yes (IRIW) |
| IRIW-sys-F | writers **store rel**; readers **load acq** ×2 | sys → thread_scope_system | `<<<4,1>>>` P0..P3 = CTA0..3 | yes (IRIW) |

¹ "rlx/rel/acq" = relaxed/release/acquire. Every access is an `atomic_ref` op
carrying its annotated order+scope (relaxed data included), so the kernels are
data‑race‑free under the C++/CUDA model rather than relying on plain accesses.

² `MP-gpu-release` and `WRC-sys-relaxed` sample the two codegen branches the
other samples do not reach: `MP-gpu-release` is the only **device‑scope** kernel
(`gpu → thread_scope_device`; all other samples are sys/cta), and `WRC-sys-relaxed`
is the only **3‑proc** launch geometry (`<<<3,1>>>`, three distinct CTAs).

## nvcc compile
Every gpu-only render assembles under `nvcc -std=c++17 -arch=sm_90 --ptx` in
`tokens.sh full` (`ptxcheck.py` over both corpora entire); `make
hetlitmus-faithful` runs `tokens.sh all`, the feature cover
(`verify/faithful-cover.txt`, asserted complete against the corpus by
`covercheck.py`). `sm_90` is also the arch the emitted Makefile/`comp.sh` build
with (`hetDialect.ml`, `gd_arch_default`). The committed `cuda-out/*.cu`
samples are the emission golden `corpus-gate.sh` re-emits byte for byte; none of
them carries a fence.

**Fence lowering (faithful inline PTX).** The emitter lowers a fence at every
scope to inline PTX — `fence.<order>.<scope>`, `<order> ∈
{acquire,release,acq_rel,sc}`, `<scope> ∈ {cta,gpu,sys}` (`CudaLang.ml`,
`ptx_fence_sem`, `ptx_scope`) — bypassing `cuda::atomic_thread_fence`, which
collapses acquire/release → `fence.acq_rel` and so cannot express the order the
annotation carries [CCCL `cuda/std/__atomic/functions/cuda_ptx_generated.h`].
Availability [CCCL `cuda/__ptx/instructions/generated/fence.h`]:
`fence.{acq_rel,sc}` from PTX ISA 6.0 / SM_70, `fence.{acquire,release}` from
PTX ISA 8.6 / SM_90 — a floor on the toolkit and the target, not an absence in
the ISA — so a fence-bearing test assembles only for sm_90 (the target the
emitted build uses; each emitted fence carries a trailing `// requires sm_90` or
`// sm_70+` comment, `fence_min_arch`). The committed samples carry no fence, so
their `.cu` stay byte-stable. Load/store mapping is unaffected: rel/acq on ops
map exactly (`st.release.<scope>` / `ld.acquire.<scope>`); only standalone
fences need the inline form. A `relaxed` fence has no PTX form and the
annotation vocabulary declares none (`ptx.bell`,
`F[{'acquire,'release,'acq_rel,'sc}, scopes]`), so the emitter refuses one
loudly.

## Limits
- The gpu-only host `main()` tallies nothing and runs no stress: it launches the
  kernel in a loop and leaves `__out` unread (`gpuLang.ml`, `dump_test`). Result
  tallying, the per-iteration rendezvous and the stress layers live on the
  heterogeneous path (`het-emission.md`, `00-environment-design.md`).
- Reference verdicts: no external reference covers GH200, and this project
  derives none of its own.
