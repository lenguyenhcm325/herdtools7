# HetLitmus — Heterogeneous Test-Run Environment: Design & Build Plan

**Status:** consolidated design, 2026-07-06. This is the synthesis of a nine-question deep-research
effort into how to *run* heterogeneous CPU–GPU litmus tests on real hardware (GH200, then MI300A) so that
the results are meaningful. It is the coding spec for the "Task 9 / Layer 4" run-wiring the emitter
currently stops short of.

**How to read this.** This document is the coherent architecture + the build order. It does **not** re-embed
every detail — each component points to its detailed findings file under `hetlitmus/../env-research/Q*.md`
(nine files, each with verbatim-quoted primary-source evidence + an assumption-transfer analysis + a
recommendation). The one-paragraph memory record is `memory/hetlitmus-env-design.md`.

**Provenance / corrections folded in** (see §7): the "~0.2 % relaxed-MP" figure is a *GPU-only* rate, not
het (verified against Bagchi pp.74–76); Q2's per-frame tally is lifted to the `(instance,run)` unit by Q3;
the cuda-litmus `MEM_STRESS` macro ships a bug; the cuda-litmus reuse is **supervisor-approved for thesis
(academic) use with citation required** (Anatole, 2026-07-06 — to be captured in writing; the upstream repo
carries **NO license**, so an explicit grant from Levine is needed before any public artifact, see §7); the
GPUHarbor + MC-Mutants secondhand claims were verified against the
local PDFs (`env-research/verify-gpuharbor-mcmutants.md`).

---

## 1. The problem

The emitter already produces a runnable heterogeneous harness (CPU pthread + GPU kernel over shared managed
memory, tallying against the `exists` condition). But it is a **placeholder driver**, and on coherent
silicon it would almost certainly observe **nothing**:

- single test instance, `<<<1,1>>>` (`CudaLang.layout_of_scopes`; `top_litmus.ml`);
- a hardcoded `const int iterations = 100000` (`top_litmus.ml:846`; `CudaLang.ml:405`; `HipLang.ml:362`),
  with `Cfg.size`/`Cfg.runs` in scope but unused;
- per-iteration `pthread_create`/`join` + kernel relaunch (launch jitter ≫ the ns-scale race window);
- one system-scope *start* barrier and nothing that widens or aligns the CPU-store/GPU-load race;
- **no stress**, **no cross-device alignment**, **no positive control**;
- shared vars allocated with `*MallocManaged`, which on GH200 page-migrates at 2 MB and *masks* the race.

Per the GPU-litmus literature — on **Nvidia** silicon, which is the GH200 target (Alglave'15 §4.3.1: *"we
did not observe sb and lb on Titan without this incantation"*, Table 6 showing them at **zero** in every
column without memory stress; S&D: 0/1000 → 102/1000 on a Tesla K20) — every "Never" from this harness is
meaningless. (On **AMD** the same paper found weak behaviours *without* stress — `lb` at 10959/100k with no
incantations — so for MI300A the layer amplifies rates rather than enabling observation; do not carry the
unqualified claim across vendors.) This document specifies the environment that makes a "Never" mean
something.

---

## 2. Architecture at a glance

```
                  ONE cooperative kernel launch  +  few persistent pinned CPU pthreads
                                   │  (sync-once, system-scope start barrier, in malloc memory)
        ┌──────────────────────────┴───────────────────────────┐
        │  PERPETUAL free-running loop (no relaunch, no per-trial cross-device barrier) │
        │                                                        │
   CPU test thread(s)  ⋈  GPU test lane(s)      +   GPU stress workgroups   +  CPU enemy threads
   (few: ≤ ~72 Grace cores)  over shared         (many: fill the grid,        (disjoint scratchpad)
   malloc() cache-line-coherent locations         co-residency-capped)         + REMOTE-PINNED pages
        │   stores tagged  value = K·n + μ                                        → C2C noise (interconnect stress)
        ▼
   per-load N-buffers  ──►  post-hoc recovery  (COUNT exact / COUNTH synchrony-point)
        │                        │  writes ──►  het_obs_record  {target, interleavings, control, skew, …}
        ▼                        ▼
   outs_t histogram        overdispersion-aware stopping + positive-control gate  ──►  MATCH / MISMATCH /
   (oracle-compare.sh)     (Q3)                         (Q4)                            NO-ORACLE + FN-bound
                                   ▲
                     autotuner tunes the stress mix to maximise the het-mutant DEATH RATE (Q7)
```

The design is overwhelmingly **reuse + adapt**, with original code confined to the genuine gap
(cross-device orchestration + the het-aware statistics/tuner). Lineage: PerpLE (perpetual instances),
cuda-litmus / S&D / Kirkham / MC-Mutants (stress + parallelism + reproducibility), litmus7 (CPU harness +
histogram + asm bodies), Fusco (C2C placement/noise), Goens/Lustig (the oracle).

---

## 3. Component design (each points to its findings file)

### 3.1 Build strategy — hybrid bespoke spine  [→ `Q9-build-strategy.md`]
Keep the bespoke `.cu`/`.hip` translation unit as the outer spine; **reuse litmus7's *parts*** (CPU
inline-asm bodies via `ASMLang.dump_fun`, the `_outs.c` histogram, CPU stress *recipes*, `-size`/`-nruns`
param plumbing, diy7 generation) **without making `Skel.ml` the driver**. `Skel.ml` is single-arch and
pthread-shaped, has no slot for a co-running kernel, and its per-cell CPU↔GPU barrier *masks the tested
order and hangs*. No prior work routes GPU/het through litmus7's CPU harness (Bagchi *stitches*).

### 3.2 Memory & allocation — per-target knob  [→ `Q8-allocation.md`]
**The allocator selects the property under test.** Emit a per-target allocator:
- **GH200 → system `malloc()`** for the shared vars *and the barrier* (cache-line CHI coherence via ATS —
  what Bagchi used). NOT `cudaMallocManaged` (2 MB migration serialises + masks the race).
- **MI300A → fine-grained** (`hipMallocManaged` default is already correct, or `malloc`+`HSA_XNACK=1`);
  never coarse-grained (invisible mid-kernel).
- **Dev box (RTX 3060/WSL2) → `cudaMallocManaged` as a compile/CI fallback only** — it has *no* hardware
  CPU-GPU coherence and concurrent access can segfault, so it validates codegen/plumbing, **never the CMCM
  property**.
- **Placement is a knob** (§3.6): first-touch / `cudaMemAdvise` remote-pinning is the interconnect-stress
  lever. `__out` may stay in ordinary host memory (off the race path).

### 3.3 Run-loop & alignment — perpetual-instance, buy alignment  [→ `Q1-alignment.md`]
Launch the GPU kernel **once** and the CPU pthreads **once**; loop *inside*; rendezvous with **one**
system-scope start barrier; then free-run. Guard GPU forward progress with **occupancy-bounded or
cooperative launch** (`cudaLaunchCooperativeKernel` + `grid.sync()`; HIP equivalents). Do **not** add a
per-trial cross-device barrier. There is no shared clock and no ordering-free side channel, so alignment is
**bought**: volume + both-side stress (window-widener) + phase drift, and recovered post-hoc (§3.4). Bagchi
never precisely aligned. *Optional Layer-5 research spike:* a calibrated `cntvct_el0`↔`%globaltimer`
cross-device timebase (both 1 GHz/32 ns, different epochs) — novel, do only after the basics work.

### 3.4 Instance structure & recovery — asymmetric + clock-independent  [→ `Q2-runloop.md`]
- **Asymmetric instances:** a *few* genuinely-het pairs (H ≤ reserved Grace cores, ~1–8; 1 pinned CPU
  pthread ⋈ 1 GPU lane, on cache-line-padded private `malloc` locations) + *many* GPU-only stress
  instances filling the co-residency-capped grid. **Het volume comes from the perpetual inner loop, not the
  instance count.** MC-Mutants' co-prime PTE is GPU-only → reuse it for the GPU stress instances, not the
  het pairs.
- **Recovery is clock-independent:** tag every store `value = K·n + μ_w` (`v mod K` decodes device/store,
  `v div K` decodes iteration). Record per-load N-sized `uint64` buffers off the race path. After the run,
  **COUNT** (exact; O(N) for MP-het) + **COUNTH** synchrony-point heuristic (for SB/IRIW) replace the
  per-iteration `_cond`/`add_outcome_outs` check. Because the iteration is decoded exactly, recovery
  **sidesteps the no-shared-clock problem entirely.**
- **Loop nesting:** `RUNS (=Cfg.runs) × [one launch; one start barrier; inner for n<N]`; the old `100000`
  becomes `N = Cfg.size` = the free-running window (drivable to millions).

### 3.5 GPU-side stress — reuse cuda-litmus  [→ `Q5-gpu-stress.md`]
Port cuda-litmus `do_stress` + `StressParams` (`functions.cu`, `params/stress_params.txt`) into the emitted
kernel — **supervisor-approved for thesis use, MUST cite** cuda-litmus/Levine + the papers (S&D, Kirkham,
Alglave'15, MC-Mutants); the upstream repo carries **no license**, so an explicit grant from Levine is
needed before any public artifact ships (§7). **Fix the shipped `MEM_STRESS` macro bug** (it passes the wrong arg → mem-stress is a no-op in
the committed config; don't inherit it). The scratchpad lives in **`cudaMalloc` device memory** (distinct
from the `malloc` shared het vars of §3.2). cuda-litmus ships only *one* committed tuned config (Hopper
device-scope) → it is a starting seed, not a preset library; re-tune (§3.9). **Assumption-transfer caveat:**
GPU scratchpad stress loads the *on-die* coherence protocol, **not** the C2C path the het weak behaviour
needs — so it must be paired with §3.6.

### 3.6 CPU-side + interconnect stress  [→ `Q6-cpu-interconnect-stress.md`]
- **CPU stress = litmus7 recipes** ported into the emitted CPU thread at two sites (preload before the
  tested body; disjoint-scratchpad enemy threads + affinity in the driver), for both host ISAs (AArch64
  primitives `dc civac`/`prfm`; x86 `clflush`/`prefetcht0`). Wire `iterations`→`Cfg.size`.
- **`-2s` invariants (enforced by construction):** enemy stress touches only a *disjoint* scratchpad (never
  X/Y/barrier); preload sits *outside* the opaque compiled tested-order unit (never between the tested
  STLR/LDAPR/DMB).
- **Interconnect stress (the genuine novelty):** remote-pin a shared page to the *consumer's* far memory
  (`cudaMemAdvise` + defeat access-counter migration) so every access crosses NVLink-C2C, and/or run **Fusco
  "noise kernels"** (each side stream-reads the other's memory → C2C bandwidth to 17 %/65 %). GPU-only /
  CPU-local stress *cannot* reach the C2C window (triangulated by Q5+Q6). Bagchi did per-device stress only,
  no link-directed component → this is a modest, honest addition. **"More effective" is an inference**
  (Fusco measured bandwidth, not weak-behaviour yield) → hardware-only. MI300A analogue = contention on the
  single HBM pool, not placement.

### 3.7 Non-observation statistics — `1−e⁻ⁿ` does NOT transfer  [→ `Q3-stats.md`]
Kirkham's `1−e⁻ⁿ` reproducibility model is a Bernoulli→Poisson approximation whose three assumptions all
break in the het setting:
- **trial unit** — the recovery counts per *frame* (`N^{T_L}` overlapping frames) → raw counts aren't
  independent Bernoulli. **Fix: compute all confidence stats at the `(instance,run)` unit** via
  `Y = 1[target_count ≥ 1]`, never from raw frame counts. (This *refines* §3.4's tally.)
- **stationarity** — occupancy warm-up + alignment/skew drift; Kirkham's own KS precheck fails 4/18 even
  GPU-only → **KS stationarity precheck is mandatory, in-loop.**
- **independence** — skew drift → autocorrelated/bursty/overdispersed; shared fabric → cross-instance
  correlation → `1−e⁻ⁿ`/rule-of-three are **optimistic**.

**Replacement:** an overdispersion-aware rule-of-three — replace the constant `3` with
`μ_upper(r) = r(0.05^(−1/r) − 1)` (3 → 19 → ~200 as dispersion rises; a bare `3/N` under Fano ≈ 20 is ~6×
optimistic), using a variance-aware (empirical-Bernstein) bound. **Gate every "Never"** on: KS-stationary +
positive-control LIVE (§3.8) + `interleavings_detected > 0` + clean negative control, else the run is
**COLD → discard the null**. `oracle-compare.sh` is **augmented, not replaced**.

**Shipped statistics (B7/B7b/B7c/DR1 — `het_verdict.h` is the normative source; this doc does not duplicate
the formulas).** The bound is scored per `(instance,run)` over `HET_NWIN` windowed sub-tallies. B7b credits
the intra-run dividend `N_eff = HET_NWIN / τ_w` (τ_w = Geyer initial-positive-sequence autocorrelation time,
clamped to `[1, HET_NWIN]`), so `R_eff = R_usable · N_eff / DEFF`; the **run-level** bound
`N_eff · p_bound = μ_upper · DEFF / R_usable` is invariant to `N_eff` by construction — the discount adds
resolution beneath B7's number, never weakens it. B7c refuses to *spend* a τ the pooled stream is too short
to resolve (`nwin < HET_TAU_MIN_SAMPLES · τ_w` → `TAU_UNRESOLVED`, `N_eff = 1`, i.e. B7 exactly); its
count-valued-stream over-credit residual is a **known-open** item (deep-review F8). `HET_P_MIN` stays
**UNSET** — `het_budget_runs` returns *NOT SIZED* rather than a fabricated rate — until GH200 measures it.
The interleaving-liveness gate is **channel-aware** (DR1): reader shapes use `interleavings_detected`, the
store-only (2+2W) shapes — which have no reader — use `observer_unique_count ≥ θ` instead, and a record with
neither channel fails closed. And the verdict is **oracle-aware**: a sighting REFUTES only on an
`ORACLE_DISALLOWED` test (16 of 338), CONFIRMS on the 286 Allowed, CHARACTERIZES the 36 NO-ORACLE.

### 3.8 Positive control / liveness  [→ `Q4-positive-control.md`]
A "Never" is only credible if the harness was demonstrably "hot". **The corpus scope×order grid is already
a mutation lattice**, so the control is essentially free:
- **Layer A (rigorous):** co-run each Disallowed `-2s` test's *nearest Allowed grid-neighbour* (one
  ordering-primitive away = an existing single-edge mutant; same shape/scope/direction/C2C structure). This
  is MC-Mutants' **"Weakening sw"** (fence-removal) mutator; the **scope axis is a HetLitmus extension**
  MC-Mutants lacks.
- **Layer B (floor):** always co-run an `MP-{cg,gc}-sys-relaxed` het canary (MP is the only het shape with a
  Bagchi-demonstrated weak result).
- **Wiring:** same launch / same stress / disjoint padded locations; feed `control_target_count`. **Null
  credible only if** `control_target_count ≥ τ_hot` (≥3, prefer 30) **and** `interleavings_detected > 0`
  that run.
- **Double duty:** the control is also the **calibrator** that measures the Fano factor / overdispersion for
  §3.7's bound.
- **Honesty caveat:** mutation-score-as-oracle rests on a bug↔mutant correlation shown on only **3 cases**
  (PCC .893–.996) → cite as *supporting*, not a guarantee. NO-ORACLE rows get Layer-B liveness only
  (characterization, not validation).

### 3.9 Tuning methodology & oracle  [→ `Q7-tuning.md`]
- **Oracle:** the forbidden violation is 0 on correct hardware (no gradient) → tune to maximise the
  **het-mutant DEATH RATE** `Δcontrol_target_count/Δt` on §3.8's controls (MC-Mutants metric; ceiling-rate
  `⌈−ln(1−r)⌉/b`, Alg.1 selection). For the **interconnect** knobs the oracle *must* be a het/cross-C2C
  observable — a GPU-only rate mis-tunes the C2C lever to zero.
- **Method:** factor the combined Q5∪Q6 knob space into three near-separable sub-searches
  (GPU → CPU → interconnect last), seeded/warm-started random search (GPUHarbor's Park-Miller reproducible
  sampler), shape-priority (Kirkham: LB/S first, SB/IRIW last).
- **Overdispersion transfer (Q3 core):** Kirkham data-peeking's Bernoulli CI is too narrow → swap for an
  **empirical-Bernstein** variance-aware early-stop at the `(instance,run)` unit; **randomized round-robin
  (SER³)** config scheduling to avoid drift aliasing; KS gate in-loop. The early-stop spends a **fixed
  per-comparison** δ (Mnih'08 §2's per-round radius), **not** the anytime (Mnih'08 §3.1, EBStop) or
  family-wise racing (Mnih'08 §4) guarantee — implementing the §3.1 δ-spending schedule empirically broke
  elimination (tunecheck 4/7). The tuner's pick is therefore a *heuristic* validated by §3.7's campaign
  statistics, not by the racing rule's confidence; this residual is a **known-open** item (deep-review F9).
- **Portability:** ship *structure + seed*; **re-tune every numeric on the actual hardware** (x86 → GH200 →
  MI300A can't share — the interconnect lever itself differs). No post-2023 memory-testing autotuner handles
  het/overdispersion → this tuner is at the frontier.

---

## 4. The `het_obs_record` — the interface that ties it together

Per `(instance, run)` (the statistical unit from §3.7):

```
het_obs_record {
  N                      // free-running window length (= Cfg.size)
  frames_examined
  target_count           // exhaustive COUNT + heuristic COUNTH: "did we see the weak behaviour"
  interleavings_detected // "could we have" — CPU/GPU iterations that provably overlapped
  distinct_decoded_iters // decoder soundness / coverage
  skew_min/max/mean/stddev  // alignment drift diagnostic (feeds stationarity + overdispersion)
  control_target_count   // the positive-control (§3.8) death signal → "harness was hot"
}
```

This cleanly separates **did we see it** (`target_count`) from **could we have** (`interleavings_detected` +
`control_target_count` + skew). It is the input to §3.7's stopping rule, §3.8's null gate, and §3.9's tuning
oracle. The `outs_t` histogram is retained (fed once per validated frame) so `oracle-compare.sh` keeps
working.

*(The block above is the illustrative core; the **shipped** `het_obs_record` — normative in `het_verdict.h`
— carries ~40 fields: the `sync_valid`/`obs_valid` channel flags plus `observer_unique_count` for the
store-only channel (DR1), the realised `nwin`, the windowed `control_*`/`canary_*` sub-tallies, the
`het_oracle` class, and the per-mechanism stress-liveness counters the §3.7 disqualifiers read.)*

---

## 5. Build order (implementation roadmap)

Dependencies flow top-down. **B0–B7 are dev-box compile/CI-testable; the science + tuning need
GH200/MI300A** (§6). A prerequisite audit (P) should run early.

| # | Task | Depends on | Notes |
|---|------|-----------|-------|
| **P** | Corpus audit: classify which of the 281 het tests carry **un-convertible `[x]=N`** final-value conditions (they don't fit the recovery scheme). | — | Q2; informs B3/B6. |
| **B0** | Parameterise `100000` → `Cfg.size` (free-running window) + `Cfg.runs` outer loop; surface as `SIZE_OF_TEST`/`NUMBER_OF_RUN` + argv. | — | Cheap; both already in scope. **Do as part of B2**, not standalone (semantics change to a window). |
| **B1** | Per-target **allocator knob**: `malloc`/GH200, fine-grained/MI300A, managed = CI fallback; `cudaMemAdvise` placement hooks. | — | Q8; replaces `gd_malloc_managed`. |
| **B2** | **Perpetual-instance rewrite** of the run-loop: launch once, loop inside, sync-once start barrier, occupancy-bounded/cooperative launch; drop per-iteration relaunch + `cudaDeviceSynchronize`. | B0,B1 | Q1/Q9; the biggest single change. |
| **B3** | **`K·n+μ` store-tagging** (touches `ASMLang` for CPU store operands) + per-load N-buffers + **COUNT/COUNTH recovery** + emit the `het_obs_record` tally. | B2,P | Q2; replaces the per-iteration `_cond` check. |
| **B4** | **GPU stress**: port cuda-litmus `do_stress`/`StressParams` (fix `MEM_STRESS` bug; cite); scratchpad in `cudaMalloc`; widen launch to stress workgroups; **asymmetric instances**. | B2 | Q5/Q2. |
| **B5** | **CPU stress** recipes (2 sites, both ISAs) + **interconnect stress** (remote-pin + noise kernels); enforce the `-2s` invariants. | B2,B4 | Q6. |
| **B6** | **Positive control** wiring: co-run adjacent-Allowed neighbour + MP canary; null-credibility gate on `control_target_count` + `interleavings_detected`. | B3,B4 | Q4. |
| **B7** | **Overdispersion-aware stopping/stats**: `(instance,run)` unit, empirical-Bernstein bound, KS precheck; augment `oracle-compare.sh` with the confidence/FN annotation. | B3,B6 | Q3. |
| **B8** | **Autotuner**: factored seeded random search, empirical-Bernstein early-stop, round-robin scheduling, KS gate; oracle = het-mutant death rate. | B4,B5,B6,B7 | Q7; runs **on hardware**. |

---

## 6. Hardware-only — what must wait for GH200 / MI300A

Everything below is unmeasurable on the dev box (wrong substrate, §3.2). **First bring-up measurement:**

1. **The Fano factor `F̂`** of het weak-behaviour counts — sets the CI width, the run budget, and the
   false-negative bound (§3.7/§3.9). *Measure this first.*
2. The **het weak-behaviour hit-rate** — genuinely unknown (the 0.2 % was GPU-only). This is `HET_P_MIN`,
   which sizes `het_budget_runs` (§3.7); it stays UNSET (budget = *NOT SIZED*) until measured here.
3. Whether the **perpetual rendezvous sustains** on GH200 without the Srivastava-style 2–3-iteration stall.
4. Whether **interconnect stress raises yield** vs per-device (currently an inference from bandwidth).
5. The **`cntvct_el0`↔`%globaltimer` drift-stability** (Layer-5 timebase spike).
6. **All MI300A specifics** — coherent rendezvous, XNACK, `s_memtime`↔`rdtsc`, per-shape observability.
7. Site-specific attributes: `concurrentManagedAccess`, `pageableMemoryAccess`, access-counter-migration
   disable mechanism.
8. Per-target **stress tuning** (all numeric knob values).

**Two Disallowed tests need calibration before their nulls count** (deep-review F5): `SB-{cg,gc}-sys-fence-2s`
are the only `T_L ≥ 2` shapes among the 16 Disallowed, so at production `N` the exhaustive `O(N^T_L)` scan is
capped (`HET_EXHAUSTIVE_MAX = 4096`) → `exhaustive_valid = 0`, and they can **never reach CREDIBLE-NULL**;
their only detector is the uncalibrated `[c−8, c+8]` window (`HET_WINDOW = 8`), so a real cross-device skew
> 8 iterations would MISS the sighting and read as a null. At bring-up: measure `skew_*` first, run a
small-`N` pass (`-s ≤ 4096`) so `exhaustive_valid = 1`, and calibrate `HET_WINDOW` from the measured skew
before trusting any null on these two. (The other 14 Disallowed are `T_L ≤ 1`, exact-`O(N)`, skew-independent.)

---

## 7. Cross-cutting corrections folded in

- **The "~0.2 %" is GPU-only, not het** — verified against Bagchi pp.74–76 (§5.1 quotes §4.1's GPU inter-CTA
  result). Bagchi gives no numeric het rate → the het hit-rate is hardware-only. (Q1's file carried the
  mis-attribution; corrected in memory + here.)
- **Q2's per-frame tally → `(instance,run)` unit** (Q3): raw frame counts are combinatorially inflated and
  break the statistics; the record is consumed at the instance-run level.
- **cuda-litmus `MEM_STRESS` bug** — fix on port, don't inherit.
- **Licence** — cuda-litmus reuse is **supervisor-approved for thesis (academic) use** (Anatole, 2026-07-06
  — a supervision decision, *to be captured in writing*; not itself a copyright grant). The upstream repo
  (`reeselevine/cuda-litmus`) carries **NO license file** (exhaustively checked), so Levine remains the sole
  rights-holder: **citation is required**, and an **explicit grant from Levine is needed before any public
  artifact ships**. A courtesy ack is prudent regardless.
- **GPUHarbor + MC-Mutants** secondhand claims verified against local PDFs
  (`env-research/verify-gpuharbor-mcmutants.md`); GPUHarbor adds a correlation validation but **no new
  reproducibility model** (don't overstate as "zero statistics").

---

## 8. Novelty summary (for the thesis)

The environment is mostly reuse; the defensible new contributions are:
1. **A native, open, `herdtools7`-integrated** heterogeneous run pipeline (vs Bagchi's unreleased stitch).
2. **Overdispersion-aware non-observation statistics** — the first het-adapted replacement for `1−e⁻ⁿ`
   (unit-lift + empirical-Bernstein + stationarity gate), strictly more rigorous than Kirkham (stationarity
   only) or Iorga (no model).
3. **A het-aware autotuner** — no prior memory-testing tuner handles the het/overdispersed regime.
4. **Explicit interconnect stress** (placement + noise kernels) — a lever no single-die prior work had.
5. The **scope axis as a mutation-lattice extension** beyond MC-Mutants' po/sw mutators.

State all of these as *methodological/infrastructural* contributions — **not** a first-discovery claim on
GH200/CMCM (Bagchi has that).

---

## 9. Pointers

- **Findings (detailed specs + evidence):** `env-research/Q1-alignment.md`, `Q2-runloop.md`, `Q3-stats.md`,
  `Q4-positive-control.md`, `Q5-gpu-stress.md`, `Q6-cpu-interconnect-stress.md`, `Q8-allocation.md`,
  `Q9-build-strategy.md`, `Q7-tuning.md`; verification `env-research/verify-gpuharbor-mcmutants.md`.
- **Memory:** `memory/hetlitmus-env-design.md` (one-paragraph record), `hetlitmus-nonobservation-alignment.md`,
  `hetlitmus-task6-stress-reuse.md`, `het-verify-imported-assumptions.md`.
- **Primary sources:** the 19 survey notes in `survey-notes/` (each read cover-to-cover) + the local PDFs in
  `papers*/`.
