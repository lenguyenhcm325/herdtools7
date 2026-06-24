# The NVIDIA GH200 het oracle (`expected-nvidia.csv`)

`hetlitmus/tests/het/expected-nvidia.csv` is the reference oracle for the
**heterogeneous** corpus on the **GH200 Grace-Hopper** target: an **ARMv9 Grace
CPU + a Hopper GPU running PTX**, i.e. the **NVIDIA-PTX-AArch64 compound memory
model**. It is the NVIDIA counterpart to the AMD/x86 GPU-only oracle
`tests/gpu-only/expected-amd-gcn3.csv`, and it is what makes the het tests
something other than `NO-ORACLE` in `oracle-compare.sh`.

The verdicts are **derived, not measured** — this step is hardware-free (running
the tests on a GH200 is Task 9). Every row is grounded in one of three primary
sources; no verdict is guessed, and every row carries its grounding in the
`Source` column. Columns mirror the AMD file exactly: `Litmus,Expected,Model,
Source`, with `Model = NVIDIA-PTX-AArch64`. The file is **regenerated
reproducibly** by `tests/het/build-nvidia-oracle.sh` from the `.litmus` names.

> **What changed in Task 3.** The Task-2 corpus annotated **only GPU procs**, so
> every het cut left an ordering-critical proc on a plain ARMv9 CPU and the
> oracle forbade *nothing* (279 Allowed + 2 NO-ORACLE). Task 3 adds a **two-sided**
> family (`-2s`) that annotates the **CPU procs too** (`STLR`/`LDAPR`/`DMB.SY`),
> so a complete morally-strong cross-device pair can form and the targeted
> outcome can be **Disallowed**. The one-sided baseline is preserved unchanged.

## Provenance (the three sources)

- **[CMCM]** Goens, Chakraborty, Sarkar, Agarwal, Oswald, Nagarajan, *Compound
  Memory Models*, PLDI'23. A heterogeneous machine's model is the
  **compositional amalgamation** of its devices': each thread keeps its own
  device's ordering rules, and a cross-device outcome is forbidden only when
  **both** sides supply a morally-strong synchronisation. Their MP example
  (Fig 2a) forbids the weak outcome on x86TSO/PTX **because the x86 consumer
  orders its two loads for free** — and the paper explicitly adds: *"the
  consumer thread would have needed an acquire or a stronger fence in a memory
  model such as PTX."*
- **[PTX]** Lustig, Sahasrabuddhe, Giroux, *A Formal Analysis of the NVIDIA PTX
  Memory Consistency Model*, ASPLOS'19. PTX is a **scoped, weakly-ordered
  (Release-Consistency)** model. Two ops are **morally strong** iff both are
  *strong* (`.relaxed`/`.acquire`/`.release`/fence) **and** each op's scope
  encompasses the *thread* executing the other (§3.3); `.sys` scope includes the
  host CPU; `.cta`/`.gpu` do not reach it. The six axioms (Fig 7) decide every
  shape: **No-Thin-Air** is `acyclic(rf ∪ dep)` (so dependency-free LB is *not*
  forbidden), MP is forbidden via release/acquire `sw`→`cause`→Causality (Fig 5),
  **SB needs `fence.sc`** — "acquire/release alone cannot prevent SB" (Fig 6) —
  and **PTX is not multi-copy-atomic** (§3.4, so IRIW is not forbidden by
  rel/acq).
- **[Bagchi]** Bagchi, Srivastava, Levine, Sorensen, Stutsman, Nagarajan,
  *Consistency and Coherence of the NVIDIA Grace-Hopper Superchip*, ISMM'26.
  The **empirical** GH200 study. ARMv9 Grace is **relaxed RC** and its *unscoped*
  ops are treated as **system-scope** (§3.2, §4.2). The CPU release in their
  Fig 1 compiles to **`STLR`** and the GPU acquire to `ld.acquire.sys`. They
  validated **message passing**: "the weak outcome was forbidden **only when both
  sides supplied the required ordering — a release/producer-fence on the producer
  AND an acquire/consumer-fence on the consumer**" (§4.1 Tab 3); and across 1,960
  heterogeneous MP variants "**No correctly synchronized system-scope test
  exhibited weak behaviors**" (§4.2 Tab 4). §5 establishes **global CPU-GPU cache
  coherence** (one coherence order per location, directory/CHI over NVLink-C2C).
  The **ARM-MCA × PTX-non-MCA interaction (IRIW, transitive cumulativity) is
  explicitly left for future work** (§4.2). (RMWs over-synchronise vs spec —
  irrelevant here: the corpus has no RMW.)

## The CPU instruction mapping (decision + grounding)

The two-sided tests need the CPU (AArch64) half of each morally-strong pair. The
`-cpu` edge cycle is parsed **verbatim** by diy's AArch64 builder (`hetGen.ml`;
no OCaml change), and `tests/_grid_lib.sh:render_cpu_cycle` emits:

| C++/PTX op | ARM instruction | diy atom | grounding |
|---|---|---|---|
| `memory_order_release` | **`STLR`** (RCsc release store) | `L` | Bagchi Fig 1: the GH200 toolchain compiles a C++ release store to `STLR`. |
| `memory_order_acquire` | **`LDAPR`** (RCpc load-acquire) | `Q` | GCC ≥13.1 / LLVM ≥16 emit `LDAPR` for `std::atomic` acquire on `-mcpu=neoverse-v*`; Grace is Armv9 Neoverse V2 (FEAT_LRCPC). |
| SC fence | **`DMB.SY`** (full system barrier) | — (`DMB.SYd<XY>` edge) | Bagchi Fig 2c: `DMB` orders store→load. |

ARM ops are **scope-free** — an unscoped ARM access is treated as **system
scope** (Bagchi §3.2) — so no scope token is appended (unlike the GPU/Bell side).
The atom letters were probed from `diyone7 -arch AArch64 -show annotations`
(`L`=`STLR`, `Q`=`LDAPR`, `A`=`LDAR` (RCsc, unused)).

**Why RCpc (`LDAPR`), not RCsc (`LDAR`)?** Two reasons, one of them
*verdict-changing*:

1. **Fidelity.** RCpc is what the modern Grace (Neoverse V2) toolchain actually
   emits for `std::atomic` acquire, and RCpc is the semantics that *matches* C++
   `memory_order_acquire` and PTX `ld.acquire`; `LDAR` (RCsc) is *stronger than*
   the language model.
2. **It is the only choice consistent with SB/R.** RCsc would additionally order
   `STLR → LDAR` (a release-store before a later acquire-load to a different
   address), so an `acqrel` annotation on a store→load proc would wrongly **forbid
   SB/R**. RCpc (`STLR → LDAPR` reorderable) keeps SB/R **Allowed** under
   release/acquire and **Disallowed only under a full `DMB.SY`/`fence.sc`** — matching
   both PTX (Fig 6 "acquire/release alone cannot prevent SB") and the AMD oracle
   precedent (`SB-sys` Allowed, `SB-sys-F` Disallowed).

For every shape in *this* corpus the two are otherwise verdict-equivalent (no
proc places a release-store before an acquire-load to a different address except
the store→load shapes just discussed), so the choice is load-bearing exactly
where it should be.

## The corpus: one-sided baseline + two-sided pairs

`generate.sh` emits **338** het tests:

- **281 one-sided** (the Task-2 baseline, unchanged): GPU procs annotated, CPU
  procs plain ARMv9. Grid `<shape>-<cuttag>-<scope>-<order>` over scope ∈
  {cta,gpu,sys} × order ∈ {relaxed,acquire,release,fence}, plus the `MP-het`/
  `SB-het` references.
- **57 two-sided** (`-2s`, new): **both** devices annotated, at **sys scope**, for
  the two **complete** pairings only:
  - **`acqrel`** — reads → acquire (`LDAPR`/`ld.acquire.sys`), writes → release
    (`STLR`/`st.release.sys`);
  - **`fence`** — `DMB.SY` (CPU) + `fence.sc.sys` (GPU) between each proc's two
    accesses.

  Two-sided is restricted to **sys** scope (cta/gpu can never encompass the CPU
  regardless of CPU annotation — Bagchi r3-5,21-22; PTX §3.3) and to the
  *complete* pairings (`acquire`/`release` alone annotate only one role and never
  close a pair). A two-sided test whose CPU procs have no instruction to attach
  to (e.g. `IRIW-gcgc` fence: both CPU procs are single writers) is dropped as
  *not actually two-sided*.

## The labelling rule

### One-sided (the plain-CPU baseline) — unchanged from Task 2

A targeted (relaxed) outcome is **forbidden on GH200 iff** every ordering-critical
proc carries the needed intra-proc ordering. A **GPU** proc qualifies only with a
**sys-scope** annotation; a **CPU** proc on the one-sided baseline is plain ARMv9
and **never** qualifies. So:

| column / case | verdict | why |
|---|---|---|
| `relaxed` (any scope) | **Allowed** | no synchronising op at all |
| `cta` scope (any order) | **Allowed** | scope too narrow to encompass the CPU (Bagchi r3-5) |
| `gpu` scope (any order) | **Allowed** | excludes the CPU thread (Bagchi Fig 4e, r21-22) |
| `sys` + rel/acq/fence (one-sided) | **Allowed** | the paired/ordering-critical CPU proc is plain ARMv9 → pair incomplete |
| `sys` + acquire/fence, **IRIW-gcgc** | **NO-ORACLE** | both readers GPU (reader-order present) but IRIW needs MCA — see below |

This deliberately overrides the naive "MP/WRC/S/ISA2 with sys rel/acq ⇒
Disallowed", which holds only for an **x86TSO** CPU (the AMD/x86 oracle), whose
loads/stores are implicit acquire/release. The GH200 CPU is ARMv9, so that half
is genuinely absent — and Bagchi observed the corresponding weak behaviours
(Table 4 rows 2,6-7,10-11,16-18).

### Two-sided (`-2s`) — the new Disallowed verdicts

With both halves annotated at sys scope, the decision procedure extends from
"the CPU is never ordered" to "**a CPU proc is ordered iff its column carries
`STLR`/`LDAPR`/`DMB.SY`**". The verdict then turns on the *shape*:

| shape(s) | `acqrel` | `fence` | grounding |
|---|---|---|---|
| **MP** | **Disallowed** | **Disallowed** | 2-proc; complete sys rel/acq (or DMB/fence.sc) pair cuts the cycle. **Empirically** forbidden: Bagchi Tab 4 "no correctly synchronized system-scope test exhibited weak". |
| **LB** | **Disallowed** | **Disallowed** | 2-proc; acquire (or fence) orders load→store on both devices; cycle cut. No MCA needed. (cf. AMD `LB-sys`.) |
| **S** | **Disallowed** | **Disallowed** | 2-proc; single-hop rel/acq `hb` + one global coherence order on the contended write (Bagchi §5). No MCA needed. |
| **SB, R** | **Allowed** | **Disallowed** | store→load: RCpc `STLR→LDAPR` (and PTX rel/acq) do **not** order store→load → `acqrel` insufficient (Allowed); `DMB.SY`/`fence.sc` do → fence Disallowed (cf. AMD `SB-sys`/`SB-sys-F`). |
| **RWC** | **Allowed** | **NO-ORACLE** | `acqrel`: its W→R proc is unfenced → weak outcome survives without invoking MCA. `fence`: 3-proc transitive (see below). |
| **2+2W** | **NO-ORACLE** | **NO-ORACLE** | needs a global write-write order = multi-copy atomicity. |
| **WRC, ISA2, WRC3** | **NO-ORACLE** | **NO-ORACLE** | transitive: need cross-device **A-cumulativity** through a GPU intermediary. |
| **IRIW** | **NO-ORACLE** | **NO-ORACLE** | needs **multi-copy atomicity**. |

**Why the conservatism (the NO-ORACLE frontier).** Bagchi empirically validated
only **MP** (2-proc, the direct producer→consumer pattern, with both rel/acq and
DMB barriers). The other 2-proc shapes are **derived** from the CMCM
compositionality + per-device semantics, each using only that **direct
producer→consumer** mechanism (or none): LB is pure per-proc load→store ordering
(no cross-thread propagation at all); S reuses the very release→acquire (or
producer-DMB) edge Bagchi validated for MP, plus the single global coherence
order on the contended location (§5); SB/R need only that the two SC fences order
each proc's store→load. None of these requires propagating a write *atomically
through a GPU intermediary*. The transitive shapes (WRC, RWC-fence, ISA2, WRC3) do
— they need **A-cumulativity** through a GPU forwarder to a third party — and
IRIW/2+2W need **multi-copy atomicity**; that **ARM-MCA × PTX-non-MCA interaction
is exactly what Bagchi §4.2 leaves for future work**. Neither `Allowed` nor
`Disallowed` is grounded there in the three sources, so honesty demands
`NO-ORACLE`.

### Honesty (unchanged)

An **observed** weak outcome makes a verdict `Allowed` and is robust; a
**non-observation NEVER proves** `Disallowed`. Every `Disallowed` row is a model
**derivation**, not a measurement (running on a GH200 is Task 9). In
`oracle-compare.sh` a `Disallowed` test merely seen as `Never` is `MATCH`
("forbidden, not seen") — *not* a confirmation; only an **observed** forbidden
outcome is a hard contradiction (`MISMATCH`).

## Verdict tally

**338 rows** (one per `.litmus`): **286 Allowed, 16 Disallowed, 36 NO-ORACLE.**

- 16 Disallowed = MP·LB·S × {cg,gc} × {acqrel,fence} (12) + SB·R × {cg,gc} ×
  {fence} (4).
- 36 NO-ORACLE = the 2 one-sided `IRIW-gcgc` + 34 two-sided (2+2W, WRC, RWC-fence,
  ISA2, IRIW, WRC3).
- 286 Allowed = 279 one-sided baseline + 7 two-sided (SB·R `acqrel`, RWC `acqrel`).

## The two one-sided NO-ORACLE tests

`IRIW-gcgc-sys-acquire` and `IRIW-gcgc-sys-fence` are the one-sided cut where
**both** ordering-critical readers (P0,P2) are GPU at sys scope, so the
reader-ordering half is present; but IRIW also needs multi-copy atomicity, which
PTX lacks and whose compound ARM/PTX behaviour is the §4.2 frontier — hence
`NO-ORACLE`. (The two-sided `IRIW-*-2s` tests are `NO-ORACLE` for the same
reason.)

## The GPU-only NVIDIA oracle (`tests/gpu-only/expected-nvidia.csv`)

A companion file gives the **pure PTX** (both procs GPU) verdicts for the 8
PLDI'23-anchored GPU-only tests, `Model = NVIDIA-PTX`, grounded purely in [PTX]
(+ Bagchi Hopper-GPU empirics). It exists to make the **vendor difference**
explicit — the same `.litmus` files, different verdicts:

| test | AMD-GCN3 | NVIDIA-PTX | why they differ |
|---|---|---|---|
| `MP-sys-F` | Disallowed | **Disallowed** | rel/acq forbids MP on both (PTX Fig 5). |
| `LB-sys` | Disallowed | **Allowed** | PTX No-Thin-Air = `acyclic(rf ∪ dep)`; LB has no dep (Axiom 4). |
| `SB-sys-F` | Disallowed | **Allowed** | PTX needs `fence.sc` for SB; rel/acq alone cannot (Fig 6). |
| `IRIW-sys-F` | Disallowed | **Allowed** | PTX is non-MCA; rel/acq cannot forbid IRIW (§3.4). |

AMD's HRF makes system-scope rel/acq a heavyweight cache flush (so it forbids
SB/IRIW/LB); PTX rel/acq is pure ordering. This is *why* a separate NVIDIA oracle
is needed and the AMD CSV must not be reused.

## Reproduce / verify

```sh
cd hetlitmus/tests/het
./generate.sh                                                # 338 tests, @all
./build-nvidia-oracle.sh                                     # regen the CSV (+ tally to stderr)

# 1. exactly one row per .litmus, no file missing, no extra/dup
ls *.litmus | wc -l                                          # 338
grep -vE '^#|^Litmus,' expected-nvidia.csv | wc -l           # 338
diff <(ls *.litmus | sed 's/\.litmus$//' | sort -u) \
     <(grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f1 | sort -u)   # empty

# 2. verdict tally + a two-sided test carries STLR/LDAPR/DMB on its CPU proc
grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f2 | sort | uniq -c
#   286 Allowed   16 Disallowed   36 NO-ORACLE
grep -E 'STLR|LDAPR|DMB SY' MP-cg-sys-acqrel-2s.litmus MP-gc-sys-fence-2s.litmus

# 3. drive the harness (synthesized; the sample includes a real MISMATCH)
cd ../../..
./hetlitmus/oracle-compare.sh \
    hetlitmus/tests/het/sample-observations-nvidia.txt \
    hetlitmus/tests/het/expected-nvidia.csv             # MATCH/MISMATCH/NO-ORACLE, exit 1
```

## Files

| File | Purpose |
|------|---------|
| `tests/het/expected-nvidia.csv` | the NVIDIA GH200 het oracle (this doc) |
| `tests/het/build-nvidia-oracle.sh` | reproducibly regenerates the het oracle from the corpus |
| `tests/het/sample-observations-nvidia.txt` | synthesized log driving the harness (MATCH + MISMATCH + NO-ORACLE) |
| `tests/het/generate.sh`, `tests/_grid_lib.sh` | emit the corpus (one-sided baseline + two-sided `-2s`) |
| `tests/gpu-only/expected-nvidia.csv` | the pure-PTX GPU-only oracle (vendor-difference companion) |
| `tests/gpu-only/expected-amd-gcn3.csv` | the AMD/x86 oracle (do **not** reuse for NVIDIA) |
| `oracle-compare.sh` | the comparison harness (unchanged) |
