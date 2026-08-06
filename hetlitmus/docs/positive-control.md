# B6 — the positive control: what makes a "Never" mean anything

**Spec:** `env-research/Q4-positive-control.md`. **Design doc:** §3.8.
**Status:** COMPLETE. B6a landed the map, the record, the rule, the report and the
gates; **B6b landed the co-run emitter** — for each **oracle-Disallowed** test the
harness genuinely co-runs `mu(T)` and the canary, in the same launch, under the same
stress, on the same C2C path, on disjoint cache-line-padded locations.
**B6c made the verdict ORACLE-AWARE and gave every non-Disallowed test a canary** (§11).

`HET_CONTROL_COMPILED_IN` (Layer A, `mu(T)`) is **1** on exactly the Disallowed rows
and **0** everywhere else — B6c did **not** widen it. `HET_CANARY_COMPILED_IN`
(Layer B) is the separate flag that says a canary is co-running: **1** wherever
`control-map.csv` names a real canary, and **0** on the two tests that *are* the
canary (`MP-{cg,gc}-sys-relaxed`, whose `Canary` field reads `self` — they cannot
co-run themselves). See §5 and §11.

**Counts move with the corpus; `control-map.csv` is the authority.** At the time of
writing the corpus is 411 het tests, oracle census **16 Disallowed / 319 Allowed /
76 NO-ORACLE** (it was 50/319/42 until the NVOR regeneration of 2026-08-06 demoted
32 rows, and 18/319/74 until that day's Phase-D3 repair demoted 2 more), so Layer A
is compiled in on 16 and Layer B on 409. Re-measure
rather than quote: `verify/controlmap.py --check` gates the map, and
`verify/verdictcheck.py` phase 3 gates that the emitted corpus reproduces the census.

## 1. The problem

A litmus campaign validates a memory model with **nulls** — with outcomes it did
*not* see. But a cold harness and a genuinely forbidden behaviour produce the
**identical empty histogram**:

> "When testing, it is impossible to tell if an unobserved illegal execution is not
> allowed or if it is simply rare and was not exposed by the tests."
> — MC-Mutants (Levine et al., ASPLOS'23) §1.1, p.474.

So without a positive control, the entire Disallowed half of the campaign — the
half that validates the CMCM — carries **no evidential weight at all**.

What the control buys, precisely: it does **not** upgrade a null to a proof. It
upgrades it from **uninterpretable** to **credible-not-observed**. Falsification is
one-sided:

> "we emphasise that for correct GPU programming the possibility, not probability of
> weak behaviours is what matters." — Alglave et al., ASPLOS'15 §4.3, p.585.

## 2. The two layers

Both are **themselves heterogeneous and cross C2C**. That is the whole point, and
it is what disqualifies the cheap controls: *a GPU-only observability result does
not vouch for the C2C path* (it fires with no CPU participation and without
crossing the interconnect). This is Q5/Q6's stress finding applied to controls.

- **Layer A — the minimal mutant `μ(T)`.** For each Disallowed test,
  co-run its nearest **Allowed** grid neighbour: same shape, same direction, same
  `sys` scope, same accesses, one ordering primitive weaker. If μ(T) fires, the
  harness demonstrably produced *the precise cross-device interleaving T's ordering
  is claimed to prevent*. This is MC-Mutants' **Weakening sw** mutator, and the
  corpus grid already contains it — no new test authoring.

- **Layer B — the universal canary.** A fixed het `MP-{cg,gc}-sys-relaxed`
  instance. MP is the only het shape with a published detected-weak result on GH200
  (Bagchi ISMM'26 Table 4), so it is the robust floor that fires when a stubborn
  shape does not.

Layer B fires and Layer A does not ⇒ *diagnostic*, not failure: the C2C path is
live but that shape's window needs more stress tuning (feeds B8). **Neither** fires
⇒ the harness was cold ⇒ the run is invalid.

## 3. μ(T) cannot be computed from the test's name

The map is **derived from the corpus sources + the oracle** by
`verify/controlmap.py`, committed as `tests/het/control-map.csv`, and **gated**
(`make hetlitmus-controlmap`).

The reason is structural. The one-sided grid variants are named for **the op the
GPU performs**, `acquire` annotates only reads and `release` only writes
(`_grid_lib.sh:ord_for`), and a variant whose GPU proc has no access of that kind is
degenerate — byte-identical to its `relaxed` sibling — so `generate.sh`
content-dedups it away. The GPU's role flips with the device cut, so:

```
MP-gc-sys-acquire   DOES NOT EXIST   (MP-gc's GPU proc is write-only)
S-gc-sys-acquire    DOES NOT EXIST   (S-gc's  GPU proc is write-only)
R-gc-sys-acquire    DOES NOT EXIST   (R-gc's  GPU proc is write-only)
```

A naive `acqrel-2s → acquire` rewrite therefore names a **nonexistent test** for 2
of the 50 (`MP-gc-sys-acqrel-2s` and `S-gc-sys-acqrel-2s`, whose real μ is the
`-release` sibling). The gate **fails closed**: a missing or non-Allowed mutant breaks the
build. It never skips the control — because a silently-absent control does not
*weaken* a null, it makes it **unfalsifiable**, and the null still prints and still
looks green.

**What "minimal" honestly means here.** Q4 calls these single-edge mutants. At the
grid's granularity the cell-adjacent neighbour is the smallest weakening
*available*, but it is not always literally one edge: `acqrel-2s → acquire` drops
the CPU half of the pair *and* the GPU's release (the grid has no one-sided `acqrel`
cell), and `fence-2s → acqrel-2s` weakens both sides from SC fence to RCpc rel/acq.
What the gate **machine-checks** is the property the vouch actually rests on: μ(T)
is *structurally identical* to T (same procs, devices and ordered accesses — a pure
ordering weakening, not another program) and *strictly weaker* componentwise on the
(cpu, gpu) strength lattice.

Where the GPU proc both reads and writes (LB, and the `-cg` cuts of S), **two**
equally-minimal mutants exist. We take `-acquire` and record the other as `MuAlt`;
which one fires more is hardware-only (Q4 §8.3).

## 4. The decision rule (`het_verdict.h`)

**Three reporting frames, one per oracle class (B6c).** "We saw the weak outcome"
means three completely different things depending on what the model predicted, and
until B6c the rule knew only the first one — so it framed *every* test as
should-be-forbidden. See §11.

```
if het_oracle == UNSET                          -> COLD-INVALID   (BUILD BUG; claim nothing)

ORACLE_DISALLOWED (50)   -- the model FORBIDS it; the NULL is the evidence
  if   a sighting (exhaustive OR heuristic > 0) -> MISMATCH       (refutes; report loudly)
  elif control >= tau_hot AND exhaustive_valid  -> CREDIBLE NULL  (evidence FOR the model)
  else                                          -> WEAK NULL      (escalate stress tuning)

ORACLE_ALLOWED (319)     -- the model PERMITS it; the SIGHTING is the evidence
  if   a sighting                               -> ALLOWED-OBSERVED
                                                   (the EXPECTED result; evidence the
                                                    model is not OVER-STRONG.  No control
                                                    needed -- the test is its own control)
  else (canary hot)                             -> ALLOWED-UNOBSERVED
                                                   (an OBSERVABILITY result, NOT a model
                                                    result -- Iorga's taxonomy, Alglave's
                                                    GTX-280 honesty.  Feeds B8's tuning)

ORACLE_NONE (42)         -- the model is SILENT; there is nothing to validate
  always                                        -> CHARACTERIZED  (against the canary rate;
                                                   never "refutes", never "confirms")

ALL CLASSES
  liveness disqualifier, or nothing hot         -> COLD-INVALID   (DISCARD; no information)
```

`COLD-INVALID` stays reachable from **all three** classes on purpose. Q4 R5 says the
NO-ORACLE rows are "characterization, always" — but a verdict that is *always* the
same value is a constant detector wearing a third hat, and characterizing a **dead**
harness is a fabrication, not a finding ("under a harness where the canary fired 0
times, GH200 exhibited the outcome 0 times" is not a datum). What the NO-ORACLE rows
can never produce is a **model claim** — that is what the gate enforces.

`tau_hot = 30` (Kirkham's 95 % floor is 3; 30 makes "hot" comfortable rather than
marginal — cheap in a perpetual harness). Its calibration is hardware-only.

**One disclosed deviation from Q4 §3.3's literal text.** Q4 keys MISMATCH off
`target_count_exhaustive` alone. For a T_L≥2 shape at production N the exhaustive
scan does not run (`HET_EXHAUSTIVE_MAX`), so that field is 0 *by construction* and a
real sighting would be **silently dropped** — a false negative on the single most
valuable outcome we can produce. The windowed heuristic searches `[c-W, c+W]` and
the exhaustive scan searches `[0, N-1]` with the **same predicate**, so the
heuristic's hits are a strict **subset**: a heuristic hit is a genuine recovered
cycle (it can miss cycles, it cannot invent them). We count it, and flag it
`HET_CV_HEURISTIC_SIGHT` so it is never passed off as ground truth.

**Liveness disqualifiers** (B4/B5). A null from a run whose stress was inert is not
the same datum as one from a stressed run, and nothing else in the record would say
so. Disqualifying: `stress_truncated > 0`; and *requested-but-dead* — the window
opener, the CPU enemies, the M3 preload, and either half of the C2C noise.
Caveating: `cpu_aff_failures` (pinning is fiction), `place_failures`
(`cudaMemAdvise` refused), a mostly-`spin_cap` run (a delay loop, not a
rendezvous), and an unstressed run (Kirkham exposed only 1 of 6 mutants with no
stress).

*Requested*-but-dead, not merely zero: a deliberately disabled mechanism is not a
bug, and treating "counter == 0" as disqualifying on its own would make an
intentional no-stress baseline COLD forever — which is just another way of building
a rule that always says the same thing.

## 5. The co-run (B6b), and what Q4's cost model got wrong

Q4 §2.4 calls the control "just another het instance… **No new machinery**" and §2.3
"essentially free". **Against live code that was false**, and the four collisions are
worth recording because each one would have failed *silently*:

1. **`K_TAG` was one `#define` per translation unit** — and it is 3 for MP/SB/LB but
   4 for R/S (three stores, not two). The canary is always an MP, so **every R/S
   control harness genuinely mixes K=4 and K=3 in one file.** A tag decoded with the
   wrong K mis-attributes both the writer (`tag % K`) and the iteration (`tag / K`):
   the recovered cycles become fiction, and no structural gate can see it. K is now
   **per instance** (`T_K_TAG` / `MU_K_TAG` / `CAN_K_TAG`), and every decode site
   spells its own.
2. **`het_run_P<proc>` was named from the proc number alone**, so T's P0 and μ(T)'s P0
   were both `het_run_P0` — a duplicate symbol at best, and at worst the driver
   calling the *wrong test's body*. Hence `~prefix` (`het_run_t_P0` / `_mu_` / `_can_`).
3. **`NPART` is not "2 → 6".** S and R carry observer lanes, so their instances are
   NPART 4, not 2, and their co-run harnesses are **10**. Every participant count is a
   **sum over the instances**; a hardcoded 6 would let the system-scope rendezvous
   release before the S/R observers arrived — a barrier that looks alive and is not.
4. **Three instances = three frame bindings, three detectors, three recovery scans,
   three `exhaustive_valid`.**

**The control's count is the one that is actually measured.** μ(`SB-*-sys-fence-2s`)
*is* `SB-*-sys-acqrel-2s` — itself a T_L≥2 shape — so its exhaustive scan does not run
at production N and its exhaustive count is 0 *by construction*. `SB-cg-sys-fence-2s`
is the **only** Disallowed row whose μ is `T_L ≥ 2` (re-measured on the 411-test
corpus: every other Disallowed shape — MP, LB, R, S — binds all its condition reads
and is `T_L ≤ 1`). Keying the control off the exhaustive count
would therefore leave `control_target_count` structurally zero on that harness,
and its null `COLD-INVALID` forever: **a positive control that cannot fire is not a
control.** The control therefore counts the *windowed* detector, whose hits are a
strict subset of the exhaustive scan's under the same predicate — it can miss cycles,
it cannot invent them — so it *under*-counts, which errs toward COLD, the safe
direction. `control_exhaustive_valid` records which kind of count it is, and
`het_verdict()` deliberately does **not** gate the control on it.

**Disjoint cache-line-padded locations.** Disjoint *addresses* are not enough: two
variables on one cache line are one coherence unit, so μ(T)'s traffic would drag T's
line around and the control would perturb the very test it exists to vouch for
(Q4 §8.4). The three instances' shared vars and the barrier are carved out of **one
`gd_alloc_shared` arena, one cache line apart** — still the coherent allocator, which
is what selects the property under test.

**The non-Disallowed tests keep `HET_CONTROL_COMPILED_IN 0`** (395 of the 411 today),
and that is right:
they have no known-forbidden cycle, so no mutant exists (Q4 §4.2), and `het_verdict()`
still refuses to call any of their nulls credible. **B6c gives them a Layer-B canary
under a separate flag** (`HET_CANARY_COMPILED_IN`) — see §11.

## 6. Reporting stance

**Never print a bare "Never."** Every null prints *paired* with the control that is
supposed to vouch for it, by name, with absolute numbers — in the harness's own
output, so the interpretation travels with the number instead of living in a note in
the thesis.

Frame the campaign two-sidedly (Iorga §4.4): Disallowed-never-observed = the CMCM is
not *over-permissive*; Allowed-sometimes-observed (the controls) = not
*over-strong*. Both halves come from the same run.

Where a shape's control cannot be made hot, say so plainly — the GTX-280 honesty:

> "In fairness to the authors of [19], we were unable to observe weak behaviours
> using our method on the Nvidia GTX 280 chip they used."
> — Alglave et al., ASPLOS'15, footnote 7, p.577.

The **NO-ORACLE rows** (42 today) get Layer-B liveness only and are reported as
**characterization, never validation** — they have no known-forbidden cycle, so no
mutant exists.

### The 0.2 % correction — disclose it

Do **not** cite Bagchi's ∼0.2 % relaxed-MP rate as this control's expected hit rate.
On re-reading the primary PDF that number is the **GPU-only inter-CTA** rate (§5.1
p.74, attributed to "our Section 4.1 results", where producer and consumer are both
GPU threads on different CTAs). It fires with **no CPU participation and without
crossing C2C**. There is **no published numeric het hit-rate anywhere in the paper**
(Table 4 is qualitative detected/not-detected). The het control/canary hit-rate is
**hardware-only: measure it, never assume it.**

## 7. Hardware-only (do not settle these in code)

- The het control/canary **hit-rate** — unpublished.
- **Which shapes' mutants are observable at all** on GH200 (MP almost certainly;
  SB/LB/S/R unknown — Kirkham ranks **SB hardest on every chip**). This decides
  which nulls are even interpretable.
- `tau_hot` calibration; `HET_WINDOW` calibration (it is a **placeholder, not a
  measurement** — owned by B8, and it must be calibrated against
  `HET_EXHAUSTIVE_MAX`).
- Whether the minimal mutant fires *less* than the fully-relaxed companion (if it
  cannot reach `tau_hot`, fall back to `MuRelaxed` — weaker vouch, higher rate).
- Whether a co-running control **perturbs** T through C2C contention.

## 8. Gates

| gate | what it proves |
|---|---|
| `make hetlitmus-controlmap` | every Disallowed test (16/16 today; `controlmap.py:N_DISALLOWED`) has a μ(T) that **exists** and is **Allowed**, structurally identical to T and strictly weaker. Fails closed. |
| `make hetlitmus-verdict` | **(B6c: three phases + `--bite`)** `het_verdict()` compiled from the **real emitted header**, fed synthetic records: all **seven** verdicts and all **three** oracle classes reachable (**provably not constant**), `exhaustive_valid == 0` ⇒ never credible, `ORACLE_UNSET` fails closed, every disqualifier bites, `tau_hot` bites exactly at `tau_hot`; the **refutation text** is reachable only from `ORACLE_DISALLOWED`; **every** emitted harness carries the right oracle class (411 today, census 16/319/76/0 — pinned in `verdictcheck.py:CENSUS`). `--bite` proves the gate FAILS on 5 injections. See §11. |
| `l0_tokens.sh selftest [8]` | B5's CPU/interconnect liveness gate **bites** — six injections, each `cmp -s`-verified to have actually changed the file. |
| `hetlitmus-faithful` (`ptxcheck`) | every lane of **every co-running instance** is modelled — a missing control lane means the harness *reports* a positive control it is not running. `het_instances()` mirrors the emitter's population exactly (T / T+canary / T+μ+canary), and disagreeing is a hard failure. |
| `hetlitmus-cram positive-control.t` | the emitted wiring: control names, the loud sentinel, `exhaustive_valid` per T_L class, the R→EXPLORATORY reporting demotion, **the oracle tag per class, the two compiled-in flags, and the canary's real co-run (name ≠ co-run)**. |

## 9. The gap B6a stated plainly — now closed

B6a recorded that `het_do_stress` (the scratchpad loop that *is* the GPU stress) had
**no runtime tally**, so `het_obs_record` carried no evidence the loop had *executed*
— only `stresscheck.py`'s structural proof that it had survived into the PTX. The rule
therefore refused to disqualify on `HET_REQ_GPU_STRESS`, because *a check that cannot
fail is worse than no check*.

**B6b closes it.** `het_stress.cuh` gained `HET_TALLY_STRESS_ROUNDS` (an `atomicMax` of
the rounds any single `het_do_stress` call completed — overflow-free, like
`NOISE_ROUNDS`), the record gained `gpu_stress_rounds`, and `het_verdict()` gained
`HET_DQ_GPU_STRESS_DEAD`. `stresscheck.py` gained a **D1 device probe** that drives
`het_do_stress` on real hardware and requires the tally to be **nonzero when on and
zero when off**, for every access pattern — a counter that cannot go to zero is not
evidence of liveness.

The two checks are **not redundant**, and that distinction is the whole lesson of B4:
the runtime tally proves the loop *ran*; `stresscheck.py` proves it still *contains*
its scratchpad accesses and that they are invariant under the `-D` pattern knobs
(which is what makes them undeletable). B4's layer was in the source, gone from the
PTX, and green on every gate — neither check alone would have caught it.

It also has a **new** job. A co-run harness reserves 3×–5× the test blocks, so the
stress population is the first thing the co-residency cap squeezes to zero: the code
present, requested, and executed by nobody. The driver now warns about that case
explicitly, *before* the run.

## 10. Still open

- **CLOSED by B6c:** the NO-ORACLE rows now co-run the Layer-B canary and report as
  `CHARACTERIZED` against its rate (Q4 R5). So do the Allowed rows (all but the two
  that *are* the canary). See §11.
- Everything in §7 remains hardware-only, and the co-run makes one of them sharper:
  whether the co-running control **perturbs** T through C2C contention is now a live
  question about a harness that actually exists (Q4 §8.4). Disjoint padded locations
  prevent *semantic* masking; contention on the window is unmeasured.
- **New, and hardware-only:** `ALLOWED-UNOBSERVED` is now a verdict the campaign can
  actually produce, and *which shapes land there on GH200* is exactly the observability
  question Q4 §8.2 flags. It is also the input B8 tunes against.

---

## 11. B6c — the verdict is oracle-aware, and every non-Disallowed test gets a canary

### The bug: every non-Disallowed harness stood ready to falsely refute the model

`het_verdict_print` was called unconditionally in **every** harness, and
`het_obs_record` carried **no oracle verdict** — so *any* test that observed its weak
outcome printed:

> `** the should-be-FORBIDDEN outcome was OBSERVED …`
> `** A single sighting REFUTES the model's prediction for this test.`

But the Disallowed rows are a small minority — **16 of the 411** today (it was 16 of
338 when B6c found this, 50 of 411 before NVOR and 18 before NVOR Phase D3). The
**319 oracle-Allowed** rows are ones for which the
weak outcome is *expected*, and observing it **confirms the CMCM is not over-strong**
(Iorga's from-below half); the **76 NO-ORACLE** rows are ones where allowed-vs-forbidden
is itself unestablished. Calling either a refutation is exactly backwards.
`verdictcheck.py`'s phase-2 message counts them: "395 of the 411".

**The sharpest instance:** `MP-cg-sys-relaxed` is oracle-**Allowed** *and* is the
Layer-B canary named by the largest block of `control-map.csv` (335 rows today; its
`gc` twin covers 74, and 2 rows are `self`). The one test whose entire job is
to **fire** would, run standalone, have printed a refutation of the compound memory
model *by doing its job*.

This is the **mirror image of the constant-false `_weak`**: not a silent false "Never",
but a **loud false refutation**, on the single most consequential claim the thesis can
make. The oracle was in `control-map.csv` (field 2) the whole time; the emitter's
parser bound it as `_exp` and threw it away.

### What B6c changed

1. **`het_oracle` in the record**, tagged from `control-map.csv` field 2.
   `ORACLE_UNSET = 0` **on purpose**: the record is `memset(0)`, so the zero value is
   what an emitter that *forgot* the field would produce. Had `DISALLOWED` been 0, that
   omission would have silently restored the bug. Instead `het_verdict()` **fails
   closed** on it and prints "this is a BUILD BUG, not a result."
2. **Three reporting frames** (§4) — and the refutation sentences are reachable from
   `ORACLE_DISALLOWED` and from nowhere else.
3. **The canary co-runs on every non-Disallowed test too** (Q4 R5) — all but the two
   that *are* the canary — closing B6b's self-reported incompleteness. Without it a non-firing test is *exactly as uninterpretable as a bare
   "Never"*: `ALLOWED-UNOBSERVED` ("permitted, harness demonstrably hot, still not seen"
   — an observability result) is indistinguishable from `COLD-INVALID` ("the harness was
   dead") unless something known-observable fired on the same run.

### Two flags, because they are two different claims

`HET_CONTROL_COMPILED_IN` was **not** widened to cover the new co-runs. "A canary is
co-running" and "the minimal mutant **of this test** is co-running" are different
claims, and only the second licenses a `CREDIBLE-NULL`. Collapsed into one bit, a null
on a test that has **no mutant at all** would start reading as vouched-for — the same
class of unfalsifiable-null bug the flag exists to prevent. So Layer A keeps its flag
(exactly the Disallowed rows — 16 today) and Layer B got its own
(`HET_CANARY_COMPILED_IN` — 1 on every row whose `Canary` field is neither `-` nor
`self`, i.e. 409 of 411, **including** the 16 that also co-run a μ).

Beware `canary_name`: the map **names** a canary for **every** row (411), including
the two that name *themselves*; only 409 **run** one.
**A name is not a co-run.** Only the flag says the instance is there.

### The two tests that are their own canary

`MP-{cg,gc}-sys-relaxed` are the Layer-B canary (`control-map.csv`: `self`), so they
cannot co-run themselves: both flags are 0 and they stay single-instance. When one
**fires**, it is `ALLOWED-OBSERVED` — a firing Allowed test is its own control. When it
does **not**, nothing in the harness can vouch for it and the verdict is
`COLD-INVALID`. That is not a gap in the instrumentation: **it is what "the harness was
cold" means** — the most observable het shape we have did not fire.

They also still take the **per-variable** allocation path (the other 409 now carve a
padded arena), which is why `shared-alloc.t`'s per-variable guard moved to
`MP-cg-sys-relaxed` rather than being deleted.

### Gating it — because a three-way branch on a constant field is the same old bug

`verdictcheck.py` grew from one phase to three, and a `--bite` mode:

| phase | what it proves |
|---|---|
| 1 — the rule | all **7** verdicts and all **3** oracle classes reachable (a rule that always returns one value is not a decision; an oracle branch keyed off a constant field is that bug in a new place); `ORACLE_UNSET` fails closed; every disqualifier still bites |
| 2 — the printout | the three refutation claims (`should-be-FORBIDDEN`, `REFUTES the model's prediction`, `Disallowed outcome`) appear **iff** `ORACLE_DISALLOWED`. Checked **both ways** — absent from every Allowed/NO-ORACLE block *and* still present in the Disallowed sighting. **Phase 1 cannot see this**: the verdict enum changing is not the deliverable, the *sentence* is. |
| 3 — the corpus | **every** emitted harness carries the class `control-map.csv` gives it (411 today; census **16 / 319 / 76**, pinned as `verdictcheck.py:CENSUS`), and **zero** untagged. A rule that branches on a class the emitter never sets is a rule nobody runs. |
| `--bite` | **5 injections** (3 against the rule, 2 against the emitted corpus), each verified to have actually changed the code it corrupts. A gate never seen to fail is not evidence. |
