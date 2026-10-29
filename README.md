# HetLitmus

[![hetlitmus CI](https://github.com/lenguyenhcm325/herdtools7/actions/workflows/hetlitmus-ci.yml/badge.svg?branch=hetlitmus-work)](https://github.com/lenguyenhcm325/herdtools7/actions/workflows/hetlitmus-ci.yml)

HetLitmus extends the [herdtools7](https://github.com/herd/herdtools7) litmus-testing suite so that
one heterogeneous CPU+GPU litmus test is generated, compiled and run on real hardware. The CPU side
is AArch64 or x86_64 assembly. The GPU side is the scoped Bell/LISA frontend, rendered to CUDA for NVIDIA or HIP for AMD.

## Run environment

```
  host (CPU)                                     device (GPU, persistent grid)
  ┌────────────────────────────┐                 ┌────────────────────────────┐
  │ test threads               │◀─ rendezvous ─▶│ test blocks                │
  │  one pthread per cpu proc, │   counter,      │  one thread per gpu proc,  │
  │  pinned to its own core    │   every iter    │  each in its own block     │
  ├────────────────────────────┤                 ├────────────────────────────┤
  │ stress threads             │                 │ stress blocks              │
  ├────────────────────────────┤                 ├────────────────────────────┤
  │ noise threads              │                 │ noise blocks               │
  └──────────────┬─────────────┘                 └──────────────┬─────────────┘
                 │                 interconnect                 │
  ┌──────────────┴──────────────────────────────────────────────┴───────────┐
  │ shared memory: test locations, rendezvous counter, readback slots       │
  ├─────────────────────────────────────────────────────────────────────────┤
  │ noise buffer, above the last-level cache, streamed by both sides        │
  └─────────────────────────────────────────────────────────────────────────┘
```

## Run on hardware

```
make all
export RESULTS=hetlitmus/run-out/<tag>
sh hetlitmus/probe-cuda.sh
hetlitmus/emit-het.sh --gpu-target cuda _build/default/hetlitmus/tests/het
hetlitmus/build.sh $RESULTS/emit
python3 hetlitmus/campaign.py --corpus $RESULTS/emit --budget-runs 100 --state $RESULTS/campaign.csv
```

For HIP, run `probe-hip.sh` instead of `probe-cuda.sh`, and `emit-het.sh --gpu-target hip` on the
`het-x86_64` tree.

## Corpora

| Tree | Tests | Rule |
|---|---|---|
| `het` | 6923 | shape × device cut × GPU scope × GPU order × CPU order, AArch64 CPU column |
| `het-x86_64` | 4056 | shape × device cut × GPU scope × GPU order × CPU order, x86_64 CPU column |
| `gpu-only` | 771 | shape × GPU scope × GPU order, every proc on the GPU |

## Documentation

- [hetlitmus/docs/README.md](hetlitmus/docs/README.md)
- [hetlitmus/docs/REFERENCES.md](hetlitmus/docs/REFERENCES.md)

## Upstream and license

HetLitmus is a fork of [herd/herdtools7](https://github.com/herd/herdtools7), home
<http://diy.inria.fr/>, by Jade Alglave and Luc Maranget. Upstream's build instructions are in
[INSTALL.md](./INSTALL.md).

Copyright 2010 -- present: Institut National de Recherche en Informatique et en Automatique, and
the authors. Released under the CeCILL-B free software license agreement, see
[LICENSE.txt](./LICENSE.txt).
