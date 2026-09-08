# GPU emitters (CUDA and HIP)

## Why this shape
The Bell/LISA scoped IR is the GPU frontend: there is no native PTX architecture. The emitters
consume the parsed Bell program, not litmus7's `Out` template, which loses the order+scope pair.

## sc accesses
PTX has no `.sc` on `ld`/`st`: libcu++ lowers an `sc` access to the scope's `fence.sc` plus a
relaxed store or acquire load [CCCL `cuda_ptx_generated.h`], so an `sc` access is two PTX ops.

## No cluster scope
PTX `.cluster` has no HIP scope.

## Fence lowering
A CUDA fence is inline PTX because libcu++ collapses acquire, release and acq_rel alike into
`fence.acq_rel.<scope>` [CCCL `cuda_ptx_generated.h`]; a relaxed fence has no PTX form.

## Fence floors
`fence.{sc,acq_rel}` need PTX ISA 6.0 and sm_70, `fence.{acquire,release}` PTX ISA 8.6 (CUDA
12.7) and sm_90 [PtxISA "membar/fence"; CCCL `fence.h`]. The sm_90 floor is a hardware one:
`ptxas` assembles a one-sided fence for any sm_70+ target and the device faults at launch.

## HIP fences
A HIP fence is `__builtin_amdgcn_fence`, which carries both the order and the scope [D75917];
`__threadfence*` takes no order. System scope is the empty sync-scope string [AMDGPUUsage
"Memory Scopes"]: `hipcc` rejects `"system"`, and `"agent"` in its place silently NARROWS it.

## HIP compile
`__hip_atomic_*` and `__builtin_amdgcn_fence` are Clang builtins, absent from HIP over nvcc; a
clean compile establishes that the builtin, order and scope the emitter wrote are accepted for
the target ISA, not what `hipcc` lowers them to.

## Limits
The gpu-only host `main()` tallies nothing; the rendezvous and the stress layers live on the
heterogeneous path. No expected verdicts: the tool reports what it observed and derives none.
