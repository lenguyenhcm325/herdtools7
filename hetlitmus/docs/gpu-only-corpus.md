# The artifact-anchored GPU-only corpus

The GPU-only corpus is anchored on the GPU litmus tests of the [Goens23]
artifact, which are the frontend's target: what `hetlitmus/bells/gpu.bell`
must express is what those tests use. The systematic grid over the same
vocabulary is `corpus-grid.md`.

## Sources

[Goens23] §7 (Table 1) and its artifact `PLDI23_Compound_Simulation`
(<https://github.com/sukarnagarwal/PLDI23_Compound_Simulation>): the runner
`runall_gpu_only.sh`, the observations `expected.csv` (`GPU-Only` rows) and the
HIP sources under `gem5-resources/gpu/GPU_Litmus_test/`.

## Vendor scope

The artifact runs on gem5's `GCN3_X86` target — an AMD GCN3 GPU (kernels built
for `gfx801,gfx803`) fused with an x86 CPU — so its observations are one
simulated AMD machine's; this project ships none of them and derives no verdict
of its own (`hip-emitter.md`, "Compile status"). The `.litmus` vocabulary is
PTX-named (`cta`/`gpu`/`sys`) because it maps 1:1 onto the levels the corpus
uses (`cta` ↔ workgroup, `sys` ↔ system), and the files carry only the shared
relaxed/acquire/release × cta/sys words, so one corpus is rendered unchanged
for both vendors; the vendor difference lives in the emitters' instruction
selection (`cuda-emitter.md`, `hip-emitter.md`: "Mappings"), never in the
`.litmus` layer.

## Families and variants

Four shapes, each in a relaxed and a release/acquire variant: `MP-sys`,
`MP-sys-F`, `MP-cta-F`, `LB-sys`, `SB-sys`, `SB-sys-F`, `IRIW-sys`, `IRIW-sys-F`
(`LB-sys-F` is skipped by `runall_gpu_only.sh`); the corpus keeps these names.
Decoded from `runall_gpu_only.sh` (`genFileName`) and the sources:

- `<shape>_Relax` (`-sys`): plain loads and stores, compiler reordering blocked
  by `#pragma GCC optimize ("O0")`.
- `<shape>_RelAcq_WO_Atomic_Fence` (`-sys-F`): the flag variable carries the
  ordering, `__atomic_store_n(&flag, 1, __ATOMIC_RELEASE)` /
  `__atomic_load_n(&flag, __ATOMIC_ACQUIRE)`; the data variable stays plain.
- `MP_RelAcq_Wg_Scope` (`-cta-F`): the same `__atomic_*` release/acquire, with
  no scope qualifier in the source — the CTA (workgroup) scope is a gem5 build
  variant (`runall_CTA_scope.sh` rebuilds the simulator from an alternate
  source tree, `src_CTA_GPU`, whose changed files are the `CTA_GPU_only`
  cache-protocol sources). Every kernel launches one thread per
  block, so the two threads sit in different workgroups and the synchronisation
  is too narrow; the corpus renders this as `cta`-scope annotations under a
  tree that puts each proc in its own CTA.

### Release/acquire without fences

The `-F` kernels synchronise with release/acquire atomics only; no source
contains a fence intrinsic. Release/acquire alone forbids MP, whose acquire
reads the released value; it does not by itself forbid SB or IRIW, whose
forbidden outcome has every acquire read the initial value, so the pairing
never engages. The artifact nonetheless records `SB-sys-F` and `IRIW-sys-F` as
disallowed: on the gem5 GCN3 model a release or acquire is implemented as a
fence and behaves as an SC fence ([Goens23] §7.2, fn. 10). That is a property
of that simulated machine; a model in which rel/acq is pure scoped ordering
reads those two tests the other way, and neither reading transfers.

## Minimum vocabulary the frontend must express

The GPU sources use `__ATOMIC_ACQUIRE` and `__ATOMIC_RELEASE` only — no
`acq_rel`, no `seq_cst`, no RMW — as order qualifiers on loads and stores. The
frontend therefore needs orders `relaxed`, `release` (stores) and `acquire`
(loads); scopes `cta` and `sys`, plus the intermediate `gpu` (device / HIP
agent), which the artifact's tests do not use and the grid sweeps; scoped loads
and stores and no RMW.

### How `bells/gpu.bell` declares it

Two upstream idioms combined: the memory-order enum and `R`/`W`/`F`
instruction sets of `herd/libdir/c11.bell`, and the scope hierarchy with its
`narrower`/`wider` functions from
`catalogue/tutorial/bells/jaguar.bell`. A Bell `instructions` declaration takes
a comma-separated list of annotation groups, so `W[<orders>, scopes]` attaches
one tag from each group and a single access carries both an order and a scope
(PTX `st.release.cta`).
