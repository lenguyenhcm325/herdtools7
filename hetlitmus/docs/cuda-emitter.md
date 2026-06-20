# Tasks 4–6 — CUDA emitter spine (CudaLang)

The HetLitmus Tier‑1 GPU code generator. Turns the GPU‑only LISA/Bell scoped
corpus (`hetlitmus/tests/gpu-only/*.litmus`) into CUDA C++ (`.cu`) litmus
kernels, one per test. **Route B** of the frontend decision (reuse the Bell/LISA
scoped IR; no native PTX architecture) — see memory `hetlitmus-route-b-frontend`.

## What ships
- **`litmus/CudaLang.ml`** — the emitter. Translates parsed `BellBase` scoped
  loads/stores + the Bell scope tree into libcu++ scoped atomics and a CTA/thread
  launch geometry.
- **`litmus/top_litmus.ml`** — the wiring. The `\`LISA` arm of the arch dispatch
  in `from_chan`'s `aux` (previously `assert false`) now parses the scoped LISA
  test (`BellLexer`/`LISAParser` → `LISAArch_litmus`) and calls `CudaLang.dump`,
  writing `<name>.cu` via `Tar.outname`.
- **`litmus/option.ml`** — `Option.get_default \`LISA` returned `assert false`
  (a dead path); now returns `copt` so the LISA test can reach the dispatch.
- **`hetlitmus/emit-cuda.sh`** — regenerates all `.cu` from the corpus.

Build: `make all` in the repo root (branch `hetlitmus-tier1`). Emit:
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

**Cluster scope → inline PTX.** libcu++'s `enum thread_scope` has only
`{thread,block,device,system}` — there is **no `thread_scope_cluster`**, so a
cluster-scoped op cannot go through `atomic_ref`. `CudaLang` emits it as inline
PTX instead — the exact strings libcu++ itself lowers cluster atomics to
(grounded against cccl `cuda_ptx_generated.h` / `__ptx/.../fence.h`):

| LISA op (scope `cluster`) | emitted PTX |
|---------------------------|-------------|
| load `relaxed`/`acquire`  | `ld.{relaxed,acquire}.cluster.b32 %0,[%1];` |
| store `relaxed`/`release` | `st.{relaxed,release}.cluster.b32 [%0],%1;` |
| fence `acquire`/`release`/`acq_rel`/`sc` | `fence.{…}.cluster;` |

Generic addressing, `.b32`; **requires PTX ISA ≥ 7.8 and `sm_90`** (Hopper).
Caveats: (a) `sc`/`acq_rel` on a cluster *load/store* has no single PTX
instruction, so it raises a loud error (the SC fence-sequence is not yet
emitted); cluster *fences* cover all four orders. (b) Forming an actual cluster
at launch (`cudaLaunchKernelEx` cluster dim / `__cluster_dims__`) is part of the
host run — Task 9 — so cluster-scoped ordering only takes effect once that
lands; the per-op codegen here is the piece this change makes correct. (c) Not
nvcc-compiled (Task 8); grounded against the PTX libcu++ emits.

CTA layout: a *block* = a maximal subtree rooted at a `cta` node in the scope
tree; CTAs numbered in DFS order, procs guarded by
`if (blockIdx.x == B && threadIdx.x == L)`. Every test in this corpus places each
proc in its **own** CTA — so the two MP threads sit in *distinct* CTAs, which is
exactly what makes `MP-cta-F` (block‑scope rel/acq across distinct CTAs) the
moral‑strength / scope‑mismatch demonstration.

## Task‑6 gate — eyeball checklist (8/8)
Each emitted kernel checked against the ASPLOS'15 (Alglave et al., "GPU
Concurrency") MP/SB/IRIW shapes and the scope mapping above.

| test | scoped-atomic ops emitted | scope → thread_scope | CTA/thread layout | matches ASPLOS'15? |
|------|---------------------------|----------------------|-------------------|--------------------|
| MP-sys     | store rlx + store rlx; load rlx + load rlx¹ | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (MP) |
| MP-sys-F   | store rlx + **store rel**; **load acq** + load rlx | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (MP) |
| MP-cta-F   | store rlx + **store rel**; **load acq** + load rlx | **cta → thread_scope_block** | `<<<2,1>>>` P0=CTA0, P1=CTA1 (distinct) | yes (MP, scope-mismatch) |
| LB-sys     | load rlx + store rlx (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (LB) |
| SB-sys     | store rlx + load rlx (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (SB) |
| SB-sys-F   | **store rel** + **load acq** (both procs) | sys → thread_scope_system | `<<<2,1>>>` P0=CTA0, P1=CTA1 | yes (SB) |
| IRIW-sys   | writers store rlx; readers load rlx ×2 | sys → thread_scope_system | `<<<4,1>>>` P0..P3 = CTA0..3 | yes (IRIW) |
| IRIW-sys-F | writers **store rel**; readers **load acq** ×2 | sys → thread_scope_system | `<<<4,1>>>` P0..P3 = CTA0..3 | yes (IRIW) |

¹ "rlx/rel/acq" = relaxed/release/acquire. Every access is an `atomic_ref` op
carrying its annotated order+scope (relaxed data included), so the kernels are
data‑race‑free under the C++/CUDA model rather than relying on plain accesses.

## Out of scope / next steps
- **Task 8 (nvcc compile):** not done — nvcc is not installed in this
  environment. The emitted host `main()` is *illustrative scaffolding* (launch
  geometry + result‑buffer layout) and has **not** been compiled. First step on a
  CUDA box: `nvcc -std=c++17 --expt-relaxed-constexpr <test>.cu` and fix any
  surface issues (e.g. `__out` indexing, header set).
- **Task 9 (hardware):** deferred — GH200 / MI300A runs + stressing + tallying
  `__out` against the `condition` line.
- The host harness currently has no result tally and no stress (timing jitter,
  memory pressure). Stressing is essential for non‑observations to be meaningful
  (see thesis principles); that lands with Task 9.
- Oracle: `expected-amd-gcn3.csv` is AMD‑only; GH200 needs its own oracle (memory
  `hetlitmus-amd-oracle-task7`).
- Cluster scope is supported in the *emitter* (inline PTX, see Mappings), but the
  corpus does not yet exercise it: `diy7` generation of cluster tests needs
  `'cluster` added to `bells/ptx.bell`'s `enum scopes` + scope order
  (`cta < cluster < gpu < sys`), and running them needs the Task‑9 cluster launch.
