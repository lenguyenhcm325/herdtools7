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

# x86_64 CPU + HIP (the (x86_64, hip) pair), from the committed one-test fixture:
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

## CPU ISA from the device tag (a functor, not a flag)

The harness body used to be AArch64-specific. It is now a **functor over the CPU
module chain**, `HetEmit.Make` in `litmus/hetEmit.ml` (extracted from
`top_litmus.ml`; the seam back to `Top`'s scope is the options slice, the
splitter, and `Make`'s compiled-CPU-code extractor, closed at the dispatch
site), instantiated by the `` `Het `` dispatch arm at the ISA
the header asks for:

1. the arm reads the program section and calls `HetArch.scan_cpu_isa` on its
   header row (`P0:… | P1:… ;`), which maps the first CPU column's tag to
   `IsaAArch64` / `IsaX86_64` (`cpu`/`aarch64`/`arm` → AArch64; `x86_64`/`amd64`
   → X86_64); no CPU column ⇒ AArch64 default;
2. the matching CPU modules are built (`AArch64Arch_litmus` +
   `AArch64Compile_litmus` + `AArch64Parser`, **or** `X86_64Arch_litmus` +
   `X86_64Compile_litmus` + `X86_64Parser`) and passed to `HetEmit`;
3. `CpuF` bundles the per-column sub-parser (`parse_column`), the human ISA
   label, the host CPP macro (`__aarch64__` / `__x86_64__`), and an optional
   `(clang-triple, -std)` for cross-assembly (`None` when the dev host already
   *is* this ISA, e.g. x86_64 → native `gcc`).

`X86_64Parser.mly` gained the single-column `instr_option_seq` start rule
(ARM/AArch64/PPC/RISCV already exposed it); since `X86_64Base.parsedInstruction =
instruction`, it returns exactly the `Cpu.parsedPseudo list` the het column
parser consumes. The GPU side is fixed (LISA/Bell) inside the functor.

## What the `Het` dispatch arm emits

Each `Het` test yields a directory containing (CPU ISA = whatever the tag named):

ONE GPU dialect per directory: the render and the build arms are the
ones `-gpu-target` named, and no other vendor's. `<v>` below is that target word.

| file            | role                                                         | compiled by |
|-----------------|--------------------------------------------------------------|-------------|
| `<t>.cu` **or** `<t>.hip` | GPU kernel + host driver in the selected dialect (alloc, barrier, launch, readback) — one of the two, never both | `nvcc -c` / `hipcc -c` |
| `<t>_cpu.c`     | CPU thread(s): real `<ISA>` inline asm, emitted by `HetCpuBody<ISA>` | `gcc -c` (native or `#else` shim) **and**, for a foreign-ISA host, `clang --target=<triple> -c` (real asm) |
| `outs.c`/`.h`   | litmus7's own outcome histogram, embedded verbatim           | `gcc -c`    |
| `comp.sh`       | compile-only driver, `sh comp.sh [<v>\|<v>-link]` (default `<v>`); the absent vendor's word is refused by name | —           |
| `Makefile`      | same; `make <v>` / `make <v>-bin` targets                    | —           |
| `README.md`     | one-paragraph description                                     | —           |

The five required pieces, and where each is reused rather than reimplemented:

1. **P(cpu) → a CPU pthread running real AArch64 asm.** The arm projects the
   compound parsed program onto a CPU-only `MiscParser` test
   (`HetArch.to_cpu_pseudo`) and runs the **genuine litmus7 AArch64 compile
   pipeline** (`SymbReg` → `AArch64Compile_litmus` → `Template`) over it — but
   it consumes exactly two fields of each compiled template, the address
   parameters (`Cpu.Out.get_addrs`) and the final registers (`Cpu.Out.final`),
   and then drops the template. The asm text itself is written by
   `HetCpuBodyA64`/`HetCpuBodyX86` over `HetCpuPlan`, **not** by
   `ASMLang.dump_fun`: litmus7's own lowering bakes a store's value in as an
   immediate, which leaves no runtime seam for the `K*iter+mu` tag (rationale
   in `litmus/hetCpuPlan.ml`). What that emitter prints is a real
   `asm __volatile__("str %x[_v0],[%[x]]" ...)` block carrying the tested
   mnemonics verbatim — hand-rolled, and genuine inline asm. `<t>.cu`'s
   `cpu_thread_P<n>` arrives at the barrier and calls the `extern "C"
   het_run_P<n>(...)` that `<t>_cpu.c` defines, one per CPU proc.

2. **P(gpu) → a GPU kernel (CUDA *and* HIP).** The arm projects onto the
   Bell/LISA side (`HetArch.to_gpu_pseudo`) and builds the kernel by reusing the
   GPU dialect's scoped-atomic translation. The layout/globals/result-register
   analysis is **identical** for both dialects (`CudaLang.collect_globals`,
   `result_regs`, `layout_of_scopes`, `instrs_of_code` — byte-for-byte the same
   as HipLang's), so only `dump_instr` is parameterised: CUDA →
   `cuda::atomic_ref<int, thread_scope_*>`, HIP → `__hip_atomic_*`. Only the
   het-specific scaffold (the barrier + per-proc guard) is new.

3. **Shared vars in `{cuda,hip}MallocManaged`.** Every shared location (the
   union of the CPU thread's addresses and the kernel's globals) is allocated in
   managed memory, so the same physical bytes are coherent to the CPU and the
   GPU (NVLink-C2C on GH200, XGMI/APU on MI300A). The CPU thread receives them as
   `int*` params (the addresses the inline asm dereferences); the kernel as
   `int*` params (dereferenced by the scoped atomic).

4. **System-scope rendezvous barrier.** A single `int* barrier` in managed
   memory, accessed at **system scope** on **both** sides — `cuda::atomic_ref<int,
   cuda::thread_scope_system>` (CUDA) or `__hip_atomic_*(…,
   __HIP_MEMORY_SCOPE_SYSTEM)` (HIP). Each participant `fetch_add(1, seq_cst)`
   then spins until the count reaches `NPART` (= #CPU pthreads + #GPU threads).
   System scope is used deliberately so the barrier itself is *strong* and does
   not contaminate the relaxed/scoped behaviour under test. The driver resets
   `*barrier = 0` each iteration, between a `pthread_join` + device-sync. The
   `__hip_atomic_*` builtins compile in **host** code under hipcc (verified), so
   the same barrier idiom works in the pthread and in the kernel.

5. **GPU readback merged into litmus7's outs histogram.** The kernel writes each
   result register to `__out[proc*NREGS + n]` (managed memory); the CPU asm
   writes its observed registers through the `*out_<p>_<reg>` pointers. Each
   iteration the driver assembles the outcome vector `_o[]` from **both**
   sources and calls litmus7's own `add_outcome_outs(...)`. `dump_outs` prints
   the histogram, marking outcomes that satisfy the test's `exists` condition
   (compiled to a C predicate `_cond` over `_o[]`).

## One render per `-gpu-target`, and `comp.sh [<target>|<target>-link]`

One LISA parse, one GPU file per emission. The driver template is rendered from
a `gpu_dialect` record; the registry `dialects = [cuda_dialect; hip_dialect]`
(`litmus/hetDialect.ml`) holds one record per vendor and `-gpu-target` filters it,
so every per-vendor site — the render, the comp.sh arms, the Makefile rules, the
README — folds over the selected list and a third vendor is an entry rather than
an edit at each site. CUDA and HIP differ only in those record fields; the kernel
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
happily.

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
`hetlitmus/spotcheck/run-one.sh` and `hetlitmus/campaign.py` exec `./<test>`,
read its `HetStats` line and stay vendor-agnostic. The GPU compiler driver pulls
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
`make cuda-bin NVCC="nvcc -DHET_MEM_STRESS_PCT=0"`. `HET_PLACE` is the exception:
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
  placement code and `#error`s on a non-zero `HET_PLACE`).
* **`Target:` names the vendor and the dialect.** The emitted `README.md` ends
  with `Target: NVIDIA CUDA.` (or `Target: AMD HIP.`) — what the render *is*,
  which the render itself decides.
* **`Pair:` names what it was built for**, from `HET_PAIR_NAME`, which **every**
  emission stamps because it is true of the binary. It is the short
  `(ISA, dialect)` label the verdict and statistics layers print where they must
  identify the target: a harness built for the wrong pair compiles, runs and
  reports identically, and this define is the only thing that says which pair it
  was measuring. `hetlitmus/hetlitmus-run.sh` spells the same label and refuses
  a render that stamps another.
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

* **x86_64 CPU on an x86_64 dev box** (`cross = None`): the host macro
  `__x86_64__` is already defined, so the `gcc -c` above assembles the **real**
  x86 asm directly — no extra step.
* **AArch64 CPU on an x86_64 dev box** (`cross = Some ("aarch64-linux-gnu",
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
* `litmus/hetEmit.ml` — the `HetEmit.Make` functor (the dialect-parameterised
  file emitter), with the tagged CPU body split out into its own modules:
  `litmus/hetCpuPlan.ml` (the node type, the `cpu_plan` the emitter consumes and
  the C frame both are rendered into) plus `litmus/hetCpuBodyA64.ml` and
  `litmus/hetCpuBodyX86.ml` (one classifier and one pair of asm operand shapes
  per CPU ISA);
* `litmus/hetCond.ml` — pure classification of a test's condition: which
  locations an observer buffer has to snoop, and the confidence tier a null
  from that condition shape may be reported at;
* `litmus/hetCpuFront.ml` — the per-CPU-ISA column frontend (`CpuF`), one
  module per supported CPU ISA;
* the `` `Het `` dispatch arm in `litmus/top_litmus.ml` — the per-ISA module
  instantiation, closing `HetEmit.Make`'s seam over `Top`'s scope.

The only edits outside those are the ones the two selection axes strictly
require: `lib/X86_64Parser.mly` (the `instr_option_seq` start rule) and
`gen/hetGen.ml` (the `-cpu-arch` flag, below). `ASMLang` is **reused, not
modified**: this branch never edits it, and litmus7's own CPU-only runs still
instantiate it — but it is not what writes the het CPU body (piece 1 above).
The het arm reads the same compiled template `ASMLang.dump_fun` would have
read, takes the address parameters and the final registers, and stops there.
`CudaLang`/`HipLang` are reused for the GPU lowering (their shared half is
`litmus/gpuLang.ml`). One general (non-het) robustness fix lives in
`litmus/dumpRun.ml`: when no test compiled to a C run harness (e.g. an
all-`Het` invocation), litmus7 no longer copies the run-harness runtime from the
libdir (nothing to run), so the command exits cleanly.

## Generating het tests for a CPU ISA (`hetgen7 -cpu-arch`)

`hetgen7` dispatches its CPU-side `*Compile_gen` builder exactly as `diyone`
does (`AArch64Compile_gen` / `X86_64Compile_gen`):

```
hetgen7 … -cpu-arch x86_64 -cpu "PodWW Rfe PodRR Fre" -gpu "…" -bell ptx.bell
```

writes a test whose cpu column carries the `x86_64` tag and holds x86 cells
(`movl $1,(x)`). With **no** `-cpu-arch` the default is AArch64 and the output is
byte-identical to before (the cpu column keeps its `cpu` back-compat tag).

## The CPU-only set (`tests/het/generate-cpuonly.sh`)

Six shapes — MP, LB, SB, 2+2W, R, IRIW — rendered as het tests whose *every*
proc is tagged `cpu`, so they run as pure x86 tests **on the shared allocation**
instead of on litmus7's own. A plain litmus7 X86 run would allocate `x` and `y`
itself, and the question this set asks is about *that* allocation; the het
harness reaches it through `gd_alloc_shared` (`HET_ALLOC` / `hipMallocManaged`),
runs the same stress and prints the same verdict machinery. The set is generated
into an OUTDIR and never committed.

* **`SB` and `R` must be observed** — the store buffer is live — which doubles
  as the write-back probe: a CPU-only sighting on the shared allocation rules
  the uncacheable mapping out ([APM] Table 7-2). `MP`, `LB`, `2+2W` and `IRIW`
  must never be.
* **A sighting of a shape x86-TSO forbids is a finding about this host's TSO
  conformance, never a refutation of the compound model:** on an all-CPU cycle
  no compound composition is under test ([Goens23] §4.6). That disambiguation is
  wired into the verdict rather than left to the reader — `het_verdict.h` keys
  those sentences off `_rec.cpu_only`, which the emitter sets when every proc of
  the test is a CPU proc, so nothing depends on the file name saying `cpuonly`.

**The `2+2W` row is unresolved and must not be read as a TSO violation.** It is
the one store-only shape in the set: with no reader, its cycle is reconstructed
from an observer, and the emitted `ws` scans test the per-store tag
`K*(_n+1)+mu` **modulo** `K_TAG` — the store id — never its quotient, the
iteration (the quotient is read only by the observer-uniqueness blocks beside
them). Under the perpetual loop the witness therefore matches "`mu_a` seen
before `mu_b`" *across* iterations, where the coherence order it is meant to
witness is defined only *within* one, so a sighting is equally consistent with
the detector over-reporting and with a real property of the allocation. The four
shapes with a real x86 reader close their cycle through a load, and none of this
reaches them.

## Scope / limits

* CPU ISAs wired: **AArch64** and **x86_64** (selected by tag); GPU dialects
  wired: **CUDA** and **HIP** (selected by `-gpu-target`). All four pairings
  emit, and each render stamps the pair it was built for as `HET_PAIR_NAME`.
* Both CPU ISAs emit a **real tagged body**: store values rebound to
  `K*(_n+1)+mu`, loads recorded into per-iteration buffers, the tested
  mnemonics reproduced verbatim (`str`/`stlr`/`ldr`/`ldar`/`ldapr`/
  `dmb` on AArch64, `movq`/`mfence` on x86-64), widened to 64-bit operands.
  An earlier x86_64 arm emitted a `(void)_n` no-op instead: the CPU thread
  tested nothing, and litmus7 could emit a harness for only 39 of the 411 x86
  renderings the corpus then held (the condition could bind neither a read
  buffer nor a `mu`). The renderings themselves are produced on demand by
  `hetlitmus/tests/het/generate-x86.sh OUTDIR` — never committed, because 94
  of them are byte-identical to a sibling (x86-TSO collapses the four CPU order
  tokens onto two images) and `dupcheck.py` rejects duplicates. Their names are
  1:1 with the 471-test corpus (`<corpus name>-x86_64`), which is what lets a
  gate pin one census against both.
* A het emission that **cannot** be completed is fail-closed: litmus7 prints
  `HetLitmus REFUSED (het|gpu-only|isa-scan) <test>: <why>` on stderr and exits
  **3** (`HetArch.refused`).  litmus7's own batch driver would have reported the
  refusal and still exited 0, which made a missing harness look like success to
  any caller that redirects stdout.
* The CPU projection supports plain straight-line procs (the het corpus). An
  instruction outside the tagged-body vocabulary is refused by name at
  classification, before any harness directory exists. A structural pseudo is
  not: `instrs_of_pseudo` peels a `Label` and drops a `Macro`/`Pagealign`/
  `Symbolic`, so a proc carrying one emits a straight-line body with it
  silently removed. Supporting them would mean extending the vocabulary in
  `HetCpuPlan` and its per-ISA classifiers, not in `ASMLang`.
* COMPILE-ONLY: no GPU is launched. Stress/observability tuning (making the CPU
  and GPU ops actually race) and on-hardware runs are hardware-only work
  (`00-environment-design.md` §6).
