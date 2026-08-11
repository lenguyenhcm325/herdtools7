(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetDialect: the GPU back-end dialect registry -- one record per vendor   *)
(* -- and litmus7's `-gpu-target' option, which picks exactly one of its    *)
(* rows.  The accepted vocabulary is not spelled out anywhere: it IS the    *)
(* registry's target column, so a vendor becomes accepted by being          *)
(* registered.  Both GPU-emitting arms (hetEmit's harness directory,        *)
(* hetGpuOnly's scoped-LISA renders) filter it through [select], so one     *)
(* emission produces one vendor's render and one vendor's build arms.       *)
(* Outside them only litmus7's option table touches this file, so a         *)
(* CPU-only run is unaffected.                                              *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

(* ===================== HetLitmus: GPU back-end dialect ===================
   The combined CPU+GPU harness is emitted for BOTH CUDA and HIP from ONE
   LISA parse.  CudaLang and HipLang share the layout / globals /
   result-register analysis byte-for-byte, so a `gpu_dialect' carries only the
   per-instruction lowering and the few differing host tokens, and one driver
   template is rendered twice (<t>.cu, <t>.hip).  Per-target behaviour is
   added as a FIELD here, never as a branch in the template. *)
type gpu_dialect = {
    gd_ext : string ;             (* output extension: "cu" | "hip" *)
    gd_name : string ;            (* "CUDA" | "HIP" *)
    (* Toolchain facts, read by the emitted comp.sh / Makefile / README.  A
       vendor supplies values here instead of a hand-written arm in each of
       those files. *)
    gd_target : string ;        (* comp.sh/make target word: "cuda" | "hip" *)
    gd_vendor : string ;        (* "NVIDIA" | "AMD" *)
    gd_toolchain : string ;     (* named when its compiler is absent *)
    gd_compiler : string ;      (* "nvcc" | "hipcc" *)
    gd_compiler_var : string ;  (* build variable holding it: "NVCC" | "HIPCC" *)
    gd_arch_var : string ;      (* "CUDA_ARCH" | "HIP_ARCH" *)
    gd_arch_default : string ;  (* "sm_90" | "gfx942" *)
    gd_arch_flag : string ;     (* "-arch=" | "--offload-arch=" *)
    gd_arch_flag_first : bool ; (* compile line: arch flag before -std=c++17 *)
    gd_obj_suffix : string ;    (* GPU object stem suffix: "" | "_hip" *)
    gd_readme_files : string ;  (* this render's entry in README's file list *)
    gd_runtime_include : string ; (* the differing GPU atomics/runtime header *)
    (* [~tag] selects the tagged/uint64 store path (Some (iter,k,mu)) over the
       standalone GPU-only path (None); a structural tuple, so this one field
       unifies across CudaLang and HipLang. *)
    gd_dump_instr :
      out_channel -> tag:(string * int * int) option -> string ->
      BellBase.instruction -> unit ;
    gd_device_sync : string ;     (* host-side device-sync statement *)
    gd_free : string -> string ;  (* var -> free statement *)
    gd_bar : string -> string -> string ; (* indent, ptr-expr -> arrive+spin *)
    (* Per-target allocator for the shared litmus vars + the rendezvous
       barrier; the banner in [gd_shared_mem_defs] states why the choice is
       correctness rather than tuning (env-research/Q8-allocation.md).
       [gd_shared_mem_defs] emits the file-scope gd_alloc_shared /
       gd_free_shared, so call sites stay dialect-agnostic C;
       [gd_shared_mem_note] is the harness-header banner comment.  __out is
       NOT routed through these. *)
    (* The page-placement lever HET_PLACE drives, by its API name -- a DIALECT
       fact, not a machine one: it is the vendor runtime call the render
       contains.  None where the render carries no placement code at all (the
       HIP lane refuses a non-zero HET_PLACE at compile time), and then
       het_verdict.h names the mechanism instead. *)
    gd_place_lever : string option ;
    gd_shared_mem_note : string ;  (* "shared vars" banner comment *)
    gd_shared_mem_defs : string ;  (* file-scope gd_alloc_shared / gd_free_shared defs *)
    (* The interconnect-stress allocator: a FOURTH object class -- large system
       buffers homed on the OTHER processing unit, so stream-reading them
       crosses the interconnect.  A field rather than a branch because the two
       targets differ in kind: GH200 places pages across an LPDDR/HBM split,
       MI300A has one HBM pool and gets its interconnect pressure from
       cross-chiplet contention instead
       (env-research/Q6-cpu-interconnect-stress.md sec 3.2/3.4). *)
    gd_noise_mem_defs : string ;   (* file-scope gd_alloc_noise / gd_free_noise *)
    (* Cooperative-launch API tokens, used only for the co-residency +
       weak-progress guarantee of the persistent kernel; the CPU<->GPU
       rendezvous stays [gd_bar] (a system-scope atomic), so no grid.sync and
       no cooperative_groups.h. *)
    gd_err_t : string ;         (* "cudaError_t"      | "hipError_t" *)
    gd_success : string ;       (* "cudaSuccess"      | "hipSuccess" *)
    gd_errstr : string ;        (* error-code -> message fn *)
    gd_dev_attr : string ;      (* device-attribute query fn *)
    gd_attr_coop : string ;     (* cooperative-launch support attribute enum *)
    gd_attr_smcount : string ;  (* multiprocessor-count attribute enum *)
    gd_occupancy : string ;     (* max-active-blocks-per-SM occupancy query fn *)
    gd_coop_launch : string ;   (* cooperative kernel-launch fn *)
    (* Read-buffer device-memory tokens.  The per-load read buffers live in
       DEVICE memory, off the coherent race path -- buffer writes must not add
       interconnect traffic that perturbs the tested race -- and are mirrored
       host-side after the terminal sync for the recovery scan. *)
    gd_dev_malloc : string -> string -> string ;   (* var, bytes -> device alloc *)
    gd_memcpy_d2h : string -> string -> string -> string ; (* dst, src, bytes *)
    gd_dev_memset0 : string -> string -> string ;  (* ptr, bytes -> zero device mem *)
    (* Host->device copy for the per-run stress scratch-location layout (chosen
       host-side by het_set_scratch_locations, consumed by every stressing
       lane).  The scratchpad is device memory -- GPU-only and disjoint from
       every test location -- so it never goes through gd_alloc_shared. *)
    gd_memcpy_h2d : string -> string -> string -> string ; (* dst, src, bytes *)
    (* A relaxed system-scope uint64 load of a shared var, used by the GPU
       observer lane to snoop a coherence (ws) location.  Analysis-only, never
       the tested order; given the global's C pointer name. *)
    gd_sys_load_u64 : string -> string ;           (* ptr -> load expression *)
  }

let cuda_dialect = {
    gd_ext = "cu" ; gd_name = "CUDA" ;
    gd_target = "cuda" ; gd_vendor = "NVIDIA" ; gd_toolchain = "CUDA" ;
    gd_compiler = "nvcc" ; gd_compiler_var = "NVCC" ;
    gd_arch_var = "CUDA_ARCH" ; gd_arch_default = "sm_90" ;
    gd_arch_flag = "-arch=" ; gd_arch_flag_first = false ;
    gd_obj_suffix = "" ;
    gd_readme_files =
      "GPU kernel + host driver, CUDA dialect (gd_alloc_shared:\n\
       \             @MALLOC_SITE@ / cudaMallocManaged fallback for the shared vars +\n\
       \             barrier, cuda::atomic_ref system-scope barrier, pthread + kernel launch).\n" ;
    gd_runtime_include = "#include <cuda/atomic>" ;
    gd_dump_instr = CudaLang.dump_instr ;
    gd_device_sync = "cudaDeviceSynchronize();" ;
    gd_free = (fun v -> Printf.sprintf "cudaFree(%s);" v) ;
    gd_bar =
      (fun ind ptr ->
        Printf.sprintf
          "%scuda::atomic_ref<int, cuda::thread_scope_system> _bar(*(%s));\n\
           %s_bar.fetch_add(1, cuda::memory_order_seq_cst);\n\
           %swhile (_bar.load(cuda::memory_order_seq_cst) < NPART) { }\n"
          ind ptr ind ind) ;
    gd_place_lever = Some "cudaMemAdvise" ;
    gd_shared_mem_note =
      "// Shared vars + barrier use gd_alloc_shared: system malloc() on GH200 (ATS =>\n\
       // cache-line CHI coherence over NVLink-C2C, the real inter-device protocol);\n\
       // cudaMallocManaged only as the dev-box/CI fallback (managed = 2 MB page\n\
       // migration on GH200, which masks the race).\n" ;
    gd_shared_mem_defs = HetPayloads.het_alloc_cuda_inc ;
    gd_noise_mem_defs = HetPayloads.het_noise_cuda_inc ;
    gd_err_t = "cudaError_t" ;
    gd_success = "cudaSuccess" ;
    gd_errstr = "cudaGetErrorString" ;
    gd_dev_attr = "cudaDeviceGetAttribute" ;
    gd_attr_coop = "cudaDevAttrCooperativeLaunch" ;
    gd_attr_smcount = "cudaDevAttrMultiProcessorCount" ;
    gd_occupancy = "cudaOccupancyMaxActiveBlocksPerMultiprocessor" ;
    gd_coop_launch = "cudaLaunchCooperativeKernel" ;
    gd_dev_malloc =
      (fun v bytes -> Printf.sprintf "cudaMalloc(&%s, %s);" v bytes) ;
    gd_memcpy_d2h =
      (fun dst src bytes ->
        Printf.sprintf "cudaMemcpy(%s, %s, %s, cudaMemcpyDeviceToHost);"
          dst src bytes) ;
    gd_memcpy_h2d =
      (fun dst src bytes ->
        Printf.sprintf "cudaMemcpy(%s, %s, %s, cudaMemcpyHostToDevice);"
          dst src bytes) ;
    gd_dev_memset0 =
      (fun p bytes -> Printf.sprintf "cudaMemset(%s, 0, %s);" p bytes) ;
    gd_sys_load_u64 =
      (fun ptr ->
        Printf.sprintf
          "cuda::atomic_ref<uint64_t, cuda::thread_scope_system>(*%s).load(cuda::memory_order_relaxed)"
          ptr) ;
  }

let hip_dialect = {
    gd_ext = "hip" ; gd_name = "HIP" ;
    gd_target = "hip" ; gd_vendor = "AMD" ; gd_toolchain = "HIP/ROCm" ;
    gd_compiler = "hipcc" ; gd_compiler_var = "HIPCC" ;
    gd_arch_var = "HIP_ARCH" ; gd_arch_default = "gfx942" ;
    gd_arch_flag = "--offload-arch=" ; gd_arch_flag_first = true ;
    gd_obj_suffix = "_hip" ;
    gd_readme_files =
      "same harness, HIP dialect (gd_alloc_shared: fine-grained\n\
       \             hipMallocManaged, __hip_atomic_*).\n" ;
    gd_runtime_include = "#include <hip/hip_runtime.h>" ;
    gd_dump_instr = HipLang.dump_instr ;
    (* no (void) cast: the driver binds this and checks its status *)
    gd_device_sync = "hipDeviceSynchronize();" ;
    gd_free = (fun v -> Printf.sprintf "(void)hipFree(%s);" v) ;
    gd_bar =
      (fun ind ptr ->
        Printf.sprintf
          "%s(void)__hip_atomic_fetch_add((%s), 1, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);\n\
           %swhile (__hip_atomic_load((%s), __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM) < NPART) { }\n"
          ind ptr ind ptr) ;
    (* No placement lever on this lane: MI300A has one HBM pool and nothing to
       place, and het_alloc_hip.inc turns a non-zero HET_PLACE into an #error. *)
    gd_place_lever = None ;
    gd_shared_mem_note =
      "// Shared vars + barrier use gd_alloc_shared: fine-grained hipMallocManaged on\n\
       // MI300A -- the only mode coherent for system-scope CPU<->GPU sync during a\n\
       // live kernel (coarse-grained is visible only at kernel boundary).\n" ;
    gd_shared_mem_defs = HetPayloads.het_alloc_hip_inc ;
    gd_noise_mem_defs = HetPayloads.het_noise_hip_inc ;
    gd_err_t = "hipError_t" ;
    gd_success = "hipSuccess" ;
    gd_errstr = "hipGetErrorString" ;
    gd_dev_attr = "hipDeviceGetAttribute" ;
    gd_attr_coop = "hipDeviceAttributeCooperativeLaunch" ;
    gd_attr_smcount = "hipDeviceAttributeMultiprocessorCount" ;
    gd_occupancy = "hipOccupancyMaxActiveBlocksPerMultiprocessor" ;
    gd_coop_launch = "hipLaunchCooperativeKernel" ;
    gd_dev_malloc =
      (fun v bytes -> Printf.sprintf "(void)hipMalloc(&%s, %s);" v bytes) ;
    gd_memcpy_d2h =
      (fun dst src bytes ->
        Printf.sprintf "(void)hipMemcpy(%s, %s, %s, hipMemcpyDeviceToHost);"
          dst src bytes) ;
    gd_memcpy_h2d =
      (fun dst src bytes ->
        Printf.sprintf "(void)hipMemcpy(%s, %s, %s, hipMemcpyHostToDevice);"
          dst src bytes) ;
    gd_dev_memset0 =
      (fun p bytes -> Printf.sprintf "(void)hipMemset(%s, 0, %s);" p bytes) ;
    gd_sys_load_u64 =
      (fun ptr ->
        Printf.sprintf
          "__hip_atomic_load(%s, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM)" ptr) ;
  }

(* THE DIALECT REGISTRY.  Every per-vendor site -- the renders themselves and
   every arm, header sentence and narrative of the emitted comp.sh / Makefile
   / README -- folds over this list, so a vendor is added by adding an entry.
   [select] below filters it on `-gpu-target': an emission sees ONE entry, and
   the folds below then name only that vendor.  List order is emission order;
   the head is what the build files default to. *)
let dialects = [ cuda_dialect ; hip_dialect ]

(* The `-gpu-target' vocabulary IS this list's target column; litmus7's option
   help reads it here rather than repeating the words. *)
let target_doc = String.concat "|" (List.map (fun d -> d.gd_target) dialects)

(* The GPU object this render compiles to, and the compile-line flags, given
   the arch reference as each build file spells it ("$CUDA_ARCH" in sh,
   "$(CUDA_ARCH)" in make). *)
let gpu_obj d tname = Printf.sprintf "%s%s.o" tname d.gd_obj_suffix
let gpu_cflags d aref =
  let a = d.gd_arch_flag ^ aref in
  if d.gd_arch_flag_first then a ^ " -std=c++17" else "-std=c++17 " ^ a

(* The filter itself: [set] records what `-gpu-target' asked for, [select]
   answers with the one row that matches. *)
let requested : string option ref = ref None

let set t = requested := Some t

(* [key] names an entry's target word -- generic, because hetGpuOnly filters a
   (dialect, banner, renderer) triple list rather than the bare rows.  Fails
   closed twice over -- no target given, and a target no entry answers to --
   because the caller's ONLY deliverable is the emitted render; the emission
   arms turn the error into a refusal (HetArch.refused: exit 3, never a
   silent 0). *)
let select ~key entries =
  let accepted = String.concat "|" (List.map key entries) in
  match !requested with
  | None ->
     Warn.user_error
       "-gpu-target <%s> is required: an emission renders ONE GPU dialect, \
        and the harness it writes carries only that vendor's render and \
        build targets"
       accepted
  | Some t ->
     begin match List.filter (fun e -> String.equal (key e) t) entries with
     | [] ->
        Warn.user_error "unknown -gpu-target %S (accepted: %s)" t accepted
     | l -> l
     end
