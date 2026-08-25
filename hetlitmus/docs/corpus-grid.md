# HetLitmus corpus grid

This note specifies the litmus corpora that
`hetlitmus/tests/gpu-only/generate.sh` and `hetlitmus/tests/het/generate.sh`
produce, the shared library that drives them (`hetlitmus/tests/_grid_lib.sh`),
the het corpus's four families — the letters are `generate.sh`'s section
labels: (A) the reference tests, (B) the one-sided scope × order grid, (D) the
matched two-sided tests, (E) the two-sided order pairs — and two things a
reader should know about: the **fence column has no external reference** and
the **`CPU_ARCHS` knob**.

It supplements the per-area docs: `gpu-only-corpus.md` (the 8 PLDI'23-anchored
tests), `het-generation.md` (how `hetgen7` merges two single-arch runs into one
`Het` test) and `het-litmus-format.md` / `het-emission.md` (the compound format
and harness emission).

## The corpora

| corpus    | manifest              |
|-----------|-----------------------|
| gpu-only  | `tests/gpu-only/@all` |
| het       | `tests/het/@all`      |

Both corpora are driven from committed scripts that also write an `@all`
list-file (herd7/litmus7 read `@all` as "one test path per line",
`lib/misc.ml` `is_list`). Re-running either `generate.sh` reproduces its
corpus.

**Scope of *this* note.** It specifies the **one-sided** scope × order grid (B)
— the het tests whose GPU procs are annotated and whose CPU procs are plain
ARMv9 — and the two two-sided families (D) and (E), which the same
`generate.sh` emits from the knobs in `_grid_lib.sh` (`TWO_SIDED_ORDERS`;
`TWO_SIDED_CPU_ORDERS` / `TWO_SIDED_GPU_ORDERS`, `TWO_SIDED_PAIR_SHAPES` /
`SHAPE_2S_PAIR_CUTS`). Family (A) is the two hand-specified reference tests,
`MP-het` and `SB-het`, whose cycles sit in `generate.sh` itself. The current
split of the het corpus by family is re-derivable at any time from
`hetlitmus/tests/het/*.litmus` (the two-sided families carry the `-2s`
suffix).

## The shape catalogue

`tests/_grid_lib.sh` (sourced by both scripts) defines each standard shape as a
closed critical cycle in diy's architecture-agnostic edge vocabulary
(`Po<L><XY>` = intra-proc program order X→Y, with `L` = `d` to a *different*
location and `s` to the *same* one; `Rfe`/`Fre` = read-from/from-read external;
`Coe` = coherence-order external):

| shape | procs | cycle |
|-------|-------|-------|
| MP    | 2 | `PodWW Rfe PodRR Fre` |
| SB    | 2 | `PodWR Fre PodWR Fre` |
| LB    | 2 | `PodRW Rfe PodRW Rfe` |
| 2+2W  | 2 | `PodWW Coe PodWW Coe` |
| R     | 2 | `PodWW Coe PodWR Fre` |
| S     | 2 | `PodWW Rfe PodRW Coe` |
| WRC   | 3 | `Rfe PodRW Rfe PodRR Fre` |
| RWC   | 3 | `Rfe PodRR Fre PodWR Fre` |
| ISA2  | 3 | `PodWW Rfe PodRW Rfe PodRR Fre` |
| IRIW  | 4 | `Rfe PodRR Fre Rfe PodRR Fre` |
| WRC3  | 4 | `Rfe PodRW Rfe PodRW Rfe PodRR Fre` (a 3-hop transitive MP/WRC chain) |
| CoRR  | 2 | `Rfe PosRR Fre` |
| CoWR  | 2 | `PosWR Fre Coe` |
| CoRW2 | 2 | `Rfe PosRW Coe` |

MP/SB/LB/IRIW carry the original PLDI'23-anchored variants. 2+2W, R, S, WRC,
RWC, ISA2 and the transitive chain WRC3 extend the different-location family;
CoRR, CoWR and CoRW2 are the same-location (coherence) family.

The three `Co` names are diy's own: put to `diyone7` without `-name`, those
cycles come back named `CoRR`, `CoWR` and `CoRW2`. Their edge order is not free
either — `PosWR Coe Fre` and `Rfe PosRW Fre` are both refused (*"Impossible
direction"*), because a `Pos` edge's far end has to agree in direction with the
external edge that follows it. A cycle whose program-order edges are all `Pos`
touches one location, which diy refuses unless the driver passes `-oneloc`; the
three scripts that drive this catalogue — `tests/gpu-only/generate.sh`,
`tests/het/generate.sh` and `tests/het/generate-x86.sh` — all pass it.

## The scope × order grid

Every shape is swept over **scope ∈ {cta, gpu, sys}** × **order ∈ {relaxed,
acquire, release, fence}** (`GRID_SCOPES`, `GRID_ORDERS`). The annotation rule
(matching the original corpus): reads carry `acquire|relaxed`, writes carry
`release|relaxed`. Concretely, per order column (`ord_for`, `render_cycle`):

- **relaxed** — every access relaxed (the baseline weak test).
- **acquire** — reads `acquire`, writes `relaxed`.
- **release** — writes `release`, reads `relaxed`.
- **fence** — every access `relaxed`, plus a standalone scoped fence between the
  two accesses of each proc (see below).

Each proc sits in its own CTA (`scopes: (sys (gpu (cta 0) (cta 1) ...))`,
`scope_tree`), so a cta-scope release/acquire is too narrow to cross threads
and does not fire — scope strength is *read* from the tree, not assumed (same
convention as `MP-cta-F`).

**Degenerate columns are dropped.** A non-relaxed column that comes out
byte-identical to its relaxed sibling is not a new test, so it is skipped: e.g.
`acquire` on the all-write shape 2+2W (no read to upgrade), and, in the het
corpus, any column whose changed annotation landed on a CPU proc or on a GPU
proc with no matching access. On a `Co` shape, which columns survive turns on
which proc the cut put on the GPU: a single-write proc keeps {relaxed, release},
an R;R proc keeps {relaxed, acquire, fence}, and a two-access proc keeps all
four. How many columns each corpus drops, and what that leaves: "Census
rationale" below.

### Naming

- GPU-only: `<shape>-<scope>-<order>.litmus` (e.g. `WRC-sys-acquire.litmus`,
  `2+2W-gpu-fence.litmus`). The original 8 keep their fixed names (`MP-sys`,
  `MP-sys-F`, `MP-cta-F`, `LB-sys`, `SB-sys`, `SB-sys-F`, `IRIW-sys`,
  `IRIW-sys-F`) because that is how the PLDI'23 artifact names them.
- Het, one-sided (B): `<shape>-<cuttag>-<scope>-<order>.litmus` (e.g.
  `MP-cg-sys-fence.litmus`, `WRC-gcc-gpu-release.litmus`), where `<cuttag>`
  abbreviates the device cut (`cpu`→`c`, `gpu`→`g`; `cut_tag`). MP-het/SB-het
  keep their reference names.
- Het, two-sided: `<shape>-<cuttag>-sys-<order>-2s` for (D) and
  `<shape>-<cuttag>-sys-<cpu>.<gpu>-2s` for (E), both below. An x86_64
  rendering of any het name appends `-x86_64`.

## Heterogeneous device cuts (which procs are CPU vs GPU)

The scope/order grid lives on the **GPU** procs (the only place scopes exist);
CPU procs are plain AArch64. Device direction follows the settled role-based,
symmetry-reduced rule (NOT 2ⁿ subsets), recorded per shape in `SHAPE_HET_CUTS`:

- **2-proc** shapes: both directions — `cpu,gpu` and `gpu,cpu` — except `SB`, `LB`
  and `2+2W`, which emit `cpu,gpu` only: their cycle is invariant under
  rotation-by-two, which swaps P0/P1, and the annotation follows the device rather
  than the proc index, so `gpu,cpu` would be `cpu,gpu` with the labels exchanged.
- **3-proc** shapes (each proc a distinct role): each proc, in turn, is the sole
  GPU participant — `gpu,cpu,cpu`, `cpu,gpu,cpu`, `cpu,cpu,gpu`.
- **IRIW** (2 symmetric writers + 2 symmetric readers): the four symmetry-class
  cuts — one writer on GPU, one reader on GPU, both writers on GPU, both readers
  on GPU.
- **WRC3** (a 4-stage causal chain, all roles distinct): each chain stage, in
  turn, on the GPU.

## The two-sided families

Family (B) annotates the GPU half alone: `hetgen7`'s `-cpu <edges>` is parsed
verbatim, so every CPU proc of a (B) test stays a plain ARMv9 ld/st and no
cross-device pair closes. The two families below annotate both halves. Every
two-sided test sits at `sys` scope: ARM ops are scope-free, so the CPU tokens
carry no scope token, and the GPU half is rendered at `sys` so the pair it
closes is the cross-device one.

### (D) Matched two-sided (`-sys-<order>-2s`)

Two orders, `acqrel` and `fence` (`TWO_SIDED_ORDERS`), each applied to **both**
devices:

- **`acqrel`** — reads → acquire, writes → release, on both sides. The CPU
  cycle is `render_cpu_cycle acqrel`, whose atoms come from `arm_ord`: `Q`
  (`LDAPR`, the RCpc acquire) on a read and `L` (`STLR`) on a write. The GPU
  cycle is `render_cycle sys acqrel` (`Acquire` / `Release`, the complete pair
  no one-sided column produces). The source of the CPU atom map, and why
  `LDAPR` rather than `LDAR`: `faithfulness.md`, "Sources".
- **`fence`** — accesses plain on both sides; each intra-proc `Po<L><XY>` becomes
  `DMB.SY<L><XY>` on the CPU (`render_cpu_cycle fence`, the `.litmus` cell is
  `DMB SY`) and `FenceScSys<L><XY>` on the GPU (`render_cycle sys fence`, the
  cell is `f[sc,sys]`), the external edges staying bare.

The family runs over every shape of the catalogue and every cut of
`SHAPE_HET_CUTS`; `generate.sh` (D) renders the AArch64 column only, and
`generate-x86.sh` (D) the x86_64 one.

**Degenerate drop.** A two-sided test that is byte-identical below its two-line
name header to its one-sided `-sys-<order>` sibling is skipped, exactly as the
grid drops a degenerate column. Only `fence` can bite — (B) emits no
`-sys-acqrel` sibling to compare against — and it bites where every CPU proc
of the cut is a single access, so the CPU barrier has nothing to sit between:
the `fence` cell of IRIW's `gcgc` cut (both CPU procs are single writers) and
of the `gc` cut of CoRR, CoWR and CoRW2 (the CPU proc is the single writer).
`generate.sh` (D) and `generate-x86.sh` (D) drop the same names, which is what
keeps the x86_64 renderings name-for-name with the committed corpus.

### (E) Two-sided order pairs (`-sys-<cpu>.<gpu>-2s`)

(D) gives both devices the same order name, i.e. only the diagonal of a
CPU-order × GPU-order product, and what a primitive orders depends on its
proc's program-order pair. (E) sweeps the off-diagonal: a CPU token from
`TWO_SIDED_CPU_ORDERS` (`ra sy st ld`) × a GPU token from
`TWO_SIDED_GPU_ORDERS` (`ra sc rel acq`), named
`<shape>-<cuttag>-sys-<cpu>.<gpu>-2s`.

| CPU token | `render_2s_cpu` renders it as | `.litmus` cells |
|-----------|-------------------------------|-----------------|
| `ra`  | `render_cpu_cycle acqrel`, token for token | `LDAPR` / `STLR` |
| `sy`  | `render_cpu_cycle fence`    — `DMB.SY<L><XY>` | `DMB SY` between the pair |
| `st`  | `render_cpu_cycle fence-st` — `DMB.ST<L><XY>` | `DMB ST` |
| `ld`  | `render_cpu_cycle fence-ld` — `DMB.LD<L><XY>` | `DMB LD` |

Each barrier form spells the intra-proc edge `DMB.<opt><L><XY>`, keeping the
location letter, and leaves the external edges bare; `render_2s_cpu` is the
only caller of the `fence-st` / `fence-ld` branches.

| GPU token | `render_2s_gpu` renders it as | `.litmus` cells |
|-----------|-------------------------------|-----------------|
| `ra`  | `render_cycle sys acqrel` | `r[acquire,sys]` / `w[release,sys]` |
| `sc`  | accesses relaxed, `FenceScSys<L><XY>` | `f[sc,sys]` |
| `rel` | accesses relaxed, `FenceReleaseSys<L><XY>` | `f[release,sys]` |
| `acq` | accesses relaxed, `FenceAcquireSys<L><XY>` | `f[acquire,sys]` |

For `sc` / `rel` / `acq` every access stays relaxed at `sys` and the ordering
sits in a standalone `Fence<o>Sys<L><XY>` edge, as the `fence` column does.

**Diagonal identities.** `ra.ra` ≡ `-sys-acqrel-2s` and `sy.sc` ≡
`-sys-fence-2s`: `render_2s_cpu ra` reproduces `render_cpu_cycle acqrel` and
`render_2s_gpu sc` reproduces `render_cycle sys fence` token for token, so (E)
skips those two cells and each cut-class emits 4 × 4 − 2 = 14 tests.

**Shapes and cuts** (`TWO_SIDED_PAIR_SHAPES`, `SHAPE_2S_PAIR_CUTS`): `MP SB LB
R S`, with MP, R and S in both directions and SB, LB as `cpu,gpu` only. The
product to cover is (primitive, program-order pair): these 2-proc shapes
realise all four `Pod` kinds — WW, RR, WR, RW — on each side, and two procs
keep a cell legible, one cpu and one gpu token per test. SB and LB emit one cut
for the rotation reason under "Heterogeneous device cuts"; a `Pos` shape stays
out, only one of its procs carrying a pair.

`f[acq_rel,sys]` is unavailable to the generator: `FenceAcq_relSys` does not
lex as a diy edge (`diyone7` stops with `lexing: empty token`), so no corpus
test carries it.

### Census rationale

The grid arithmetic gives each corpus's size:

- gpu-only: 14 shapes × 3 scopes × 4 orders = 168, +8 fixed-name originals =
  176, −3 degenerate columns = 173.
- het (A) + (B): 32 cut-classes (`SHAPE_HET_CUTS`) × 3 × 4 = 384, −87
  degenerate columns = 297, +`MP-het`/`SB-het` = 299 one-sided — every name
  without `-2s`.
- het (D): 32 cut-classes × 2 orders = 64, −4 degenerate `fence` cells = 60.
- het (E): 8 cut-classes × 14 cells = 112.
- 299 + 60 + 112 = 471.

`generate-x86.sh` prints exactly that breakdown as it runs (`(A) 2 + (B) 297
(skipped 87 degenerate) + (D) 60 (skipped 4 degenerate) + (E) 112 = 471`);
`generate.sh` prints the same per-section counts but tallies the two kinds of
skip together. The x86_64 renderings are name-for-name with the corpus but not
experiment-for-experiment: under x86-TSO the four CPU tokens collapse onto two
images — `ra` / `st` / `ld` → the bare base cycle (plain `movl`), `sy` →
`MFence<L><XY>` (`mfence`) — in `generate-x86.sh`'s `render_x86_cpu`; what
follows from that for the x86 lane is `het-emission.md`'s, "Scope / limits".

## Two things to know

### 1. The fence column has no external reference

The `fence` column is a **real standalone scoped fence**, distinct from the
rel/acq columns: the accesses stay relaxed and diy inserts a Bell fence event
`f[sc,<scope>]` between the two accesses of each proc (the intra-proc edge
`Po<L><XY>` is generated as the fence edge `FenceSc<Scope><L><XY>`, carrying the
same location letter — diy supports this directly, no generator code change).
PTX renders this as `fence.sc.<scope>`.

What bounds the column is **provenance, not expressiveness**. There is no fence
and no `sc` operation anywhere in the PLDI'23 artifact, so its verdicts reach the
original 8 and no part-(B) grid test: a CSV built from that artifact has no row
for a grid test at all, so an offline comparison the reader assembles decides
none of them.

### 2. The `CPU_ARCHS` knob (het corpus)

The het CPU procs default to **AArch64** (the GH200 target). `hetgen7` accepts
`-cpu-arch` (`aarch64` | `x86_64`), and `generate.sh` mirrors it as an
environment knob over its section (B):

```sh
CPU_ARCHS="aarch64 x86_64" ./generate.sh
```

emits x86_64 variants of the one-sided grid (suffix `-x86_64`) alongside the
AArch64 ones with no code edit. Sections (A), (D) and (E) of `generate.sh` are
AArch64 only, and `CPU_ARCHS` defaults to `aarch64`, so the committed corpus
carries no x86_64 file. The x86_64 rendering of all four sections is
`generate-x86.sh OUTDIR` (why it is not committed: `het-emission.md`,
"Scope / limits").
