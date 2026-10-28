# HetLitmus: requirements, hardware runs and tests

The tools, the test format and the corpora are described in the top-level [README.md](../../README.md).

## Requirements

| To | Needs |
|---|---|
| build the tools, generate and emit tests | OCaml and dune as in upstream's [INSTALL.md](../../INSTALL.md), python3, gcc |
| compile a CUDA harness | CUDA 12.x (`nvcc`), sm_70 or later; one-sided fences need sm_90 |
| compile a HIP harness | ROCm (`hipcc`) |
| assemble the CPU column off its native host | `clang` |
| run a harness | an NVIDIA GPU (CUDA) or an AMD GPU (HIP); a CPU-GPU pair sharing memory |

## Run on hardware

All four steps share `RESULTS`, so one run's artefacts sit in one directory.

```
export RESULTS=hetlitmus/run-out/<tag>
sh hetlitmus/probe-cuda.sh
hetlitmus/emit-het.sh --gpu-target cuda _build/default/hetlitmus/tests/het
hetlitmus/build.sh $RESULTS/emit
python3 hetlitmus/campaign.py --corpus $RESULTS/emit --budget-runs 100 --state $RESULTS/campaign.csv
```

The HIP run uses `probe-hip.sh`, `--gpu-target hip` and the `het-x86_64` tree. The campaign draws
a seed base and records it in every state row; `--seed0` replays it.
`hetlitmus/tests/subset.py` selects a device-run subset of a het tree, and
`hetlitmus/device-runs/gb10/runbook.sh` is the full recipe used on a GB10.

## Tests

The Makefile section "HetLitmus test targets" lists every gate.

- Base lane, `make hetlitmus-test`: needs the OCaml build, gcc and python3, no GPU compiler and no
  device. A cram miss means a golden no longer matches what `grid.py` computes, what
  `hetgen7`/`diyone7` generate, or what `litmus7` refuses and emits.
- Toolchain lane, `make hetlitmus-test-toolchain`: needs nvcc, hipcc, clang and gcc, plus a CUDA
  device for `hetlitmus-characterize-hw`.
- `.github/workflows/hetlitmus-ci.yml` runs the deviceless gates of both lanes on every push to
  `hetlitmus-work`.
