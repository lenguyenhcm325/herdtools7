# HetLitmus corpus grid

This note documents the systematic litmus corpus that
`hetlitmus/tests/gpu-only/generate.sh` and `hetlitmus/tests/het/generate.sh`
produce, the shared library that drives them, and two additions a reader should
know about: the **fence column has no external reference** and the
**`CPU_ARCHS` knob**.

It supplements the earlier per-area docs: `gpu-only-corpus.md` (the original 8
PLDI'23-anchored tests), `het-generation.md` (how `hetgen7` merges
two single-arch runs into one `Het` test) and `het-litmus-format.md` /
`het-emission.md` (the compound format and harness emission).

## What was added

Before: ~10 hand-listed tests (8 GPU-only + MP-het/SB-het). After:

| corpus    | tests | manifest |
|-----------|-------|----------|
| gpu-only  | 137   | `tests/gpu-only/@all` |
| het       | 411   | `tests/het/@all`      |

Both corpora are now driven from committed, reproducible scripts that also write
an `@all` list-file (herd7/litmus7 read `@all` as "one test path per line",
`lib/misc.ml:is_list`). Re-running either `generate.sh` reproduces its corpus.

**Scope of *this* note.** What follows describes the **one-sided** scope × order
grid — the 248 het tests whose GPU procs are annotated and whose CPU procs are
plain ARMv9. The het corpus has since grown two further families that the same
`generate.sh` emits and specifies in place — its arms (D) and (E), over the token
table and order-pair rules in `hetlitmus/tests/_grid_lib.sh`: the **matched
two-sided** tests (`-2s`) and the **two-sided order pairs** (`-2s` with an
`<cpu>.<gpu>` order). The current split of the 411 by family, like
the counts here, is re-derivable at any time from `hetlitmus/tests/het/*.litmus`
(and `verify/dupcheck.py` reports how many of them are distinct experiments).

## The shape catalogue

`tests/_grid_lib.sh` (sourced by both scripts) defines each standard shape as a
closed critical cycle in diy's architecture-agnostic edge vocabulary
(`Pod<XY>` = intra-proc program order X→Y to a different location; `Rfe`/`Fre` =
read-from/from-read external; `Coe` = coherence-order external):

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

MP/SB/LB/IRIW already had their original PLDI'23-anchored variants; 2+2W, R, S,
WRC, RWC, ISA2 and the transitive chain WRC3 are the newly added shapes.

## The scope × order grid

Every shape is swept over **scope ∈ {cta, gpu, sys}** × **order ∈ {relaxed,
acquire, release, fence}**. The annotation rule (matching the original corpus):
reads carry `acquire|relaxed`, writes carry `release|relaxed`. Concretely, per
order column:

- **relaxed** — every access relaxed (the baseline weak test).
- **acquire** — reads `acquire`, writes `relaxed`.
- **release** — writes `release`, reads `relaxed`.
- **fence** — every access `relaxed`, plus a standalone scoped fence between the
  two accesses of each proc (see below).

Each proc sits in its own CTA (`scopes: (sys (gpu (cta 0) (cta 1) ...))`), so a
cta-scope release/acquire is too narrow to cross threads and does not fire —
scope strength is *read* from the tree, not assumed (same convention as
`MP-cta-F`).

**Degenerate columns are dropped.** A non-relaxed column that comes out
byte-identical to its relaxed sibling is not a new test, so it is skipped: e.g.
`acquire` on the all-write shape 2+2W (no read to upgrade), and, in the het
corpus, any column whose changed annotation landed on a CPU proc or on a GPU
proc with no matching access. GPU-only drops 3 such columns; the one-sided het
grid drops 66 (11 shapes × 3 scopes × 4 orders = 132, +8 fixed-name originals
= 140, −3 ⇒ 137 gpu-only; 26 het cut-classes × 3 × 4 = 312, +`MP-het`/`SB-het`
= 314, −66 ⇒ 248 one-sided het).

### Naming

- GPU-only: `<shape>-<scope>-<order>.litmus` (e.g. `WRC-sys-acquire.litmus`,
  `2+2W-gpu-fence.litmus`). The original 8 keep their fixed names (`MP-sys`,
  `MP-sys-F`, `MP-cta-F`, `LB-sys`, `SB-sys`, `SB-sys-F`, `IRIW-sys`,
  `IRIW-sys-F`) because that is how the PLDI'23 artifact names them.
- Het: `<shape>-<cuttag>-<scope>-<order>.litmus` (e.g. `MP-cg-sys-fence.litmus`,
  `WRC-gcc-gpu-release.litmus`), where `<cuttag>` abbreviates the device cut
  (`cpu`→`c`, `gpu`→`g`). MP-het/SB-het keep their reference names.

## Heterogeneous device cuts (which procs are CPU vs GPU)

The scope/order grid lives on the **GPU** procs (the only place scopes exist);
CPU procs are plain AArch64. Device direction follows the settled role-based,
symmetry-reduced rule (NOT 2ⁿ subsets):

- **2-proc** shapes: both directions — `cpu,gpu` and `gpu,cpu` — except `SB`, `LB`
  and `2+2W`, which emit `cpu,gpu` only: their cycle is invariant under
  rotation-by-two, which swaps P0/P1, and the annotation follows the device rather
  than the proc index, so `gpu,cpu` would be `cpu,gpu` with the labels exchanged
  (`verify/dupcheck.py` holds that honest).
- **3-proc** shapes (each proc a distinct role): each proc, in turn, is the sole
  GPU participant — `gpu,cpu,cpu`, `cpu,gpu,cpu`, `cpu,cpu,gpu`.
- **IRIW** (2 symmetric writers + 2 symmetric readers): the four symmetry-class
  cuts — one writer on GPU, one reader on GPU, both writers on GPU, both readers
  on GPU.
- **WRC3** (a 4-stage causal chain, all roles distinct): each chain stage, in
  turn, on the GPU.

## Two things to know

### 1. The fence column has no external reference

The `fence` column is a **real standalone scoped fence**, distinct from the
rel/acq columns: the accesses stay relaxed and diy inserts a Bell fence event
`f[sc,<scope>]` between the two accesses of each proc (the intra-proc edge
`Pod<XY>` is generated as the fence edge `FenceSc<Scope>d<XY>` — diy supports
this directly, no generator code change). PTX renders this as
`fence.sc.<scope>`.

What bounds the column is **provenance, not expressiveness**. There is no fence
and no `sc` operation anywhere in the PLDI'23 artifact, so its verdicts reach the
original 8 and no part-(B) grid test: an offline `oracle-compare.sh` pass of a
grid row against a CSV built from that artifact reports UNINTERPRETED rather than
a verdict.

### 2. The `CPU_ARCHS` knob (het corpus)

The het CPU procs default to **AArch64 only** (matching the GH200 target;
byte-identical to before). `hetgen7` already accepts `-cpu-arch`; the script
mirrors it as an environment knob:

```sh
CPU_ARCHS="aarch64 x86_64" ./generate.sh
```

emits x86_64 het variants (suffix `-x86_64`) alongside the AArch64 ones with no
code edit. The x86_64 files are **not committed by default** (`CPU_ARCHS`
defaults to `aarch64`).

## End-state checks (reproduce)

```sh
# 1. counts  (the het total includes the two-sided families)
ls hetlitmus/tests/gpu-only/*.litmus | wc -l                     # 137
ls hetlitmus/tests/het/*.litmus      | wc -l                     # 411
ls hetlitmus/tests/het/*.litmus | grep -vc -- '-2s\.litmus'      # 248 one-sided

# 2. herd7 prints one Observation per GPU-only test
cd hetlitmus/tests/gpu-only
herd7 -set-libdir ../../../herd/libdir -bell ../../bells/ptx.bell \
      -cat ../../cats/nvidia-ptx.cat @all | grep -c '^Observation'   # 137

# 3. every het test parses + routes through litmus7
cd ../het
while read f; do litmus7 -gpu-target cuda -set-libdir ../../../litmus/libdir -o /tmp/r "$f"; done < @all

# 4. no regression
dune build                                           # exit 0
```
