# The NVIDIA GH200 het oracle (`expected-nvidia.csv`)

`hetlitmus/tests/het/expected-nvidia.csv` is the reference oracle for the
**heterogeneous** corpus on the **GH200 Grace-Hopper** target: an **ARMv9 Grace
CPU + a Hopper GPU running PTX**, i.e. the **NVIDIA-PTX-AArch64 compound memory
model**. It is the NVIDIA counterpart to the AMD/x86 GPU-only oracle
`tests/gpu-only/expected-amd-gcn3.csv`, and it is what makes the het tests
something other than `NO-ORACLE` in `oracle-compare.sh`.

The verdicts are **derived, not measured** — this step is hardware-free (running
the tests on a GH200 is Task 9). Every row is grounded in one of three primary
sources; no verdict is guessed, and every row carries its grounding in the
`Source` column. Columns mirror the AMD file exactly: `Litmus,Expected,Model,
Source`, with `Model = NVIDIA-PTX-AArch64`.

## Provenance (the three sources)

- **[CMCM]** Goens, Chakraborty, Sarkar, Agarwal, Oswald, Nagarajan, *Compound
  Memory Models*, PLDI'23. A heterogeneous machine's model is the
  **compositional amalgamation** of its devices': each thread keeps its own
  device's ordering rules, and a cross-device outcome is forbidden only when
  **both** sides supply a morally-strong synchronisation. Their MP example
  (Fig 2a) forbids the weak outcome on x86TSO/PTX **because the x86 consumer
  orders its two loads for free** — and the paper explicitly adds: *"the
  consumer thread would have needed an acquire or a stronger fence in a memory
  model such as PTX."*
- **[PTX]** Lustig, Sahasrabuddhe, Giroux, *A Formal Analysis of the NVIDIA PTX
  Memory Consistency Model*, ASPLOS'19. PTX is a **scoped, weakly-ordered
  (Release-Consistency)** model. Two ops are **morally strong** iff both are
  *strong* (`.relaxed`/`.acquire`/`.release`/fence) **and** each op's scope
  encompasses the *thread* executing the other (§3.3); `.sys` scope includes the
  host CPU; `.cta`/`.gpu` do not reach it. PTX is **not multi-copy-atomic**.
- **[Bagchi]** Bagchi, Srivastava, Levine, Sorensen, Stutsman, Nagarajan,
  *Consistency and Coherence of the NVIDIA Grace-Hopper Superchip*, ISMM'26.
  The **empirical** GH200 study. ARMv9 Grace is **relaxed RC** and its *unscoped*
  ops are treated as **system-scope**. Across 1,960 MP variants, **weak
  (relaxed) behaviours were observed on hardware exactly when a morally-strong
  sys-scope release/acquire pair was absent** — i.e. an **asymmetric** pairing
  (one side plain/relaxed; Table 4 rows 16-18) or a **narrow** `cta`/`gpu` scope
  (rows 3-5, 21-22). Only fully morally-strong sys-scope rel/acq pairs showed no
  weak behaviour. The **ARM-MCA × PTX-non-MCA interaction (IRIW) is explicitly
  left for future work** (§4.2). (RMWs over-synchronise vs spec — irrelevant
  here: the corpus has no RMW.)

## The labelling rule (and why it overrides the naive heuristic)

The het generator annotates **only GPU procs**; **CPU procs are always plain
ARMv9** (the generator *drops* any order column that would land on a CPU proc —
see `corpus-grid.md`, "het drops 69"). ARMv9 plain `ld`/`st` impose **no**
ordering on the tests in this corpus (different addresses, no dependencies, no
same-address coherence pair). So a GPU sys-scope `acquire`/`release`/fence on one
proc can **never complete the morally-strong release/acquire pair** that the
CMCM requires to cut a message-passing cycle: the *other* ordering-critical proc
is a plain CPU thread that contributes nothing.

A targeted (relaxed) outcome is therefore **forbidden on GH200 iff** every proc
that must carry an intra-proc ordering does so, where a **GPU** proc qualifies
only with a **sys-scope** annotation matching the needed pair, and a **CPU** proc
**never** qualifies — **and**, for the multi-copy-atomicity-dependent shapes, the
system is MCA. Concretely:

| column / case | verdict | why |
|---|---|---|
| `relaxed` (any scope) | **Allowed** | no synchronising op at all |
| `cta` scope (any order) | **Allowed** | scope too narrow to encompass the CPU — not morally strong (Bagchi r3-5) |
| `gpu` scope (any order) | **Allowed** | excludes the CPU thread — not morally strong (Bagchi Fig 4e, r21-22) |
| `sys` + rel/acq/fence, **2-proc** (MP SB LB 2+2W R S) | **Allowed** | the one CPU proc of the cut is plain ARMv9 → pair incomplete (Bagchi Tab 4; CMCM Fig 2a) |
| `sys` + rel/acq/fence, **3/4-proc** (WRC RWC ISA2 WRC3, IRIW cuts cgcc/cgcg/gccc) | **Allowed** | ≥1 ordering-critical proc sits on a plain ARMv9 CPU → chain not closed |
| `sys` + `acquire`/`fence`, **IRIW-gcgc** | **NO-ORACLE** | see below |

**This deliberately overrides the naive heuristic** "MP/WRC/S/ISA2 with sys
rel/acq ⇒ Disallowed." That heuristic is correct only when the CPU is **x86TSO**
(as in the PLDI'23 AMD/x86 oracle), because x86 loads/stores are *implicit*
acquire/release and silently supply the missing half of the pair (CMCM Fig 2a).
**The GH200 CPU is ARMv9, not x86**, so that half is genuinely absent — and
Bagchi observed the corresponding weak behaviours on real hardware (Table 4).
This is exactly why a separate NVIDIA oracle is needed and why it must **not**
reuse the AMD CSV.

### Consequence: this corpus forbids nothing on GH200

Every het cut leaves at least one ordering-critical proc on the plain ARMv9 CPU,
so **279/281 tests are `Allowed`** and the oracle contains **no `Disallowed`
rows** (a MISMATCH is therefore impossible against it — no observation can
contradict a verdict that forbids nothing). This is a real finding, not a gap:
to obtain a *forbidden* het outcome the generator would have to annotate the CPU
procs too (ARM `STLR`/`LDAR`/`DMB`), completing the morally-strong pair — a
worthwhile future extension, currently out of scope.

## The two NO-ORACLE tests

`IRIW-gcgc-sys-acquire` and `IRIW-gcgc-sys-fence` are the **only** tests left
`NO-ORACLE`. `IRIW-gcgc` is the unique cut in the whole corpus where **both
ordering-critical procs are GPU**: in this corpus IRIW's readers are P0 and P2
(two reads each) and its writers are P1 and P3 (one write each), and `gcgc` puts
**both readers on the GPU** (writers on the CPU). With `sys`-scope `acquire` (or
the `sys` fence) on both readers, the **reader-ordering half is present** — the
one configuration where it is.

But IRIW is forbidden only if the reader ordering is combined with
**multi-copy atomicity**: a single global order of the two writes seen by both
readers. Here the writers are ARM (MCA among themselves) but the readers are PTX,
and **PTX is non-MCA** (so it *permits* IRIW), while whether the ARM writes
propagate atomically to the GPU readers across NVLink-C2C is precisely the
**ARM-MCA × PTX-non-MCA interaction that Bagchi explicitly leaves for future
work** (§4.2; CMCM Fig 3 calls it out as "rais[ing] more questions"). Neither
`Allowed` nor `Disallowed` is grounded in the three sources, so honesty demands
`NO-ORACLE`. (`IRIW-gcgc-sys-relaxed` is `Allowed` — readers unordered; the
`cta`/`gpu` variants are `Allowed` — scope too narrow to reach the CPU writers;
`release` is not generated for `gcgc` because it would land on the CPU writers.)

## Reproduce / verify

```sh
cd hetlitmus/tests/het
# 1. exactly one row per .litmus, no file missing, no extra/dup
ls *.litmus | wc -l                                           # 281
grep -vE '^#|^Litmus,' expected-nvidia.csv | wc -l            # 281
diff <(ls *.litmus | sed 's/\.litmus$//' | sort -u) \
     <(grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f1 | sort -u)   # empty

# 2. verdict tally
grep -vE '^#|^Litmus,' expected-nvidia.csv | cut -d, -f2 | sort | uniq -c
#   279 Allowed   2 NO-ORACLE

# 3. drive the harness (synthesized, hardware-free)
cd ../../..
./hetlitmus/oracle-compare.sh \
    hetlitmus/tests/het/sample-observations-nvidia.txt \
    hetlitmus/tests/het/expected-nvidia.csv             # MATCH/NO-ORACLE table, exit 0
```

## Files

| File | Purpose |
|------|---------|
| `tests/het/expected-nvidia.csv` | the NVIDIA GH200 het oracle (this doc) |
| `tests/het/sample-observations-nvidia.txt` | synthesized log driving the harness against it |
| `tests/gpu-only/expected-amd-gcn3.csv` | the AMD/x86 oracle (do **not** reuse for NVIDIA) |
| `oracle-compare.sh` | the comparison harness (unchanged) |
