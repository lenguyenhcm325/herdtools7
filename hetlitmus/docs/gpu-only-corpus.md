# The GPU-only corpus and the artifact behind it

The GPU-only corpus is the all-GPU cut of the grid (`corpus-grid.md`, "The
gpu-only corpus"). Its vocabulary — what `hetlitmus/bells/gpu.bell` must
express — is anchored on the GPU litmus tests of the [Goens23] artifact, which
are the frontend's target: the artifact motivates the vocabulary, not
membership. Its kernels are grid cells, except where an order sits on one
access of a proc and not the other (below).

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
uses (`cta` ↔ workgroup, `sys` ↔ system), and the files carry only order and
scope words both emitters map, so one corpus is rendered unchanged
for both vendors; the vendor difference lives in the emitters' instruction
selection (`cuda-emitter.md`, `hip-emitter.md`: "Mappings"), never in the
`.litmus` layer.

## The artifact's kernels as grid cells

Four shapes, each in a relaxed and a release/acquire variant, decoded from
`runall_gpu_only.sh` (`genFileName`) and the sources (`LB_RelAcq_*` is
skipped by the runner):

- `<shape>_Relax`: plain loads and stores, compiler reordering blocked by
  `#pragma GCC optimize ("O0")` — the `rlx` cell at `sys` scope (`MP-sys-rlx`,
  `LB-sys-rlx`, `SB-sys-rlx`, `IRIW-sys-rlx`).
- `SB_RelAcq_WO_Atomic_Fence`: each thread's store is
  `__atomic_store_n(…, __ATOMIC_RELEASE)` and its load
  `__atomic_load_n(…, __ATOMIC_ACQUIRE)` — the `ra` cell at `sys`
  (`SB-sys-ra`). The kernel also reads the other thread's variable once
  before its store, a read whose result the tested load overwrites; the
  cell carries the tested pair only.
- `MP_RelAcq_WO_Atomic_Fence`, `IRIW_RelAcq_WO_Atomic_Fence`: the flag
  variable alone carries the ordering — its store `__ATOMIC_RELEASE`, its load
  `__ATOMIC_ACQUIRE` — and the data variable stays plain (in IRIW each reader
  acquire-loads the first variable and plain-loads the second; the writers
  release). A per-access placement of an order is not an axis of the grid, so
  neither kernel is a cell: the corpus carries the `rlx` and `ra` cells on
  either side of each (`MP-sys-rlx`/`MP-sys-ra`, `IRIW-sys-rlx`/`IRIW-sys-ra`).
  This is the residual between the artifact and the corpus.
- `MP_RelAcq_Wg_Scope`: the same flag-only release/acquire, with no scope
  qualifier in the source — the CTA (workgroup) scope is a gem5 build variant
  (`runall_CTA_scope.sh` rebuilds the simulator from an alternate source
  tree, `src_CTA_GPU`, whose changed files are the `CTA_GPU_only`
  cache-protocol sources). Every kernel launches one thread per block, so the
  two threads sit in different workgroups and the synchronisation is too
  narrow; the corpus renders `cta`-scope annotations under a tree that puts
  each proc in its own CTA (`MP-cta-rlx`, `MP-cta-ra`), the same residual.

### Release/acquire without fences

The `RelAcq` kernels synchronise with release/acquire atomics only; no source
contains a fence intrinsic. Release/acquire alone forbids MP, whose acquire
reads the released value; it does not by itself forbid SB or IRIW, whose
forbidden outcome has every acquire read the initial value, so the pairing
never engages. The artifact nonetheless records `SB_RelAcq_WO_Atomic_Fence`
and `IRIW_RelAcq_WO_Atomic_Fence` as disallowed: on the gem5 GCN3 model a
release or acquire is implemented as a fence and behaves as an SC fence
([Goens23] §7.2, fn. 10). That is a property of that simulated machine; a
model in which rel/acq is pure scoped ordering reads those two tests the other
way, and neither reading transfers.

## The vocabulary the frontend must express

The artifact's GPU sources use `__ATOMIC_ACQUIRE` and `__ATOMIC_RELEASE` only
— no `acq_rel`, no `seq_cst`, no RMW — as order qualifiers on loads and
stores, at system scope and, by build variant, workgroup scope. The frontend
therefore needs orders `relaxed`, `release` (stores) and `acquire` (loads);
scopes `cta` and `sys`, plus the intermediate `gpu` (device / HIP agent),
which the artifact's tests do not use and the grid sweeps; scoped loads and
stores and no RMW. Beyond the artifact, the bell declares `sc` on an access
and the standalone fences `sc`, `acquire`, `release` and `acqrel`, because the
grid's GPU orders use them (`corpus-grid.md`, "The five axes").

### How `bells/gpu.bell` declares it

Two upstream idioms combined: the memory-order enum and `R`/`W`/`F`
instruction sets of `herd/libdir/c11.bell`, and the scope hierarchy with its
`narrower`/`wider` functions from
`catalogue/tutorial/bells/jaguar.bell`. A Bell `instructions` declaration takes
a comma-separated list of annotation groups, so `W[<orders>, scopes]` attaches
one tag from each group and a single access carries both an order and a scope
(PTX `st.release.cta`).
