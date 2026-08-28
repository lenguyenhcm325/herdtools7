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

(* HetLitmus: emit an AMD HIP C++ (.hip) litmus kernel from a parsed LISA/Bell
   scoped test -- the lowering into __hip_atomic_load/store and
   __builtin_amdgcn_fence, plus the emitted HIP tokens; gpuLang holds
   everything shared with CudaLang.  Design: hetlitmus/docs/hip-emitter.md. *)

open Printf
include GpuLang

(* Annotation -> HIP token [HipAtomicHeader]. *)

let hip_memory_order = function
  | "relaxed" -> "__ATOMIC_RELAXED"
  | "acquire" -> "__ATOMIC_ACQUIRE"
  | "release" -> "__ATOMIC_RELEASE"
  | "acq_rel" -> "__ATOMIC_ACQ_REL"
  | "sc"      -> "__ATOMIC_SEQ_CST"
  | s -> Warn.user_error "HipLang: unknown memory order %S" s

let hip_scope = function
  | "cta"     -> "__HIP_MEMORY_SCOPE_WORKGROUP"
  | "gpu"     -> "__HIP_MEMORY_SCOPE_AGENT"
  | "sys"     -> "__HIP_MEMORY_SCOPE_SYSTEM"
  | s -> Warn.user_error "HipLang: unknown scope %S" s

(* The sync-scope string a fence carries beside its order [D75917]. *)
let hip_fence_scope = function
  | "cta"     -> "workgroup"
  | "gpu"     -> "agent"
  (* `sys' is the unnamed default sync scope; naming one here would NARROW it
     [AMDGPUUsage "Memory Scopes"]. *)
  | "sys"     -> ""
  | s -> Warn.user_error "HipLang: unknown fence scope %S" s

(* Locations are kernel int* parameters, so `x' is already the pointer. *)
let ptr_of_addr_op ~het ao =
  let v = var_of_addr_op ao in
  match het with
  | Some idx -> sprintf "(%s + (%s)*HET_SLOT_STRIDE_WORDS)" v idx
  | None -> v

(* Instruction translation *)

let dump_instr chan ~het ind i = match i with
  | BellBase.Pst (ao, roi, annots) ->
      let var = var_of_addr_op ao in
      let v = value_of_roi roi in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// w[%s,%s] %s %s\n" ind ord scp var v ;
      fprintf chan "%s__hip_atomic_store(%s, %s, %s, %s);\n"
        ind (ptr_of_addr_op ~het ao) v (hip_memory_order ord) (hip_scope scp)
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// r[%s,%s] %s %s\n" ind ord scp dst var ;
      fprintf chan "%s%s = __hip_atomic_load(%s, %s, %s);\n"
        ind dst (ptr_of_addr_op ~het ao) (hip_memory_order ord) (hip_scope scp)
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      fprintf chan "%s__builtin_amdgcn_fence(%s, %S); // f[%s,%s]\n"
        ind (hip_memory_order ord) (hip_fence_scope scp) ord scp
  | BellBase.Pnop -> ()
  | _ -> assert false

(* Whole-test emission *)

let dialect = {
    gl_kind = "HIP" ;
    gl_lang = "HipLang" ;
    gl_emit_script = "hetlitmus/emit-hip.sh" ;
    gl_group = "workgroup" ;
    gl_include = "#include <hip/hip_runtime.h>" ;
    gl_alloc =
      (fun v bytes -> sprintf "alloc_checked((void**)&%s, %s, \"%s\");" v bytes v) ;
    gl_alloc_def = {|static void alloc_checked(void** p, size_t bytes, const char* what) {
  *p = NULL;
  hipError_t e = hipMallocManaged(p, bytes);
  if (e != hipSuccess || *p == NULL) {
    fprintf(stderr, "HetLitmus FATAL: hipMallocManaged of %llu bytes for %s failed (%s)\n",
            (unsigned long long)bytes, what, hipGetErrorString(e));
    exit(2);
  }
}|} ;
    gl_launch =
      (fun id nb bd args ->
        sprintf "hipLaunchKernelGGL(litmus_%s, dim3(%d), dim3(%d), 0, 0, %s);"
          id nb bd args) ;
    gl_sync = "(void)hipDeviceSynchronize();" ;
    gl_dump_instr = dump_instr ;
  }

let dump chan tname parsed = dump_test dialect chan tname parsed
