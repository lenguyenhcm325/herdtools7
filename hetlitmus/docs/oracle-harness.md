# Oracle-comparison harness (HetLitmus Tier 4, comparison axis)

`hetlitmus/oracle-compare.sh` reads the verdicts litmus7 prints after running
tests and compares each against a **reference oracle CSV passed explicitly**,
emitting one of three results per test: **MATCH**, **MISMATCH**, or
**NO-ORACLE**. This is the comparison half of Tier 4; the generation half is
`het-generation.md`.

The harness deliberately does **not** run anything on hardware or in gem5 — that
is **Task 9** and is out of Tier-4 scope. It consumes *Observation lines* (real,
from a future hardware/gem5 run, or synthesized) and an oracle CSV, and decides
conformance.

## 1. Inputs

**Observation lines.** litmus7 prints, per test, a line of the form
(`litmus/skelUtil.ml:1010`, `litmus/KSkel.ml:830`):

```
Observation <name> <Never|Sometimes|Always> <count_target> <count_other>
```

`Never` means the `exists` outcome under test was never observed across all
iterations; `Sometimes`/`Always` mean it was observed. The harness keys on the
first three fields and ignores the counts and any other log lines.
`tests/het/sample-observations.txt` is a **synthesized** sample (clearly marked)
that drives every branch.

**Oracle CSV.** Columns `Litmus,Expected,Model,Source`; `#` comment lines and the
header are skipped. The reference shipped here is
`tests/gpu-only/expected-amd-gcn3.csv`, the PLDI'23 artifact's gem5 `GCN3_X86`
oracle = **AMD GCN3 GPU + x86 CPU**, with `Expected ∈ {Allowed, Disallowed}`.

## 2. Why NO-ORACLE is a first-class result

The PLDI'23 `expected.csv` is an **AMD oracle only** (gem5 has no NVIDIA GPU
model). It grounds the GPU-only AMD corpus, but the **heterogeneous GH200 tests**
(AArch64 CPU + PTX GPU, e.g. `MP-het`, `SB-het`) have **no oracle yet** — a
separate `expected-nvidia.csv` must be derived from the NVIDIA PTX model (an open
question for the GH200 reference model). The harness therefore refuses to assume
a verdict for a test it cannot ground: a test absent from the supplied CSV is
**NO-ORACLE**, not a silent pass. This keeps the AMD-grounded results honest and
makes the missing NVIDIA oracle visible per test rather than hidden.

## 3. Comparison semantics

The only **hard contradiction** in litmus methodology is observing a *forbidden*
outcome. An *allowed* relaxation that simply is not exhibited on a given run is
consistent with the model (it *may* happen). Hence:

| Oracle `Expected` | Observation        | Result    | Note                     |
|-------------------|--------------------|-----------|--------------------------|
| `Disallowed`      | `Never`            | MATCH     | forbidden, not seen      |
| `Disallowed`      | `Sometimes`/`Always` | MISMATCH | FORBIDDEN OUTCOME SEEN (violation) |
| `Allowed`         | `Sometimes`/`Always` | MATCH    | relaxation seen          |
| `Allowed`         | `Never`            | MATCH     | allowed, not exhibited   |
| *(absent)*        | any                | NO-ORACLE | not in this oracle (GH200/PTX?) |

The harness exits **1 if any MISMATCH** (so it is CI-usable) and **0** otherwise;
the table prints regardless of exit status.

## 4. Usage and example

```
./oracle-compare.sh <observations-file> <oracle-csv>
```

Running the synthesized sample against the AMD oracle:

```
$ ./hetlitmus/oracle-compare.sh \
      hetlitmus/tests/het/sample-observations.txt \
      hetlitmus/tests/gpu-only/expected-amd-gcn3.csv

TEST           OBSERVED   ORACLE       MODEL          RESULT     NOTE
----           --------   ------       -----          ------     ----
MP-sys         Sometimes  Allowed      AMD-GCN3-x86   MATCH      relaxation seen
MP-sys-F       Never      Disallowed   AMD-GCN3-x86   MATCH      forbidden, not seen
IRIW-sys-F     Never      Disallowed   AMD-GCN3-x86   MATCH      forbidden, not seen
SB-sys-F       Sometimes  Disallowed   AMD-GCN3-x86   MISMATCH   FORBIDDEN OUTCOME SEEN
MP-het         Sometimes  -            -              NO-ORACLE  not in this oracle (GH200/PTX?)
SB-het         Never      -            -              NO-ORACLE  not in this oracle (GH200/PTX?)

6 test(s): 3 MATCH, 1 MISMATCH, 2 NO-ORACLE
```

The AMD GPU-only tests are grounded by the AMD oracle (MATCH, and the planted
`SB-sys-F` violation surfaces as MISMATCH); the heterogeneous GH200 tests come
out NO-ORACLE because the AMD CSV does not cover AArch64+PTX. To validate the AMD
side end to end on real hardware, point `<observations-file>` at an MI300A
litmus7 log (caveat: MI300A is CDNA3, several generations past GCN3 — confirm,
don't assume); to ground the GH200 het tests, supply an `expected-nvidia.csv` as
the oracle once one exists.

## 5. Files

| File | Purpose |
|------|---------|
| `hetlitmus/oracle-compare.sh` | the harness (awk: load CSV, classify each Observation) |
| `hetlitmus/tests/het/sample-observations.txt` | synthesized sample driving MATCH/MISMATCH/NO-ORACLE |
| `hetlitmus/tests/gpu-only/expected-amd-gcn3.csv` | the AMD-GCN3 reference oracle (existing) |
