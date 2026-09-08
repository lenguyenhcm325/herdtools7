# Heterogeneous litmus tests (the compound format)

The compound `.litmus` format, and the decisions behind parsing and generating it.

## The constraint
herdtools7 is one ISA per test on both sides: a parsed test is monomorphic in one `'pseudo` that each
litmus7 dispatch arm fixes, and the diy cycle engine encodes every processor of a cycle in one architecture.

## The compound pseudo-arch
Heterogeneity lives inside one `'pseudo`, the `Archs.t` value `Het` that `HetArch.Make (Cpu) (Gpu)` builds
as a sum of the two backends, because a `'pseudo` per processor would need existential packaging and a
re-dispatch in every consumer. Functors are compile-time and the arch tag is runtime, so litmus7's `Het`
arm builds one CPU module chain per supported CPU ISA and picks between them by pre-scanning the header's
device tags.

## The file format
A heterogeneous test differs from a single-arch `.litmus` in three places:
```
Het MP-cg-sys-plain.acq
"Heterogeneous MP-cg-sys-plain.acq: per-proc device assignment cpu,gpu (cpu=AArch64, gpu=LISA)"
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
1. The arch token `Het`, which names neither sub-architecture.
2. A device tag on every processor, where all CPU procs of one test name ONE ISA.
3. A `scopes:` row, anywhere in the program section, giving the scope tree the GPU procs are launched in,
   in the grammar herd7 reads.

## Parsing per column
CPU assembly and LISA share no grammar, so `HetArch.het_parser` cuts the program table into per-processor
columns and hands each to its own sub-architecture's lexer and parser.

## One run per device
`hetgen7` runs the unmodified cycle engine once per device on a cycle of the same logical shape and keeps
for each processor the column of the run that owns that processor's device. The merge is well-formed
because a diy test is determined by its cycle, so two runs over the same edge sequence agree on everything
but the spelling of each access. Dependency, standalone-fence and read-modify-write edges carry an
architecture-typed kind, so the shape check refuses them rather than comparing them.

## String erasure
The CPU and LISA builders are different `Arch` modules whose `test` records cannot be held side by side, so
each erases its test to strings (`HetCells.t`) for the merge.

## The scopes tree
The tree goes in the test body rather than diy's `Scopes=` info field because herd7 reads the body form and
never the field. CPU procs are absent from it because the grammar makes a node either all-procs or
all-subtrees, so a CPU proc could not share the `sys` node with the `gpu` subtree. Two upstream files carry
a HetLitmus change so diy can write it: `lib/coreDumper.ml` prints a `MiscParser.BellExtra` tree, and
`lib/scopeLexer.mll` has an `eof` rule.

## Limits
- `;` and `|` are table delimiters everywhere in the program section, comments included.
- Labels are per column, so a branch target cannot cross devices.
- Only `-cond cycle` works: the merge splices per-proc atoms out of a flat conjunction, which no other
  condition style produces.
- herd7 does not read a `Het` test.
