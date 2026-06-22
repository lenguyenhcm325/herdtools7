# HetLitmus Tier-2: heterogeneous CPU+GPU harness emission

This document describes how `litmus7` turns a `Het` (compound) `.litmus` test
into **one compilable CPU+GPU harness directory**. It is the Tier-2 follow-on to
Tier-0 (the compound pseudo-arch / single-arch break, see
`docs/het-litmus-format.md`) and Tier-1 (the GPU-only CudaLang/HipLang emitters,
see `docs/cuda-emitter.md`). Cross-device *execution* on real hardware is **Task
9** and out of scope here; Tier-2 stops at a harness that **compiles**.

## Reproduce

```
litmus7 -set-libdir herd/libdir hetlitmus/tests/het/MP-het.litmus   # emits ./MP-het/
litmus7 -set-libdir herd/libdir hetlitmus/tests/het/SB-het.litmus   # emits ./SB-het/
( cd MP-het && sh comp.sh )                                          # nvcc -c + gcc -c, exit 0
```

The harness directory is written next to the current directory (or into the
`-o <dir>` directory if one is given). The command exits 0: a `Het` test
compiles to its own self-contained harness, so litmus7 builds **no** suite-level
run harness (and therefore needs no `_show.awk`/`cache.h` runtime from the
libdir — which is why `-set-libdir herd/libdir` is fine even though those files
live under `litmus/libdir`).

## What the `Het` dispatch arm emits

For the GH200 pairing `AArch64 (CPU) + LISA/PTX (GPU)`, each `Het` test yields a
directory containing:

| file            | role                                                         | compiled by |
|-----------------|--------------------------------------------------------------|-------------|
| `<t>.cu`        | GPU kernel + host driver (alloc, barrier, launch, readback)  | `nvcc -c`   |
| `<t>_cpu.c`     | CPU thread(s): real AArch64 inline asm (ASMLang)             | `gcc -c` (host shim) **and** `clang --target=aarch64-linux-gnu -c` (real asm) |
| `outs.c`/`.h`   | litmus7's own outcome histogram, embedded verbatim           | `gcc -c`    |
| `comp.sh`       | compile-only driver (`set -e`; `nvcc -c` + `gcc -c`)         | —           |
| `Makefile`      | same, as a Makefile                                          | —           |
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

2. **P(gpu) → a CUDA kernel.** The arm projects onto the Bell/LISA side
   (`HetArch.to_gpu_pseudo`) and builds the kernel by reusing **CudaLang**'s
   scoped-atomic translation (`CudaLang.dump_instr`, `result_regs`,
   `collect_globals`, `layout_of_scopes`) — `cuda::atomic_ref<int,
   thread_scope_*>` loads/stores with the annotated order. Only the het-specific
   scaffold (the barrier + per-proc guard) is new.

3. **Shared vars in cudaMallocManaged.** Every shared location (the union of the
   CPU thread's addresses and the kernel's globals) is `cudaMallocManaged`, so
   the same physical bytes are coherent to the Grace CPU and the Hopper GPU over
   NVLink-C2C. The CPU thread receives them as `int*` params (the addresses the
   AArch64 asm dereferences); the kernel as `int*` params (dereferenced by
   `atomic_ref`).

4. **System-scope rendezvous barrier.** A single `int* barrier` in managed
   memory, accessed through `cuda::atomic_ref<int, cuda::thread_scope_system>`
   on **both** sides: each participant `fetch_add(1, seq_cst)` then spins until
   the count reaches `NPART` (= #CPU pthreads + #GPU threads). System scope is
   used deliberately so the barrier itself is *strong* and does not contaminate
   the relaxed/scoped behaviour under test (see
   `hetlitmus-work-tiers`, Tier-2/Tier-3 note). The driver resets `*barrier = 0`
   each iteration, between a `pthread_join` + `cudaDeviceSynchronize`.

5. **GPU readback merged into litmus7's outs histogram.** The kernel writes each
   result register to `__out[proc*NREGS + n]` (managed memory); the CPU asm
   writes its observed registers through the `*out_<p>_<reg>` pointers. Each
   iteration the driver assembles the outcome vector `_o[]` from **both**
   sources and calls litmus7's own `add_outcome_outs(...)`. `dump_outs` prints
   the histogram, marking outcomes that satisfy the test's `exists` condition
   (compiled to a C predicate `_cond` over `_o[]`).

## Why a separate AArch64 object (clang) on an x86 dev box

The harness targets the GH200, whose host CPU is `aarch64`; there `nvcc`'s host
compiler assembles `<t>_cpu.c` natively. On a non-aarch64 dev box the AArch64
inline asm cannot be assembled by the host `gcc`, so:

* the asm is guarded by `#if defined(__aarch64__)`, with a clearly-marked
  portable **shim** for the `#else` branch so `gcc -c <t>_cpu.c` succeeds on any
  host (the shim is *not* the tested path);
* `comp.sh` additionally runs `clang --target=aarch64-linux-gnu -c <t>_cpu.c`
  when `clang` is present — clang's integrated assembler emits a genuine
  `ELF aarch64` object from the real asm, with no cross-binutils needed. This is
  how the AArch64 thread is compile-checked on the (x86) dev box.

`nvcc -c` + `gcc -c` are always invoked (the END-STATE requirement); the clang
step is the faithful cross-assembly of piece (1).

## Where the code lives (and what is *not* touched)

All het logic is confined to:

* `litmus/HetArch.ml` — `to_cpu_pseudo`/`to_gpu_pseudo` (project a compound
  internal pseudo back onto a sub-arch) and the verbatim `outs.{c,h}` strings;
* the `` `Het `` dispatch arm in `litmus/top_litmus.ml` — the CPU compile
  pipeline wiring + the file emitter.

`ASMLang` and `CudaLang` are **reused, not modified**. One general (non-het)
robustness fix lives in `litmus/dumpRun.ml`: when no test compiled to a C run
harness (e.g. an all-`Het` invocation), litmus7 no longer copies the run-harness
runtime from the libdir (nothing to run), so the command exits cleanly.

## Scope / limits

* Pairing wired: AArch64 + LISA/PTX (GH200). A HIP/MI300A pairing would add one
  more dispatch arm (HipLang already exists for the GPU side).
* The CPU projection supports plain straight-line procs (the het corpus); a proc
  using labels/PTEs/macros would need the corresponding ASMLang machinery and is
  rejected rather than mis-emitted.
* COMPILE-ONLY: no GPU is launched. Stress/observability tuning (making the CPU
  and GPU ops actually race) and on-hardware runs are Tier-3 / Task 9.
