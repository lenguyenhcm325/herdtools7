# Oracle-comparison harness (HetLitmus Tier 4, comparison axis)

**This is an OPTIONAL, OFFLINE, POST-RUN step, and nothing in the toolchain
requires it.** The emitted harness holds no prediction: it reports what it
observed and what vouched for the harness that did not observe it
(`positive-control.md`), and no verdict enters the emitter, the record or the
runtime. Comparing a row against expected verdicts is therefore something a
*reader* chooses to do afterwards, against a CSV **they** supply — and the
comparison inherits whatever that CSV is worth. This file describes that step.

`hetlitmus/oracle-compare.sh` reads a litmus7 run log and compares each
observation against a **reference verdict CSV passed explicitly**, emitting one of
four results per test: **MATCH**, **MISMATCH**, **NO-ORACLE**, or
**UNINTERPRETED**. This is the comparison half of Tier 4; the generation half is
`het-generation.md`.

The harness deliberately does **not** run anything on hardware or in gem5. It
consumes *Observation lines* (real, from a hardware/gem5 run, or synthesized) and a
verdict CSV, and decides conformance. It is a pure text function, which is why it
can be gated on frozen fixtures with no toolchain at all.

The two het CSVs in `tests/het/` are **not** an input any tool reaches for: they are
inert data left by the retired per-test derivation effort (branch
`hetlitmus-oracle-derivation`), and their own headers say so. Nothing reads them.

## 1. Inputs

**Observation lines.** litmus7 prints, per test, a line of the form
(`litmus/skelUtil.ml:1010`, `litmus/KSkel.ml:830`):

```
Observation <name> <Never|Sometimes|Always> <count_target> <count_other>
```

For an `exists` test, `Never` means the outcome under test was never observed
across all iterations; `Sometimes`/`Always` mean it was observed. The harness
keys on the first three fields and ignores the counts and any other log lines.
`tests/cram/obs.txt` is a **synthesized** sample (clearly marked) that drives
every branch.

**Condition lines (quantifier recovery).** litmus7 also prints, immediately
*before* each Observation, a line naming the test's quantifier
(`litmus/skelUtil.ml:949`):

```
Condition <exists|forall|~exists> (...) is [NOT ]validated
```

This matters because litmus reports `Never|Sometimes|Always` relative to the
test's *validation* and, for a `forall` test, swaps the `p_true`/`p_false` roles
internally (`litmus/skelUtil.ml:1000-1013`). So for `forall`, `Never` is the
**mirror image** of `exists`: it means the targeted predicate held in *every*
execution (no counterexample), not that it was never seen. The harness stashes
the quantifier from each `Condition` line and applies it to the next
`Observation`; `~exists` reads like `exists` (only `forall` flips). A log with
no `Condition` lines defaults to `exists`, so older logs classify exactly as
before.

**Oracle CSV.** Columns `Litmus,Expected,Model,Source`; `#` comment lines and the
header are skipped. The reference shipped here is
`tests/gpu-only/expected-amd-gcn3.csv`, the PLDI'23 artifact's gem5 `GCN3_X86`
oracle = **AMD GCN3 GPU + x86 CPU**, with `Expected ∈ {Allowed, Disallowed}`.

## 2. Why "the CSV does not decide this" is a first-class result

The PLDI'23 `expected.csv` is an **AMD oracle only** (gem5 has no NVIDIA GPU
model). It grounds the GPU-only AMD corpus and nothing else; the **heterogeneous
tests** (e.g. `MP-het`, `SB-het`) are outside it entirely. The harness therefore
refuses to assume a verdict for a test the supplied CSV cannot ground, and it
distinguishes the two ways that happens, because they are different facts:

* the CSV **has** the row and writes `NO-ORACLE` — *earned model silence*, a
  decision not to decide;
* the CSV **does not have** the row at all — **UNINTERPRETED**, no frame for this
  test, never a silent pass and never model silence.

Aliasing them is how a run whose corpus the CSV never covered would have printed as
model silence on every row. Which of the two a reader is looking at is the whole
point of supplying a CSV rather than assuming one.

## 3. Comparison semantics

The only **hard contradiction** in litmus methodology is observing a *forbidden*
outcome. An *allowed* relaxation that simply is not exhibited on a given run is
consistent with the model (it *may* happen). The harness reduces each Observation
to a single boolean — **was the oracle's targeted predicate witnessed?** — and
that reduction is where the quantifier enters: for `exists`/`~exists` it is
`obs ≠ Never`, for `forall` it is `obs = Never` (the inversion above). The
classification then keys on that boolean (`seen`):

| Oracle `Expected` | `seen` (predicate witnessed) | Result    | Note                  |
|-------------------|------------------------------|-----------|-----------------------|
| `Disallowed`      | no                           | MATCH     | forbidden, not seen   |
| `Disallowed`      | yes                          | MISMATCH  | FORBIDDEN OUTCOME SEEN (violation) |
| `Allowed`         | yes                          | MATCH     | relaxation seen       |
| `Allowed`         | no                           | MATCH     | allowed, not exhibited |
| `NO-ORACLE`       | —                            | NO-ORACLE | earned model silence: the CSV has the row and declines to decide it |
| *(absent)*        | —                            | UNINTERPRETED | no frame for this test at all — never model silence |
| *(unknown word)*  | —                            | UNINTERPRETED | a corrupt oracle, never a pass |

Concretely, for a `Disallowed` oracle the **same** observation flips verdict by
quantifier: `exists … Never` → MATCH but `forall … Never` → MISMATCH, and
`exists … Sometimes` → MISMATCH but `forall … Sometimes` → MATCH. The output
table carries a `QUANT` column so this is legible per row.

The harness exits **1 if any MISMATCH** (so it is CI-usable) and **0** otherwise;
the table prints regardless of exit status.

## 4. Usage and example

```
./oracle-compare.sh <observations-file> <oracle-csv>
```

Running the frozen cram fixtures — a synthesized log and a hand-authored oracle,
paired so that one run drives every result class:

```
$ cd hetlitmus && ./oracle-compare.sh tests/cram/obs.txt tests/cram/oracle.csv

Oracle:       tests/cram/oracle.csv
Observations: tests/cram/obs.txt

TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT         NOTE
----           -----   --------   ------       -----          ------         ----
SB-sys         exists  Sometimes  Allowed      PTX            MATCH          relaxation seen
MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
LB-sys         exists  Never      -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
SB-sys-fa      forall  Sometimes  Disallowed   PTX            MATCH          forbidden, not seen
MP-sys-fa      forall  Never      Disallowed   PTX            MISMATCH       FORBIDDEN OUTCOME SEEN -- indicts THIS ORACLE ROW first not the CMCM
LB-sys-fa      forall  Sometimes  -            -              UNINTERPRETED  ABSENT from this oracle -- no frame for this test (never model silence)
WS-sys         exists  Sometimes  NO-ORACLE    PTX            NO-ORACLE      model silence: this oracle makes no claim here
BOGUS-sys      exists  Never      ?            -              UNINTERPRETED  unknown oracle verdict "Perhaps"

8 test(s): 2 MATCH, 2 MISMATCH, 1 NO-ORACLE, 3 UNINTERPRETED
```

Every row carries a `Condition` line, so `QUANT` is populated and the `forall`
inversion of §3 is driven: `MP-sys-fa` is `Disallowed` and `Never`, which under
`forall` means the forbidden predicate held in every execution — MISMATCH —
while its `exists` counterpart would read as "forbidden, not seen". The fixture
also drives the three ways an oracle can fail to decide: the `LB-*` rows are
absent from the CSV, `WS-sys` is present and declines, and `BOGUS-sys` carries a
verdict string the harness does not know, which fails closed rather than
passing. `tests/cram/oracle-negatives.t` pins this run.

To validate the AMD side end to end on real hardware, point
`<observations-file>` at an MI300A litmus7 log and `<oracle-csv>` at
`tests/gpu-only/expected-amd-gcn3.csv` (caveat: MI300A is CDNA3, several
generations past GCN3 — confirm, don't assume).

## 5. The statistics section

A log from a real het harness also carries `HetStats` lines (`het_verdict.h`,
`het_stats_line` + `het_stats_print`). When it does, a second section follows the
table: for each test, its `RESULT` from the table, then **`het_stats_print`'s own
block reprinted verbatim** — what the null is worth, its dispersion, its
within-run correlation reading, its bound and its budget. The interpretation is
written once, in C, beside the numbers it belongs to; the harness does not
re-derive it, because a second implementation of the same decode is what silently
drifts from the first.

What the section adds on top of the reprint is the campaign-level roll-up: the
negative control over the rows **the supplied CSV** marks `Disallowed` (PerpLE VII-A —
if the decoder invented cycles, that is where it would show), plus counts of the
`VOID` rows and of the nulls whose bound came out ≥ 1 and so bounds nothing. The class
is read from the CSV on every row, because the run log carries none: a harness that
printed its own class would make this roll-up a check of the emitter against itself.

A log without `HetStats` lines prints the table alone. Both paths are pinned by
`hetlitmus/tests/cram/oracle-negatives.t`.

## 6. Files

| File | Purpose |
|------|---------|
| `hetlitmus/oracle-compare.sh` | the harness (awk: load CSV, classify each Observation) |
| `hetlitmus/tests/cram/obs.txt` + `oracle.csv` | synthesized fixture pair driving every result class (§4) |
| `hetlitmus/tests/gpu-only/expected-amd-gcn3.csv` | the AMD-GCN3 reference oracle (existing) |
| `hetlitmus/tests/cram/obs-stats.txt` | frozen log carrying real `HetStats` lines, one per reporting path |
| `hetlitmus/tests/cram/oracle-stats.csv` | the oracle that fixture is compared against |
