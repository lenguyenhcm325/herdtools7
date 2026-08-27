# Heterogeneous CPU+GPU harness emission

This document describes how `litmus7` turns a `Het` (compound) `.litmus` test
into **one compilable CPU+GPU harness directory**. It builds on the compound
pseudo-arch / single-arch break (see `docs/het-litmus-format.md`) and on the
GPU-only CudaLang/HipLang emitters (see `docs/cuda-emitter.md`). Cross-device
*execution* on real hardware is out of scope here; emission stops at a harness
that **compiles**.

Two axes are chosen per test rather than hard-wired:

* **CPU ISA is selected by the per-column device tag.** The header tag
  *names* the CPU ISA — `P0:aarch64` or `P0:x86_64` — and `P0:cpu` is a
  back-compat alias for AArch64. litmus7 pre-scans the header, then instantiates
  the matching CPU sub-parser + compile pipeline. The GPU side stays LISA/Bell.
* **The GPU dialect is selected by `-gpu-target`.** One LISA parse
  yields the ONE render that flag names — `<t>.cu` (CUDA) or `<t>.hip` (HIP) —
  from a shared driver template; only the per-instruction lowering and a few
  host tokens differ. The flag is mandatory on the `Het` and `LISA` arms and has
  no default: a harness directory carries one vendor's render and one vendor's
  build arms (`litmus/hetDialect.ml`).

## Reproduce

```
# AArch64 CPU + CUDA (the (AArch64, cuda) pair). Emits ./MP-het/ with the .cu:
litmus7 -gpu-target cuda -set-libdir herd/libdir hetlitmus/tests/het/MP-het.litmus
( cd MP-het && sh comp.sh )        # CUDA: nvcc -c + gcc -c (+clang aarch64), exit 0

# x86_64 CPU + HIP (the (x86_64, hip) pair), from a committed x86_64 rendering (tests/het-x86):
litmus7 -gpu-target hip -o hip-out -set-libdir herd/libdir \
  hetlitmus/tests/het-x86/MP-cg-sys-relaxed-x86_64.litmus
( cd hip-out/MP-cg-sys-relaxed-x86_64 && sh comp.sh )  # hipcc --offload-arch=gfx942 -c
```

The harness directory is written next to the current directory (or into the
`-o <dir>` directory if one is given). The command exits 0: a `Het` test
compiles to its own self-contained harness, so litmus7 builds **no** suite-level
run harness (and therefore needs no `_show.awk`/`cache.h` runtime from the
libdir — which is why `-set-libdir herd/libdir` is fine even though those files
live under `litmus/libdir`).

Emission is deterministic: the same `.litmus` and the same `-gpu-target` yield
byte-identical output.

## CPU ISA from the device tag (a functor, not a flag)

The harness **derivation** is a functor over the CPU module chain,
`HetEmit.Make` in `litmus/hetEmit.ml` (the seam back to `Top`'s scope is the
options slice, the splitter, and `Make`'s compiled-CPU-code extractor, closed at
the dispatch site), instantiated by the `` `Het `` dispatch arm at the ISA
the header asks for:

1. the arm reads the program section and calls `HetArch.scan_cpu_isa` on its
   header row (`P0:… | P1:… ;`), which maps every CPU column's tag to
   `IsaAArch64` / `IsaX86_64` (`cpu`/`aarch64`/`arm` → AArch64; `x86_64`/`amd64`
   → X86_64); no CPU column ⇒ AArch64 default, and a header whose CPU columns
   name two ISAs is refused — a harness is derived over **one** CPU backend;
2. the matching CPU modules are built (`AArch64Arch_litmus` +
   `AArch64Compile_litmus` + `AArch64Parser`, **or** `X86_64Arch_litmus` +
   `X86_64Compile_litmus` + `X86_64Parser`) and passed to `HetEmit`;
3. `CpuF` supplies the per-column sub-parser (`parse_column`) and one
   `HetCpuFront.toolchain` the ISA module itself defines: the human ISA label,
   the host CPP macro (`__aarch64__` / `__x86_64__`), the `uname -m` word its
   link guards compare, an optional `(clang-triple, -std)` for cross-assembly
   (`None` when the build host already *is* this ISA, e.g. x86_64 → native
   `gcc`) and the CPU compile flags.

`X86_64Parser.mly` gained the single-column `instr_option_seq` start rule
(ARM/AArch64/PPC/RISCV already exposed it); since `X86_64Base.parsedInstruction =
instruction`, it returns exactly the `Cpu.parsedPseudo list` the het column
parser consumes. The GPU side is fixed (LISA/Bell) inside the functor.

What the functor derives is a `HetHarness.t` — the harness as data — and every
file in the directory is then rendered by a plain module over that record
(`HetCpuFile`, `HetGpuFile` with `HetDriverMain`, `HetBuildFiles`), none of them
parameterised by the CPU module chain.

## What the `Het` dispatch arm emits

Each `Het` test yields a directory containing (CPU ISA = whatever the tag named):

ONE GPU dialect per directory: the render and the build arms are the
ones `-gpu-target` named, and no other vendor's. `<v>` below is that target word.

| file            | role                                                         | compiled by |
|-----------------|--------------------------------------------------------------|-------------|
| `<t>.cu` **or** `<t>.hip` | GPU kernel + host driver in the selected dialect (alloc, barrier, launch, readback) — one of the two, never both | `nvcc -c` / `hipcc -c` |
| `<t>_cpu.c`     | CPU thread(s): real `<ISA>` inline asm, printed by litmus7's own `ASMLang.dump_fun` | `gcc -c` (native or `#else` shim) **and**, for a foreign-ISA host, `clang --target=<triple> -c` (real asm) |
| `outs.c`/`.h`   | litmus7's own outcome histogram, embedded verbatim           | `gcc -c`    |
| `comp.sh`       | compile-only driver, `sh comp.sh [<v>\|<v>-link]` (default `<v>`); the absent vendor's word is refused by name | —           |
| `Makefile`      | same; `make <v>` / `make <v>-bin` targets                    | —           |
| `README.md`     | one-paragraph description                                     | —           |

The five required pieces, and where each is reused rather than reimplemented:

1. **P(cpu) → a CPU pthread running real AArch64 asm.** The arm projects the
   compound parsed program onto a CPU-only `MiscParser` test
   (`HetArch.to_cpu_pseudo`) and runs the **genuine litmus7 AArch64 compile
   pipeline** (`SymbReg` → `AArch64Compile_litmus` → `Template`) over it, and it
   is litmus7's **own printer** that writes the body: `CpuKit.dump_fun` is
   `ASMLang.dump_fun`, handed the compiled template, the global environment and
   the value environment exactly as litmus7's own CPU harness hands them. What
   lands in `<t>_cpu.c` is therefore litmus7's lowering of the column, marker
   comments and all (`#START _litmus_P<n>` … `#END`), with no het vocabulary in
   between. Around it the emitter writes one non-static wrapper per CPU proc,
   `void het_run_P<n>(<addr params>, <int* out params>)`, whose parameter lists
   come from `Cpu.Out.get_addrs` and `Cpu.Out.final`, plus a portable `#else`
   shim for a host of another ISA. **The slot arithmetic is the caller's**: the
   asm addresses a bare pointer as litmus7 writes it, so `<t>.cu`'s
   `cpu_thread_P<n>` passes `<g> + _n*HET_SLOT_STRIDE_WORDS` for each address and
   `bufP<n>_<i> + _n` for each output register. One tested mnemonic needs a build
   flag rather than a rewrite: LDAPR is ARMv8.3 RCpc, so `-march=armv8.3-a`
   (upstream's own mechanism — `litmus/libdir/armv8.3.cfg`) rides every
   compilation that assembles the real AArch64 body. `comp.sh`'s
   `clang --target=aarch64-linux-gnu` cross line carries it whatever the build
   host is; the host `gcc` line — `comp.sh`'s and the emitted `Makefile`'s alike,
   and the only rule the `Makefile` has for `_cpu.c` — carries it only where
   `uname -m` is this test's ISA, because everywhere else that object is the
   portable shim and another ISA's flags are not the shim's to take.

2. **P(gpu) → a GPU kernel (CUDA *and* HIP).** The arm projects onto the
   Bell/LISA side (`HetArch.to_gpu_pseudo`) and builds the kernel by reusing the
   GPU dialect's scoped-atomic translation. The layout/globals/result-register
   analysis is shared by both dialects (`litmus/gpuLang.ml`: `collect_globals`,
   `result_regs`, `layout_of_scopes`, `instrs_of_code`), so only `dump_instr`
   is per dialect: CUDA → `cuda::atomic_ref<int, thread_scope_*>`, HIP →
   `__hip_atomic_*`. Only the het-specific scaffold (the barrier + per-proc
   guard) is new.

3. **Shared vars in `{cuda,hip}MallocManaged`.** Every shared location (the
   union of the CPU thread's addresses and the kernel's globals) is allocated in
   managed memory, so the same physical bytes are coherent to the CPU and the
   GPU (NVLink-C2C on GH200, XGMI/APU on MI300A). The CPU thread receives them as
   `int*` params (the addresses the inline asm dereferences); the kernel as
   `int*` params (dereferenced by the scoped atomic).

4. **A per-iteration cross-device rendezvous.** One `uint64_t* barrier` counter
   on its own padded shared allocation, arrived at and polled at **system
   scope** on both sides — `cuda::atomic_ref<uint64_t,
   cuda::thread_scope_system>` (CUDA) or `__hip_atomic_fetch_add`/`__hip_atomic_load(…,
   __HIP_MEMORY_SCOPE_SYSTEM)` (HIP). Iteration `n` opens when every participant
   has added 1 and seen the counter reach `NPART*(n+1)`; `NPART` = #CPU pthreads
   + #GPU test lanes. Both operations are **relaxed** and no fence stands between
   or behind them: the rendezvous decides *when* an iteration starts and adds no
   ordering to what it then executes, which is why strengthening it would erase
   the cache state under test (`litmus/het-runtime/het_rdv.h`,
   `00-environment-design.md` §3.3). The counter is reset once per run, not per
   iteration, and the participants are never joined and relaunched in between.
   A participant that hits its cap records a 0 in its own arrival flag and the
   iteration is discarded.

5. **GPU readback merged into litmus7's outs histogram, slot by slot.** The kernel
   writes each result register to `bufP<p>_<i>[_n]`, the CPU asm writes its
   observed registers through the `*out_<p>_<reg>` pointers its caller aimed at
   slot `n`, and every shared location keeps iteration `n`'s value in its own
   slot. **After** the run the driver walks the slots once: it ANDs the arrival
   flags, discards or scores, assembles the outcome vector `_o[]` from both
   sources and calls litmus7's own `add_outcome_outs(...)` at the single call
   site. `dump_outs` prints the histogram, marking outcomes that satisfy the
   test's `exists` condition (compiled to a C predicate over `_o[]`).

## One render per `-gpu-target`, and `comp.sh [<target>|<target>-link]`

One LISA parse, one GPU file per emission. The driver template is rendered from
a `gpu_dialect` record; the registry `dialects = [cuda_dialect; hip_dialect]`
(`litmus/hetDialect.ml`) holds one record per vendor and `-gpu-target` filters it,
so every per-vendor site — the render (`litmus/hetGpuFile.ml`), the comp.sh
arms, the Makefile rules and the README (`litmus/hetBuildFiles.ml`) — folds over
the selected list and a third vendor is an entry rather than an edit at each
site. CUDA and HIP differ only in those record fields; the kernel
guards, the pthread wrappers, the outcome histogram, and the `<<<…>>>` launch
(hipcc accepts triple-chevron) are shared verbatim.

`comp.sh` takes one argument, this render's target (the default) or
`<target>-link`:

* the **shared CPU steps** run first — `gcc -c outs.c`, `gcc -c <t>_cpu.c`, and
  (for a foreign-ISA host) the clang cross-assembly below;
* the **GPU step branches** on the target and **hard-fails if the toolchain is
  absent** (`command -v "$NVCC"`/`"$HIPCC"` … || exit 1): `cuda` →
  `nvcc -std=c++17 -arch=$CUDA_ARCH -c <t>.cu`; `hip` →
  `hipcc --offload-arch=$HIP_ARCH -std=c++17 -c <t>.hip`.

The `Makefile` mirrors this with the render's own object target (`all: <target>`)
plus `<target>-bin`, which links. Name the GPU arch explicitly
(`CUDA_ARCH=sm_90 make cuda-bin`): `-arch=native` only exists from CUDA 11.5
update 1 onwards, and a build for the wrong arch links and exits 0 just as
happily. `CUDA_ARCH` is `sm_75` on a T4G, `sm_90` on a GH200 and `sm_121` on a
GB10; `hetlitmus/probe-cuda.sh` reads the box's own value into `probe.txt` as
`suggested_cuda_arch`, and `hetlitmus/build.sh` takes it from there. The probe
itself is compiled to `compute_75` PTX and JITs at load, so the one command runs
before any arch is known — and not to `compute_60`, which CUDA 13 drops with the
rest of pre-Turing.

### The emitted `README.md`, and what it points here for

The emitted `README.md` is a page: the file list, the build and link commands, a
closing `Target:` line naming the vendor and dialect it renders, and a `Pair:`
line naming the pair it was built for. Everything a reader needs *once* rather
than per harness lives here instead: emission writes one harness directory per
test per lane, so a paragraph put there is copied once per test.

**Where an emitted file's repo paths point.** Every repo path an emitted file
names — `hetlitmus/docs/het-emission.md` in the README, `hetlitmus/campaign.py`
in the runtime headers — resolves against a herdtools7 checkout, never against
the harness directory; the headers beside a harness are copies of
`litmus/het-runtime/*`, so such a path names the original rather than the file
next to it. A harness travels to a GPU box and comes back
as a results tree, and those pointers are that tree's only trail back to the
emitter: provenance for a reader who has the repo, inert for one who does not.

**Why there is one binary path per vendor.** Both link paths write `./<t>`, so
`hetlitmus/campaign.py` runs `./<test>` directly, reads its `HetStats`
line and stays vendor-agnostic. The GPU compiler driver pulls
in its own device runtime; `-lpthread -lm` cover the CPU threads and the emitted
render's own `sqrt` (it includes `<cmath>`; `het_verdict.h` calls no math function).
`<target>-bin` is `.PHONY` and always relinks, so a build can never report
success while leaving a stale binary in place.

**Why both link paths refuse a foreign host.** `<t>_cpu.c` carries the tested asm
under `#if defined(<host_macro>)` and a portable shim in the `#else` branch, so
`gcc -c` succeeds anywhere. Linking elsewhere therefore produces a binary that
runs, prints a histogram and tests nothing, and both `comp.sh <target>-link` and
`make <target>-bin` compare `uname -m` against the render's ISA and refuse
instead (`comp.sh` exits 3; the make recipe exits 3, which `make` reports as its
own exit 2). `make <t>` refuses too, and the refusal rule is not by itself what
makes that hold. With every link target phony no rule names `./<t>`, and on a
CUDA render the GPU object *is* `<t>.o` — exactly what GNU make's built-in
`%: %.o` rule wants, so make would link past the guard with `$(CC)`.
`.SUFFIXES:` is what removes that rule: the built-in link rules are
suffix-derived, so clearing the suffix list drops `%: %.o` and `%: %.c`
together, and every object rule the harness emits is explicit. Reached, the
built-in rule would not even leave a wrong binary behind — `$(CC)` links no
device runtime, so the link dies on undefined `cudaLaunchKernel` — but that
failure is incidental rather than the guard's, so `./<t>` also gets a rule of
its own, which refuses by name and points at `<target>-bin`. That rule is
`.PHONY` as well: a plain rule whose target already exists is "up to date", so
`make <t>` would otherwise exit 0 and hand back whichever binary was lying in
the directory.

**Compile-time knobs** go through the compiler variable, e.g.
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`. `SIZE_OF_TEST` and
`NUMBER_OF_RUN` are the two that cannot: they are emitted as unguarded
`#define`s, so `-D` cannot lower them, and `HET_RUNS_MAX` (clamped to
`NUMBER_OF_RUN`) is the only lever on the run count. `HET_PLACE` is the exception:
page placement exists only on a render whose runtime has a placement API, and a
non-zero value is an `#error` on a render that has none
(`litmus/het-runtime/het_alloc_hip.inc`) rather than a value reported in the
banner without anything having been placed.

## The pair a harness names

A harness is not "an AArch64 test" or "a HIP test": it is a **(CPU ISA x GPU
dialect) PAIR**. That pair, and no machine, is what a render names.

* **A render names no machine.** The words its printouts are written around —
  `HET_LINK_NAME`, `HET_HOST_HALF`, `HET_DEV_HALF` — are plain `#define`s in
  `litmus/het-runtime/het_verdict.h` naming the *mechanism*: the host-device
  interconnect and its two halves. The emitter stamps none of them, so no build
  can turn a printed sentence into a claim about a part. `HET_PLACE_LEVER` is
  the one word that does vary, and it is a **dialect** fact rather than a
  machine one (`cudaMemAdvise` on the CUDA render; the HIP render has no
  placement code and `#error`s on a non-zero `HET_PLACE`); a dialect that
  supplies no lever gets no `#define` at all, and `het_verdict.h`'s own
  `"the page-placement lever"` default names the mechanism instead.
* **`Target:` names the vendor and the dialect.** The emitted `README.md` ends
  with `Target: NVIDIA CUDA.` (or `Target: AMD HIP.`) — what the render *is*,
  which the render itself decides.
* **`Pair:` names what it was built for**, from `HET_PAIR_NAME`, which **every**
  emission stamps because it is true of the binary. It is the short
  `(ISA, dialect)` label the verdict and statistics layers print where they must
  identify the target: a harness built for the wrong pair compiles, runs and
  reports identically, and this define is the only thing that says which pair it
  was measuring. The label is derived once in `litmus/hetEmit.ml` and carried
  to every emitter in the harness record's identity — the `pair:` line litmus7
  prints, the `HET_PAIR_NAME` stamp and the README's `Pair:` line all take it —
  so the two stamped frames cannot print different labels.
* **The one target-specific *number* is a build knob.** `HET_LLC_MB` is the
  last-level cache a noise buffer must exceed to cross the interconnect at all;
  below it the buffer is served from cache and the noise stresses nothing. It is
  supplied through the compile-knob channel above, e.g. on an MI300A box, whose
  last level is the 256 MB MALL / AMD Infinity Cache on the IOD
  ([Tee25 Table 1], p. 1111 — MI300A: sL1 16 KB, L2 4 MB/XCD, MALL 256 MB):

  ```
  make hip-bin HIPCC="hipcc -DHET_LLC_MB=256"
  ```

  With nothing supplied, `het_cpu_stress.h` defaults to 114 MB —
  `max(Grace L3, Hopper L2)` ([Bagchi26 Table 1]), a figure measured on another
  part — and sets `HET_LLC_MB_IS_FALLBACK`, which selects the arm of the
  driver's warning that discloses it as a fallback rather than naming it as this
  target's cache.

## The CPU object: native vs. cross-assembly

`<t>_cpu.c` holds the real `<ISA>` inline asm under `#if defined(<host_macro>)`,
with a clearly-marked portable **shim** in the `#else` branch so `gcc -c` always
succeeds. Whether a *real* asm object is also produced depends on `CpuF.cross`:

* **x86_64 CPU on an x86_64 build host** (`cross = None`): the host macro
  `__x86_64__` is already defined, so the `gcc -c` above assembles the **real**
  x86 asm directly — no extra step.
* **AArch64 CPU on an x86_64 build host** (`cross = Some ("aarch64-linux-gnu",
  "gnu11")`): the host `gcc` takes the shim; `comp.sh` additionally runs
  `clang --target=aarch64-linux-gnu -std=gnu11 -c <t>_cpu.c` when `clang` is
  present — clang's integrated assembler emits a genuine `ELF aarch64` object
  from the real asm, no cross-binutils needed. On the GH200 itself (`aarch64`
  host) `gcc`/`nvcc`'s host compiler assembles it natively and the clang step is
  redundant.

## Where the code lives (and what is *not* touched)

All het logic is confined to:

* `litmus/HetArch.ml` — `to_cpu_pseudo`/`to_gpu_pseudo` (project a compound
  internal pseudo back onto a sub-arch) and the top-level CPU-ISA tag
  classifier + header pre-scan (`cpu_isa_of_tag`, `scan_cpu_isa`) the dispatch
  arm needs *before* it can choose CPU modules;
* `litmus/hetSlurp.mll` — the section-slurp lexer `HetArch`'s parser reads the
  whole program section through, verbatim, before re-lexing it column by
  column with each column's own ISA lexer;
* the generated `HetPayloads` module — the verbatim runtime payloads
  (`outs.{c,h}` cat'ed from `litmus/libdir/_outs.{h,c}`, plus the
  `litmus/het-runtime/*` headers), wrapped by the rule in `litmus/dune`;
* `litmus/hetDialect.ml` — the `gpu_dialect` record, the registry holding one
  of them per vendor, and the `-gpu-target` option that picks exactly one row;
  read by both GPU-emitting arms and by litmus7's option table;
* `litmus/hetGpuOnly.ml` — the other GPU-emitting arm, `` `LISA ``: a scoped
  Bell/LISA test with no CPU column, parsed once and written out as one bare
  kernel file in the selected dialect (no harness directory, no payloads);
* `litmus/hetEmit.ml` — the `HetEmit.Make` functor: it parses the compound
  test, derives the harness and writes the directory; every refusal fires
  there, before the directory exists;
* `litmus/hetHarness.ml` — that harness as data: the per-proc records, the read
  buffers, the outcome slots, the memory-object table whose two families
  (race surface, observation record) the driver's allocation, per-run reset,
  readback and free each fold over, and the naming every emitter below shares;
* `litmus/hetCpuFile.ml` — the `<t>_cpu.c` render: the CPU threads litmus7's
  own asm printer writes, and the entry points the driver calls;
* `litmus/hetGpuFile.ml` — the `.cu`/`.hip` render: the prelude, the kernel
  (test lanes and stressing workgroups), the CPU pthread wrappers and the
  outcome labels;
* `litmus/hetDriverMain.ml` — the driver's `main()`: allocation, launch
  geometry, the stress populations, the run loop, the slot readout and
  teardown;
* `litmus/hetBuildFiles.ml` — `comp.sh`, the `Makefile` and the `README.md`,
  each folding over the selected dialects;
* `litmus/hetCond.ml` — a test's condition, as pure functions over the parsed
  proposition: which shared locations its atoms name, so the emitter knows which
  locations need an outcome column, and its compilation to the C predicate that
  scores one iteration;
* `litmus/hetCpuFront.ml` — the per-CPU-ISA column frontend (`CpuF`), one
  module per supported CPU ISA, each providing its own toolchain record (ISA
  label, host-detection tokens, cross-assembly pair, CPU compile flags);
* the `` `Het `` dispatch arm in `litmus/top_litmus.ml` — the per-ISA module
  instantiation, closing `HetEmit.Make`'s seam over `Top`'s scope.

The only edits outside those are the ones the two selection axes strictly
require: `lib/X86_64Parser.mly` (the `instr_option_seq` start rule),
`gen/hetGen.ml` (the `-cpu-arch` flag, below) and the `CpuKit` seam in
`litmus/top_litmus.ml`, which hands the het arm the compiled record and
`ASMLang.dump_fun` itself. `ASMLang` is **reused, not modified**: this branch
never edits it, litmus7's own CPU-only runs still instantiate it, and it is
also what writes the het CPU body (piece 1 above).
`CudaLang`/`HipLang` are reused for the GPU lowering (their shared half is
`litmus/gpuLang.ml`). One general (non-het) robustness fix lives in
`litmus/dumpRun.ml`: when no test compiled to a C run harness (e.g. an
all-`Het` invocation), litmus7 does not copy the run-harness runtime from the
libdir (nothing to run), so the command exits cleanly.

## Generating het tests for a CPU ISA (`hetgen7 -cpu-arch`)

`hetgen7` dispatches its CPU-side `*Compile_gen` builder exactly as `diyone`
does (`AArch64Compile_gen` / `X86_64Compile_gen`):

```
hetgen7 … -cpu-arch x86_64 -cpu "PodWW Rfe PodRR Fre" -gpu "…" -bell ptx.bell
```

writes a test whose cpu column carries the `x86_64` tag and holds x86 cells
(`movl $1,(x)`). With **no** `-cpu-arch` the default is AArch64 (the cpu column
keeps its `cpu` back-compat tag).

## Scope / limits

* CPU ISAs wired: **AArch64** and **x86_64** (selected by tag); GPU dialects
  wired: **CUDA** and **HIP** (selected by `-gpu-target`). All four pairings
  emit, and each render stamps the pair it was built for as `HET_PAIR_NAME`.
* Both CPU ISAs emit a **real body, litmus7's own**: the tested mnemonics as
  litmus7 lowers the column (`str`/`stlr`/`ldr`/`ldar`/`ldapr`/`dmb` on AArch64,
  `movl`/`mfence` on x86-64), on `int` locations, with the store values the
  `.litmus` writes and the loads recorded into per-iteration buffers by the
  wrapper's caller. Nothing is widened: the x86 store is the column's own
  `movl $1,%[x]` on an `int` slot. The renderings themselves are produced on demand by
  `hetlitmus/tests/het/generate-x86.sh OUTDIR` — never committed, because many
  of them are byte-identical to a sibling below their two-line name header
  (the x86-TSO collapse: `corpus-grid.md`, "Census rationale") and the corpus
  admits no duplicate experiment. Their names are name-for-name with the
  committed corpus (`<corpus name>-x86_64`).
* A het emission that **cannot** be completed is fail-closed: litmus7 prints
  `HetLitmus REFUSED (het|gpu-only|isa-scan) <test>: <why>` on stderr and exits
  **3** (`HetArch.refused`) — distinct from litmus7's own exit **2** (usage and
  lex-rename errors, `litmus/litmus.ml`), so a wrapper can tell the two apart.
  Every het emission boundary routes through `HetArch.refused`: `HetEmit.run`,
  `HetGpuOnly.compile`, and the `` `Het `` dispatch arm, which owns the
  pre-parse ISA scan, where a header naming two CPU ISAs is refused. The file
  emitters run inside `HetEmit.run`'s boundary, so a failure in any of them is
  reported the same way. A refusal leaves nothing on disk: the boundary removes
  the files that invocation wrote and the harness directory it created (never a
  directory it found already there), and litmus7's compile-only pass derives the
  harness without writing it, so a test that will be refused is refused before
  the suite driver writes anything of its own. litmus7's own batch driver (`Answer.Interrupted`,
  `litmus/dumpRun.ml`) would have reported the refusal and still exited 0, which
  made a missing harness look like success to any caller that redirects stdout.
* **A het test has at least one `gpu` proc.** An all-CPU `Het` test is refused
  (`HetLitmus REFUSED (het)`, exit 3), and `hetgen7` refuses a `-devices` list
  naming no `gpu`. A test whose threads are all of one architecture exercises no
  compound composition ([Goens23] §4.6), and an all-CPU cycle is litmus7's own
  X86_64/AArch64 path.
* **The GPU column admits exactly what `hetlitmus/bells/ptx.bell` declares.**
  `GpuLang.check_program` runs over every GPU proc before any file is written
  and gives the same answer under `-gpu-target cuda` and `hip`:
  - loads, stores and fences are rendered; `mov`, a branch, an `rmw` and
    a `call` are **refused**, not lowered and not commented out;
  - an access or fence carries one order from its own set (`R` takes
    `relaxed`/`acquire`/`sc`, `W` takes `relaxed`/`release`/`sc`, `F` takes
    `acquire`/`release`/`acq_rel`/`sc`) and then one scope (`cta`/`gpu`/`sys`),
    in that order, because a Bell annotation group is positional and herd7
    matches it position by position (`lib/BellModel.ml`, `check_event`). An
    order-less `w[] x 1`, an `f[sys]`, an `r[release,sys]`, a scope-first
    `w[sys,relaxed]` and a relaxed fence (a form neither vendor has) are all
    refused;
  - registers are the numbered `rN`: no register allocator runs over this
    column, so a symbolic `%T1` is refused.
* The CPU projection supports plain straight-line procs (the het corpus). The
  instruction vocabulary is litmus7's own — whatever `AArch64Compile_litmus`
  / `X86_64Compile_litmus` accept and `ASMLang.dump_fun` prints — so there is no
  het-side classifier to refuse an instruction by name, and the CPU half's
  faithfulness rests on litmus7's lowering (`faithfulness.md`); the projection
  hands litmus7's own compile pipeline whatever the column parsed. On the GPU
  column a structural pseudo is dropped rather than refused: `instrs_of_pseudo`
  (`litmus/gpuLang.ml`) peels a `Label` and drops a
  `Macro`/`Symbolic`/`Pagealign`/`Skip`, so a LISA proc carrying one emits a
  straight-line body with it silently removed.
* **What the condition compiler (`litmus/hetCond.ml`) refuses, and the one
  thing it does not check.**
  A test is refused (`HetLitmus REFUSED`, exit 3) when its condition names a
  register no proc makes observable, when it observes a location no proc of the
  test touches (no slot backs it), when an atom's value is not an integer, when
  an atom is not of the form `loc=v`, or when the whole predicate compiles to a
  constant — a constant-true detector reports the weak behaviour every run and a
  constant-false one reports "Never" every run. It does **not** check that some
  store in the program ever writes the value an atom asks for. A condition asking for a value nothing
  writes therefore compiles to a detector that is permanently false, which the
  run reports as a null — caveated `HET_CV_ONE_OUTCOME` when every scored
  iteration read the same vector, and excluded from corroboration by
  `het_cell_degenerate`, but not refused. A disclosed limit, not a guarantee.
* COMPILE-ONLY: no GPU is launched. Stress/observability tuning (making the CPU
  and GPU ops actually race) and on-hardware runs are hardware-only work
  (`00-environment-design.md` §6).

## From a corpus to a results dir

A corpus becomes a results dir in four steps, run in a checkout on the machine
under test. `RESULTS` is the results dir (env; default
`hetlitmus/run-out/<date>-<host>`, the one ignored root), and every step writes
into it.

| step | command | writes |
| --- | --- | --- |
| probe | `RESULTS=… sh hetlitmus/probe-cuda.sh` (or `probe-hip.sh`) | `$RESULTS/probe.txt` |
| emit | `hetlitmus/emit-het.sh --gpu-target cuda\|hip CORPUS [--tests LIST\|FILE] [-o EMIT]` | `EMIT/<t>/…` (default `$RESULTS/emit`), `$RESULTS/emit.log` |
| build | `hetlitmus/build.sh EMIT [--tests LIST\|FILE] [--arch A] [-j N]` | `EMIT/<t>/<t>`, `$RESULTS/build.txt`, `$RESULTS/build/<t>.log` |
| execute | `python3 hetlitmus/campaign.py --corpus EMIT --budget-runs N --state $RESULTS/campaign-<tag>.csv [--log-dir $RESULTS/runlogs-<tag>] [--tests LIST\|FILE] [--timeout S]` | the state CSV, the transcripts, the final report |

`--tests` everywhere takes a comma list or a path to a file with one name per
line (`#` and blanks ignored, the first field of a line is the name); with no
`--tests`, build and campaign take the whole corpus. The arch is `probe.txt`'s
`suggested_cuda_arch` / `suggested_hip_arch` unless `--arch` names one, and
nothing else detects it.

**What the probe decides.** These are the conditions under which a
`cuda::thread_scope_system` atomic is atomic at all [CudaGuide "Atomicity"], and
every tested access and the rendezvous counter is such an atomic, so a mode whose
condition fails is not a weaker experiment but an undefined one.

* `cooperativeLaunch=0` — the harness returns 2 and nothing runs.
* `usesHostPageTables` — which coherence mechanism is behind a shared page: 1 is
  hardware, 0 is software, and the two are different experiments
  [CudaGuide "Unified Memory Paradigms"].
* `concurrentManagedAccess=0` — `HET_ALLOC=managed` is fatal, not degraded
  [CudaGuide "Coherency and Concurrency"].
* `hostNativeAtomicSupported=0` — `pinned`'s rendezvous counter loses
  increments; each iteration that loses one costs its whole cap and is discarded.
* `sysatomic_*` — a **short** total is decisive that the mode's read-modify-write
  is not atomic against the CPU; a matching one is weak evidence the other way.

The run-time knobs a campaign retunes per invocation are listed at
`litmus/het-runtime/het_verdict.h`'s knob block; `HET_ALLOC` is the allocator's
(`litmus/het-runtime/het_alloc_cuda.inc`) and `HET_CAP_CPU`/`HET_CAP_GPU` are the
rendezvous's (`litmus/het-runtime/het_rdv.h`). Everything else is compile-time
and goes through the compiler variable, the `-D` route above.
