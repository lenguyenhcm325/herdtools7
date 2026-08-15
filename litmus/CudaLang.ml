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
   scoped test.  The CUDA half of gpuLang: this file holds the libcu++ /
   inline-PTX lowering and the emitted CUDA tokens; gpuLang holds the shared
   vocabulary, the accessors, the launch layout and the whole-test driver.
   Design: hetlitmus/docs/cuda-emitter.md. *)

open Printf
include GpuLang

(* ------------------------------------------------------------------ *)
(* Order / scope vocabulary  (.litmus annotation  ->  libcu++ token)  *)
(* An access is a cuda::atomic_ref<T, cuda::thread_scope_*> over      *)
(* <cuda/atomic> [CCCL]; the scope map cta<->block, gpu<->device,     *)
(* sys<->system is stated in hetlitmus/docs/cuda-emitter.md.          *)
(* ------------------------------------------------------------------ *)

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

(* ------------------------------------------------------------------ *)
(* Inline-PTX fences.  cuda::atomic_thread_fence maps acquire, release and
   acq_rel alike onto fence.<scope>.acq_rel
   [CCCL "cuda/std/__atomic/functions/cuda_ptx_generated.h"], which loses the
   release-vs-acquire distinction the annotation carries, so a fence is
   emitted as inline PTX instead, at every scope.  Availability
   [CCCL "cuda/__ptx/instructions/generated/fence.h"]: fence.{acq_rel,sc}
   from PTX ISA 6.0 / SM_70, fence.{acquire,release} from PTX ISA 8.6 /
   SM_90 -- a floor on the toolkit, NOT an absence in the ISA. *)
(* ------------------------------------------------------------------ *)

(* Each annotated order maps to its own PTX fence rather than to the collapsed
   fence.acq_rel above.  A relaxed fence is a no-op with no PTX form; the
   corpus never emits one (hetlitmus/bells/ptx.bell declares
   F[{acquire,release,acq_rel,sc}]), so fail loudly. *)
let ptx_fence_sem = function
  | "acquire" -> "acquire"
  | "release" -> "release"
  | "acq_rel" -> "acq_rel"
  | "sc"      -> "sc"
  | "relaxed" -> Warn.user_error
      "CudaLang: a relaxed fence has no PTX form (relaxed fence is a no-op)"
  | s -> Warn.user_error "CudaLang: unknown fence order %S" s

(* PTX scope suffix for inline fences.  The LISA scope names coincide with
   the PTX scope tokens (.cta/.gpu/.sys). *)
let ptx_scope = function
  | "cta" -> "cta" | "gpu" -> "gpu" | "sys" -> "sys"
  | s -> Warn.user_error "CudaLang: unknown fence scope %S" s

(* Minimum SM target for a fence order (availability above): acquire/release
   need SM_90, acq_rel/sc work on SM_70+.  Emitted as a trailing comment for
   the reader. *)
let fence_min_arch ord =
  if ord = "acquire" || ord = "release"
  then "requires sm_90" else "sm_70+"

(* Kernel lvalue for atomic_ref binding.  Memory locations are passed to the
   kernel as int* parameters (managed memory), so every access dereferences:
   a global `x' becomes `*x', a register-held address `r0' becomes `*r0'. *)
let lvalue_of_addr_op ao = sprintf "*%s" (var_of_addr_op ao)

(* Element type of the scoped atomic_ref: uint64_t on the het tag path, so a
   store value cannot truncate to less than a tag; plain int on the GPU-only
   path (see GpuLang.tag_ctx). *)
let ref_elt_type : tag_ctx -> string = function Some _ -> "uint64_t" | None -> "int"

(* ------------------------------------------------------------------ *)
(* Instruction translation                                            *)
(* ------------------------------------------------------------------ *)

let scoped_ref ~tag ind chan var scope =
  fprintf chan "%scuda::atomic_ref<%s, %s> ref(%s);\n"
    ind (ref_elt_type tag) (thread_scope scope) var

(* dest reg of a load is declared at proc scope; here we just assign.
   [~tag] selects the tagged/uint64 path (Some) over the standalone GPU-only
   path (None). *)
let dump_instr chan ~tag ind i = match i with
  | BellBase.Pst (ao, roi, annots) ->
      let var = var_of_addr_op ao in
      (* GPU-only: the parsed store value; het: the per-iteration tag. *)
      let v = match tag with
        | Some (iter,k,mu) -> tagged_value iter k mu
        | None -> value_of_roi roi in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s{ // w[%s,%s] %s %s\n" ind ord scp var v ;
      scoped_ref ~tag (ind ^ "  ") chan (lvalue_of_addr_op ao) scp ;
      fprintf chan "%s  ref.store(%s, %s);\n" ind v (memory_order ord) ;
      fprintf chan "%s}\n" ind
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s{ // r[%s,%s] %s %s\n" ind ord scp dst var ;
      scoped_ref ~tag (ind ^ "  ") chan (lvalue_of_addr_op ao) scp ;
      fprintf chan "%s  %s = ref.load(%s);\n" ind dst (memory_order ord) ;
      fprintf chan "%s}\n" ind
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      (* The annotated order, as inline PTX at its scope; see the note above
         this file's ptx_fence_sem. *)
      fprintf chan "%sasm volatile(\"fence.%s.%s;\" ::: \"memory\"); // %s\n"
        ind (ptx_fence_sem ord) (ptx_scope scp) (fence_min_arch ord)
  | BellBase.Pnop -> ()
  | _ ->
      fprintf chan "%s// UNSUPPORTED: %s\n" ind (BellBase.dump_instruction i)

(* ------------------------------------------------------------------ *)
(* Whole-test emission                                                *)
(* ------------------------------------------------------------------ *)

let dialect = {
    gl_kind = "CUDA" ;
    gl_lang = "CudaLang" ;
    gl_emit_script = "hetlitmus/emit-cuda.sh" ;
    gl_group = "CTA" ;
    gl_include = "#include <cuda/atomic>" ;
    gl_harness_note =
      "// ---- host harness (illustrative; hetlitmus/verify/ptxcheck.py compiles it for sm_90 with nvcc --ptx) ----" ;
    gl_alloc =
      (fun p bytes -> sprintf "cudaMallocManaged(%s, %s);" p bytes) ;
    gl_launch =
      (fun id nb bd args -> sprintf "litmus_%s<<<%d, %d>>>(%s);" id nb bd args) ;
    gl_sync = "cudaDeviceSynchronize();" ;
    gl_dump_instr = dump_instr ;
  }

let dump chan tname parsed = dump_test dialect chan tname parsed
