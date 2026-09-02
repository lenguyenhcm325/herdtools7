# External sources cited by HetLitmus code

A `[Key]` in HetLitmus code, tests or docs resolves here. An entry holds the full citation
(commit or edition for a living document), the claims this project takes from the source — one
bullet each, locator first, then the fact taken — and any deviation still true of the code. An
entry lives while a site outside this file cites its key, a claim while a site rests on it;
both go with their last site. Locators follow `COMMENT-RULES.md` rule 9: fixed `§`/Fig./Table
locators for papers, section names for living documents.

## [Alglave15]
Jade Alglave, Mark Batty, Alastair F. Donaldson, Ganesh Gopalakrishnan, Jeroen Ketema, Daniel
Poetzl, Tyler Sorensen, John Wickerson. *GPU Concurrency: Weak Behaviours and Programming
Assumptions.* ASPLOS 2015, pp. 577–591. DOI 10.1145/2694344.2694391.
* §4.3.1 Tab. 6 (p. 584): on the NVIDIA GTX Titan inter-CTA `lb` and `sb` are 0 per 100k in
  every column without memory stress; on the AMD Radeon HD 7970 `lb` reaches 10959 per 100k
  unstressed. §4.3.1's hypothesis: heavy stress makes out-of-order transfer likelier.
* §4.3 (p. 585): "for correct GPU programming the possibility, not probability of weak
  behaviours is what matters".
* Fn. 7 (p. 577): "In fairness to the authors of [19], we were unable to observe weak
  behaviours using our method on the Nvidia GTX 280 chip they used."

## [Kirkham20]
Jake Kirkham, Tyler Sorensen, Esin Tureci, Margaret Martonosi. *Foundations of Empirical
Memory Consistency Testing.* Proc. ACM Program. Lang. 4, OOPSLA, Article 226 (2020). DOI
10.1145/3428294.
* §3.1: the stress parameter space — line size, target count, assignment strategy, the
  two-instruction access pattern, stride, pre-test stress.
* §3.4 Tab. 3: `MemoryStress` is an `{on, off}` parameter.
* §4.2 Tab. 6: SB has the lowest rate on Quadro and Vega and the highest on Iris.
* §6.2 Tab. 10: of six mutants, "only one mutant was exposed with no stress".
* §6.4: parameters for one chip may not be optimal on another, even from the same vendor.
* Deviation: realised in CUDA/HIP, not OpenCL; no configuration of the paper's is reused.

## [Goens23]
Andrés Goens, Soham Chakraborty, Susmit Sarkar, Sukarn Agarwal, Nicolai Oswald, Vijay
Nagarajan. *Compound Memory Models.* Proc. ACM Program. Lang. 7, PLDI, Article 153 (June
2023), 24 pages. DOI 10.1145/3591267.
* §4.6: "by the LOST principle, the behavior of a thread does not depend on the architecture
  of other threads" — a compound model is one whose threads have different architectures.
* §7 Tab. 1: the CPU and GPU litmus tests and their outcomes on a gem5 x86 + GCN3 simulation.
* §7.2, fn. 10: there releases and acquires "are implemented like fences", and each
  system-scoped fence "behaves like an SC fence".
* Deviation: only the framework of §§3–4 is used; the x86TSO/PTX instantiation of §§5–6 is one
  machine's and is carried to no target.

## [AMDGPUUsage]
LLVM Project. *User Guide for AMDGPU Backend.* Living document,
`https://llvm.org/docs/AMDGPUUsage.html` (`llvm/docs/AMDGPUUsage.rst`, llvm-project `main`).
* One "Memory Model GFX*" section per generation (GFX6–GFX9, GFX90A, GFX942, GFX10–GFX11,
  GFX12, GFX125x), each with its own code-sequence table.
* Table "AMDHSA Memory Model Code Sequences GFX942": at `system` scope `atomicrmw monotonic`
  is `global/flat_atomic sc1=1` and `load atomic monotonic` is `global/flat_load sc0=1 sc1=1`,
  neither with a writeback or invalidate; `load atomic acquire` adds `buffer_inv sc0=1 sc1=1`,
  `store atomic release` is preceded by `buffer_wbl2 sc0=1 sc1=1`.
* "Memory Scopes", table "AMDHSA LLVM Sync Scopes": the nameable scopes are `agent`,
  `cluster`, `workgroup`, `wavefront`, `singlethread` and their `-one-as` variants; the
  unnamed row reads "The default: `system`".
* Deviation: only `workgroup`, `agent` and the unnamed default are emitted.

## [D75917]
Saiyedul Islam. *Expose llvm fence instruction as clang intrinsic.* LLVM review D75917
(`reviews.llvm.org/D75917`), landed as llvm-project commit `06bdffb2bb45`, April 2020.
* Adds `BUILTIN(__builtin_amdgcn_fence, "vUicC*", "n")`: a C11 memory-order constant and an
  AMDHSA sync-scope string; its tests exercise `(__ATOMIC_SEQ_CST, "workgroup")`,
  `(__ATOMIC_ACQUIRE, "agent")` and `(__ATOMIC_SEQ_CST, "")`, the last a bare `fence seq_cst`.

## [HipAtomicHeader]
AMD ROCm. `hipamd/include/hip/amd_detail/amd_hip_atomic.h`, ROCm/clr repository, branch
`develop`; the same ladder ships in ROCm 7.2.4 (`/opt/rocm/include/hip/amd_detail/`).
* The scope ladder is `__HIP_MEMORY_SCOPE_SINGLETHREAD 1`, `_WAVEFRONT 2`, `_WORKGROUP 3`,
  `_AGENT 4`, `_SYSTEM 5`; a scoped load is spelled `__hip_atomic_load(ptr, order, scope)`.
* Deviation: `__hip_atomic_store` is a Clang builtin the header neither declares nor uses; its
  argument order (ptr, value, order, scope) is the builtin's.

## [CCCL]
NVIDIA. *CUDA C++ Core Libraries (libcu++)*, as shipped with CUDA Toolkit 12.9:
`cuda/std/__atomic/functions/cuda_ptx_generated.h` and
`cuda/__ptx/instructions/generated/fence.h`.
* `cuda_ptx_generated.h`: `__atomic_thread_fence_cuda` maps acquire, release and acq_rel alike
  to `fence.<scope>.acq_rel`, so `cuda::atomic_thread_fence` cannot express a one-sided fence.
* `cuda_ptx_generated.h`: every scoped access (`cuda::atomic_ref<T, cuda::thread_scope_*>`,
  `<cuda/atomic>`) is `asm volatile(... ::: "memory")`; a `seq_cst` load is `fence.sc` +
  acquire load, a `seq_cst` store `fence.sc` + relaxed store.
* `fence.h`: `fence.{sc,acq_rel}` is marked "PTX ISA 60, SM_70", `fence.{acquire,release}`
  "PTX ISA 86, SM_90".

## [IntelSDM]
Intel Corporation. *Intel 64 and IA-32 Architectures Software Developer's Manual, Volume 3A:
System Programming Guide, Part 1.* Order Number 253668-084US, June 2024.
* §9.2.3.9 "Loads and Stores Are Not Reordered with Locked Instructions": a locked instruction
  such as `lock xaddq` is a full barrier.

## [Bagchi26]
Soham Bagchi, Sanya Srivastava, Reese Levine, Tyler Sorensen, Ryan Stutsman, Vijay Nagarajan.
*Consistency and Coherence of the NVIDIA Grace-Hopper Superchip.* ISMM '26, ACM, pp. 66–79.
DOI 10.1145/3814942.3816134.
* Table 1 (p. 70), "Grace CPU and Hopper GPU Hardware": Grace L3 114 MB, Hopper L2 51 MB.
* §4.2: each test ran "millions of times with memory stressing [21] on both devices".
* §5.3: "results strongly suggests that an acquire operation on the Hopper GPU with a scope of
  gpu or higher triggers a self-invalidation of the local L1 cache".
* Deviation: §5.3 is an inference from latencies, and Hopper's; gfx942 is [AMDGPUUsage]'s.

## [Fusco24]
Luigi Fusco, Mikhail Khalilov, Marcin Chrapek, Giridhar Chukkapalli, Thomas Schulthess,
Torsten Hoefler. *Understanding Data Movement in Tightly Coupled Heterogeneous Systems: A Case
Study with the Grace Hopper Superchip.* arXiv:2408.11556v2 [cs.DC], 26 August 2024.
* §II: under ATS the GPU reaches system memory "serving loads and stores at the cache line
  level".
* Tab. II: system-allocated (`malloc`) memory is first-touch placed, ATS-translated and
  migratable (CUDA ≥ 12.4); `cudaMallocManaged` memory is first-touch placed and migrates.
* §III-C: a Grace and a Hopper noise kernel each stream an 8 GB buffer homed on the other
  unit's memory; under them writes to HBM fall to 17 % (Grace) and 65 % (Hopper) of peak.
* §III-E.1: the L2 "can cache data that is physically allocated on HBM, both local and peer".

## [Tee25]
Andrew Tee, Nicholas Curtis, Noah Wolfe, Daniel Wong. *The MALL is Open: Exploring Shared
Caches and Latency in AMD CDNA™ 3 GPUs.* SC Workshops '25, ACM, pp. 1110–1116. DOI
10.1145/3731599.3767487.
* Table 1 (p. 1111): MI300A scalar L1 16 KB, L2 4 MB per XCD, MALL 256 MB, HBM 128 GB; the
  MALL is the last-level cache, on the I/O die (Fig. 1).

## [CudaLitmus]
Reese Levine. *cuda-litmus*, `https://github.com/reeselevine/cuda-litmus`, read at commit
`d107bb5617ee86fea67a851b73565d62d4c2ecf0`, no licence file (citation conditions the reuse).
* `functions.cu:19` `do_stress`, `runner.cu:130` `setScratchLocations`, `runner.cu:106`
  `percentageCheck`, `litmus.cuh:336-346` `PRE_STRESS`/`MEM_STRESS`: the ported stress layer.
* `params/stress_params.txt`, the one committed configuration (`workgroupSize=128` among its
  values): the `HET_*` seeds, `HET_MEM_STRESS_PCT` excepted.
* `tune.sh:29-57` `random_config` draws every knob together — `workgroupSize` (`:39`)
  included, `scratchMemorySize` as `32 × stressLineSize × stressTargetLines` — and
  `runner.cu:261` launches at that width: the block width is a member of the tuned vector.
* `litmus.cuh:344` `MEM_STRESS()` is the `else` arm of the testing-workgroup guard
  (`kernels/mp.cu:45`): every thread of a non-testing workgroup stresses.
* Deviation: `litmus.cuh:346` passes `pre_stress_iterations` as the pattern, so under the
  committed configuration no branch matches and `memStressPattern` is never read; here the
  pattern is the pattern, and `HET_MEM_STRESS_PCT` seeds from [WebGPULitmus] instead.
* Deviation: `runner.cu:131-135` guards the region draw with a `usedRegions` set nothing
  inserts into; `het_set_scratch_locations` dedups for real, hence its exhaustion break.
* Deviation: the toggles are re-rolled on the host per relaunch (`runner.cu:160`, `:259`);
  here one launch loops, so `het_draw` draws them device-side, the mem-stress one per
  iteration grid-wide. `het_do_stress` adds a tally argument and one `atomicMax`.

## [Sorensen16]
Tyler Sorensen, Alastair F. Donaldson. *Exposing Errors Related to Weak Memory in GPU
Applications.* PLDI 2016, pp. 100–113. DOI 10.1145/2908080.2908114.
* §1: "Because the stressing threads and memory are disjoint from application threads and
  data, the set of possible behaviours a program can exhibit remains the same."
* §1: `cbe-dot` errs in 0 of 1000 runs on a Tesla K20 unstressed and in 102 of 1000 stressed.
* §3.2 critical patch size P, §3.3 access sequence σ, §3.4 spread m — `HET_STRESS_LINE_SIZE`,
  `HET_*_STRESS_PATTERN` / `HET_CPU_ENEMY_SEQ`, `HET_STRESS_TARGETS` / `HET_CPU_SPREAD`.
* §3.3: "all of the most effective sequences involve a combination of loads and stores"; for
  most chips the lowest-ranked σs consist exclusively of stores.
* Deviation: §3.3 tests sequences up to five instructions; `het_do_stress` and the CPU enemy
  implement the two-instruction case only.

## [MCMutants23]
Reese Levine, Tianhao Guo, Mingun Cho, Alan Baker, Raph Levien, David Neto, Andrew Quinn,
Tyler Sorensen. *MC Mutants: Evaluating and Improving Testing for Memory Consistency
Specifications.* ASPLOS 2023, Volume 2, pp. 473–488. DOI 10.1145/3575693.3575750.
* §1.1 (p. 474): "When testing, it is impossible to tell if an unobserved illegal execution is
  not allowed or if it is simply rare and was not exposed by the tests."

## [GPUHarbor23]
Reese Levine, Mingun Cho, Devon McKee, Andrew Quinn, Tyler Sorensen. *GPUHarbor: Testing GPU
Memory Consistency at Large (Experience Paper).* ISSTA 2023, pp. 779–791. DOI
10.1145/3597926.3598095.
* §3.4: stress configurations come from a seeded Park-Miller generator so that "the
  configurations run on different devices are the same for data analysis purposes".

## [Alglave11]
Jade Alglave, Luc Maranget, Susmit Sarkar, Peter Sewell. *Litmus: Running Tests against
Hardware.* TACAS 2011, pp. 41–44. DOI 10.1007/978-3-642-19835-9_5.
* §3: test repetition (n = max(1, a/t) instances on a cores), indirect mode ("the array cell
  is accessed by a shuffled array of pointers"), preload, synchronisation, affinity.
* §4: "we generally find such combinations of parameters remain good on the same testbed, even
  for different tests".
* Deviation: repetition is ported as disjoint-scratchpad enemy threads; whole-test copies do
  not compose with a persistent GPU kernel.

## [Melissaris20]
Themis Melissaris, Markos Markakis, Kelly Shaw, Margaret Martonosi. *PerpLE: Improving the
Speed and Effectiveness of Memory Consistency Testing.* MICRO 2020, pp. 329–341. DOI
10.1109/MICRO50266.2020.00037.
* Abstract, §I: perpetual litmus tests run "without per-iteration synchronization".
* §VIII: litmus7 "does not have the logging to see cross-iteration interleavings".

## [Schieffer24]
Gabin Schieffer, Ruimin Shi, Stefano Markidis, Andreas Herten, Jennifer Faj, Ivy Peng.
*Understanding Data Movement in AMD Multi-GPU Systems with Infinity Fabric.* SC-W '24, pp.
567–576. DOI 10.1109/SCW63240.2024.00079. Read as arXiv:2410.00801v1 [cs.DC].
* §II.C: on MI250X GPU-side caching is disabled for coherent memory, so every remote coherent
  access crosses the interconnect; "on more recent systems, such as AMD MI300A, the no-caching
  restriction can be lifted".
* Deviation: the measurements are MI250X's and the MI300A sentence an uncited aside;
  `het_noise_hip.inc` marks the step to "per-access traffic is not automatic" as an inference.

## [Wahlgren25]
Jacob Wahlgren, Gabin Schieffer, Ruimin Shi, Edgar A. Leon, Roger Pearce, Maya B. Gokhale, Ivy
Peng. *Dissecting CPU-GPU Unified Physical Memory on AMD MI300A APUs.* IISWC 2025, pp.
368–380. DOI 10.1109/IISWC66894.2025.00038. Read as arXiv:2508.12743v1 [cs.DC].
* §4.4 (Fig. 5): CPU and GPU threads incrementing a shared 1K-element array with system-scope
  atomics — "with 3328 GPU threads or more the relative CPU performance is only between
  11%–25%", GPU throughput falling only to 79 %.
* Deviation: the collapse is contention-dependent (the 1M-element array leaves the CPU at or
  above baseline) and the paper does not attribute it to CCD-to-XCD traffic;
  `het_noise_hip.inc` marks both steps as inferences.

## [Srivastava24]
Sanya Srivastava. *Testing Memory Models of Heterogeneous CPU-GPU Systems.* MSc thesis,
University of California, Santa Cruz, June 2024. `https://escholarship.org/uc/item/5hm7q1jv`.
* §4.1 (p. 69): the constant-read artefact — runs showing 0 % or 100 % weak behaviour "because
  the read nodes loaded the same values in all the iterations".
* §4.1 (p. 69): a per-iteration both-sided CPU–GPU spin barrier got "2- 3 iterations ahead"
  and then stuck for good — the bring-up probe of `00-environment-design.md` §5.
* p. 93: the relaunch-per-trial harness observed no weak behaviour with a `threadfence`
  between the GPU instructions; the perpetual-instance harness did, in MP and SB.
* Deviation: the stall was on two integrated consumer parts (Ryzen 7 5700G, i7-12700K) and the
  thesis reads it as CPU–GPU visibility failing, not as a property of per-iteration barriers;
  the rendezvous here sits around the tested group, never between two of its accesses.

## [APM]
Advanced Micro Devices, Inc. *AMD64 Architecture Programmer's Manual, Volume 2: System
Programming.* Publication No. 24593, Revision 3.45, July 2026.
* §7.2 "Multiprocessor Memory Access Ordering" (p. 190): the ordering rules hold for "normal
  cacheable accesses on naturally aligned boundaries to WB memory".
* §7.4.2 "Memory Barrier Interaction with Memory Types" (p. 200): "Memory types other than WB
  may allow weaker ordering in certain respects."

## [CudaGuide]
NVIDIA. *CUDA Programming Guide*, Release 13.3,
`https://docs.nvidia.com/cuda/cuda-programming-guide/`.
* "Atomicity" (appendix "CUDA C++ Memory Model"): system-scope atomicity needs
  `pageableMemoryAccess=1` on system-allocated memory, `concurrentManagedAccess=1` on managed,
  and on mapped memory `hostNativeAtomicSupported=1` or a naturally-aligned 1–16-byte access.
* "cudaMallocHost and cudaHostAlloc": "The pointers returned by these APIs can be directly
  used in kernel code to access the memory on the host".
* "Unified Memory Paradigms": `cudaDevAttrPageableMemoryAccessUsesHostPageTables` "Indicates
  the mechanism of CPU/GPU coherence: 1 is hardware, 0 is software".
* "Overview of Memory Allocators for Unified Memory": where "device memory is exposed as a
  NUMA domain to the system", `numa_alloc_on_node` may pin memory to the device node.
* "Coherency and Concurrency": without concurrent managed access "the GPU has exclusive access
  to all managed data and the CPU is not permitted to access it" while a kernel executes.
* "CUDA C++ Execution model": `Execution.Model.API.2` — a host spin on a device-set flag "may
  never be unblocked", the device thread being guaranteed to start only once a synchronization
  API is called; `.API.4` terminates because it "repeatedly calls a CUDA query API".
* Deviation: Release 12.x, the pinned toolchain's, is titled "CUDA C++ Programming Guide" and
  states the mapped-pointer rule as the unified-address-space exception in "Mapped Memory"
  (12.9 checked); whether it states the execution-model guarantee is a bring-up check
  (`00-environment-design.md` §5).

## [HipRuntimeApi]
AMD ROCm. `hip_runtime_api.h`, as shipped with ROCm 7.2.4
(`/opt/rocm/include/hip/hip_runtime_api.h`).
* `hipMemAdviseSetCoarseGrain`: "The default memory model is fine-grain. That allows coherent
  operations between host and device, while executing kernels."
* `hipMallocManaged`: without HMM it "behaves the same as hipMallocHost".
* `hipDeviceAttributeIntegrated` ("Device is integrated GPU"; `hipDeviceProp_t::integrated`,
  "APU vs dGPU"): the one runtime query separating MI300A from MI300X, both `gfx942`.

## [Iorga21]
Dan Iorga, Alastair F. Donaldson, Tyler Sorensen, John Wickerson. *The Semantics of Shared
Memory in Intel CPU/FPGA Systems.* Proc. ACM Program. Lang. 5, OOPSLA, Article 120 (October
2021), 28 pages. DOI 10.1145/3485497.
* §6 Tab. 3: the 583 disallowed outcomes are never observed in a million runs each, even under
  stress; hand-tuned stress exposes weak behaviour in 4 of 10 allowed tests.

## [Vigna15]
Sebastiano Vigna. `splitmix64.c`, 2015, `https://prng.di.unimi.it/splitmix64.c`
(byte-identical at `https://xoshiro.di.unimi.it/splitmix64.c`); public domain by its own
dedication.
* Verbatim: `z = (x += 0x9e3779b97f4a7c15); z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9; z = (z ^
  (z >> 27)) * 0x94d049bb133111eb; return z ^ (z >> 31);`; the increment being fixed, draw `k`
  from `x0` is the mixer of `x0 + k * 0x9e3779b97f4a7c15`.
* Provenance, as the file states it: "a fixed-increment version of Java 8's SplittableRandom
  generator" — Guy L. Steele Jr., Doug Lea, Christine H. Flood, *Fast Splittable Pseudorandom
  Number Generators*, OOPSLA 2014, DOI 10.1145/2714064.2660195.
* Deviation: evaluated at an index, never advanced, so no state is stored; the BigCrush claim
  concerns the output sequence and is not taken. A fixed increment makes every `(seed, who)`
  stream an offset into one cycle, not an independent stream.

## [WebGPULitmus]
Reese Levine. *webgpu-litmus*, `https://github.com/reeselevine/webgpu-litmus`, read at commit
`c7234af7cefd90f7206152b9255eee3e58ff989c`. Apache-2.0.
* `components/stressPanel.js:225`: the memory-stress percentage is "The percentage of
  iterations in which all non-testing threads repeatedly access the scratch memory to cause
  memory stress"; `components/litmus-setup.js:184` rolls it per iteration into one grid-wide
  flag.
* `components/stressPanel.js:185-197`: the "Stress" preset sets `memStressPct: 100` and
  `preStressPct: 100`, and no preset carries an intermediate percentage.
* Deviation: the draw is device-side and stateless (`het_draw(seed, HET_WHO_GRID, n)` per
  stress block, `n` from `_gpu_iter`); the source rolls on the host and copies a flag.
* Deviation: only the scratchpad stress blocks obey the percentage; noise blocks, CPU enemies
  and pre-stress run regardless, so an off-iteration is not quiet.

## [ArmA64ISA]
Arm Limited. *Arm A-profile A64 Instruction Set Architecture* (DDI 0602). Living document,
`https://developer.arm.com/documentation/ddi0602/`; read as Arm's machine-readable release
`ISA_A64_xml_A_profile-2022-12` (`ldapr.xml`, `stlr.xml`, `dmb.xml`).
* "LDAPR", Load-Acquire RCpc Register: the ordering of Load-AcquirePC — "There is no ordering
  requirement, separate from the requirements of a Load-AcquirePC or a Store-Release, created by
  having a Store-Release followed by a Load-AcquirePC instruction"; FEAT_LRCPC, Armv8.3.
* "STLR", Store-Release Register: "memory ordering semantics as described in Load-Acquire,
  Store-Release".
* "DMB", the `<option>` table: `SY` orders reads and writes before the barrier against reads
  and writes after; `ST` writes before against writes after; `LD` reads before against reads
  and writes after.
