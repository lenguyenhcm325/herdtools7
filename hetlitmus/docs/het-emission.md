# HetLitmus Tier-2: heterogeneous CPU+GPU harness emission

This document describes how `litmus7` turns a `Het` (compound) `.litmus` test
into **one compilable CPU+GPU harness directory**. It is the Tier-2 follow-on to
Tier-0 (the compound pseudo-arch / single-arch break, see
`docs/het-litmus-format.md`) and Tier-1 (the GPU-only CudaLang/HipLang emitters,
see `docs/cuda-emitter.md`). Cross-device *execution* on real hardware is **Task
9** and out of scope here; Tier-2 stops at a harness that **compiles**.

Two axes are chosen per test rather than hard-wired (the **Phase A/B** work):

* **CPU ISA is selected by the per-column device tag** (Phase A). The header tag
  *names* the CPU ISA — `P0:aarch64` or `P0:x86_64` — and `P0:cpu` is a
  back-compat alias for AArch64. litmus7 pre-scans the header, then instantiates
  the matching CPU sub-parser + compile pipeline. The GPU side stays LISA/Bell.
* **The GPU dialect is selected by `-gpu-target`** (Phase B). One LISA parse
  yields the ONE render that flag names — `<t>.cu` (CUDA) or `<t>.hip` (HIP) —
  from a shared driver template; only the per-instruction lowering and a few
  host tokens differ. The flag is mandatory on the `Het` and `LISA` arms and has
  no default: a harness directory carries one vendor's render and one vendor's
  build arms (`litmus/hetTarget.ml`).

## Reproduce

```
# AArch64 CPU + GPU (the GH200 pairing). Emits ./MP-het/ with the .cu:
litmus7 -gpu-target cuda -set-libdir herd/libdir hetlitmus/tests/het/MP-het.litmus
( cd MP-het && sh comp.sh )        # CUDA: nvcc -c + gcc -c (+clang aarch64), exit 0

# x86_64 CPU + HIP (the MI300A pairing), from the committed one-test fixture:
litmus7 -gpu-target hip -o hip-out -set-libdir herd/libdir \
  hetlitmus/tests/het-x86/MP-cg-sys-relaxed-x86_64.litmus
( cd hip-out/MP-cg-sys-relaxed-x86_64 && sh comp.sh )  # hipcc --offload-arch=gfx942 -c

# the AArch64 corpus paired with HIP is a machine no oracle covers, so it REFUSES:
litmus7 -gpu-target hip -set-libdir herd/libdir hetlitmus/tests/het/MP-het.litmus
# HetLitmus REFUSED (het) ...: no oracle is registered for the CPU-ISA x
# GPU-dialect pair (AArch64, hip). ...                                  exit 3
```

The harness directory is written next to the current directory (or into the
`-o <dir>` directory if one is given). The command exits 0: a `Het` test
compiles to its own self-contained harness, so litmus7 builds **no** suite-level
run harness (and therefore needs no `_show.awk`/`cache.h` runtime from the
libdir — which is why `-set-libdir herd/libdir` is fine even though those files
live under `litmus/libdir`).

## Phase A — CPU ISA from the device tag (a functor, not a flag)

The Tier-2 body used to be AArch64-specific. It is now a **functor over the CPU
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

ONE GPU dialect per directory (Phase B): the render and the build arms are the
ones `-gpu-target` named, and no other vendor's. `<v>` below is that target word.

| file            | role                                                         | compiled by |
|-----------------|--------------------------------------------------------------|-------------|
| `<t>.cu` **or** `<t>.hip` | GPU kernel + host driver in the selected dialect (alloc, barrier, launch, readback) — one of the two, never both | `nvcc -c` / `hipcc -c` |
| `<t>_cpu.c`     | CPU thread(s): real `<ISA>` inline asm (ASMLang)             | `gcc -c` (native or `#else` shim) **and**, for a foreign-ISA host, `clang --target=<triple> -c` (real asm) |
| `outs.c`/`.h`   | litmus7's own outcome histogram, embedded verbatim           | `gcc -c`    |
| `comp.sh`       | compile-only driver, `sh comp.sh [<v>\|<v>-link]` (default `<v>`); the absent vendor's word is refused by name | —           |
| `Makefile`      | same; `make <v>` / `make <v>-bin` targets                    | —           |
| `README.md`     | one-paragraph description                                     | —           |

The five required pieces, and where each is reused rather than reimplemented:

1. **P(cpu) → a CPU pthread running real AArch64 asm.** The arm projects the
   compound parsed program onto a CPU-only `MiscParser` test
   (`HetArch.to_cpu_pseudo`), runs the **genuine litmus7 AArch64 compile
   pipeline** (`SymbReg` → `AArch64Compile_litmus` → `Template`), and emits each
   thread's inline-asm function with **`ASMLang.dump_fun`** — the exact code path
   litmus7 uses for its own `-mode presi -ascall` harnesses. The body is the
   real `asm __volatile__("str %w[x0],[%[x1]]" ...)`, not a hand-rolled string.
   `<t>.cu`'s `cpu_thread_P<n>` arrives at the barrier and calls the
   `extern "C" het_run_P<n>(...)` wrapper (a non-static entry into the static
   `code<n>` ASMLang emits).

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
   not contaminate the relaxed/scoped behaviour under test (see
   `hetlitmus-work-tiers`, Tier-2/Tier-3 note). The driver resets `*barrier = 0`
   each iteration, between a `pthread_join` + device-sync. The `__hip_atomic_*`
   builtins compile in **host** code under hipcc (verified), so the same barrier
   idiom works in the pthread and in the kernel.

5. **GPU readback merged into litmus7's outs histogram.** The kernel writes each
   result register to `__out[proc*NREGS + n]` (managed memory); the CPU asm
   writes its observed registers through the `*out_<p>_<reg>` pointers. Each
   iteration the driver assembles the outcome vector `_o[]` from **both**
   sources and calls litmus7's own `add_outcome_outs(...)`. `dump_outs` prints
   the histogram, marking outcomes that satisfy the test's `exists` condition
   (compiled to a C predicate `_cond` over `_o[]`).

## Phase B — one render per `-gpu-target`, and `comp.sh [<target>|<target>-link]`

One LISA parse, one GPU file per emission. The driver template is rendered from
a `gpu_dialect` record; the registry `dialects = [cuda_dialect; hip_dialect]`
(`litmus/hetEmit.ml`) holds one record per vendor and `-gpu-target` filters it,
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

## Phase C/D — the machine table, and the machine a harness may name

A harness is not "an AArch64 test" or "a HIP test": it is a **(CPU ISA x GPU
dialect) PAIR**, and the silicon the run *names* belongs to that pair.
`litmus/hetMachine.ml` is the table:

| pair              | row                    | machine defines stamped        |
|-------------------|------------------------|--------------------------------|
| (AArch64, cuda)   | GH200                  | link `NVLink-C2C`, Grace / Hopper halves, LLC 114 MB, Alglave-zero |
| (x86_64, hip)     | MI300A                 | link `Infinity Fabric`, x86 / MI300A halves, LLC 256 MB |
| (x86_64, cuda)    | registered, no machine — the dev box | none |
| (AArch64, hip)    | in no row              | none, plus one stderr warning  |

Three rules make it worth having:

* **An empty cell is never filled from a neighbour.** Keying the machine on the
  CPU ISA alone — what this replaced — described an x86+CUDA emission as an
  MI300A, so its stderr told the reader which Infinity Fabric half had been
  disabled on a box that has none.
* **A pair with no row emits anyway, and claims less.** The tool
  characterizes: an unregistered pair still has a machine somebody can run, and
  what it loses is the right to name it. Emission warns once, stamps no machine
  define, and the render says in band which of the two nameless states it is in
  (registered-without-a-row, or in no row at all).
* **The machine prose keys on the pair, not on the dialect.** The emitter stamps
  `HET_LINK_NAME` / `HET_HOST_HALF` / `HET_DEV_HALF` / `HET_LLC_MB` (and
  `HET_ALGLAVE_ZERO_MEASURED`, for the one measurement that is NVIDIA-only) from
  the pair row; `het_verdict.h` prints from those defines and sniffs nothing. A
  pair with no machine row stamps none of them and gets the header's generic
  defaults, which name the *mechanism* — so a missing stamp can only ever weaken
  a claim. `HET_PLACE_LEVER` is separate: the placement API is a *dialect* fact
  (`cudaMemAdvise` on the CUDA render; the HIP render has no placement code and
  `#error`s on a non-zero `HET_PLACE`).
* **The defines are not the only place a harness names a machine.** The dialect
  payloads (`litmus/het-runtime/*.inc`) are pasted into the render as *text*, and
  the emitted `README.md` / `comp.sh` are prose — neither goes through a define,
  and both once carried the part their sentences were written for onto lanes
  entitled to none. They are now written with `@NAME@` holes filled from the row
  that resolved (`HetMachine.mc_words` / `fill`), so an entitled lane prints the
  words its row owns and a nameless one prints the mechanism; a hole no row has a
  word for **refuses** the emission. `hetlitmus/verify/brandscan.py` is the
  independent detector: printed string literals (comments stripped, adjacent
  literals joined) plus `README.md`/`comp.sh`/`Makefile`, keyed on entitlement
  because the two lanes with a row legitimately print their own machine's words.
  `emit-all.sh` runs it once per lane, cram `machine-pairs.t` (e) on all four.

### What the defines close, measured

The prose used to **sniff** the recorded oracle-source string for `NVIDIA`. On
an AMD-tagged harness it therefore called the two halves of the interconnect
noise *"the Grace half"* and *"the Hopper half"* and cited *"On NVIDIA silicon
an unstressed run observes nothing"* as if it applied — and it would have said
the same on an x86 host with an NVIDIA GPU, whose oracle string still carries
the word. Measured 2026-08-03 on a real run of `2+2W-cpuonly-x86_64`, whose
first two stderr lines were *"the Hopper half of the C2C noise is DISABLED"* and
*"the Grace half … is DISABLED"*. None of those is a statement about the machine
that ran. Keying on the dialect instead of the pair would have reproduced the
same defect one table over: the host half is a property of the **pair**, so a
dialect-keyed `HET_HOST_HALF` stamps *"the Grace half"* on the (x86_64, cuda)
emission.

`HET_LLC_MB` is the same rule applied to a *number*. The threshold a noise
buffer must exceed to cross anything is per target: 114 MB is
`max(Grace L3, Hopper L2)` (Bagchi ISMM'26 Table 1) and **under-fires** on
MI300A, whose last level is the 256 MB MALL / AMD Infinity Cache on the IOD
(Tee et al., *The MALL is Open*, SC Workshops '25, Table 1 p. 1111 — MI300A:
sL1 16 KB, L2 4 MB/XCD, MALL 256 MB). Each pair with a row stamps its own; 114
stays as `het_cpu_stress.h`'s `#ifndef` default, and where it is *not* the
target's own figure the emitted warning says so instead of naming it as this
machine's cache.

### Two build facts every pair stamps

`HET_PAIR_NAME` and `HET_NO_CONTROL_MAP` are stamped from **every** pair,
machine row or not, because they are true of the binary whatever the table says.

* `HET_PAIR_NAME` is the short `(ISA, dialect)` label the verdict and statistics
  layers print where they must identify the target. A harness built for the
  wrong pair compiles, runs and reports identically; this define is the only
  thing that says which machine it was measuring.
* `HET_NO_CONTROL_MAP` says the positive-control map was **not beside the
  test**. The map is keyed on the CPU frontend
  (`HetCpuFront.control_map_csv`: AArch64 → `control-map.csv`, x86_64 →
  `control-map-amd.csv`) and looked for on every lane, because `mu(T)` is a
  weakening on a strength lattice and the lattice is the CPU column's. Where it
  is missing nothing marks any row the canary, and the statistics layer must not
  read "co-runs no control" as "it IS the Layer-B canary":
  `HET_ST_SELF_CONTROL` requires the record to **name itself** its canary, the
  same test the per-run liveness block makes, and a different sentence is
  printed for each. The denominator is `R` in both: the selection effect
  ("usable" is defined by firing where nothing co-runs) is identical, and
  classifying over the survivors would report ALWAYS for a row that fired in 3
  runs of 10.

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
* the generated `HetPayloads` module — the verbatim runtime payloads
  (`outs.{c,h}` cat'ed from `litmus/libdir/_outs.{h,c}`, plus the
  `litmus/het-runtime/*` headers), wrapped by the rule in `litmus/dune`;
* `litmus/hetEmit.ml` — the `gpu_dialect` record + the `HetEmit.Make` functor
  (the dialect-parameterised file emitter), with two of its phases as their own
  modules: `litmus/hetControlMap.ml` (the positive-control map) and
  `litmus/hetCpuBody.ml` + `litmus/hetCpuBodyX86.ml` (the tagged CPU body, one
  matcher per CPU ISA, sharing `cpu_plan` and emitting the same C shape);
* `litmus/hetCpuFront.ml` — the per-CPU-ISA column frontend (`CpuF`), one
  module per supported CPU ISA;
* the `` `Het `` dispatch arm in `litmus/top_litmus.ml` — the per-ISA module
  instantiation, closing `HetEmit.Make`'s seam over `Top`'s scope.

The only edits outside those are the ones Phase A/B strictly require:
`lib/X86_64Parser.mly` (the `instr_option_seq` start rule) and `gen/hetGen.ml`
(the `-cpu-arch` flag, below). `ASMLang` is **reused, not modified**;
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

## Scope / limits

* CPU ISAs wired: **AArch64** and **x86_64** (selected by tag); GPU dialects
  wired: **CUDA** and **HIP** (selected by `-gpu-target`). All four pairings
  emit; what the machine table decides is which of them may name a machine.
  GH200 (AArch64+CUDA) and MI300A (x86_64+HIP) are the two science targets,
  x86_64+CUDA is the dev box, and AArch64+HIP is in no row and names none.
* Both CPU ISAs emit a **real B3-tagged body** since P2b (2026-08-03): store
  values rebound to `K*(_n+1)+mu`, loads recorded into per-iteration buffers,
  the tested mnemonics reproduced verbatim (`str`/`stlr`/`ldr`/`ldar`/`ldapr`/
  `dmb` on AArch64, `movq`/`mfence` on x86-64), widened to 64-bit operands.
  Before P2b the x86_64 arm emitted a `(void)_n` no-op: the CPU thread tested
  nothing, and litmus7 could emit a harness for only 39 of the 411 x86
  renderings (the condition could bind neither a read buffer nor a `mu`).
  The renderings themselves are produced on demand by
  `hetlitmus/tests/het/generate-x86.sh OUTDIR` — never committed, because ~90
  of them are byte-identical to a sibling (x86-TSO collapses the four CPU order
  tokens onto two images) and `dupcheck.py` rejects duplicates. Their names are
  1:1 with the 411-test corpus (`<corpus name>-x86_64`), which is what lets
  `expected-amd.csv` and `control-map-amd.csv` stay keyed on the unsuffixed
  names.
* A het emission that **cannot** be completed is fail-closed: litmus7 prints
  `HetLitmus REFUSED (het|gpu-only|isa-scan) <test>: <why>` on stderr and exits
  **3** (`HetArch.refused`).  litmus7's own batch driver would have reported the
  refusal and still exited 0, which made a missing harness look like success to
  any caller that redirects stdout.
* The CPU projection supports plain straight-line procs (the het corpus); a proc
  using labels/PTEs/macros would need the corresponding ASMLang machinery and is
  rejected rather than mis-emitted.
* COMPILE-ONLY: no GPU is launched. Stress/observability tuning (making the CPU
  and GPU ops actually race) and on-hardware runs are Tier-3 / Task 9.
