# HetLitmus — Test Plan & Spec

**Status as of 2026-07-06.** Living document. Captures the design decisions and
the empirical findings they rest on. `✓` = exists today, `○` = to build. **Build
status: Layers 1–3 + Makefile wiring are COMPLETE, and Layer 4's wiring ships with it
(gated CUDA-free by `hetlitmus-run-gate`); what remains for Layer 4 is the hardware —
the measurements, not the machinery.**

## 0. Goals

Two distinct guarantees for the toolchain (the "black box": generator → GPU/CPU
codegen → harness emission → checkers):

- **No regression** — pin what the tools produce today and shout if it changes.
  Needs *no understanding of the code*. → **golden-master**.
- **Works as expected** — assert observable properties against an *independent*
  notion of correct, so a bug that is already baked in gets caught. → **unit /
  contract / faithfulness / negative-control** tests.

A golden-master faithfully reproduces a bug forever, so both are required. The
gap between them is where bugs hide.

---

## 1. Findings this session (the evidence the plan rests on)

All verified on the dev box (has `dune`/`ocaml`, `herd7`/`litmus7`/`hetgen7`/
`diyone7` built in `_build`, `nvcc`, and an RTX 3060 = sm_86).

- **Generation is byte-reproducible.** Re-running `tests/gpu-only/generate.sh`
  (173) and `tests/het/generate.sh` (471) reproduces the committed `.litmus`
  corpus with **zero diff** (`git status --short` empty). Het ~6.8 s.
  → golden-master via `git diff` is viable and nearly free.
- **Emitters are byte-reproducible.** Re-emitting the 10 committed `cuda-out/*.cu`
  samples is byte-identical (modulo the `//` banner).
- **Compilation needs `nvcc`+`clang` but NOT a GPU.** Proved by compiling with
  **all GPUs hidden**, targeting an arch the box does not have:
  `CUDA_VISIBLE_DEVICES="" nvcc -std=c++17 -arch=sm_90 --ptx|-c <t>.cu` → exit 0;
  `clang --target=aarch64-linux-gnu -c <t>_cpu.c` → exit 0. `-arch` is a compile
  target, not a device requirement. **Only *launching* a kernel needs a GPU.**
- **`comp.sh` already IS a compile-smoke.** Every emitted het dir ships one; it
  runs `gcc -c outs.c`, `gcc -c <t>_cpu.c` (host), `clang --target=aarch64-linux-gnu
  -c <t>_cpu.c` (real AArch64), `nvcc -std=c++17 -arch=sm_90 -c <t>.cu`, under
  `set -e`, printing `HetLitmus: compile OK`. Verified exit 0 with GPUs hidden.
  → compile-smoke needs *no new build code*, just a driver that runs `comp.sh`.
- **`ptxcheck.py` has discriminating power.** Honest PTX → `RESULT: PASS` (exit 0);
  a one-token corruption (`st.release.sys`→`st.acq_rel.sys`) → `RESULT: FAIL`
  (exit 1) with an exact diff. Its `--ptx`/`--cpu-c` self-test seam means the
  **negative controls run with no GPU** (feed a frozen corrupted PTX).
- **`oracle-compare.sh` is a pure text function** (obs file + oracle CSV → table +
  exit 0/1). Trivially testable on frozen fixtures; no toolchain.
- **`_grid_lib.sh` is pure functions** (`render_cycle`, `render_cpu_cycle`,
  `cut_tag`, `scope_tree`, `arm_ord`, …) — unit-testable, and they encode the
  load-bearing model decisions (release→writes, acquire→reads, LDAPR=RCpc
  acquire, fence→standalone scoped fence / DMB.SY).

### Current state of `hetlitmus/verify/` against this plan
- **Layer 3 faithfulness: ✓ and gated.** `tokens.sh all` sweeps all 644 via
  `nvcc --ptx` + `ptxcheck`, returning nonzero on any FAIL.
- **Layer 1 negatives: now gated (`c2e4df4c5`).** `tokens.sh selftest` (weaken
  order/scope, miscount, CPU STLR→STR) and `guard` (unknown-token → exit 2) are real
  injections that now **aggregate and return nonzero**, printing `SELFTEST OK` /
  `GUARD OK` sentinels. The eyeball gap is closed in the shell; the Layer-1 cram
  `ptx-negatives.t` now only **byte-freezes** that output (belt-and-suspenders), it
  is no longer the sole gate.
- Missing entirely: Layer-1 unit tests, `oracle-compare` negatives, Layer-2
  golden gate.

---

## 2. The 4 layers

Consolidated from an earlier six-layer cut; nothing was dropped. Boundary
between layers = the heaviest tool you must install to run it: **nothing →
OCaml build → CUDA → GPU.**

| Layer | Checks | Mechanism | Needs | Runs |
|---|---|---|---|---|
| **1 Static** | rule-fns as spec (unit); checker discriminating-power (negatives) | dune **cram** | bash/python | anywhere, ms |
| **2 Generate** | corpus + emission regression golden; parse-smoke; census | **git-diff** + make | `make build` | local/CI, ~10 s |
| **3 Compile** | PTX faithfulness (all 644); compile-smoke (11 reps) | shell drivers | nvcc+clang, **no GPU** | local / CI-with-CUDA, ~min |
| **4 Hardware** | behavioral characterization; positive controls; the stationarity gate + the stop rule | `hetlitmus-run.sh` + `campaign.py` | **GH200** | manual, off-CI |

Goal mapping: **regression = Layer 2** (goldens); **works-as-expected = Layers 1,
3, 4** (spec units, faithfulness, negatives, behavioral).

Pre-commit gate = Layers 1–3 (all local, none need a GPU). Layer 4 is GH200-only.

### Coverage map — where "all the good cases" live

Exhaustive good-case coverage is the **goldens' job, not the cram's.** The good-case
enumeration is *defined* by the grid knobs in `_grid_lib.sh` (`SHAPE_ORDER` ×
`GRID_SCOPES` × `GRID_ORDERS`, plus het `SHAPE_HET_CUTS` × `TWO_SIDED_ORDERS`) and
*materialized* as the committed corpus (**173 gpu-only + 471 het**). It is asserted
exhaustively over **all 644** by:

| What is checked over ALL 644 | Layer |
|---|---|
| byte-pinned (regression) | 2 golden (regenerate out of tree + byte-diff) |
| PTX/asm matches its annotation (faithfulness) | 3 (`tokens.sh all`) |
| compiles | 3 (faithful `nvcc --ptx` + smoke) |
| enumeration didn't silently shrink | 2 census (counts 173/471, `@all`) |

The rule functions (`render_cycle`, …) get exhaustive coverage *transitively* — the
corpus **is** their output across the full grid, so the Layer-2 golden pins every
good-case result. **The cram is therefore a curated sample, not a matrix:** it
documents the rules readably (`basics.t`, ~10 lines, one per rule branch) and pins
the checkers' discriminating power (`*-negatives.t`). The only cram file worth making
exhaustive is `oracle-negatives.t`, whose decision logic no golden covers.

---

## 3. Mechanism decision (what we use, and what we deliberately do NOT)

Three golden mechanisms, each matched to a layer by shape of the check:

| Mechanism | Used for | "Promote" (update golden) = | Why it fits |
|---|---|---|---|
| **dune cram `.t`** | Layer 1 units + negatives | `dune promote` | each is one command → exact stdout/exit |
| **git-diff** | Layer 2 corpus/emission golden | `git commit` | 644 byte-stable files; git already is the store + promote |
| **shell drivers** (`tokens.sh`, new `smoke.sh`) | Layer 3 sweeps | n/a (pass/fail) | directory sweeps / multi-step |
| (none) | Layer 4 | n/a | nondeterministic, hardware |

**Cram in one line:** a `.t` is `  $ command` followed by its frozen expected
output (stdout+stderr merged, plus nonzero exit as `[N]`). `dune runtest` does a
line-exact diff; `dune promote` overwrites the expected block with current output.
Author = write command, `dune promote`, then **eyeball** that the captured golden
is what you *wanted*.

**Not used:** the `.expected` + `REGRESSION_TEST_MODE` OCaml-driver idiom. Its one
advantage over git-diff is *normalization* (order-insensitive/derived comparison);
our generation is byte-stable so we don't need it.

---

## 4. Layer-by-layer contents

### Layer 1 — Static (cram; no toolchain)
- ✓ `basics.t` (`0d5940b5e`) — executable spec of `_grid_lib.sh`: **~10 lines, one per rule branch,
  NOT the 168-cell grid** (that is the Layer-2 golden's job). Cover the 4
  `render_cycle` orders (relaxed/acquire/release/fence, varying scope so all of
  Sys/Gpu/Cta appear), the 2 `render_cpu_cycle` orders (acqrel→STLR `L`/LDAPR `Q`,
  fence→`DMB.SYd*`), `cut_tag` (2- and 3-proc), `scope_tree` (2- and 3-proc). Exact
  list + real outputs in Appendix B. (Optional +2: unit `arm_ord R/W acqrel`→`Q`/`L`
  to pin the atom mapping directly.)
- ✓ `oracle-negatives.t` (`0d5940b5e`) — the **offline** `oracle-compare.sh` on frozen
  fixtures. This one is **exhaustive**: the full decision matrix **{MATCH, MISMATCH,
  NO-ORACLE, UNINTERPRETED} × {exists, forall}** in one run (no golden covers this
  logic; the `forall` quantifier inversion is subtle, and a test the CSV *has and
  declines* must not read like one the CSV does not have at all). Any MISMATCH → exit 1.
  A second fixture (`obs-stats.txt`, carrying `HetStats` lines printed by
  `het_verdict.h` itself) drives the statistics section: that `het_stats_print`'s block
  arrives verbatim — all four sentences of a null: that no rate is attached to it, which
  control vouched, that the row is characterization and agrees with no model, and the
  effort behind the zero — and that the campaign roll-up (negative control, VOID)
  counts it. Every `ORACLE` column there is read from the CSV — the run log carries no
  class of its own.
- ✓ `ptx-negatives.t` (`0d5940b5e`) — `ptxcheck --ptx <frozen-corrupt.ptx>` → exit 1 (no GPU). A
  thin **byte-freeze** of one corruption; the eyeball gap is already closed in the
  gated `tokens.sh selftest` (`c2e4df4c5`), so this is belt-and-suspenders.
- (optional, lower priority) unit-test `ptxcheck.py` parsers (`classify_ptx_op`, …).

### Layer 2 — Generate (git-diff + make; OCaml build)
- ✓ `generate.sh` (both dirs), byte-stable.
- ✓ **golden gate** (`verify/corpus-gate.sh`, `6e92f2657`): regenerate into a temp
  tree (`generate.sh OUTDIR`), then fail on any name-set or byte difference against the
  committed corpus — added, removed and modified files are each named. `--bite` reddens it
  with a generator that writes nothing and with one tampered byte.
- ✓ emission golden (in `corpus-gate.sh`): 10 `cuda-out/*.cu` **and** 10 `hip-out/*.hip`
  samples are committed; `emit-cuda.sh` and `emit-hip.sh` each emit all 173 to a
  **temp dir** and each sample is diffed against its own lane — emitter drift = nonzero
  diff. One emission renders one vendor (`litmus/hetDialect.ml`), so the `.hip` lane is a
  second pass and not optional. (Not re-emitted in place: that would litter 163 untracked
  files per lane.)
- ~ parse-smoke (every `.litmus` emits without error) already comes free from the
  Layer-3 faithfulness sweep, which emits every test.
- ✓ census (in `corpus-gate.sh`): asserts counts 173/471. The extra per-test
  column-count / `@all` contracts remain optional (not implemented).

### Layer 3 — Compile (shell drivers; nvcc+clang, no GPU)
- ✓ faithfulness: `verify/tokens.sh all` (already gated).
- ✓ `comp.sh` per test (verified compiles no-GPU).
- ✓ `smoke.sh` (built, `fa2adc9db`): emit + compile the 11 reps (§5), fail on any
  nonzero. `nvcc --ptx` from faithfulness already covers gpu-only/het `.cu`, so smoke
  adds the het CPU side (clang AArch64) + `nvcc -c`/ptxas.

### Layer 4 — Hardware (GH200; later)
- ✓ **positive controls**: every row co-runs a control that must fire under stress, else
  the harness is dead and its "Never" is meaningless — `mu(T)`, the row's own structural
  twin at the lattice floor, on the 375 rows that have one, and the Layer-B canary on 469
  (`positive-control.md`).
- ✓ **run wiring**: `hetlitmus/hetlitmus-run.sh` (the device session) + `campaign.py`
  (cross-invocation pooling and the stop rule), gated CUDA-free by `hetlitmus-run-gate`.
- ✓ **the statistics**: the `(instance,run)` replication unit, the mandatory KS stationarity
  gate, `P_rep` on the observed side, and the corroboration stop rule (`het_verdict.h`;
  `hetlitmus-stats`). A null reports the control that vouched for it and the effort behind
  it; no rate and no probability is attached to what the harness did not see.
- ○ the numbers: every knob in `00-environment-design.md` §6 is measured on the target,
  not settled here.
- (optional, offline) `oracle-compare.sh` over the collected log, against a verdicts CSV
  the reader supplies. Not part of a run, and not required for one.

---

## 5. Compile-smoke spec (settled)

Single "before every commit" run — **no tiers, no nightly**. **Not all 644**
(gpu-only `.cu` already gets `nvcc --ptx` from faithfulness). Emit + compile **11
representatives** — 10 het via their `comp.sh cuda` and 1 het via `comp.sh hip` —
chosen to hit each distinct compile path once. `verify/smoke.sh` is the
authority: `NREPS` and the rep list in its header are the spec, and this table
mirrors them.

| # | Rep | Covers |
|---|---|---|
| 1 | het one-sided (`MP-cg-cta-acquire`) | plain CPU STR/LDR + barrier + `nvcc -c` |
| 2 | `*-acqrel-2s` (`2+2W-cg-sys-acqrel-2s`) | two-sided; CPU STLR (store-only shape: **no** load) |
| 3 | `*-acqrel-2s`, gc cut (`MP-gc-sys-acqrel-2s`) | the only rep emitting a CPU load-acquire (LDAPR, RCpc, `.arch_extension rcpc`) |
| 4 | `*-fence-2s` (`2+2W-cg-sys-fence-2s`) | CPU `DMB.SY` |
| 5 | 4-proc het (`IRIW-cgcc-cta-relaxed`) | largest barrier / proc count |
| 6 | 3-proc het (`WRC-ccg-cta-relaxed`) | 3-proc scaffolding — buys down the proc-scaling assumption |
| 7 | **HIP** render of `MP-cg-sys-relaxed-x86_64` (`comp.sh hip`) | the AMD/MI300A lane — the only rep here whose render is a `.hip`. `hipbuildcheck.py` compiles and links one too, and `amdisacheck.py` compiles all 644 device-only (`amd-faithfulness.md`). Missing `hipcc` ⇒ **SKIP, loudly**; never a pass |
| 8 | order pair (`MP-cg-sys-sy.acq-2s`) | the only rep emitting inline `fence.acquire.sys`; carries a compiled-in co-run control (μ = its lattice-floor sibling `MP-cg-sys-relaxed`); first rep whose name contains a `.` |
| 9 | order pair (`S-gc-sys-ra.rel-2s`) | the only rep emitting inline `fence.release.sys`, paired with CPU STLR/LDAPR; the largest co-run in the corpus (K=4, NPART=10) |
| 10 | order pair (`MP-cg-sys-st.sc-2s`) | the CPU `dmb st` form; its μ is the floor sibling, so the barrier is T's alone |
| 11 | order pair (`MP-gc-sys-ld.sc-2s`) | the CPU `dmb ld` form on the `gc` cut (the CPU proc reads); likewise T's alone |

Reps 8–11 are all off the lattice floor, so each also exercises the co-run control
(`HET_CONTROL_COMPILED_IN = 1`) on that family. Reps 10–11 claim only that the
three barrier forms **build**; *which* one is emitted is pinned by
`tokens.sh selftest [5b]`.

Tens of seconds total (last timed at the original 6 reps; not re-measured at 11).
Residual risk (11 reps ≠ proof all 644 build) is accepted once: the same gate
`nvcc --ptx`-compiles every one of the 644 via faithfulness, and the stages smoke
adds (ptxas / CPU clang / link) are near-constant across tests.

---

## 6. Makefile targets

Mirror herdtools7's `::` accumulation + `| build` order-only prereq + `@ echo OK`.
The second lane is `-toolchain`: a target joins it when it needs a compiler or a
device this box may not have, three of its members needing a real GPU (see below).
**✓ All targets wired into the top-level Makefile (`68d102ef5`).**

**The Makefile is the roster; this table mirrors it.** Re-read it with
`grep -E '^hetlitmus-[a-z0-9-]+:' Makefile` before trusting the list below.

Umbrellas (what you press):
- **`make hetlitmus-test`** → the CUDA-free lane: `hetlitmus-cram` · `-corpus` ·
  `-dup` · `-hipsrc` · `-verdict` · `-recfields` · `-stats` · `-hist` ·
  `-x86body` · `-x86fixture` · `-cpuonly` · `-run-gate`.
- **`make hetlitmus-test-toolchain`** (old name `hetlitmus-test-nvcc`, kept as an alias)
  → the toolchain lane: `hetlitmus-faithful` · `-stress` ·
  `-cpustress` · `-obs` · `-hipbuild` · `-amd-faithful` · `-characterize-hw` ·
  `-run-hw` · `-selftest` · `-smoke`. This lane has **outgrown Layer 3**: it still needs CUDA for the compile
  members, but three of them now need a real device — `-run-hw` and `-characterize-hw`
  run the wrapper and a built harness on the GPU, and `-stress`'s device-probe check drives
  `het_do_stress` on hardware to prove the tally is live both ways. The CUDA-free
  stand-in for the session wrapper (stub compiler, stub probe) is `hetlitmus-run-gate`,
  which is in the other umbrella.
- **`make hetlitmus-test-all`** → both. ← pre-commit gate on the dev box.
- **`make hetlitmus-promote`** → regenerate both corpora, then
  `dune test hetlitmus/tests/cram --auto-promote` (the cram dir only); does **not**
  commit; prints "review `git diff` then commit".

One building block is worth naming, because it exists for a failure no other gate can
see: `hetlitmus-recfields` pins the emitted `_rec.*` writes against `het_verdict.h`'s
members and the emitted `#define`s against its `#ifndef` defaults, which is the one skew
a CPU-only gate would otherwise miss.

**Seven targets were deleted, not renamed** — they derived or audited expected verdicts,
and the tool claims none: `hetlitmus-oracle`, `-nvroundtrip`, `-amd-oracle`, `-amdorder`,
`-amdprov`, `-nvprov`, `-nvanchor`. So was `-noracle`, together with the
`-allow-no-oracle` flag it gated. All of them live on with the retired
oracle-derivation lineage, outside this tree. **Four more went with the positive
control**, which is withdrawn: `hetlitmus-controlmap` and `-amd-controlmap` gated its
map, `-lattice` the ordering-strength lattice its siblings were selected on, and
`-tuner` the stress autotuner whose objective was its death rate. `hetlitmus-order`
had become `hetlitmus-lattice` and goes with it. One survivor moved rather than went:
`hetlitmus-noracle-hw` → `hetlitmus-characterize-hw` (the unregistered-pair
refusal became a warning, so what the gate reads off a real printout is the control
sentence, not a refusal).

**A gate that is not in the build is a script, not a gate — `hetlitmus-stats` is the
worked example.** `statscheck.py` once sat in the tree with **no Makefile target invoking
it**: on a build whose `ks_pass` was forced constant the script returned rc=1 while
`hetlitmus-test-all` returned rc=0, fully green.  Its phase 2 still refuses a stationarity
gate that only ever says one thing, and that refusal now reaches the build, because the
target is wired.  When a verify script lands, its target and its `hetlitmus-test` hookup
land **in the same commit**.

`hetlitmus-faithful` proves the harness carries **exactly the tested ops**; it is blind to
the **scaffolding** (stress carries no order/scope qualifier, so it is not a model op — by
design). `hetlitmus-stress` (`verify/stresscheck.py`) is the other half: it proves the stress
layer is **in the PTX at all**. It exists because the GPU scratchpad stress once shipped as
a pre-stress incantation whose traffic nvcc had hoisted clean out of the loop, and every
other gate stayed green.

Notes:
- `hetlitmus-corpus` compares a fresh out-of-tree regeneration against the committed corpus (catches add/remove/modify; writes nothing into the tree).
- GPU/nvcc targets are never wired into upstream `test::`. **Decided: hetlitmus targets
  stay standalone (not folded into `test::`) to keep the main suite fast + CUDA-free.**
- Layer 4 is `hetlitmus/hetlitmus-run.sh`, the device-session wrapper: run by hand on the
  machine under test and in no umbrella. Its gates are: `hetlitmus-run-gate` (CUDA-free,
  drives the whole chain against a stub compiler and a stub probe) and `hetlitmus-run-hw`
  (the same wrapper on a device).

Cram stanzas: `hetlitmus/tests/cram/dune` is the authority and is not mirrored here — it
carries four `(cram (applies_to …))` stanzas rather than one, because the tests split by
the heaviest tool they need. The three Layer-1 tests (`basics`, `oracle-negatives`,
`ptx-negatives`) declare **no** binary, so they stay toolchain-free; the emitting tests
need `%{bin:litmus7}` **and the whole `tests/het` corpus**, since naming each test here
would break silently the moment one of them touched a different row; `gpu-target`
and `machine-pairs` are separate for reasons the file's own comments give. No stanza names
`herd7`: cram covers emission, and the `.cat` lane is driven by hand. The `gpu-target`
comment records a trap (`litmus/libdir` cannot be declared as a dep) — read it before
adding a stanza.

---

## 7. Golden & promote model

Two goldens, in two places, updated by different buttons — **read the diff before
either** (promote blindly enshrines current output, bugs and all):
- cram expected-blocks → `dune promote`.
- committed corpus files → `git commit` (after regenerate).
- `hetlitmus-promote` bundles both, but leaves the corpus staged for you to review + commit.

---

## 8. Build order (highest ROI first)

1. ✓ **Layer 1 cram** (`0d5940b5e`) — `basics.t`, `oracle-negatives.t`, `ptx-negatives.t` + fixtures + `dune`.
2. ✓ **`hetlitmus-corpus`** (`6e92f2657`) — corpus + emission golden gate.
3. ✓ **`smoke.sh`** (landed at 6 reps, `fa2adc9db`; **11 today** — see §5) — reuses `comp.sh`.
4. ✓ **Makefile targets wired** (`68d102ef5`).
5. ○ **Layer 4** — later, on the GH200.

Steps 1–4 all run on the dev box (and in CI, Layer 3 with a CUDA-install step).

---

## 9. Reuse ledger (don't reinvent)

| Need | Reuse |
|---|---|
| compile-smoke | ✓ `comp.sh` (emitted per test) |
| PTX faithfulness | ✓ `ptxcheck.py` + `tokens.sh` |
| oracle comparison | ✓ `oracle-compare.sh` |
| annotation rules under test | ✓ `_grid_lib.sh` functions |
| corpus golden store + promote | ✓ git (`commit` / `checkout`) + regenerate-and-diff |
| cram runner + promote | ✓ dune (`(cram enable)` already in `dune-project`; `dune promote`) |
| Makefile idiom | ✓ herdtools7 `test::`/`| build`/`@ echo OK` |

---

## 10. Open items / pending decisions

- Layer 4 **numbers** — every knob, rate and threshold is measured on GH200/MI300A, not
  here (`00-environment-design.md` §6). The wiring and the positive-control design are
  shipped and gated; what is deferred is the measurement.
- Whether to also unit-test `ptxcheck.py` parsers (optional; low priority).
- Whether to fold `hetlitmus-test` into upstream `test::`.

---

## Appendix A — where the token check sits

`verify/tokens.sh` checks *static, hardware-free token faithfulness* — that is
**Layer 3** here, NOT Layer 1, even though it needs no device. Its make target is
`hetlitmus-faithful`; its discriminating-power lane is `hetlitmus-selftest`.

## Appendix B — ready-to-use cram examples (real captured output)

`basics.t` (Layer 1; `source` persists across `$` lines in one `.t`; ~10 lines,
one per rule branch. Outputs below are REAL captures — but always `dune promote` the
actual output rather than trusting these bytes):
```
  $ source _grid_lib.sh
  $ render_cycle sys relaxed PodWW Rfe PodRR Fre
  PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  $ render_cycle gpu acquire PodWW Rfe PodRR Fre
  PodWWRelaxedGpuRelaxedGpu RfeRelaxedGpuAcquireGpu PodRRAcquireGpuAcquireGpu FreAcquireGpuRelaxedGpu
  $ render_cycle sys release PodWW Rfe PodRR Fre
  PodWWReleaseSysReleaseSys RfeReleaseSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysReleaseSys
  $ render_cycle cta fence PodWW Rfe PodRR Fre
  FenceScCtadWWRelaxedCtaRelaxedCta RfeRelaxedCtaRelaxedCta FenceScCtadRRRelaxedCtaRelaxedCta FreRelaxedCtaRelaxedCta
  $ render_cpu_cycle acqrel PodWR Fre PodWR Fre
  PodWRLQ FreQL PodWRLQ FreQL
  $ render_cpu_cycle fence PodWW Rfe PodRR Fre
  DMB.SYdWW Rfe DMB.SYdRR Fre
  $ cut_tag cpu,gpu
  cg
  $ cut_tag gpu,cpu,cpu
  gcc
  $ scope_tree 2
  (sys (gpu (cta 0) (cta 1)))
  $ scope_tree 3
  (sys (gpu (cta 0) (cta 1) (cta 2)))
```
Optional atom-mapping units: `arm_ord R acqrel`→`Q` (LDAPR), `arm_ord W acqrel`→`L` (STLR).

`oracle-negatives.t` (Layer 1) is **not** reproduced here: it has outgrown a sample and
the committed `.t` is the authority. It drives the offline `oracle-compare.sh` over three
fixture pairs — `obs.txt`/`oracle.csv` (the full class × quantifier matrix in one run),
`obs-stats.txt`/`oracle-stats.csv` (the statistics section, whose blocks come verbatim from
`het_verdict.h`), and `obs-amd.txt`/`oracle-amd.csv` (the same decision logic over a
differently shaped CSV, pinning the mismatch sentence as unconditional across three
different `Source` cells). Read the file; `dune promote` the actual output rather than any
bytes quoted in a doc.

`ptx-negatives.t` (Layer 1; frozen corrupted PTX, no GPU):
```
  $ python3 ptxcheck.py tests/gpu-only/MP-sys-F.litmus --ptx corrupt-strengthen.ptx -q
  RESULT: FAIL
  [1]
```
