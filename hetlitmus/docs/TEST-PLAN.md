# HetLitmus — Test Plan & Spec

**Status as of 2026-07-05.** Living document. Captures the design decisions and
the empirical findings they rest on. `✓` = exists today, `○` = to build.

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
  (137) and `tests/het/generate.sh` (338) reproduces the committed `.litmus`
  corpus with **zero diff** (`git status --short` empty). Het ~6.8 s.
  → golden-master via `git diff` is viable and nearly free.
- **Emitters are byte-reproducible.** Re-emitting the 8 committed `cuda-out/*.cu`
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
- **Layer 3 faithfulness: ✓ and gated.** `l0_tokens.sh all` sweeps all 475 via
  `nvcc --ptx` + `ptxcheck`, returning nonzero on any FAIL.
- **Layer 1 negatives: now gated (`c2e4df4c5`).** `l0_tokens.sh selftest` (weaken
  order/scope, miscount, CPU STLR→STR) and `guard` (unknown-token → exit 2) are real
  injections that now **aggregate and return nonzero**, printing `SELFTEST OK` /
  `GUARD OK` sentinels. The eyeball gap is closed in the shell; the Layer-1 cram
  `ptx-negatives.t` now only **byte-freezes** that output (belt-and-suspenders), it
  is no longer the sole gate.
- Missing entirely: Layer-1 unit tests, `oracle-compare` negatives, Layer-2
  golden gate.

---

## 2. The 4 layers

Consolidated from an earlier 6-layer cut. Boundary between layers = the heaviest
tool you must install to run it: **nothing → OCaml build → CUDA → GPU.** Nothing
was dropped: old L0,L3→**1**; L1,L2-golden→**2**; L2-faithful,L4→**3**; L5→**4**.

| Layer | Checks | Mechanism | Needs | Runs |
|---|---|---|---|---|
| **1 Static** | rule-fns as spec (unit); checker discriminating-power (negatives) | dune **cram** | bash/python | anywhere, ms |
| **2 Generate** | corpus + emission regression golden; parse-smoke; census | **git-diff** + make | `make build` | local/CI, ~10 s |
| **3 Compile** | PTX faithfulness (all 475); compile-smoke (5 reps) | shell drivers | nvcc+clang, **no GPU** | local / CI-with-CUDA, ~min |
| **4 Hardware** | behavioral falsification; positive controls | `oracle-compare.sh` | **GH200** | manual, off-CI |

Goal mapping: **regression = Layer 2** (goldens); **works-as-expected = Layers 1,
3, 4** (spec units, faithfulness, negatives, behavioral).

Pre-commit gate = Layers 1–3 (all local, none need a GPU). Layer 4 is GH200-only.

### Coverage map — where "all the good cases" live

Exhaustive good-case coverage is the **goldens' job, not the cram's.** The good-case
enumeration is *defined* by the grid knobs in `_grid_lib.sh` (`SHAPE_ORDER` ×
`GRID_SCOPES` × `GRID_ORDERS`, plus het `SHAPE_HET_CUTS` × `TWO_SIDED_ORDERS`) and
*materialized* as the committed corpus (**137 gpu-only + 338 het**). It is asserted
exhaustively over **all 475** by:

| What is checked over ALL 475 | Layer |
|---|---|
| byte-pinned (regression) | 2 golden (`git status --porcelain`) |
| PTX/asm matches its annotation (faithfulness) | 3 (`l0_tokens.sh all`) |
| compiles | 3 (faithful `nvcc --ptx` + smoke) |
| enumeration didn't silently shrink | 2 census (counts 137/338, `@all`) |

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
| **git-diff** | Layer 2 corpus/emission golden | `git commit` | 475 byte-stable files; git already is the store + promote |
| **shell drivers** (`l0_tokens.sh`, new `smoke.sh`) | Layer 3 sweeps | n/a (pass/fail) | directory sweeps / multi-step |
| (none) | Layer 4 | n/a | nondeterministic, hardware |

**Cram in one line:** a `.t` is `  $ command` followed by its frozen expected
output (stdout+stderr merged, plus nonzero exit as `[N]`). `dune runtest` does a
line-exact diff; `dune promote` overwrites the expected block with current output.
Author = write command, `dune promote`, then **eyeball** that the captured golden
is what you *wanted*.

**Not used:** the `.expected` + `REGRESSION_TEST_MODE` OCaml-driver idiom. Its one
advantage over git-diff is *normalization* (order-insensitive/derived comparison);
our generation is byte-stable so we don't need it. The only place normalization
matters is verdict-level oracle checks (Layer 4) — and there `herd_regression_test.exe`
already does "run herd over a dir, compare outcomes to expected", so we would
**reuse** it, never write one.

---

## 4. Layer-by-layer contents

### Layer 1 — Static (cram; no toolchain)
- ○ `basics.t` — executable spec of `_grid_lib.sh`: **~10 lines, one per rule branch,
  NOT the 132-cell grid** (that is the Layer-2 golden's job). Cover the 4
  `render_cycle` orders (relaxed/acquire/release/fence, varying scope so all of
  Sys/Gpu/Cta appear), the 2 `render_cpu_cycle` orders (acqrel→STLR `L`/LDAPR `Q`,
  fence→`DMB.SYd*`), `cut_tag` (2- and 3-proc), `scope_tree` (2- and 3-proc). Exact
  list + real outputs in Appendix B. (Optional +2: unit `arm_ord R/W acqrel`→`Q`/`L`
  to pin the atom mapping directly.)
- ○ `oracle-negatives.t` — `oracle-compare` on frozen fixtures. Make this one
  **exhaustive**: the full 6-cell decision matrix **{MATCH, MISMATCH, NO-ORACLE} ×
  {exists, forall}** (no golden covers this logic; the `forall` quantifier inversion
  is subtle). Any MISMATCH → exit 1.
- ○ `ptx-negatives.t` — `ptxcheck --ptx <frozen-corrupt.ptx>` → exit 1 (no GPU). A
  thin **byte-freeze** of one corruption; the eyeball gap is already closed in the
  gated `l0_tokens.sh selftest` (`c2e4df4c5`), so this is belt-and-suspenders.
- (optional, lower priority) unit-test `ptxcheck.py` parsers (`classify_ptx_op`, …).

### Layer 2 — Generate (git-diff + make; OCaml build)
- ✓ `generate.sh` (both dirs), byte-stable.
- ○ **golden gate**: regenerate, then fail on any tree change including added/removed
  files — use `git status --porcelain -- hetlitmus/tests/`, **not** bare `git diff`.
- ○ emission golden: the 8 `cuda-out/*.cu` samples are **already committed**. Re-emit
  them in place and fold `cuda-out/` into the **same** `git status --porcelain` check
  as the corpus — emitter drift shows up as a dirty working tree.
- ~ parse-smoke (every `.litmus` emits without error) already comes free from the
  Layer-3 faithfulness sweep, which emits every test.
- ○ (optional) census contracts: counts 137/338; het proc-header column count ==
  number of device tags; `@all` lists exactly the `.litmus` files.

### Layer 3 — Compile (shell drivers; nvcc+clang, no GPU)
- ✓ faithfulness: `verify/l0_tokens.sh all` (already gated).
- ✓ `comp.sh` per test (verified compiles no-GPU).
- ○ `smoke.sh` (~10 lines): emit + run `comp.sh` on the 5 reps (§5), fail on any
  nonzero. `nvcc --ptx` from faithfulness already covers the gpu-only `.cu`, so
  smoke only needs the het harnesses (CPU side + `nvcc -c`/ptxas + link).

### Layer 4 — Hardware (GH200; later)
- ✓ `oracle-compare.sh`.
- ○ run wiring + **positive controls**: a known-Allowed relaxation must be observed
  at least sometimes under stress, else the harness is dead and every "Never" is
  meaningless. Report effort (rule-of-three), no confidence model.

---

## 5. Compile-smoke spec (settled)

Single "before every commit" run — **no tiers, no nightly**. **Not all 475**
(gpu-only `.cu` already gets `nvcc --ptx` from faithfulness). Run `comp.sh` (assert
exit 0) on **5 het representatives**, chosen to hit each distinct compile path once:

| Rep | Covers |
|---|---|
| one het one-sided (e.g. `MP-cg-sys-relaxed`) | plain CPU STR/LDR + barrier + `nvcc -c` |
| one `*-acqrel-2s` | CPU STLR + LDAPR |
| one `*-fence-2s` | CPU DMB.SY |
| one `tests/cluster/*` | Hopper-only cluster path |
| one 4-proc het (an IRIW cut) | largest barrier / proc count |

~20 s total. Residual risk (5 reps ≠ proof all 475 build) is accepted once: the
same gate `nvcc --ptx`-compiles every one of the 475 via faithfulness, and the
stages smoke adds (ptxas / CPU clang / link) are near-constant across tests.

---

## 6. Makefile targets

Mirror herdtools7's `::` accumulation + `| build` order-only prereq + `@ echo OK`.
Renamed the CUDA lane `-gpu`→`-nvcc` (nothing here needs a GPU).

Umbrellas (what you press):
- **`make hetlitmus-test`** → Layer 1+2 (`hetlitmus-cram` + `hetlitmus-corpus`). No CUDA.
- **`make hetlitmus-test-nvcc`** → Layer 3 (`hetlitmus-faithful` + `hetlitmus-smoke`). CUDA, no GPU.
- **`make hetlitmus-test-all`** → both. ← pre-commit gate on the dev box.
- **`make hetlitmus-promote`** → regenerate + `dune test hetlitmus/tests --auto-promote`;
  does **not** commit; prints "review `git diff` then commit".

Building blocks (run solo while iterating):
`hetlitmus-cram` · `hetlitmus-corpus` · `hetlitmus-faithful` · `hetlitmus-smoke`.

Notes:
- `hetlitmus-corpus` uses `git status --porcelain` (catches add/remove; non-invasive).
- GPU/nvcc targets are never wired into upstream `test::`. Optional: `test:: hetlitmus-test`.
- Layer 4 is a separate `hetlitmus-run` on the GH200, in no umbrella.

Cram `dune` stanza (in `hetlitmus/tests/cram/dune`):
```
(cram
 (deps %{bin:diyone7} %{bin:hetgen7} %{bin:litmus7}
       _grid_lib.sh oracle-compare.sh obs.txt oracle.csv
       ptxcheck.py corrupt-strengthen.ptx
       (glob_files tests/gpu-only/*.litmus)))
```

---

## 7. Golden & promote model

Two goldens, in two places, updated by different buttons — **read the diff before
either** (promote blindly enshrines current output, bugs and all):
- cram expected-blocks → `dune promote`.
- committed corpus files → `git commit` (after regenerate).
- `hetlitmus-promote` bundles both, but leaves the corpus staged for you to review + commit.

---

## 8. Build order (highest ROI first)

1. **Layer 1 cram** (`basics.t`, `oracle-negatives.t`, `ptx-negatives.t` + fixtures
   + `dune`) — pins the spec *and* closes the eyeball-only-negatives gap.
2. **`hetlitmus-corpus`** — cheapest, broadest regression net.
3. **`smoke.sh`** (5 reps) — reuses `comp.sh`.
4. **Wire the Makefile targets.**
5. **Layer 4** — later, on the GH200.

Steps 1–4 all run on the dev box (and in CI, Layer 3 with a CUDA-install step).

---

## 9. Reuse ledger (don't reinvent)

| Need | Reuse |
|---|---|
| compile-smoke | ✓ `comp.sh` (emitted per test) |
| PTX faithfulness | ✓ `ptxcheck.py` + `l0_tokens.sh` |
| oracle comparison | ✓ `oracle-compare.sh` |
| annotation rules under test | ✓ `_grid_lib.sh` functions |
| corpus golden store + promote | ✓ git (`status --porcelain` / `commit` / `checkout`) |
| cram runner + promote | ✓ dune (`(cram enable)` already in `dune-project`; `dune promote`) |
| Makefile idiom | ✓ herdtools7 `test::`/`| build`/`@ echo OK` |
| verdict-level oracle driver (Layer 4, if needed) | ✓ `internal/herd_regression_test.exe` — reuse, don't build |

---

## 10. Open items / pending decisions

- Layer 4 (hardware) run wiring + positive-control design — deferred to GH200 access.
- Exact 5 rep test names for `smoke.sh` (pattern is settled; pick concrete names at build).
- Whether to also unit-test `ptxcheck.py` parsers (optional; low priority).
- Whether to fold `hetlitmus-test` into upstream `test::`.

---

## Appendix A — naming collision (important)

The **"L0"** in `verify/l0_tokens.sh` means *static, hardware-free token
faithfulness* — that is **Layer 3** here, NOT Layer 1. Do not let the `l0`
filename leak into a Layer-1 target name. (This is why the faithfulness make
target is `hetlitmus-faithful`, not `hetlitmus-l0`.)

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

`oracle-negatives.t` (Layer 1; `obs.txt` = 3 Observation lines, `oracle.csv` =
`Litmus,Expected,Model,Source` with SB-sys Allowed + MP-sys-F Disallowed):
```
  $ oracle-compare.sh obs.txt oracle.csv
  Oracle:       oracle.csv
  Observations: obs.txt
  
  TEST           QUANT   OBSERVED   ORACLE       MODEL          RESULT     NOTE
  ----           -----   --------   ------       -----          ------     ----
  SB-sys         exists  Sometimes  Allowed      PTX            MATCH      relaxation seen
  MP-sys-F       exists  Sometimes  Disallowed   PTX            MISMATCH   FORBIDDEN OUTCOME SEEN
  LB-sys         exists  Never      -            -              NO-ORACLE  not in this oracle (GH200/PTX?)
  
  3 test(s): 1 MATCH, 1 MISMATCH, 1 NO-ORACLE
  [1]
```

`ptx-negatives.t` (Layer 1; frozen corrupted PTX, no GPU):
```
  $ python3 ptxcheck.py tests/gpu-only/MP-sys-F.litmus --ptx corrupt-strengthen.ptx -q
  RESULT: FAIL
  [1]
```
