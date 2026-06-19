# Task 1 — PLDI'23 GPU-only litmus corpus (frontend target)

Inventory of the GPU-only test family the HetLitmus frontend must be able to
express and generate. Derived by inspecting the PLDI'23 Compound Memory Models
artifact (gem5 + HIP litmus tests), cross-checked against the in-tree PTX `.cat`.

## Sources
- **Goens, Chakraborty, Sarkar, Agarwal, Oswald, Nagarajan. "Compound Memory
  Models." PLDI 2023.** Artifact: `PLDI23_Compound_Simulation`
  (https://github.com/sukarnagarwal/PLDI23_Compound_Simulation), paper:
  https://homepages.inf.ed.ac.uk/vnagaraj/papers/pldi23.pdf
  - Oracle: `expected.csv` (Allowed/Disallowed per test).
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
Confirmed by `grep __ATOMIC_*` over the whole GPU corpus: only
`__ATOMIC_ACQUIRE` and `__ATOMIC_RELEASE` appear (no acq_rel/seq_cst, no RMW,
no standalone `__threadfence` — ordering is via atomic order qualifiers).

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
