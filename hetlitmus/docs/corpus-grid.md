# HetLitmus corpus grid

The rule that generates the corpora `hetlitmus/tests/gpu-only/generate.sh` and
`hetlitmus/tests/het/generate.sh` write, and why it is shaped as it is. The
tables the rule runs over — shapes, device cuts, scopes, orders, token
renderers, name formats — are the variables and functions of
`hetlitmus/tests/_grid_lib.sh`, which both generators source; re-running a
generator reproduces its corpus and its `@all` manifest. The het corpus has
four families, lettered by `generate.sh`'s section labels: (A) the reference
tests, (B) the one-sided scope × order grid, (D) the matched two-sided tests
and (E) the two-sided order pairs (suffix `-2s`).

Related: `gpu-only-corpus.md` (the artifact-anchored tests and the vendor-scope
boundary), `het-generation.md` (how `hetgen7` merges two single-arch runs into
one `Het` test), `het-litmus-format.md` and `het-emission.md`.

## The shape catalogue

`SHAPE_CYCLE` holds each shape as a closed critical cycle in diy's
architecture-agnostic edge vocabulary: `Po<L><XY>` is intra-proc program order
X→Y with `L` = `d` (different location) or `s` (same); `Rfe`, `Fre` and `Coe`
are the external read-from, from-read and coherence edges. MP, SB, LB and IRIW
are the artifact's shapes; 2+2W, R, S, WRC, RWC, ISA2 and WRC3 (a 3-hop MP/WRC
chain) extend the different-location family; CoRR, CoWR and CoRW2 are the
same-location (coherence) family.

What diy fixes about the catalogue:

- The `Co` names and their edge order are diy's own: `diyone7` without `-name`
  returns `CoRR`, `CoWR` and `CoRW2` for these cycles, and refuses `PosWR Coe
  Fre` and `Rfe PosRW Fre` ("Impossible direction") because a `Pos` edge's far
  end must agree in direction with the external edge that follows it.
- A cycle whose program-order edges are all `Pos` touches one location, which
  diy refuses without `-oneloc`; every generator passes it.
- Each `Coe` edge puts one location in the condition (`[x]`, `[y]`); a cycle
  with no `Coe` names none, the case `HetCond.condition_locations` answers
  with an empty list.
- A diy edge token admits no underscore (`gen/common/lexUtil.mll`), so the
  acquire-release fence tag is `acqrel`, not PTX's `acq_rel`.

## The scope × order grid

Every shape is swept over `GRID_SCOPES` × `GRID_ORDERS`. The annotation rule
is the artifact's: reads carry `acquire|relaxed`, writes `release|relaxed`
(`ord_for`). The `fence` column keeps every access relaxed and places a
standalone `f[sc,<scope>]` between the two accesses of each proc: the `Po`
edge becomes `FenceSc<Scope><L><XY>`, which diy supports as it stands. Nothing
external bounds that column: the artifact contains no fence and no `sc`
operation, so no `fence` test has an external reference.

Each proc sits in its own CTA (`scope_tree`), as the artifact places its
threads, so a cta-scope annotation is too narrow to cross threads: scope
strength is read from the tree, not assumed.

A non-relaxed column byte-identical to its relaxed sibling is not a new
experiment and is dropped: `acquire` on an all-write shape, and, in the het
corpus, a column whose changed annotation lands on a CPU proc or on a GPU proc
with no matching access (on a `Co` shape, which columns survive follows the
proc the cut put on the GPU). The census of a corpus is this arithmetic —
shapes (× cuts) × scopes × orders, minus the dropped columns, plus the
fixed-name tests — and each generator prints its split as it runs. The
artifact-anchored gpu-only tests keep the artifact's names; an x86_64 rendering
appends `-x86_64`.

## Heterogeneous device cuts

The grid lives on the GPU procs, the only place scopes exist; CPU procs are
plain. Which procs are GPU is `SHAPE_HET_CUTS`, chosen by role and reduced by
symmetry, not the 2ⁿ subsets:

- 2-proc shapes: both directions, except SB, LB and 2+2W, whose cycle is
  invariant under rotation-by-two (which swaps P0/P1): the annotation follows
  the device rather than the proc index, so `gpu,cpu` is `cpu,gpu` with the
  labels exchanged. Such a rotation duplicate is not a corpus member.
- 3-proc shapes and WRC3 (every proc a distinct role): each proc in turn is the
  sole GPU participant.
- IRIW (two symmetric writers, two symmetric readers): the four symmetry
  classes — one writer, one reader, both writers, both readers on the GPU.

## The two-sided families

Family (B) annotates the GPU half alone: `hetgen7 -cpu <edges>` is parsed
verbatim, so every CPU proc of a (B) test stays a plain ld/st and no
cross-device pair closes. (D) and (E) annotate both halves, always at `sys`
scope: ARM ops are scope-free, so the CPU tokens carry no scope, and the GPU
half is rendered at `sys` so the pair it closes is the cross-device one.

### (D) Matched two-sided

`TWO_SIDED_ORDERS`, each applied to both devices over every shape and cut of
`SHAPE_HET_CUTS`.

Why the CPU acquire is the RCpc `LDAPR` rather than `LDAR`: `faithfulness.md`,
"CPU column (AArch64)". A two-sided test byte-identical below its name header to its
one-sided `-sys-<order>` sibling is dropped, as the grid drops a degenerate
column. Only `fence` can be — (B) emits no `-sys-acqrel` sibling — and it is
where every CPU proc of the cut is a single access with nothing for a barrier
to sit between. That condition is the same in every CPU ISA, so a rendering in
another ISA drops the same names and stays name-for-name with the corpus.

### (E) Two-sided order pairs

(D) gives both devices the same order name — the diagonal of a CPU-order ×
GPU-order product — and what a primitive orders depends on its proc's
program-order pair. (E) sweeps the off-diagonal, `TWO_SIDED_CPU_ORDERS` ×
`TWO_SIDED_GPU_ORDERS`, named `<shape>-<cuttag>-sys-<cpu>.<gpu>-2s`. The two
cells that reproduce (D) token for token — `ra.ra` = `-sys-acqrel-2s`, `sy.sc`
= `-sys-fence-2s` — are skipped.

Shapes and cuts (`TWO_SIDED_PAIR_SHAPES`, `SHAPE_2S_PAIR_CUTS`): the 2-proc
different-location shapes MP, SB, LB, R and S, which realise all four `Pod`
kinds — WW, RR, WR, RW — on each side while two procs keep a cell legible, one
CPU and one GPU token per test. SB and LB take one cut for the rotation reason
above; a `Pos` shape stays out, only one of its procs carrying a pair.

## The CPU ISA of a rendering

`generate.sh` renders all four families for one CPU ISA per run, named by
`--cpu-arch`: `aarch64` is the default and the committed corpus; `x86_64` goes
to an OUTDIR of the caller's, since a rendering in a non-default ISA is
refused into `tests/het`. Each test's name is the corpus name plus the ISA
suffix (`<name>-x86_64`), and the drop rules of (B) and (D) fire on the same
names in every ISA, so a rendering is name-for-name with the corpus. It is not
experiment-for-experiment with it: under x86-TSO [Sewell10 §3.1] the four CPU
tokens collapse onto two images, `ra`/`st`/`ld` → the bare cycle (plain
`movl`) and `sy` → `MFence<L><XY>` (`mfence`), in `render_2s_x86_64`. What
follows for the x86 lane, and why the rendering is produced on demand:
`het-emission.md`, "Scope / limits".

The grid, the cuts, the four loops and the GPU renderer are ISA-free. A CPU
ISA is a profile in `_grid_lib.sh` — one `render_2s_<isa>` renderer, one arm
of `render_2s_cpu`, one entry in `CPU_ARCHS` and one row each in `CPU_ARCH_NAME`
and `CPU_ARCH_SFX` — beside
what the tools need to accept it: a `-cpu-arch` arm in `gen/hetGen.ml` over a
diy backend (`gen/<Isa>Compile_gen.ml`), and in litmus7 a device tag and a
`HetCpuFront` module (`het-litmus-format.md` sec 3; `het-emission.md`, "CPU
ISA from the device tag").
