(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* CudaLang: emit a CUDA C++ (.cu) litmus kernel from a parsed LISA/Bell    *)
(* scoped test.  The CUDA half of GpuLang: this file holds the libcu++ /    *)
(* inline-PTX lowering and the emitted CUDA tokens, GpuLang the shared      *)
(* vocabulary, accessors, launch layout and driver.                         *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software.                   *)
(****************************************************************************)

open Printf
include GpuLang

(* ------------------------------------------------------------------ *)
(* Order / scope vocabulary  (.litmus annotation  ->  libcu++ token)  *)
(* Grounded against libcu++ (NVIDIA/cccl): header <cuda/atomic>,      *)
(*   cuda::atomic_ref<T, cuda::thread_scope_{block,device,system}>    *)
(*   ref(lvalue); ref.store(v, cuda::memory_order_release);           *)
(*   r = ref.load(cuda::memory_order_acquire);                        *)
(* Scope map (gpu-only-corpus.md): cta<->block, gpu<->device,         *)
(*   sys<->system.                                                    *)
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
(* Inline-PTX fences.  libcu++'s cuda::atomic_thread_fence COLLAPSES an
   acquire/release/acq_rel thread-fence to fence.acq_rel (verified in CUDA
   12.9 cuda/std/__atomic/functions/cuda_ptx_generated.h,
   __atomic_thread_fence_cuda), losing the release-vs-acquire distinction.
   To keep fences faithful to the .litmus annotation we emit them as inline
   PTX at every scope:
     fence.{acquire,release,acq_rel,sc}.{cta,gpu,sys};
   PTX availability (NVIDIA PTX ISA; cross-checked against cccl
   __ptx/instructions/generated/fence.h):
     - fence.{acq_rel,sc}.{cta,gpu,sys} : PTX ISA 6.0, SM_70
     - fence.{acquire,release}.<any>    : PTX ISA 8.6, SM_90
   fence.acquire/fence.release therefore need a ptxas that implements PTX ISA
   8.6 -- a toolkit floor, not an absence in the ISA.  nvcc-verified on CUDA
   12.9 with `nvcc -std=c++17 -arch=sm_90'. *)
(* ------------------------------------------------------------------ *)

(* PTX fence semantics, FAITHFUL: each annotated order maps to its own PTX
   fence, not to the collapsed fence.acq_rel above.  A relaxed fence is a
   no-op with no PTX form; the corpus never emits one
   (ptx.bell F = {acquire,release,acq_rel,sc}), so fail loudly. *)
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

(* Minimum SM target for a fence order (see availability table above):
   acquire/release need SM_90, acq_rel/sc work on SM_70+.  Emitted as a
   trailing comment for the reader. *)
let fence_min_arch ord =
  if ord = "acquire" || ord = "release"
  then "requires sm_90" else "sm_70+"

(* Kernel lvalue for atomic_ref binding.  Memory locations are passed to the
   kernel as int* parameters (managed memory), so every access dereferences:
   a global `x' becomes `*x', a register-held address `r0' becomes `*r0'. *)
let lvalue_of_addr_op ao = sprintf "*%s" (var_of_addr_op ao)

(* Element type of the scoped atomic_ref: widened to uint64_t on the het
   tag path (B3 Decision 3), plain int on the GPU-only path. *)
let ref_elt_type : tag_ctx -> string = function Some _ -> "uint64_t" | None -> "int"

(* ------------------------------------------------------------------ *)
(* Instruction translation                                            *)
(* ------------------------------------------------------------------ *)

let scoped_ref ~tag ind chan var scope =
  fprintf chan "%scuda::atomic_ref<%s, %s> ref(%s);\n"
    ind (ref_elt_type tag) (thread_scope scope) var

(* dest reg of a load is declared at proc scope; here we just assign.
   [~tag] gates the HetLitmus tagged/uint64 path (Some) vs the standalone
   GPU-only path (None, byte-for-byte unchanged). *)
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
      (* Faithful fence: emit the annotated order as inline PTX at its scope
         (bypasses libcu++ atomic_thread_fence, which collapses
         acquire/release -> fence.acq_rel).  See the inline-PTX note above. *)
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
    (* NOT nvcc-checked: Task 8/9 are out of scope for this render; the
       harness documents launch geometry + result slots. *)
    gl_harness_note =
      "// ---- host harness (illustrative; emit-only, not compiled here) ----" ;
    gl_alloc =
      (fun p bytes -> sprintf "cudaMallocManaged(%s, %s);" p bytes) ;
    gl_launch =
      (fun id nb bd args -> sprintf "litmus_%s<<<%d, %d>>>(%s);" id nb bd args) ;
    gl_sync = "cudaDeviceSynchronize();" ;
    gl_dump_instr = dump_instr ;
  }

let dump chan tname parsed = dump_test dialect chan tname parsed
