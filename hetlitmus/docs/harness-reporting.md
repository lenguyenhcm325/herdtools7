# What a HetLitmus printout means

**Normative source:** `litmus/het-runtime/het_verdict.h`. This file describes the rule
that header implements and the reasoning behind the sentences it prints; where the two
disagree, the header is what ships (`00-environment-design.md` §9). The design decision
and its record are `00-environment-design.md` §3.7.

**Status:** characterization-only. The harness reports what it observed and carries no
prediction; comparing a row against a verdicts file is an offline post-run step, never
part of a run. This tree ships neither the verdicts nor a comparator: a reader who wants
the comparison supplies both.

## 1. The problem a null poses

A litmus campaign reports **nulls** — outcomes it did *not* see. A cold harness and a
genuinely unreachable behaviour produce the **identical empty histogram**
([MCMutants23 §1.1] p. 474, quoted in `REFERENCES.md`).
Falsification is one-sided — what matters is the *possibility*, not the probability, of a
weak behaviour ([Alglave15 §4.3] p. 585, quoted in `REFERENCES.md`) — so a sighting stands
on its own and a null does not.

What this harness does about that is bounded, and the bound is the whole reporting stance:
**nothing vouches for a null.** A null reports the effort the run spent and the liveness
the run's own counters measured, and a run that rested on a dead mechanism is discarded
outright rather than reported as a non-observation.

## 2. The decision rule (`het_verdict()`)

**One axis, three outcomes:** was the weak outcome seen, and if not, is this run's zero a
datum at all. No prediction enters and none is printed — "observed" and "not observed" are
the whole vocabulary.

```
1. caveats computed FIRST            (they travel with a sighting too, not only
                                      with a null: a weak behaviour observed under
                                      a stress config nobody recorded is not
                                      reproducible)

2. target_count > 0                  -> HET_OBSERVED  (believed unconditionally --
                                        nothing has to vouch for a positive)

3. liveness disqualifiers (§3)

4. any disqualifier                  -> HET_COLD_INVALID
   otherwise                         -> HET_NOT_OBSERVED
```

`het_verdict()` is a **pure function of one `het_obs_record`**, so it is decidable from the
record alone, with no hardware at all.

**Step 2 reads one number, and it is a count of iterations.** The readout scores at most one
outcome per iteration and compares it against the condition there
(`00-environment-design.md` §3.4), so `target_count ≤ iters_scored ≤ N` and there is no
search, no heuristic and no second detector to reconcile. A sighting is one scored iteration
whose outcome vector satisfied the `exists` condition.

## 3. Liveness — disqualifiers and caveats

A null from a run whose stress was inert is not the same datum as one from a stressed run,
and nothing else in the record would say so. A **disqualifier** discards the run
(`COLD-INVALID`); a **caveat** leaves it reportable and travels with the number, on a
sighting as well as on a null.

**Disqualifying:** a **dead rendezvous** (`HET_DQ_RDV_DEAD` — the readout never ran, or
nothing was scored, or more than `HET_RDV_MAX_DISCARD_PCT` of `N` was thrown away at the
cap); a nonzero `stress_truncated`; and *requested-but-dead* on each of the GPU scratchpad
stress, the CPU enemies, the cache preload and either half of the interconnect noise.

**The rendezvous disqualifier is the one that is about the experiment rather than about
the stress.** An iteration only one side started is not an iteration of the test: the two
sides never shared a window for the outcome to appear in, so its slot is discarded unread.
A run that lost most of its iterations that way has an empty histogram *about the
rendezvous*, and the printed sentence says so — a timed-out rendezvous is a dead partner
or a cap set too short, never a non-observation. The counts it prints beside that
(`rdv_cap_cpu`, `rdv_cap_gpu`) are cap expiries counted **per participant per iteration**,
so they neither partition nor bound `iters_discarded`; what they separate is a partner
that never arrived from a cap set too short.

**Caveating:** `cpu_aff_failures` (the pinning is fiction), `place_failures` (the
page-placement lever was refused), **uncalibrated caps** (`HET_CV_RDV_UNCALIBRATED` — the
caps that produced the discards are `het_rdv.h`'s placeholders, and a discard count means
nothing without the wait it came from), **one outcome** (`HET_CV_ONE_OUTCOME` — every
scored iteration read back the same vector, which is the constant-read artefact
[Srivastava24 §4.1] and yields a spurious 0 % or 100 %), and an unstressed run (one of six
mutants was exposed with no stress at all, [Kirkham20 §6.2 Tab.10]).

**Requested-but-dead, not merely zero.** A deliberately disabled mechanism is not a bug,
and treating "counter == 0" as disqualifying on its own would make an intentional
no-stress baseline COLD forever — which is just another way of building a rule that always
says the same thing. The emitter fills `stress_requested` from the compile-time knobs, so
the distinction is carried in the record rather than inferred from it.

## 4. The null contract

**Never a bare "Never".** A null prints the outcome that was not seen, the effort behind
the zero (runs × `N` iterations, how many of them were scored and how many were discarded
at the rendezvous), this run's own liveness counters and the pair the binary was built
for — numbers and caveats, no interpretation. How those numbers are read is settled here,
once:

- **no rate and no probability is attached to it** — falsification is one-sided, so what a
  null carries is the effort behind it, never an interval;
- **nothing vouches for the harness that did not see it** — what is reported is the reach
  the run demonstrated on its own counters, and no component certifies that reach;
- **characterization, never validation** — the harness carries no prediction, so the null
  agrees with no model and refutes none;
- **grow R, not N** — the replication unit is the run (§5), so more runs buy independent
  draws where a longer window does not; this is the one instruction the aggregate prints,
  because it is what the reader does next.

An offline reader assembling a comparison should take the printed numbers as they are
rather than re-derive the decode: a second implementation of the same decode is what
silently drifts from the first.

Reporting a non-observation plainly, as a fact about one's own reach, has a precedent: the
GTX 280 footnote of [Alglave15 fn. 7] p. 577, whose quotation lives in `REFERENCES.md`.

The harness stops at the observation. A two-sided reading — a not-observed row bounding
one direction and an observed row the other, as [Iorga21 §6] reads a CPU/FPGA campaign —
is a claim about a model, and this harness holds none, so it is assembled **offline**
against a verdicts file the reader supplies, with a comparator the reader also supplies.

## 5. The aggregate — what a campaign reports over its runs

The **iteration is not the trial**: the readout scores at most one outcome per iteration, so
no count is inflated, but the `N` iterations of one run share a seed, a thermal and DVFS
state, a page placement, one stress configuration and one alignment regime — one condition
sampled `N` times. The replication unit is therefore the `(instance,run)` cell and
`Y = 1[target_count ≥ 1]` is what is counted; runs are re-seeded, so two runs are two draws
(`00-environment-design.md` §3.7).

**The denominator is `R`, the runs executed, uniformly.** "Usable" is outcome-dependent
unless something co-running makes it outcome-independent, and nothing does: a cell is
usable when it fired *or* when its own liveness counters were alive, so scoring over usable
cells would report `Always` for a row that fired in only some of its runs. `VOID` is the
one class read off `R_usable` instead — a pool with no usable cell measured nothing at all,
and an empty histogram from a dead harness is an absence of data rather than a
non-observation.

**The corroboration tier layers on top and suppresses nothing.** `het_verdict()` still
returns `HET_OBSERVED` on the first sighting; the tier says only how many independent
**runs** reproduced it (`HET_CORROB_RUNS`), because runs are re-seeded and carry a fresh
phase/thermal draw. A sighting from a degenerate cell — a reader stuck on its initial value
or on one value yields a spurious 100 %/0 % [Srivastava24 §4.1] — is reported, never
discarded, and simply does not count toward corroboration. *Is the sighting real?* and *is
it reproducible?* are two questions and get two answers.

**Where the hardware hours go.** One stop rule for every row, because no row carries a
prediction to schedule against: a sighting stops it once it reproduces; a *lone* clean
sighting holds the row open for `HET_CONFIRM_RUNS` runs measured **from the run it fired
in** — outranking the budget stop, since ending there would bank "seen once, stopped
looking" — and then stops `UNCONFIRMED-SIGHTING`, which is neither a null nor a
corroboration; a row that never fires stops when its budget is spent. The confirmation
window (`HET_CONFIRM_RUNS`, counted from the run that fired) and the budget are distinct
stops, and with the window shorter than the budget the two are told apart by the run
count alone. `HET_RATE=1` turns the sighting stop off. The window outranks the budget
stop but not the caller's run capacity: with a budget below the window the loop ends at
its own limit while the rule still says `CONTINUE`, leaving the row for the scheduler to
grow with a fresh seed. `hetlitmus/campaign.py` applies
the same rule across invocations,
each with a fresh seed base — replaying a seed adds no new phase draw and is not a
replicate. The two are separate units — the header decides over the records one
invocation holds, the driver over the pooled runs — so on one row they need not reach
the same arm; only the stop names and counts `check_flag_mirror` pins have to agree.

**What a schedule costs, and when pooling engages at all.** A row that fires in its last
budgeted run is owed the whole window after it, so it costs `--budget-runs +
--confirm-runs`: budget instance time for that, not for the budget alone. And a
`--budget-runs` at or below the compiled `NUMBER_OF_RUN` finishes a null row inside one
invocation, so the cross-invocation pooling above never engages — a schedule meant to
exercise it has to budget above `NUMBER_OF_RUN`.

## 6. Every atom of the condition is a histogram column

A coherence-final `[ell]=v` atom is an ordinary outcome column: iteration `n`'s slot
for `ell` holds what that iteration left there, so the readout reads it beside the register
atoms, `_dump_one` prints it as a number, and the condition compiler compares it like any
other. There is no `?` column and no separate witness: every emitted render has one
`add_outcome_outs` site and one discard site
(`if (!_ok) { _rec.iters_discarded++; continue; }`) inside the readout loop, the discard
ahead of the score, and `_dump_one` prints every column as a number even on the shape
whose every column is a location.

What the emitter still refuses at compile time, because a condition it cannot compile is a
detector that would silently never fire, is listed in `het-emission.md`; the one thing it
does **not** check is that some store in the program actually writes the value the
condition asks for.

## 7. The flag words are a wire format

`flags=0x…` on a `HetStats` line is read by archived transcripts and thesis-facing
evidence, and none of those numbers can be re-read later. A retired bit is
therefore left **vacant** rather than closed up, and each `#define` block in
`het_verdict.h` states its own vacancies beside the bits it still uses. Add at the top;
never renumber.

The `HetStats` machine line's field set, and the order it prints them in, are a wire
format too: `hetlitmus/campaign.py` reads it by key (`fnum(kv, …)`: `R`, `usable`, `k`,
`k_eff`, `k_runs`, `first_sight`), so a field a consumer reads must be one
`het_stats_line` prints.

## 8. What this file does not settle

- **Which shapes are observable at all** on a given part decides which nulls are even
  interpretable, and shape difficulty does **not** transfer between parts
  ([Kirkham20 §4.2 Tab.6]) — `00-environment-design.md` §6.
- **Rates.** No published numeric het hit-rate exists — the ~0.2 % relaxed-MP figure is a
  GPU-only inter-CTA one, corrected once in `00-environment-design.md` §7. A het rate is
  measured on the target or it is not claimed.
