# HetLitmus -- the heterogeneous run environment

The run-environment design and the reporting stance; `[Key]`s resolve in `REFERENCES.md`.

## The problem

Inter-CTA `sb` and `lb` are observed 0 times per 100k without memory stress on NVIDIA silicon,
while the same table records `lb` at 10959 per 100k unstressed on AMD, so the NVIDIA figure does
not carry across vendors [Alglave15 sec 4.3.1 Tab. 6]; a CUDA application's weak-memory error
appears in 0 of 1000 executions unstressed and 102 of 1000 under tuned stress [Sorensen16 sec 1].
`cudaMallocManaged` on GH200 migrates its pages between the sides [Fusco24 Tab. II], so the two
sides do not race on one line over the inter-device protocol. `Skel.ml`'s per-cell relaunch -- not
synchronisation as such -- is refused because a relaunch-per-trial harness observed no weak
behaviour where persistent instances observed it in MP and SB [Srivastava24 p.93], and litmus7
"does not have the logging to see cross-iteration interleavings" [Melissaris20 sec VIII].

## Allocation

Whether the two sides touch one physical line over the inter-device protocol is decided by the
allocator, so it is correctness, not tuning. On GH200 the shared variables and the rendezvous
counter are system `malloc()`: ATS-translated, first-touch placed, migratable, served at
cache-line granularity [Fusco24 Tab. II, sec II]. On MI300A they are fine-grained
`hipMallocManaged`, the default [HipRuntimeApi], coarse-grained memory being coherent only at
kernel boundaries. Each CUDA mode is system-scope atomic only under a condition of
[CudaGuide "Atomicity"], so a failing guard is fatal, never a fallback. The x86 ordering rules are
specified for write-back memory [APM sec 7.2, sec 7.4.2] and the allocation's memory type is never
read back, so CPU-proc outcomes rest on an unmeasured precondition.

## Rendezvous

The rendezvous writes no ordering, a correctness property: an acquire poll self-invalidates the
Hopper L1 [Bagchi26 sec 5.3] and a system-scope acquire or release on gfx942 carries a
`buffer_inv` or `buffer_wbl2` [AMDGPUUsage "AMDHSA Memory Model Code Sequences GFX942"], erasing
the cache state the iteration is about to race on while every annotation under test still matches.
Narrowing the scope fails oppositely, an agent-scope counter not being the object the host
increments; the rendezvous sits around the tested group, never between two of its accesses. The
CUDA, HIP and AArch64 arrivals lower fence-free, a claim over this source and these compilers that
nothing reads back at run time. The x86_64 arrival is `lock xaddq`, a full barrier
[IntelSDM "Loads and Stores Are Not Reordered with Locked Instructions"]: it orders none of the
tested accesses that follow it, but drains the previous iteration's tested stores while the
partner may still be reading that slot. A missed rendezvous costs its own iteration and no more,
the participant that gave up being one add ahead; a wrong counter is beyond any wait, one lost
increment stranding every later target. A host thread spinning on a device-set flag without
entering the runtime may never be unblocked [CudaGuide "CUDA C++ Execution model"], so the CUDA
render pokes it while waiting, on iteration 0 and after a failure only: a call inside the tested
loop is traffic the window does not need. The block is 128 lanes wide, the width [CudaLitmus]
tuned its stress knobs jointly with. Alignment is bought, not measured: the rendezvous buys a
common start, a per-iteration release delay sweeps the rest. One test instance runs beside the
stress workgroups, more het pairs sharing the one interconnect under test. Whether the cold line
each iteration touches lengthens the window or the miss dominates it is unmeasured. Every
probabilistic decision is one stateless draw, splitmix64 [Vigna15] at index `k` of `(seed, who)`,
never advanced, so host and device compute the same value. The seed fixes the schedule and nothing
else: varied per run, it makes two runs or two devices comparable [GPUHarbor23 sec 3.4], timing
and phase staying unseeded.

## GPU stress

The layer ports cuda-litmus's stress loop and parameters [CudaLitmus]; that repository carries no
licence file, so citation conditions the reuse and a public artifact needs its author's grant. It
rests on the window-widening hypothesis -- heavy stress makes out-of-order transfer likelier
[Alglave15 sec 4.3.1] -- and loads the on-die protocol only. Upstream's mem-stress loop matches no
branch of its pattern chain, so its `memStressPct=20` was tuned through a dead loop; here the
pattern is passed as the pattern. The mem-stress percentage is of test iterations, decided
grid-wide by one draw per iteration [WebGPULitmus], defaulting to that tool's all-stress 100, the
on/off literature's "on" [Kirkham20 Tab. 3]; below 100 an off-iteration is not quiet, pre-stress,
CPU stress and noise running regardless.

## Interconnect stress

CPU stress is litmus7's recipes at two sites, under two invariants: the stress threads touch only
a scratchpad disjoint from every test location and the barrier, and the preload sits outside the
tested body, never between two tested accesses. Both noise halves stream-read one
CPU-first-touched system buffer, mechanism and 8 GB default from [Fusco24 sec III-C]'s two noise
kernels; the construction needs both. No single-die harness has this lever, GPU-only and CPU-local
stress not reaching the host-device window; Bagchi's campaign stressed per device on both devices
[Bagchi26 sec 4.2], with no link-directed component. The host half's threads take disjoint
sequential slices [Fusco24 sec III-B.2], each one core the CPU stress threads lose, and how many
is per target ([Fusco24 Fig. 8], [Wahlgren25 sec 4.2]). The lever is claimed additive with
per-device stress and specific to the cross-device window, never better: Fusco measured bandwidth,
not yield, and noise costs loop rate. The buffer must exceed the last-level cache on its path, a
line resident in one stressing nothing [Fusco24 sec III-E.1]. Without pageable-memory access the
GPU cannot read a system buffer, so it is refused, not degraded, and a run requesting either half
is discarded ("Liveness"). Not ported from litmus7: whole-test repetition (copies do not compose
with a persistent kernel), launch randomisation, a shared-timebase release.

## Reporting

Characterization only: the harness carries no prediction, so comparing a row against expected
verdicts is offline work this tree does not ship. A cold harness and an unreachable behaviour
produce the same empty histogram [MCMutants23 sec 1.1], and falsification is one-sided, the
possibility rather than the probability of a weak behaviour being what matters
[Alglave15 sec 4.3]. Nothing vouches for a null: it reports the effort spent and the liveness the
run's counters measured, and no rate, probability or bound attaches to what was not reached. The
replication unit is the run: one run's `N` iterations share a seed, a thermal and DVFS state, a
page placement, one stress configuration and one alignment regime, so effort grows as `R`, not
`N`. A condition asking for a value no store writes compiles to a detector that never fires, and
the run reports a non-observation (`het-emission.md`, "Scope / limits"). Reporting a
non-observation as a fact about one's own reach has a precedent in [Alglave15 fn. 7]; the
two-sided reading of a campaign [Iorga21 sec 6] is a model claim this harness does not make.

## Liveness

A disqualifier discards a run; a caveat leaves it reportable, travelling with the number on a
sighting as on a null. Caveats come first because they travel with a sighting too: a weak
behaviour observed under a stress configuration nobody recorded is not reproducible. A mechanism
disqualifies when requested and dead, not merely zero: "counter == 0" alone would discard a
no-stress baseline forever. A timed-out rendezvous is a dead partner or too short a cap, never a
non-observation: a run that lost most iterations has an empty histogram about the rendezvous, not
the memory model. The caveats rest on measurements: one outcome vector across every scored
iteration is the constant-read artefact [Srivastava24 sec 4.1], and an unstressed null is weak
evidence, only one of six mutants having been exposed without stress [Kirkham20 sec 6.2 Tab.10].

## Aggregate

The denominator is `R`, the runs executed, not `R_usable`: "usable" is outcome-dependent, so that
denominator would report `Always` for a row that fired in some runs only, a pool with none usable
having measured nothing. A sighting from a degenerate run -- nothing scored, or a readout that did
not vary [Srivastava24 sec 4.1] -- is reported and left out of `k_eff`. One stop rule serves every
row, no row carrying a prediction and stubbornness being the part's property, not the shape's
[Kirkham20 sec 4.2 Tab.6]: a clean sighting ends a row, one that never fires ends at its budget,
and disabling the sighting stop yields a rate. A replayed seed adds no new draw and is not a
replicate.

## Wire format

A retired bit in the observation line's mechanism bitmask is left vacant, not closed up,
transcripts not being re-decodable later: add at the top, never renumber. The aggregate line is a
wire format too, read by key, so a field a consumer reads must be one the harness prints.

## Tuning

Method basis: [CudaLitmus]'s `tune.sh`, which draws every knob in one `random_config` call. Two
deltas: the knobs are compile-time, so a configuration costs a rebuild, and the co-resident grid
adds a launch-time validity layer. A vector the machine cannot honour is redrawn at no cost in
configuration index. A configuration whose grid is not the one drawn is killed at launch, what ran
not being what was drawn. A run the outcome rule discards, or one over the discard budget, leaves
the ranking, so the search cannot win by killing a mechanism. Nothing transfers: parameters for
one chip may not be optimal on another, even from the same vendor [Kirkham20 sec 6.4].

## Hardware-only constraints

1. The caps are placeholders, so every null says uncalibrated until polls-to-target is measured
   and each cap set above its tail.
2. A dead partner costs about `N x cap` polls, bounded only by a timeout; there is no early bail,
   a shortened `N` not being comparable.
3. The release jitter is a placeholder: measure the spread between the sides' first tested access
   and size it to sweep that.
4. Whether the rendezvous sustains is unestablished, a both-sided CPU-GPU spin barrier having
   stalled on integrated consumer parts [Srivastava24 sec 4.1].
5. An MI300A wavefront's progress while polling a system-scope load is unestablished; a probe
   precedes a campaign, both failure modes reading as a clean null.
6. The forward-progress guarantee behind the host poke is read from the Release 13.3 CUDA guide;
   confirm the pinned 12.x edition states it.
7. SB has the lowest observed rate on two of three GPUs and the highest on the third
   [Kirkham20 sec 4.2 Tab. 6]: observability is the part's.
8. The stress population is what the co-residency cap leaves after the test and noise blocks, so
   an over-large test geometry empties it.
9. The memory type of the shared allocation ("Allocation") is read from the platform (PAT/MTRR,
   `/proc/self/smaps`) for this allocator.
