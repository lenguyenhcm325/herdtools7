# Heterogeneous litmus tests (the compound format)

This document specifies the **compound `.litmus` format** for heterogeneous
CPU-GPU tests and how it is implemented in litmus7 via the **compound
pseudo-architecture** (design fork (a)). It is the *single-arch break*: it
makes a single test whose processors span a CPU ISA and a GPU ISA
*representable, parseable, and dispatchable* inside herdtools7. Cross-device
code **emission** (asymmetric launch, coherent allocation, per-iteration rendezvous,
result readback) is `het-emission.md`'s job and deliberately out of scope here.

## 1. The problem (the blocker)

herdtools7 hard-assumes **one ISA per test**. A parsed test is monomorphic in a
single `'pseudo` (`lib/miscParser.mli`: `prog = (proc * 'pseudo list) list`),
every `.litmus` begins with one arch token, the splitter stores one
`arch : Archs.t` (`lib/splitter.mli`), and the litmus7 dispatch instantiates one
functor stack `Make(Cfg)(Arch')(LexParse)(Compile)` that fixes that `'pseudo`
for the whole test. A test with `P0` on a CPU core and `P1` as a GPU kernel
thread has no representation.

## 2. The decision: fork (a), the compound pseudo-arch

Heterogeneity must live **either** (a) inside one `'pseudo` (a sum type — the
pipeline stays monomorphic, cheap, localized) **or** (b) as a *different*
`'pseudo` per processor (needs first-class-module/existential packaging and
every consumer re-dispatches — invasive). Fork (a) is chosen.

Concretely, **one** new `Archs.t` value `` `Het `` is added, implemented by a
**functor**

```
HetArch.Make (Cpu : Arch_litmus.S) (Gpu : Arch_litmus.S)   (* unsealed; an ArchBase.S *)
```

whose instruction type is a sum that delegates per constructor:

```
type reg                = CPUreg  of Cpu.reg                | GPUreg  of Gpu.reg
type instruction        = CPUins  of Cpu.instruction        | GPUins  of Gpu.instruction
type parsedInstruction  = CPUpins of Cpu.parsedInstruction  | GPUpins of Gpu.parsedInstruction
type barrier            = CPUbar  of Cpu.barrier            | GPUbar  of Gpu.barrier
```

The CPU-vs-GPU split is hidden **inside this one module**, so the rest of
litmus7 stays single-arch-typed. Each `{cpu} × {gpu}` pairing is then exactly
**one dispatch arm** in `litmus/top_litmus.ml` (functors are compile-time, the
arch tag is runtime, so supported pairings are enumerated as match arms — the
same as every existing single arch). The GH200 pairing is **AArch64 (CPU) +
LISA/PTX (GPU)**; MI300A (`+ HIP`) would be a second arm.

`HetArch.Make` is *unsealed*. Its result is used at two interfaces: `ArchBase.S`,
which is what the het `GenParser` instance requires (and what the build checks
at that application), and the parser helpers past it that the emitter drives
(`of_cpu_parsed`, `of_gpu_parsed`, `het_parser`, `to_cpu_pseudo`,
`to_gpu_pseudo`).

## 3. The file format

A heterogeneous test differs from a normal `.litmus` in exactly two places:

1. **Compound-arch header.** The first-line arch token is `Het`. It is parsed
   by the splitter through the ordinary `Archs.parse` path (no splitter grammar
   change) into the single value `` `Het ``. The sub-architecture *pairing*
   (AArch64 + LISA) is fixed by the chosen dispatch arm, not by the
   header.

2. **Per-processor device tag.** Each processor in the program header carries a
   `:`-suffixed device tag, e.g. `P0:cpu | P1:gpu`. This is the compound test's
   only extra syntax. Recognised tags (case-insensitive):
   - CPU side: `cpu`, `aarch64`, `arm`
   - GPU side: `gpu`, `lisa`, `ptx`, `hip`

   This models the existing per-test info-field convention (e.g. `Scopes=`),
   but places the tag *on the processor* where it belongs — a processor is the
   thing that has a device. The tag travels with the proc into
   `MiscParser.proc`'s annotation slot (`(p, Some ["cpu"], Main)`), so the
   dispatch arm can report each proc's backend after parsing.

Everything else — the init block, the `|`/`;` program table, the `exists`
condition — is standard. Each processor's cells are written in **that
processor's native ISA**: AArch64 assembly for `cpu` procs, LISA/Bell scoped
syntax for `gpu` procs.

### Example (`hetlitmus/tests/het/MP-het.litmus`)

```
Het MP-het
"Heterogeneous message-passing: P0 on the CPU (AArch64), P1 on the GPU (LISA/PTX)"
{
0:X1=x;
0:X3=y;
}
 P0:cpu        | P1:gpu               ;
 MOV W0,#1     | r[acquire,sys] r0 y  ;
 STR W0,[X1]   | r[relaxed,sys] r1 x  ;
 MOV W2,#1     |                      ;
 STR W2,[X3]   |                      ;
exists (1:r0=1 /\ 1:r1=0)
```

`P0` (CPU) writes data `x` then flag `y`; `P1` (GPU) reads flag `y` then data
`x`. The shared variables are 32-bit ints; AArch64 and LISA both use
`Int64Constant`, so a shared variable needs no value-module reconciliation.

## 4. Parsing (how two grammars coexist in one table)

The herdtools program table is row-major and is normally parsed by **one**
menhir grammar over **one** token type. AArch64 assembly and LISA cannot share
one grammar/lexer, so the het arm parses **per column**:

1. `lib/genParser.ml` hands `HetArch.het_parser` a lexbuf over the program
   section. `het_parser` slurps that section verbatim with `HetSlurp.slurp`
   (`litmus/hetSlurp.mll`) — it ignores the supplied token lexer (token type is
   `unit`).
2. The text is split into rows on `;` and the header row into cells on `|`,
   giving each processor's device. Instruction rows are split into per-proc
   cells and transposed into **columns**.
3. Each column's cells are re-joined with `;` and parsed by the **right
   sub-architecture's `instr_option_seq` start symbol** with that arch's lexer
   (`AArch64Parser.instr_option_seq` + `AArch64Lexer`, or
   `LISAParser.instr_option_seq` + `BellLexer`), then lifted into the compound
   parsed pseudo via `of_cpu_parsed` / `of_gpu_parsed`.
4. The per-proc columns are transposed back into rows and returned as the
   `(proc list, rows, extra_data)` triple `genParser` expects (genParser
   transposes rows→columns again internally; the two transposes cancel).

Because each column is genuinely fed to its sub-arch parser, a malformed cell on
either side is rejected (verified: a bogus AArch64 mnemonic and a bogus LISA
cell each produce a parse error), so a successful parse is not vacuous.

The `ArchBase.S` obligations needed by the parse path are all delegated
**faithfully** to the sub-architectures' exposed `Pseudo.S` output — there are
no placeholders on the parse path:
- `parsed_tr` round-trips a singleton `Instruction` pseudo through the
  sub-arch's `pseudo_parsed_tr`;
- per-instruction access counts via `get_naccesses [Instruction i]`;
- `size_of_ins`, `fold_labels`, and `map_labels` via `map_labels_base`;
- `is_valid` / `norm_ins` / `dump_instruction_hash` (used by the validity check
  and the test hash) delegate per constructor.

## 5. Scope boundary and simplifications

**What the compound format itself ships:** the `Het` format, the `` `Het ``
`Archs` variant, the `HetArch` functor satisfying `ArchBase.S`, the per-column
parser, the AArch64+LISA dispatch arm, and a clean `make all`. End-to-end,
litmus7 parses the test and routes each column to its device — and, since
harness emission was built on top of that routing
(`hetlitmus/docs/het-emission.md`), emits the harness too:

```
$ litmus7 -gpu-target cuda -o OUT hetlitmus/tests/het/MP-het.litmus
HetLitmus: emitting CPU+GPU harness for MP-het (2 procs, CPU=AArch64)
  P0 device=cpu -> CPU pthread (litmus7 AArch64 asm)
  P1 device=gpu -> GPU kernel (LISA/PTX via CudaLang/HipLang)
  pair: (AArch64, cuda)
HetLitmus: emitted harness directory OUT/MP-het (MP-het.cu)
```

The CPU column's asm is litmus7's own: the arm runs the genuine CPU compile
pipeline over the projected column and prints the body with
`ASMLang.dump_fun`, wrapping it in a `het_run_P<n>` whose caller supplies
iteration `n`'s slot address for every location.

**Left to emission, and inert here** (the record of what the single-arch break
itself shipped; emission has since closed the first item):
- The dispatch arm stops after parse + per-proc routing report; it does not
  emit a harness.
- `nop` / `mk_imm_branch` are `None` (no device-agnostic compound form);
  `get_macro` errors (the corpus uses no macros); `symb_reg` and the
  cross-device arms of `map_regs` default harmlessly (registers never cross
  devices). None of these are on the parse path.

**Lexical limitations of the per-column splitter** (documented, safe for
the hand-written corpus): the program body must not contain `;` or `|` *inside*
an instruction cell, and must not contain comments — these characters are
treated purely as table delimiters. `map_labels` is **not** a placeholder: it
delegates per constructor to each sub-architecture's `map_labels_base` (see §4),
so labels and branch targets *within* a processor are renamed faithfully. The
only structural caveat is that a label cannot cross devices — each processor's
column is parsed independently — but a cross-device branch is meaningless
anyway. The het corpus happens to use no branch targets, so this path is
currently unexercised in practice.

## 6. Files

| File | Change |
|------|--------|
| `lib/Archs.ml`, `lib/Archs.mli` | new `` `Het `` arch variant + `parse`/`pp`/`tags` |
| `lib/splitter.mli`, `lib/splitter.mll` | documentation of why the single `arch` field is unchanged under fork (a) |
| `litmus/HetArch.ml` | the `HetArch` functor (sum-type `ArchBase.S`) + per-column parser helpers |
| `litmus/hetSlurp.mll` | section-slurp lexer used by the het parser |
| `litmus/top_litmus.ml` | the `` `Het `` dispatch arm (AArch64+LISA pairing, per-proc sub-parser routing) |
| `litmus/option.ml`, `gen/autoOpt.ml` | `` `Het `` arms for exhaustiveness |
| `hetlitmus/tests/het/MP-het.litmus` | the sample heterogeneous MP test |
