# Heterogeneous CPU+GPU harness emission

`litmus7` turns one `Het` `.litmus` test (`het-litmus-format.md`) into one
harness directory that compiles: a GPU render in one dialect, the CPU threads
as litmus7's own inline asm, litmus7's outcome histogram and the build files.
Running it on hardware is the four steps of "From a corpus to a results dir".

Two axes are chosen per test rather than hard-wired:

* the **CPU ISA**, by the per-column device tag (`P0:aarch64`, `P0:x86_64`;
  `P0:cpu` reads as AArch64) — "CPU ISA from the device tag";
* the **GPU dialect**, by `-gpu-target cuda|hip`, mandatory on the `Het` and
  the `LISA` arm alike — "One render per `-gpu-target`".

Where the directory lands is what `-o` names: the current directory with no
`-o`, the named directory, or the archive itself for `-o <name>.tar|.tgz`
(`lib/tar.ml` decides by extension). The `-o` target holds the harness
directories and nothing else: an all-`Het` batch compiles no C run harness, so
litmus7 writes no suite-level `run.sh`/`comp.sh`/`README.txt`/`Makefile` beside
them and copies no run-harness runtime from the libdir (`litmus/dumpRun.ml`).

## CPU ISA from the device tag

The harness derivation is a functor, `HetEmit.Make` (`litmus/hetEmit.ml`),
closed over one CPU module chain. The `Het` arm of `litmus/top_litmus.ml`
pre-scans the header (`HetArch.scan_cpu_isa`) before any parser exists and
instantiates the AArch64 or the x86_64 chain; a header whose CPU columns name
two ISAs is refused, because one harness is derived over one CPU backend. The
functor's only seam back into `Top` is a slice of its options (`HetOpts`), the
splitter and the compiled-code extractor, so no het module depends on
`top_litmus.ml`. `HetCpuFront` supplies, per ISA, the column sub-parser and
the toolchain record the build files fold over (host macro, `uname -m` word,
clang cross triple, CPU compile flags); the GPU side is LISA/Bell in both
cases. The functor derives `HetHarness.t`, the harness as data, and every
file is rendered from that record by a module the CPU chain does not
parameterise (`HetCpuFile`, `HetGpuFile` with `HetDriverMain`,
`HetBuildFiles`).

## One render per `-gpu-target`

One LISA parse yields the one render the flag names. The per-vendor facts are
one `gpu_dialect` record per vendor (`litmus/hetDialect.ml`), and every
per-vendor site — the render, the `comp.sh` arms, the `Makefile` rules, the
README — folds over the selected record, so a third vendor is a registry entry
rather than an edit at each site, and a harness directory carries one vendor's
render and build targets. The dialects differ only in the record's fields: the
instruction lowering (`CudaLang`/`HipLang`, over their shared half
`litmus/gpuLang.ml`), the allocator and noise payloads, and the runtime
tokens. The flag has no default: a harness is filed under its pair, and a
default would pick the vendor silently.

## What the harness reuses, and what is new

* **CPU threads are litmus7's own.** The CPU columns are projected onto a
  CPU-only test (`HetArch.to_cpu_pseudo`) and run through litmus7's own compile
  pipeline; `ASMLang.dump_fun` prints the body into `<t>_cpu.c`, so the CPU
  half's faithfulness is litmus7's lowering (`faithfulness.md`) with no het
  vocabulary inside the asm. The emitter adds one non-static entry
  `het_run_P<n>` per proc. The slot arithmetic is the caller's: the asm
  dereferences bare pointers as litmus7 writes them, and the driver's
  `cpu_thread_P<n>` passes iteration `n`'s slot address for every location and
  output buffer (`litmus/het-runtime/het_rdv.h`, `HET_SLOT_STRIDE_WORDS`).
* **GPU lanes reuse the GPU-only lowering.** The GPU columns are projected
  onto Bell/LISA (`HetArch.to_gpu_pseudo`); globals, result registers and the
  launch layout come from `litmus/gpuLang.ml`, shared with the GPU-only arm,
  and only `dump_instr` is per dialect. New is the het scaffold: the per-proc
  guard, the rendezvous and the slot addressing.
* **Shared locations and the rendezvous counter come from one allocator,**
  `gd_alloc_shared`, whose mode selects the coherence property under test
  (`00-environment-design.md` §3.2): `HET_ALLOC` on the CUDA render
  (`litmus/het-runtime/het_alloc_cuda.inc`), one fine-grained mode on HIP
  (`het_alloc_hip.inc`). Read buffers are device memory, off the race path.
* **One rendezvous per iteration:** a system-scope counter arrived at and
  polled relaxed on both sides, with no fence between or after, because it
  decides when an iteration starts and must write no ordering into it
  (`00-environment-design.md` §3.3, `het_rdv.h`). The counter is reset once
  per run and the participants persist across iterations. A participant whose
  cap expires records 0 in its arrival flag, and that iteration is discarded.
* **The memory-object table drives the driver.** `HetHarness` lists every
  object `main()` allocates as one record (type, bytes, residence, reset) in
  two families — the race surface (shared globals, then the barrier counter)
  and the observation record (read buffers, arrival flags) — and allocation,
  per-run reset, readback and free fold over it in that lifecycle order, so an
  object is added by adding a row.
* **Readback merges into litmus7's histogram.** After the run the driver walks
  the slots once — ANDs the arrival flags, discards or scores, assembles the
  outcome vector `_o[]` from both sides — and calls litmus7's
  `add_outcome_outs` at one call site; the `exists` condition is a C predicate
  over `_o[]` (`litmus/hetCond.ml`).

## The CPU object: native vs. cross-assembly

`<t>_cpu.c` holds the asm under `#if defined(<host macro>)` with an `#error`
in the `#else`, so exactly one compiler can produce an object and `comp.sh`
picks it on `uname -m` alone:

* **native** (`uname -m` is the render's ISA): `gcc $HET_CPU_CFLAGS -c` writes
  `<t>_cpu_host.o`, the only object either link path names;
* **foreign**: `clang --target=<triple> -std=gnu11 -c` writes `<t>_cpu.o` and
  nothing else. clang's integrated assembler emits an ELF of the target from
  the real asm, so no cross-binutils are needed; every ISA carries a triple
  (`HetCpuFront.toolchain.cross`) because each is foreign to the other's
  host. A foreign host without `clang` is an error exit, not a skip, so no
  directory reports success having assembled nothing.

Only the native branch writes `<t>_cpu_host.o`, which is why `comp.sh
<target>` succeeds on a foreign host while every link path fails there:
`make <target>-bin` stops at the `#error` in its `$(CC)` rule, and `comp.sh
<target>-link` dies on the missing object. Neither leaves a `./<t>`.

`HET_CPU_CFLAGS` carries `-march=armv8.3-a` on an AArch64 render: litmus7
lowers a two-sided acquire read to LDAPR (ARMv8.3 RCpc), which the assembler's
default base rejects; `litmus/libdir/armv8.3.cfg` is upstream's spelling of
the same flag. The `Makefile` applies it only where `uname -m` matches
(`HET_HOST_CFLAGS`), because `gcc` rejects a foreign `-march` before
preprocessing and would replace the `#error` with a complaint about the flag.

## Build knobs and link targets

Both link paths write `./<t>`, so `hetlitmus/campaign.py` runs `./<test>` and
stays vendor-agnostic; `<target>-bin` is `.PHONY` and always relinks.

`make <t>` refuses (exit 3) rather than being absent. On a CUDA render the GPU
object is `<t>.o`, which GNU make's built-in `%: %.o` rule would link with
`$(CC)`; `.SUFFIXES:` removes the built-in rules, and the explicit `<t>` rule
is `.PHONY` so that an existing binary is never "up to date".

Compile-time knobs go through the compiler variable, the `-D` route:
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`. A `-D` knob changes no
source, so rebuild with `make clean` first (`hetlitmus/build.sh` does).
`SIZE_OF_TEST` and `NUMBER_OF_RUN` are emitted as unguarded `#define`s and
cannot be lowered this way; `HET_RUNS_MAX` (clamped to `NUMBER_OF_RUN`) is the
only run-count lever. `HET_PLACE` exists only on a render whose target has two
memory pools to bind a page between: the HIP render (MI300A, one HBM pool) has
no placement code and `#error`s on a non-zero value (`het_alloc_hip.inc`)
rather than printing a placement it did not perform; on that render the
interconnect is driven by the noise knobs instead.

**`CUDA_ARCH` / `HIP_ARCH`.** Name the device arch explicitly
(`CUDA_ARCH=sm_90 make cuda-bin`), never `-arch=native`: the arch a binary was
built for must be a recorded value, and `native` records nothing.
`hetlitmus/probe-cuda.sh` (`probe-hip.sh`) writes the box's value to
`probe.txt` as `suggested_cuda_arch` (`suggested_hip_arch`) and
`hetlitmus/build.sh` takes it from there. The probe itself is built as
`compute_75` PTX and JIT-compiled at load, so it runs before any arch is known.
A render that contains a one-sided fence refuses any CUDA target below sm_90 at
compile time (`cuda-emitter.md`, "nvcc compile").

Repo paths an emitted file names (`hetlitmus/docs/het-emission.md` in the
README, `hetlitmus/campaign.py` in the runtime headers) resolve against a
herdtools7 checkout, not the harness directory: the headers beside a harness
are copies of `litmus/het-runtime/*`.

## The pair a harness names

A harness is a **(CPU ISA × GPU dialect) pair**, not a machine.

* **Printouts name mechanisms.** The noise sentences in the emitted driver
  and in `litmus/het-runtime/het_verdict.h` say "host-device interconnect"
  and its halves as literal text; the emitter stamps none of it, so no build
  turns a printed sentence into a claim about a part.
  `HET_PLACE_LEVER` is the one stamped word, and it is a dialect fact:
  `mbind(MPOL_BIND)` on the CUDA render, none on HIP, where `het_verdict.h`'s
  default names the mechanism.
* **`HET_PAIR_NAME`** is stamped by every emission and is the only thing that
  says which pair a binary measured: a harness built for the wrong pair
  compiles, runs and reports identically. The label is derived once
  (`litmus/hetEmit.ml`, `id_pair_label`) and carried to the `pair:` line
  litmus7 prints, the stamp and the README's `Pair:` line.
* **The one target-specific number is a build knob.** `HET_LLC_MB` is the
  last-level cache a noise buffer must exceed to cross the interconnect at
  all; below it the buffer is served from cache. On MI300A that level is the
  256 MB MALL on the I/O die [Tee25 Table 1]:

  ```
  make hip-bin HIPCC="hipcc -DHET_LLC_MB=256"
  ```

  Unsupplied, `het_cpu_stress.h` defaults to a figure from another part
  ([Bagchi26 Table 1]) and sets `HET_LLC_MB_IS_FALLBACK`, which selects the
  warning arm that discloses the default as a fallback.

## Scope / limits

* CPU ISAs: AArch64 and x86_64 (by tag); GPU dialects: CUDA and HIP (by
  `-gpu-target`); all four pairs emit. The x86_64 rendering of the corpus is
  produced on demand by `hetlitmus/tests/het/generate.sh --cpu-arch x86_64
  OUTDIR` and is not committed as a corpus: under x86-TSO the CPU tokens
  collapse (`corpus-grid.md`, "The CPU ISA of a rendering"), so distinct names
  render the same experiment, and the corpus admits no duplicate experiment.
  Names are name-for-name with the committed corpus (`<name>-x86_64`).
* **Refusal is fail-closed.** litmus7 prints
  `HetLitmus REFUSED (het|gpu-only|isa-scan) <test>: <why>` on stderr and
  exits **3** (`HetArch.refused`), distinct from litmus7's own exit 2 (usage,
  lex-rename; `litmus/litmus.ml`): litmus7's batch driver reports a per-test
  failure and exits 0, which a caller redirecting stdout reads as success. A
  refusal leaves nothing on disk — the files this invocation wrote and the
  directory it created (never one it found) are removed — and a compile-only
  pass derives the harness without writing.
* **A het test has at least one `gpu` proc.** An all-CPU `Het` test is
  refused, and `hetgen7` refuses a `-devices` list naming no `gpu`: threads
  all of one architecture exercise no compound composition ([Goens23] §4.6),
  and an all-CPU cycle is litmus7's own path.
* **The GPU column admits what `hetlitmus/bells/gpu.bell` declares**
  (`GpuLang.check_program`, before any file is written, the same under either
  target): loads, stores and fences; `mov`, a branch, `rmw` and `call` are
  refused. An access or fence carries one order from its own set, then one
  scope, in that order — a Bell annotation group is positional
  (`lib/BellModel.ml`, `check_event`) — so an order-less access, a scope-first
  pair and a relaxed fence are refused. Registers are the numbered `rN`; no
  allocator runs over this column, so a symbolic `%T1` is refused.
* **The launch geometry is the test's `scopes:` tree** (`GpuLang.scopes_of`,
  read by both arms; a block is a maximal subtree under a `cta` node,
  `cuda-emitter.md`, "Mappings"). A tree that does not parse, places a
  non-`gpu` proc, places a proc twice, declares an empty `cta` or leaves a
  `gpu` proc out is refused; with no tree, or for a proc under no `cta`, the
  proc gets a block of its own. The tree fixes the block count and a floor on
  the block width; the width is `HET_BLOCK_DIM` (`00-environment-design.md`
  §3.3).
* **CPU procs are straight-line.** Their vocabulary is whatever litmus7's own
  compile pipeline accepts; no het-side classifier refuses an instruction by
  name. On the GPU column a structural pseudo is dropped, not refused:
  `instrs_of_pseudo` peels a `Label` and drops
  `Nop`/`Macro`/`Symbolic`/`Pagealign`/`Skip` silently.
* **The condition compiler** (`litmus/hetCond.ml`) refuses a condition naming
  a register no proc makes observable, a location no proc touches, a
  non-integer value, an atom not of the form `loc=v`, or one that folds to a
  constant (a constant-true detector fires every run, a constant-false one
  never; every connective folds over constant operands). It does **not** check
  that some store writes the value an atom asks for: such a condition compiles
  to a permanently false detector reported as a null — caveated
  `HET_CV_ONE_OUTCOME` and excluded from corroboration by
  `het_run_degenerate` — not refused.
* Emission stops at a harness that compiles; nothing is launched.

## From a corpus to a results dir

Four steps, run in a checkout on the machine under test. `RESULTS` (env;
default `hetlitmus/run-out/<date>-<host>`, git-ignored) is shared by all four,
so every artefact of one run sits in one directory.

AArch64 CPU + CUDA:

```
export RESULTS=hetlitmus/run-out/<tag>
sh hetlitmus/probe-cuda.sh                                  # $RESULTS/probe.txt
hetlitmus/emit-het.sh --gpu-target cuda hetlitmus/tests/het  # $RESULTS/emit/<t>/, $RESULTS/emit.log
hetlitmus/build.sh $RESULTS/emit                             # $RESULTS/emit/<t>/<t>, build.txt, build/<t>.log
python3 hetlitmus/campaign.py --corpus $RESULTS/emit \
    --budget-runs 100 --state $RESULTS/campaign.csv          # the state CSV, campaign-logs/, the report
```

x86_64 CPU + HIP (the corpus is rendered first):

```
export RESULTS=hetlitmus/run-out/<tag>
sh hetlitmus/probe-hip.sh
hetlitmus/tests/het/generate.sh --cpu-arch x86_64 $RESULTS/corpus-x86
hetlitmus/emit-het.sh --gpu-target hip $RESULTS/corpus-x86
hetlitmus/build.sh $RESULTS/emit
python3 hetlitmus/campaign.py --corpus $RESULTS/emit \
    --budget-runs 100 --state $RESULTS/campaign.csv
```

`--tests LIST|FILE` on emit, build and campaign takes a comma list or a file
with one name per line (`#` and blanks ignored); a name listed twice is taken
once. The arch is `probe.txt`'s `suggested_cuda_arch` / `suggested_hip_arch`
unless `--arch` names one, and nothing else detects it. The campaign draws a
seed base, prints it and banks it in every state row; `--seed0` replays it. A
harness run alone draws its own base unless `HET_SEED` pins one.

**What the probe decides.** Each `HET_ALLOC` mode is a system-scope atomic
only under a condition of [CudaGuide "Atomicity"], and the tested accesses and
the rendezvous counter are such atomics, so a mode whose condition fails is
not a weaker experiment but an undefined one; the guards in
`het_alloc_cuda.inc` are fatal for that reason.

| key | consequence |
| --- | --- |
| `cooperativeLaunch=0` | the harness exits 2 and nothing runs |
| `coherence_mechanism` (from `usesHostPageTables`) | which mechanism backs a shared page, `hardware-ATS` or `software-HMM`; the two are different experiments and the allocator banner prints it |
| `concurrentManagedAccess=0` | `HET_ALLOC=managed` is fatal, not degraded [CudaGuide "Coherency and Concurrency"] |
| `hostNativeAtomicSupported=0` | on `pinned` a read-modify-write is not system-atomic, so the rendezvous counter can lose increments; the run warns |
| `sysatomic_*` | a short total is decisive that the mode's read-modify-write is not atomic against the CPU; a matching one is weak evidence |

Run-time knobs a campaign varies per invocation are `het_verdict.h`'s knob
block; `HET_ALLOC` is the allocator's (`het_alloc_cuda.inc`) and
`HET_CAP_CPU`/`HET_CAP_GPU` the rendezvous's (`het_rdv.h`). Everything else is
compile-time, through the `-D` route above.
