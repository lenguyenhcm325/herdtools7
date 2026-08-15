# `nvidia-ptx.cat` — transcription-fidelity record

`hetlitmus/cats/nvidia-ptx.cat` transcribes a published axiomatic PTX memory
model into herd7's cat language over the `hetlitmus/bells/ptx.bell` annotation
vocabulary. This note answers one question: **how faithful is the transcription,
and where does it depart?**

It is a solver, not an oracle. It predicts nothing about hardware, decides no
thesis test, and no run path consults it. Its only executable consumer is
`hetlitmus/verify/ordercheck.py`, whose PTX phase (`make hetlitmus-lattice`)
decides 96 sys-scope LISA cells so that the per-primitive ordering table behind
`verify/controlmap.py`'s positive-control lattice meets a model instead of being
asserted.

---

## 1. Sources

* **[Lustig19]** D. Lustig, S. Sahasrabuddhe, O. Giroux, *"A Formal Analysis of
  the NVIDIA PTX Memory Consistency Model"*, ASPLOS'19
  (`papers/AFormalAnalysisoftheNVIDIAPTXMemoryConsistencyModel.pdf`). The model
  being transcribed.
* **[PTXISA]** NVIDIA PTX ISA 9.3, §8.8 *"Release and Acquire Patterns"* and
  §9.7.14.4 *"membar/fence"*
  (`docs.nvidia.com/cuda/parallel-thread-execution/`). Cited only for the
  extension in §3.
* **[PTXISA60]** NVIDIA PTX ISA 6.0, §9.7.12.3 *"membar/fence"*
  (`docs.nvidia.com/cuda/archive/9.0/parallel-thread-execution/`) — the ISA
  revision [Lustig19] analyses. Cited only for the extension in §3.

**A later formalisation exists, and this file does not follow it.** D. Lustig,
S. Cooksey, O. Giroux, *"Mixed-Proxy Extensions for the NVIDIA PTX Memory
Consistency Model: Industrial Product"*, ISCA'22, keeps the same six axioms
(§6.1) and states its deltas as proxy-related: moral strength gains the
condition *"Both operations are performed via the same proxy"* (§6.2.2); base
causality gains program order, of which the paper says *"This change by itself
has no effect in the pre-existing memory model without proxies"* (§6.2.3); and a
proxy-preserved base causality order is newly created (§6.2.4). `ptx.bell`
carries no proxy tag, so this transcription targets the pre-proxy ASPLOS'19
model by construction. Whether the ISCA'22 revision would decide the 96 lattice
cells identically is **not** adjudicated here.

---

## 2. Where each definition comes from

| `.cat` definition | [Lustig19] |
|---|---|
| `pattern_rel`, `pattern_acq`, `obs`, `sw`, `cause_base`, `cause` | Fig 4 |
| `Wrel`, `Racq`, `Frel`, `Facq` = the `W^{≥REL}`, `R^{≥ACQ}`, `F^{REL}`, `F^{ACQ}` sets of Fig 4 | Fig 4 notation; §3.4.1 |
| `ms` — strong, mutually scope-encompassing, overlapping if both are memory ops; program-order pairs included | §3.3 |
| `sc` — acyclic order relating every morally-strong `fence.sc` pair | §3.4.3 |
| `sync_barrier` — CTA execution barriers | §3.4.2 |
| scope tags `'cta`/`'gpu`/`'sys`, fence semantics | Fig 3c |
| Axiom 1 `coherence` — `[W]; cause; [W] ⊆ co` | Fig 7; §3.5.1 |
| Axiom 2 `fence_sc` — `irreflexive(sc; cause)` | Fig 7; §3.5.2 |
| Axiom 3 `atomicity` — `empty(((ms ∩ fr);(ms ∩ co)) ∩ rmw)` | Fig 7; §3.5.3 |
| Axiom 4 `no_thin_air` — `acyclic(rf ∪ dep)` | Fig 7 |
| Axiom 5 `sc_per_location` — `acyclic((ms ∩ (rf ∪ co ∪ fr)) ∪ po_loc)` | Fig 7 |
| Axiom 6 `causality` — `irreflexive((rf ∪ fr); cause)` | Fig 7 |

The axiom formulas are spelled out because Axioms 5 and 6 are the pair secondary
accounts swap: the `acyclic(… ∪ po_loc)` formula is SC-per-Location, and
Causality is `irreflexive((rf ∪ fr); cause)`.

`ms` is computed from the `scopes:` tree each test carries: `enc` is the union
over scope levels of `[tagged-at-S]; tag2scope(S)`, and `mutual = enc & enc⁻¹`
is mutual encompassment. With each proc in its own CTA, cta-scope operations on
different procs are not mutually encompassing.

---

## 3. The one extension: `Frel` / `Facq` admit `fence.release` / `fence.acquire`

The cat defines

```
let Frel = F & (REL | SCo)        (* F^{>=REL} : fence.release, fence.sc   *)
let Facq = F & (ACQ | SCo)        (* F^{>=ACQ} : fence.acquire, fence.sc   *)
```

so `f[release,<scope>]` and `f[acquire,<scope>]` complete Fig 4's
`([Frel]; po; [W])` and `([R]; po; [Facq])` patterns. **[Lustig19] does not model
those fences.** Fig 3c gives the modelled fence as `fence{.sem}.scope` with
`.sem = {.sc, .acq_rel}` and `.scope = {.cta, .gpu, .sys}`, under the caption
*"We explicitly model the highlighted portions"* with both lines highlighted. The
paper's own `F^{REL}` / `F^{ACQ}` therefore range over `{acq_rel, sc}` alone.

The extension is disclosed rather than removed, on two grounds:

1. **The paper writes these fences even where it does not model them.**
   [Lustig19] Figure 11 (*"Our mapping from C/C++ to PTX"*, §4.2, p.265) names
   `fence.acquire.<sco>` and `fence.release.<sco>` in its PTX column, as the
   targets of the scoped-C++ fences `F^{ACQ,sco}` and `F^{REL,sco}` (beside
   `fence.acq_rel.<sco>` and `fence.sc.<sco>`). Three things hold at once, and
   the extension rests on the first: the paper's mapping table **writes** these
   fences (Fig 11, p.265); its axioms do not **range over** them (Fig 3c,
   p.260); and the ISA of the day did not **define** them — PTX ISA 6.0, the
   revision [Lustig19] analyses, gives the fence as `fence{.sem}.scope` with
   `.sem = {.sc, .acq_rel}` and no `.acquire` or `.release` ([PTXISA60]
   §9.7.12.3). They are defined now:
   [PTXISA] §9.7.14.4 gives `.sem = { .sc, .acq_rel, .acquire, .release }` and
   states, verbatim, *".acquire and .release qualifiers for fence instruction
   introduced in PTX ISA version 8.6"* and *".acquire and .release qualifiers
   for fence instruction require sm_90 or higher."* The same bound is recorded
   in-tree at `litmus/CudaLang.ml` (`fence.{acquire,release}.<any>` : PTX ISA
   8.6, SM_90), nvcc-verified on CUDA 12.9.
2. **[PTXISA] §8.8 puts them in exactly these pattern positions.** The release
   pattern includes *"a release or acquire-release memory fence followed by a
   strong write on M in program order"* (`fence.release; st.relaxed [M];`), and
   the acquire pattern includes *"a strong read on M followed by an acquire
   memory fence in program order"* (`ld.relaxed [M]; fence.acquire;`).

**It is load-bearing.** Restricting both sets to `F & SCo` — Lustig19's modelled
subset — flips **20 of ordercheck.py's 96 PTX cells** from Forbidden to Allowed
(five `MP`, ten `LB`, five `S`; every one a cell where a `fence.release` or
`fence.acquire` completes the pattern). The lattice gate would then certify
positive-control siblings against a table the solver no longer supports.

A caveat, not carried into the `.cat`: `ptxas` 12.9 accepts `fence.release.sys`
at `.version 6.0` / `.target sm_70`, i.e. it enforces neither floor. For version
and target floors the spec is authoritative and the assembler is not.

---

## 4. Local specialisations, and why each is harmless

### `let dep = 0` — forced, not chosen

herd7 binds `dep` for its native architectures, not for a Bell model, so Axiom 4
cannot mention `dep` unless the cat defines it. Deleting the line makes the model
fail to load:

```
$ grep -v '^let dep = 0$' hetlitmus/cats/nvidia-ptx.cat > /tmp/nodep.cat
$ herd7 -set-libdir herd/libdir -bell hetlitmus/bells/ptx.bell -cat /tmp/nodep.cat \
        hetlitmus/tests/gpu-only/LB-sys.litmus
File "/tmp/nodep.cat", line 125, characters 14-17: unbound var: dep
```

Binding it to `0` is faithful for the inputs this file sees: diy emits no
dependency edge on either surface (the edge vocabulary is `Po<L><XY>`,
`Fence<Order><Scope><L><XY>`, `Rfe`, `Fre`, `Coe`, with `L` the location letter
`d` or `s`). An input carrying a real dependency would need the binding
revisited.

### `let sync_barrier = 0`

`ptx.bell` declares `R`, `W` and `F` and no barrier instruction, so Fig 4's
`sync_barrier` term ([Lustig19] §3.4.2, `bar.sync`/`bar.red`/`bar.arrive`) has no
events to relate.

### `rmw` is empty

`ptx.bell` declares no read-modify-write instruction, so herd7's `rmw` is empty.
Two consequences, both transcribed rather than dropped: Fig 4's
`obs := (ms ∩ rf) ∪ (obs; rmw; obs)` collapses to its base term, written
`let obs = ms & rf`; and Axiom 3 (Atomicity) is vacuous but kept.

### `& loc` on Axiom 1

Fig 7 writes Coherence as `[W]; cause; [W] ⊆ co`. herd7's `co` is per-location,
so an unrestricted reading would demand that cause-ordered writes to *different*
locations be co-related, which no execution can satisfy. [Lustig19] §3.5.1
supplies the restriction in prose: PTX `co` is *"a partial transitive order that
relates overlapping write operations"*, and the spec rule quoted there is *"if a
write W precedes an overlapping write W' in causality order, then W must precede
W' in coherence order"*. So `& loc` restores the paper's *"overlapping"*.

Measured both ways: dropping `& loc` changes no verdict on either surface — 0 of
the 96 lattice cells, 0 of the 173 `tests/gpu-only` tests. It is not a no-op on
the executions themselves (`ISA2-{gpu,sys}-fence` fall from 18 candidate
executions to 6, `WRC3-{gpu,sys}-fence` from 44 to 30), so the two forms are
verdict-equivalent here rather than interchangeable.

### `sc` via `linearisations`

[Lustig19] §3.4.3 defines Fence-SC order as *"an acyclic partial order,
determined at runtime, that relates every pair of morally strong fence.sc
operations"*, adding that *"Morally weak fences may be related by sc order due to
transitivity, but they may also be unrelated in sc."* The cat writes

```
with sc_tot from linearisations(FSC, 0)
let sc = sc_tot & ms
```

`linearisations` makes herd7 enumerate total orders of the `fence.sc` events and
admit an execution if some enumerated order satisfies the axioms — the "determined
at runtime" existential. A total order relates every pair one way or the other,
so intersecting with `ms` relates every morally-strong pair; and any subrelation
of a total order is acyclic. Both requirements of the definition are therefore
met.

The formal gap is transitivity: a *partial order* containing the morally-strong
pairs also contains whatever transitivity forces through morally-weak fences, and
`sc_tot & ms` does not. Closing it (`let sc = (sc_tot & ms)+`) was measured and
changes nothing on either surface: 0 of 96 lattice cells, and byte-identical
`Observation` lines — including execution counts — across all 173
`tests/gpu-only` tests. Under a `scopes:` tree that puts each proc in its own CTA
and every CTA under one GPU under one SYS, all fences in a single test share one
scope, so the mixed morally-strong/morally-weak configuration that would separate
the two forms never arises.

---

## 5. Not transcribed: `f[acq_rel,*]`

`ptx.bell` admits `F[{'acquire,'release,'acq_rel,'sc}, scopes]`, but the cat's
`REL`, `ACQ` and `SCo` sets are `tag2events` of `'release`, `'acquire` and `'sc`
only. An `f[acq_rel,<scope>]` event would therefore land in neither `Frel` nor
`Facq`, where [Lustig19]'s `F^{≥REL}` and `F^{≥ACQ}` both contain it — `.acq_rel`
is one of the two fence semantics Fig 3c models.

The omission is unexercised, and cannot be exercised by the generator: diy has no
edge name for it, because `FenceAcq_relSys` does not lex (`tests/_grid_lib.sh`,
under the two-sided order vocabulary). No `.litmus` file in the tree carries an
`acq_rel` fence. It is recorded here rather than closed because closing it would
change model behaviour that no consumer asks for.

---

## 6. Reproduce

```sh
# The live consumer: 192 solver cells (96 AArch64 + 96 PTX) against the table,
# plus the four injections that must redden it.
make hetlitmus-lattice

# herd7 parses and solves every gpu-only test under this model.
cd hetlitmus/tests/gpu-only
herd7 -set-libdir ../../../herd/libdir -bell ../../bells/ptx.bell \
      -cat ../../cats/nvidia-ptx.cat @all | grep -c '^Observation'   # 173
```
