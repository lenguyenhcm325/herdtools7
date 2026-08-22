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
- **no stress**, **no cross-device alignment**, **no liveness evidence** (nothing in the record
  says whether the two engines ever overlapped);
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
        │                        │  writes ──►  het_obs_record  {target, interleavings, liveness, skew, …}
        ▼                        ▼
   outs_t histogram        liveness disqualifiers  ──►  OBSERVED / NOT-OBSERVED /
   (fed per valid frame)   (het_verdict.h)                COLD-INVALID
                           corroboration tier + stop rule  ──►  on the OBSERVED side only
```

**The pipeline ends at the observation.** The harness carries no prediction and prints none;
comparing a row against a verdicts file the reader supplies is an **offline post-run step**
(`hetlitmus/oracle-compare.sh`, `oracle-harness.md`), outside the loop above.

The design is overwhelmingly **reuse + adapt**, with original code confined to the genuine gap
(cross-device orchestration + the het-aware reporting layer). Lineage: PerpLE [Melissaris20] (perpetual
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
device-scope) → it is a starting seed, not a preset library; re-tune on the target (§6). **Assumption-transfer caveat:**
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
**A null carries no rate and no probability.** The harness reports that the outcome was **not observed**
in the `(instance,run)` cells it scored, discloses the effort the run spent and the liveness the run's
own counters measured, says outright that **nothing vouches for the harness that did not see it**, and
says that this is characterization — the null agrees with no model and refutes none — and stops there.
Falsification is one-sided:

> "we emphasise that for correct GPU programming the possibility, not probability of weak
> behaviours is what matters." — [Alglave15 §4.3], p. 585.

So what a null carries is not an interval: it is the effort behind it, ending on **grow R, not N**, and
the stop rule holds the other side to a matching bar — a *sighting* is not written up until it
reproduces. `het_verdict.h` is the normative source, and `harness-reporting.md` is where the rule it
implements is written down: the three outcomes, the liveness disqualifiers and caveats, the denominator,
the corroboration tier and the stop rule, and every sentence a verdict prints. What this section carries
is the decision and the reasoning that fixed it.

**The frame is not the trial, and that correction is load-bearing.** The recovery scan validates
`N^{T_L}` *overlapping* frames per `N` iterations [Melissaris20 §IV.A], so raw frame counts are neither
independent nor Bernoulli and the replication unit is the `(instance,run)` cell instead. That *refines*
§3.4's per-frame tally rather than replacing it — the `outs_t` histogram is still fed once per validated
frame — and no reproducibility number is computed from the unit (`harness-reporting.md` §5).

**The scheduler has no parallelism axis, deliberately.** Running `H > 1` het pairs at once is real
emitter work, and the pairs would share the one interconnect under test, so the gain is not the pair
count. The policy levers stay `--budget-runs`, `--confirm-runs` and `--rate`.

**Nothing here prices what the harness missed.** The dispersion-aware 95 % upper bound on the rate of a
never-observed outcome is **withdrawn**, and with it every scheduler arm, tuner knob and roll-up column
that existed to compute or justify it, and the optional per-config rule-of-three garnish as well: a
characterization tool reports what its harness reached and attaches no probability to what it did not.

### 3.8 Positive control / liveness — withdrawn
Withdrawn with the positive control; see §7.

### 3.9 Tuning methodology — withdrawn
- **Withdrawn with the positive control (see §7):** the objective was the control's
  het-mutant death rate, and with no control there is no such rate to tune against.

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
}
```

This cleanly separates **did we see it** (`target_count`) from **could we have** (`interleavings_detected`
+ skew). It is the input to the liveness gate and the stop rule (`harness-reporting.md` §3, §5). The
`outs_t` histogram is retained (fed once per validated frame) so an offline `oracle-compare.sh` pass over
the log keeps working.

*(The block above is the illustrative core; the **shipped** `het_obs_record` — normative in `het_verdict.h`
— carries a good deal more: `rec_magic` (an unstamped record is refused before any other field is read), the
`sync_valid`/`obs_valid` channel flags plus `observer_unique_count` for the store-only channel, the
`gpu_lanes`/`spin_lanes` build facts the structural-absence caveat asserts, and the per-mechanism
stress-liveness counters the disqualifiers read (`harness-reporting.md` §3).)*

---

## 5. Build order (implementation roadmap)

Every component below is shipped. Dependencies flow top-down: the corpus audit and the
allocator knob have no prerequisites, and everything from store-tagging onwards needs the
perpetual-instance loop. One of them *reads* the audit rather than merely following it
(`litmus/hetCond.ml` computes its shape rule): store-tagging + recovery emits an observer channel
exactly on the shapes it marks, and a harness's block and lane counts follow from that.
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
| **Non-observation reporting** | `(instance,run)` replication unit, the three-outcome rule and its liveness disqualifiers, the corroboration tier and the stop rule; the offline `oracle-compare.sh` pass augmented with each test's own block. |

---

## 6. Hardware-only — what must wait for GH200 / MI300A

Everything below is unmeasurable on the dev box (wrong substrate, §3.2). **First bring-up measurement:**

1. **The liveness counters' time structure** — `interleavings_detected`, `observer_unique_count` and
   the spin and stress tallies each say a mechanism was alive over a *whole* run; whether that liveness
   holds *across* one — through occupancy warm-up, thermal/DVFS drift and alignment drift — is a
   question none of them answers, and what it decides is whether a long run is one experiment or
   several. Nothing in the harness prices a null, so no gate rests on the answer. *Measure this first.*
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
9. **Which shapes are observable at all** on the part — this decides which nulls are even
   interpretable, and shape difficulty does **not** transfer between parts: `SB` carries the lowest
   observed relaxed-behaviour rate on two of [Kirkham20 §4.2 Tab.6]'s three GPUs and the **highest**
   on the third.
10. The **launch geometry against the device's co-residency cap** — `HET_TEST_BLOCKS` and
   `HET_NOISE_GPU_BLOCKS` against the cap the emitted driver computes at start-up
   (`*OccupancyMaxActiveBlocksPerMultiprocessor` x the SM count), taken on the target *before* a
   campaign. The stress blocks fill only what that cap leaves over, so an over-large test geometry
   squeezes the stress population to zero — which the driver warns about *before* the run rather than
   leaving to the tally afterwards (`faithfulness.md`), but only the target says which geometries do it.

**`HET_WINDOW` calibration is a precondition for nearly half the corpus.** A `T_L ≥ 2` shape's exhaustive
`O(N^T_L)` scan is capped at production `N` (`HET_EXHAUSTIVE_MAX = 4096`) → `exhaustive_valid = 0`, so such
a row's zero is **not a measured zero** — the printout says so, keyed on `HET_CV_NO_EXHAUSTIVE` — and its
only detector is the uncalibrated `[c−8, c+8]` window (`HET_WINDOW = 8`). That is **215 of the 471 tests**
(`SB` 29, `WRC3` 47, `IRIW` 37, `ISA2` 36, `RWC` 33, `WRC` 33), re-derivable from the `exists` conditions.
So measure `skew_*` and calibrate `HET_WINDOW` against `HET_EXHAUSTIVE_MAX` at bring-up, before any
campaign.

---

## 7. Cross-cutting corrections folded in

- **The positive control is withdrawn** (2026-08-21), both layers: the lattice-floor structural twin
  `mu(T)` and the `MP-{cg,gc}-sys-relaxed` canary. A harness runs its test alone. Withdrawn with it,
  each having had no input or no consumer left: the KS stationarity gate and `P_rep`, whose only stream
  was the control's per-window sub-tallies; the ordering-strength lattice the twin was selected on; and
  the stress autotuner, whose objective was the control's death rate (§3.8, §3.9). The rationale is the
  one §3.7 now stands on alone — a characterization tool reports what its harness reached and prices
  nothing, and a co-running control is an attempt to price a null in evidence about the harness. This
  **reverses** §3.7's earlier "what licenses a null is … the two-layer positive control that fired
  beside it": nothing licenses a null, and the printout says so in those words. No gate polices the
  absence; the pre-removal tree is preserved on branch `hetlitmus-positive-control` (`77ba412e1`).
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
   rather than the combinatorially inflated frame count [Melissaris20 §IV.A], with the effort spent and
   the run's own liveness counters disclosed beside the zero rather than a confidence bound.
3. **Explicit interconnect stress** (placement + noise kernels) — a lever no single-die prior work had.
4. The **scope axis** — the generated corpus crosses scope with ordering strength, a dimension
   MC-Mutants' po/sw mutators do not have.

State all of these as *methodological/infrastructural* contributions — **not** a first-discovery claim on
GH200/CMCM (Bagchi has that).

---

## 9. Pointers

- **External sources:** every `[Key]` above resolves in `hetlitmus/docs/REFERENCES.md`, which holds the
  full citation, the claim this project takes from it, and any deviation from it.
- **The mechanisms in full:** `harness-reporting.md` (what a printout means — the three-outcome rule,
  the liveness disqualifiers and caveats, the reporting tiers), `faithfulness.md` (what the static checkers
  can and cannot see), `het-emission.md` (how a harness is built), `oracle-harness.md` (the offline
  comparison), `TEST-PLAN.md` (which gate proves what).
- **What actually ships:** the runtime headers under `litmus/het-runtime/` — `het_verdict.h` above all,
  which is the normative source for the outcome vocabulary, the liveness disqualifiers and every
  sentence a verdict prints (the allocator, stress and noise layers print their own).
  **Where a design document and `het_verdict.h` disagree, the header is what ships**: a document can
  describe a bound or a knob the harness no longer carries, and the header cannot.
