# HetLitmus dev-tier spot check

A **machinery** validation of the emitted het harness on a rented NVIDIA box
that is *not* a GH200 — first target AWS **g5g** (Graviton2 AArch64 + T4G,
sm_75, PCIe). The same bundle serves **DGX Spark** (GB10, sm_121, real ATS) and
**GH200** (sm_90) unchanged; nothing here is g5g-specific except the numbers the
probe reads off the machine.

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
has no NVLink-C2C and (on g5g) no ATS, so the shared variables are not two
devices contending for one cache line under a live hardware-coherence protocol —
they migrate, or they cross PCIe. So:

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
* `ladder.sh` reads `suggested_cuda_arch` from that probe, and rung 1 greps
  `cudaDevAttrConcurrentManagedAccess` / `cudaDevAttrPageableMemoryAccess` out of
  harness logs. Every rung from 2 up is a **runtime** rung.
* There is no AMD GPU on the dev box (`rocminfo`: 0 gfx agents), so not one of
  those rungs could be observed to pass or fail here. A ladder written blind and
  never run is the "mechanism that reports success while doing nothing" this
  project has already shipped four times.

`ladder.sh` already fails closed on an AMD box: it `die`s on `nvcc not on PATH`
before rung 0. Leave it that way until the AMD ladder is written *against real
MI300X hardware*.

### What did NOT need porting, and why (measured 2026-08-03)

`campaign.py` and `run-one.sh` are **vendor-agnostic** and were left untouched:

* `campaign.py` contains zero occurrences of `cuda` or `hip`. It drives a
  `--runner` command template and parses the `HetStats` line; the toolchain that
  produced the binary is settled before it is invoked.
* `run-one.sh` is `cd {dir}; exec ./{test}`.
* Both vendors' link targets write the **same** `./<test>`, which is what makes
  that possible. `make hip-bin` is `.PHONY` and relinks unconditionally, so it
  can never report success while leaving the other vendor's binary in place —
  the failure `make cuda-bin` once had, and which
  `hetlitmus/verify/hipbuildcheck.py` phase 5 now pins in both directions.

`pack-bundle.sh` ships whole harness dirs, so the `.hip`, the HIP arms of
`comp.sh` and the `hip-bin` target travel with every bundle already. An AMD
bundle needs x86-rendered harnesses (`generate-x86.sh`) as well, which
`pack-bundle.sh` does not assemble yet, so it must not be pointed at an AMD run.

## Order of operations

```sh
# --- dev box -------------------------------------------------------------
make all                                   # litmus7 must be built
hetlitmus/spotcheck/pack-bundle.sh         # -> bundle-out/hetlitmus-spotcheck-<rev>.tar.gz
scp bundle-out/hetlitmus-spotcheck-*.tar.gz <instance>:

# --- instance ------------------------------------------------------------
tar xzf hetlitmus-spotcheck-*.tar.gz && cd hetlitmus-spotcheck-*
sh probe-cuda.sh     # rung -1: what does this machine offer?  ALWAYS FIRST.
sh ladder.sh         # rungs 0-6
```

`probe-cuda.sh` writes `results-devtier-.../probe.txt`; `ladder.sh` reads
`suggested_cuda_arch` from it, so running the probe first is not a suggestion.

## This ladder vs. `hetlitmus/hetlitmus-run.sh`

Two different jobs, deliberately not merged. **This ladder** is the *machinery*
spot check: seven rungs that ask whether the knobs, the reporting frames and the
pooling still work on a rented box, driven from an unpacked bundle. **The
wrapper** is the *session*: preflight → probe → emit → compile → campaign →
collect, driven from a checkout on the machine under test, and it records the
pair, the resolved arch and the mode so the results dir can be read afterwards.
The wrapper does not run the ladder, and the ladder does not emit.

`probe-hip.sh` is the AMD side of `probe-cuda.sh` for the wrapper's
`--gpu-target hip` lane. It records what `hipcc`, `amdgpu-arch` and `rocminfo`
report and stamps `probe_status=HOST_ONLY`: there is **no** device-attribute
kernel for HIP, for the reason this file gives above — it cannot be written
blind, and there is no AMD GPU here to write it against.

## Read the probe before the ladder

| key | why it decides the trip |
| --- | --- |
| `cooperativeLaunch` | `0` ⇒ the harness returns 2 immediately. Nothing will run. Stop. |
| `pageableMemoryAccess` | `1` ⇒ `HET_ALLOC=auto` picks `malloc`. |
| `usesHostPageTables` | **which machine this is**: `1` = hardware coherence (ATS: GH200, Spark), `0` = software (HMM). A box can report `pageableMemoryAccess=1` through HMM and take the same `malloc` branch as GH200 while being a different experiment. |
| `concurrentManagedAccess` | `0` ⇒ `managed` is FATAL; use `HET_ALLOC=pinned`. |
| `hostNativeAtomicSupported` | `0` ⇒ the `fetch_add` of `pinned`'s rendezvous counter is not system-atomic; the harness warns, increments are lost, and each iteration that loses one costs its cap and is discarded. |
| `sysatomic_*` | a **short** total is decisive: that mode's RMW is not atomic against the CPU. A matching total is weak evidence (the kernel may have finished before the host loop began). |

These are the conditions the CUDA C++ Memory Model states for a
`cuda::thread_scope_system` atomic to actually be atomic — one per mode. Every
tested access here, and the rendezvous counter, is such an atomic, so a mode
whose condition fails is not a weaker experiment, it is undefined. That is why
`HET_ALLOC` fails closed rather than falling back.

## Knobs

Exactly **six** runtime (`getenv`) knobs; everything else is compile-time and
is set through the compiler variable, e.g.
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`.

| knob | meaning |
| --- | --- |
| `HET_ALLOC` | `auto`\|`malloc`\|`managed`\|`pinned` — shared-memory mode |
| `HET_RUNS_MAX` | runs this invocation, clamped to the compiled `NUMBER_OF_RUN` (10) |
| `HET_ADAPTIVE` | `1` ⇒ consult `het_campaign_should_stop()` after every run |
| `HET_RATE` | `1` ⇒ a sighting stops nothing; the row runs to budget |
| `HET_CONFIRM_RUNS` | runs *after the one it fired in* that a lone clean sighting may hold a row open for (default 30) |
| `HET_SEED` | overrides the compiled seed base; **must** vary per invocation |

Growing R is done by re-invoking with a fresh seed (`campaign.py`), never by
replaying the same seeds — the harness says so itself if you try.

`CUDA_ARCH` is passed to `make`/`comp.sh` (`sm_75` T4G, `sm_90` GH200, `sm_121`
GB10). Always explicit: `-arch=native` only exists from CUDA 11.5 update 1, and
the toolkit version on a fresh instance is one of the things being probed.

## The subset

Five harnesses; see `TESTS.txt` for the per-test rationale. They are keyed to
what the emitted machinery *is*, not to what any model says about them: a
two-sided row, a one-sided row whose only annotation is a cta-scope GPU acquire,
the corpus's widest launch (`IRIW-gcgc-sys-fence`: 4 procs, NPART=4, 2 GPU
blocks), and the two rows whose outcome does not arrive through a register alone
— one carrying both kinds of outcome column (R), one store-only (2+2W).

## Known quirks, so nobody rediscovers them at $/hour

* **`campaign.py` schedules the corpus and nothing else.** The corpus is the
  whole schedule and every row takes one stop rule; the only knobs are
  `--budget-runs`, `--confirm-runs` and `--rate`. A row that fires once and will
  not repeat runs for the confirmation window (30 runs by default) **counted from
  the run it fired in**, which carries it **past** `--budget-runs`, and ends
  `UNCONFIRMED-SIGHTING`. A row firing in its last budgeted run therefore costs
  `--budget-runs + --confirm-runs`: budget your instance time for that, not for
  the budget alone.
* **Rung 6 is the long one.** Five rows × up to `LADDER_BUDGET` runs ×
  `SIZE_OF_TEST=100000` iterations with full stress. Budget your instance time,
  or lower `LADDER_BUDGET` — but keep it **above 10** (`NUMBER_OF_RUN`), or a
  null row finishes in one invocation and the cross-invocation pooling that the
  rung exists to exercise never engages.
* **`SIZE_OF_TEST` and `NUMBER_OF_RUN` are emitted as unguarded `#define`s**, so
  unlike the other compile-time knobs they cannot be lowered with `-D`. The only
  runtime lever on run count is `HET_RUNS_MAX` (clamped to `NUMBER_OF_RUN`).
* **`pinned` really can lose rendezvous increments.** Measured on a WSL2 RTX 3060
  (`hostNativeAtomicSupported=0`): a device/host system-scope `fetch_add` race
  landed **201665 of 400000** increments. That is the documented behaviour and it
  is what the harness warns about. A lost increment does not hang the run: the
  iteration that lost it ends at the cap and is discarded, and the run is thrown
  away only once the discards pass `HET_RDV_MAX_DISCARD_PCT` of `N`. What it
  costs is **wall clock** — a whole cap per unmet iteration, with no early bail —
  which is why `ladder.sh` wraps every invocation in a 900 s `timeout`.

## Files

| file | role |
| --- | --- |
| `probe.cu`, `probe-cuda.sh` | machine probe → `probe.txt` |
| `TESTS.txt` | the subset and why each test is in it |
| `pack-bundle.sh` | dev box: emit, prune, re-measure the widest launch, stamp, tar |
| `ladder.sh` | instance: rungs 0–6, exit-code table |
| `run-one.sh` | one invocation, for `campaign.py --runner` |
| `STAMP` (in the bundle) | git revision, date, census, per-test geometry, emitter + dialect SHA-256 |

The emitted harness dirs are self-contained — `outs.c/h`, `het_stress.h`,
`het_cpu_stress.h`, `het_rdv.h` and `het_verdict.h` are written into every dir at
emission —
so the instance needs no repo, no OCaml and no `litmus7`: just `nvcc`, `gcc`,
`make` and `python3`.
