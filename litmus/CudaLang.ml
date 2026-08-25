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

(* HetLitmus: emit a CUDA C++ (.cu) litmus kernel from a parsed LISA/Bell
   scoped test -- the libcu++ / inline-PTX lowering and the emitted CUDA
   tokens; gpuLang holds everything shared with HipLang.
   Design: hetlitmus/docs/cuda-emitter.md. *)

open Printf
include GpuLang

(* Annotation -> libcu++ token [CCCL]. *)

let memory_order = function
  | "relaxed" -> "cuda::memory_order_relaxed"
  | "acquire" -> "cuda::memory_order_acquire"
  | "release" -> "cuda::memory_order_release"
  | "acq_rel" -> "cuda::memory_order_acq_rel"
  | "sc"      -> "cuda::memory_order_seq_cst"
  | s -> Warn.user_error "CudaLang: unknown memory order %S" s

let thread_scope = function
  | "cta"     -> "cuda::thread_scope_block"
  | "gpu"     -> "cuda::thread_scope_device"
  | "sys"     -> "cuda::thread_scope_system"
  | s -> Warn.user_error "CudaLang: unknown scope %S" s

(* One inline PTX fence per annotated order, rather than the collapsed
   cuda::atomic_thread_fence (hetlitmus/docs/cuda-emitter.md, "nvcc compile").
   hetlitmus/bells/ptx.bell declares no relaxed fence, so refuse one. *)
let ptx_fence_sem = function
  | "acquire" -> "acquire"
  | "release" -> "release"
  | "acq_rel" -> "acq_rel"
  | "sc"      -> "sc"
  | "relaxed" -> Warn.user_error
      "CudaLang: a relaxed fence has no PTX form (relaxed fence is a no-op)"
  | s -> Warn.user_error "CudaLang: unknown fence order %S" s

(* PTX fence scope suffix: the LISA scope names coincide with .cta/.gpu/.sys. *)
let ptx_scope = function
  | "cta" -> "cta" | "gpu" -> "gpu" | "sys" -> "sys"
  | s -> Warn.user_error "CudaLang: unknown fence scope %S" s

(* SM floor per fence order [CCCL "cuda/__ptx/instructions/generated/fence.h"]. *)
let fence_min_arch ord =
  if ord = "acquire" || ord = "release"
  then "requires sm_90" else "sm_70+"

(* Locations are kernel int* parameters, so an access dereferences. *)
let lvalue_of_addr_op ~het ao =
  let v = var_of_addr_op ao in
  match het with
  | Some idx -> sprintf "*(%s + (%s)*HET_SLOT_STRIDE_WORDS)" v idx
  | None -> sprintf "*%s" v

(* Instruction translation *)

let scoped_ref ind chan var scope =
  fprintf chan "%scuda::atomic_ref<int, %s> ref(%s);\n"
    ind (thread_scope scope) var

(* A load's dest reg is declared at proc scope; here it is only assigned. *)
let dump_instr chan ~het ind i = match i with
  | BellBase.Pst (ao, roi, annots) ->
      let var = var_of_addr_op ao in
      let v = value_of_roi roi in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s{ // w[%s,%s] %s %s\n" ind ord scp var v ;
      scoped_ref (ind ^ "  ") chan (lvalue_of_addr_op ~het ao) scp ;
      fprintf chan "%s  ref.store(%s, %s);\n" ind v (memory_order ord) ;
      fprintf chan "%s}\n" ind
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s{ // r[%s,%s] %s %s\n" ind ord scp dst var ;
      scoped_ref (ind ^ "  ") chan (lvalue_of_addr_op ~het ao) scp ;
      fprintf chan "%s  %s = ref.load(%s);\n" ind dst (memory_order ord) ;
      fprintf chan "%s}\n" ind
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      fprintf chan "%sasm volatile(\"fence.%s.%s;\" ::: \"memory\"); // %s\n"
        ind (ptx_fence_sem ord) (ptx_scope scp) (fence_min_arch ord)
  | BellBase.Pnop -> ()
  | _ ->
      fprintf chan "%s// UNSUPPORTED: %s\n" ind (BellBase.dump_instruction i)

(* Whole-test emission *)

let dialect = {
    gl_kind = "CUDA" ;
    gl_lang = "CudaLang" ;
    gl_emit_script = "hetlitmus/emit-cuda.sh" ;
    gl_group = "CTA" ;
    gl_include = "#include <cuda/atomic>" ;
    gl_alloc =
      (fun p bytes -> sprintf "cudaMallocManaged(%s, %s);" p bytes) ;
    gl_launch =
      (fun id nb bd args -> sprintf "litmus_%s<<<%d, %d>>>(%s);" id nb bd args) ;
    gl_sync = "cudaDeviceSynchronize();" ;
    gl_dump_instr = dump_instr ;
  }

let dump chan tname parsed = dump_test dialect chan tname parsed
