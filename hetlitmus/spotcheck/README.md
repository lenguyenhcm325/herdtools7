# HetLitmus dev-tier spot check

A **machinery** validation of the emitted het harness on a rented NVIDIA box
that is *not* a GH200. Nothing in the bundle is keyed to one machine: an AWS
**g5g** (Graviton2 AArch64 + T4G, sm_75, PCIe), a **DGX Spark** (GB10, sm_121,
ATS) and a **GH200** (sm_90) all run it unchanged, and the only numbers a run
takes from the machine are the ones the probe reads off it.

## What this can and cannot establish

It **can** establish that the code works: that a harness dir builds and links,
that both devices launch and rendezvous at every iteration, that `HET_ALLOC`
selects a shared-memory mode and refuses the illegal ones, that every reporting
frame is printed and
parseable, that the stress knobs actually reach the build, and that `campaign.py`
pools across invocations, so a row is scored over more `(instance,run)` cells
than one invocation holds. Every one of those is a property of the code and is
checkable anywhere.

It **cannot** establish anything about a memory model — and neither can the
bundle, which ships no prediction to compare a row against. A non-GH200 box also
has no NVLink-C2C, and a PCIe box such as g5g has no ATS, so the shared variables
are not two devices contending for one cache line under a live
hardware-coherence protocol — they migrate, or they cross PCIe. So:

* a **null** here describes the window *this* box gave us — different machine,
  different window;
* a **sighting** here is an observation about *this* box under *this* stress
  config, and the ladder reports it as one. Comparing any row against a verdicts
  file the reader supplies is a separate offline step, never part of a run, and
  this tree ships no comparator for it.

Results go to `results-devtier-<date>-<host>/` and **must never be merged with
GH200 evaluation data**.

## This ladder is NVIDIA-only. The AMD one is unwritten.

The AMD build arms make AMD harnesses *linkable and runnable* — `sh comp.sh
hip-link` and `make hip-bin` produce `./<test>` from `<test>_hip.o` at
`--offload-arch=gfx942`, under the same `uname -m` refusal as the CUDA arms.
What they deliberately do **not** do is port this ladder, and the reason is that
porting it half-way would be worse than not porting it:

* `probe.cu` is CUDA (`cudaDeviceGetAttribute`, `cudaMallocManaged`,
  `cudaHostAlloc`); its HIP twin has to ask different questions
  (`hipDeviceAttributeManagedMemory`, `hipDeviceAttributeIntegrated`), so it is a
  new probe, not a `sed`.
* `ladder.sh` reads `suggested_cuda_arch` from that probe, rung 1 exercises
  `HET_ALLOC` against the CUDA allocator's refusal and banner ("The rungs"
  below), and every rung from 2 up is a **runtime** rung.
* Without an AMD GPU to run against, not one of those rungs could be observed
  to pass or fail. A ladder written blind and never run is a mechanism that
  reports success while doing nothing.

`ladder.sh` fails closed on an AMD box: it `die`s on `nvcc not on PATH` before
rung 0. Leave it that way until the AMD ladder is written *against real MI300X
hardware*.

### What needs no porting, and why

`campaign.py` and `run-one.sh` are **vendor-agnostic**:

* `campaign.py` contains zero occurrences of `cuda` or `hip`. It drives a
  `--runner` command template and parses the `HetStats` line; the toolchain that
  produced the binary is settled before it is invoked.
* `run-one.sh` is `cd {dir}` then `exec ./{test}`. With `HET_RUN_LOG_DIR` set it
  runs the same binary and appends the transcript to
  `$HET_RUN_LOG_DIR/<test>.log`, keeping stdout and stderr separate and exiting
  with the harness's own status (`campaign.py` builds an errored row's note from
  the runner's stderr). The ladder leaves the variable unset; the session
  wrapper sets it.
* Both vendors' link targets write the **same** `./<test>`, which is what makes
  that possible. Each `<vendor>-bin` target is `.PHONY` and always relinks
  (`hetlitmus/docs/het-emission.md`), so neither can report success while
  leaving the other vendor's binary in place; `hipbuildcheck.py`'s
  `stale-binary` phase pins that in both directions.

`pack-bundle.sh` emits the CUDA lane only: it refuses any `GPU_TARGET` but
`cuda`, and one emission carries one vendor's render and one vendor's `comp.sh`
arms (`hetlitmus/docs/het-emission.md`), so no `.hip` and no hip arm travels in
a bundle. An AMD bundle would need x86-rendered harnesses (`generate-x86.sh`)
emitted with `-gpu-target hip`, which `pack-bundle.sh` does not assemble; do not
point it at an AMD run.

## Order of operations

```sh
# --- build host (needs the built litmus7) ----------------------------------
make all                                   # litmus7 must be built
hetlitmus/spotcheck/pack-bundle.sh         # -> bundle-out/hetlitmus-spotcheck-<rev>.tar.gz
scp bundle-out/hetlitmus-spotcheck-*.tar.gz <instance>:

# --- instance ------------------------------------------------------------
tar xzf hetlitmus-spotcheck-*.tar.gz && cd hetlitmus-spotcheck-*
sh probe-cuda.sh     # the probe, always first: what does this machine offer?
sh ladder.sh         # rungs 0-4
```

`probe-cuda.sh` writes `results-devtier-.../probe.txt`; `ladder.sh` reads
`suggested_cuda_arch` from it (and `pageableMemoryAccess`,
`concurrentManagedAccess`, `cooperativeLaunch` for its conditional arms), so
running the probe first is not a suggestion. The probe compiles `compute_75`
PTX and JITs it at load, so the one command works before the arch is known:
never `-arch=native` (`het-emission.md`, the `CUDA_ARCH` paragraph), and not
`compute_60`, which CUDA 13 drops with the rest of pre-Turing.

## The rungs

| rung | what it drives | what it reads |
| --- | --- | --- |
| 0 | build: `sh comp.sh cuda` + `make cuda-bin` in every harness dir of `TESTS.txt` | an executable `./<test>` in each |
| 1 | `HET_ALLOC` bites: `HET_ALLOC=garbage`, then `HET_ALLOC=managed` where the probe allows it | a nonzero exit naming `is not a shared-memory mode`; a banner saying `mode=managed` |
| 2 | every row of `TESTS.txt` at tiny N (`LADDER_RUNS_TINY`, default 2), a fresh seed per row | the shared-mem banner, the `HetVerdict` frame, both `HetStats` lines, `scored`/`discarded`/`k`, the `CAVEAT:` lines |
| 3 | stress off → on: `MP-cg-sys-fence-2s` rebuilt with every stress `-D` knob at 0, then as shipped (`LADDER_RUNS_MAIN`, default 4) | the two `cpu-stress:` lines differ; the `HetObs` counters `do_stress_rounds`, `enemy_rounds`, `preload` go 0 → nonzero and `req` differs; the noise pair declares itself degraded where the box has no C2C |
| 4 | campaign pooling: `campaign.py` over every row, `--budget-runs LADDER_BUDGET` (default 16, above `NUMBER_OF_RUN` 10), a fresh `--state` | every row took ≥ 2 invocations |

A failed rung is data, not an abort (rung 0 excepted: nothing runs without
binaries); the exit code is the number of failed rungs, and every harness
invocation runs under `timeout LADDER_TIMEOUT` (default 900 s).

## This ladder vs. `hetlitmus/hetlitmus-run.sh`

Two different jobs, deliberately not merged. **This ladder** is the *machinery*
spot check: five rungs that ask whether the knobs, the reporting frames and the
pooling still work on a rented box, driven from an unpacked bundle. **The
wrapper** is the *session*: preflight → probe → emit → compile → campaign →
collect, driven from a checkout on the machine under test, and it records the
pair, the resolved arch and the mode so the results dir can be read afterwards.
The wrapper does not run the ladder, and the ladder does not emit.

`probe-hip.sh` is the AMD side of `probe-cuda.sh` for the wrapper's
`--gpu-target hip` lane. It records what `hipcc`, `amdgpu-arch` and `rocminfo`
report and stamps `probe_status=HOST_ONLY`: there is **no** device-attribute
kernel for HIP, for the reason this file gives above — it cannot be written
blind, and there is no AMD GPU to write it against.

## Read the probe before the ladder

| key | why it decides the trip |
| --- | --- |
| `cooperativeLaunch` | `0` ⇒ the harness returns 2 immediately. Nothing will run. Stop. |
| `pageableMemoryAccess` | `1` ⇒ `HET_ALLOC=auto` picks `malloc`. |
| `usesHostPageTables` | **which machine this is**: `1` = hardware coherence (ATS: GH200, Spark), `0` = software (HMM). A box can report `pageableMemoryAccess=1` through HMM and take the same `malloc` branch as GH200 while being a different experiment. |
| `concurrentManagedAccess` | `0` ⇒ `managed` is FATAL; use `HET_ALLOC=pinned`. |
| `hostNativeAtomicSupported` | `0` ⇒ the `fetch_add` of `pinned`'s rendezvous counter is not system-atomic; the harness warns, increments are lost, and each iteration that loses one costs its cap and is discarded. |
| `sysatomic_*` | a **short** total is decisive: that mode's RMW is not atomic against the CPU. A matching total is weak evidence (the kernel may have finished before the host loop began). |

These are the conditions under which a `cuda::thread_scope_system` atomic is
atomic at all [CudaGuide "Atomicity"] — one per mode. Every tested access here,
and the rendezvous counter, is such an atomic, so a mode whose condition fails
is not a weaker experiment, it is undefined. That is why `HET_ALLOC` fails
closed rather than falling back.

`probe.cu` never exercises a mode the device cannot reach:
`cudaErrorIllegalAddress` is sticky and poisons the context, so every mode
probed after it — managed and pinned included — would read as failed too. A
mode it skipped prints `mode_<mode>=skipped(<why>)`; a poisoned probe prints
`probe_status=POISONED-partial`.

## Knobs

The runtime knobs, each a `getenv`/`het_env_*` read in the emitted harness (the
table is the list of record); everything else is compile-time and is set
through the compiler variable, e.g.
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`.

| knob | meaning |
| --- | --- |
| `HET_ALLOC` | `auto`\|`malloc`\|`managed`\|`pinned` — shared-memory mode |
| `HET_RUNS_MAX` | runs this invocation, clamped to the compiled `NUMBER_OF_RUN` (10) |
| `HET_ADAPTIVE` | `1` ⇒ consult `het_campaign_should_stop()` after every run |
| `HET_RATE` | `1` ⇒ a sighting stops nothing; the row runs to budget |
| `HET_CONFIRM_RUNS` | runs *after the one it fired in* that a lone clean sighting may hold a row open for (default 30) |
| `HET_SEED` | overrides the compiled seed base; **must** vary per invocation |
| `HET_CAP_CPU` | the host's rendezvous cap, in polls, overriding the compiled placeholder |
| `HET_CAP_GPU` | the device's rendezvous cap, in polls, overriding the compiled placeholder |

The two caps ship as placeholders until a target measures them
(`HET_CAP_CALIBRATED` in `het_rdv.h`). `HET_RUN_LOG_DIR` is `run-one.sh`'s
knob, not the harness's.

Growing R is done by re-invoking with a fresh seed (`campaign.py`), never by
replaying the same seeds — the harness says so itself if you try.

`CUDA_ARCH` is passed to `make`/`comp.sh` (`sm_75` T4G, `sm_90` GH200, `sm_121`
GB10). Always explicit, never `-arch=native` (above).

## The subset

The harnesses `TESTS.txt` names, one row each with its rationale: they are
keyed to what the emitted machinery *is* (proc count, GPU lanes, scope, which
side is annotated, which kind of outcome column), not to what any model says
about them.

## Known quirks, so nobody rediscovers them at $/hour

* **`campaign.py` schedules the corpus and nothing else.** The corpus is the
  whole schedule and every row takes one stop rule; the only knobs are
  `--budget-runs`, `--confirm-runs` and `--rate`. A row that fires once and will
  not repeat runs for the confirmation window (30 runs by default) **counted from
  the run it fired in**, which carries it **past** `--budget-runs`, and ends
  `UNCONFIRMED-SIGHTING`. A row firing in its last budgeted run therefore costs
  `--budget-runs + --confirm-runs`: budget your instance time for that, not for
  the budget alone.
* **Rung 4 (campaign pooling) is the long one.** Every row of `TESTS.txt` × up
  to `LADDER_BUDGET` runs × `SIZE_OF_TEST=100000` iterations with full stress.
  Budget your instance time, or lower `LADDER_BUDGET` — but keep it **above 10**
  (`NUMBER_OF_RUN`), or a null row finishes in one invocation and the
  cross-invocation pooling that the rung exists to exercise never engages.
* **`SIZE_OF_TEST` and `NUMBER_OF_RUN` are emitted as unguarded `#define`s**, so
  unlike the other compile-time knobs they cannot be lowered with `-D`. The only
  runtime lever on run count is `HET_RUNS_MAX` (clamped to `NUMBER_OF_RUN`).
* **`pinned` can lose rendezvous increments.** On a box reporting
  `hostNativeAtomicSupported=0` a device/host system-scope `fetch_add` race
  loses increments, and the probe's `sysatomic_*` keys show it as a short
  total, which is decisive. The harness warns [CudaGuide "Atomicity"]. A lost
  increment does not hang the run: the iteration that lost it ends at the cap
  and is discarded, and the run is thrown away only once the discards pass
  `HET_RDV_MAX_DISCARD_PCT` of `N`. What it costs is **wall clock** — a whole
  cap per unmet iteration, with no early bail — which is why `ladder.sh` wraps
  every invocation in `LADDER_TIMEOUT` (900 s).

## Files

| file | role |
| --- | --- |
| `probe.cu`, `probe-cuda.sh` | machine probe → `probe.txt` |
| `probe-hip.sh` | the wrapper's AMD probe (host facts only); not in the bundle |
| `TESTS.txt` | the subset and why each test is in it |
| `pack-bundle.sh` | build host (needs the built `litmus7`): emit, prune, re-measure the widest launch, stamp, tar |
| `ladder.sh` | instance: rungs 0-4, exit-code table |
| `run-one.sh` | one invocation, for `campaign.py --runner` |
| `STAMP` (in the bundle) | git revision, date, census, per-test geometry, and `emitter_sha256`, `dialect_sha256`, `verdict_h_sha256` — the only thing tying a bundle's harnesses to the emitter that produced them |

The emitted harness dirs are self-contained — `outs.c/h`, `het_stress.h`,
`het_cpu_stress.h`, `het_rdv.h` and `het_verdict.h` are written into every dir at
emission —
so the instance needs no repo, no OCaml and no `litmus7`: just `nvcc`, `gcc`,
`make` and `python3`.
