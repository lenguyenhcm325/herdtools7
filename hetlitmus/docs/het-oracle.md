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
  explicitly left for future work** (**§2.1, p. 68** — the deferral is stated in
  the background section, not in §4.2 where this doc used to point it; corrected
  by NVOR 2026-08-06). (RMWs over-synchronise vs spec —
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

`generate.sh` emits **411** het tests:

- **248 one-sided** (the Task-2 baseline, unchanged): GPU procs annotated, CPU
  procs plain ARMv9. Grid `<shape>-<cuttag>-<scope>-<order>` over scope ∈
  {cta,gpu,sys} × order ∈ {relaxed,acquire,release,fence}, plus the `MP-het`/
  `SB-het` references.
- **51 two-sided, matched** (`-2s`, Task 3): **both** devices annotated, at
  **sys scope**, for the two **complete** pairings only:
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
- **112 two-sided, order-pair** (`-2s` with order `<cpu>.<gpu>`, Q10 + Q10b):
  the **off-diagonal** of the same pairing grid, on the 2-proc shapes minus
  `2+2W` — 8 cut classes × (4 CPU × 4 GPU − 2 diagonal). Q10 shipped 48 of
  them with the CPU axis stuck at `{ra,sy}`; Q10b lifted the emitter blocker
  and added the other 64. See "Two-sided order pairs" below.

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
is exactly what Bagchi §2.1 (p. 68) leaves for future work**. Neither `Allowed` nor
`Disallowed` is grounded there in the three sources, so honesty demands
`NO-ORACLE`.

### Two-sided **order pairs** (`-2s` with order `<cpu>.<gpu>`) — Q10

The table above covers the two *matched* pairings the corpus started with:
`acqrel` applies release/acquire to both devices, `fence` applies a full barrier
to both. Both are **diagonal** cells of a pairing grid that was never swept.
Q10 sweeps the off-diagonal on the six 2-proc shapes (minus `2+2W`):

| axis | values | name token |
|---|---|---|
| CPU | `STLR`/`LDAPR` atoms, `DMB SY`, `DMB ST`, `DMB LD` | `ra`, `sy`, `st`, `ld` |
| GPU | `w[release,sys]`/`r[acquire,sys]` atoms, `f[sc,sys]`, `f[release,sys]`, `f[acquire,sys]` | `ra`, `sc`, `rel`, `acq` |

so `MP-cg-sys-sy.acq-2s` is MP on the `cpu,gpu` cut with `DMB SY` between the
CPU producer's two stores and `fence.acquire.sys` between the GPU consumer's two
loads. The two diagonal cells are **not** re-emitted: `ra.ra` **is**
`<shape>-<cut>-sys-acqrel-2s` and `sy.sc` **is** `<shape>-<cut>-sys-fence-2s`,
and `generate.sh` regenerates each under its `(D)` name and byte-diffs the
committed file rather than assuming it. `SB` and `LB` emit the `cg` cut only
(their cycle is rotation-invariant, so `gc` would be the same experiment with
the labels exchanged — `make hetlitmus-dup` is what holds that honest).

> **THE BLOCKED AXIS, LIFTED (Q10b).** Q10 asked for `DMB ST` / `DMB LD` on the
> CPU and could not ship them: diy generated them, the rule below decided them
> and `ordercheck.py` machine-checked them, but **no such test could be
> emitted** — `litmus/hetCpuBody.ml` accepted only `DMB SY` / `DSB SY` and
> called `Warn.fatal` on any other `I_FENCE`. Q10b added the two match arms
> (`DMB (SY, ST)` → `dmb st`, `DMB (SY, LD)` → `dmb ld`; both assemble under
> `clang --target=aarch64-linux-gnu` with no architectural extension), so the
> CPU axis is now four values wide and the grid is 4 × 4. **Not one line of the
> verdict rule changed** to accept the 64 new cells — they were already decided.

These verdicts are **not hand-written**. `build-nvidia-oracle.sh` carries a
compositional rule over two per-primitive facts, and
`hetlitmus/verify/ordercheck.py` (`make hetlitmus-order`) proves the rule is the
same function herd7 computes — 96 CPU-only cells under herd7's **native AArch64
model**, 96 GPU-only cells under **`nvidia-ptx.cat`** (mixed cells included:
atoms on one proc, a barrier on the other, which is what separates `ord` from
`role`), plus every two-sided 2-proc row of `expected-nvidia.csv` including the
legacy `-fence-2s` / `-acqrel-2s` rows read as the `(sy,sc)` / `(ra,ra)` cells.

**ord(p)** — the program-order pairs the primitive orders *inside its own
thread*:

| | WW | RR | WR | RW |
|---|---|---|---|---|
| `DMB SY` / `f[sc,sys]` | ✓ | ✓ | ✓ | ✓ |
| `STLR`/`LDAPR`, `w[release]`/`r[acquire]` | ✓ | ✓ | | ✓ |
| `f[release,sys]` (and `DMB ST`: WW only) | ✓ | | | ✓ |
| `f[acquire,sys]` (and `DMB LD`) | | ✓ | | ✓ |

The ARM rows are herd7's own answer (Phase 1 of the gate *is* their derivation).
The GPU rows are [CMCM] §5 verbatim: *"a request that is marked with `sem ≥ rel`
enforces R + pred → W and W → W. A request with `sem ≥ acq` enforces R → R and
R → W, and an sc fence additionally enforces W → R."* Note the missing `WR`
column for release/acquire — that is RCpc, and it is exactly why `SB`/`R` stay
Allowed under everything but a double SC fence.

**role(p)** — which half of a morally-strong pair it can supply: `DMB SY` /
`f[sc,sys]` → {rel, acq, sc}; `STLR`/`LDAPR` and `w[release]`/`r[acquire]` →
{rel, acq}; `f[release,sys]` → {rel}; `f[acquire,sys]` → {acq}.

**The rule.**

| condition | verdict |
|---|---|
| some side's own model leaves that side's own program-order pair unordered | **Allowed** |
| both sides order their own pair **and** the [PTX] pattern completes | **Disallowed** |
| both sides order their own pair **but** the [PTX] pattern does not complete | **NO-ORACLE** |

"the [PTX] pattern completes" = the rf-source proc supplies `rel` and the
rf-target proc supplies `acq` (either direction, for LB which carries two `rf`
edges); or — for a cycle with **no** `rf` at all (SB, R, 2+2W) — **both** procs
supply `sc`, which is [PTX] Fig 6 (*"requires a `fence.sc` to be placed between
the memory operations in each thread. PTX also requires the two fences to be
morally strong."*).

**The rule above is the ORDERING layer only.** Since the NVOR regeneration
(2026-08-06, below) a cell the rule forbids is shipped `Disallowed` only if every
*registration* its derivation needs was accepted; three were declined, so a
further 34 rows are `NO-ORACLE`. The counts in this section are the ordering
rule's own, i.e. what `NVOR_ACCEPT_DECLINED=1` reproduces.

The 112 emitted cells come out **37 Disallowed / 67 Allowed / 8 NO-ORACLE**
(Q10's 48 gave 22/21/5; Q10b's 64 add 15/46/3):

| cut class | D | A | NO | |
|---|---|---|---|---|
| MP-cg | 7 | 7 | 0 | producer=CPU: needs `rel` + WW; consumer=GPU: needs `acq` + RR |
| MP-gc | 7 | 7 | 0 | mirrored |
| SB-cg | 0 | 14 | 0 | W→R on both procs: only `sy.sc` (already existing) reaches it |
| LB-cg | 9 | 4 | 1 | both procs R;W and LB has `rf` **both** ways, so most cells pair |
| R-cg | 0 | 12 | 2 | no `rf`: needs `sc` on both, which only `sy.sc` has |
| R-gc | 0 | 12 | 2 | ditto |
| S-cg | 7 | 4 | 3 | producer=CPU (WW, `rel`); consumer=GPU (RW, `acq`) |
| S-gc | 7 | 7 | 0 | mirrored |

The 15 cells Q10b added on the `st`/`ld` CPU rows are exactly those where a
**partial** CPU barrier is the half its role needs: `MP-cg` and `S-cg`
`st.{ra,sc,acq}` (CPU producer `W;W`, so `DMB ST` suffices and supplies `rel`),
and `MP-gc`, `S-gc`, `LB-cg` `ld.{ra,sc,rel}` (CPU consumer reads first, so
`DMB LD` suffices and supplies `acq`).

**Why the third row is NO-ORACLE and not Disallowed — [CMCM] says so itself.**
CMCM ships **two** compound models: the operational LOST-POP model of §4–5 and
the axiomatic CMM of §6.2, the latter "designed to be a **sound abstraction** of
the x86TSO/PTX operational model, *i.e.* permit all behavior observable in the
operational model" (§6). CMM's PTX component is exactly [PTX] Fig 4/Fig 7 (CMCM
Fig 12), so the axiomatic model permits **strictly more**. §5.1 states where,
verbatim:

> There are two ways in which our operational model is stronger than the
> axiomatic PTX model:
> (1) Write serialization is enforced within the causality constraints by our
> operational model, but not by the axiomatic PTX model.
> (2) Release and acquire fences are slightly stronger in cumulative chains of
> events, downstream of a release fence (so-called B-cumulativity [Alglave
> et al. 2014]). In our operational model, events can be transitively ordered
> using **either release or acquire fences**, though the axiomatic PTX model
> would only order if the fence is at least acqrel.

and Fig 11's caption names the witnesses: *"In 2+2W, PTX allows r1 = 1, r2 = 1
but this behavior is not allowed our operational model. Similarly, in ISA2 with
an Acq (11b) or Rel (11c) fence, the outcome … is allowed in PTX but disallowed
in our model. PTX requires the fence to be acqrel for the outcome to be
disallowed, whereas our model disallows it with either of the three."*

Every NO-ORACLE cell of this grid is an instance of (1) or (2) — the operational
model forbids, the axiomatic one does not, and CMCM does not say which the
hardware follows. Concretely, `LB-cg-sys-ld.acq-2s` (`DMB LD` on the CPU,
`fence.acquire.sys` on the GPU, both ordering load→store) is **Forbidden** by
herd7's AArch64 model for the all-ARM analogue and **Allowed** by
`nvidia-ptx.cat` for the all-PTX analogue. Calling it Disallowed would
manufacture a falsification claim out of a modelling disagreement the paper
itself documents; calling it Allowed would assert a weak outcome the operational
CMCM forbids. It is characterization — and, incidentally, the cheapest available
experiment on precisely the §5.1 divergence.

**What is *not* machine-checked.** That a CPU `DMB` and a sys-scope GPU fence
are morally strong *at all*, i.e. that the two sides compose across the C2C
boundary. That is [CMCM] §3.2.3 (*"We address compositionality by treating every
non-scoped order constraint coming from a non-scoped memory model as system
scoped (i.e., global scope)"*) and §4.4 (*"in an unscoped LOST-POP model, all
requests should be system-scoped"*; *"to be disallowed, both fences need to be
system-scoped"*), [Bagchi] §3.2 (*"CPU unscoped operations are treated as
system-scoped when synchronizing with a GPU that employs a scoped model"*) and
[PTX] Table 1, where `.sys` covers *"all threads constituting the host program
itself"*.

`2+2W` is deliberately **not** given fence-pair variants: its cycle is two `co`
edges with no `rf`, so every verdict would turn on cross-device write-write
multi-copy atomicity — the question [Bagchi] §2.1 explicitly defers — and it
would land NO-ORACLE by shape, not by annotation.

### Honesty (unchanged)

An **observed** weak outcome makes a verdict `Allowed` and is robust; a
**non-observation NEVER proves** `Disallowed`. Every `Disallowed` row is a model
**derivation**, not a measurement (running on a GH200 is Task 9). In
`oracle-compare.sh` a `Disallowed` test merely seen as `Never` is `MATCH`
("forbidden, not seen") — *not* a confirmation; only an **observed** forbidden
outcome is a hard contradiction (`MISMATCH`).

## Verdict tally

**411 rows** (one per `.litmus`): **319 Allowed, 16 Disallowed, 76 NO-ORACLE.**

- **16 Disallowed**, every one of them cut by a **CPU-producer (`cg`) direction**
  synchronization: LB-cg 4 + MP-cg 6 + S-cg 6. MP-cg and S-cg each contribute
  their two diagonal cells (`-acqrel-2s`, `-fence-2s`) plus four order-pair
  cells whose GPU half is a rel/acq atom pair or a `fence.sc`; LB-cg contributes
  the same six **minus** `ld.ra` and `ld.sc`, whose CPU `DMB LD` carries only the
  acquire role, so their only route is the **declined** `gc` meet (NVOR Phase D3
  — note that `cg` here names the *direction of the synchronizing `rf`*, not the
  test's name tag; on `LB` the two can differ).
- **76 NO-ORACLE** = 34 + 8 + **34 NVOR-demoted**.
  - 34 = the 2 one-sided `IRIW-gcgc` + 32 matched two-sided (2+2W, WRC,
    RWC-fence, ISA2, IRIW, WRC3) — cross-device MCA / A-cumulativity.
  - 8 order-pair = R-cg 2 + R-gc 2 + S-cg 3 + LB-cg 1, the cells where CMCM's
    operational and axiomatic models disagree (see below).
  - 34 = the NVOR demotions: **23 `gc`-direction** (Q2), **3 rf-free** (Q3),
    **8 unidirectional-fence `cg`** (Q4). Per-row list:
    `build-nvidia-oracle.sh --declined-list`.
- **319 Allowed** = 246 one-sided baseline + 6 matched two-sided (SB-cg·R
  `acqrel`, RWC `acqrel`) + 67 order-pair. **Unchanged by NVOR** — the
  adjudication took the lenient reading of Q4b, so no Allowed row moved.

Up to (proc permutation × location renaming) the 16 `Disallowed` files are
**16 distinct experiments** — the corpus's falsification surface (`make
hetlitmus-dup`; the `cg`/`gc` mirror pairs that used to collapse three of them
were removed from the corpus on 2026-08-01). It was 50 before NVOR and 18 before
NVOR Phase D3.

## NVOR — the registrations behind the Disallowed surface (2026-08-06)

The NVIDIA-lane provenance audit (`env-research/NVOR-phaseC-brief.md`, adjudicated
by Nguyen; decisions in `env-research/NVOR-register.md`) found that the entire
Disallowed surface rested on premises that were correct-looking, **uncited, and
never registered as decisions**. Seven were put up; the ones that move rows:

| id | the registration | verdict | rows |
|---|---|---|---|
| **Q1** | ARMv9 plain accesses are PTX **strong** ops on the generic proxy, the builder's `ROLE` table is the ARM→PTX request-type map, and an unscoped ARM op meets a `.sys` PTX op at **system** scope — **in the CPU-producer direction** | **ACCEPT** | keeps 16 |
| **Q2** | the meet is **symmetric**, i.e. the same holds with the GPU as producer | **DECLINE** | 23 → NO-ORACLE |
| **Q3** | a CPU `DMB SY` **is** a PTX `fence.sc` for the Fence-SC total order | **DECLINE** | 3 → NO-ORACLE |
| **Q4** | `fence.acquire` / `fence.release` semantics (PTX ISA 8.6 / SM_90, postdating Lustig'19) | **DECLINE** | 8 → NO-ORACLE |
| **Q4b** | the 18 *Allowed* rows making a **negative** `ord` claim about the same instructions keep `Allowed` on the a-fortiori transfer, disclosed | **LENIENT** | 0 moved |
| **Q5** | a `fence.sc` still heads a release pattern and completes an acquire pattern (the semantic-lattice reading of PTX ISA §8.8), keyed to **Lustig'19**, with the ≥ 8.8 clause-narrowing as a **disclosure** | **ACCEPT** | keeps 8 |
| **Q6** | `CMCM Fig2a` struck as a key (it is the x86TSO+PTX example and CMCM §3.1 attributes its forbidden verdict to *the x86TSO consumer's* acquire semantics — no ARMv9 load has that) | **ACCEPT** | re-key only |

Why Q2 is the interesting one: **every scrap of GH200 system-scope heterogeneous
evidence is CPU-producer.** Bagchi Table 4 has `GPU_rlx` in the Consumer column of
all 13 CPU-producer rows, `GPU_acq` nowhere, and its only `GPU_rel` rows (21–22)
are at `gpu` scope, never `system`; Fig 4a is CPU-producer; the §3.2 doctrinal
derivation is CPU-producer. CMCM's own footnote 7 warns the meet "*can be
asymmetrical*". So the 23 `gc`-direction rows became a **pre-registered,
hardware-falsifiable prediction** rather than a silent assumption — which is what
Q10's two-sided `cg`/`gc` sweep was built to expose in the first place.

**Nothing was demoted to `Allowed`.** Silence is not permission, and a wrongly-
Allowed row can absorb a real violation as an `ALLOWED-OBSERVED` "confirmation".

**The demoted rows are still run.** `NVOR_ACCEPT_DECLINED=1` re-derives the
pre-regeneration verdicts (319/50/42) into a **separate** file
`expected-nvidia-declined.csv` — a counterfactual can never clobber the oracle —
and `make hetlitmus-nvroundtrip` asserts the round trip touches exactly those 34
rows and nothing else. **Observing one of the listed outcomes on GH200 is DATA,
never a refutation of the compound model.**

### Phase D3 — the blind-pass repair (2026-08-06)

Phase E staged the 18 shipping `Disallowed` rows plus 16 controls into a directory
holding only the `.litmus` sources and a `herd7` toolchain, and asked a **blind**
analyst to re-derive every verdict from primary sources under the register's
premise sheet. **16 of 18 were confirmed**; two — `LB-cg-sys-ld.ra-2s` and
`LB-cg-sys-ld.sc-2s` — were challenged, and the challenge was sustained.

Both the shell generator and its independent Python cross-check derived the `GC`
slot from the test's **name tag** (`cuttag[0]`, `cut[0]`) rather than from the
**direction of the `rf` that carries the `sw`**. On `MP` (`PodWW Rfe PodRR Fre`)
and `S` (`PodWW Rfe PodRW Coe`) the cycle has one `Rfe` and the two coincide; on
`R` and `SB` there is none and neither applies; on `LB` (`PodRW Rfe PodRW Rfe`)
there are **two**, so a `cg`-*named* test synchronizes `gc`-wards whenever its CPU
primitive carries only the acquire role. `DMB LD` does not order prior stores, so
it cannot head a release pattern — leaving GPU-release → CPU-acquire as the only
route, which is exactly the meet **Q2 declined**.

Because *both* implementations were wrong by *the same* rows, the count pin and
the demoted-set sha were stable at the wrong value — the one failure the
register's §4 names as uncatchable by either alone. Only the blind derivation
found it. The repair keys the slot on the direction in both implementations,
independently, and each is bitten: `ordercheck.py --bite` restores the name-tag
predicate and must redden `ORACLE`; `build-nvidia-oracle.sh --bite` rewrites the
generator three ways and must redden the generator's own census pin.

| row | before | after |
|---|---|---|
| `LB-cg-sys-ld.ra-2s`, `LB-cg-sys-ld.sc-2s` | `Disallowed` | **`NO-ORACLE` / `S_GC_MEET_UNKEYED`** |
| `LB-cg-sys-{ld,ra,sy}.rel-2s` | `NO-ORACLE` / `S_UNIDIR_UNKEYED` | `NO-ORACLE` / `S_GC_UNIDIR_UNKEYED` |
| `R-gc-sys-fence-2s` | `NO-ORACLE` / `S_GC_SC_UNKEYED` | `NO-ORACLE` / `S_SC_IDENT_UNKEYED` |
| `LB-cg-sys-{acqrel,fence,ra.sc,sy.ra}-2s` | `Disallowed`, prose naming the `gc` route | `Disallowed`, prose naming the **registered `cg`** route |

Census **319/18/74 → 319/16/76**; demoted set **32 → 34**, sha
`71ebe7baba4fbb83` → `31df21956128093d`. The three re-slotted `.rel` rows matter
beyond bookkeeping: they were verdict-safe *only* because Q4 is also declined, so
registering Q4 (register open item **O2**) would have re-armed them to
`Disallowed` on the declined `gc` meet as a silent side effect. This repair
therefore had to land **before** any O2 decision, and it did. Report:
`env-research/NVOR-DR-nvidia-oracle.md`.

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
./generate.sh                                                # 411 tests, @all
./build-nvidia-oracle.sh                                     # regen the CSV (+ tally to stderr)

# 1. exactly one row per .litmus, no file missing, no extra/dup
ls *.litmus | wc -l                                          # 411
grep -vE '^#|^Litmus,' expected-nvidia.csv | wc -l           # 411
diff <(ls *.litmus | sed 's/\.litmus$//' | sort -u) \
     <(grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f1 | sort -u)   # empty

# 2. verdict tally + a two-sided test carries STLR/LDAPR/DMB on its CPU proc
grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f2 | sort | uniq -c
#   319 Allowed   16 Disallowed   76 NO-ORACLE

# 2b. the NVOR slot toggle: the 34 demoted rows + the round trip to 319/50/42
./build-nvidia-oracle.sh --declined-list                     # 34 rows + their slots
./build-nvidia-oracle.sh --roundtrip                         # the G16-analog gate
./build-nvidia-oracle.sh --bite                              # the D3 direction predicate
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
