# HetLitmus corpus grid

The rule that generates both corpora, `hetlitmus/tests/grid.py`, and why it
is shaped as it is. One module holds the shape catalogue, the token
renderers, the device-cut enumeration and its reduction, the name formats and
the two loops. The trees it writes are dune build products under
`_build/default/hetlitmus/tests/` — `het` and `het-x86_64` (the het corpus in
each CPU ISA) and `gpu-only` — declared as directory targets in
`hetlitmus/tests/dune`, rebuilt only when `grid.py`, the bell, herd's libdir
or a generator binary changes, and committed nowhere.

Related: `gpu-only-corpus.md` (the artifact that motivates the vocabulary and
the vendor-scope boundary), `het-generation.md` (how `hetgen7` merges two
single-arch runs into one `Het` test), `het-litmus-format.md` and
`het-emission.md`.

## The shape catalogue

`SHAPES` holds each shape as a closed critical cycle in diy's
architecture-agnostic edge vocabulary: `Po<L><XY>` is intra-proc program order
X→Y with `L` = `d` (different location) or `s` (same); `Rfe`, `Fre` and `Coe`
are the external read-from, from-read and coherence edges. MP, SB, LB and IRIW
are the artifact's shapes; 2+2W, R, S, WRC, RWC, ISA2 and WRC3 (a 3-hop MP/WRC
chain) extend the different-location family, joined by diy's remaining
three-proc families 3.2W, 3.SB, 3.LB, WWC, WRW+2W, WRW+WR, WRR+2W, W+RWC and
Z6.0–Z6.5 under the names `norm7` gives their cycles; CoRR, CoWR and CoRW2
are the same-location (coherence) family.

What diy fixes about the catalogue:

- The `Co` names and their edge order are diy's own: `diyone7` without `-name`
  returns `CoRR`, `CoWR` and `CoRW2` for these cycles, and refuses `PosWR Coe
  Fre` and `Rfe PosRW Fre` ("Impossible direction") because a `Pos` edge's far
  end must agree in direction with the external edge that follows it.
- A cycle whose program-order edges are all `Pos` touches one location, which
  diy refuses without `-oneloc`; the generator passes it.
- Each `Coe` edge puts one location in the condition (`[x]`, `[y]`); a cycle
  with no `Coe` names none, the case `HetCond.condition_locations` answers
  with an empty list.
- A diy edge token admits no underscore (`gen/common/lexUtil.mll`), so the
  acquire-release fence tag is `acqrel`, not PTX's `acq_rel`.

## The five axes

A het test is one cell of shape × device cut × GPU scope × GPU order × CPU
order; a gpu-only test is a cell of shape × GPU scope × GPU order, the
all-GPU cut of the same product. The value lists are `grid.py`'s tables:

- **GPU scope**: `cta`, `gpu`, `sys`. Each proc sits in its own CTA
  (`scope_tree`; `hetgen7` composes the same tree), as the artifact places
  its threads, so a `cta`-scope annotation is too narrow to cross threads:
  scope strength is read from the tree, not assumed.
- **GPU order**: what `hetlitmus/bells/gpu.bell` admits, at uniform strength.
  The access orders `rlx`, `acq`, `rel`, `ra` and `sc` give every read one
  annotation and every write the other — `relaxed`/`relaxed`,
  `acquire`/`relaxed`, `relaxed`/`release`, `acquire`/`release`, `sc`/`sc` —
  on both ends of every edge. The fence orders `fsc`, `facq`, `frel` and
  `fra` keep every access relaxed and place one standalone fence of that
  order, at the cell's scope, between the two accesses of each proc: the `Po`
  edge becomes `Fence<Order><Scope><L><XY>`, which diy supports as it stands.
  A mixed pair, an acquire read against an `sc` write, is not a cell.
- **CPU order**: a per-ISA profile ("The CPU ISA of a rendering"), rendered on
  the `Po` edges of the CPU cycle alone; external edges stay bare. A
  non-`plain` CPU order pairs with `sys` scope only — one skip line in the
  loop — because CPU ops are scope-free and the pair they close is the
  cross-device one.
- **Device cut**: which procs are GPU (next section). The grid lives on the
  GPU procs, the only place scopes exist.

`hetgen7` is handed the CPU cycle and the GPU cycle of one cell separately
(`-cpu`, `-gpu`) and keeps for each proc the column of the run that owns its
device (`het-generation.md`).

## Device cuts and their reduction

A cut assigns each of the n procs to `cpu` or `gpu`; every assignment but
all-CPU (litmus7's own path) and all-GPU (the gpu-only corpus) is a raw cut,
2ⁿ−2 of them. Two raw cuts are one experiment when a symmetry of the cycle
maps one onto the other. The edge list rotated to its first `Po` edge is
diy's proc list (diy numbers P0 from the first `Po` edge, `gen/cycle.ml`; a
cycle opening with an external edge, WRC's `Rfe PodRW Rfe PodRR Fre`, puts
that edge's single-access proc last), one segment per proc — its run of `Po`
edges plus the external edge leaving it — and a rotation of the segments
that leaves the list unchanged token for token is a renaming of procs and
locations. The corpus keeps one cut per orbit of the raw cuts under those
rotations, under the lexicographically smallest tag (`cut_classes`): SB, LB,
2+2W, 3.2W, 3.SB and 3.LB are invariant under rotation by one proc, so `gc`
is `cg` and `cgc` is `ccg` with the procs renamed; IRIW under rotation by
two, which exchanges the two writers and the two readers; every other shape
under none. A rotation that fixes the edge list is a literal
renaming, so the reduction drops no distinct experiment; and it keeps no two
tests that are one experiment up to proc permutation and location renaming.

## Byte-dedup

Not every cell is a distinct test. An order whose annotation has no access
of its kind to land on renders the body of a weaker one: `acq` on a
writes-only GPU proc is `rlx`, `ra` on a reads-only one is `acq`, every fence
order on a proc with a single GPU access is `rlx` (no `Po` edge to sit on),
and a barrier CPU order on a single-access CPU proc is `plain`. After the
loop the generator keys every test by its body — the file from its `{` line
on, which drops the name header and the comment — and deletes each test
whose body equals an earlier one's, logging the survivor. The loop order
decides which name survives: shapes, cuts, scopes, CPU orders and GPU orders
each in table order, so a collapsed cell keeps the earliest name it equals.
The census a run prints is the cells written and dropped, with the cut
classes per shape.

## Names

het: `<shape>-<cut>-<scope>-<cpu>.<gpu>`, the cut one letter per proc
(`c`/`g`), the CPU order spelled out (`plain` included), the GPU order after
the dot; the x86_64 rendering appends `-x86_64`. gpu-only:
`<shape>-<scope>-<gpu>`. A name says which cell a test is; which cells exist
is the dedup's.

## The CPU ISA of a rendering

A CPU ISA is a profile (`CPU_ISAS`): the `-cpu-arch` tag `hetgen7` takes, the
file-name suffix, the CPU-order list and the renderer.

- **aarch64** (the default): `plain` (the bare cycle), `ra` (the `Q` atom on
  reads and `L` on writes: LDAPR and STLR; why RCpc rather than LDAR:
  `faithfulness.md`, "CPU column (AArch64)"), `sy`, `st` and `ld`
  (`DMB.SY|ST|LD<L><XY>` on each `Po` edge).
- **x86_64**: `plain` and `mf` (`MFence<L><XY>` on each `Po` edge). Under
  x86-TSO [Sewell10 §3.1] the store/load pair is the only reordering and
  MFENCE the instruction that removes it, so a release store, an acquire
  load or a one-sided barrier has no image distinct from the plain cycle or
  from MFENCE: the profile has two orders by construction. The x86_64
  rendering is therefore a smaller set of cells than the AArch64 one, not a
  renaming of it, and its names are its own.

The grid, the cuts, the loops and the GPU renderer are ISA-free. A new CPU
ISA is one profile row and one renderer in `grid.py`, beside
what the tools need to accept it: a `-cpu-arch` arm in `gen/hetGen.ml` over a
diy backend (`gen/<Isa>Compile_gen.ml`), and in litmus7 a device tag and a
`HetCpuFront` module (`het-litmus-format.md` sec 3; `het-emission.md`, "CPU
ISA from the device tag").

## The gpu-only corpus

The gpu-only corpus is the all-GPU cut of the same product — the same shapes,
scopes, GPU orders and renderer — emitted through `diyone7 -arch LISA` with
the scope tree passed as `-scopes`, and byte-deduped the same way. What the
artifact behind it contributes, and which of its kernels are not cells:
`gpu-only-corpus.md`.
