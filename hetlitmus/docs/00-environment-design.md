# HetLitmus — the heterogeneous run environment

The environment an emitted harness ships with so that a run on real hardware (GH200; MI300A)
yields a result that can be read: the design decisions and their reasons. The mechanisms in
full are the sibling documents — `harness-reporting.md` (what a printout means),
`faithfulness.md` and `amd-faithfulness.md` (what the emitted code carries of its `.litmus`
annotation), `het-emission.md` (how a harness is built), `litmus/het-runtime/README.md` (the
runtime headers). External sources are `[Key]`s resolved in `REFERENCES.md`. Where this
document and a shipped header disagree, the header is what ships.

---

## 1. The problem

A harness that relaunches its CPU threads and its kernel per iteration over managed memory
observes nothing on coherent silicon, and its "Never" means nothing:

- On NVIDIA silicon the inter-CTA `sb` and `lb` tests are observed 0 times per 100k in every
  column without the memory-stress incantation [Alglave15 §4.3.1 Tab. 6], and a weak-memory
  error in a CUDA application appears in 0 of 1000 executions on a Tesla K20 unstressed and in
  102 of 1000 under a tuned stressing environment [Sorensen16 §1]. On AMD the same table
  records `lb` at 10959 per 100k with no incantation: there stress amplifies a rate rather than
  enabling observation, and the NVIDIA figure does not carry across vendors.
- A launch is orders of magnitude longer than the ns-scale race window, so a per-iteration
  relaunch samples launch jitter, not the tested race.
- Nothing in a bare harness records whether the two engines ever overlapped, so its null
  carries no evidence that a joint experiment took place.
- `cudaMallocManaged` on GH200 migrates its pages between the sides ([Fusco24 Tab. II]), so
  the two sides do not race on one cache line over the inter-device coherence protocol.

The environment therefore supplies stress on both sides and on the interconnect (§3.5, §3.6),
one cross-device rendezvous per iteration with a per-iteration record of who took part (§3.3,
§3.4), and a reporting rule that reads a null against those counters (§3.7).

---

## 2. Architecture

- One cooperative kernel launch and a few pinned CPU pthreads per run, launched once and
  looping over `N` iterations inside; every iteration opens at a cross-device rendezvous.
- One test instance — the test's CPU threads and GPU lanes over shared locations from the
  per-target allocator (§3.2) — beside GPU stress workgroups that fill the rest of the
  co-resident grid, CPU enemy threads on a disjoint scratchpad, and a noise pair loading the
  interconnect (§3.5, §3.6).
- Iteration `n` touches slot `n` of every location on both sides, and each participant records
  per iteration whether it started it (§3.3, §3.4).
- The readout ANDs the arrival flags, discards or scores slot `n`, feeds litmus7's histogram
  once per scored iteration, and fills one `het_obs_record` per run (§4); `het_verdict.h` reads
  it into `OBSERVED` / `NOT-OBSERVED` / `COLD-INVALID` (§3.7).
- The pipeline ends at the observation. No prediction is carried or printed; comparing a row
  against expected verdicts is an offline step with a verdicts file and a comparator the reader
  supplies.

The design is reuse and adaptation — litmus7, cuda-litmus, PerpLE's launch-once instances
[Melissaris20], Fusco's noise kernels — and the original code is the cross-device
orchestration and the het-aware reporting.

---

## 3. Component design

### 3.1 Build strategy

The bespoke `.cu` / `.hip` translation unit is the driver; litmus7 supplies parts — CPU
inline-asm bodies via `ASMLang.dump_fun`, the `_outs.c` histogram, CPU stress recipes, the
`-s` / `-r` plumbing, diy7 generation. `Skel.ml` is not the driver: it is single-arch and
pthread-shaped, with no slot for a co-running kernel, and it creates and joins its participants
per cell. That per-cell relaunch — not synchronisation as such — is refused on three grounds:

- **Relaunch cost.** A launch dwarfs the race window (§1).
- **Tail sensitivity.** Under a relaunch-per-trial harness [Srivastava24 p.93] observed no weak
  behaviour with a `threadfence` between the GPU instructions, and observed it in MP and SB once
  the same tests ran as persistent instances. Throughput decides which rows are answerable.
- **Attribution.** litmus7 "does not have the logging to see cross-iteration interleavings"
  [Melissaris20 §VIII]; the slot layout (§3.4) is what makes a per-iteration outcome readable.

The rendezvous sits around the tested group and never between two of its accesses (the same
invariant the stress layer holds, §3.6): it decides when an iteration starts and adds no
ordering to what the sides then execute.

### 3.2 Memory and allocation — the allocator selects the property under test

Whether the two sides touch one physical line over the machine's inter-device coherence
protocol is decided by the allocator, so it is correctness rather than tuning:

- **GH200: system `malloc()`** for the shared variables and the rendezvous counter —
  ATS-translated, first-touch placed and migratable ([Fusco24 Tab. II]), served at cache-line
  granularity over the host-device link ([Fusco24 §II]). `cudaMallocManaged`
  (`HET_ALLOC=managed`) is a machinery fallback for a box without pageable-memory access: it
  validates codegen and plumbing, never the property under test.
- **MI300A: fine-grained `hipMallocManaged`**, the default [HipRuntimeApi]; coarse-grained memory
  is coherent only at kernel boundaries and is never used. One HBM pool, so no placement lever
  exists there.
- Each CUDA mode is system-scope atomic only under a condition of [CudaGuide "Atomicity"]; the
  allocator's guards are fatal and never fall back, and a placement request the selected mode
  cannot honour is counted and printed rather than swallowed.
- Placement (`HET_PLACE`) is the interconnect-stress lever (§3.6). The read buffers are device
  memory, off the race path.
- The x86 ordering rules are specified for write-back memory ([APM §7.2, §7.4.2]). The memory
  type of the shared allocation is a platform fact the harness does not read back, so every
  CPU-proc outcome on that allocation is read under an unmeasured precondition (§5).

### 3.3 Run loop and rendezvous — persistent instances, one rendezvous per iteration

Launch the kernel once and the CPU threads once; loop inside. Every iteration opens at a
rendezvous on a shared counter (`litmus/het-runtime/het_rdv.h`): each participant adds 1 with
a relaxed atomic — system-scoped on the device side, where scope is a choice — polls the
counter relaxed until it reaches `NPART*(n+1)`, and records for itself whether it got there.

**The rendezvous writes no ordering, and that is a correctness property.** An acquire poll
self-invalidates the Hopper L1 [Bagchi26 §5.3]; a system-scope acquire or release on gfx942
carries a `buffer_inv` or a `buffer_wbl2` ([AMDGPUUsage "AMDHSA Memory Model Code Sequences
GFX942"]). Either erases the cache state the iteration is about to race on while every
annotation under test still matches. Narrowing the scope is the opposite failure: a device- or
agent-scope counter is not the object the host increments.

**What the arrival lowers to.** Three arms are fence-free: `nvcc` emits
`atom.add.relaxed.sys.u64` and `ld.relaxed.sys.b64`; `hipcc` for gfx942 emits
`global_atomic_add_x2` and `global_load_dwordx2`, both `sc0 sc1`, with no `buffer_inv` and no
`buffer_wbl2`; an AArch64 host emits `ldadd` under LSE, else an `ldxr`/`stxr` pair, and no
`dmb`. The x86_64 arrival is `lock xaddq`, a full barrier ([IntelSDM "Loads and Stores Are Not
Reordered with Locked Instructions"]). It orders none of the tested accesses that follow it in
the same iteration — the tested store enters an empty store buffer and can still pass the
tested load — but it drains the previous iteration's tested stores while the partner may still
be reading that iteration's slot. The claim is over this source and these compilers; nothing
reads the lowering back at run time.

**A missed rendezvous costs its own iteration.** A participant that has not seen the target
after `HET_CAP_CPU` (host) or `HET_CAP_GPU` (device) polls records a 0 and the readout discards
the iteration (§3.4). It is then one add ahead: its partner's next targets are met without
waiting while its own need the partner's add, so the sides re-align within the cap. A counter
that is wrong rather than late is beyond any wait: one lost increment — `HET_ALLOC=pinned` on a
device without native host atomics, §3.2 — puts every later target out of reach. Both caps are
placeholders until a target measures them (`HET_CAP_CALIBRATED = 0`), and every null produced
under them carries `HET_CV_RDV_UNCALIBRATED`. There is no early bail (§5).

**Forward progress is a documented requirement.** A CUDA host thread spinning on a device-set
flag without entering the runtime may never be unblocked [CudaGuide "CUDA C++ Execution
model"], so the CUDA render calls `cudaStreamQuery(0)` once per `HET_RDV_POKE_EVERY` polls on
iteration 0 and on any iteration whose predecessor failed — where the grid may not be resident
— and on no other, because a runtime call inside the tested loop is traffic the window does
not need. The HIP render passes no poke. On the device side every test block must be
resident, since every GPU proc is a participant, so the launch is cooperative and the grid is
occupancy-bounded.

**Block width.** A block is `HET_BLOCK_DIM` lanes wide, defaulting to `max(128, widest cta of
the scope tree)`: 128 is `workgroupSize` in the one committed [CudaLitmus] configuration the
stress knobs of §3.5 are seeded from, and that project's tuner draws it in the same call as
those knobs, so the width is a member of that vector, not a free parameter. Lanes past the ones
the tree places match no proc guard and exit at launch, so the rendezvous needs no intra-block
barrier. The stress and noise blocks, which hold no participant, do take one: lane 0 polls the
iteration clock and broadcasts it between two `__syncthreads()`, so the poll is one
device-scope RMW per block per round and the mem-stress decision one per iteration per block.
Every lane of a stress block stresses, so scratchpad traffic scales with the width, as in
[CudaLitmus]; what that volume costs the rendezvous is answered only by the cap calibration
(§5).

**Alignment is bought, not measured.** There is no shared clock and no ordering-free side
channel. The rendezvous buys a common start; the residual skew is swept by a per-participant
release delay of `0..HET_RELEASE_JITTER` empty spins drawn per iteration, so the run samples
relative phases instead of repeating one alignment, and by both-side stress. The jitter is a
placeholder like the caps (§5).

**One stress schedule, computed the same way on both sides.** Every probabilistic decision of
the run environment — the release delay, a lane's pre-stress toggle, the grid's mem-stress
toggle, a CPU thread's preload, the scratchpad targets, the enemy index permutation — is one
call to `het_draw(seed, who, k)` (`litmus/het-runtime/het_cpu_stress.h`): splitmix64 [Vigna15]
evaluated at index `k` of the stream `(seed, who)`, never advanced. The host and the device
therefore compute the same value for the same (participant, index), which they must, since the
host setup and the kernel draw from one seed. Participant ids are pairwise distinct and each
participant's indices are its own, so a `(who, k)` is one decision and a CPU thread's delays
never track a GPU lane's. The seed fixes the schedule and nothing else: `HET_SEED` — varied
per run as `_seed0 + _run`, and per invocation by `hetlitmus/campaign.py` from a base it draws
and records — makes two runs or two devices comparable under one configuration
[GPUHarbor23 §3.4]; timing, thermal state and relative phase are unseeded, so a run does not
repeat. A base nobody pins is drawn with `getrandom(&s, 4, GRND_NONBLOCK)`: a request that
small is all-or-nothing, and the flag turns an entropy pool not yet initialised into an error
the driver reports rather than a block. The base is 31 bits, so `_seed0 + _run` cannot wrap
into another invocation's range.

### 3.4 Launch structure and readout — one test instance, one slot per iteration

- **One test instance beside the stress workgroups.** Het volume comes from the persistent
  inner loop, not from replicating the test (`H = 1`, §3.7); the GPU-only stress workgroups
  fill what the co-residency cap leaves.
- **The pairing is addressed, not recovered.** Every shared location is `SIZE_OF_TEST` slots
  wide and iteration `n` touches slot `n` on both sides, so nothing is decoded or searched: the
  stores carry the values the `.litmus` writes and the loads record what they read.
  `HET_SLOT_STRIDE_WORDS` is 32 `int`s, one 128 B line per slot, so two iterations share
  neither a word nor a line; a location costs `N × 128 B` (12.8 MB at `N = 100000`). Every
  iteration therefore touches a line in neither cache; whether a cold line lengthens the window
  or the miss dominates it is unmeasured — the levers are `HET_SLOT_STRIDE_WORDS` and the CPU
  preload, and the discriminator is a run at stride 1 beside one at 32.
- **The readout is one pass over the slots.** For each `n` the host ANDs the participants'
  arrival flags: an iteration a participant never started is discarded unread; the rest are
  scored against the condition and handed to `add_outcome_outs` once. So
  `target_count ≤ iters_scored ≤ N`, and `scored + discarded = N` once the readout ran.
- **Loop nesting:** `NUMBER_OF_RUN × [one launch; N = SIZE_OF_TEST iterations, each opening at
  the rendezvous]`. Growing `N` costs slot memory linearly and, against a missing partner, wall
  clock linearly (§5), so millions of iterations is a target-side decision.
- **A limit of the condition compiler:** it does not check that some store writes the value an
  atom asks for; such a condition compiles to a detector that never fires and is reported as a
  null (`het-emission.md`, "Scope / limits").

### 3.5 GPU-side stress — cuda-litmus, ported

`litmus/het-runtime/het_stress.h` ports cuda-litmus's `do_stress` and `StressParams`
[CudaLitmus]. The repository carries no licence file, so citation is the condition of the reuse
and a public artifact needs a grant from its author. The scratchpad is device memory
(`cudaMalloc` / `hipMalloc`), disjoint from every test location [Sorensen16 §1]. The layer
rests on the window-widening hypothesis — a memory system under heavy stress is likelier to
transfer data out of order [Alglave15 §4.3.1] — and it loads the on-die protocol only, not the
host-device path, so it is paired with §3.6.

The knob defaults are the one committed tuned configuration (one chip, device scope): a seed,
re-tuned per target (§3.8). Two deviations: upstream's `MEM_STRESS` macro passes an iteration
count in `do_stress`'s pattern slot, so its mem-stress loop matches no branch and its
`memStressPct=20` was tuned through a dead loop — here the pattern is passed as the pattern;
and `HET_MEM_STRESS_PCT` is a percentage of test *iterations* decided grid-wide, one draw per
iteration [WebGPULitmus], defaulting to that tool's all-stress 100, which is the on/off
literature's "on" [Kirkham20 Tab. 3]. Below 100 an off-iteration is not a quiet one: the
pre-stress, the enemies and the noise still run.

### 3.6 CPU-side and interconnect stress

- **CPU stress is litmus7's recipes at two sites** (`litmus/het-runtime/het_cpu_stress.h`): a
  cache preload of the test variables before the tested body, and disjoint-scratchpad enemy
  threads with affinity, on both host ISAs. Two invariants hold by construction: the enemies
  touch only a scratchpad disjoint from every test location and the barrier, and the preload
  sits outside the compiled tested body, never between two tested accesses. Test repetition is
  ported as enemy threads rather than as concurrent copies of the whole test, which do not
  compose with a persistent kernel.
- **Interconnect stress**, the lever no single-die harness has: (a) placement — bind the shared
  page to the NUMA node far from its consumer with `mbind(MPOL_BIND)`, a strict policy that
  also blocks later migration, then read the home back with `move_pages` and count any page
  left off-node; a system-malloc page is otherwise first-touch placed and migratable
  ([Fusco24 Tab. II]); (b) noise kernels — each side stream-reads a buffer homed on the other
  unit's memory, the construction under which [Fusco24 §III-C] measured Grace and Hopper write
  bandwidth to HBM at 17 % and 65 % of peak. GPU-only and CPU-local stress cannot reach the
  host-device window. Bagchi's campaign stressed per device on both devices [Bagchi26 §4.2],
  with no link-directed component.
- **The claim for the lever is bounded.** Placement and noise slow the loop, so there are fewer
  rendezvous per second, and sightings = yield × rate. What is claimed is that the lever is
  additive with per-device stress and specific to the cross-device window — never that it
  beats per-device stress: Fusco measured bandwidth, not weak-behaviour yield.
- **A noise buffer must exceed the last-level cache on its path** (`HET_LLC_MB`): a remote line
  resident in Hopper L2 crosses nothing [Fusco24 §III-E.1].
- **The host-streamed noise half needs concurrent managed access.** Where the CUDA render
  finds no pageable-memory access the noise buffers fall back to `cudaMallocManaged`, and a
  device without concurrent managed access faults on a host access to a managed buffer while
  the kernel is live ([CudaGuide "Coherency and Concurrency"]), so that half is disabled; a
  half that crosses no link is reported inert, and `harness-reporting.md` states what that
  costs a run.
- **MI300A:** one HBM pool, so no placement (a non-zero `HET_PLACE` is a compile error on the
  HIP render). The analogue is contention on the shared pool, measurable on this part as CPU
  throughput falling to 11–25 % of baseline once thousands of GPU threads share a contended
  array [Wahlgren25 §4.4]; that this is chiplet-crossing traffic is an inference
  ([Schieffer24 §II.C]).
- **Not ported from litmus7:** launch randomisation (nothing is relaunched; the phase sweep is
  the release jitter, §3.3) and a shared-timebase release (it needs a clock both sides read
  against one epoch; none is used).

### 3.7 What a non-observation reports — no rate, no probability

A null carries no rate and no probability. The run reports that the outcome was not observed,
the effort it spent and the liveness its own counters measured, and stops there: nothing
vouches for the harness that did not see it, and the null agrees with no model and refutes
none. The rule, the disqualifiers and caveats, the aggregate, the stop rule and every printed
sentence are `het_verdict.h`, described in `harness-reporting.md`; this section carries the
decisions behind them.

- **The replication unit is the run.** The readout scores at most one outcome per iteration,
  but the `N` iterations of one run share a seed, a thermal and DVFS state, a page placement,
  one stress configuration and one alignment regime: one condition sampled `N` times. So
  `Y = 1[target_count ≥ 1]` per run, runs are re-seeded so that two are two draws, and effort
  is grown as `R`, not `N`.
- **No parallelism axis.** `H > 1` het pairs would share the one interconnect under test, so
  the gain is not the pair count. The policy levers are `--budget-runs`, `--confirm-runs` and
  `--rate` (`hetlitmus/campaign.py`).
- **Nothing prices what the harness missed.** No bound on the rate of a never-observed outcome
  is computed: a characterization tool attaches no probability to what its harness did not
  reach.

### 3.8 Tuning — a seeded random search over the stress environment

`hetlitmus/tune_stress.py` draws stress configurations at random, rebuilds the tuning set under
each with the knobs as `-D` flags, runs each row once, and appends one JSONL line per
(configuration, row) to a log that is its whole state; a second pass ranks the log offline and
writes each winner's `-D` vector stamped with the target, the base seed and the configuration
index, which regenerate it. Method basis: [CudaLitmus]'s `tune.sh`, which draws every knob in
one `random_config` call. Two deltas: the knobs are compile-time, so a configuration
costs a rebuild rather than a parameter file; and the co-resident persistent grid adds a
launch-time validity layer upstream has no analogue for.

- **The draw** is one joint uniform draw of the knobs of §3.5 and §3.6 from `het_draw` at
  (base seed, configuration index, knob index), so an index regenerates its vector anywhere.
  `HET_BLOCK_DIM` is drawn even and no narrower than the tree's floor; `HET_SCRATCH_SIZE` is
  derived, never drawn. Out of the space: the knobs that fix identity or protocol rather than
  pressure (reserve cores, affinity, noise chunk, slot stride); the caps and the jitter,
  calibrated once per target; and `HET_ALLOC` / `HET_PLACE`, which are conditions under test.
- **Validity, three layers.** Draw-time: a vector asking for more regions than its scratchpad
  holds, more threads than the machine has cores, or a noise working set below twice the
  last-level cache is redrawn at fresh sub-indices and costs no configuration index; a
  configuration whose every redraw is invalid ends the search. Launch-time: a configuration
  whose mem-stress population is empty or whose grid exceeds the co-resident cap is killed at
  the driver's geometry print and logged as invalid geometry, because what ran is not what was
  drawn. Score-time: a run `het_verdict.h` finds `COLD-INVALID`, or one over the rendezvous
  discard budget, is excluded from the ranking, so the search cannot win by killing a
  mechanism.
- **The objective** is weak iterations per wall-clock second per row under `HET_RATE=1`.
  Selection is a per-row argmax on that rate, beside a coverage view of which rows each
  configuration revealed and which add rows the leader misses. Winners are stamped from
  one-shot readings; there is no confirmation pass.
- **Per target.** Nothing transfers: parameters for one chip may not be optimal on another,
  even from the same vendor [Kirkham20 §6.4]. The draw stream is shared, so configuration `k`
  is the same request on every target [GPUHarbor23 §3.4]; which part of the stream is valid is
  the target's, and the log records it.

---

## 4. The `het_obs_record`

One per run, the replication unit of §3.7:

```
het_obs_record {
  N                         // iterations per run (SIZE_OF_TEST)
  iters_scored              // both sides started it and the readout read it back
  iters_discarded           // a rendezvous hit the cap; scored + discarded = N
  target_count              // scored iterations that matched the condition
  rdv_valid                 // the readout ran; without it the counts are memset zeros
  rdv_cap_cpu, rdv_cap_gpu  // cap expiries, counted per participant per iteration
  cap_cpu, cap_gpu, cap_calibrated
  outcomes_vary             // 0 = every scored iteration read back the same vector
  ...                       // per-mechanism stress liveness (het_verdict.h)
}
```

It separates *was it seen* (`target_count`) from *how much of the run was a joint experiment*
(`iters_scored` against `N`), and is the input to the liveness disqualifiers and the stop rule
(`harness-reporting.md`). `rdv_cap_cpu` and `rdv_cap_gpu` separate a partner that never
arrived from a cap set too short; each participant raises its own tally and an iteration nobody
reached raises all of them, so their sum can exceed `iters_discarded`. The `outs_t` histogram
is fed once per scored iteration, so an offline pass has the per-outcome counts.
`het_verdict.h` is normative for the shipped record.

---

## 5. Hardware-only constraints

Unmeasurable off the target part; each shapes what a run means.

1. **Cap calibration.** `HET_CAP_CPU` and `HET_CAP_GPU` are placeholders on every target. Until
   the distribution of polls-to-target on a run whose sides meet is measured and each cap set
   above its tail (`HET_CAP_CALIBRATED = 1`), every null carries `HET_CV_RDV_UNCALIBRATED`. Too
   short a cap manufactures discards; too long a cap buys wall clock.
2. **A dead partner costs about `N × cap` polls.** A discarded iteration still costs the live
   side its whole cap, and nothing stops the run once the discards pass
   `HET_RDV_MAX_DISCARD_PCT`. `hetlitmus/campaign.py` bounds it with `--timeout` and ends the
   row `ERROR`. An early bail is not implemented: a run whose `N` was cut short would not mean
   what a scored run's `N` does.
3. **Post-rendezvous skew.** `HET_RELEASE_JITTER` is a placeholder: measure the spread between
   the two sides' first tested access and size the jitter to sweep it.
4. **Whether the rendezvous sustains**, or stalls as a per-iteration both-sided CPU–GPU spin
   barrier did on integrated consumer parts [Srivastava24 §4.1]; the cap and the discard rule
   exist to survive that. A stall shared with a GPU-only cooperative test of the same geometry
   is a launch/occupancy failure; one only the het pair shows is cross-device visibility.
5. **MI300A rendezvous forward progress.** That a wavefront polling a system-scope load makes
   progress while a CPU thread arrives is not established. One probe before a campaign:
   concurrent arrivals sum to exactly `NPART × K`, and the wave observes the CPU's arrival
   within a stated wall-clock bound. Both failure modes — a hang, a silently narrower-scoped
   rendezvous — look like a clean non-observation.
6. **The CUDA execution-model edition.** The forward-progress guarantee behind the host poke
   (§3.3) is read from the Release 13.3 guide; the pinned toolchain is CUDA 12.x. Confirm the
   12.x edition states it, or record the difference.
7. **Which shapes are observable** is a property of the part: SB carries the lowest observed
   rate on two of the three GPUs of [Kirkham20 §4.2 Tab. 6] and the highest on the third. This
   decides which nulls are interpretable, and it does not transfer between parts.
8. **Launch geometry against the co-residency cap.** The stress population is what the cap
   leaves after `HET_TEST_BLOCKS` and `HET_NOISE_GPU_BLOCKS`; an over-large test geometry
   empties it, and only the target says which geometries do.
9. **The memory type of the shared allocation** (§3.2): read it from the platform (PAT/MTRR,
   `/proc/self/smaps`) for this allocator.
