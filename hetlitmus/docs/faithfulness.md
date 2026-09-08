# Lowering faithfulness

Home of the faithfulness property: every emitted harness carries exactly the
order, scope and op kind its `.litmus` annotation specifies.

## Stated on the PTX

`cuda::atomic_thread_fence` cannot express a one-sided fence [CCCL], so a CUDA
fence is inline PTX (`gpu-emitters.md`, "Fence lowering"). The PTX witnesses
the order: inline asm keeps source order [CCCL], scaffolding carries none.

## Stated on HIP source

The HIP path has no inline assembly, so only the emitter half of the failure
surface shows. What `hipcc` makes of the constants is UNVERIFIED: [AMDGPUUsage]
spells the memory model per GPU generation; no lowering profile is kept here.

## CPU column (AArch64)

`STLR` is store-release, `LDAPR` load-acquire RCpc [ArmA64ISA "STLR", "LDAPR"].
`DMB SY` orders reads and writes on both sides, `DMB ST` writes against later
writes, `DMB LD` reads against later reads and writes [ArmA64ISA "DMB"], so
`DMB ST` in `DMB SY`'s place is a different instruction. RCpc is upstream's
`ReadAcqPc` atom lowered to `LDAPR`, so the build needs `-march=armv8.3-a`.

## Het lane loop

A het lane's body is one `#pragma unroll 1` loop: a rendezvous lifted out of it
would join the devices once and leave every later iteration unsynchronised.

## Runtime stress pattern

The GPU stress routine takes its access pattern as a runtime kernel argument: a
constant lets nvcc hoist the traffic out and leave the bookkeeping, and
`volatile` is not the fix, since the stress must stay plain cacheable traffic.

## CPU-side stress liveness

`volatile` on the CPU stress thread's discarded load is load-bearing: without
it the read half of every pattern is deleted.

## Scope and limits

Static lowering only: reordering by `ptxas` or the hardware is under test.
Stress carries no order or scope qualifier, so the property cannot see the
stress layer; only a tally says it ran. On HIP the loop placement is a
source-level statement. The CPU half is the column's rendering only: the cache
preload touches the same locations outside it. The lane at `(0,0)` bumps the
device-only `_gpu_iter`, not the rendezvous counter, whose latency sets
cross-device alignment.
