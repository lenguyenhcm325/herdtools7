# Heterogeneous test generation (generation axis)

This document specifies how `diy7` is extended to **generate** heterogeneous
CPU-GPU litmus tests in the compound `Het` format (see `het-litmus-format.md`).
The compound pseudo-arch made a hand-written compound test *representable,
parseable, and routable*; the generator described here *emits* such tests
automatically from a per-processor `{device, scope}` assignment.

The hardware/gem5 *execution* of these tests is **out of scope**, and so is the
matching oracle-comparison half: the tests carry no expected outcome, and a
reader who wants one brings both the verdicts file and the comparator.

## 1. The problem: the generator is monomorphic in one architecture

The diy cycle engine (`gen/top_gen.ml`) compiles **one** critical cycle of
annotated edges into a test whose every processor is encoded in **one**
architecture: `diyone7 -arch AArch64` emits AArch64 on every proc, `diyone7
-bell ptx.bell -arch LISA` emits LISA on every proc. This is the gen-side mirror
of the litmus7 single-arch blocker that `HetArch` solved. A single
engine run therefore cannot produce a test whose `P0` is an AArch64 CPU thread
and whose `P1` is a scoped LISA/PTX GPU thread.

## 2. The design: one engine run per device, then merge columns

`gen/hetGen.ml` (`hetgen7`) runs the **unmodified** cycle engine **once per
device**, on a device-appropriate cycle of the **same logical shape**, and then
keeps, for each processor, the column produced by the run that **owns** that
processor's device:

```
hetgen7 -set-libdir herd/libdir -bell ptx.bell -devices cpu,gpu -name MP-het \
  -cpu "PodWW Rfe PodRR Fre" \
  -gpu "PodWWRelaxedSysReleaseSys RfeReleaseSysAcquireSys PodRRAcquireSysRelaxedSys FreRelaxedSysRelaxedSys"
```

- the **`-cpu`** cycle is generated with the AArch64 builder (plain accesses);
- the **`-gpu`** cycle is generated with the LISA/Bell builder (scoped
  acquire/release accesses);
- **`-devices cpu,gpu`** assigns `P0 -> cpu`, `P1 -> gpu`.

For `MP-het`, `P0` (the writer column) is taken from the AArch64 run and `P1`
(the reader column) from the LISA run; the merged test is:

```
Het MP-het
"Heterogeneous message-passing: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)"
{
0:X1=x;
0:X3=y;
}
 P0:cpu      | P1:gpu              ;
 MOV W0,#1   | r[acquire,sys] r0 y ;
 STR W0,[X1] | r[relaxed,sys] r1 x ;
 MOV W2,#1   |                     ;
 STR W2,[X3] |                     ;
exists (1:r0=1 /\ 1:r1=0)
```

This is byte-for-byte (modulo table whitespace) the hand-written
`MP-het.litmus`; `tests/het/generate.sh` regenerates it and checks the
reproduction with `diff -w`.

### Why the merge is sound

A diy test is determined by its cycle. The cycle fixes the **event graph**: how
many processors there are, which memory accesses live on each, the **shared
locations** they touch (`x`, `y`, …), and the **final condition** over the
reader registers. Only the *instruction encoding* of each access is
architecture-specific. The two runs use the **same cycle shape** (same edge
sequence, same number of procs, same per-proc roles), so they agree on
locations, proc structure, and condition structure; they differ **only** in how
each access is spelled (`STR W0,[X1]` vs `w[release,sys] x 1`). Keeping proc *p*'s
column from the run that owns *p*'s device therefore yields a well-formed test:
every shared variable is the same physical location in both runs (Int64Constant
on both sides — see `het-litmus-format.md` §3), and each processor speaks its own
ISA. The annotation difference between the two cycles (a plain `PodWW` on the CPU
side vs a scoped `…ReleaseSys` on the GPU side) changes only encodings, never the
locations or the condition.

The driver **validates** this precondition: it aborts unless both runs report
the same processor count as the `-devices` list (`gen/hetGen.ml`,
"Both runs must agree on the proc count").

## 3. The cross-architecture boundary: `HetCells.t` (strings)

The AArch64 and LISA builders are **different `Arch` modules**, so their `test`
records have **different OCaml types** and cannot be held side by side. The
boundary that lets them be combined is a small **string** record,
`HetCells.t` (`gen/hetCells.ml`), exposed by every builder via a new
`Builder.S.het_cells` method (`gen/builder.mli`, implemented in `gen/top_gen.ml`;
the C/C++ backend, which is never a het column, stubs it in
`gen/CCompile_gen.ml`):

```
type t = {
  hc_init : (int option * string) list ;  (* (owning proc, atom); None = global *)
  hc_cols : (int * string list) list ;    (* per proc: instruction-cell strings *)
  hc_cond : string ;                       (* full condition, e.g. "exists (..)" *)
}
```

`het_cells` reuses the builder's own renderers — `A.dump_instruction` for cells
(mirroring `lib/simpleDumper.ml`'s `fmt_io`), `State.dump_state_atom` for init
atoms, and `Final.dump_constr` for the condition — so a proc's cells render
exactly as in a normal single-arch dump. With strings on both sides, `hetGen`
merges three things:

- **columns** — proc *p*'s cells come from `run_of(devices[p])`, then the
  aligned `P0:dev | P1:dev | …` table is produced by `Misc.string_of_prog`;
- **init** — each proc's register atoms (`p:Reg=val`) come from its owner; global
  atoms (`x=0`) are unioned across both runs and de-duplicated;
- **condition** — atoms are classified by their leading proc number; proc *p*'s
  atoms are taken from its owner's condition and recombined with the original
  quantifier. (`SB-het` exercises this: `exists (0:X3=0 /\ 1:r0=0)` keeps the
  `0:`-atom from the AArch64 run and the `1:`-atom from the LISA run.)

This is the gen-side analogue of `litmus/HetArch.ml`: heterogeneity is a per-proc
`{device, scope}` assignment over otherwise standard single-arch generation, with
strings as the erasure boundary.

## 4. Scope

`-devices` carries the device axis; the **scope** axis rides on the GPU edge
annotations themselves (`ReleaseSys`, `AcquireCta`, … — order+scope per access,
exactly as in the GPU-only corpus, `bells/ptx.bell`). These inline per-access
scope tags are what carry into the GPU column.

In addition, hetgen7 now emits a **parseable nested `scopes:` body tree** (the
grammar is `lib/scopeRules.mly`; diy's `Scopes=` header info field is *not*
herd-parseable, so we follow the GPU-only `generate.sh` precedent of writing the
tree into the test body). Each GPU-owned proc nests in its own CTA under the GPU
device, e.g. `scopes: (sys (gpu (cta P1)))` for `-devices cpu,gpu`. CPU procs are
system-scope and are therefore *omitted* from the tree — a proc absent from every
sub-scope group sits at the `sys` root by default (and the scope grammar makes a
node either all-procs or all-subtrees, so a CPU proc could not share the `sys`
node with the `gpu` subtree in any case). With no GPU proc the tree degenerates
to `scopes: (sys)`.

That GPU-only precedent is worth spelling out, because it took two repairs to
**upstream** files before diy could produce a herd-parseable `scopes:` section
at all — until they landed, `tests/gpu-only/generate.sh` had to append the line
with `awk`. Both are live in this tree:

* **The dumper discarded the tree it was handed.** `diyone7` already builds the
  structured scope tree and passes it down as `MiscParser.BellExtra`
  (`gen/top_gen.ml`), but `lib/coreDumper.ml`'s `do_dump` printed info, init,
  program and condition and dropped `extra_data`. It now prints the tree through
  `BellInfo.pp` ahead of the condition, guarded so it stays inert for a test that
  carries no scope tree. herd's parser already *read* `scopes:`; the dumper now
  *writes* it.
* **The literal `-scopes "(tree)"` path could not lex.** `lib/scopeParser.mly`
  starts at `main: top_scope_tree EOF`, but `lib/scopeLexer.mll` had no `eof`
  rule, so end of input fell through to the error case (*"Lex error Scope
  lexer"*) and every nested literal tree was rejected. `| eof { EOF }` supplies
  the token the grammar requires.

With both in place, `diyone7 … -scopes "(sys (gpu (cta P0) …))"` writes the
`scopes:` line itself (`hetlitmus/tests/gpu-only/generate.sh`), with no shell
post-processing. `hetgen7` does **not** route through that path — it composes
its own `scopes:` line into the test buffer directly (`gen/hetGen.ml`) — but it
emits the same grammar, so both corpora carry the tree in one form.

The het tests are **not** herd-ingested (the single-arch assumption blocks that),
so the tree is documentary rather than load-bearing: litmus7's `Het` arm parser
(`HetArch.het_parser`) explicitly **skips** the `scopes:` line — it carries no
`;` and would otherwise survive HetSlurp as a spurious trailing program row — and
the CPU/GPU emission does not consume it. Emitting a herd-parseable tree is the
deliverable; making herd *read* it for a het test remains future work behind the
single-arch break.

## 5. End-to-end check

```
$ hetgen7 ... -name MP-het -cpu "PodWW Rfe PodRR Fre" -gpu "PodWW…ReleaseSys …" > MP-het.litmus
$ litmus7 -gpu-target cuda -o OUT hetlitmus/tests/het/MP-het.litmus
HetLitmus: emitting CPU+GPU harness for MP-het (2 procs, CPU=AArch64)
  P0 device=cpu -> CPU pthread (litmus7 AArch64 asm)
  P1 device=gpu -> GPU kernel (LISA/PTX via CudaLang/HipLang)
  pair: (AArch64, cuda)
HetLitmus: emitted harness directory OUT/MP-het (MP-het.cu)
```

`tests/het/generate.sh` produces `SB-het.litmus` and verifies the `MP-het`
reproduction; both generated tests parse and route through litmus7's `Het` arm
without error.

## 6. Files

| File | Change |
|------|--------|
| `gen/hetGen.ml` | new `hetgen7` driver: per-device runs + column/init/condition merge |
| `gen/hetCells.ml` | new string record `HetCells.t` (cross-arch boundary) |
| `gen/builder.mli`, `gen/top_gen.ml` | new `Builder.S.het_cells` accessor (real impl) |
| `gen/CCompile_gen.ml` | `het_cells` stub (C/C++ is never a het column) |
| `gen/dune` | build `hetGen` / install `hetgen7` |
| `hetlitmus/tests/het/generate.sh` | generate the het corpus (`SB-het`, reproduce `MP-het`) |
| `hetlitmus/tests/het/SB-het.litmus` | generated het store-buffering test |

## 7. Limitations (generation scope)

- The two `-cpu` / `-gpu` cycles must describe the **same logical shape** (same
  proc count and per-proc roles); the driver checks proc counts but not deeper
  shape equivalence — supplying mismatched cycles is user error.
- The condition merge assumes **conjunctive** `exists`/`forall` conditions
  (`a /\ b /\ …`), which the MP/SB/LB/IRIW corpus uses; disjunctions are not
  split.
- Device pairing is fixed to **AArch64 (cpu) + LISA/PTX (gpu)** (the GH200
  target), matching the single compound dispatch arm. A second `+ HIP` pairing
  (MI300A) would add one builder wiring here and one dispatch arm in
  `litmus/top_litmus.ml`.
- Generation produces the **test**; cross-device harness *emission* (asymmetric
  launch, coherent allocation, per-iteration rendezvous, readback) is
  `het-emission.md`'s job, and *execution* is hardware-only.
