# B6 — the positive control: what makes a "Never" mean anything

**Spec:** `env-research/Q4-positive-control.md`. **Design doc:** §3.8.
**Status:** COMPLETE. B6a landed the map, the record, the rule, the report and the
gates; **B6b landed the co-run emitter** — for each of the 16 Disallowed tests the
harness now genuinely co-runs `mu(T)` and the canary, in the same launch, under the
same stress, on the same C2C path, on disjoint cache-line-padded locations.
`HET_CONTROL_COMPILED_IN` is **1** on those 16 and **0** on the other 322 (which have
no forbidden cycle and so no mutant). See §5.

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

- **Layer A — the minimal mutant `μ(T)`.** For each of the 16 Disallowed tests,
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
of the 16. The gate **fails closed**: a missing or non-Allowed mutant breaks the
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

```
if   a sighting (exhaustive OR heuristic > 0)   -> MISMATCH       (refutes; report loudly)
elif control >= tau_hot AND interleavings > 0
     AND exhaustive_valid                       -> CREDIBLE NULL  (evidence FOR the model)
elif (control OR canary) >= tau_hot
     AND interleavings > 0                      -> WEAK NULL      (escalate stress tuning)
else                                            -> COLD-INVALID   (DISCARD the null)
```

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
at production N and its exhaustive count is 0 *by construction*. Keying the control
off it would leave `control_target_count` structurally zero on 2 of the 16 harnesses,
and their nulls `COLD-INVALID` forever: **a positive control that cannot fire is not a
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

**The 322 non-Disallowed tests keep `HET_CONTROL_COMPILED_IN 0`**, and that is right:
they have no known-forbidden cycle, so no mutant exists (Q4 §4.2), and `het_verdict()`
still refuses to call any of their nulls credible. Giving the 36 NO-ORACLE rows a
Layer-B-only co-run (Q4 R5, "characterization, never validation") is **not** done and
is the one piece of Q4 left open — see §10.

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

The **36 NO-ORACLE rows** get Layer-B liveness only and are reported as
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
| `make hetlitmus-controlmap` | 16/16 Disallowed tests have a μ(T) that **exists** and is **Allowed**, structurally identical to T and strictly weaker. Fails closed. |
| `make hetlitmus-verdict` | `het_verdict()` compiled from the **real emitted header**, fed synthetic records: all four branches reachable (**provably not constant**), `exhaustive_valid == 0` ⇒ never credible, every disqualifier bites, `tau_hot` bites exactly at `tau_hot`. |
| `l0_tokens.sh selftest [8]` | B5's CPU/interconnect liveness gate **bites** — six injections, each `cmp -s`-verified to have actually changed the file. |
| `hetlitmus-cram positive-control.t` | the emitted wiring: control names, the loud sentinel, `exhaustive_valid` per T_L class, the R→EXPLORATORY reporting demotion. |

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

- **The 36 NO-ORACLE rows get no co-run.** Q4 R5 asks for Layer-B (canary) liveness on
  them, reported as *characterization, never validation*. B6b scoped the co-run to the
  16 Disallowed tests (the only rows for which the map names a mutant), so the
  NO-ORACLE rows still report `COLD-INVALID`. Adding a canary-only co-run for them is
  a small extension of the same instance machinery.
- Everything in §7 remains hardware-only, and the co-run makes one of them sharper:
  whether the co-running control **perturbs** T through C2C contention is now a live
  question about a harness that actually exists (Q4 §8.4). Disjoint padded locations
  prevent *semantic* masking; contention on the window is unmeasured.
