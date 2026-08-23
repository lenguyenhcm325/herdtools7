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
het ([Bagchi26 §5.1]); the replication unit is the `(instance,run)` cell;
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
                                   │  (launched once, over shared coherent memory)
        ┌──────────────────────────┴───────────────────────────┐
        │  PERSISTENT loop; every iteration opens at ONE cross-device rendezvous │
        │                                                        │
   CPU test thread(s)  ⋈  GPU test lane(s)      +   GPU stress workgroups   +  CPU enemy threads
   (few: ≤ ~72 Grace cores)  over shared         (many: fill the grid,        (disjoint scratchpad)
   malloc() cache-line-coherent locations         co-residency-capped)         + REMOTE-PINNED pages
        │   iteration n touches SLOT n, on both sides                             → C2C noise (interconnect stress)
        ▼
   per-participant arrival flags  ──►  readout: AND them, then score or discard slot n
        │                        │  writes ──►  het_obs_record  {scored, discarded, target, caps, liveness, …}
        ▼                        ▼
   outs_t histogram        liveness disqualifiers  ──►  OBSERVED / NOT-OBSERVED /
   (one call per scored     (het_verdict.h)                COLD-INVALID
    iteration)             corroboration tier + stop rule  ──►  on the OBSERVED side only
```

**The pipeline ends at the observation.** The harness carries no prediction and prints none;
comparing a row against a verdicts file the reader supplies is an **offline post-run step**
outside the loop above, for which this tree ships no comparator either.

The design is overwhelmingly **reuse + adapt**, with original code confined to the genuine gap
(cross-device orchestration + the het-aware reporting layer). Lineage: PerpLE [Melissaris20] (launch-once
instances, and the observation that a harness without per-iteration logging cannot attribute an outcome
to an iteration), cuda-litmus / S&D / Kirkham / MC-Mutants (stress + parallelism + reproducibility), litmus7 (CPU
harness + histogram + asm bodies), Fusco (C2C placement/noise), Goens/Lustig (the memory models an offline
comparison would be made against).

---

## 3. Component design

### 3.1 Build strategy — hybrid bespoke spine
Keep the bespoke `.cu`/`.hip` translation unit as the outer spine; **reuse litmus7's *parts*** (CPU
inline-asm bodies via `ASMLang.dump_fun`, the `_outs.c` histogram, CPU stress *recipes*, `-size`/`-nruns`
param plumbing, diy7 generation) **without making `Skel.ml` the driver**. `Skel.ml` is single-arch and
pthread-shaped, and has no slot for a co-running kernel. What is refused is its **per-cell relaunch**,
not synchronisation as such — the harness now opens *every* iteration at a cross-device rendezvous
(§3.3) — and it is refused on three grounds:

- **Relaunch cost.** `Skel.ml` creates and joins the participants per cell. A launch is orders of
  magnitude longer than the ns-scale race window (§1), so the window is dominated by launch jitter
  rather than by the tested race.
- **Tail sensitivity.** The behaviours worth having are the ones a low-throughput loop never reaches:
  [Srivastava24 p.93] observed *no* weak behaviour with a `threadfence` between the GPU instructions
  under the relaunch-per-trial ("single instance") harness, and did observe it — in `MP` and `SB` —
  once the same tests ran as persistent instances. Throughput is not a convenience here; it decides
  which rows are answerable at all.
- **Attribution.** litmus7's own harness has no record of *which* iteration an access belonged to:
  "Litmus7's different synchronization modes may allow for some of the same orderings, but that tool
  does not have the logging to see cross-iteration interleavings" [Melissaris20 §VIII]. The slot
  layout (§3.4) is this harness's answer, and it is what makes a per-iteration outcome readable.

The rendezvous sits **around** the tested group and never between two of its accesses — the same
invariant (ii) the stress layer holds (`litmus/het-runtime/README.md`) — so it decides *when* the two
sides start an iteration and adds no ordering to what they then execute.
No prior work routes GPU/het through litmus7's CPU harness (Bagchi *stitches*).

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

### 3.3 Run-loop & alignment — persistent instances, one rendezvous per iteration
Launch the GPU kernel **once** and the CPU pthreads **once**; loop *inside*. Every iteration then opens
at a **cross-device rendezvous** on a shared counter (`litmus/het-runtime/het_rdv.h`): each participant
adds 1 with a relaxed atomic — **system-scoped** on the device side, where scope is a choice — then polls
the counter relaxed until it reaches `NPART*(n+1)`, and records for itself whether it got there.

**The rendezvous orders nothing, and that is a correctness property.** Arrival and poll are relaxed and
there is no fence between them or behind them. An acquire poll self-invalidates the GPU L1
[Bagchi26 §5.3]; a system-scope fence flushes it ([AMDGPUUsage "AMDHSA Memory Model Code Sequences
GFX942"] spells the gfx942 sequence). Either would erase the cache state the tested iteration is about
to race on while every ordering annotation under test still matched, so the rendezvous decides *when*
the sides start and contributes nothing to *what* they then observe. Narrowing the scope is the opposite
failure: a device- or agent-scope counter is not the object the host half increments.

**A cap, not a hang.** A participant that has not seen the target after `HET_CAP_CPU` (host) or
`HET_CAP_GPU` (device) polls abandons *that iteration* and records a 0; the readout discards it (§3.4).
So a partner that never arrives costs iterations, never the session — and what it costs is stated in §6,
because there is no early bail. Both caps are `#define`s overridable per run, both are **placeholders**
until a target measures them (`HET_CAP_CALIBRATED = 0`), and every null produced under them carries
`HET_CV_RDV_UNCALIBRATED`.

**Forward progress on the host side is a documented requirement, not a precaution.** A CUDA host thread
that spins on a device-set flag without entering the runtime may never be unblocked
[CudaGuide "CUDA C++ Execution model"], so the CUDA render calls `cudaStreamQuery(0)` once per poll —
on iteration 0 alone, where the grid may not yet be resident, and on no other, because a vendor runtime
call inside the tested loop is traffic the window does not need. The HIP render passes no such call. On
the device side, forward progress is guarded by **occupancy-bounded or cooperative launch**
(`cudaLaunchCooperativeKernel`; HIP equivalents) — every test block has to be resident, since every GPU
proc is a participant. Each is one block of one thread (`HET_BLOCK_DIM = 1`), so the rendezvous needs no
intra-block barrier and no assumption about progress *within* a warp.

**Alignment is still bought, not measured.** There is no shared clock and no ordering-free side channel.
What the rendezvous buys is a common *start*; the residual skew is swept by a per-participant release
delay of `0..HET_RELEASE_JITTER` empty spins drawn per iteration, so the run samples relative phases
instead of repeating one alignment, and by both-side stress (§3.5, §3.6). Bagchi never precisely aligned.

### 3.4 Instance structure & readout — asymmetric instances, one slot per iteration
- **Asymmetric instances:** a *few* genuinely-het pairs (H ≤ reserved Grace cores, ~1–8; 1 pinned CPU
  pthread ⋈ 1 GPU lane, on cache-line-padded private `malloc` locations) + *many* GPU-only stress
  instances filling the co-residency-capped grid. **Het volume comes from the persistent inner loop, not
  the instance count.** MC-Mutants' co-prime PTE is GPU-only → reuse it for the GPU stress instances, not
  the het pairs.
- **The pairing is addressed, not recovered.** Every shared location is `SIZE_OF_TEST` slots wide and
  iteration `n` touches slot `n` on both sides, so there is nothing to decode and nothing to search: the
  stores carry the values the `.litmus` writes and the loads record what they read. `HET_SLOT_STRIDE_WORDS`
  is 32 `int`s, one 128 B line per slot, so two iterations share neither a word nor a line. The budget is
  the price of that: at `N = 100000` a location costs 12.8 MB, at `N = 10^6` 128 MB, and a test pays it per
  location. The per-run `memset` that clears the slots is also what first-touches those pages.
- **The readout is one pass over the slots.** For each `n` the host ANDs the participants' arrival flags:
  an iteration at least one participant never started is **discarded** and never read; the rest are
  **scored** — outcome vector assembled from the register buffers and the location slots, compared against
  the test's condition, and handed to litmus7's `add_outcome_outs` at the single call site. So
  `target_count ≤ iters_scored ≤ N`, and `scored + discarded = N` on a run whose readout ran at all.
- **Loop nesting:** `RUNS (=Cfg.runs) × [one launch; inner for n<N, each iteration opening at the
  rendezvous]`; the old `100000` becomes `N = Cfg.size`. Growing `N` costs slot memory linearly, and a
  run whose partner is missing costs wall clock linearly too (§6), so millions of iterations is a
  target-side decision rather than a free knob.
- **A disclosed limit of the condition compiler.** The emitter refuses to emit a test whose condition
  names an unobservable register, observes a location no proc touches, carries a non-integer value, is
  not of the form `loc=v`, or compiles to a constant detector — the five refusals are listed with their
  messages in `het-emission.md` ("Scope / limits"). It does **not** check that some store in the
  program ever writes the value an atom asks for: that check lived in the store-tag map and went with
  it. A mis-specified condition therefore compiles to a detector that is permanently false and is
  reported as a null — caveated `HET_CV_ONE_OUTCOME` when every scored iteration read the same vector,
  and excluded from corroboration by `het_cell_degenerate`, but not refused. Stated here as a limit, not
  a guarantee.

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

**The iteration is not the trial, and that is why the unit is the run.** The readout scores at most one
outcome per iteration (§3.4), so the count is not inflated — but the iterations of one run are not
independent draws either: they share a seed, a thermal and DVFS state, a page placement, one stress
configuration and one alignment regime, so a run is a single experimental condition sampled `N` times.
The replication unit is therefore the `(instance,run)` cell, `Y = 1[target_count ≥ 1]`, and runs are
re-seeded so that two of them are two draws. No reproducibility number is computed from the unit
(`harness-reporting.md` §5).

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
  N                      // iterations per run (= Cfg.size)
  iters_scored           // iterations both sides started, and the readout read back
  iters_discarded        // the rest: a rendezvous that hit the cap.  scored + discarded = N
  target_count           // of the scored ones, how many matched the condition
  rdv_cap_cpu/rdv_cap_gpu  // cap expiries, counted PER PARTICIPANT per iteration
  cap_cpu/cap_gpu, cap_calibrated  // the waits this run used, and whether they were ever measured
  outcomes_vary          // 0 = every scored iteration read back the same outcome vector
  rdv_valid              // the readout ran; without it the three counts are memset zeros
}
```

This separates **did we see it** (`target_count`) from **how much of the run was a joint experiment at
all** (`iters_scored` against `N`). It is the input to the liveness gate and the stop rule
(`harness-reporting.md` §3, §5). The `outs_t` histogram is retained (fed once per scored iteration) so an
offline pass over the log the reader writes has the per-outcome counts to read.

`rdv_cap_cpu` and `rdv_cap_gpu` say which side timed out, which separates a partner that never arrived
from a cap set too short. They are **not** the two halves of `iters_discarded`: a test has one
participant per proc, each raises its own tally, and an iteration nobody reached raises all of them — so
their sum can exceed the discard count. The printed sentence says so beside the numbers.

*(The block above is the illustrative core; the **shipped** `het_obs_record` — normative in `het_verdict.h`
— carries a good deal more: `rec_magic` (an unstamped record is refused before any other field is read),
the `gpu_lanes` build fact the structural-absence caveat asserts, and the per-mechanism stress-liveness
counters the disqualifiers read (`harness-reporting.md` §3).)*

---

## 5. Build order (implementation roadmap)

Every component below is shipped. Dependencies flow top-down: the allocator knob has no
prerequisites, and everything from the slot layout onwards needs the persistent loop.
Everything is dev-box compile/CI-testable except the **science + tuning, which need
GH200/MI300A** (§6).

| component | what it carries |
|---|---|
| **Iteration window** | `100000` → `Cfg.size` + a `Cfg.runs` outer loop, surfaced as `SIZE_OF_TEST`/`NUMBER_OF_RUN` + argv. Not a standalone step: the semantics change to a window, so it lands with the persistent loop. |
| **Allocator knob** | Per target: `malloc`/GH200, fine-grained/MI300A, managed = CI fallback; `cudaMemAdvise` placement hooks. Replaces `gd_malloc_managed`. |
| **Persistent loop** | Launch once, loop inside, occupancy-bounded/cooperative launch; no per-iteration relaunch and no `cudaDeviceSynchronize`. The biggest single change. |
| **Cross-device rendezvous** | `het_rdv.h`: relaxed system-scope counter arrival + poll under a cap, per-participant arrival flags, per-participant release jitter, host-side runtime poke on iteration 0. Every iteration opens at it (§3.3). |
| **Slots + readout** | One slot per iteration per location (`HET_SLOT_STRIDE_WORDS`), stores carrying the `.litmus` values, one O(N) pass that ANDs the flags, discards or scores, and feeds the histogram once (§3.4). Replaces the per-iteration `_cond` check *and* any post-hoc pairing. |
| **GPU stress** | Port cuda-litmus `do_stress`/`StressParams` (fix the `MEM_STRESS` bug; cite); scratchpad in `cudaMalloc`; launch widened to stress workgroups; **asymmetric instances**. |
| **CPU + interconnect stress** | CPU recipes at two sites on both ISAs + remote-pinning and noise kernels; the `-2s` invariants enforced by construction. |
| **Non-observation reporting** | `(instance,run)` replication unit, the three-outcome rule and its liveness disqualifiers, the corroboration tier and the stop rule; each test's own interpretation block, printed beside its numbers so an offline pass reprints rather than re-derives it. |

---

## 6. Hardware-only — what must wait for GH200 / MI300A

Everything below is unmeasurable on the dev box (wrong substrate, §3.2). **First bring-up measurement:**

1. **The liveness counters' time structure** — `iters_scored` and the stress tallies each say a
   mechanism was alive over a *whole* run; whether that liveness holds *across* one — through occupancy
   warm-up, thermal/DVFS drift and alignment drift — is a question none of them answers, and what it
   decides is whether a long run is one experiment or several (§3.7 makes the run the unit on exactly
   that reasoning). Nothing in the harness prices a null, so no gate rests on the answer.
   *Measure this first.*
2. The **het weak-behaviour hit-rate** — genuinely unknown (the 0.2 % was GPU-only, §7). Nothing the
   harness reports rests on it; what it settles is how much effort a row is worth before its null is
   banked, i.e. what `--budget-runs` should be. Grow R, not N.
3. **CAP calibration**, and it gates the reading of every null. `HET_CAP_CPU = 262144` and
   `HET_CAP_GPU = 4096` are placeholders on any target: nothing has measured how many polls a *met*
   rendezvous actually costs there, so `HET_CAP_CALIBRATED` is 0 and `HET_CV_RDV_UNCALIBRATED` caveats
   every outcome. Measure the distribution of polls-to-target on a run whose two sides do meet, set each
   cap above its tail, and stamp `HET_CAP_CALIBRATED = 1`. Too short a cap manufactures discards; too
   long a one buys wall clock (item 5).
4. **MI300A rendezvous forward progress, and `fetch_add` integrity with it.** What is established there
   is one half: ROCm's hardware-atomics table gives MI300A `Native` for the 32/64-bit system-scope
   integer RMWs on **fine-grained** memory, and AMD's own ISCA'24 Fig. 15(a) shows a CPU spin-loop on
   flags a *running* kernel writes. What is **not** established on either AMD part is that a GPU
   wavefront spinning on a system-scope load makes progress while a CPU thread arrives — the published
   evidence runs the other direction. So one probe, two assertions, before any campaign: (i) integrity —
   concurrent CPU and GPU arrivals must sum to exactly `NPART × K`; (ii) bounded release — the wave must
   observe the CPU's arrival within a stated wall-clock bound, failing closed if it does not. The failure
   modes are a hang or a silently device-scoped rendezvous, and both look like a clean non-observation.
   Coarse-grained memory downgrades a system-scope atomic silently and `hipMalloc` is coarse-grained by
   default, so the counter is refused there by the allocator's own guard rather than by this probe.
5. **The wall-clock cost of a dead partner, and whether the harness should bail early.** A discarded
   iteration still costs the *live* side its whole cap, and nothing stops a run early: once the discards
   pass `HET_RDV_MAX_DISCARD_PCT` the run is disqualified whatever the rest does, and it still pays a cap
   for every remaining iteration. So a run against a partner that never arrives costs about `N × cap`
   polls rather than the seconds a met rendezvous costs, which is why the device-side drivers are bounded
   against it instead: `hetlitmus/hetlitmus-run.sh` and `verify/runcheck.py`'s `--hw` lane allow 900 s per
   invocation, `--characterize-hw` 600 s and two runs, and `spotcheck/ladder.sh` 900 s. **Open design
   question, deliberately not implemented:** an early bail once the discard count has already passed the
   budget would fix the cost everywhere instead of per driver — at the price of a run whose `N` no longer
   means what a scored run's does. Decide it on the target, with item 3's numbers in hand.
6. Whether the **rendezvous sustains** on GH200 without the Srivastava-style 2-3-iteration stall — and if
   it does not, **which hypothesis the stall belongs to**. The two are separable on the target: co-run a
   GPU-only cooperative test of the same geometry beside the het one. A stall that appears in both is the
   launch/occupancy hypothesis (the grid never became co-resident); a stall only the het pair shows is the
   cross-device visibility hypothesis, which is what [Srivastava24 §4.1] measured on integrated consumer
   parts.
7. Whether **interconnect stress raises yield** vs per-device (currently an inference from bandwidth).
8. **The CUDA execution-model edition the host poke rests on.** The forward-progress requirement behind
   `cudaStreamQuery(0)` (§3.3) is read off the *Release 13.3* programming guide; the toolchain this
   project pins is CUDA 12.x. Confirm the same guarantee is stated in the 12.x edition on the box that
   runs the campaign, or record the difference.
9. **All MI300A specifics** — XNACK, per-shape observability, and the compute-partitioning mode
   (SPX/TPX/CPX) the scope words are interpreted under.
10. Site-specific attributes: `concurrentManagedAccess`, `pageableMemoryAccess`, access-counter-migration
   disable mechanism.
11. Per-target **stress tuning** (all numeric knob values).
12. **Which shapes are observable at all** on the part — this decides which nulls are even
   interpretable, and shape difficulty does **not** transfer between parts: `SB` carries the lowest
   observed relaxed-behaviour rate on two of [Kirkham20 §4.2 Tab.6]'s three GPUs and the **highest**
   on the third.
13. The **launch geometry against the device's co-residency cap** — `HET_TEST_BLOCKS` and
   `HET_NOISE_GPU_BLOCKS` against the cap the emitted driver computes at start-up
   (`*OccupancyMaxActiveBlocksPerMultiprocessor` x the SM count), taken on the target *before* a
   campaign. The stress blocks fill only what that cap leaves over, so an over-large test geometry
   squeezes the stress population to zero — which the driver warns about *before* the run rather than
   leaving to the tally afterwards (`faithfulness.md`), but only the target says which geometries do it.
14. **Post-rendezvous skew on GH200.** The rendezvous fixes a common start, not a common instant: what
   remains is the spread between the two sides' first tested access, and it is what the release jitter is
   sized against. `HET_RELEASE_JITTER = 64` is a placeholder like the caps. Measure the spread, then size
   the jitter to sweep it rather than to a round number.

**Cold slots are a new regime, and this is where it is measured.** Every iteration now touches a line in
neither cache (§3.4), where the previous loop reused one word. Whether that helps (a fresh line is a
longer window) or hurts (the miss dominates the race) is unmeasured; the levers are
`HET_SLOT_STRIDE_WORDS` and the CPU preload, and the discriminator is a run at stride 1 beside a run at
32.

---

## 7. Cross-cutting corrections folded in

- **The free-running loop is replaced by a barriered persistent one** (2026-08-23). Launch-once
  survives; "sync once, then free-run" does not. Withdrawn with it, each having had no consumer left
  once the pairing became an address rather than an inference: the `K·n+μ` store tags and their decode,
  the frame scan with its pins, windows and synchrony points (`HET_WINDOW`, `HET_EXHAUSTIVE_MAX`) and
  the exhaustive-vs-heuristic split, the observer lane and the observer pthread, the device-scope window
  opener `het_spin`, the three confidence tiers, and the bespoke CPU body the tag seam forced. What
  replaced them is §3.3 and §3.4. The refusal this **reverses** is §3.1's: a per-iteration cross-device
  rendezvous is not anti-correct — a rendezvous *between* the tested accesses orders them and one
  *around* the tested group does not, and the sources cited against it said something narrower than the
  sentence they were cited for (`REFERENCES.md`, `[Srivastava24]` and `[Melissaris20]`). No gate polices
  the absence, and the pre-removal tree is preserved on branch `hetlitmus-perpetual-loop`
  (`b61d75aca`).
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
- **The `(instance,run)` cell is the replication unit**, and the reason for it has changed with the
  loop: it is no longer that a frame scan inflates the count (there is no scan — §3.4 scores at most one
  outcome per iteration), it is that the iterations of one run share a seed, a thermal state, a placement
  and one stress configuration, so a run is one condition sampled `N` times (§3.7).
- **The CPU body is litmus7's own again.** The store-tagging that once forced a bespoke body is gone
  with the slot layout, so `ASMLang.dump_fun` is reached: the het arm hands litmus7's compiled template
  to litmus7's own printer, wraps it in `het_run_P<n>`, and does the slot arithmetic in the caller
  (`hetlitmus/docs/het-emission.md`). §3.1's reuse item therefore stands as written. Two consequences
  travel with it: the emitted x86 store is the column's own `movl` on an `int` slot rather than a widened
  `movq`, and LDAPR needs `-march=armv8.3-a`, which the emitted `comp.sh` and `Makefile` carry.
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
2. **A disclosure discipline for non-observation** — the null names the effort it cost and the liveness
   the run's own counters measured, says in words that nothing vouches for it, and attaches no rate and
   no probability; a run whose two sides did not meet is discarded rather than reported as a zero. The
   claim is the discipline and the replication unit it is stated at (the `(instance,run)` cell), not a
   confidence bound.
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
  the liveness disqualifiers and caveats, the aggregate and the stop rule), `faithfulness.md` (what the
  static checkers can and cannot see), `het-emission.md` (how a harness is built),
  `TEST-PLAN.md` (which gate proves what), `litmus/het-runtime/README.md` (what each
  emitted runtime header is for).
- **What actually ships:** the runtime headers under `litmus/het-runtime/` — `het_rdv.h` for the
  rendezvous and the slot layout, and `het_verdict.h` above all,
  which is the normative source for the outcome vocabulary, the liveness disqualifiers and every
  sentence a verdict prints (the allocator, stress and noise layers print their own).
  **Where a design document and `het_verdict.h` disagree, the header is what ships**: a document can
  describe a bound or a knob the harness no longer carries, and the header cannot.
