# Heterogeneous test generation

`hetgen7` (`gen/hetGen.ml`) generates one heterogeneous CPU-GPU test in the
compound `Het` format (`het-litmus-format.md`) from a per-processor device
assignment. It produces the test only: harness emission is
`het-emission.md`, execution is hardware-only, and a generated test carries
no expected outcome.

## 1. The constraint

The diy cycle engine (`gen/top_gen.ml`) compiles one cycle into a test whose
every processor is encoded in one architecture, the gen-side mirror of the
single-arch assumption `HetArch` works around in litmus7.

## 2. One engine run per device, then merge columns

`hetgen7` runs the unmodified engine once per device, on a device-appropriate
cycle of the same logical shape, and keeps for each processor the column of
the run that owns that processor's device:

```
hetgen7 -set-libdir herd/libdir -bell ptx.bell -devices cpu,gpu -name MP-het \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys"
```

`-cpu` is built by the CPU builder `-cpu-arch` selects (AArch64 by default,
x86_64 on request), `-gpu` by the LISA/Bell builder; `-devices` assigns
`P0 -> cpu`, `P1 -> gpu`. `hetlitmus/tests/het/generate.sh` is the corpus's
invocation (`corpus-grid.md`).

The merge is well-formed because a diy test is determined by its cycle: the
cycle fixes the processor count, the accesses on each processor, the shared
locations and the final condition over the reader registers; only the
instruction encoding of each access is architecture-specific. Two runs over
the same edge sequence therefore agree on everything but spelling
(`STR W0,[X1]` vs `w[release,sys] x 1`), and a per-processor splice of
columns, init atoms and condition atoms yields one consistent test. The
driver checks that both runs report the `-devices` proc count and nothing
deeper: cycles of different shape are user error.

## 3. The cross-architecture boundary: `HetCells.t`

The CPU and LISA builders are different `Arch` modules, so their `test`
records have different types and cannot be held side by side. Each builder
therefore erases its test to strings, `HetCells.t` (`gen/hetCells.ml`, via
`Builder.S.het_cells`), rendered by the builder's own dumpers. `hetGen`
merges the string records: each proc's cells, register atoms and condition
atoms come from its owner; global init and condition atoms are unioned over
both runs.

## 4. Scope

`-devices` carries the device axis; the scope axis rides on the GPU edge
annotations (`ReleaseSys`, `AcquireCta`, ...: order and scope per access, as
in the GPU-only corpus and `hetlitmus/bells/ptx.bell`), which carry into the
GPU column as-is.

`hetgen7` also writes a `scopes:` body tree (grammar `lib/scopeRules.mly`),
each GPU proc in its own CTA under the GPU device: `scopes: (sys (gpu (cta
P1)))` for `-devices cpu,gpu`. CPU procs are absent from it: the emitter's
tree places GPU procs only, and the grammar makes a node either all-procs or
all-subtrees, so a CPU proc could not share the `sys` node with the `gpu`
subtree. The tree goes in the body rather than diy's `Scopes=` info field
because herd7 reads the body form and never the field. Two HetLitmus changes
to upstream files let diy write it: `lib/coreDumper.ml` prints a
`MiscParser.BellExtra` tree through `BellInfo.pp` (inert without one), and
`lib/scopeLexer.mll` has an `eof` rule so `diyone7 -scopes "(tree)"` parses
to the end. `hetgen7` composes its own `scopes:` line rather than routing
through `-scopes`; both corpora carry the same grammar.

The tree is load-bearing although herd7 does not read a `Het` test:
litmus7's het parser hands it on as `MiscParser.BellExtra`, and the emitter
takes the launch geometry from it (`cuda-emitter.md`, "Mappings"), so a test
placing its GPU procs in one CTA and one placing them in two emit different
harnesses.

## 5. Limitations

- Both cycles must have the same logical shape; only the proc count is
  checked.
- The condition merge splices per-proc atoms out of a flat conjunction, so
  `-cond cycle` is the only condition style: `-cond unicond` and `-cond
  observe` are refused, and a disjunction is not split.
- The CPU side is `-cpu-arch aarch64` (default) or `x86_64`; the GPU column
  is LISA/Bell for either GPU dialect, the dialect being litmus7's
  `-gpu-target` (`het-emission.md`, "One render per `-gpu-target`").
