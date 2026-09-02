# Heterogeneous litmus tests (the compound format)

The compound `.litmus` format places the processors of one test on a CPU ISA
and a GPU ISA, and litmus7 parses it through one compound
pseudo-architecture. This document covers representation and parsing.
Harness emission is `het-emission.md`; generation is `het-generation.md`.

## 1. The constraint

herdtools7 assumes one ISA per test: a parsed test is monomorphic in one
`'pseudo` (`lib/miscParser.mli`), the splitter records one `arch : Archs.t`
(`lib/splitter.mli`), and each litmus7 dispatch arm instantiates one functor
stack that fixes that `'pseudo` for the whole test.

## 2. The compound pseudo-arch

Heterogeneity lives inside one `'pseudo`: a single `Archs.t` value `` `Het ``,
implemented by `HetArch.Make (Cpu) (Gpu)` (`litmus/HetArch.ml`), whose
register, instruction, parsed-instruction and barrier types are sums of the
two backends' and delegate per constructor. The alternative, a different
`'pseudo` per processor, needs existential packaging and a re-dispatch in
every consumer; the sum keeps the rest of litmus7 single-arch-typed.

Functors are compile-time and the arch tag is runtime, so the `` `Het `` arm
of `litmus/top_litmus.ml` builds one CPU module chain per supported CPU ISA,
AArch64 or x86_64, chosen by `HetArch.scan_cpu_isa` from the device tags of
sec 3, and drives `HetEmit.Make` over it; the GPU side is LISA/Bell in both.
The GPU dialect, CUDA or HIP, is not an arm: it is litmus7's `-gpu-target`
(`het-emission.md`, "CPU ISA from the device tag").

`HetArch.Make` is unsealed: `GenParser.Make` takes its result as an
`ArchBase.S`, and the emitter uses the parser helpers past that signature
(`of_cpu_parsed`, `of_gpu_parsed`, `het_parser`, `to_cpu_pseudo`,
`to_gpu_pseudo`).

## 3. The file format

A heterogeneous test differs from a single-arch `.litmus` in three places;
`hetlitmus/tests/het/MP-het.litmus` shows all three.

1. **Arch token `Het`.** Read by the splitter through `Archs.parse` with no
   grammar change. The header names neither sub-architecture: the CPU ISA
   comes from the device tags, the GPU dialect from `-gpu-target`.
2. **A device tag on every processor** of the program header, `P0:cpu |
   P1:gpu`. A CPU tag names the ISA: `cpu`, `aarch64`, `arm` for AArch64;
   `x86_64`, `x86-64`, `amd64`, `x64` for x86_64. GPU tags: `gpu`, `lisa`,
   `ptx`, `hip`. Tags are case-insensitive; the corpora use `cpu`, `x86_64`
   and `gpu`. All CPU procs of one test name one ISA; a header naming two is
   refused. The tag travels with the proc in `MiscParser.proc`'s annotation
   slot, which is how the emitter tells each proc's device after parsing.
3. **A `scopes:` row**, the scope tree the GPU procs are launched in, in the
   grammar herd7 reads (`lib/scopeRules.mly`): `scopes: (sys (gpu (cta P1)))`.
   Its position in the program section does not matter. The launch geometry
   is derived from it (`cuda-emitter.md`, "Mappings"); what a tree must
   satisfy is `het-emission.md`, "Scope / limits".

Everything else is standard. Each processor's cells are in that processor's
own ISA: the tagged CPU ISA's assembly for CPU procs, LISA/Bell scoped syntax
for GPU procs, whose registers are `rN` and whose cells carry the vocabulary
of `hetlitmus/bells/ptx.bell` only (`het-emission.md`, "Scope / limits").

## 4. Parsing: one column at a time

The program table is normally parsed by one menhir grammar over one token
type. CPU assembly and LISA share no grammar, so `HetArch.het_parser` parses
per column: it slurps the program section verbatim (`litmus/hetSlurp.mll`),
cuts out the `scopes:` row, splits rows on `;` and cells on `|`, transposes
to columns, and feeds each column, re-joined with `;`, to its own
sub-architecture's `instr_option_seq` start symbol and lexer
(`litmus/hetCpuFront.ml` for a CPU column, `LISAParser` and `BellLexer` for a
GPU column), lifting the result into the compound parsed pseudo. A malformed
cell on either side is a parse error from that side's parser.

The `ArchBase.S` obligations on the parse path delegate to the
sub-architectures' own `Pseudo.S` output; `parsed_tr` recovers a sub-arch's
parsed-to-internal translation by round-tripping a singleton `Instruction`
through its `pseudo_parsed_tr`.

## 5. Limits

- `;` and `|` are table delimiters everywhere in the program section, inside
  cells and comments included.
- Labels are per column, so a branch target cannot cross devices.
- A test with no `gpu` proc, a header naming two CPU ISAs, and a GPU cell
  outside the `ptx.bell` vocabulary are refused with exit 3
  (`het-emission.md`, "Scope / limits").
- herd7 does not read a `Het` test.
