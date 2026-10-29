# HetLitmus: requirements, tools and tests

## Requirements

| To | Needs |
|---|---|
| build the tools, generate and emit tests | OCaml and dune as in upstream's [INSTALL.md](../../INSTALL.md), python3, gcc |
| compile a CUDA harness | CUDA 12.x (`nvcc`), sm_70 or later (one-sided fences need sm_90) |
| compile a HIP harness | ROCm (`hipcc`) |
| assemble the CPU column off its native host | `clang` |
| run a harness | an NVIDIA GPU (CUDA) or an AMD GPU (HIP); a CPU-GPU pair sharing memory |

## Tools

Call hetgen7 and litmus7 directly only for a one-off, hand-written test. To add a shape to the
corpora, extend `SHAPES` in `hetlitmus/tests/grid.py`; to emit a corpus, use `hetlitmus/emit-het.sh`.

`make all` builds every binary into `_build/install/default/bin`. Every invocation takes
`-set-libdir`: `herd/libdir` for the generators, `litmus/libdir` for litmus7.

Note: `litmus7` on `PATH` may be another herdtools7 install, not the HetLitmus build. Put the
build directory first:
`export PATH=$PWD/_build/install/default/bin:$PATH`.

### hetgen7: generate one heterogeneous test

hetgen7 runs diy's cycle engine once per device on the same cycle shape and merges the columns,
the init and the condition into one `Het` test.

| Flag | Meaning |
|---|---|
| `-cpu <edges>` | the cycle, in the CPU edge vocabulary |
| `-gpu <edges>` | the same cycle in the Bell vocabulary, every access annotated `<Order><Scope>` |
| `-devices cpu,gpu,...` | per-proc device assignment, default `cpu,gpu`; at least one proc is `gpu` |
| `-cpu-arch aarch64\|x86_64` | ISA of the `cpu` procs, default `aarch64` |
| `-bell <file>` | the scoped Bell model; `-show edges\|annotations\|fences` lists what it accepts |

Every other diyone7 option applies unchanged (`-name`, `-stdout`, `-oneloc`, ...).

```
hetgen7 -set-libdir herd/libdir -bell hetlitmus/bells/gpu.bell \
  -cpu-arch aarch64 -devices cpu,gpu -name MP -stdout \
  -cpu 'PodWW Rfe PodRR Fre' \
  -gpu 'PodWWRelaxedSysRelaxedSys RfeRelaxedSysAcquireSys PodRRAcquireSysAcquireSys FreAcquireSysRelaxedSys'
```

```
Het MP
"Heterogeneous MP: per-proc device assignment cpu,gpu (cpu=AArch64, gpu=LISA)"
{
0:X1=x;
0:X3=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#1   | r[acquire,sys] r0 y ;
 STR W0,[X1] | r[acquire,sys] r1 x ;
 MOV W2,#1   |                     ;
 STR W2,[X3] |                     ;
scopes: (sys (gpu (cta P1)))
exists (1:r0=1 /\ 1:r1=0)
```

### litmus7: emit a harness

```
litmus7 -set-libdir litmus/libdir -gpu-target cuda|hip -o DIR test.litmus
```

One self-contained harness directory per test: the `.cu` or `.hip` render with the GPU kernel and
the run loop, a `_cpu.c` with the CPU column, the runtime headers, and a Makefile.

| Flag / variable | Meaning |
|---|---|
| `-gpu-target cuda\|hip` | the GPU dialect to render; mandatory, no default; also required for GPU-only scoped LISA tests |
| `make cuda-bin`, `make hip-bin` | link the harness binary inside the emitted directory |
| `CUDA_ARCH` (`sm_90`), `HIP_ARCH` (`gfx942`) | device architecture, with its default |
| `NVCC`, `HIPCC`, `CC`, `HET_CPU_CFLAGS` | compilers and CPU-column flags; build-time `HET_*` knobs ride in the compiler variable, `NVCC="nvcc -DHET_LLC_MB=256"` |

## Tests

The Makefile section "HetLitmus test targets" lists every gate.

- Base lane, `make hetlitmus-test`: needs the OCaml build, gcc and python3, no GPU compiler and no
  device. A cram miss means a golden no longer matches what `grid.py` computes, what
  `hetgen7`/`diyone7` generate, or what `litmus7` refuses and emits.
- Toolchain lane, `make hetlitmus-test-toolchain`: needs nvcc, hipcc, clang and gcc, plus a CUDA
  device for `hetlitmus-characterize-hw`.
- `.github/workflows/hetlitmus-ci.yml` runs the deviceless gates of both lanes on every push to
  `hetlitmus-work`.
