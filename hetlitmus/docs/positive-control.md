# B6 — the positive control: what makes a "Never" mean anything

**Spec:** `env-research/Q4-positive-control.md`. **Design doc:** §3.8.
**Status:** B6a landed (map, record, rule, report, gates). **B6b — the co-run
emitter — is NOT landed**, and until it is, `control_target_count` is structurally
zero and the harness reports every null as `COLD-INVALID`. That is deliberate; see
§5.

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

## 5. What is NOT here yet, and why the harness says so out loud

**`HET_CONTROL_COMPILED_IN` is 0.** B6a wires the map, the record, the rule, the
report and the gates. The **multi-instance emitter that actually co-runs μ(T) and
the canary inside T's harness is B6b.** Until it lands, `control_target_count` is
structurally zero and means nothing, so `het_verdict()` returns `COLD-INVALID` and
prints:

```
companion MP-cg-sys-fence (minimal mutant): *** NO CONTROL COMPILED INTO THIS HARNESS ***
  -- control_target_count is structurally 0 and means NOTHING.
  This null is UNINTERPRETABLE and MUST NOT be reported as "not observed".
```

This is the safe direction and it is deliberate. With no control a null *is*
uninterpretable, and refusing to report it is correct. What would not be correct is
printing "Never" and letting it read as confirmation of the memory model.

Q4 §2.4 says the control is "just another het instance… **No new machinery**" and
§2.3 that it is "essentially free". **Against live code that is false.**
`top_litmus.ml` is explicitly a *single-instance* emitter (`instance_id` is
hardcoded 0); there is no instance-slot machinery, no multi-test emission and no
symbol prefixing. Co-running means the emitted `.cu` must carry **three** tests'
worth of GPU lanes, CPU pthreads, shared globals, tag plans (per-instance `K_TAG` —
3 for MP/SB/LB, 4 for R/S), read buffers, detectors and recovery scans, with `NPART`
2→6. That is a generalisation of the whole single-test emitter, and it is B6b.

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

## 9. A known gap, stated plainly

`het_do_stress` — the scratchpad loop that *is* the GPU stress — has **no runtime
tally**. `het_stress.cuh` counts RDV / CAP / TRUNC / NOISE / NOISE_ROUNDS and
nothing else, so `het_obs_record` carries no evidence that the stress loop
**executed**; `stresscheck.py` only proves (structurally) that it survived into the
emitted PTX. `het_verdict()` therefore deliberately does **not** disqualify on
`HET_REQ_GPU_STRESS`: checking it against the spin counters — which measure a
different mechanism — would look like a check while proving nothing about the one it
names, and *a check that cannot fail is worse than no check*. Closing this needs a
device-side `do_stress` counter (B4/B8).
