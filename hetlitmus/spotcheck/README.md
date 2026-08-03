# HetLitmus dev-tier spot check

A **machinery** validation of the emitted het harness on a rented NVIDIA box
that is *not* a GH200 — first target AWS **g5g** (Graviton2 AArch64 + T4G,
sm_75, PCIe). The same bundle serves **DGX Spark** (GB10, sm_121, real ATS) and
**GH200** (sm_90) unchanged; nothing here is g5g-specific except the numbers the
probe reads off the machine.

## What this can and cannot establish

It **can** establish that the code works: that a harness dir builds and links,
that both devices launch and rendezvous, that `HET_ALLOC` selects a shared-memory
mode and refuses the illegal ones, that the positive controls stay hot, that each
oracle class prints its own reporting frame, that the stress knobs actually reach
the build, and that `campaign.py` pools across invocations so the B7 statistics
engage. Every one of those is a property of the code and is checkable anywhere.

It **cannot** establish anything about the compound memory model. A non-GH200 box
has no NVLink-C2C and (on g5g) no ATS, so the shared variables are not two
devices contending for one cache line under a live hardware-coherence protocol —
they migrate, or they cross PCIe. And `expected-nvidia.csv` was derived for
GH200 specifically (ARMv9 Grace + Hopper PTX). So:

* a **null** here says nothing — different machine, different window;
* a **sighting on a Disallowed row** here is *not* a refutation of the CMCM
  either, but it is a five-alarm machinery event; the ladder stops and says so.

Results go to `results-devtier-<date>-<host>/` and **must never be merged with
GH200 evaluation data**.

## This ladder is NVIDIA-only. The AMD one is Phase 3a.

P2c made AMD harnesses *linkable and runnable* — `sh comp.sh hip-link` and `make
hip-bin` produce `./<test>` from `<test>_hip.o` at `--offload-arch=gfx942`, under
the same `uname -m` refusal as the CUDA arms. What P2c deliberately did **not**
do is port this ladder, and the reason is that porting it half-way would be
worse than not porting it:

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
MI300X hardware* in Phase 3a.

### What did NOT need porting, and why (measured 2026-08-03)

`campaign.py` and `run-one.sh` are **vendor-agnostic** and were left untouched:

* `campaign.py` contains zero occurrences of `cuda` or `hip`. It drives a
  `--runner` command template and parses the `HetStats` line; the toolchain that
  produced the binary is settled before it is invoked.
* `run-one.sh` is `cd {dir}; exec ./{test}`.
* Both vendors' link targets write the **same** `./<test>`, which is what makes
  that possible. `make hip-bin` is `.PHONY` and relinks unconditionally, so it
  can never report success while leaving the other vendor's binary in place —
  the failure `make cuda-bin` had before P2c, and which
  `hetlitmus/verify/hipbuildcheck.py` phase 5 now pins in both directions.

`pack-bundle.sh` ships whole harness dirs, so the `.hip`, the HIP arms of
`comp.sh` and the `hip-bin` target travel with every bundle already. It also
ships `control-map.csv` and `expected-nvidia.csv` — **the NVIDIA oracle**. An AMD
bundle needs `control-map-amd.csv` + `expected-amd.csv` *and* x86-rendered
harnesses (`generate-x86.sh`); `pack-bundle.sh` does not assemble that pairing
yet, so it must not be pointed at an AMD run.

## Order of operations

```sh
# --- dev box -------------------------------------------------------------
make all                                   # litmus7 must be built
hetlitmus/spotcheck/pack-bundle.sh         # -> bundle-out/hetlitmus-spotcheck-<rev>.tar.gz
scp bundle-out/hetlitmus-spotcheck-*.tar.gz <instance>:

# --- instance ------------------------------------------------------------
tar xzf hetlitmus-spotcheck-*.tar.gz && cd hetlitmus-spotcheck-*
sh probe.sh          # rung -1: what does this machine offer?  ALWAYS FIRST.
sh ladder.sh         # rungs 0-6
```

`probe.sh` writes `results-devtier-.../probe.txt`; `ladder.sh` reads
`suggested_cuda_arch` from it, so running the probe first is not a suggestion.

## Read the probe before the ladder

| key | why it decides the trip |
| --- | --- |
| `cooperativeLaunch` | `0` ⇒ the harness returns 2 immediately. Nothing will run. Stop. |
| `pageableMemoryAccess` | `1` ⇒ `HET_ALLOC=auto` picks `malloc`. |
| `usesHostPageTables` | **which machine this is**: `1` = hardware coherence (ATS: GH200, Spark), `0` = software (HMM). A box can report `pageableMemoryAccess=1` through HMM and take the same `malloc` branch as GH200 while being a different experiment. |
| `concurrentManagedAccess` | `0` ⇒ `managed` is FATAL; use `HET_ALLOC=pinned`. |
| `hostNativeAtomicSupported` | `0` ⇒ `pinned`'s barrier `fetch_add` is not system-atomic; the harness warns, and the run may hang. |
| `sysatomic_*` | a **short** total is decisive: that mode's RMW is not atomic against the CPU. A matching total is weak evidence (the kernel may have finished before the host loop began). |

These are the conditions the CUDA C++ Memory Model states for a
`cuda::thread_scope_system` atomic to actually be atomic — one per mode. Every
tested access here, and the rendezvous barrier, is such an atomic, so a mode
whose condition fails is not a weaker experiment, it is undefined. That is why
`HET_ALLOC` fails closed rather than falling back.

## Knobs

Exactly **five** runtime (`getenv`) knobs; everything else is compile-time and
is set through the compiler variable, e.g.
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`.

| knob | meaning |
| --- | --- |
| `HET_ALLOC` | `auto`\|`malloc`\|`managed`\|`pinned` — shared-memory mode |
| `HET_RUNS_MAX` | runs this invocation, clamped to the compiled `NUMBER_OF_RUN` (10) |
| `HET_ADAPTIVE` | `1` ⇒ consult `het_campaign_should_stop()` after every run |
| `HET_P_GOAL` | stop a bound-needing row once `p_bound <= this` |
| `HET_SEED` | overrides the compiled seed base; **must** vary per invocation |

Growing R is done by re-invoking with a fresh seed (`campaign.py`), never by
replaying the same seeds — the harness says so itself if you try.

`CUDA_ARCH` is passed to `make`/`comp.sh` (`sm_75` T4G, `sm_90` GH200, `sm_121`
GB10). Always explicit: `-arch=native` only exists from CUDA 11.5 update 1, and
the toolkit version on a fresh instance is one of the things being probed.

## The subset

Five harnesses; see `TESTS.txt` for the per-test rationale. Between them they
cover the Disallowed-with-co-run-control shape, an Allowed one-sided test whose
weakness is GPU-side, a NO-ORACLE 4-proc row, an observer-lane (R) row and a
store-only (2+2W) row. Every one of them co-runs the canary
`MP-{cg,gc}-sys-relaxed` inside its own launch, so the fully-relaxed het-MP
floor — the likeliest thing to fire anywhere — rides along with all five.

## Known quirks, so nobody rediscovers them at $/hour

* **`campaign.py --control-map` accepts either CSV** (fixed post-PORT1): its
  header-skip once matched only `expected-nvidia.csv`'s `Litmus` header, so
  `control-map.csv` was unreadable and early ladders fed it `expected-nvidia.csv`
  as a workaround. Both headers are skipped now, statscheck phase 6.0 parses both
  *real* files as a gate, and `ladder.sh` passes `control-map.csv` — the file
  `read_control_map`'s docstring names. Columns 1–2 of the two files agree by
  construction (`make hetlitmus-controlmap` gates it).
* **Rung 6 is the long one.** Five rows × up to `LADDER_BUDGET` runs ×
  `SIZE_OF_TEST=100000` iterations with full stress. Budget your instance time,
  or lower `LADDER_BUDGET` — but keep it **above 10** (`NUMBER_OF_RUN`), or a
  bound row finishes in one invocation and the cross-invocation pooling that the
  rung exists to exercise never engages.
* **`SIZE_OF_TEST` and `NUMBER_OF_RUN` are emitted as unguarded `#define`s**, so
  unlike the other compile-time knobs they cannot be lowered with `-D`. The only
  runtime lever on run count is `HET_RUNS_MAX` (clamped to `NUMBER_OF_RUN`).
* **`pinned` really can lose barrier increments.** Measured on a WSL2 RTX 3060
  (`hostNativeAtomicSupported=0`): a device/host system-scope `fetch_add` race
  landed **201665 of 400000** increments. That is the documented behaviour, it is
  what the harness warns about, and it is why `ladder.sh` wraps every invocation
  in `timeout`.

## Files

| file | role |
| --- | --- |
| `probe.cu`, `probe.sh` | machine probe → `probe.txt` |
| `TESTS.txt` | the subset and why each test is in it |
| `pack-bundle.sh` | dev box: emit, prune, stamp, tar |
| `ladder.sh` | instance: rungs 0–6, exit-code table |
| `run-one.sh` | one invocation, for `campaign.py --runner` |
| `STAMP` (in the bundle) | git revision, date, census, emitter SHA-256 |

The emitted harness dirs are self-contained — `outs.c/h`, `het_stress.cuh`,
`het_cpu_stress.h` and `het_verdict.h` are written into every dir at emission —
so the instance needs no repo, no OCaml and no `litmus7`: just `nvcc`, `gcc`,
`make` and `python3`.
