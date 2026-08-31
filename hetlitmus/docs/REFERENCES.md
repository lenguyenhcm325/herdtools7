# External sources cited by HetLitmus code

A `[Key]` in a HetLitmus comment resolves here. Each entry holds the full
citation, the claim(s) this project takes from the source — one bullet per
claim — and any deviation from it, one bullet per deviation. Append-only: a
key, once used, is never respelled or removed, and a claim, once taken, is never
removed — only corrected or withdrawn (below). An entry is not widened to cover
a new site: a site that takes a further claim from a source cites
`[Key + locator]` and states its own claim where it stands.

Locators follow the citation rule in `COMMENT-RULES.md` (rule 9): papers get a
fixed `§`/Fig./Table locator, living documents get the section *name*.

Withdrawal. When the code stops resting on a claim — the site it grounded is
deleted, or the claim itself turns out not to describe what the code does — the
claim moves to a `Withdrawn claim(s):` block in its own entry, restated with the
reason. It is never silently deleted: an archived transcript or a thesis draft
may still quote it, and a reader who goes looking for it deserves to find what
happened to it rather than a gap.

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
  — is the precedent for reporting a non-observation as one; `harness-reporting.md`
  §4 rests on it, and the quotation lives here.

## [Kirkham20]

Jake Kirkham, Tyler Sorensen, Esin Tureci, Margaret Martonosi. *Foundations of
Empirical Memory Consistency Testing.* Proc. ACM Program. Lang. 4, OOPSLA,
Article 226 (November 2020), 29 pages. DOI 10.1145/3428294.

Claim(s) this project takes from it:
* §3.1 defines the memory-stress parameter space `litmus/het-runtime/het_stress.h`
  is built on: `StressLineSize`, `TargetNumber`, `StressAssignment`, the
  two-instruction `AccessPattern`, `XYStride` and `PretestMemoryStress`.
* §6.4 reports, of the stress configuration tuned on one Nvidia GPU and run on
  another, that "parameters for one chip may not be optimal on another chip,
  even from the same vendor". Every stress numeric in `het_stress.h` and
  `het_cpu_stress.h` is therefore a seed to be re-tuned on the target rather
  than a tuning.
* §4.2 Table 6 gives the minimum and maximum observed relaxed-behaviour rates
  per chip: SB is the lowest-rate test on two of the three GPUs and the highest
  on the third, which is why `het_verdict.h`'s stopping rule treats shape
  difficulty as a property of the part and not of the shape.
* §6.2 (Table 10) evaluates stress configurations by mutation testing over six
  memory-order weakenings of the vendor OpenCL implementation, and finds that
  only one of the six was exposed with no stress at all. `het_verdict.h`'s
  unstressed caveat rests on that count.

Deviation(s):
* The parameter space is realised in CUDA/HIP rather than in the paper's
  OpenCL, and no configuration of the paper's is carried over: §3.1 supplies
  the axes, and every numeric here is a seed under §6.4.

## [Lustig19]

Daniel Lustig, Sameer Sahasrabuddhe, Olivier Giroux. *A Formal Analysis of the
NVIDIA PTX Memory Consistency Model.* ASPLOS 2019, pp. 257-270.
DOI 10.1145/3297858.3304043.

Withdrawn claim(s):
* That the paper gives the first formal axiomatic model of the official PTX
  memory consistency model, adapted from the public PTX documentation, and that
  `hetlitmus/cats/nvidia-ptx.cat` transcribes that model into herd7's cat
  language over `hetlitmus/bells/ptx.bell`. Withdrawn because the transcription
  is deleted: it decided no test, no run path consulted it, and nothing
  executed, parsed or declared it as a dependency, so no site in this tree
  rests on the paper any more. The paper's model is untouched by that; this
  project simply transcribes nothing from it.
* The deviation that travelled with the transcription -- that its fidelity
  record, including where it departs from the paper and where it extends it
  from the PTX ISA manual, is `hetlitmus/docs/nvidia-ptx-cat.md`, the authority
  on that question -- is withdrawn with its subject: that record is deleted
  too, so there is no departure and no extension left to disclose. The two
  keys it defined locally for the extension, `[PTXISA]` and `[PTXISA60]`, were
  never registry keys and end with it. `hetlitmus/bells/ptx.bell` survives, but
  on the sources named in its own header, never on this one.

## [Goens23]

Andrés Goens, Soham Chakraborty, Susmit Sarkar, Sukarn Agarwal, Nicolai Oswald,
Vijay Nagarajan. *Compound Memory Models.* Proc. ACM Program. Lang. 7, PLDI,
Article 153 (June 2023), 24 pages. DOI 10.1145/3591267.

Claim(s) this project takes from it:
* §4.6 defines a compound model as a LOST-POP model whose threads have
  different architectures — "by the LOST principle, the behavior of a thread
  does not depend on the architecture of other threads".
* A test whose threads are all of one architecture therefore exercises no
  compound composition, which is why a het test names at least one GPU proc and
  is refused otherwise.

Deviation(s):
* Only the general framework of §§3-4 is used. The x86TSO/PTX instantiation of
  §§5-6 is an instantiation for one machine and is not carried to any other
  target.

## [AMDGPUUsage]

LLVM Project. *User Guide for AMDGPU Backend*. Living document,
`https://llvm.org/docs/AMDGPUUsage.html`; each claim below names its own section
and table, which is the locator a living document gets.

Claim(s) this project takes from it:
* Section "Memory Model GFX942", table **"AMDHSA Memory Model Code Sequences
  GFX942"**, gives the sequences the rendezvous is read back against on gfx942:
  an `atomicrmw monotonic` at `system` scope on global/generic memory is
  `buffer/global/flat_atomic` with `sc1=1`, and a `load atomic monotonic` at
  `system` scope is `buffer/global/flat_load` with `sc0=1 sc1=1`. Neither carries
  a writeback or an invalidate, which is what the fence-free lowering of the HIP
  arm of `litmus/het-runtime/het_rdv.h` rests on: a `wbl2` or a `buffer_inv`
  beside either would be a strengthened rendezvous. The lowering
  is not read back from `hipcc` (`amd-faithfulness.md`, "Scope and limits"), so
  this is a design ground, cited from `00-environment-design.md` sec 3.3.
* Section "Memory Scopes", table "AMDHSA LLVM Sync Scopes": the sync scopes an
  AMDGPU fence may name are `agent`, `cluster`, `workgroup`,
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

Withdrawn claim(s):
* §9.1.1 "Guaranteed Atomic Operations" ("Reading or writing a quadword aligned
  on a 64-bit boundary" is always carried out atomically) was cited to license
  widening a tested 4-byte x86 access to `movq`, and §9.2.2 "Memory Ordering in
  P6 and More Recent Processor Families" was cited to license reading the widened
  access as ordered exactly as the 4-byte one. Both are withdrawn because nothing
  widens anything any more: the CPU body is litmus7's own lowering of the column
  and the emitted store is `movl $1,%[x]` on an `int` slot. The widening existed
  only to carry a 64-bit store tag, and the tag went with the slot layout. The
  quoted sentences remain true of the architecture; this project simply no longer
  rests on them.

## [Bagchi26]

Soham Bagchi, Sanya Srivastava, Reese Levine, Tyler Sorensen, Ryan Stutsman,
Vijay Nagarajan. *Consistency and Coherence of the NVIDIA Grace-Hopper
Superchip.* ISMM '26, June 16, 2026, Boulder, CO, USA. ACM.

Claim(s) this project takes from it:
* Table 1 ("Grace CPU and Hopper GPU Hardware") gives the GH200 cache figures a
  noise buffer is sized against: Grace L3 114 MB and Hopper L2 51 MB.
* §5.3 is why the cross-device rendezvous polls RELAXED and carries no fence:
  "results strongly suggests that an acquire operation on the Hopper GPU with a
  scope of gpu or higher triggers a self-invalidation of the local L1 cache."
  An acquire poll inside the loop would therefore throw away the L1 state the
  tested iteration is about to race on, while every ordering annotation under
  test still matched. Cited at `litmus/het-runtime/het_rdv.h`.

Deviation(s):
* §5.3's sentence is an inference the authors draw from a visibility experiment
  and its read latencies ("strongly suggests"), not a vendor statement and not a
  direct observation of an invalidation. It is also Hopper's: the parallel
  gfx942 statement comes from [AMDGPUUsage] instead, and nothing here carries one
  part's mechanism onto the other.

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
  (`workgroupSize=128`, `scratchMemorySize=4608`, `stressLineSize=16`,
  `stressTargetLines=9`, `stressAssignmentStrategy=1`, `memStressPct=20`,
  `memStressIterations=445`, `memStressPattern=0`, `preStressPct=65`,
  `preStressIterations=57`, `preStressPattern=3`, `barrierPct=68`), which the
  `HET_*` knob defaults seed from — `HET_MEM_STRESS_PCT` excepted, see
  Deviation(s). `tune.sh` draws every one of them together
  in one `random_config` call (`tune.sh:29-57`, `workgroupSize` at `:39`,
  rounded even out of 1..256), and `runner.cu:261` launches
  `litmus_test<<<numWorkgroups, workgroupSize>>>`, so the block width is tuned
  jointly with the knobs beside it; `HET_BLOCK_DIM` defaults to it
  (`hetlitmus/docs/00-environment-design.md` §3.3).
* `MEM_STRESS()` (`litmus.cuh:344`) is the `else` arm of the kernel's
  testing-workgroup guard, written at kernel scope (e.g. `kernels/mp.cu`), so
  *every thread* of a non-testing workgroup calls `do_stress` on
  `scratch_locations[blockIdx.x]`: the stress volume a grid carries is per
  thread, not per workgroup.
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
  configuration is not a valid tuning seed here. `HET_MEM_STRESS_PCT` therefore
  defaults to [WebGPULitmus]'s all-stress 100.
* `setScratchLocations` declares `std::set<int> usedRegions` (`runner.cu:131`)
  and guards its draw with it (`runner.cu:135`) but never inserts into it, so the
  dedup never fires and the realised spread can be smaller than
  `stressTargetLines`. `het_set_scratch_locations` dedups for real, and therefore
  needs an exhaustion break the dead guard did not.
* `het_do_stress` adds a tally parameter and one `atomicMax` after the loop; the
  stress traffic itself is unchanged.
* The toggles are drawn device-side here rather than re-rolled on the host
  between relaunches: this kernel is launched once and loops inside, so there is
  no relaunch to re-roll at. The pre-stress toggle is drawn by the test lane it
  belongs to; the mem-stress toggle is one grid-wide draw indexed by the
  iteration, which lane 0 of each stress block reads off the device clock and
  broadcasts to its block ([WebGPULitmus] is the origin of that reading).

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
* §3.3 also ranks the sequences by measured effectiveness: "We observe that
  all of the *most effective* sequences involve a combination of loads and
  stores", while "for most chips, the lowest ranked sigmas consist exclusively
  of stores" (Tab. 2 gives the per-chip winners, Tab. 3 the Titan ranking).
  Store traffic alone is the *least* effective sequence measured, not the
  strongest stressor.

Deviation(s):
* §3.3 tests access sequences up to five instructions; both `het_do_stress` and
  the CPU enemy implement the two-instruction case only.

## [MCMutants23]

Reese Levine, Tianhao Guo, Mingun Cho, Alan Baker, Raph Levien, David Neto,
Andrew Quinn, Tyler Sorensen. *MC Mutants: Evaluating and Improving Testing for
Memory Consistency Specifications.* ASPLOS 2023, Volume 2, pp. 473-488.
DOI 10.1145/3575693.3575750.

Claim(s) this project takes from it:
* §1.1 (p. 474) states why a non-observation is not self-interpreting:
  "When testing, it is impossible to tell if an unobserved illegal execution is
  not allowed or if it is simply rare and was not exposed by the tests."
* §4.1's Parallel Test Environment assigns test instances with a permutation
  `(v*P) mod N`, P co-prime to N, chosen to avoid patterns shown ineffective in
  prior work.

## [GPUHarbor23]

Reese Levine, Mingun Cho, Devon McKee, Andrew Quinn, Tyler Sorensen. *GPUHarbor:
Testing GPU Memory Consistency at Large (Experience Paper).* ISSTA 2023,
pp. 779-791. DOI 10.1145/3597926.3598095.

Claim(s) this project takes from it:
* §3.4 uses one seed to make the stress configurations identical across the
  devices a campaign compares: "While system stress configurations are generated
  randomly, we would like to ensure that the configurations run on different
  devices are the same for data analysis purposes. ... We ensure this by
  integrating a seedable Park-Miller random number generator [39] into both the
  web interface and the Android app and using the same seed when running all of
  our tuning experiments." That comparability is what `HET_SEED` is for here:
  `het_draw` makes the whole stress schedule a function of the seed, so two runs
  and two devices can be read against one configuration. It is bought by setting
  the variable, a base nothing pins being drawn from entropy per run.

Withdrawn claim(s):
* That §3.4 "makes a stress configuration replayable by seeding it", which
  `het_rng_*`, `het_cpu_rng_*` and `HET_SEED` were said to follow. Withdrawn as
  an over-read on both sides. Of the source: §3.4 seeds the *tuning*
  configurations so that the same ones run on every device, and says nothing
  about replaying a run at all. Of the code: the seed fixes the stress schedule
  alone, while the timing, the thermal state and the relative phase a het
  outcome depends on are unseeded, so no run replays. The two functions named
  are also gone; `het_draw` replaces them.

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
* §VIII states what a persistent loop costs a harness that does not pay for it:
  "Litmus7's different synchronization modes may allow for some of the same
  orderings, but that tool does not have the logging to see cross-iteration
  interleavings." The per-iteration slot layout is this project's answer to that
  -- iteration n's outcome is addressed rather than reconstructed -- and it is
  the ground the build strategy states for not driving the harness from
  `Skel.ml` (`00-environment-design.md` §3.1).

Withdrawn claim(s):
* §IV.A's *frame* -- "a tuple of TL iterations, one per load-performing thread,
  where iteration indices need not be the same", with "time complexity N^TL for
  a run of N iterations" -- was the ground for scoring per run rather than
  per frame. Withdrawn because the harness no longer examines frames at all:
  it scores at most one outcome per iteration, read out of that iteration's
  own slot. The run is still the replication unit,
  on a different ground (within-run correlation, `harness-reporting.md` §5).
* §IV.B's linear-complexity `COUNT_H` was the precedent for scoring a windowed
  heuristic beside an exhaustive scan. Withdrawn with both: there is one
  detector now, an exact per-iteration comparison, and no window.

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
* p.93 is the tail-sensitivity result the persistent loop is kept for: under the
  relaunch-per-trial ("single instance") harness "we were not able to observe any
  weak behaviors with a threadfence between instructions on the GPU thread.
  However, with the perpetual instance approach, we are able to observe weak
  memory behavior with a threadfence in the Message Passing and Store Buffer
  litmus tests." Throughput therefore decides which rows are answerable at all,
  which is one of the three grounds `00-environment-design.md` §3.1 gives for not
  driving the harness from litmus7's per-cell `Skel.ml`.
* §4.1 also reports a per-iteration, both-sided CPU-GPU spin barrier stalling for
  good: "we could get up to 2- 3 iterations ahead in some runs on both devices,
  but the loop was getting stuck after that, and the CPU could not observe the
  increment made by the GPU." This harness now runs exactly such a barrier every
  iteration, so the stall is the failure mode its cap and its discard rule exist
  to survive, and confirming it does not occur is a bring-up probe
  (`00-environment-design.md` §6).

Deviation(s):
* The stall was observed on two integrated parts (an AMD Ryzen 7 5700G and an
  Intel i7-12700K with their integrated GPUs) and the thesis reads it as
  CPU-GPU shared-memory visibility failing, not as a property of per-iteration
  barriers. Nothing in it says a per-iteration rendezvous is anti-correct, and
  this project does not claim it either: the rendezvous here sits AROUND the
  tested group and never between two of its accesses, which is a different
  construct from a barrier placed between them.

Withdrawn claim(s):
* That the §4.1 stall is a reason to keep the cross-device rendezvous *outside*
  the loop. Withdrawn: it was this project's own reading, the thesis attributes
  the stall to broken integrated-GPU coherence on consumer parts rather than to
  the barrier, and a rendezvous around the tested group adds no ordering to it.
  The masking argument that travelled with it -- that a barrier between the
  tested accesses orders them -- still holds, and is why the rendezvous is placed
  where it is rather than why it is absent.

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

Withdrawn claim(s):
* That Table 7-2 "Memory Access by Memory Type" (p. 199), whose reordering rows
  are all "no" for the UC/CD column and "yes" for WC in the Write/Out-of-Order
  row where WP, WT and WB are "no", lets a CPU-only sighting on the shared
  allocation rule the uncacheable mapping out. Withdrawn: the site was the
  all-CPU het route, and a het test now names at least one GPU proc, so no
  all-CPU cycle runs on the shared allocation and nothing probes its memory
  type. The two deviations that qualified it go with it -- that Table 7-2 is a
  per-type permission matrix rather than the first-op-by-second-op rules of
  Table 7-4 "Memory Access Ordering Rules" (p. 202), and that "UC reorders
  nothing" is one-sided, since a later non-UC access may pass an earlier
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
* Section "CUDA C++ Execution model" is why the host half of the rendezvous
  calls into the runtime while it waits. Its example `Execution.Model.API.2`
  carries the outcome "eventually, no thread makes progress" for a host thread
  spinning on a flag a device thread sets, with the rationale that "CUDA only
  guarantees that `producer` device thread eventually starts if the
  synchronization API is called. Therefore, the host thread may never be
  unblocked from the flag spin-loop"; `Execution.Model.API.4` terminates because
  it "repeatedly calls a CUDA query API in within the flag spin-loop, which
  guarantees that the device thread eventually makes progress". The CUDA render
  therefore calls `cudaStreamQuery(0)` once per poll on iteration 0, where the
  grid may not yet be resident (`het_rdv.h`, `litmus/hetDialect.ml`); past that
  it does not, because a vendor runtime call inside the tested loop is traffic
  the window does not need. The HIP render passes no such call.

Deviation(s):
* Release 12.x titles this document "CUDA C++ Programming Guide" and states the
  mapped-pointer rule conditionally, as the unified-addressing exception in
  section "Mapped Memory"; 13.3 states it unconditionally for `cudaMallocHost`
  and `cudaHostAlloc`. The payload relies only on the part both editions agree
  on.
* The 16-byte case of the naturally-aligned allowance carries a footnote that it
  needs platform support which no CUDA API can query when
  `hostNativeAtomicSupported` is 0. Nothing here relies on a 16-byte access.
* The execution-model section above was read in the **Release 13.3** edition
  cited at the head of this entry. The toolchain this project pins is CUDA 12.x,
  and whether the 12.x edition states the same guarantee in the same words is a
  bring-up check rather than something verified here
  (`00-environment-design.md` §6).

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

## [Iorga21]

Dan Iorga, Alastair F. Donaldson, Tyler Sorensen, John Wickerson. *The Semantics
of Shared Memory in Intel CPU/FPGA Systems.* Proc. ACM Program. Lang. 5, OOPSLA,
Article 120 (October 2021), 28 pages. DOI 10.1145/3485497.

Claim(s) this project takes from it:
* §6 (Table 3) is the two-sided reading a heterogeneous campaign is assembled
  into. Run a million times each, none of the 583 model-disallowed outcomes is
  observed — "we did not observe any of the disallowed behaviours, even when
  enabling the stress generator" — while weak behaviour does appear in 4 of the
  10 allowed tests once stress is tuned by hand: one direction bounded by what
  did not appear, the other by what did. `harness-reporting.md` §4 cites it for
  the shape of that reading only. This harness holds no model, so it stops at
  the observation and the pairing is an offline step.

## [Vigna15]

Sebastiano Vigna. `splitmix64.c`, 2015. `https://prng.di.unimi.it/splitmix64.c`
(byte-identical copy at `https://xoshiro.di.unimi.it/splitmix64.c`). Public
domain, in the file's own words: "To the extent possible under law, the author
has dedicated all copyright and related and neighboring rights to this software
to the public domain worldwide. Permission to use, copy, modify, and/or
distribute this software for any purpose with or without fee is hereby granted."

Claim(s) this project takes from it:
* The mixer, its two multipliers, its three shifts and its increment, verbatim
  from the file: `z = (x += 0x9e3779b97f4a7c15); z = (z ^ (z >> 30)) *
  0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) * 0x94d049bb133111eb; return z ^ (z >>
  31);`. The increment is fixed, so value `k` of the stream a state `x0` starts
  is the mixer applied to `x0 + k * 0x9e3779b97f4a7c15` and needs no iteration.
  `het_draw` (`litmus/het-runtime/het_cpu_stress.h`) is exactly that function.
* Its provenance, as the file states it: "This is a fixed-increment version of
  Java 8's SplittableRandom generator", citing DOI 10.1145/2714064.2660195
  (Guy L. Steele Jr., Doug Lea, Christine H. Flood, *Fast Splittable
  Pseudorandom Number Generators*, OOPSLA 2014).

Deviation(s):
* The generator is evaluated at an index, never advanced: no state is stored and
  nothing is seeded once, so the value for a (participant, index) is the same
  whoever computes it and whenever. The file's claim that the generator passes
  BigCrush is about its output sequence, and is neither taken nor needed here:
  what the stress layer needs is that one participant's decisions do not repeat
  and that two participants do not make the same ones.
* A fixed increment makes every stream one cycle entered at a different point,
  so distinct `(seed, who)` pairs are offsets into a single sequence rather
  than independent streams.

## [WebGPULitmus]

Reese Levine. *webgpu-litmus*, `https://github.com/reeselevine/webgpu-litmus`,
default branch `main`, read at commit
`c7234af7cefd90f7206152b9255eee3e58ff989c`. Apache-2.0 (LICENSE file present).

Claim(s) this project takes from it:
* `components/stressPanel.js:225` states what the memory-stress percentage
  means: "The percentage of iterations in which all non-testing threads
  repeatedly access the scratch memory to cause memory stress (values should be
  between 0 and 100)". `setStressParams` (`components/litmus-setup.js:176`)
  realises it at `:184-188` --
  `if (getRandomInt(100) < testParams.memStressPct) { stressParamsArray[1] = 1; }`
  -- one roll writing ONE grid-wide flag that every non-testing workgroup reads,
  called at `:394` from `runTestIteration` (`:364`), which `runLitmusTest` runs
  once per iteration of its `for (let i = 0; i < iterations; i++)` loop
  (`:579-585`). `HET_MEM_STRESS_PCT` is that knob: one draw per test iteration,
  grid-wide.
* `components/stressPanel.js:185-203` defines the UI's presets; the "Stress"
  one (`allStressConfig`) sets `memStressPct: 100` and `preStressPct: 100`
  (`:190`, `:197`) — the tool's own stressed environment stresses every
  iteration, and no preset carries an intermediate percentage.
  `HET_MEM_STRESS_PCT` defaults to that 100.

Deviation(s):
* The draw is device-side and stateless: every stress block recomputes
  `het_draw(seed, HET_WHO_GRID, n)` for the iteration `n` it reads off
  `_gpu_iter`, where the source rolls once on the host and copies a flag into a
  buffer. One launch spans every iteration here, so there is no per-iteration
  host step to roll at.
* Only the scratchpad stress blocks obey the percentage. The GPU DDR-noise
  blocks, the CPU enemy threads and the test lanes' own pre-stress
  (`HET_PRE_STRESS_PCT`, on the same scratchpad) run whatever the draw says, so
  an off-iteration is one the stress blocks sit out, not one in which the
  scratchpad is quiet.
