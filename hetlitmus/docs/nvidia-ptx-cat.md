# NVIDIA PTX scoped axiomatic `.cat` — the GPU-only NVIDIA oracle

`hetlitmus/cats/nvidia-ptx.cat` is the scoped PTX model for NVIDIA Hopper. It
machine-checks `hetlitmus/tests/gpu-only/expected-nvidia.csv` (all **137**
GPU-only tests) and reproduces the **8** hand-derived PLDI'23-anchored verdicts.
Drive it with:

```
bash hetlitmus/cats/run-gpu-only-nvidia.sh     # RESULT: 137/137 match
```

It reads the *vendor-neutral* `.litmus` corpus through the
`hetlitmus/bells/ptx.bell` vocabulary; the vendor-specific part is the `.cat`
(the meaning), never the `.litmus` layer. The runner reads the verdict off
herd7's `Observation … Never|Sometimes|Always` line (Never ⇒ the targeted weak
outcome is unreachable ⇒ Forbidden/Disallowed).

---

## 1. Source authority (which model, and is it current?)

**Finding: the right authority is the Lustig'19 ASPLOS axiomatic PTX model, and
it is *not* superseded.** Every modelling decision below is grounded in primary
sources that were *read* (axioms, not abstracts):

* **[Lustig19]** D. Lustig, S. Sahasrabuddhe, O. Giroux,
  *"A Formal Analysis of the NVIDIA PTX Memory Consistency Model"*, ASPLOS'19
  (`papers/AFormalAnalysisoftheNVIDIAPTXMemoryConsistencyModel.pdf`). This is the
  **canonical axiomatic formalisation** of PTX. It is *explicitly a formalisation
  of the official NVIDIA PTX ISA memory-model chapter* (the paper states it
  formalises the English spec, ref. [40] = the PTX ISA doc). What was read and
  encoded:
  * **Fig 4** — the relations `pattern_rel`, `obs`, `pattern_acq`, `sw`,
    `cause_base`, `cause`.
  * **Fig 7** — the six top-level axioms: Coherence, FenceSC, Atomicity,
    No-Thin-Air, SC-per-Location, Causality.
  * **Fig 5 / §3.4.1** — release/acquire synchronisation forbids MP.
  * **Fig 6 / §3.4.3** — *"The Fence-SC order can prevent weak memory ordering
    behaviors that acquire/release alone cannot prevent, such as the well-known
    store buffering (SB) pattern"*, and *"PTX also requires the two fences to be
    morally strong."* This is the headline result.
  * **§3.3** — *"strong"* operation and *"morally strong"* (mutually
    scope-encompassing) operations.
  * **§3.4** — *"The PTX model is not multi-copy atomic."*

* **Official PTX ISA** (current 9.x; cross-checked on docs.nvidia.com). The
  memory-model chapter still carries the *same* model Lustig'19 formalised:
  "morally strong", release/acquire patterns, fence-SC order, and the axioms
  Coherence / Atomicity / No-Thin-Air / SC-per-Location / Causality. So the
  academic formalisation and the normative spec agree, and the model is current.

* **Successor check (does anything supersede Lustig'19?).** The only later
  *formalisation* is **"Mixed-Proxy Extensions for the NVIDIA PTX Memory
  Consistency Model"** (ISCA'22), which *adds* handling for multiple memory
  *proxies* (texture / surface / constant paths). Our corpus uses a single,
  generic global-memory proxy, so the mixed-proxy extension does not apply and
  the **base** scoped model is exactly the right authority. Citation chasing
  (Google Scholar, 2024–2026) shows Lustig'19 remains *the* cited formal PTX MCM
  (e.g. Cleaveland & Trippel 2024; the Dartagnan GPU model-checker; the
  Grace-Hopper study below) with no replacement.

* **[Bagchi26]** S. Bagchi et al.,
  *"Consistency and Coherence of the NVIDIA Grace-Hopper Superchip"*, ISMM'26
  (`papers/ConsistencyAndCoherenceOfTheNVIDIA.pdf`) — the **empirical** check on
  real Hopper silicon. Read and used to cross-validate:
  * **§3.2 (verbatim):** *"Synchronizing operations are considered morally strong
    if and only if the scope of each operation encompasses the scope of the
    thread performing the other operation involved in the synchronization."*
    → grounds the `enc & enc⁻¹` mutual-encompassment encoding.
  * **Fig 2e:** cta-scope release/acquire across different CTAs *"is not morally
    strong … the outcome … is permitted"* → grounds `MP-cta-F = Allowed`.
  * **Fig 2a / §4.1:** *"If the release or acquire labels are omitted … the
    necessary ordering constraints are absent, permitting the outcome"*, and
    *"Across all 560 litmus tests, whenever a morally strong release-acquire
    synchronization was established (both the release and acquire at gpu scope or
    higher), no weak behaviors were observed. Conversely, in all other
    scenarios — including insufficient scope and asymmetric cases where only one
    side had a release or acquire — weak behaviors were consistently observed."*
    → grounds every one-sided `acquire`/`release` column = Allowed, and the
    gpu+/sys paired-sync = Forbidden direction.
  * **§2.1 / §4:** *"GPUs like NVIDIA PTX permit non-MCA behaviors."* → grounds
    `IRIW-sys-F = Allowed`.
  * Caveat honestly recorded: Bagchi's *empirical* suite prioritises **MP**
    patterns, so the **SB-needs-fence.sc** and **IRIW non-MCA** verdicts here
    rest on the Lustig'19 *model* (Fig 6, §3.4), not on a Bagchi measurement.
    These are NO-HARDWARE-ORACLE predictions until the GH200 run (Task 9).

> One read-the-source note: a web summariser mislabelled SC-per-Location's
> formula `acyclic((morally_strong ∩ (rf∪co∪fr)) ∪ po_loc)` as "Causality".
> Lustig'19 Fig 7 (read directly) is authoritative: that formula is **Axiom 5
> (SC-per-Location)**; **Axiom 6 (Causality)** is `irreflexive((rf∪fr); cause)`.

---

## 2. How the model is encoded (Fig 4 + Fig 7 → cat)

* **Annotation sets** come from `ptx.bell` tags via `tag2events` (`'release`,
  `'acquire`, `'sc`, `'relaxed`; `'cta`, `'gpu`, `'sys`). The order lattice is
  `relaxed < {acquire,release} < acq_rel < sc`, so a corpus `f[sc,<scope>]`
  fence is **both** a release fence and an acquire fence.
* **Moral strength** (`ms`): `enc = ⋃ₛ [tagged-at-s] ; tag2scope(s)` is "my scope
  encompasses your thread"; `mutual = enc & enc⁻¹` is mutual encompassment.
  Memory–memory pairs additionally require same address (`loc`); fence pairs do
  not; program-order-related pairs are morally strong too. `tag2scope` reads the
  true `scopes:` tree the corpus carries (each proc in its own CTA), so cta-scope
  ops on different procs are **not** morally strong.
* **Fence-SC order** (`sc`): `with sc_tot from linearisations(FSC, 0)` lets herd7
  enumerate total orders of the `fence.sc` events; `sc = sc_tot & ms` keeps only
  the morally-strong pairs (empty at cta scope). This is the existential
  "acyclic order over morally-strong `fence.sc` ops" of Lustig'19 §3.4.3.
* **Axioms** are the six of Fig 7, transcribed directly. Coherence is written
  `empty ((([W];cause;[W]) & loc) \ co)` (co is per-location, so the cause-ordered
  write pairs are restricted to overlapping ones). `rmw`, `dep`, `sync_barrier`
  are empty in this corpus (no atomics, no dependencies, no `bar.sync`), so
  Atomicity / No-Thin-Air / barrier terms are vacuous — faithfully kept.

---

## 3. The verdict structure (and the AMD difference)

Because the grid sweeps one order at a time, **no grid test ever pairs a release
write with an acquire read** (only the 4 `-F` anchors do). Synchronisation (`sw`)
needs *both* halves, so:

| variant | verdict | why |
|---|---|---|
| `*-relaxed`, `*-acquire`, `*-release` (all scopes) | **Allowed** | one-sided / none ⇒ `sw` empty ⇒ no `cause` ⇒ weak permitted [Bagchi §4.1] |
| `*-cta-fence` | **Allowed** | fences in different CTAs ⇒ not morally strong ⇒ `sc` empty |
| `*-gpu-fence`, `*-sys-fence` | **Disallowed** | morally-strong `fence.sc` ⇒ `sc` order ⇒ FenceSC/Causality/Coherence cut the cycle |
| `MP-sys-F` (anchor) | **Disallowed** | sys release/acquire pair ⇒ `sw` ⇒ Causality |
| `MP-cta-F`, `SB-sys-F`, `IRIW-sys-F`, `LB-sys`, … (anchors) | **Allowed** | see CSV row provenance |

Totals: **114 Allowed, 23 Disallowed** (= 11 shapes × {gpu,sys}-fence + MP-sys-F).

**Where this parts company with the PLDI'23 AMD verdicts** — same `.litmus`
files, three rows differ, all because PTX rel/acq is pure scoped *ordering* (a
`synchronizes-with` that needs a real morally-strong `rf` to observe):

| test | `expected-amd-gcn3.csv` | NVIDIA-PTX | reason for the NVIDIA value |
|---|---|---|---|
| `LB-sys` | Disallowed | **Allowed** | No-Thin-Air is `acyclic(rf∪dep)`; no dep ⇒ not forbidden |
| `SB-sys-F` | Disallowed | **Allowed** | both readers read init ⇒ no `rf` to observe ⇒ `sw` never fires; SB needs `fence.sc` (Fig 6) |
| `IRIW-sys-F` | Disallowed | **Allowed** | PTX is non-MCA; rel/acq cannot force one write order |

These are different machines, and neither column carries to the other.
