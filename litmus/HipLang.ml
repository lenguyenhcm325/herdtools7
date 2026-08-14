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

(* HetLitmus: emit an AMD HIP C++ (.hip) litmus kernel from a parsed
   LISA/Bell scoped test.  The HIP half of gpuLang: this file holds the
   lowering into the HIP scoped-atomic builtins __hip_atomic_load/store and
   into the Clang builtin __builtin_amdgcn_fence, plus the emitted HIP
   tokens; gpuLang holds the shared vocabulary, the accessors, the launch
   layout and the whole-test driver.  Design:
   hetlitmus/docs/hip-emitter.md. *)

open Printf
include GpuLang

(* ------------------------------------------------------------------ *)
(* Order / scope vocabulary  (.litmus annotation  ->  HIP token)      *)
(* The scope ladder is __HIP_MEMORY_SCOPE_{SINGLETHREAD=1,WAVEFRONT=2, *)
(* WORKGROUP=3,AGENT=4,SYSTEM=5} [HipAtomicHeader]; the vendor rungs   *)
(* cta<->workgroup, gpu<->agent, sys<->system are stated in            *)
(* hetlitmus/docs/hip-emitter.md.                                      *)
(* ------------------------------------------------------------------ *)

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

(* __builtin_amdgcn_fence(<order>, "<scope-string>") carries BOTH the memory
   order and the sync scope [D75917], which is what lets a fence keep the order
   its annotation names.  The scope map mirrors hip_scope. *)
let hip_fence_scope = function
  | "cta"     -> "workgroup"
  | "gpu"     -> "agent"
  (* `sys' is the default sync scope, whose name is the empty string; naming
     a scope here instead would NARROW it [AMDGPUUsage "Memory Scopes"]. *)
  | "sys"     -> ""
  | s -> Warn.user_error "HipLang: unknown fence scope %S" s

(* The pointer passed to __hip_atomic_*: memory locations are kernel int*
   parameters, so a global `x' is already the pointer (no `&' / no deref). *)
let ptr_of_addr_op = var_of_addr_op

(* ------------------------------------------------------------------ *)
(* Instruction translation                                            *)
(* ------------------------------------------------------------------ *)

(* On the tagged path the store value is a uint64_t; the __hip_atomic_*
   builtins are type-generic, so widening is carried by the uint64_t* kernel
   parameters (emitted in hetEmit), not by these builtins. *)
let dump_instr chan ~tag ind i = match i with
  | BellBase.Pst (ao, roi, annots) ->
      let var = var_of_addr_op ao in
      let v = match tag with
        | Some (iter,k,mu) -> tagged_value iter k mu
        | None -> value_of_roi roi in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// w[%s,%s] %s %s\n" ind ord scp var v ;
      fprintf chan "%s__hip_atomic_store(%s, %s, %s, %s);\n"
        ind (ptr_of_addr_op ao) v (hip_memory_order ord) (hip_scope scp)
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// r[%s,%s] %s %s\n" ind ord scp dst var ;
      fprintf chan "%s%s = __hip_atomic_load(%s, %s, %s);\n"
        ind dst (ptr_of_addr_op ao) (hip_memory_order ord) (hip_scope scp)
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      (* A `relaxed' fence is a no-op in the C11/AMDGPU model, and
         __builtin_amdgcn_fence accepts only acquire/release/acq_rel/seq_cst,
         so nothing executable is emitted for it. *)
      if ord = "relaxed" then
        fprintf chan "%s// f[%s,%s] (relaxed fence = no-op; nothing emitted)\n"
          ind ord scp
      else
        fprintf chan "%s__builtin_amdgcn_fence(%s, %S); // f[%s,%s]\n"
          ind (hip_memory_order ord) (hip_fence_scope scp) ord scp
  | BellBase.Pnop -> ()
  | _ ->
      fprintf chan "%s// UNSUPPORTED: %s\n" ind (BellBase.dump_instruction i)

(* ------------------------------------------------------------------ *)
(* Whole-test emission                                                *)
(* ------------------------------------------------------------------ *)

let dialect = {
    gl_kind = "HIP" ;
    gl_lang = "HipLang" ;
    gl_emit_script = "hetlitmus/emit-hip.sh" ;
    gl_group = "workgroup" ;
    gl_include = "#include <hip/hip_runtime.h>" ;
    gl_harness_note =
      "// ---- host harness (illustrative; compile-checked for gfx942 via hetlitmus/compile-hip.sh; run = Task 9, MI300A) ----" ;
    gl_alloc =
      (fun p bytes -> sprintf "(void)hipMallocManaged(%s, %s);" p bytes) ;
    gl_launch =
      (fun id nb bd args ->
        sprintf "hipLaunchKernelGGL(litmus_%s, dim3(%d), dim3(%d), 0, 0, %s);"
          id nb bd args) ;
    gl_sync = "(void)hipDeviceSynchronize();" ;
    gl_dump_instr = dump_instr ;
  }

let dump chan tname parsed = dump_test dialect chan tname parsed
