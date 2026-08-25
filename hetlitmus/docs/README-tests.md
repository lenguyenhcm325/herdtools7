# Makefile entries for HetLitmus tests

The roster is the Makefile: `grep -E '^hetlitmus-[a-z0-9-]+:' Makefile`. Each gate's
contract lives in the script its target runs; a bullet says what a target proves and
needs. Nothing here runs the device session (`hetlitmus/hetlitmus-run.sh`, by hand).

## Base lane — `make hetlitmus-test` (OCaml build, gcc, python3; no GPU compiler, no device)
  + `make hetlitmus-cram`, `dune runtest hetlitmus/tests/cram`: the corpus rule functions and
    the emitted drivers, read statically; every `.t` but `basics` and `ptx-negatives` needs `litmus7`.
  + `make hetlitmus-corpus`, `verify/corpus-gate.sh`: the committed corpora, the `tests/het-x86`
    fixture and the `cuda-out`/`hip-out` samples are what the generators and the emitter produce,
    plus the census against `verify/census.sh`. Exit 0 pass, 1 drift, 2 infrastructure.
  + `make hetlitmus-dup`, `verify/dupcheck.py`: no two het tests are the same experiment up to
    proc permutation × location renaming; an empty `--dir` is a refusal.
  + `make hetlitmus-hipsrc`, `verify/hipsrccheck.py --all`: every HIP kernel and x86_64 CPU body
    carries exactly the ops its `.litmus` annotates, at source level (no hipcc).
  + `make hetlitmus-verdict`, `verify/verdictcheck.py`: `het_verdict()` compiled from the real
    emitted header and driven with synthetic records; the printout and the stamped pair.
  + `make hetlitmus-recfields`, `verify/recfields.py`: every `_rec.<field>` a render writes and
    every `HET_*` define it stamps binds to `litmus/het-runtime/*.h`, over both pairs.
  + `make hetlitmus-rdv`, `verify/rdvcheck.py`: every iteration begins at the rendezvous, ahead
    of the tested accesses, and the primitive orders nothing; both het renderings are swept.
  + `make hetlitmus-stats`, `verify/statscheck.py`: `het_stats_compute()` from the real header,
    the stop rule, and `campaign.py` end to end against a stub runner.
  + `make hetlitmus-cpuonly`, `tests/het/generate-cpuonly.sh`: the all-CPU shapes are generated,
    emitted and read for the `_rec.cpu_only = 1` stamp against a negative control; nothing runs.
  + `make hetlitmus-run-gate`, `verify/runcheck.py`: the device-session wrapper end to end against
    a stand-in compiler and probe (dry-run, chain, refusals, fail-closed handlers, second session).

## Toolchain lane — `make hetlitmus-test-toolchain` (nvcc, hipcc, clang; two members need a device)
  + `make hetlitmus-faithful`, `verify/tokens.sh all`: `covercheck.py` proves the committed
    `verify/faithful-cover.txt` reaches every feature of both corpora, then `ptxcheck.py` reads
    exactly the annotated ops off `nvcc --ptx` for that cover (`tokens.sh full`: both corpora entire).
  + `make hetlitmus-smoke`, `verify/smoke.sh`: a curated rep sample builds through its own
    `comp.sh` (gcc, clang cross-assembly, `nvcc -c`, `hipcc -c`); no hipcc is a loud SKIP, no clang a FAIL.
  + `make hetlitmus-stress`, `verify/tokens.sh stress`: the GPU scratchpad stress is in the emitted
    PTX, pattern-invariant, and its tally moves at run time (`device-probe`). Needs a CUDA device.
  + `make hetlitmus-stress-static`, `verify/tokens.sh stress-static`: the deviceless half of the
    above (the static checks, `gpu-noise-live`/`-runtime`). In no umbrella; CI runs it by name.
  + `make hetlitmus-cpustress`, `verify/tokens.sh cpustress`: the CPU-side and interconnect stress
    survive `-O2` on both host ISAs (clang cross) and do work at run time (gcc). No nvcc.
  + `make hetlitmus-hipbuild`, `verify/hipbuildcheck.py`: an AMD harness links into a gfx942 ELF,
    its allocator and placement refusals execute under a stub, and the CUDA lane does not regress.
  + `make hetlitmus-characterize-hw`, `verify/runcheck.py --characterize-hw`: this host's
    relaxed-MP row is built, run on the GPU (`HET_ALLOC=pinned` unless set) and read off its
    printout; a sighting, a null and a discarded run are each an arm. Needs a CUDA device.

## Umbrellas, promote, CI
  + `make hetlitmus-test`, the base lane; `make hetlitmus-test-toolchain`, the toolchain lane (a
    target joins it when it needs a toolchain or a device, not merely because it concerns GPU
    code); `make hetlitmus-test-all`, both.
  + `make hetlitmus-promote`: regenerates both corpora in place, re-cuts the `tests/het-x86`
    fixture, re-emits the `cuda-out`/`hip-out` samples, promotes the cram goldens; commits nothing,
    read `git diff` first. Not the faithfulness cover (`verify/covercheck.py --extend`).
  + CI (`.github/workflows/hetlitmus-ci.yml`): one job runs `make -k hetlitmus-test` with
    `DUNE_CACHE: disabled`; the other installs clang, nvcc and hipcc and runs `make -k
    hetlitmus-faithful hetlitmus-smoke hetlitmus-stress-static hetlitmus-cpustress hetlitmus-hipbuild`.
    The two device gates fail closed on a hosted runner and run on a GPU box only.

Notice:
  1. Two guarantees: regression (the goldens pin what the tools produce today) and works-as-expected
     (contract, faithfulness and negative-control checks); a golden reproduces a bug forever.
  2. Negative controls exist only where they are the sole coverage of a product behaviour; there is
     no self-test lane.
  3. No hetlitmus target is a `test::` prerequisite, but upstream `dune runtest` (`make test`) runs
     `hetlitmus/tests/cram` too, without `DUNE_CACHE=disabled`.
  4. Two goldens, two buttons: cram expected blocks → `dune promote`; corpus, fixture and samples →
     regenerate and `git commit`. `hetlitmus-promote` presses both.
  5. `corpus-gate.sh` compares out of tree (a temp dir), so the working tree is untouched pass or
     fail and drift is told apart from a generator that wrote nothing; it byte-pins `@all` too.
  6. No gate runs the device-session wrapper on a device: a gate over it could read only the
     session's bookkeeping, never the outcome.
  7. `hetlitmus/tests/cram/dune` is the authority for the stanzas and carries the `litmus/libdir`
     trap: a cram run re-runs only when a declared dep changes (`--force` re-runs only the diff),
     and `gpu-target.t` reads `litmus/libdir`, which no dep can name, hence its `(universe)` dep.
     `DUNE_CACHE=disabled` keeps a fresh build tree from replaying a run from the shared cache.
  8. Anti-vacuity: every sweep asserts a pinned census (`verify/census.py`, mirrored in
     `verify/census.sh`, the two compared by `corpus-gate.sh`) and fails closed on an empty input;
     `hipbuildcheck.py` refuses a phase that made no assertions; `smoke.sh` pins `NREPS`.
  9. A verify script that is not in the build is a script, not a gate: its target and its umbrella
     hookup land in the same change.
  10. `verify/emit-all.sh` is invoked by no target or CI step: it is the refactor instrument (emit
      both corpora over every lane, `diff -r` two snapshots). `hetlitmus/compile-hip.sh` is likewise
      invoked by no target (`hip-emitter.md`, "Compile status").
  11. No target compiles a HIP render whose x86_64 CPU column carries `mfence`: `hetlitmus-hipbuild`'s
      render and `hetlitmus-smoke`'s HIP reps have plain `movl` columns, and `hipsrccheck.py` reads
      `mfence` at source level only.
