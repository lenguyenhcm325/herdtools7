(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* HipLang: emit an AMD HIP C++ (.hip) litmus kernel from a parsed          *)
(* LISA/Bell scoped test.  The HIP half of GpuLang: this file holds the     *)
(* lowering into the HIP scoped-atomic builtins                            *)
(* __hip_atomic_load/store(..., order, __HIP_MEMORY_SCOPE_<s>) and the      *)
(* Clang builtin __builtin_amdgcn_fence(order, "<scope-string>") -- which   *)
(* carries BOTH the order and the scope (the AMD counterpart of CudaLang's  *)
(* faithful inline-PTX fence.<order>.<scope>) -- plus the emitted HIP       *)
(* tokens; GpuLang holds the shared vocabulary, accessors, launch layout    *)
(* and driver.  No target compiles a fence -- see hip_fence_scope.          *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software.                   *)
(****************************************************************************)

open Printf
include GpuLang

(* ------------------------------------------------------------------ *)
(* Order / scope vocabulary  (.litmus annotation  ->  HIP token)      *)
(* Grounded against the HIP scoped-atomic builtins (ROCm/clr           *)
(*   hipamd/include/hip/amd_detail/amd_hip_atomic.h) and Clang:        *)
(*   __hip_atomic_store(ptr, val, memorder, scope);                    *)
(*   v = __hip_atomic_load(ptr, memorder, scope);                      *)
(*   memorder in {__ATOMIC_RELAXED,_ACQUIRE,_RELEASE,_ACQ_REL,_SEQ_CST}*)
(*   scope    = __HIP_MEMORY_SCOPE_{SINGLETHREAD=1,WAVEFRONT=2,         *)
(*              WORKGROUP=3,AGENT=4,SYSTEM=5}.                          *)
(* Scope map (gpu-only-corpus.md, vendor ladder cta<->workgroup,       *)
(*   gpu<->agent, sys<->system): see hetlitmus/docs/hip-emitter.md.    *)
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

(* Faithful HIP fence lowering via the Clang builtin __builtin_amdgcn_fence,
   the AMD counterpart of CudaLang's inline-PTX `fence.<order>.<scope>'.
     __builtin_amdgcn_fence(<order>, "<scope-string>")
   carries BOTH the memory order AND the sync scope.  This SUPERSEDES the old
   __threadfence{,_block,_system} primitives, which carried only the scope and
   were always FULL fences -- they silently dropped the annotated order and
   over-synchronised (e.g. a release fence became a full fence).

   Not gated: no target compiles a fence.  Both AMD compile paths build
   fence-free tests (hipbuildcheck.py; smoke.sh rep 7), no committed hip-out
   golden carries one, and compile-hip.sh defaults to that same golden dir --
   so a syntactically broken __builtin_amdgcn_fence still passes
   hetlitmus-test, -test-nvcc and -corpus.  ptxcheck.py earns the same claim
   on the CUDA side by reading `nvcc --ptx' back; nothing reads AMD ISA.
   Fence tests do exist: 33 of the 137 gpu-only and 171 of the 411 het.

   Grounded (web-fetched, not memory):
   - LLVM review D75917 ("Expose llvm fence instruction as clang intrinsic")
     and the Clang LanguageExtensions docs: the first arg is a C11 memory-order
     constant -- one of __ATOMIC_{ACQUIRE,RELEASE,ACQ_REL,SEQ_CST} -- and the
     second arg is an AMDHSA LLVM sync-scope STRING.  The clang builtin tests in
     D75917 use exactly "workgroup", "agent", and "" (the empty string) for the
     system scope.
   - LLVM AMDGPUUsage "AMDHSA LLVM Sync Scopes" table: the named scopes include
     "workgroup", "agent", "wavefront" and "singlethread"; SYSTEM is the
     DEFAULT and is the EMPTY STRING "" (no syncscope name).  Getting `sys' wrong
     (e.g. naming a scope instead of "") would silently NARROW the scope, so the
     empty string is load-bearing.

   Scope map mirrors hip_scope: cta -> "workgroup", gpu -> "agent",
   sys -> "" (system, the default). *)
let hip_fence_scope = function
  | "cta"     -> "workgroup"
  | "gpu"     -> "agent"
  | "sys"     -> ""        (* system = the default = empty syncscope string *)
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
      (* __builtin_amdgcn_fence carries BOTH order and scope; see
         hip_fence_scope for what no target compiles.
         A `relaxed' fence is meaningless (a no-op in the C11/AMDGPU model) and
         __builtin_amdgcn_fence accepts only acquire/release/acq_rel/seq_cst, so
         emit nothing executable for it -- just a traceability comment. *)
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
    (* The device kernel + this harness are compile-checked for the MI300A ISA
       (gfx942) by hetlitmus/compile-hip.sh (the HIP analog of CUDA Task 8);
       hardware execution stays Task 9 / MI300A-gated.  See
       hetlitmus/docs/hip-emitter.md. *)
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
