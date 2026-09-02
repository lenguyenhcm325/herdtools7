# What a HetLitmus printout means

**Normative source:** `litmus/het-runtime/het_verdict.h` — record, rule, printed sentences and
aggregate. This file states the contract that header implements and the reasons for it; the
decision behind the reporting stance is `00-environment-design.md` §3.7.

**Scope:** characterization only. The harness reports what it observed and carries no
prediction; comparing a row against expected verdicts is an offline step with a verdicts file
and a comparator the reader supplies, and this tree ships neither.

## 1. The problem a null poses

A cold harness and an unreachable behaviour produce the same empty histogram
([MCMutants23 §1.1]), and falsification is one-sided: the possibility, not the probability,
of a weak behaviour is what matters ([Alglave15 §4.3]). A sighting stands on its own; a null
does not. Hence **nothing vouches for a null**: it reports the effort spent and the liveness
the run's own counters measured, and a run resting on a dead mechanism is discarded outright.

## 2. The decision rule (`het_verdict()`)

One axis, three outcomes — `OBSERVED`, `NOT-OBSERVED`, `COLD-INVALID`: was the weak outcome
seen, and if not, is this run's zero a datum at all. The rule is a pure function of one
`het_obs_record`, so it is decidable from the record with no hardware. The order of its
steps is the policy:

- Caveats first, because they travel with a sighting too: a weak behaviour observed under a
  stress configuration nobody recorded is not reproducible.
- A sighting (`target_count > 0`) is believed unconditionally; nothing has to vouch for a
  positive. `target_count` counts iterations: the readout scores at most one outcome per
  iteration against the condition (`00-environment-design.md` §3.4), so
  `target_count ≤ iters_scored ≤ N`.
- Only then the liveness of the null (§3).

## 3. Liveness — disqualifiers and caveats

A null from a run whose stress was inert is not the same datum as one from a stressed run,
and nothing else in the record would say so. A **disqualifier** discards the run
(`COLD-INVALID`); a **caveat** leaves it reportable and travels with the number, on a
sighting as on a null.

- `HET_DQ_RDV_DEAD` — the readout did not run, nothing was scored, or more than
  `HET_RDV_MAX_DISCARD_PCT` of `N` was discarded at the cap. An iteration only one side
  started is not an iteration of the test, so its slot is discarded unread; a run that lost
  most of them has an empty histogram about the rendezvous, not the memory model. A timed-out
  rendezvous is a dead partner or a cap set too short, never a non-observation.
- `HET_DQ_*_DEAD`, one per mechanism (GPU scratchpad stress, CPU enemies, cache preload, each
  half of the interconnect noise) — requested, and its round tally is zero. A noise half is
  dead as well when its buffer crosses no link (`noise_inert`): its round and block counters
  stay healthy while it stresses nothing, so only that field separates it from a live half.

Caveats: a refused pin or placement (`HET_CV_AFF_FAILED`, `HET_CV_PLACE_REFUSED`: the topology
is not the configured one); placeholder rendezvous caps (`HET_CV_RDV_UNCALIBRATED`: a discard
count prices a wait nobody measured); one outcome vector across every scored iteration
(`HET_CV_ONE_OUTCOME`: the constant-read artefact, a spurious 0 % or 100 %
[Srivastava24 §4.1]); no stress requested (`HET_CV_UNSTRESSED`: only one of six mutants was
exposed without stress [Kirkham20 §6.2 Tab.10]).

**Requested-but-dead, not merely zero.** A deliberately disabled mechanism is not a bug, and
"counter == 0" as a disqualifier on its own would make a no-stress baseline `COLD-INVALID`
forever; the driver stamps `stress_requested` from what the build asked for, so the
distinction is carried in the record. On a box that can home neither noise buffer across the
link (`00-environment-design.md` §3.6) each half is allocated inert or refused, and either
way a run requesting it is `COLD-INVALID`; the reportable baseline there is
`HET_NOISE_CPU=0 HET_NOISE_GPU_BLOCKS=0`, which still requests the GPU scratchpad stress, the
CPU enemies and the preload and so is not `HET_CV_UNSTRESSED` (every stress knob at zero).

## 4. The null contract

A null prints the outcome not seen, the effort behind the zero (runs × `N`, scored and
discarded), the run's own liveness counters and the pair the binary was built for — numbers
and caveats, no interpretation. How those numbers are read:

- **No rate and no probability is attached.** Falsification is one-sided, so a null carries
  the effort behind it, never an interval.
- **Nothing vouches for the harness that did not see it.** What is reported is the reach the
  run demonstrated on its own counters; no component certifies that reach.
- **Characterization, never validation.** The harness carries no prediction, so a null agrees
  with no model and refutes none.
- **Grow `R`, not `N`.** The replication unit is the run (§5): more runs buy independent draws
  where a longer window does not. This is the one instruction the aggregate prints.

Reporting a non-observation plainly, as a fact about one's own reach, has a precedent in
[Alglave15 fn. 7]. The two-sided reading of a campaign — a not-observed row bounding one
direction and an observed row the other, as [Iorga21 §6] reads a CPU/FPGA campaign — is a
claim about a model; this harness holds none, so that reading is assembled offline.

## 5. The aggregate — what a campaign reports over its runs

**The replication unit is the run, not the iteration:** `Y = 1[target_count ≥ 1]` per run,
and runs are re-seeded so that two runs are two draws (why: `00-environment-design.md` §3.7).

**The denominator is `R`, the runs executed, and only `VOID` reads `R_usable`.** "Usable" is
outcome-dependent — a run that fired is usable whatever its counters say — so a usable-run
denominator would report `Always` for a row that fired in only some runs, while a pool with
no usable run measured nothing at all: an absence of data, not a non-observation. `R_usable`
is scored through `het_verdict()`, so every disqualifier of §3 is inherited.

**Corroboration layers on top and suppresses nothing.** `het_verdict()` still returns
`OBSERVED` on the first sighting; the tier says only in how many independent runs it
reproduced (`HET_CORROB_RUNS`), not how often. A sighting from a degenerate run
(`het_run_degenerate`: nothing scored, or a readout that did not vary [Srivastava24 §4.1]) is
reported and does not count toward corroboration: *is the sighting real?* and *is it
reproducible?* are two questions with two answers.

**One stop rule for every row**, because no row carries a prediction to schedule against and
which shape is stubborn is a property of the part, not of the shape [Kirkham20 §4.2 Tab.6].
The policy in it: a lone clean sighting holds the row open for `HET_CONFIRM_RUNS` runs counted
from the run it fired in — outranking the budget stop, since ending at the budget would bank
"seen once, stopped looking" — and then stops `UNCONFIRMED-SIGHTING`, neither a null nor a
corroboration; `HET_RATE=1` turns the sighting stop off, so a row that fires yields a rate.

One invocation's loop is bounded by the compiled `NUMBER_OF_RUN`, so a window past it ends the
loop while the rule still says `CONTINUE`; `hetlitmus/campaign.py` applies the same rule over
a row's pooled runs, re-invoking with a fresh seed base each time (a replayed seed adds no new
draw and is not a replicate), and ends a row whose pooled `usable` is 0 `ERROR` — the `VOID`
case at the pooled scale. Budget and window stack on one row, so a row costs up to
`--budget-runs + --confirm-runs`; a `--budget-runs` at or below `NUMBER_OF_RUN` finishes a
null row inside one invocation, so pooling engages only above it.

## 6. Every atom of the condition is a histogram column

A register atom and a coherence-final `[ell]=v` atom are both outcome columns, read from
iteration `n`'s register buffer or location slot and compared by the compiled condition
alike; there is no separate witness, and the discard precedes the score, so a discarded
iteration feeds neither the histogram nor `target_count`. What the condition compiler refuses,
and the one thing it does not check, is `het-emission.md`, "Scope / limits".

## 7. The flag words are a wire format

`flags=0x…` on a `HetStats` line is read back from transcripts that cannot be re-decoded
later, so a retired bit is left vacant rather than closed up: add at the top, never renumber.
The `HetStats` machine line's field set is a wire format too: `hetlitmus/campaign.py` reads
it by key (`R`, `usable`, `k`, `k_eff`, `first_sight`, `scored`, `discarded`, `flags`) and
ORs the flag words across a row's invocations, so a field a consumer reads must be one
`het_stats_line` prints.
