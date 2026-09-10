# Heterogeneous CPU+GPU harness emission

## CPU ISA from the device tag

One harness is derived over one CPU backend, so a header naming two CPU ISAs is
refused. The ISA comes from a pre-scan of the header, before any parser exists.

## One render per `-gpu-target`

The flag has no default, because a default would pick the vendor silently.

## Reuse and what is new

The CPU columns run through litmus7's own compile pipeline, so the CPU half's
faithfulness is litmus7's lowering (`faithfulness.md`, "CPU column (AArch64)")
and the driver, not the asm, does the slot arithmetic. The GPU columns reuse
the GPU-only lowering; new is the het scaffold: the per-proc guard, the
rendezvous and the slot addressing (`environment-design.md`
"Allocation", "Rendezvous").

## The CPU object

`<t>_cpu.c` holds the asm under a host-macro `#if` with an `#error` in the
`#else`, so exactly one compiler can produce an object and a foreign host never
hands back a runnable binary. It cross-assembles the file with clang instead,
whose integrated assembler needs no cross-binutils; a missing `clang` is an
error exit, not a skip, so nothing reports success having assembled nothing.
`HET_CPU_CFLAGS` carries `-march=armv8.3-a` on an AArch64 render, where the
`ra` order's acquire read is LDAPR (ARMv8.3 RCpc), and only where `uname -m`
matches, since a foreign `-march` is rejected before the `#error` is reached.

## The pair a harness names

A harness is a (CPU ISA x GPU dialect) pair, not a machine: `HET_PAIR_NAME` is
the only thing that says which pair a binary measured, and one built for the
wrong pair compiles, runs and reports identically. The emitted printouts name
mechanisms, never parts, so no printed sentence becomes a claim about a
machine. Name the device arch explicitly, never `-arch=native`: the arch a
binary was built for must be a recorded value, and `native` records nothing.
`HET_LLC_MB` is the last-level cache a noise buffer must exceed to cross the
interconnect at all, 256 MB on MI300A [Tee25 Table 1]; unsupplied it takes
another part's figure ([Bagchi26 Table 1]), which a run warning discloses as a
fallback.

## Scope / limits

A het test has at least one `gpu` proc: threads all of one architecture
exercise no compound composition ([Goens23] §4.6). A het emission that emits
nothing exits 3, unlike litmus7's own per-test failure, which exits 0 and reads
as success to a caller redirecting stdout. The condition compiler does not
check that some store writes the value an atom asks for: such a condition
compiles to a permanently false detector reported as a null, not refused.
Emission stops at a harness that compiles; nothing is launched.

## From a corpus to a results dir

All four steps share `RESULTS`, so one run's artefacts sit in one directory.

```
export RESULTS=hetlitmus/run-out/<tag>
sh hetlitmus/probe-cuda.sh
hetlitmus/emit-het.sh --gpu-target cuda _build/default/hetlitmus/tests/het
hetlitmus/build.sh $RESULTS/emit
python3 hetlitmus/campaign.py --corpus $RESULTS/emit --budget-runs 100 --state $RESULTS/campaign.csv
```

The HIP run differs in the probe script, the `--gpu-target` value and the
corpus tree. The campaign draws a seed base and banks it in every state row;
`--seed0` replays it. Each `HET_ALLOC` mode is system-scope atomic only under a
condition of [CudaGuide "Atomicity"], so a failing mode is undefined rather
than weaker, and the allocator's guards are fatal.
