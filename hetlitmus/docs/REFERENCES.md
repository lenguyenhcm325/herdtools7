# References

A `[Key]` in HetLitmus code or tests resolves here. A locator after the key (`§`, Table, a section
name for a living document, `file:line` for code) points into the source.

## Papers

[Alglave11] Jade Alglave, Luc Maranget, Susmit Sarkar, Peter Sewell. *Litmus: Running Tests
against Hardware.* TACAS 2011, pp. 41–44. DOI 10.1007/978-3-642-19835-9_5.

[Alglave15] Jade Alglave, Mark Batty, Alastair F. Donaldson, Ganesh Gopalakrishnan, Jeroen
Ketema, Daniel Poetzl, Tyler Sorensen, John Wickerson. *GPU Concurrency: Weak Behaviours and
Programming Assumptions.* ASPLOS 2015, pp. 577–591. DOI 10.1145/2694344.2694391.

[Bagchi26] Soham Bagchi, Sanya Srivastava, Reese Levine, Tyler Sorensen, Ryan Stutsman, Vijay
Nagarajan. *Consistency and Coherence of the NVIDIA Grace-Hopper Superchip.* ISMM '26, pp. 66–79.
DOI 10.1145/3814942.3816134.

[Fusco24] Luigi Fusco, Mikhail Khalilov, Marcin Chrapek, Giridhar Chukkapalli, Thomas Schulthess,
Torsten Hoefler. *Understanding Data Movement in Tightly Coupled Heterogeneous Systems: A Case
Study with the Grace Hopper Superchip.* arXiv:2408.11556v2, 2024.

[GPUHarbor23] Reese Levine, Mingun Cho, Devon McKee, Andrew Quinn, Tyler Sorensen. *GPUHarbor:
Testing GPU Memory Consistency at Large (Experience Paper).* ISSTA 2023, pp. 779–791. DOI
10.1145/3597926.3598095.

[Kirkham20] Jake Kirkham, Tyler Sorensen, Esin Tureci, Margaret Martonosi. *Foundations of
Empirical Memory Consistency Testing.* Proc. ACM Program. Lang. 4, OOPSLA, Article 226 (2020).
DOI 10.1145/3428294.

[Sorensen16] Tyler Sorensen, Alastair F. Donaldson. *Exposing Errors Related to Weak Memory in GPU
Applications.* PLDI 2016, pp. 100–113. DOI 10.1145/2908080.2908114.

[Srivastava24] Sanya Srivastava. *Testing Memory Models of Heterogeneous CPU-GPU Systems.* MSc
thesis, University of California, Santa Cruz, 2024. `https://escholarship.org/uc/item/5hm7q1jv`.

## Specifications and documentation

[AMDGPUUsage] LLVM Project. *User Guide for AMDGPU Backend.* Living document,
`https://llvm.org/docs/AMDGPUUsage.html`.

[CCCL] NVIDIA. *CUDA C++ Core Libraries (libcu++)*, as shipped with CUDA Toolkit 12.9.

[CudaGuide] NVIDIA. *CUDA Programming Guide*, Release 13.3,
`https://docs.nvidia.com/cuda/cuda-programming-guide/`.

[HipAtomicHeader] AMD ROCm. `hip/amd_detail/amd_hip_atomic.h`, as shipped with ROCm 7.2.4.

[HipRuntimeApi] AMD ROCm. `hip/hip_runtime_api.h`, as shipped with ROCm 7.2.4.

[PtxISA] NVIDIA. *Parallel Thread Execution ISA*, Version 8.8 (CUDA Toolkit 12.9),
`https://docs.nvidia.com/cuda/archive/12.9.0/parallel-thread-execution/`.

## Code

[AMDGPUIntrin] LLVM Project. `clang/lib/Headers/amdgpuintrin.h`, llvm-project commit
`ea4d814a136bbc30c09c631cb00cdddcd4a58326`.

[CudaLitmus] Reese Levine. *cuda-litmus*, `https://github.com/reeselevine/cuda-litmus`, commit
`d107bb5617ee86fea67a851b73565d62d4c2ecf0`. No licence file.

[D75917] Saiyedul Islam. *Expose llvm fence instruction as clang intrinsic.* LLVM review D75917,
llvm-project commit `06bdffb2bb45`, 2020.

[Vigna15] Sebastiano Vigna. `splitmix64.c`, 2015, `https://prng.di.unimi.it/splitmix64.c`.
Public domain.

[WebGPULitmus] Reese Levine. *webgpu-litmus*, `https://github.com/reeselevine/webgpu-litmus`,
commit `c7234af7cefd90f7206152b9255eee3e58ff989c`. Apache-2.0.
