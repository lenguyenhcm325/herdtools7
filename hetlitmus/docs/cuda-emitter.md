# Tasks 4–6 — CUDA emitter spine (CudaLang)

The HetLitmus Tier‑1 GPU code generator. Turns the GPU‑only LISA/Bell scoped
corpus (`hetlitmus/tests/gpu-only/*.litmus`) into CUDA C++ (`.cu`) litmus
kernels, one per test. **Route B** of the frontend decision (reuse the Bell/LISA
scoped IR; no native PTX architecture) — see memory `hetlitmus-route-b-frontend`.

## What ships
- **`litmus/CudaLang.ml`** — the emitter. Translates parsed `BellBase` scoped
  loads/stores + the Bell scope tree into libcu++ scoped atomics and a CTA/thread
  launch geometry.
- **`litmus/gpuLang.ml`** — the half CudaLang shares with HipLang: the
  annotation vocabulary, the `BellBase` accessors, the launch layout and the
  whole-test driver, parameterised by a `GpuLang.t` dialect record.
- **`litmus/hetGpuOnly.ml`** — the wiring. The `\`LISA` arm of the arch dispatch
  in `top_litmus.ml`'s `aux` (previously `assert false`) closes this functor,
  which parses the scoped LISA test (`BellLexer`/`LISAParser` →
  `LISAArch_litmus`) and calls `CudaLang.dump`, writing `<name>.cu` via
  `Tar.outname`.
- **`litmus/option.ml`** — `Option.get_default \`LISA` returned `assert false`
  (a dead path); now returns `copt` so the LISA test can reach the dispatch.
- **`hetlitmus/emit-cuda.sh`** — regenerates all `.cu` from the corpus; the
  CUDA-side entry point of `hetlitmus/emit-gpu.sh`, which it calls with
  `-gpu-target cuda` (one vendor per pass; `litmus/hetDialect.ml`).

Build: `make all` in the repo root (branch `hetlitmus-work`). Emit:
`./hetlitmus/emit-cuda.sh [OUTDIR]` (default `hetlitmus/cuda-out/`).

## How it works (and why this shape)
litmus7 had **no** LISA path at all (the `\`LISA` arm was `assert false`; LISA is
handled only by *klitmus7*, `top_klitmus.ml`). We reuse litmus7's existing LISA
**parser** but not its C‑harness emission: the standard `Skel` pipeline wraps
per‑thread code in a pthread C harness, which is the wrong shape for a readable,
eyeball‑able CUDA kernel.

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

## Mappings (grounded)
Scoped‑atomic syntax grounded against libcu++ (NVIDIA/cccl): header
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
`__HIP_MEMORY_SCOPE_CLUSTER` — and the transcribed PTX model's scope tags are
`.cta`/`.gpu`/`.sys` ([`nvidia-ptx-cat.md`](nvidia-ptx-cat.md)).

CTA layout: a *block* = a maximal subtree rooted at a `cta` node in the scope
tree; CTAs numbered in DFS order, procs guarded by
`if (blockIdx.x == B && threadIdx.x == L)`. Every test in this corpus places each
proc in its **own** CTA — so the two MP threads sit in *distinct* CTAs, which is
exactly what makes `MP-cta-F` (block‑scope rel/acq across distinct CTAs) the
moral‑strength / scope‑mismatch demonstration.

## Task‑6 gate — eyeball checklist (10/10)
Each emitted kernel checked against the ASPLOS'15 (Alglave et al., "GPU
Concurrency") MP/SB/IRIW shapes (plus the standard 3‑proc write‑read‑causality
WRC shape) and the scope mapping above.

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

² `MP-gpu-release` and `WRC-sys-relaxed` were added to sample the last two
un‑eyeballed codegen branches: `MP-gpu-release` is the only **device‑scope** kernel
(`gpu → thread_scope_device`; all other samples are sys/cta), and `WRC-sys-relaxed`
is the only **3‑proc** launch geometry (`<<<3,1>>>`, three distinct CTAs).

## Task 8 — nvcc compile (DONE)
Done on this WSL box (CUDA Toolkit **12.9**, `nvcc /usr/local/cuda/bin/nvcc`;
`export PATH=/usr/local/cuda/bin:$PATH`; originally Task 8 ran on 12.2 — see the
fence-lowering note below for what the upgrade changed). Every emitted kernel
assembles **exit 0**.

- **Corpus (cta/sys/gpu), Ampere** — each of the 10 `cuda-out/*.cu`:

  ```
  nvcc -std=c++17 -arch=sm_86 <test>.cu -o /tmp/<test>
  ```

  All 10 (MP/LB/SB/IRIW × relaxed/-F, MP-cta-F, plus MP-gpu-release and
  WRC-sys-relaxed) compile exit 0. `sm_86` = this box's RTX 3060 Laptop
  (Ampere), so the corpus can also smoke *run* here.

**Fence lowering (faithful inline PTX).** `fence.acquire`/`fence.release` are
real instructions added in **PTX ISA 8.6 (SM_90)**; a ptxas implementing an
earlier ISA rejects them (CUDA 12.2's, at PTX ISA 8.2, does), which is a
*toolkit-version* limit and not a PTX-ISA one. They assemble on this box's
current **CUDA 12.9** (`nvcc -std=c++17 -arch=sm_90`). The emitter lowers fences
**faithfully** at every scope via inline PTX — `fence.<order>.<scope>`, `<order>
∈ {acquire,release,acq_rel,sc}`, `<scope> ∈ {cta,gpu,sys}` — bypassing
`cuda::atomic_thread_fence`, which (verified in CUDA 12.9
`cuda/std/__atomic/functions/cuda_ptx_generated.h`) **still** collapses
acquire/release → `fence.acq_rel`. Availability: `fence.{acq_rel,sc}` work on
SM_70+; `fence.{acquire,release}` need SM_90 — so a fence-bearing test assembles
only for sm_90 (fine for the GH200 target; the 10 samples above carry no fence,
so their `.cu` stay byte-stable). Load/store mapping is unchanged: rel/acq on ops
already map exactly (`st.release.<scope>` / `ld.acquire.<scope>`); only
standalone fences are affected.

## Out of scope / next steps
- **Task 9 (hardware):** deferred — GH200 / MI300A runs + stressing + tallying
  `__out` against the `condition` line.
- The host harness currently has no result tally and no stress (timing jitter,
  memory pressure). Stressing is essential for non‑observations to be meaningful
  (see thesis principles); that lands with Task 9.
- Reference verdicts: no external reference covers GH200, and this project
  derives none of its own.
