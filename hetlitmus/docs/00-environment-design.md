# HetLitmus — Heterogeneous Test-Run Environment: Design & Build Plan

**Status:** consolidated design, 2026-07-06. This is the synthesis of a nine-question deep-research
effort into how to *run* heterogeneous CPU–GPU litmus tests on real hardware (GH200, then MI300A) so that
the results are meaningful. It is the coding spec for the "Layer 4" run-wiring the emitter
currently stops short of.

**How to read this.** This document is the coherent architecture + the build order. It does **not**
re-embed every detail: each section states one design decision and names the code that carries it, and
the sibling docs in this directory carry the mechanisms in full. §9 names the artefact that wins where
a document and the shipped header disagree.

**Provenance / corrections folded in** (see §7): the "~0.2 % relaxed-MP" figure is a *GPU-only* rate, not
het ([Bagchi26 §5.1]); the per-frame tally is lifted to the `(instance,run)` unit;
the cuda-litmus `MEM_STRESS` macro ships a bug; the cuda-litmus reuse is **supervisor-approved for thesis
(academic) use with citation required** (Anatole, 2026-07-06 — to be captured in writing; the upstream repo
carries **NO license**, so an explicit grant from Levine is needed before any public artifact, see §7); the
reproducibility statistics GPUHarbor runs on are MC-Mutants' ([GPUHarbor23 §6], [MCMutants23 §4.2]), and
GPUHarbor's own addition is a correlation validation and not a second statistics layer.

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

Per the GPU-litmus literature — on **Nvidia** silicon, which is the GH200 target ([Alglave15 §4.3.1]: *"we
did not observe sb and lb on Titan without this incantation"*, Table 6 showing them at **zero** in every
column without memory stress; and [Sorensen16 §1], where the weak-memory error in the `cbe-dot`
*application* — a spinlock-guarded CUDA dot product, not a litmus test — appears in **0 of 1000** executions
on a Tesla K20 unstressed and **102 of 1000** under their tuned stressing environment) — every "Never" from
this harness is meaningless. (On **AMD** the same [Alglave15] table records weak behaviours *without*
stress — `lb` at 10959/100k on the Radeon HD 7970 with no incantations at all — so for MI300A the layer
amplifies rates rather than enabling observation; do not carry the unqualified claim across vendors.) This
document specifies the environment that makes a "Never" mean something.

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
   outs_t histogram        positive-control gate + liveness disqualifiers  ──►  OBSERVED /
   (fed per valid frame)   (het_verdict.h)                                      NOT-OBSERVED / COLD-INVALID
                           stationarity gate       ──►  P_rep + sighting tier, on the OBSERVED side only
                                   ▲
                     autotuner tunes the stress mix to maximise the het-mutant DEATH RATE
```

**The pipeline ends at the observation.** The harness carries no prediction and prints none;
comparing a row against a verdicts file the reader supplies is an **offline post-run step**
(`hetlitmus/oracle-compare.sh`, `oracle-harness.md`), outside the loop above.

The design is overwhelmingly **reuse + adapt**, with original code confined to the genuine gap
(cross-device orchestration + the het-aware statistics/tuner). Lineage: PerpLE [Melissaris20] (perpetual
instances), cuda-litmus / S&D / Kirkham / MC-Mutants (stress + parallelism + reproducibility), litmus7 (CPU
harness + histogram + asm bodies), Fusco (C2C placement/noise), Goens/Lustig (the memory models an offline
comparison would be made against).

---

## 3. Component design

### 3.1 Build strategy — hybrid bespoke spine
Keep the bespoke `.cu`/`.hip` translation unit as the outer spine; **reuse litmus7's *parts*** (CPU
inline-asm bodies via `ASMLang.dump_fun`, the `_outs.c` histogram, CPU stress *recipes*, `-size`/`-nruns`
param plumbing, diy7 generation) **without making `Skel.ml` the driver**. `Skel.ml` is single-arch and
pthread-shaped, and has no slot for a co-running kernel. Its per-cell CPU↔GPU barrier is refused on two
grounds of different provenance: it *hangs* — on integrated CPU↔GPU parts a per-iteration, both-sided
CPU↔GPU spin barrier has been seen to get no further than 2–3 iterations before sticking for good
[Srivastava24 §4.1] — and it *masks the tested order*, which no source states and which is this project's
own reasoning, that a barrier between the tested accesses adds ordering the test does not have. No prior
work routes GPU/het through litmus7's CPU harness (Bagchi *stitches*).
*[The `ASMLang.dump_fun` item is superseded — see §7; the rest of the reuse list stands.]*

### 3.2 Memory & allocation — per-target knob
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

### 3.3 Run-loop & alignment — perpetual-instance, buy alignment
Launch the GPU kernel **once** and the CPU pthreads **once**; loop *inside*; rendezvous with **one**
system-scope start barrier; then free-run. Guard GPU forward progress with **occupancy-bounded or
cooperative launch** (`cudaLaunchCooperativeKernel` + `grid.sync()`; HIP equivalents). Do **not** add a
per-trial cross-device barrier. There is no shared clock and no ordering-free side channel, so alignment is
**bought**: volume + both-side stress (window-widener) + phase drift, and recovered post-hoc (§3.4). Bagchi
never precisely aligned. *Optional research spike:* a calibrated `cntvct_el0`↔`%globaltimer`
cross-device timebase (both 1 GHz/32 ns, different epochs) — novel, do only after the basics work.

### 3.4 Instance structure & recovery — asymmetric + clock-independent
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

### 3.5 GPU-side stress — reuse cuda-litmus
Port cuda-litmus `do_stress` + `StressParams` (`functions.cu`, `params/stress_params.txt`) into the emitted
kernel — **supervisor-approved for thesis use, MUST cite** cuda-litmus/Levine + the papers (S&D, Kirkham,
Alglave'15, MC-Mutants); the upstream repo carries **no license**, so an explicit grant from Levine is
needed before any public artifact ships (§7). **Fix the shipped `MEM_STRESS` macro bug** (it passes the wrong arg → mem-stress is a no-op in
the committed config; don't inherit it). The scratchpad lives in **`cudaMalloc` device memory** (distinct
from the `malloc` shared het vars of §3.2). cuda-litmus ships only *one* committed tuned config (Hopper
device-scope) → it is a starting seed, not a preset library; re-tune (§3.9). **Assumption-transfer caveat:**
GPU scratchpad stress loads the *on-die* coherence protocol, **not** the C2C path the het weak behaviour
needs — so it must be paired with §3.6.

### 3.6 CPU-side + interconnect stress
- **CPU stress = litmus7 recipes** ported into the emitted CPU thread at two sites (preload before the
  tested body; disjoint-scratchpad enemy threads + affinity in the driver), for both host ISAs (AArch64
  primitives `dc civac`/`prfm`; x86 `clflush`/`prefetcht0`). Wire `iterations`→`Cfg.size`.
- **`-2s` invariants (enforced by construction):** enemy stress touches only a *disjoint* scratchpad (never
  X/Y/barrier); preload sits *outside* the opaque compiled tested-order unit (never between the tested
  STLR/LDAPR/DMB).
- **Interconnect stress (the genuine novelty):** remote-pin a shared page to the *consumer's* far memory
  (`cudaMemAdvise` + defeat access-counter migration) so every access crosses NVLink-C2C, and/or run **Fusco
  "noise kernels"** (each side stream-reads the other's memory → C2C bandwidth to 17 %/65 %). GPU-only /
  CPU-local stress *cannot* reach the C2C window. Bagchi did per-device stress only,
  no link-directed component → this is a modest, honest addition. **"More effective" is an inference**
  (Fusco measured bandwidth, not weak-behaviour yield) → hardware-only. MI300A analogue = contention on the
  single HBM pool, not placement.
- **What Bagchi actually did, verbatim** [Bagchi26 §4.2]: *"Each was executed millions of times with memory
  stressing [21] on both devices."* Per-device stress on both devices; no page placement, no
  `cudaMemAdvise`, no link-directed noise anywhere in the paper — where §4.3 says "placement" it means
  thread placement.
- **The inference is also *confounded*, and the claim is bounded accordingly.** Placement and noise slow
  the whole loop, so there are fewer rendezvous per second, and `sightings = yield × rate`. What the
  interconnect lever supports is that it is **additive** with per-device stress and is the lever most
  **specific** to the cross-device window — never that it beats per-device stress. Do not upgrade that
  without hardware evidence. The same bound is restated at the head of `het_cpu_stress.h`, which is the
  copy that travels to a GPU box.

### 3.7 What a non-observation reports — no rate, no probability
**A null carries no rate and no probability.** The harness reports that the outcome was **not observed** in
the usable `(instance,run)` cells it scored, names the control that vouched for them, says that this is
characterization and that the null agrees with no model and refutes none, and discloses the effort spent —
and stops there. Falsification is one-sided:

> "we emphasise that for correct GPU programming the possibility, not probability of weak behaviours is
> what matters." — [Alglave15 §4.3], p. 585.

So what licenses a null is not an interval. It is the two-layer positive control that fired **beside** it,
in the same launch, under the same stress, on the same C2C path (§3.8); `het_verdict()`'s liveness
disqualifiers, which discard a run whose stress, window-opener or decode channel was dead rather than
reporting its empty histogram; and the reported effort, ending on **grow R, not N**. The stop rule holds
the other side to a matching bar: a *sighting* is not written up until it reproduces (below).
`het_verdict.h` is the normative source and this doc does not duplicate its printouts.

**The frame is not the trial, and that correction is load-bearing.** The recovery scan validates `N^{T_L}`
*overlapping* frames per `N` iterations [Melissaris20 §IV.A], so raw frame counts are neither independent
nor Bernoulli, and [Kirkham20 §1.1]'s `1−e⁻ⁿ` evaluated on one is driven to 1 vacuously. Every statistic is
therefore scored at the **`(instance,run)` cell** via `Y = 1[target_count ≥ 1]` (this *refines* §3.4's
per-frame tally), and the one reproducibility number the layer reports — `P_rep = 1 − e^{−k_eff}` over the
cells that passed the decode guard — sits on the **OBSERVED** side, where the harness has something it
actually measured.

**Stationarity is tested, never assumed — the gate is mandatory.** Occupancy warm-up, thermal/DVFS drift
and alignment drift all act along the run, and [Kirkham20 §4.3 Tab.7]'s own precheck already fails 4 of
18 chip/test combinations GPU-only. Each run's control sightings are sub-tallied into `HET_NWIN` windows
(`control_win[]` or `canary_win[]`, whichever channel calibrated — the same selection §3.8 records as
`ctrl=` — whose sum against the total is the one runtime check that the tallies are alive at all,
`WIN_DESYNC`), and the early windows of every usable run are two-sample-KS'd against the late ones
(`het_ks2`, `HET_KS_C05 = 1.358`), on the same 20 %/10 % early-late split [Kirkham20 §4.3] uses. One
divergence: what is compared there is the *inter-arrival* distribution, with the rate read off a Poisson
fit; this layer compares the per-window sighting counts and fits nothing, the Poisson being the wrong
likelihood on a channel whose arrivals come in bursts. The gate **fails closed** — a control stream that
is empty or desynchronised is `KS_UNDERPOWERED`, never a free pass — a rejection is `NONSTATIONARY` and
suppresses `P_rep`, and `het_changepoint` locates where to split the run [Kirkham20 §5.1]. The same
reading is what §3.9's tuner drops a bout on.

**Where the hardware hours go.** One stop rule for every row, because no row carries a prediction to
schedule against: a sighting stops it once it reproduces in `HET_CORROB_RUNS = 2` distinct clean runs; a
*lone* clean sighting holds the row open for `HET_CONFIRM_RUNS` runs **measured from the run it fired in**
— outranking the budget stop, since ending there would bank "seen once, stopped looking" — and then stops
`UNCONFIRMED-SIGHTING`, which is neither a null nor a corroboration; a row that never fires stops when its
budget is spent. `HET_RATE=1` turns the sighting stop off, so a row that fires yields a rate instead of a
first sighting. `hetlitmus/campaign.py` applies the same rule across invocations, each with a fresh seed
base — replaying a seed adds no new phase draw and is not a replicate.

**The scheduler has no parallelism axis, deliberately.** Running `H > 1` het pairs at once is real emitter
work, and the pairs would share the one interconnect under test, so the gain is not the pair count. The
policy levers stay `--budget-runs`, `--confirm-runs` and `--rate`.

**Shipped (`het_verdict.h` is normative).** The interleaving-liveness gate is **channel-aware**:
reader shapes use `interleavings_detected`, the store-only (2+2W) shapes — which have no reader — use
`observer_unique_count ≥ θ` instead, and a record with neither channel fails closed. And the outcome
carries **no prediction**: one axis, four values — `HET_OBSERVED`, `HET_NOT_OBSERVED_MU_HOT`,
`HET_NOT_OBSERVED_CANARY_ONLY`, `HET_COLD_INVALID` — where the only question a null answers is what vouched
for the harness that did not see it, and which tier a null is reported at is read off **its own cells**
(`n_mu_hot`), never off the pooled control channel. What each row co-runs moves with the corpus, so read it
from `hetlitmus/tests/het/control-map.csv` (today: **375 of 471 rows carry a `mu(T)`**, the other **96 are
at the lattice floor**, and **469 co-run a canary**; the census is pinned in `verify/verdictcheck.py:CENSUS`
and gated by `make hetlitmus-verdict`, and the map's own partition by `make hetlitmus-controlmap`).

**The positive control is the primary evidence, and the statistics are not.** The dispersion-aware 95 %
upper bound on the rate of a never-observed outcome is **withdrawn**, and with it every scheduler arm,
tuner knob and roll-up column that existed to compute or justify it, and the optional per-config
rule-of-three garnish as well: nothing here prices the probability of what the harness missed.

### 3.8 Positive control / liveness
A "Never" is only credible if the harness was demonstrably "hot". **The corpus scope×order grid is already
an ordering-strength lattice**, so the control is essentially free:
- **Layer A (shape-matched):** co-run every test's own **structural twin at the lattice floor** — the same
  program with every ordering annotation dropped on both sides, so same shape/scope/direction/C2C structure
  and the weakest member of the family the corpus holds. This is MC-Mutants' **"Weakening sw"**
  (fence-removal) mutator taken to the floor rather than one edge; the **scope axis is a HetLitmus
  extension** MC-Mutants lacks. The 96 rows that *are* the floor have no Layer A by construction.
- **Layer B (floor):** always co-run an `MP-{cg,gc}-sys-relaxed` het canary, cut the same way round as the
  test it vouches for (MP is the only het shape with a published detected-weak result on GH200,
  [Bagchi26 Table 4] listing MP variants and nothing else).
- **Wiring:** same launch / same stress / disjoint padded locations; feed `control_target_count`. A null is
  `NOT-OBSERVED-MU-HOT` only if `control_target_count ≥ τ_hot` (≥3, prefer 30) **and** the run's decode
  channel was live **and** the ground-truth scan ran; otherwise it is `NOT-OBSERVED-CANARY-ONLY`, and with
  nothing hot at all it is `COLD-INVALID`.
- **Double duty:** the control's per-window sub-tallies are also the **only stream §3.7's stationarity gate
  can test** — the target is far too rare to say anything about a rate from, and the control is a
  strictly weaker shape, so it fires at least as often, on the same fabric in the same run under the
  same stress. How often that is has not been measured (§6 item 1). `mu(T)` calibrates wherever one is
  compiled in and fired, the canary otherwise, and the record says which (`ctrl=`,
  `HET_ST_CTRL_IS_CANARY`). That is the whole of the second duty; nothing is priced off it.
- **Honesty caveat:** mutation-score-as-a-proxy rests on a bug↔mutant correlation shown on only **3 cases**
  (PCC .893–.996) → cite as *supporting*, not a guarantee. The control's count is **reported**, never
  compared against a prediction.

### 3.9 Tuning methodology & objective
- **Tuning objective:** the tests worth tuning for are exactly the ones whose count stays 0, so the target
  itself supplies no gradient → tune to maximise the **het-mutant DEATH RATE**
  `Δcontrol_target_count/Δt` on §3.8's controls (the metric of [MCMutants23 §4.2], whose Alg.1 picks a
  per-test environment against a ceiling rate `⌈−ln(1−r)⌉/b`). For the **interconnect** knobs the
  objective *must* be a het/cross-C2C observable — a GPU-only rate mis-tunes the C2C lever to zero.
- **Method:** factor the combined stress knob space into three near-separable sub-searches
  (GPU → CPU → interconnect last), seeded/warm-started random search (the seedable Park-Miller sampler of
  [GPUHarbor23 §3.4], which is what makes one stress configuration replayable across devices),
  shape-priority: LB/S first, SB/IRIW last on the two discrete GPUs of [Kirkham20 §4.1], neither of which
  shows IRIW at all [Kirkham20 §6.4 Tab.11] — an order that **inverts** on that paper's integrated part,
  so re-measure it per part.
- **The racing rule — the tuner's, and nothing else's (`tune.py`):** the data-peeking CI of
  [Kirkham20 §5.1 Fig.10] is a normal approximation to a binomial, too narrow on a bursty channel → swap
  for an **empirical-Bernstein** variance-aware early-stop at the `(instance,run)` unit, whose radius
  absorbs the between-bout spread with no pre-estimated dispersion figure; **randomized round-robin
  (SER³)** config scheduling to avoid drift aliasing; §3.7's KS reading drops a non-stationary bout
  in-loop. The early-stop spends a **fixed per-comparison** δ (Mnih'08 §2's
  per-round radius), **not** the anytime (Mnih'08 §3.1, EBStop) or family-wise racing (Mnih'08 §4)
  guarantee — implementing the §3.1 δ-spending schedule empirically broke elimination (tunecheck 4/7). The
  tuner's pick is therefore a *heuristic*: what its config is worth is established by the campaign the
  tuned harness then runs, not by this rule's confidence, and it feeds no reported outcome. This residual
  is a **known-open** item.
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
  skew_min/max/mean/stddev  // alignment drift diagnostic; skew_stddev is the synchrony
                            // channel's decode guard (a decode that never varied)
  control_target_count   // the positive-control (§3.8) death signal → "harness was hot"
}
```

This cleanly separates **did we see it** (`target_count`) from **could we have** (`interleavings_detected` +
`control_target_count` + skew). It is the input to §3.7's stopping rule, §3.8's null gate, and §3.9's tuning
objective. The `outs_t` histogram is retained (fed once per validated frame) so an offline
`oracle-compare.sh` pass over the log keeps working.

*(The block above is the illustrative core; the **shipped** `het_obs_record` — normative in `het_verdict.h`
— carries ~40 fields: `rec_magic` (an unstamped record is refused before any other field is read), the
`sync_valid`/`obs_valid` channel flags plus `observer_unique_count` for the store-only channel, the
realised `nwin`, the windowed `control_*`/`canary_*` sub-tallies, and the per-mechanism stress-liveness
counters the §3.7 disqualifiers read.)*

---

## 5. Build order (implementation roadmap)

Every component below is shipped. Dependencies flow top-down: the corpus audit and the
allocator knob have no prerequisites, everything from store-tagging onwards needs the
perpetual-instance loop, and the autotuner needs both stress layers, the positive control and
the statistics. Two of them *read* the audit rather than merely following it (`litmus/hetCond.ml`
computes its shape rule): store-tagging + recovery emits an observer channel exactly on the shapes
it marks, and the positive control's co-run sums the block and lane counts those observers add.
Everything is dev-box compile/CI-testable except the **science + tuning, which need
GH200/MI300A** (§6).

| component | what it carries |
|---|---|
| **Corpus audit** | Which het tests carry **un-convertible `[x]=N`** final-value conditions (they don't fit the recovery scheme). Audited at 281 tests; the rule is per *shape*, so it still holds on the 471-test corpus — 159 tests (2+2W, R, S, CoWR, CoRW2) carry an observer channel. |
| **Free-running window** | `100000` → `Cfg.size` + a `Cfg.runs` outer loop, surfaced as `SIZE_OF_TEST`/`NUMBER_OF_RUN` + argv. Not a standalone step: the semantics change to a window, so it lands with the perpetual-instance loop. |
| **Allocator knob** | Per target: `malloc`/GH200, fine-grained/MI300A, managed = CI fallback; `cudaMemAdvise` placement hooks. Replaces `gd_malloc_managed`. |
| **Perpetual-instance loop** | Launch once, loop inside, sync-once start barrier, occupancy-bounded/cooperative launch; no per-iteration relaunch and no `cudaDeviceSynchronize`. The biggest single change. |
| **Store-tagging + recovery** | **`K·n+μ` store-tagging** (planned to touch `ASMLang` for CPU store operands *[superseded, §7]*) + per-load N-buffers + **COUNT/COUNTH recovery** + the emitted `het_obs_record` tally. Replaces the per-iteration `_cond` check. |
| **GPU stress** | Port cuda-litmus `do_stress`/`StressParams` (fix the `MEM_STRESS` bug; cite); scratchpad in `cudaMalloc`; launch widened to stress workgroups; **asymmetric instances**. |
| **CPU + interconnect stress** | CPU recipes at two sites on both ISAs + remote-pinning and noise kernels; the `-2s` invariants enforced by construction. |
| **Positive control** | Co-run the lattice-floor twin + the MP canary; null-credibility gate on `control_target_count` + `interleavings_detected`. |
| **Non-observation statistics** | `(instance,run)` unit, mandatory KS stationarity gate, `P_rep` on the observed side, corroboration stop rule; the offline `oracle-compare.sh` pass augmented with each test's own block. |
| **Autotuner** | Factored seeded random search, empirical-Bernstein early-stop, round-robin scheduling, KS gate; objective = het-mutant death rate. Runs **on hardware**. |

---

## 6. Hardware-only — what must wait for GH200 / MI300A

Everything below is unmeasurable on the dev box (wrong substrate, §3.2). **First bring-up measurement:**

1. **The control channel's rate and its time structure** — how often `mu(T)` and the canary fire per run,
   and whether that rate holds *across* a run at all. §3.7's stationarity gate is a pass/fail on exactly
   this stream and §3.9's tuner races on it, so both are running blind until it is measured, and `tau_hot`
   cannot be calibrated without it. *Measure this first.*
2. The **het weak-behaviour hit-rate** — genuinely unknown (the 0.2 % was GPU-only, §7). Nothing the
   harness reports rests on it; what it settles is how much effort a row is worth before its null is
   banked, i.e. what `--budget-runs` should be. Grow R, not N.
3. Whether the **perpetual rendezvous sustains** on GH200 without the Srivastava-style 2–3-iteration stall.
4. Whether **interconnect stress raises yield** vs per-device (currently an inference from bandwidth).
5. The **`cntvct_el0`↔`%globaltimer` drift-stability** (the cross-device timebase spike, §3.3).
6. **All MI300A specifics** — coherent rendezvous, XNACK, `s_memtime`↔`rdtsc`, per-shape observability.
7. Site-specific attributes: `concurrentManagedAccess`, `pageableMemoryAccess`, access-counter-migration
   disable mechanism.
8. Per-target **stress tuning** (all numeric knob values).

**`HET_WINDOW` calibration is a precondition for nearly half the corpus.** A `T_L ≥ 2`
shape's exhaustive `O(N^T_L)` scan is capped at production `N` (`HET_EXHAUSTIVE_MAX = 4096`) →
`exhaustive_valid = 0`, so such a row can **never** return `NOT-OBSERVED-MU-HOT` — its zero is not a
measured zero — and its only detector is the uncalibrated `[c−8, c+8]` window (`HET_WINDOW = 8`). That is
**215 of the 471 tests** (`SB` 29, `WRC3` 47, `IRIW` 37, `ISA2` 36, `RWC` 33, `WRC` 33), re-derivable from
the `exists` conditions. So measure `skew_*` and calibrate `HET_WINDOW` against `HET_EXHAUSTIVE_MAX` at
bring-up, before any campaign. Consequence to carry: `mu(T)` is structurally identical to T and inherits
its `T_L`, so every off-floor `T_L ≥ 2` row emits `control_exhaustive_valid = _mu_exh` and its control is
windowed too — pinned in **both** directions in `tests/cram/positive-control.t` (`SB-cg-sys-fence-2s`
emits it; `LB-cg-sys-fence-2s`, whose floor sibling decodes every frame exactly, does not).

---

## 7. Cross-cutting corrections folded in

- **The "~0.2 %" is GPU-only, not het** — [Bagchi26 §5.1] quotes it back from §4.1, where it is the
  inter-CTA GPU-only result. Bagchi gives no numeric het rate → the het hit-rate is hardware-only. The
  earlier reading of it as a het rate is a mis-attribution, corrected here.
- **The per-frame tally → `(instance,run)` unit**: raw frame counts are combinatorially inflated and
  break the statistics; the record is consumed at the instance-run level.
- **The store-tagging does not touch `ASMLang`** (supersedes §3.1's reuse item and §5's store-tagging
  row) — litmus7's own lowering bakes a store's value in as an immediate, leaving no runtime seam for
  the `K·n+μ` tag, so the CPU thread body is written by `litmus/hetCpuPlan.ml` +
  `litmus/hetCpuBody{A64,X86}.ml` and `ASMLang.dump_fun` is never reached. What the het arm still
  takes from litmus7's CPU compile pipeline is the address parameters
  and the final registers (`hetlitmus/docs/het-emission.md`).
- **cuda-litmus `MEM_STRESS` bug** — fix on port, don't inherit.
- **Licence** — cuda-litmus reuse is **supervisor-approved for thesis (academic) use** (Anatole, 2026-07-06
  — a supervision decision, *to be captured in writing*; not itself a copyright grant). The upstream repo
  (`reeselevine/cuda-litmus`) carries **NO license file** (exhaustively checked), so Levine remains the sole
  rights-holder: **citation is required**, and an **explicit grant from Levine is needed before any public
  artifact ships**. A courtesy ack is prudent regardless.
- **GPUHarbor carries no reproducibility model of its own** — the statistical measures of
  reproducibility it runs on are MC-Mutants' time-budget/confidence strategy [MCMutants23 §4.2], which
  it reuses [GPUHarbor23 §6]. What GPUHarbor adds is a **correlation validation**: over 150 random
  stress configurations on each of three devices, the Pearson coefficient between the `MP`
  weak-behaviour rate and the `MP-CO` coherence-bug rate is 0.732-0.832 [GPUHarbor23 §5.1] — evidence
  that a configuration tuned on weak behaviours also reveals conformance bugs. So it is neither a
  second statistics layer nor "zero statistics".

---

## 8. Novelty summary (for the thesis)

The environment is mostly reuse; the defensible new contributions are:
1. **A native, open, `herdtools7`-integrated** heterogeneous run pipeline (vs Bagchi's unreleased stitch).
2. **Non-observation reporting at the right replication unit** — scoring at the `(instance,run)` cell
   rather than the frame count, which makes `1−e⁻ⁿ` vacuous [Melissaris20 §IV.A], under a mandatory KS
   stationarity gate, and paired with positive controls rather than with a confidence bound.
3. **A het-aware autotuner** — no prior memory-testing tuner handles the het/overdispersed regime.
4. **Explicit interconnect stress** (placement + noise kernels) — a lever no single-die prior work had.
5. The **scope axis as a mutation-lattice extension** beyond MC-Mutants' po/sw mutators.

State all of these as *methodological/infrastructural* contributions — **not** a first-discovery claim on
GH200/CMCM (Bagchi has that).

---

## 9. Pointers

- **External sources:** every `[Key]` above resolves in `hetlitmus/docs/REFERENCES.md`, which holds the
  full citation, the claim this project takes from it, and any deviation from it.
- **The mechanisms in full:** `positive-control.md` (§3.8's two layers and the decision rule),
  `faithfulness.md` (what the static checkers can and cannot see), `het-emission.md` (how a harness is
  built), `oracle-harness.md` (the offline comparison), `TEST-PLAN.md` (which gate proves what).
- **What actually ships:** the runtime headers under `litmus/het-runtime/` — `het_verdict.h` above all,
  which is the normative source for the outcome vocabulary, the liveness disqualifiers and every
  sentence a verdict prints (the allocator, stress and noise layers print their own).
  **Where a design document and `het_verdict.h` disagree, the header is what ships**: a document can
  describe a bound or a knob the harness no longer carries, and the header cannot.
