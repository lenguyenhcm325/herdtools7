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

type gpu_dialect = {
    gd_ext : string ;
    gd_name : string ;
    gd_target : string ;
    gd_vendor : string ;
    gd_toolchain : string ;
    gd_compiler : string ;
    gd_compiler_var : string ;
    gd_arch_var : string ;
    gd_arch_default : string ;
    gd_arch_flag : string ;
    gd_obj_suffix : string ;
    gd_readme_files : string ;
    gd_runtime_include : string ;
    gd_dump_instr :
      out_channel -> het:string option -> string ->
      BellBase.instruction -> unit ;
    gd_fence_floor_guard : BellBase.instruction list -> string ;
    gd_device_sync : string ;
    gd_free : string -> string ;
    (* gd_poke_def and gd_poke_arg go together: an empty definition must pair
       with a NULL argument. *)
    gd_poke_def : string ;
    gd_poke_arg : string ;
    gd_shared_mem_defs : string ;
    gd_noise_mem_defs : string ;
    gd_err_t : string ;
    gd_success : string ;
    gd_errstr : string ;
    gd_dev_attr : string ;
    gd_attr_coop : string ;
    gd_attr_smcount : string ;
    gd_occupancy : string ;
    gd_coop_launch : string ;
    (* Read buffers live in device memory, off the coherent race path. *)
    gd_dev_malloc : string -> string -> string ;
    gd_memcpy_d2h : string -> string -> string -> string ;
    gd_dev_memset0 : string -> string -> string ;
    (* The scratchpad is device memory, never gd_alloc_shared. *)
    gd_memcpy_h2d : string -> string -> string -> string ;
  }

let cuda_dialect = {
    gd_ext = "cu" ; gd_name = "CUDA" ;
    gd_target = "cuda" ; gd_vendor = "NVIDIA" ; gd_toolchain = "CUDA" ;
    gd_compiler = "nvcc" ; gd_compiler_var = "NVCC" ;
    gd_arch_var = "CUDA_ARCH" ; gd_arch_default = "sm_90" ;
    gd_arch_flag = "-arch=" ;
    gd_obj_suffix = "" ;
    gd_readme_files = "GPU kernel + host driver, CUDA dialect.\n" ;
    gd_runtime_include = "#include <cuda/atomic>" ;
    gd_dump_instr = CudaLang.dump_instr ;
    gd_fence_floor_guard = CudaLang.fence_floor_guard ;
    gd_device_sync = "cudaDeviceSynchronize();" ;
    gd_free = (fun v -> Printf.sprintf "cudaFree(%s);" v) ;
    gd_poke_def =
      "static void gd_progress_poke(void) { (void)cudaStreamQuery(0); }\n" ;
    gd_poke_arg = "(_n == 0 || !a->_rdv[_n-1]) ? gd_progress_poke : NULL" ;
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
    gd_arch_flag = "--offload-arch=" ;
    gd_obj_suffix = "_hip" ;
    gd_readme_files = "GPU kernel + host driver, HIP dialect.\n" ;
    gd_runtime_include = "#include <hip/hip_runtime.h>" ;
    gd_dump_instr = HipLang.dump_instr ;
    gd_fence_floor_guard = (fun _ -> "") ;
    gd_device_sync = "hipDeviceSynchronize();" ;
    gd_free = (fun v -> Printf.sprintf "(void)hipFree(%s);" v) ;
    gd_poke_def = "" ;
    gd_poke_arg = "NULL" ;
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

let dialects = [ cuda_dialect ; hip_dialect ]

let target_doc = String.concat "|" (List.map (fun d -> d.gd_target) dialects)

let gpu_obj d tname = Printf.sprintf "%s%s.o" tname d.gd_obj_suffix
let gpu_cflags d aref =
  Printf.sprintf "-std=c++17 %s%s" d.gd_arch_flag aref

let requested : string option ref = ref None

let set t = requested := Some t

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
     begin match List.find_opt (fun e -> String.equal (key e) t) entries with
     | None ->
        Warn.user_error "unknown -gpu-target %S (accepted: %s)" t accepted
     | Some e -> e
     end
