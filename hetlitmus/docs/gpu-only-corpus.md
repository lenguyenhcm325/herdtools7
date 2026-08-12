# Task 1 — PLDI'23 GPU-only litmus corpus (frontend target)

Inventory of the GPU-only test family the HetLitmus frontend must be able to
express and generate. Derived by inspecting the PLDI'23 Compound Memory Models
artifact (gem5 + HIP litmus tests), cross-checked against the in-tree PTX `.cat`.

## Oracle provenance & vendor scope (read this first)
The Allowed/Disallowed verdicts in this corpus come from the artifact's gem5
build target **`GCN3_X86`** — an **AMD GCN3 GPU + x86 CPU** (the HIP sources build
for `gfx801,gfx803`). They are therefore **AMD-specific, not vendor-neutral**, and
live in `tests/gpu-only/expected-amd-gcn3.csv`.

Note the deliberate split this creates:
- **Vocabulary** (`cta`/`gpu`/`sys`, and the `ptx.cat` cross-check below) is
  **NVIDIA PTX** naming, chosen only because it maps 1:1 onto the levels this
  corpus uses (`cta`↔workgroup, `sys`↔system).
- **Corpus + oracle** (which accesses are rel/acq, and the verdicts themselves)
  are **AMD**.

So this is *NVIDIA vocabulary over an AMD corpus with an AMD oracle.* The
`.litmus` files themselves stay vendor-neutral (only the shared
relaxed/acquire/release × cta/sys words appear), so they are reused unchanged for
both vendors; the vendor difference lives **downstream** — in the `.cat` (meaning)
and the emitter (instruction selection) — never in the `.litmus` layer.

Consequence for the two hardware targets:
- **MI300A (AMD):** `expected-amd-gcn3.csv` is the right reference — caveat:
  MI300A is CDNA3, several generations past GCN3, so confirm rather than assume.
- **GH200 (NVIDIA):** PLDI'23 provides **no** NVIDIA oracle. The separate
  `tests/gpu-only/expected-nvidia.csv` now exists and covers all 137 rows,
  machine-computed from `hetlitmus/cats/nvidia-ptx.cat` (Lustig ASPLOS'19) — see
  `nvidia-ptx-cat.md`. It disagrees with the AMD verdicts for `SB-sys-F` /
  `IRIW-sys-F` exactly as this file warned it might (see "Why the synchronised
  verdicts hold"); the two are different machines and neither carries to the other.

## Sources
- **Goens, Chakraborty, Sarkar, Agarwal, Oswald, Nagarajan. "Compound Memory
  Models." PLDI 2023.** Artifact: `PLDI23_Compound_Simulation`
  (https://github.com/sukarnagarwal/PLDI23_Compound_Simulation), paper:
  https://homepages.inf.ed.ac.uk/vnagaraj/papers/pldi23.pdf
  - Oracle: `expected-amd-gcn3.csv` (Allowed/Disallowed per test; **AMD GCN3 +
    x86** — see "Oracle provenance & vendor scope" above).
  - Runner: `runall_gpu_only.sh`.
  - Test sources: `gem5-resources/gpu/GPU_Litmus_test/{MP,LB,SB,IRIW}/`
    (HIP `__atomic_*` C++ kernels for the AMD GCN3 gem5 model).
- **In-tree PTX axiomatic model**: `catalogue/demo/cats/ptx.cat`
  (3-scope membar model: `membar.cta` ⊂ `membar.gl` ⊂ `membar.sys`).
  Originates from Alglave et al., "GPU Concurrency: Weak Behaviours and
  Programming Assumptions", ASPLOS 2015.

## Families and variants (the corpus)
Four classic shapes, each in a relaxed and a synchronised variant:

| Test       | Type     | Expected   | Synchronisation in the kernel |
|------------|----------|------------|-------------------------------|
| MP-sys     | GPU-Only | Allowed    | plain accesses (relaxed)      |
| MP-sys-F   | GPU-Only | Disallowed | release store + acquire load, system scope |
| MP-cta-F   | GPU-Only | Allowed    | release/acquire at **CTA (workgroup) scope** — too narrow |
| LB-sys     | GPU-Only | Disallowed | plain accesses (relaxed)      |
| SB-sys     | GPU-Only | Allowed    | plain accesses (relaxed)      |
| SB-sys-F   | GPU-Only | Disallowed | release/acquire, system scope |
| IRIW-sys   | GPU-Only | Allowed    | plain accesses (relaxed)      |
| IRIW-sys-F | GPU-Only | Disallowed | release/acquire, system scope |

(LB-sys-F is intentionally skipped by `runall_gpu_only.sh`.)

### Why the synchronised verdicts hold (the rel/acq caveat)
The `-F` variants synchronise with **plain release/acquire only** — no fences. (A
grep for `threadfence`/`thread_fence`/`membar` over the `-F` sources matches only
filenames and ReadMe comments, e.g. the informal name "MP Fence"; the actual
`.cpp` kernels contain no fence intrinsics.)

Release/acquire alone is enough to forbid **MP**: the acquire load reads the
*released* value, so the release→acquire pairing fires. It is **not**, on its own,
enough to forbid **SB** or **IRIW** — those are the canonical tests that need
sequential consistency / full fences (SB needs store→load ordering; IRIW needs
multi-copy atomicity), and in their forbidden outcome the acquire loads read the
*initial* value, so the rel/acq pairing never engages.

`SB-sys-F` and `IRIW-sys-F` are nonetheless **Disallowed** in the artifact's
verdicts. Whatever the `GCN3_X86` target gives system-scope release/acquire, it
is more than the rel/acq annotation by itself supplies — and that is a property
of the machine the artifact simulated, recorded here rather than derived. The
consequence worth carrying forward is the direction of the disagreement: any
model in which rel/acq is *pure scoped ordering* computes `SB-sys-F` /
`IRIW-sys-F` as **Allowed**, which is exactly what `nvidia-ptx.cat` does. The two
targets are different machines and neither reading carries to the other.

### Naming decoded (from `runall_gpu_only.sh` `genFileName` + source files)
- `Relax` (suffix `-sys`): plain non-atomic loads/stores, compiler reordering
  blocked with `#pragma GCC optimize ("O0")`; relies on hardware reordering.
  Source e.g. `MP/MP-sys/MP_Relax.cpp`.
- `RelAcq_WO_Atomic_Fence` (suffix `-sys-F`): the flag variable carries the
  ordering — `__atomic_store_n(&flag,1,__ATOMIC_RELEASE)` /
  `__atomic_load_n(&flag,__ATOMIC_ACQUIRE)`; data variable stays plain.
  Source e.g. `MP/MP-sys-F/MP_RelAcq_WO_Atomic_Fence.cpp`.
- `RelAcq_Wg_Scope` (suffix `-cta-F`): same release/acquire but at **workgroup
  (= CTA) scope**; with threads in different CTAs the sync is too narrow, so the
  weak behaviour is still Allowed — the scope-mismatch demonstration.
  Source `MP/MP-cta-F/MP_RelAcq_Wg_Scope.cpp`.

## Minimum vocabulary the frontend must express
A `grep __ATOMIC_*` over the GPU corpus shows only `__ATOMIC_ACQUIRE` and
`__ATOMIC_RELEASE` (no `acq_rel`/`seq_cst`, no RMW) — ordering is via atomic order
qualifiers. NB: that grep does **not** by itself rule out fences: HIP/CUDA fences
are intrinsics (`__threadfence_*()`, `atomic_thread_fence(...)`), not `__atomic_*`,
so they would not match. A separate grep for `threadfence`/`thread_fence`/`membar`
over the `-F` sources confirms none are present in the kernels (matches are only
in filenames/ReadMe text).

- **Memory orders**: `relaxed` (plain access), `release` (stores),
  `acquire` (loads). Keep `acq_rel`, `sc` in the vocabulary for completeness /
  future families, but they are unused by this corpus.
- **Scopes**: `cta` (CTA / HIP workgroup) and `sys` (system); plus the
  intermediate `gpu` (device / HIP agent) level from the `.cat` hierarchy,
  unused by GPU-only but needed for compound tests.
- **Operations**: scoped load (acquire/relaxed), scoped store (release/relaxed).
  No RMW required for MP/LB/SB/IRIW.

## Scope-name mapping (for the emitter, later)
| Bell (`ptx.bell`) | PTX (NVIDIA) | HIP/ROCm (AMD) | gem5 source term |
|-------------------|--------------|----------------|------------------|
| `cta`             | `.cta`       | workgroup      | `Wg_Scope`       |
| `gpu`             | `.gpu`       | agent/device   | (device)         |
| `sys`             | `.sys`       | system         | (default)        |
