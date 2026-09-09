# HetLitmus test index

The roster is the Makefile; each gate's contract is the docstring of the script its target runs.
Base lane, `make hetlitmus-test`: needs the OCaml build, gcc and python3, no GPU compiler and no device.
A cram miss means a golden no longer matches what `grid.py` computes, what `hetgen7`/`diyone7` generate, or what `litmus7` refuses and emits.
Toolchain lane, `make hetlitmus-test-toolchain`: needs nvcc, hipcc, clang and gcc, plus a CUDA device for `hetlitmus-stress` and `hetlitmus-characterize-hw`.
`.github/workflows/hetlitmus-ci.yml` runs the deviceless gates of both lanes on every push to `hetlitmus-work`.

| target | script |
|---|---|
| `hetlitmus-cram` | `hetlitmus/tests/cram` |
| `hetlitmus-corpus` | `verify/corpus-gate.sh` |
| `hetlitmus-dup` | `verify/dupcheck.py` |
| `hetlitmus-hipsrc` | `verify/hipsrccheck.py` |
| `hetlitmus-verdict` | `verify/verdictcheck.py` |
| `hetlitmus-stamps` | `verify/stampcheck.py` |
| `hetlitmus-rdv` | `verify/rdvcheck.py` |
| `hetlitmus-stats` | `verify/statscheck.py` |
| `hetlitmus-probe-hip` | `verify/runcheck.py` |
| `hetlitmus-faithful` | `verify/tokens.sh all` |
| `hetlitmus-smoke` | `verify/smoke.sh` |
| `hetlitmus-stress` | `verify/tokens.sh stress` |
| `hetlitmus-stress-static` | `verify/tokens.sh stress-static` |
| `hetlitmus-cpustress` | `verify/tokens.sh cpustress` |
| `hetlitmus-hipbuild` | `verify/hipbuildcheck.py` |
| `hetlitmus-characterize-hw` | `verify/runcheck.py --characterize-hw` |

## Constraints
- Every corpus sweep but `dupcheck.py` asserts the census pinned in `verify/census.py` and mirrored in `verify/census.sh`; a generator change that adds or removes a test moves both.
- A verify script with no Makefile target is not a gate: `verify/emit-all.sh` is invoked by no target and no CI step.
- No gate compiles an x86_64 CPU body carrying `mfence`: every x86 render a gate builds has a plain `movl` column, and `hipsrccheck.py` reads `mfence` at source level only.
