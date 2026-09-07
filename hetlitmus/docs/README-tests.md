# HetLitmus test index

The roster is the Makefile (`grep -E '^hetlitmus-[a-z0-9-]+:' Makefile`); each gate's contract
is the docstring of the script its target runs, and this file only indexes them. No target runs
a campaign on a device: the steps from a corpus to a results dir are run by hand
(`het-emission.md`, "From a corpus to a results dir").

## Corpus trees — `make hetlitmus-corpus-gen`

`dune build @@hetlitmus/tests/corpus`: the three corpus trees `het`, `het-x86_64` and
`gpu-only` under `_build/default/hetlitmus/tests/`, `grid.py`'s directory targets
(`tests/dune`), rebuilt only when `grid.py`, the bell, herd's libdir or a generator binary
changed. Nothing under them is committed. Every gate below lists the target as a prerequisite,
so none reads a stale tree; `dune runtest` resolves the cram deps against the same rules.

## Base lane — `make hetlitmus-test`

Needs the OCaml build (`litmus7`, `hetgen7`, `diyone7`), gcc, python3; no GPU compiler, no device.

| target | runs | a miss means |
|---|---|---|
| `hetlitmus-cram` | `dune runtest hetlitmus/tests/cram` under `DUNE_CACHE=disabled` (stanzas: `tests/cram/dune`; every `.t` but `basics`, `ptx-negatives` and `corpus` needs `litmus7`; `corpus` needs `hetgen7`/`diyone7` through the corpus trees) | a golden no longer matches what `grid.py` computes, what `hetgen7`/`diyone7` generate, or what `litmus7` refuses and emits |
| `hetlitmus-corpus` | `verify/corpus-gate.sh` | a built corpus tree is not what `grid.py` produces afresh, a `cuda-out`/`hip-out` sample is not what the emitter produces, or the census moved (exit 1; 2 = infrastructure) |
| `hetlitmus-dup` | `verify/dupcheck.py` | two built het tests are one experiment up to proc permutation × location renaming, i.e. the cut reduction by the cycle's symmetry kept an isomorphic pair; an empty dir is a refusal |
| `hetlitmus-hipsrc` | `verify/hipsrccheck.py --all` | a HIP kernel or x86_64 CPU body renders an annotation as another op, order, scope or operand, or drops it (source level, no hipcc) |
| `hetlitmus-verdict` | `verify/verdictcheck.py` | `het_verdict()`, compiled from the real emitted header, stopped deciding, or a printout sentence reports what nothing measured |
| `hetlitmus-recfields` | `verify/recfields.py` | a `_rec.<field>` or stamped `HET_*` define no longer binds to `litmus/het-runtime/*.h`: a harness that does not compile |
| `hetlitmus-rdv` | `verify/rdvcheck.py` | an iteration does not begin at the rendezvous, or the primitive carries an order or a fence: a slot pairs an outcome to an iteration the two sides did not share (both het renderings) |
| `hetlitmus-stats` | `verify/statscheck.py` | `het_stats_compute()` or `campaign.py` (end to end, stub harness) answers the same whatever it is handed |
| `hetlitmus-probe-hip` | `verify/runcheck.py` | one of `probe-hip.sh`'s exit paths under stand-in vendor tools (no hipcc, no gfx agent, one agent, two agents) lost its `probe_status` |

## Toolchain lane — `make hetlitmus-test-toolchain`

A target joins this lane when it needs a toolchain or a device, not because it concerns GPU code.

| target | runs | a miss means | needs |
|---|---|---|---|
| `hetlitmus-faithful` | `verify/tokens.sh all`: `covercheck.py`, then `ptxcheck.py` over `verify/faithful-cover.txt` (entries relative to the built corpus root; `tokens.sh full` sweeps both corpora) | the cover misses a corpus feature, or a harness does not run the program its `.litmus` names, read off `nvcc --ptx` | nvcc |
| `hetlitmus-smoke` | `verify/smoke.sh` | a rep's own `comp.sh` fails, or the rep list shrank below `NREPS`; no hipcc skips the `.hip` reps loudly, no clang fails | nvcc, hipcc, clang, gcc |
| `hetlitmus-stress` | `verify/tokens.sh stress` (`stresscheck.py`) | a null was scored on a GPU scratchpad stress layer nvcc folded away, or the device never ran it | nvcc, CUDA device |
| `hetlitmus-stress-static` | `verify/tokens.sh stress-static` | the deviceless half of the above; in no umbrella, CI runs it by name | nvcc |
| `hetlitmus-cpustress` | `verify/tokens.sh cpustress` (`cpustresscheck.py`) | the CPU-side or interconnect stress is removed by `-O2` on either host ISA or does no work at run time | clang (cross), gcc |
| `hetlitmus-hipbuild` | `verify/hipbuildcheck.py` | an AMD harness builds into something other than the test, its ELF carries no gfx942 code, its shared-memory resolver misbehaves under a stub `hipDeviceGetAttribute`, or the CUDA lane regresses | hipcc and nvcc, no device |
| `hetlitmus-characterize-hw` | `verify/runcheck.py --characterize-hw` | this host's relaxed-MP row, built through `hetlitmus/build.sh` and run under `HET_ALLOC` (default `pinned`), prints an arm — sighting, null, discarded — that nothing recorded | nvcc, CUDA device |

## Umbrellas, promote, CI

- `hetlitmus-test-all` runs both lanes. No hetlitmus target is a `test::` prerequisite, but
  `make test`'s `dune runtest` runs `hetlitmus/tests/cram` too, with the dune cache on.
- `hetlitmus-promote` re-cuts the goldens the corpus and cram gates pin — the `cuda-out`/`hip-out`
  samples, from the built gpu-only tree, and the cram expected blocks — and commits nothing; the
  corpus trees are build products with no golden, and the faithfulness cover is extended by
  `verify/covercheck.py --extend` instead.
- CI (`.github/workflows/hetlitmus-ci.yml`, on push to `hetlitmus-work`): one job runs
  `make -k hetlitmus-test` with `DUNE_CACHE=disabled`; the other installs clang, nvcc and hipcc and
  runs `make -k hetlitmus-faithful hetlitmus-smoke hetlitmus-stress-static hetlitmus-cpustress
  hetlitmus-hipbuild`. The two device gates fail closed on a hosted runner.

## Constraints

- Every corpus sweep but `dupcheck.py` asserts the census pinned in `verify/census.py` and its
  mirror `verify/census.sh` (gpu-only, het, het-x86_64, cover), whose tree paths mirror
  `hetlitmus/paths.sh`; a generator change that adds or removes a test moves both.
- A verify script with no Makefile target is not a gate: `verify/emit-all.sh` (emit both corpora
  over every lane, `diff -r` two snapshots) is invoked by no target or CI step.
- No gate compiles an x86_64 CPU body carrying `mfence`: every x86 render a gate builds has a
  plain `movl` column, and `hipsrccheck.py` reads `mfence` at source level only.
