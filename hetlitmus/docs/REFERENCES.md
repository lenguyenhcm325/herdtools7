# External sources cited by HetLitmus code

A `[Key]` in a HetLitmus comment resolves here. Each entry holds the full
citation, the claim(s) this project takes from the source — one bullet per
claim — and any deviation from it, one bullet per deviation. Append-only: keys
never change spelling once used, and an entry is edited only to correct it. An
entry is not widened to cover a new site: a site that takes a further claim from
a source cites `[Key + locator]` and states its own claim where it stands.

Locators follow the citation rule in `COMMENT-RULES.md` (rule 9): papers get a
fixed `§`/Fig./Table locator, living documents get the section *name*.

## [Alglave15]

Jade Alglave, Mark Batty, Alastair F. Donaldson, Ganesh Gopalakrishnan, Jeroen
Ketema, Daniel Poetzl, Tyler Sorensen, John Wickerson. *GPU Concurrency: Weak
Behaviours and Programming Assumptions.* ASPLOS 2015, pp. 577-591.
DOI 10.1145/2694344.2694391.

Claim(s) this project takes from it:
* §4.3 names the four incantations that provoke weak behaviour during testing —
  memory stress, general bank conflicts, thread synchronisation, thread
  randomisation — and the busy-wait deadlock guard inter-CTA synchronisation
  needs. The GPU stress layer implements them.
* §4.3.1 (Table 6) is the memory-stress figure the emitted "empty stress
  population" warning rests on: on the NVIDIA GTX Titan the inter-CTA `lb` and
  `sb` tests are observed 0 times per 100k executions in every column without the
  memory-stress incantation — §4.3.1 states it outright, "we did not observe sb
  and lb on Titan without this incantation" — while on the Radeon HD 7970 `lb`
  reaches 10959 per 100k with no incantation at all. The zero covers `lb` and
  `sb` and no other test: on the same chip and the same columns `mp` (inter-CTA)
  reaches 2921 and `coRR` (intra-CTA) 9774 unstressed. It is therefore a
  per-test, per-chip figure, scoped in every string that carries it to the NVIDIA
  part it was measured on and to those two tests.
* §4.3 also states that "for correct GPU programming the possibility, not
  probability of weak behaviours is what matters" — the one-sided reading the
  reporting stance takes.
* Footnote 7, p. 577 — "In fairness to the authors of [19], we were unable to
  observe weak behaviours using our method on the Nvidia GTX 280 chip they used."
  — is the precedent for reporting a non-observation as one. `het_verdict.h`
  cites it; the quotation itself lives in
  `hetlitmus/docs/positive-control.md` sec 6.

## [Kirkham20]

Jake Kirkham, Tyler Sorensen, Esin Tureci, Margaret Martonosi. *Foundations of
Empirical Memory Consistency Testing.* Proc. ACM Program. Lang. 4, OOPSLA,
Article 226 (November 2020), 29 pages. DOI 10.1145/3428294.

Claim(s) this project takes from it:
* §1.1 (Eqs 1-2, p. 226:3) derives the reproducibility probability
  `P_rep = 1 - k^N ≈ 1 - e^{-n}`, tied only to `n`, the number of times the
  relaxed behaviour was observed (`n=1` → 63.21 %, `n=2` → 86.47 %, `n=3` →
  95.02 %).
* §4.3 makes the stationarity assumption explicit and supplies the KS precheck
  the statistics layer runs — the first 20 % of the iterations against the last
  10 % — and reports its own outcome: "We found 4 combinations (out of 18) that
  are not stable across iterations" (Table 7, over three GPUs x six tests). That
  rejection rate is why the precheck is mandatory here rather than advisory.
  §5.1 supplies the restart-from-instability remedy.

Deviation(s):
* `1 - e^{-n}` is scored at the `(instance,run)` cell, never at a frame of the
  perpetual harness — the recovery scan validates `N^{T_L}` *overlapping*
  frames per `N` iterations, so a frame count drives the expression to 1
  vacuously.

## [Lustig19]

Daniel Lustig, Sameer Sahasrabuddhe, Olivier Giroux. *A Formal Analysis of the
NVIDIA PTX Memory Consistency Model.* ASPLOS 2019, pp. 257-270.
DOI 10.1145/3297858.3304043.

Claim(s) this project takes from it:
* The first formal axiomatic model of the official PTX memory consistency
  model, adapted from the public PTX documentation.
* `hetlitmus/cats/nvidia-ptx.cat` transcribes that model into herd7's cat
  language over `hetlitmus/bells/ptx.bell`.

Deviation(s):
* The transcription's fidelity record, including where it departs from the
  paper and where it extends it from the PTX ISA manual, is
  `hetlitmus/docs/nvidia-ptx-cat.md`, which is the authority on that question.

## [Goens23]

Andrés Goens, Soham Chakraborty, Susmit Sarkar, Sukarn Agarwal, Nicolai Oswald,
Vijay Nagarajan. *Compound Memory Models.* Proc. ACM Program. Lang. 7, PLDI,
Article 153 (June 2023), 24 pages. DOI 10.1145/3591267.

Claim(s) this project takes from it:
* §4.6 defines a compound model as a LOST-POP model whose threads have
  different architectures — "by the LOST principle, the behavior of a thread
  does not depend on the architecture of other threads".
* A test whose threads are all of one architecture therefore exercises no
  compound composition, which is what the CPU-only-cycle flag records.

Deviation(s):
* Only the general framework of §§3-4 is used. The x86TSO/PTX instantiation of
  §§5-6 is an instantiation for one machine and is not carried to any other
  target.

## [AMDGPUUsage]

LLVM Project. *User Guide for AMDGPU Backend*, section "Memory Scopes", table
"AMDHSA LLVM Sync Scopes". Living document,
`https://llvm.org/docs/AMDGPUUsage.html`.

Claim(s) this project takes from it:
* The sync scopes an AMDGPU fence may name are `agent`, `cluster`, `workgroup`,
  `wavefront`, `singlethread` and their `-one-as` variants. The row whose LLVM
  sync scope is *none* reads "The default: `system`", so system scope is the
  absence of a syncscope name — the empty string — which is what
  `HipLang.hip_fence_scope` returns for `sys`. Naming a scope there instead
  would narrow the fence.

Deviation(s):
* Only `workgroup`, `agent` and the unnamed default are ever emitted: the scope
  vocabulary of this project is `cta`/`gpu`/`sys`, so `cluster`, `wavefront`,
  `singlethread` and the `-one-as` variants have no annotation that reaches
  them.

## [D75917]

Sameer Sahasrabuddhe. *Expose llvm fence instruction as clang intrinsic.* LLVM
review D75917, April 2020 (`reviews.llvm.org/D75917`), which adds
`BUILTIN(__builtin_amdgcn_fence, "vUicC*", "n")`. Its builtin tests survive as
`clang/test/CodeGenCXX/builtin-amdgcn-fence.cpp` in llvm-project.

Claim(s) this project takes from it:
* `__builtin_amdgcn_fence(<order>, "<scope-string>")` takes a C11 memory-order
  constant as its first argument and an AMDHSA LLVM sync-scope string as its
  second, so one call carries both the order and the scope. The tests exercise
  `(__ATOMIC_SEQ_CST, "workgroup")`, `(__ATOMIC_ACQUIRE, "agent")` and
  `(__ATOMIC_SEQ_CST, "")`; the last lowers to a bare `fence seq_cst` carrying
  no syncscope.

## [HipAtomicHeader]

AMD ROCm. `hipamd/include/hip/amd_detail/amd_hip_atomic.h`, ROCm/clr
repository, branch `develop`.

Claim(s) this project takes from it:
* The HIP memory-scope ladder is `__HIP_MEMORY_SCOPE_SINGLETHREAD 1`,
  `_WAVEFRONT 2`, `_WORKGROUP 3`, `_AGENT 4`, `_SYSTEM 5`, and a scoped atomic
  load is spelled `__hip_atomic_load(ptr, memorder, scope)`.

Deviation(s):
* `__hip_atomic_store` is a Clang builtin and is not declared or used in this
  header; the header is taken as the authority for the scope ladder only, and
  the store's argument order (pointer, value, order, scope) comes from the
  builtin itself.

## [CCCL]

NVIDIA. *CUDA C++ Core Libraries (CCCL / libcu++)*, as shipped with CUDA
Toolkit 12.9: `cuda/std/__atomic/functions/cuda_ptx_generated.h` and
`cuda/__ptx/instructions/generated/fence.h`.

Claim(s) this project takes from it:
* `__atomic_thread_fence_cuda` dispatches `__ATOMIC_ACQUIRE`, `__ATOMIC_RELEASE`
  and `__ATOMIC_ACQ_REL` alike onto `__cuda_atomic_fence(_Sco{},
  __atomic_cuda_acq_rel{})`, i.e. `fence.<scope>.acq_rel`, so
  `cuda::atomic_thread_fence` cannot express a release-only or acquire-only
  fence. `litmus/CudaLang.ml` emits inline PTX rather than that call.
* The generated fence wrappers carry their availability: `fence.{sc,acq_rel}` at
  `.cta`/`.gpu`/`.sys` is marked "PTX ISA 60, SM_70", and
  `fence.{acquire,release}` "PTX ISA 86, SM_90".
* A scoped access is spelled `cuda::atomic_ref<T, cuda::thread_scope_*>` over
  `<cuda/atomic>`, with `cuda::memory_order_*` orders.

Deviation(s):
* The availability figures are read off these headers rather than off the PTX
  ISA manual they are generated from.

## [IntelSDM]

Intel Corporation. *Intel 64 and IA-32 Architectures Software Developer's
Manual, Volume 3A: System Programming Guide, Part 1.* Order Number
253668-082US, December 2023.

Claim(s) this project takes from it:
* §9.1.1 "Guaranteed Atomic Operations": on the Pentium and newer processors,
  "Reading or writing a quadword aligned on a 64-bit boundary" is always
  carried out atomically. Widening a tested 4-byte access to `movq` therefore
  keeps it one access.
* §9.2.2 "Memory Ordering in P6 and More Recent Processor Families" states the
  ordering principles over reads and writes ("Reads are not reordered with
  other reads", "Writes are not reordered with older reads", …) with no
  qualification by access width, so the widened access is ordered exactly as
  the 4-byte one was.

## [Bagchi26]

Soham Bagchi, Sanya Srivastava, Reese Levine, Tyler Sorensen, Ryan Stutsman,
Vijay Nagarajan. *Consistency and Coherence of the NVIDIA Grace-Hopper
Superchip.* ISMM '26, June 16, 2026, Boulder, CO, USA. ACM.

Claim(s) this project takes from it:
* Table 1 ("Grace CPU and Hopper GPU Hardware") gives the GH200 cache figures a
  noise buffer is sized against: Grace L3 114 MB and Hopper L2 51 MB.

## [Fusco24]

Luigi Fusco, Mikhail Khalilov, Marcin Chrapek, Giridhar Chukkapalli, Thomas
Schulthess, Torsten Hoefler. *Understanding Data Movement in Tightly Coupled
Heterogeneous Systems: A Case Study with the Grace Hopper Superchip.*
arXiv:2408.11556v2 [cs.DC], 26 August 2024.

Claim(s) this project takes from it:
* §III-E.1 (Pointer Chase): "Hopper L2 cache can cache data that is physically
  allocated on HBM, both local and peer." A buffer that fits in Hopper's L2 can
  therefore stay off the interconnect even when its pages are remote, which is
  what the GH200 last-level figure is stated against.

## [Tee25]

Andrew Tee, Nicholas Curtis, Noah Wolfe, Daniel Wong. *The MALL is Open:
Exploring Shared Caches and Latency in AMD CDNA™ 3 GPUs.* SC Workshops '25,
November 16–21, 2025, St Louis, MO, USA. ACM.

Claim(s) this project takes from it:
* Table 1 (p. 1111, "Cache and memory sizes for AMD Instinct™ MI300A, MI300X,
  and MI250X") gives MI300A scalar L1 16 KB, L2 4 MB per XCD, MALL 256 MB, HBM
  128 GB. The text at Fig. 1 places that MALL / AMD Infinity Cache on the I/O
  die (IOD) as the part's last-level cache, so 256 MB is the figure an MI300A
  noise buffer must exceed.

## [CudaLitmus]

Reese Levine. *cuda-litmus*, `https://github.com/reeselevine/cuda-litmus`, read
at commit `d107bb5617ee86fea67a851b73565d62d4c2ecf0`. The repository carries no
licence file.

Claim(s) this project takes from it:
* `functions.cu` supplies `do_stress` (line 19), `spin` (line 10), `permute_id`
  and `stripe_workgroup`; `litmus.cuh` supplies `KernelParams` and the
  `PRE_STRESS` / `MEM_STRESS` macros; `runner.cu` supplies `StressParams`,
  `setScratchLocations` (line 130) and `percentageCheck` (line 106).
  `litmus/het-runtime/het_stress.h` ports the stress layer from these, and
  citation is the condition of that reuse.
* `params/stress_params.txt` is the one committed tuned configuration
  (`scratchMemorySize=4608`, `stressLineSize=16`, `stressTargetLines=9`,
  `stressAssignmentStrategy=1`, `memStressPct=20`, `memStressIterations=445`,
  `memStressPattern=0`, `preStressPct=65`, `preStressIterations=57`,
  `preStressPattern=3`, `barrierPct=68`), which the `HET_*` knob defaults seed
  from.
* Its probabilistic toggles are re-rolled on the host and copied to the device
  before every relaunch (`setDynamicKernelParams`, `runner.cu:160`, and the
  `cudaMemcpy` at `runner.cu:259`), and the barrier toggle is one host-set
  boolean uniform across a launch (`litmus.cuh:340`).

Deviation(s):
* `MEM_STRESS()` (`litmus.cuh:346`) passes `pre_stress_iterations` in
  `do_stress`'s pattern argument, where `PRE_STRESS()` (`litmus.cuh:338`) passes
  `pre_stress_pattern`. The if-chain has no `else`, so under the committed
  configuration the mem-stress loop matches no branch and `memStressPattern` is
  never read. HetLitmus passes the pattern as the pattern, which is why that
  configuration is not a valid tuning seed here.
* `setScratchLocations` declares `std::set<int> usedRegions` (`runner.cu:131`)
  and guards its draw with it (`runner.cu:135`) but never inserts into it, so the
  dedup never fires and the realised spread can be smaller than
  `stressTargetLines`. `het_set_scratch_locations` dedups for real, and therefore
  needs an exhaustion break the dead guard did not.
* `het_do_stress` adds a tally parameter and one `atomicMax` after the loop; the
  stress traffic itself is unchanged.

## [Sorensen16]

Tyler Sorensen, Alastair F. Donaldson. *Exposing Errors Related to Weak Memory
in GPU Applications.* PLDI 2016, pp. 100-113. DOI 10.1145/2908080.2908114.

Claim(s) this project takes from it:
* §1 states the disjointness invariant the whole stress design rests on:
  "Because the stressing threads and memory are disjoint from application threads
  and data, the set of possible behaviours a program can exhibit remains the
  same." The GPU scratchpad, the CPU enemy scratchpad and the noise buffers are
  all disjoint from every test location for this reason.
* §3.2 fixes the stressing-thread count against occupancy: each micro-benchmark
  execution "employs a random number of stressing threads such that the total number
  of threads executing the kernel is 50% to 100% of the maximum threads that can
  run concurrently on the GPU."
* §3.2 defines the *critical patch size* P, §3.3 the *access sequence* sigma, and
  §3.4 the *spread* m ("stressing is applied to m distinct critical patch-sized
  regions"). `HET_STRESS_LINE_SIZE`, `HET_*_STRESS_PATTERN` and
  `HET_STRESS_TARGETS` are those three knobs.
* §3.3 also ranks the sequences by measured effectiveness, which is why both
  stress gates require a load AND a store: "We observe that all of the *most
  effective* sequences involve a combination of loads and stores", while "for
  most chips, the lowest ranked sigmas consist exclusively of stores" (Tab. 2
  gives the per-chip winners, Tab. 3 the Titan ranking). Store traffic alone is
  the *least* effective sequence measured, not the strongest stressor.

Deviation(s):
* §3.3 tests access sequences up to five instructions; both `het_do_stress` and
  the CPU enemy implement the two-instruction case only.

## [MCMutants23]

Reese Levine, Tianhao Guo, Mingun Cho, Alan Baker, Raph Levien, David Neto,
Andrew Quinn, Tyler Sorensen. *MC Mutants: Evaluating and Improving Testing for
Memory Consistency Specifications.* ASPLOS 2023, Volume 2, pp. 473-488.
DOI 10.1145/3575693.3575750.

Claim(s) this project takes from it:
* §1.1 (p. 474) states why a non-observation needs a positive control at all:
  "When testing, it is impossible to tell if an unobserved illegal execution is
  not allowed or if it is simply rare and was not exposed by the tests."
* §1.2 defines the mutant: a litmus test "mutated in such a way that the
  erroneous behavior that the test was checking is now allowed", killed by
  observing that behaviour. The Layer-A control mu(T) is such a mutant, which is
  also why a test already at the lattice floor has none.
* §4.1's Parallel Test Environment assigns test instances with a permutation
  `(v*P) mod N`, P co-prime to N, chosen to avoid patterns shown ineffective in
  prior work.

## [GPUHarbor23]

Reese Levine, Mingun Cho, Devon McKee, Andrew Quinn, Tyler Sorensen. *GPUHarbor:
Testing GPU Memory Consistency at Large (Experience Paper).* ISSTA 2023,
pp. 779-791. DOI 10.1145/3597926.3598095.

Claim(s) this project takes from it:
* §3.4 makes a stress configuration replayable by seeding it: "We ensure this by
  integrating a seedable Park-Miller random number generator [39] into both the
  web interface and the Android app and using the same seed when running all of
  our tuning experiments." `het_rng_*`, `het_cpu_rng_*` and `HET_SEED` follow
  that discipline.

## [Alglave11]

Jade Alglave, Luc Maranget, Susmit Sarkar, Peter Sewell. *Litmus: Running Tests
against Hardware.* TACAS 2011, pp. 41-44. DOI 10.1007/978-3-642-19835-9_5.

Claim(s) this project takes from it:
* §3 is the CPU incantation vocabulary `het_cpu_stress.h` ports: test repetition
  ("we run n = max(1, a/t) identical test instances concurrently on a machine
  with a cores"); indirect memory mode, the default, where "the array cell is
  accessed by a shuffled array of pointers, giving a much greater variability of
  outcomes"; preload mode, also the default; thread synchronisation; and
  affinity.
* §4 is why every stress numeric here is a seed rather than a tuning: "we
  generally find such combinations of parameters remain good on the same testbed,
  even for different tests."

Deviation(s):
* Test repetition is ported as disjoint-scratchpad enemy threads rather than as
  concurrent copies of the whole test, which do not compose with a persistent GPU
  kernel.

## [Melissaris20]

Themis Melissaris, Markos Markakis, Kelly Shaw, Margaret Martonosi. *PerpLE:
Improving the Speed and Effectiveness of Memory Consistency Testing.* MICRO
2020, pp. 329-341. DOI 10.1109/MICRO50266.2020.00037.

Claim(s) this project takes from it:
* §IV.A defines the *frame* -- "a tuple of TL iterations, one per
  load-performing thread, where iteration indices need not be the same" -- and
  states that "examining all frames therefore has time complexity N^TL for a run
  of N iterations". That is why the frame is not the replication unit here: the
  (instance,run) cell is.
* §IV.B's linear-complexity `COUNT_H` is the precedent for scoring a windowed
  heuristic alongside the exhaustive scan.

## [Schieffer24]

Gabin Schieffer, Ruimin Shi, Stefano Markidis, Andreas Herten, Jennifer Faj, Ivy
Peng. *Understanding Data Movement in AMD Multi-GPU Systems with Infinity
Fabric.* SC24 Workshops (SC-W '24), pp. 567-576.
DOI 10.1109/SCW63240.2024.00079. Read as arXiv:2410.00801v1 [cs.DC], 1 October
2024.

Claim(s) this project takes from it:
* §II.C: "On MI250X, to achieve this effect, GPU-side caching is disabled for
  coherent memory. Therefore, each access to data located in remote coherent
  memory generates traffic over the CPU-GPU interconnect. ... Note that on more
  recent systems, such as AMD MI300A, the no-caching restriction can be lifted
  thanks to the introduction of cache-coherent interconnects." The HIP noise
  render rests on the second half: per-access fabric traffic is not automatic on
  MI300A, so the lines have to be kept moving by contention.

Deviation(s):
* The paper's measurements are all MI250X; its MI300A sentence is an uncited
  aside stating that the restriction *can* be lifted, not that it is. The comment
  in `het_noise_hip.inc` marks the step from that to "per-access traffic is not
  automatic" as an inference.
* The paper says "coherent" throughout, never "fine-grained"; the HIP payload's
  "fine-grained" comes from [HipRuntimeApi], not from here.

## [Wahlgren25]

Jacob Wahlgren, Gabin Schieffer, Ruimin Shi, Edgar A. Leon, Roger Pearce, Maya
B. Gokhale, Ivy Peng. *Dissecting CPU-GPU Unified Physical Memory on AMD MI300A
APUs.* IISWC 2025, pp. 368-380. DOI 10.1109/IISWC66894.2025.00038. Read as
arXiv:2508.12743v1 [cs.DC], 18 August 2025.

Claim(s) this project takes from it:
* §4.4 (Fig. 5), on a four-MI300A testbed: with CPU and GPU threads incrementing
  a shared 1K-element array with system-scope atomics at once, "the CPU
  performance is at best within 13% of the baseline, but with 3328 GPU threads or
  more the relative CPU performance is only between 11%-25%", while GPU
  throughput falls only to 79%. Cross-chiplet coherence contention on one shared
  pool is therefore measurable on this part, which is what the HIP noise pair
  drives.

Deviation(s):
* The collapse is contention-dependent, not a property of co-running as such: on
  the lower-contention 1M-element array the same experiment leaves the CPU at or
  slightly above baseline (up to 1.14x). Any use of this figure must carry the
  contention level.
* The paper does not attribute the collapse to CCD-to-XCD traffic specifically;
  §2.2's asymmetry (GPU atomics at the shared L2, CPU atomics by taking exclusive
  ownership in L1) is suggestive, and the causal step is not the paper's.

## [Srivastava24]

Sanya Srivastava. *Testing Memory Models of Heterogeneous CPU-GPU Systems.* MSc
thesis, University of California, Santa Cruz, June 2024.
`https://escholarship.org/uc/item/5hm7q1jv`.

Claim(s) this project takes from it:
* §4.1 records the constant-read artefact the decode guard exists for: "In most
  of the runs, we observed 0 weak behaviors, and in some rare runs, we observed
  100% weak behaviors or weak behaviors in all 100,000 iterations. We found that
  this was happening because the read nodes loaded the same values in all the
  iterations." Both poles are there -- a reader pinned to the initial value 0
  gives a spurious 0%, one pinned to a value satisfying the predicate gives a
  spurious 100%.
* §4.1 also reports a per-iteration, both-sided CPU-GPU spin barrier stalling for
  good: "we could get up to 2- 3 iterations ahead in some runs on both devices,
  but the loop was getting stuck after that, and the CPU could not observe the
  increment made by the GPU."

Deviation(s):
* The stall was observed on two integrated parts (an AMD Ryzen 7 5700G and an
  Intel i7-12700K with their integrated GPUs) and the thesis reads it as
  CPU-GPU shared-memory visibility failing, not as a property of per-trial
  barriers. It says nothing about a barrier masking the order under test; that
  reason for keeping the cross-device rendezvous outside the perpetual loop is
  this project's own.

## [APM]

Advanced Micro Devices, Inc. *AMD64 Architecture Programmer's Manual, Volume 2:
System Programming.* Publication No. 24593, Revision 3.45, July 2026. Chapter 7,
"Memory System", pp. 185-246.

Claim(s) this project takes from it:
* §7.2 "Multiprocessor Memory Access Ordering" scopes the ordering rules: "certain
  rules are followed with regard to normal cacheable accesses on naturally aligned
  boundaries to WB memory."
* §7.4.2 "Memory Barrier Interaction with Memory Types": "Memory types other than
  WB may allow weaker ordering in certain respects."
* Table 7-2 "Memory Access by Memory Type" (p. 199) has every reordering row at
  "no" for the UC/CD column, and "yes" for WC in the Write/Out-of-Order row where
  WP, WT and WB are "no". A CPU-only sighting on the shared allocation therefore
  rules the uncacheable mapping out.

Deviation(s):
* Table 7-2 is a per-type permission matrix, not the ordering matrix: the
  first-op-by-second-op rules live in Table 7-4 "Memory Access Ordering Rules"
  (p. 202). In particular load-load reordering is not distinguished by Table 7-2
  (its Read/Out-of-Order row is "yes" for WC, WP, WT and WB alike); Table 7-4
  rule b is where a later WC/WC+ load may pass an earlier load.
* "UC reorders nothing" is one-sided: a UC access never passes an earlier access
  (Table 7-4 rule f), but a later non-UC access may pass an earlier
  non-conflicting UC one (§7.4, Uncacheable bullet; Table 7-4 rule i).

## [CudaGuide]

NVIDIA Corporation. *CUDA Programming Guide*, Release 13.3,
`https://docs.nvidia.com/cuda/cuda-programming-guide/index.html`. Living
document; section names are the locators.

Claim(s) this project takes from it:
* Section "Atomicity" lists the conditions under which an operation is atomic at
  system scope: it affects system allocated memory and `pageableMemoryAccess` is
  1, or managed memory and `concurrentManagedAccess` is 1, or mapped memory and
  `hostNativeAtomicSupported` is 1, or it is a naturally-aligned load or store of
  1, 2, 4, 8 or 16 bytes on mapped memory. `_het_alloc_mode`'s three fatal guards
  are exactly those conditions.
* Section "cudaMallocHost and cudaHostAlloc": "The pointers returned by these
  APIs can be directly used in kernel code to access the memory on the host", so
  the pinned mode needs no `cudaHostGetDevicePointer` and no second pointer.
* Section "Unified Memory Paradigms" gives
  `cudaDevAttrPageableMemoryAccessUsesHostPageTables` its meaning: "Indicates the
  mechanism of CPU/GPU coherence: 1 is hardware, 0 is software." The allocator
  banner prints it so a hardware-coherent run and a software-coherent one are not
  read as the same experiment.
* Section "Coherency and Concurrency" is why `concurrentManagedAccess` is fatal
  rather than advisory: without it "the GPU has exclusive access to all managed
  data and the CPU is not permitted to access it, while any kernel operation is
  executing", and a concurrent CPU access is a segmentation fault.

Deviation(s):
* Release 12.x titles this document "CUDA C++ Programming Guide" and states the
  mapped-pointer rule conditionally, as the unified-addressing exception in
  section "Mapped Memory"; 13.3 states it unconditionally for `cudaMallocHost`
  and `cudaHostAlloc`. The payload relies only on the part both editions agree
  on.
* The 16-byte case of the naturally-aligned allowance carries a footnote that it
  needs platform support which no CUDA API can query when
  `hostNativeAtomicSupported` is 0. Nothing here relies on a 16-byte access.

## [HipRuntimeApi]

AMD ROCm. `hip_runtime_api.h`, as shipped with ROCm 7.2.4
(`/opt/rocm/include/hip/hip_runtime_api.h`).

Claim(s) this project takes from it:
* `hipMemAdviseSetCoarseGrain` documents the default: "The default memory model
  is fine-grain. That allows coherent operations between host and device, while
  executing kernels. The coarse-grain can be used for data that only needs to be
  coherent at dispatch boundaries for better performance." The HIP shared
  allocator relies on that default and never advises coarse grain.
* `hipMallocManaged` degrades silently: "If HMM is not supported, the function
  behaves the same as hipMallocHost", and "It is recommend to do the capability
  check before call this API". That is why a zero
  `hipDeviceAttributeManagedMemory` is fatal here rather than a warning.
* `hipDeviceAttributeIntegrated` is "Device is integrated GPU", mirrored by
  `hipDeviceProp_t::integrated`, "APU vs dGPU". It is the only runtime query that
  separates MI300A from MI300X, which both report `gfx942`.

## [LLVMSched]

LLVM Project. *LLVM source*, `github.com/llvm/llvm-project`, branch `main` — the
machine-instruction scheduler's memory-dependence construction and the AMDGPU
override of it. Locators are the function names, which outlive the line numbers
recorded beside them:

* `MachineMemOperand::isUnordered` — `llvm/include/llvm/CodeGen/MachineMemOperand.h:328-332`
* `MachineInstr::hasOrderedMemoryRef` — `llvm/lib/CodeGen/MachineInstr.cpp:1595-1612`
* `TargetInstrInfo::isGlobalMemoryObject` — `llvm/lib/CodeGen/TargetInstrInfo.cpp:2232-2235`
* `ScheduleDAGInstrs::buildSchedGraph` — `llvm/lib/CodeGen/ScheduleDAGInstrs.cpp:876-921`
* `SIInstrInfo::isGlobalMemoryObject` — `llvm/lib/Target/AMDGPU/SIInstrInfo.cpp:11708-11713`

Claim(s) this project takes from it:
* The machine scheduler does not reorder two atomic accesses against each other.
  A memory operand whose success ordering is neither `NotAtomic` nor `Unordered`
  is not unordered, so the instruction carrying it has an ordered memory
  reference, so it is a global memory object; `buildSchedGraph` then makes such
  an instruction the barrier chain and gives every later memory instruction a
  dependency edge to it. On AMDGPU the hook is overridden only to exempt IGLP
  pseudo-instructions, which a litmus kernel never carries.

Deviation(s):
* This bounds the machine scheduler alone. Nothing here says whether a mid-level
  LLVM IR pass may reorder two model operations before instruction selection,
  which is why the ISA read-back gate states that half as unverified rather than
  excluded.
