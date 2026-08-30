(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2013-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(* HetLitmus: the GPU back-end dialect registry -- one record per vendor -- and
   litmus7's `-gpu-target' option, which picks exactly one row.  The accepted
   vocabulary is the registry's target column, so a vendor becomes accepted by
   being registered.  Both GPU-emitting arms filter through [select], so one
   emission renders one vendor.  hetlitmus/docs/het-emission.md, "One render
   per `-gpu-target`". *)

(* One driver template is rendered per selected vendor, so per-target behaviour
   is added as a field here, NEVER as a branch in the template. *)
type gpu_dialect = {
    gd_ext : string ;             (* output extension: "cu" | "hip" *)
    gd_name : string ;            (* "CUDA" | "HIP" *)
    (* Toolchain facts the emitted comp.sh / Makefile / README fold over. *)
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
    (* [~het] Some <C expression naming the iteration> selects the
       slot-addressed compound path; None the standalone GPU-only path. *)
    gd_dump_instr :
      out_channel -> het:string option -> string ->
      BellBase.instruction -> unit ;
    gd_device_sync : string ;     (* host-side device-sync statement *)
    gd_free : string -> string ;  (* var -> free statement *)
    (* The forward-progress poke the host half of the rendezvous calls while it
       waits, on iteration `_n' = 0 alone (litmus/het-runtime/het_rdv.h;
       hetlitmus/docs/00-environment-design.md sec 3.3).  The two fields travel
       together -- an empty definition MUST pair with a NULL argument. *)
    gd_poke_def : string ;        (* file-scope definition, or "" *)
    gd_poke_arg : string ;        (* the argument expression, over `_n' *)
    (* The page-placement mechanism HET_PLACE drives, by name -- a dialect fact,
       not a machine one (hetlitmus/docs/het-emission.md, "The pair a harness
       names").  None where the render carries no placement code. *)
    gd_place_lever : string option ;
    (* Per-target allocator for the shared vars + the rendezvous counter
       (hetlitmus/docs/00-environment-design.md sec 3.2).  Call sites stay
       dialect-agnostic C; __out is NOT routed through it. *)
    gd_shared_mem_note : string ;  (* "shared vars" banner comment *)
    gd_shared_mem_defs : string ;  (* file-scope gd_alloc_shared / gd_free_shared defs *)
    (* The interconnect-stress allocator: large system buffers homed on the
       OTHER processing unit, so stream-reading them crosses the interconnect.
       A field because the targets differ in kind
       (hetlitmus/docs/00-environment-design.md sec 3.6). *)
    gd_noise_mem_defs : string ;   (* file-scope gd_alloc_noise / gd_free_noise *)
    (* Cooperative-launch tokens: co-residency and weak progress for the
       persistent kernel ONLY.  The CPU<->GPU rendezvous is het_rdv.h's own
       counter, so no grid.sync and no cooperative_groups.h. *)
    gd_err_t : string ;         (* "cudaError_t"      | "hipError_t" *)
    gd_success : string ;       (* "cudaSuccess"      | "hipSuccess" *)
    gd_errstr : string ;        (* error-code -> message fn *)
    gd_dev_attr : string ;      (* device-attribute query fn *)
    gd_attr_coop : string ;     (* cooperative-launch support attribute enum *)
    gd_attr_smcount : string ;  (* multiprocessor-count attribute enum *)
    gd_occupancy : string ;     (* max-active-blocks-per-SM occupancy query fn *)
    gd_coop_launch : string ;   (* cooperative kernel-launch fn *)
    (* Read-buffer tokens.  The read buffers live in device memory, off the
       coherent race path, and are mirrored host-side after the terminal sync. *)
    gd_dev_malloc : string -> string -> string ;   (* var, bytes -> checked device alloc *)
    gd_memcpy_d2h : string -> string -> string -> string ; (* dst, src, bytes *)
    gd_dev_memset0 : string -> string -> string ;  (* ptr, bytes -> zero device mem *)
    (* Host->device copy for the per-run stress scratch-location layout.  The
       scratchpad is device memory, disjoint from every test location, so it
       never goes through gd_alloc_shared. *)
    gd_memcpy_h2d : string -> string -> string -> string ; (* dst, src, bytes *)
  }

let cuda_dialect = {
    gd_ext = "cu" ; gd_name = "CUDA" ;
    gd_target = "cuda" ; gd_vendor = "NVIDIA" ; gd_toolchain = "CUDA" ;
    gd_compiler = "nvcc" ; gd_compiler_var = "NVCC" ;
    gd_arch_var = "CUDA_ARCH" ; gd_arch_default = "sm_90" ;
    gd_arch_flag = "-arch=" ; gd_arch_flag_first = false ;
    gd_obj_suffix = "" ;
    gd_readme_files =
      "GPU kernel + host driver, CUDA dialect (gd_alloc_shared: system malloc\n\
       \             where the GPU reaches pageable memory / cudaMallocManaged\n\
       \             fallback for the shared vars + rendezvous counter,\n\
       \             cuda::atomic_ref system-scope rendezvous, pthread + kernel\n\
       \             launch).\n" ;
    gd_runtime_include = "#include <cuda/atomic>" ;
    gd_dump_instr = CudaLang.dump_instr ;
    gd_device_sync = "cudaDeviceSynchronize();" ;
    gd_free = (fun v -> Printf.sprintf "cudaFree(%s);" v) ;
    gd_poke_def =
      "static void gd_progress_poke(void) { (void)cudaStreamQuery(0); }\n" ;
    gd_poke_arg = "(_n == 0) ? gd_progress_poke : NULL" ;
    gd_place_lever = Some "mbind(MPOL_BIND)" ;
    gd_shared_mem_note =
      "// Shared vars + rendezvous counter use gd_alloc_shared: system malloc() where\n\
       // the device reaches pageable host memory (ATS: cache-line coherence over the\n\
       // host-device interconnect, the real inter-device protocol); cudaMallocManaged\n\
       // only as the dev-box/CI fallback (managed = page migration, which masks the\n\
       // race).\n" ;
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
      (fun v bytes ->
        Printf.sprintf "gd_alloc_dev((void**)&%s, %s, \"%s\");" v bytes v) ;
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
    gd_poke_def = "" ;
    gd_poke_arg = "NULL" ;
    (* MI300A has one HBM pool and nothing to place; het_alloc_hip.inc turns a
       non-zero HET_PLACE into an #error. *)
    gd_place_lever = None ;
    gd_shared_mem_note =
      "// Shared vars + rendezvous counter use gd_alloc_shared: fine-grained\n\
       // hipMallocManaged -- the only mode coherent for system-scope CPU<->GPU sync\n\
       // during a live kernel (coarse-grained is visible only at kernel boundary).\n" ;
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
      (fun v bytes ->
        Printf.sprintf "gd_alloc_dev((void**)&%s, %s, \"%s\");" v bytes v) ;
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
  }

(* The registry.  Every per-vendor site folds over this list, so a vendor is
   added by adding an entry; [select] filters it on `-gpu-target', so an
   emission sees ONE entry.  List order is emission order, and the head is what
   the emitted build files default to. *)
let dialects = [ cuda_dialect ; hip_dialect ]

(* litmus7's option help reads the vocabulary here rather than repeating it. *)
let target_doc = String.concat "|" (List.map (fun d -> d.gd_target) dialects)

(* The GPU object and compile-line flags, given the arch reference as each
   build file spells it ($CUDA_ARCH in sh, $(CUDA_ARCH) in make). *)
let gpu_obj d tname = Printf.sprintf "%s%s.o" tname d.gd_obj_suffix
let gpu_cflags d aref =
  let a = d.gd_arch_flag ^ aref in
  if d.gd_arch_flag_first then a ^ " -std=c++17" else "-std=c++17 " ^ a

(* [set] records what `-gpu-target' asked for, [select] answers with the row. *)
let requested : string option ref = ref None

let set t = requested := Some t

(* [key] names an entry's target word, generic because hetGpuOnly filters
   (dialect, banner, renderer) triples rather than bare rows.  Fails closed on
   both a missing and an unknown target: the caller's ONLY deliverable is the
   render, and the emission arms turn the error into HetArch.refused. *)
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
