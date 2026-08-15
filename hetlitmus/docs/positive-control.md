# The positive control: what makes a "Never" mean anything

**Design doc:** `00-environment-design.md` §3.8.
**Status:** shipped, and **characterization-only**. The harness reports what it observed
and carries no prediction; comparing a row against a verdicts file is an offline
post-run step (`hetlitmus/oracle-compare.sh`), never part of a run.

Every test that has a strictly weaker structural sibling co-runs `mu(T)` **and** the
Layer-B canary in its own launch, under the same stress, on the same C2C path, on
disjoint cache-line-padded locations. A test at the lattice floor co-runs the canary
alone — except the two tests that *are* the canary, which co-run nothing.

`HET_CONTROL_COMPILED_IN` (Layer A, `mu(T)`) is **1** on the rows off the lattice floor
and **0** on the rows at it. `HET_CANARY_COMPILED_IN` (Layer B) is the separate flag that
says a canary is co-running: **1** wherever `control-map.csv` names a real canary, and
**0** on the two tests whose `Canary` field reads `self` (`MP-{cg,gc}-sys-relaxed` — they
cannot co-run themselves). See §5 and §11.

**Counts move with the corpus; `control-map.csv` is the authority.** At the time of
writing the corpus is 471 het tests: **375 carry a `mu(T)`**, **96 are at the lattice
floor**, and **469 co-run a canary** (471 minus the two that are it). Re-measure rather
than quote: `verify/controlmap.py --check` gates the map and asserts that partition
(`N_TESTS` / `N_WITH_MU` / `N_FLOOR`), and `verify/verdictcheck.py` phase 3 gates that the
emitted corpus reproduces the co-run census (`verdictcheck.py:CENSUS`).

## 1. The problem

A litmus campaign reports **nulls** — outcomes it did *not* see. But a cold harness and a
genuinely unreachable behaviour produce the **identical empty histogram**:

> "When testing, it is impossible to tell if an unobserved illegal execution is not
> allowed or if it is simply rare and was not exposed by the tests."
> — [MCMutants23 §1.1], p. 474.

So without a positive control, **every null in the campaign carries no evidential weight
at all**, whatever anyone later compares it against.

What the control buys, precisely: it does **not** upgrade a null to a proof. It upgrades
it from **uninterpretable** to **credible-not-observed**. Falsification is one-sided:

> "we emphasise that for correct GPU programming the possibility, not probability of
> weak behaviours is what matters." — [Alglave15 §4.3], p. 585.

## 2. The two layers

Both are **themselves heterogeneous and cross C2C**. That is the whole point, and it is
what disqualifies the cheap controls: *a GPU-only observability result does not vouch for
the C2C path* (it fires with no CPU participation and without crossing the interconnect).
It is the stress design's own reasoning applied to controls — this project's, carried by no
source: a mechanism confined to one device reaches that device's own coherence, never the
link (`00-environment-design.md` §3.5, §3.6).

- **Layer A — `mu(T)`, T's structural twin at the lattice floor.** For each test off the
  floor, co-run the same program with **every ordering annotation dropped on both sides**:
  same shape, same device cut, same scopes, same accesses, same condition — the weakest
  member of T's own family the corpus contains, and therefore the one most likely to fire
  in the window T is being watched in. If `mu(T)` fires, the harness demonstrably produced
  *a cross-device interleaving of T's own shape*. The mutation is the kind MC-Mutants
  calls **Weakening sw**, taken to the floor rather than one edge; the corpus grid already
  contains the target, so there is no new test to author.

- **Layer B — the universal canary.** A fixed het `MP-{cg,gc}-sys-relaxed` instance, cut
  the same way round as the test it vouches for. MP is the only het shape with a published
  detected-weak result on GH200 ([Bagchi26 Table 4]), so it is the robust floor that
  fires when a stubborn shape does not.

Layer B fires and Layer A does not ⇒ *diagnostic*, not failure: the C2C path is live but
that shape's window needs more stress tuning (feeds the autotuner, `hetlitmus/tune.py`).
**Neither** fires ⇒ the harness was cold ⇒ the run is invalid.

**Why the floor and not the nearest weakening.** A nearest-weakening `mu(T)` would be a
closer shape-match to T, but it is also the choice most likely to be *as cold as T itself*
— and a control that does not fire vouches for nothing. The floor sibling maximises the
chance of a live control at the cost of sitting further from T on the strength lattice;
the distance is recorded per row rather than discarded (`MuAlt`, §3), so how far T sits
from its own floor is readable from the map.

## 3. `mu(T)` cannot be computed from the test's name

The map is **derived from the corpus sources** by `verify/controlmap.py`, committed as
`tests/het/control-map.csv`, and **gated** (`make hetlitmus-controlmap`).

The reason is structural. On the grid rows the floor sibling does happen to spell
`<shape>-<cut>-<scope>-relaxed`, but on the two non-grid reference tests it does not:
`mu(MP-het)` is `MP-cg-sys-relaxed` and `mu(SB-het)` is `SB-cg-sys-relaxed`, names no
rewrite of `MP-het` produces. And which rows *have* a sibling at all is a fact about the
corpus, not about the spelling.

Name rewriting fails outright one column over. The one-sided grid variants are named for
**the op the GPU performs**, `acquire` annotates only reads and `release` only writes
(`_grid_lib.sh:ord_for`), and a variant whose GPU proc has no access of that kind is
degenerate — byte-identical to its `relaxed` sibling — so `generate.sh` content-dedups it
away. The GPU's role flips with the device cut, so:

```
MP-gc-sys-acquire   DOES NOT EXIST   (MP-gc's GPU proc is write-only)
S-gc-sys-acquire    DOES NOT EXIST   (S-gc's  GPU proc is write-only)
R-gc-sys-acquire    DOES NOT EXIST   (R-gc's  GPU proc is write-only)
```

The gate therefore checks the **property**, not the spelling, and **fails closed**: a
missing or non-weaker mutant breaks the build. It never skips the control — because a
silently-absent control does not *weaken* a null, it makes it **unfalsifiable**, and the
null still prints and still looks green.

**What the gate machine-checks**, per row: `mu(T)` exists; it is *structurally identical*
to T (same procs, devices and ordered accesses, same init block, same `scopes:` tree, same
condition — a pure ordering weakening, not another program, and it counts T's outcome
rather than another); it is *strictly weaker* componentwise on the (cpu, gpu) strength
lattice and *at the floor* of it; `none` ⟺ at the floor, re-derived rather than trusted.
`--bite` proves the gate fails on six injections (deleted mutant, name-rewritten row,
wrong shape, a strictly *stronger* sibling, a moved `exists`, and the legacy 8-column
header — the last checked end to end against the emitter's own reader, since a gate that
refuses a schema the harness would happily mis-read protects nothing).

**The two documentation columns.** `MuAlt` is the **nearest** weakening — a maximal
element of the same candidate set, i.e. what a minimal-mutant policy would have co-run.
It is never compiled in; it records how far T sits from its own floor (243 of the 471
rows leave it `-`, meaning the floor *is* the nearest weakening or T is already at it).
`MuRelaxed` is the fully-relaxed companion, which is `Mu` itself on every row; the column
stays because the gate **asserts that identity**, so a hand-edit that moves one and not
the other is caught instead of silently splitting the co-run choice from the documented
one.

**The x86 lane derives its own map; it does not translate the AArch64 one.** The
per-side strength lattice `mu(T)` is weakened on is CPU-ISA vocabulary. On AArch64 it
has a middle rung — `STLR`/`LDAPR`/`LDAR`/`DMB.ST`/`DMB.LD` are *partial* orderings
above plain accesses and below `DMB SY`. On x86 that rung collapses: those images are
all a plain `MOV`, so the only CPU op that orders a pair is `MFENCE`, and `mu(T)` for an
`MFENCE`-bearing test is the **`MFENCE`-deleted** test rather than an `acqrel` one. A
candidate that merely moves within the collapsed set is not a weakening at all — the
harness would co-run the identical program and the "control" would vouch for nothing —
so `controlmap.py --lattice x86` refuses it and emits a separate file,
`tests/het/control-map-amd.csv`. Which map a lane reads is therefore a property of its
**CPU column**, named by that column's frontend (`litmus/hetCpuFront.ml`); the file
keeps its AMD-era name.

## 4. The decision rule (`het_verdict.h`)

**One axis, four outcomes: was the weak outcome seen, and if not, what vouches for the
harness that did not see it.** No prediction enters and none is printed — "observed" and
"not observed" are the whole vocabulary.

```
0. rec_magic != HET_REC_MAGIC                 -> COLD-INVALID   (HET_DQ_REC_UNSTAMPED;
                                                 a BUILD BUG -- every field below it is
                                                 whatever memset left.  Claim nothing.)

1. caveats computed FIRST (they travel with a sighting too, not only with a null)

2. target_count_exhaustive > 0 || target_count_heuristic > 0
                                              -> HET_OBSERVED
                                                 (believed unconditionally: no control is
                                                  needed to believe a positive)

3. liveness disqualifiers (below)

4. hot_control = control_compiled_in && control_target_count >= HET_TAU_HOT
   hot_canary  = canary_compiled_in  && canary_target_count  >= HET_TAU_HOT
   neither hot                                -> HET_DQ_CONTROLS_COLD

5. any disqualifier                           -> HET_COLD_INVALID
   hot_control && exhaustive_valid            -> HET_NOT_OBSERVED_MU_HOT
   otherwise                                  -> HET_NOT_OBSERVED_CANARY_ONLY
```

`HET_NOT_OBSERVED_MU_HOT` is the strong null: `mu(T)` fired on the same run, stress and
C2C path, T's own two engines provably overlapped, and the zero came from the
ground-truth scan. `HET_NOT_OBSERVED_CANARY_ONLY` is the weaker one and the printout names
*which* weakness applies — no `mu` co-runs, or it did not reach `tau_hot`, or the
ground-truth scan never ran so the zero is not a measured zero. The GTX 280 honesty of
[Alglave15 fn. 7], p. 577 is the precedent for saying so plainly rather than reporting the
two alike.

`COLD-INVALID` stays reachable from every row on purpose, including the ones with no
Layer A: characterizing a **dead** harness is a fabrication, not a finding ("under a
harness where the canary fired 0 times, the machine exhibited the outcome 0 times" is not
a datum).

`tau_hot = 30` (`HET_TAU_HOT`; [Kirkham20 §1.1]'s 95 % floor is 3 — 30 makes "hot" comfortable
rather than marginal, which is cheap in a perpetual harness). Its calibration is
hardware-only.

**One disclosed deviation, and step 2 of the rule above is where it sits.** Keying the
sighting off `target_count_exhaustive` alone would be the tighter rule; `het_verdict()`
ORs `target_count_heuristic` in. For a `T_L ≥ 2` shape at production `N` the exhaustive
scan does not run (`HET_EXHAUSTIVE_MAX = 4096`), so that field is 0 *by construction* and a
real sighting would be **silently dropped** — a false negative on the single most valuable
outcome the campaign can produce. The windowed heuristic searches `[c−W, c+W]` and the
exhaustive scan searches `[0, N−1]` with the **same predicate**, so the heuristic's hits
are a strict **subset**: a heuristic hit is a genuine recovered cycle (it can miss cycles,
it cannot invent them). It is counted, and flagged `HET_CV_HEURISTIC_SIGHT` so it is never
passed off as ground truth.

**Liveness disqualifiers.** A null from a run whose stress was inert is not the
same datum as one from a stressed run, and nothing else in the record would say so.
Disqualifying: an unstamped record; neither layer compiled in; no interleaving on the
synchrony channel, or fewer than `HET_THETA_DISTINCT` distinct store-values on the
observer channel (the store-only shapes' only channel); `stress_truncated > 0`; both
controls cold; and *requested-but-dead* — the window opener, the GPU scratchpad stress,
the CPU enemies, the cache preload, and either half of the C2C noise. Caveating:
`cpu_aff_failures` (pinning is fiction), `place_failures` (`cudaMemAdvise` refused), a
mostly-`spin_cap` run (a delay loop, not a rendezvous), an unstressed run (1 of 6 mutants
exposed with no stress at all, [Kirkham20 §6.2 Tab.10]), a zero lane count (the mechanism
is structurally absent, not dead), a canary-only vouch, and a non-measured exhaustive count.

*Requested*-but-dead, not merely zero: a deliberately disabled mechanism is not a bug, and
treating "counter == 0" as disqualifying on its own would make an intentional no-stress
baseline COLD forever — which is just another way of building a rule that always says the
same thing.

### The mechanism behind two of the caveat lines

The printout states each caveat in one line and cites nothing; the reasoning is here.

**A zero lane count is structural, not dead.** `het_do_stress`'s round loop is guarded by
`_gpu_done < HET_GPU_LANES`, which is false at 0 before the body runs once, so at zero
lanes the mechanism cannot report a round however hard the run tries — and a tally of 0 is
therefore not evidence of anything. The emitter withholds the two GPU-side mechanisms
separately (`hetEmit.ml`'s `stress_requested` guards `HET_REQ_GPU_STRESS` on
`HET_GPU_LANES` and `HET_REQ_SPIN` on `HET_SPIN_LANES`), so a zero count drops exactly one
of them out of `stress_requested` while the other keeps its disqualifier. The caveat prints
both counts, so the claim is checkable against the harness's own `#define`s rather than
taken on trust.

**A KS rejection is common enough to budget for.** [Kirkham20] §4.3's own precheck already
rejects 4 of its 18 chip/test combinations GPU-only (Tab. 7), and a het run adds warm-up,
thermal drift and alignment drift on top of whatever the GPU-only case carried. `P_rep` is
suppressed across a non-stationary boundary rather than reported over it; the remedy is to
re-run split at the change-point the printout names and score the segments separately.

### The calibration channel this changed — read before comparing two campaigns

**Two rows whose stationarity was tested against different channels are not directly
comparable.** The KS precheck is run on a *control* stream — the target is far too rare to
carry a time series — and which stream that is changed on **every one of the 375 rows that
now co-run a `mu`**: all but 16 had no Layer A at all and were tested against the Layer-B
canary, and on the 16 that did, `mu(T)` itself became a different program (nearest
weakening → lattice floor — measured: the two differ on all 16). A stationarity claim
carried by another shape's stream is the weaker of the two, and on any shape but MP the
canary *is* another shape, so a `ctrl=canary` pass and a `ctrl=mu(T)` pass are not the same
statement about the same window.

Which channel a row was tested against is **on the record**, not left to the reader — the channel is
chosen once from the pooled totals and applies to every run in the pool, so there is one such fact per
row and not one per run:
`HetStats … ctrl=mu(T)` or `ctrl=canary`, backed by the `HET_ST_CTRL_IS_CANARY` flag bit in
the same line's `flags=`, and `het_stats_print` adds an explicit note whenever the canary
was used. Selection is mechanical: `mu` is read whenever one is compiled in and fired,
otherwise the canary is.

## 5. The co-run, and what the design estimate got wrong

The design estimate priced the co-run as just another het instance, needing no new machinery
and essentially free. **Against live code that was false**, and the four collisions are worth
recording because each one would have failed *silently*:

1. **`K_TAG` was one `#define` per translation unit** — and it is 3 for MP/SB/LB but 4 for
   R/S (three stores, not two). The canary is always an MP, so **every R/S control harness
   genuinely mixes K=4 and K=3 in one file.** A tag decoded with the wrong K
   mis-attributes both the writer (`tag % K`) and the iteration (`tag / K`): the recovered
   cycles become fiction, and no structural gate can see it. K is now **per instance**
   (`T_K_TAG` / `MU_K_TAG` / `CAN_K_TAG`), and every decode site spells its own.
2. **`het_run_P<proc>` was named from the proc number alone**, so T's P0 and `mu(T)`'s P0
   were both `het_run_P0` — a duplicate symbol at best, and at worst the driver calling the
   *wrong test's body*. Hence `~prefix` (`het_run_t_P0` / `_mu_` / `_can_`).
3. **`NPART` is not "2 → 6".** S and R carry observer lanes, so their instances are NPART 4,
   not 2, and their co-run harnesses are **10**. Every participant count is a **sum over the
   instances**; a hardcoded 6 would let the system-scope rendezvous release before the S/R
   observers arrived — a barrier that looks alive and is not.
4. **Three instances = three frame bindings, three detectors, three recovery scans, three
   `exhaustive_valid`.**

**The control's count is the one that is actually measured.** `mu(T)` is structurally
identical to T, so it inherits T's `T_L` class: wherever T's exhaustive scan is capped at
production `N`, `mu(T)`'s is too, and its exhaustive count is 0 *by construction*. Keying
the control off the exhaustive count would therefore leave `control_target_count`
structurally zero on every such harness and its null `COLD-INVALID` forever: **a positive
control that cannot fire is not a control.** The control therefore counts the *windowed*
detector, whose hits are a strict subset of the exhaustive scan's under the same predicate
— it can miss cycles, it cannot invent them — so it *under*-counts, which errs toward COLD,
the safe direction. `control_exhaustive_valid` records which kind of count it is, and
`het_verdict()` deliberately does **not** gate the control on it.

That path is live and pinned **both ways** in `tests/cram/positive-control.t`: `SB`'s floor
sibling is another `T_L ≥ 2` shape, so `SB-cg-sys-fence-2s` emits
`control_exhaustive_valid = _mu_exh`; `LB`'s decodes every frame exactly, so
`LB-cg-sys-fence-2s` does not. A line emitted everywhere and a line emitted nowhere are
equally uninformative.

**Disjoint cache-line-padded locations.** Disjoint *addresses* are not enough: two variables
on one cache line are one coherence unit, so `mu(T)`'s traffic would drag T's line around
and the control would perturb the very test it exists to vouch for. The instances'
shared vars and the barrier are carved out of **one `gd_alloc_shared` arena, one
cache line apart** — still the coherent allocator, which is what selects the property under
test.

**The 96 tests at the lattice floor keep `HET_CONTROL_COMPILED_IN 0`**, and that is right:
no sibling of them can be weaker, so Layer A has nothing to build, and `het_verdict()`
still refuses to return `NOT-OBSERVED-MU-HOT` for any of their nulls. They carry a Layer-B
canary under the separate flag — see §11.

## 6. Reporting stance

**Never print a bare "Never."** Every null prints *paired* with the control that is supposed
to vouch for it, by name, with absolute numbers — in the harness's own output, so the
interpretation travels with the number instead of living in a note in the thesis.

The harness stops there: it says what fired and what did not, and what vouched for the run.
The two-sided reading Iorga §4.4 describes — a not-observed row bounding one direction and
an observed row the other — is assembled **offline**, against a verdicts file the reader
supplies (`oracle-harness.md`), because it is a claim about a model and the harness holds
none.

Where a shape's control cannot be made hot, say so plainly — the GTX 280 honesty:

> "In fairness to the authors of [19], we were unable to observe weak behaviours
> using our method on the Nvidia GTX 280 chip they used."
> — [Alglave15 fn. 7], p. 577.

### The 0.2 % correction — disclose it

Do **not** cite Bagchi's ∼0.2 % relaxed-MP rate as this control's expected hit rate. On
re-reading the primary PDF that number is the **GPU-only inter-CTA** rate (§5.1 p.74,
attributed to "our Section 4.1 results", where producer and consumer are both GPU threads on
different CTAs). It fires with **no CPU participation and without crossing C2C**. There is
**no published numeric het hit-rate anywhere in the paper** (Table 4 is qualitative
detected/not-detected). The het control/canary hit-rate is **hardware-only: measure it,
never assume it.**

### The three reporting tiers (`het_confidence`)

What a null may be *claimed* as is fixed by the shape of the test's condition,
classified in `litmus/hetCond.ml` and stamped beside the `het_obs_record` it labels:

- **`CONF_ROBUST`** — the condition carries no `Location_global` atom, so every atom is
  a register read the recovery scan decodes on its own (every shape but 2+2W, R and S).
- **`CONF_ADVISORY`** — at least one register atom and exactly one ws-location (R, S).
- **`CONF_EXPLORATORY`** — register-free, every atom a `Location_global` (2+2W), and any
  other unanticipated shape: the lowest-confidence floor.

`perpetual_class` computes the **mechanism** tier and stops there. The **reporting** tier
demotes exactly one case. R and S are mechanically alike (one ws-location each), but only
S's read is an `rf` read: it observes a real writer's tag, which decodes a synchrony
point. R's only read is the fr-against-init read, which in the weak case returns the init
value, whose tag is 0 — no writer, no iteration, no synchrony. R must therefore borrow
both its synchrony point and its ws edge from the fragile observer, exactly as 2+2W does,
so its full-cycle result is reported at the 2+2W floor. `reporting_class ~has_rf_anchor`
applies that demotion and must not be folded back into `perpetual_class`; the emitter
supplies `has_rf_anchor`, because `hetCond` never sees the program.

### A ws-location is not a histogram column

A coherence-final `[ell]=v` atom is decided by the per-run observer `ws` witness and
reported through `HetObs` / `HetVerdict`, never as a number in the outcome histogram: no
run measures one, so the slot carries no bits to print and the emitted driver prints `?`
there. `verify/histcheck.py` phase 2 gates that in both directions — every register slot
prints numerically, every location slot prints `?`.

### The CPU-only set (`tests/het/generate-cpuonly.sh`)

Six shapes — MP, LB, SB, 2+2W, R, IRIW — rendered as het tests whose *every* proc is
tagged `cpu`, so they run as pure x86 tests **on the shared allocation** instead of on
litmus7's own. A plain litmus7 X86 run would allocate `x` and `y` itself, and the question
this set asks is about *that* allocation; the het harness reaches it through
`gd_alloc_shared` (`HET_ALLOC` / `hipMallocManaged`), runs the same stress and prints the
same verdict machinery.

* **`SB` and `R` must be observed** — the store buffer is live — which doubles as the
  write-back probe: a CPU-only sighting on the shared allocation rules the uncacheable
  mapping out ([APM] Table 7-2). `MP`, `LB`, `2+2W` and `IRIW` must never be.
* **A sighting of a shape x86-TSO forbids is a finding about this host's TSO conformance,
  never a refutation of the compound model:** on an all-CPU cycle no compound composition
  is under test ([Goens23] §4.6). That disambiguation is wired into the verdict rather
  than left to the reader — `het_verdict.h` keys those sentences off `_rec.cpu_only`,
  which the emitter sets when every proc of the test is a CPU proc, so nothing depends on
  the file name saying `cpuonly`.
* **Every row is at the lattice floor** (`Mu = none`): an x86 rendering of these cycles is
  plain `MOV`s with no fence to drop, so no weakening exists and the Layer-B canary is the
  whole vouch. That canary is `SB-cpuonly-x86_64` rather than the het `MP` the main corpus
  uses — what a null here needs vouched for is *the shared allocation's* store buffer, and
  only a CPU-only Allowed shape on that allocation vouches for it; the het canary would
  vouch for a C2C path these tests never take.

**The `2+2W` row is unresolved and must not be read as a TSO violation.** It is the one
store-only shape in the set: with no reader, its cycle is reconstructed from an observer,
and the emitted `ws` scans test the per-store tag `K*(_n+1)+mu` **modulo** `T_K_TAG` — the
store id — never its quotient, the iteration (the quotient is read only by the
observer-uniqueness blocks beside them). Under the perpetual loop the witness therefore
matches "`mu_a` seen before `mu_b`" *across* iterations, where the coherence order it is
meant to witness is defined only *within* one, so a sighting is equally consistent with
the detector over-reporting and with a real property of the allocation. The four shapes
with a real x86 reader close their cycle through a load, and none of this reaches them.

## 7. Hardware-only (do not settle these in code)

- The het control/canary **hit-rate** — unpublished.
- **Which shapes' mutants are observable at all** on GH200 (MP almost certainly; SB/LB/S/R
  unknown — SB is revealed by the fewest parameter configurations across [Kirkham20 §4.1]'s
  three GPUs and carries the lowest rate on two of them, yet the **highest** rate on the
  third [Kirkham20 §4.2 Tab.6], so shape difficulty does **not** transfer between parts).
  This decides which nulls are even interpretable.
- `tau_hot` calibration; `HET_WINDOW` calibration (it is a **placeholder, not a
  measurement** — owned by the autotuner (`hetlitmus/tune.py`), and it must be calibrated
  against `HET_EXHAUSTIVE_MAX`).
- Whether the floor twin is hot enough often enough that the **nearest** weakening (`MuAlt`,
  §3) could be afforded instead. The shipped `mu` *is* the fully-relaxed companion, the
  weakest candidate the corpus holds, so this is a re-tightening question rather than a
  fallback: a nearest-weakening control would vouch for a state closer to T, and only
  measured rates can say whether it fires enough to be worth the distance it gives up.
- Whether a co-running control **perturbs** T through C2C contention.

## 8. Gates

| gate | what it proves |
|---|---|
| `make hetlitmus-controlmap` | every row's `mu(T)` **exists**, is structurally identical to T and strictly weaker, at the floor of the lattice, with the same scopes and condition; `none` ⟺ at the floor; the census 471 = 375 + 96 holds. Fails closed. `--bite` proves it fails on six injections (§3). |
| `make hetlitmus-amd-controlmap` | the same derivation over the x86 strength lattice, and that the two lattices put the **same** rows at the floor — so `N_FLOOR` is not silently an AArch64 number. |
| `make hetlitmus-verdict` | four phases + `--bite`. `het_verdict()` is compiled from the **real emitted header** and fed synthetic records: all four outcomes and every liveness disqualifier reachable (**provably not constant**), an unstamped record fails closed, `tau_hot` bites exactly at `tau_hot`; each outcome's sentences are reachable from that outcome and no other, checked **both ways**; **every** emitted harness stamps `rec_magic` once and carries the co-run population the map gives it (census pinned as `verdictcheck.py:CENSUS`); and the printout names only the machine its pair is entitled to. |
| `tokens.sh selftest [8]` | the CPU/interconnect stress-liveness checker (`verify/cpustresscheck.py`) **bites** — seven injections, each `cmp -s`-verified to have actually changed the file. |
| `hetlitmus-faithful` (`ptxcheck`) | every lane of **every co-running instance** is modelled — a missing control lane means the harness *reports* a positive control it is not running. `het_instances()` mirrors the emitter's population exactly (T / T+canary / T+`mu`+canary), and disagreeing is a hard failure. |
| `hetlitmus-cram positive-control.t` | the emitted wiring: control names, the direction-matched canary, the `HET_MU_NAME NULL` sentinel and the in-harness sentence that says *why* a floor row co-runs no `mu`, `control_exhaustive_valid` per `T_L` class in both directions, the R→EXPLORATORY reporting demotion, the two compiled-in flags, and the canary's real co-run (name ≠ co-run). |

## 9. Proving the GPU stress ran, not just that it exists

`het_do_stress` (the scratchpad loop that *is* the GPU stress) once had **no runtime
tally**, so `het_obs_record` carried no evidence the loop had *executed* — only
`stresscheck.py`'s structural proof that it had survived into the PTX. The rule therefore
refused to disqualify on `HET_REQ_GPU_STRESS`, because *a check that cannot fail is worse
than no check*.

**The runtime tally closes that.** `het_stress.h` gained `HET_TALLY_STRESS_ROUNDS` (an
`atomicMax` of the rounds any single `het_do_stress` call completed — overflow-free, like
`NOISE_ROUNDS`), the record gained `gpu_stress_rounds`, and `het_verdict()` gained
`HET_DQ_GPU_STRESS_DEAD`.
`stresscheck.py` gained a **device-probe check** that drives `het_do_stress` on real hardware
and requires the tally to be **nonzero when on and zero when off**, for every access pattern
— a counter that cannot go to zero is not evidence of liveness.

The two checks are **not redundant**, and that distinction is the whole lesson of the stress
layer nvcc deleted: the runtime tally proves the loop *ran*; `stresscheck.py` proves it still
*contains* its scratchpad accesses and that they are invariant under the `-D` pattern knobs
(which is what makes them undeletable). That layer was in the source, gone from the PTX, and
green on every gate — neither check alone would have caught it.

It also has a **new** job. A co-run harness reserves 3×–5× the test blocks, so the stress
population is the first thing the co-residency cap squeezes to zero: the code present,
requested, and executed by nobody. The driver now warns about that case explicitly, *before*
the run.

## 10. Still open

- Everything in §7 remains hardware-only, and the co-run makes one of them sharper: whether
  the co-running control **perturbs** T through C2C contention is now a live question about a
  harness that actually exists. Disjoint padded locations prevent *semantic* masking;
  contention on the window is unmeasured.
- **`mu` everywhere costs blocks.** Co-run harnesses reserve 3×–5× the test blocks
  (the contention question above is the other half of the same budget), so the census of
  `NPART`/blocks against the device's `cooperativeLaunchMaxBlocks` must be taken on the
  target before a campaign, not after.
- `NOT-OBSERVED-CANARY-ONLY` is an outcome the campaign can actually produce on any row, and
  *which shapes land there* is exactly the observability question §7 flags. It is also
  the input the autotuner (`hetlitmus/tune.py`) tunes against.

---

## 11. Two flags, because they are two different claims

`HET_CONTROL_COMPILED_IN` was never widened to cover the Layer-B co-runs. "A canary is
co-running" and "the structural twin **of this test** is co-running" are different claims,
and only the second licenses `NOT-OBSERVED-MU-HOT`. Collapsed into one bit, a null on a test
that has **no mutant at all** would start reading as vouched-for by its own shape — the same
class of unfalsifiable-null bug the flag exists to prevent. So Layer A keeps its flag
(exactly the rows off the floor — 375 today) and Layer B has its own
(`HET_CANARY_COMPILED_IN` — 1 on every row whose `Canary` field is neither `-` nor `self`,
i.e. 469 of 471, **including** all 375 that also co-run a `mu`).

Beware `canary_name`: the map **names** a canary for **every** row (471), including the two
that name *themselves*; only 469 **run** one. **A name is not a co-run.** Only the flag says
the instance is there. `het_verdict()` gates each layer on its own flag for the same reason:
gating the canary on the mutant's flag would make the liveness evidence of the 96 floor rows
invisible.

The canary is matched on **direction**, not only on shape: a `cg`-cut row gets the `cg`
canary (359 rows today) and a `gc`-cut row the `gc` one (110), because a canary that crosses
the interconnect the other way round would vouch for traffic the test never generates.

On **37 of the 471 rows** of either lattice (counted over `control-map.csv` and
`control-map-amd.csv`: rows whose `Mu` is neither `none` nor `self` and equals their
`Canary`), `mu(T)` *is* the canary shape. There the two co-running instances run the same
program, so preferring the `mu` channel for the stationarity precheck buys a **second draw
of one channel**, not a shape-match — and nothing in `het_verdict.h` reads the two as
different shapes.

### The two tests that are their own canary

`MP-{cg,gc}-sys-relaxed` are the Layer-B canary (`control-map.csv`: `self`), so they cannot
co-run themselves: both flags are 0 and they stay single-instance. When one **fires**, it is
`HET_OBSERVED` — a firing test is its own control. When it does **not**, nothing in the
harness can vouch for it and the outcome is `COLD-INVALID`. That is not a gap in the
instrumentation: **it is what "the harness was cold" means** — the most observable het shape
available did not fire.

They also still take the **per-variable** allocation path (the other 469 carve a padded
arena), which is why `shared-alloc.t`'s per-variable guard sits on `MP-cg-sys-relaxed` rather
than having been deleted.

The statistics layer must not read "co-runs no control" as "it IS the canary" either:
`HET_ST_SELF_CONTROL` requires the record to **name itself** its canary, and
`HET_ST_NO_CONTROL_CORUN` covers the other way a row can co-run nothing (no map beside the
test, or an emitter that built it wrong). The denominator is `R` in both — the selection
effect is identical — but the printed sentence is not, because only one of them is a canary.
