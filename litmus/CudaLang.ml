(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* CudaLang: emit a CUDA C++ (.cu) litmus kernel from a parsed LISA/Bell    *)
(* scoped test.  Route B of the HetLitmus frontend (see memory              *)
(* hetlitmus-route-b-frontend): reuse the Bell/LISA scoped IR as the GPU    *)
(* frontend and translate its scoped loads/stores into libcu++ scoped       *)
(* atomics (cuda::atomic_ref<T, cuda::thread_scope_*>).                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software.                   *)
(****************************************************************************)

(* The emitter consumes the *parsed* Bell program (BellBase.pseudo, ints),
   not the litmus7 Out template: the template flattens a scoped load/store
   into an opaque `memo' string, losing the structured order+scope
   annotation we need.  Working on BellBase.Pld/Pst directly keeps the
   scope/order mapping exact and robust. *)

open Printf

(* ------------------------------------------------------------------ *)
(* Order / scope vocabulary  (.litmus annotation  ->  libcu++ token)  *)
(* Grounded against libcu++ (NVIDIA/cccl): header <cuda/atomic>,      *)
(*   cuda::atomic_ref<T, cuda::thread_scope_{block,device,system}>    *)
(*   ref(lvalue); ref.store(v, cuda::memory_order_release);           *)
(*   r = ref.load(cuda::memory_order_acquire);                        *)
(* Scope map (gpu-only-corpus.md): cta<->block, gpu<->device,         *)
(*   sys<->system.                                                    *)
(* ------------------------------------------------------------------ *)

let is_order = function
  | "relaxed" | "acquire" | "release" | "acq_rel" | "sc" -> true
  | _ -> false

let is_scope = function
  | "cta" | "gpu" | "sys" | "cluster" -> true
  | _ -> false

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
  | "cluster" ->
      (* Unreachable guard.  libcu++'s `enum thread_scope' has only
         {thread,block,device,system} -- there is NO thread_scope_cluster
         enumerator (only an internal __thread_scope_cluster_tag).  So a
         cluster-scoped op cannot go through atomic_ref; dump_instr emits it
         as inline PTX instead (see ptx_* below).  We fail loudly rather than
         emit a token that does not exist. *)
      Warn.user_error
        "CudaLang: cluster scope is emitted as inline PTX, not atomic_ref \
         (libcu++ has no cuda::thread_scope_cluster)"
  | s -> Warn.user_error "CudaLang: unknown scope %S" s

(* ------------------------------------------------------------------ *)
(* Inline-PTX path.  We drop to inline PTX (rather than libcu++) in two
   cases:
     (1) Cluster scope (NVIDIA Hopper thread-block clusters; PTX .cluster,
         between .cta and .gpu) has NO libcu++ atomic_ref form -- enum
         thread_scope lacks a cluster enumerator -- so cluster loads/stores
         must be inline PTX:
           ld.{relaxed,acquire}.cluster.b32 %0,[%1];
           st.{relaxed,release}.cluster.b32 [%0],%1;
     (2) FENCES (all scopes): libcu++'s cuda::atomic_thread_fence COLLAPSES
         an acquire/release/acq_rel thread-fence to fence.acq_rel (verified
         in CUDA 12.9 cuda/std/__atomic/functions/cuda_ptx_generated.h,
         __atomic_thread_fence_cuda), losing the release-vs-acquire
         distinction.  To keep fences faithful to the .litmus annotation we
         emit them as inline PTX at every scope:
           fence.{acquire,release,acq_rel,sc}.{cta,gpu,sys,cluster};
   PTX availability (NVIDIA PTX ISA; cross-checked against cccl
   __ptx/instructions/generated/fence.h):
     - fence.{acq_rel,sc}.{cta,gpu,sys} : PTX ISA 6.0, SM_70
     - fence.{acq_rel,sc}.cluster       : PTX ISA 7.8, SM_90
     - fence.{acquire,release}.<any>    : PTX ISA 8.6, SM_90
   So fence.acquire/fence.release ARE real PTX instructions (added in PTX
   ISA 8.6).  The CUDA 12.2 toolkit this file was first written against
   predates them, so ptxas-12.2 rejected them -- a toolkit-version limit,
   NOT an absence in the ISA.  nvcc-verified on CUDA 12.9:
   fence.{acquire,release}.cluster assemble with
   `nvcc -std=c++17 -arch=sm_90'.  Generic addressing, .b32 for ld/st. *)
(* ------------------------------------------------------------------ *)

let ptx_load_sem = function
  | "relaxed" -> "relaxed"
  | "acquire" -> "acquire"
  | s -> Warn.user_error
      "CudaLang: cluster-scope load order %S has no single-instruction PTX \
       form (PTX ld has only .relaxed/.acquire; sc needs a fence.sc.cluster \
       sequence -- not yet emitted)" s

let ptx_store_sem = function
  | "relaxed" -> "relaxed"
  | "release" -> "release"
  | s -> Warn.user_error
      "CudaLang: cluster-scope store order %S has no single-instruction PTX \
       form (PTX st has only .relaxed/.release; sc needs a fence.sc.cluster \
       sequence -- not yet emitted)" s

(* PTX fence semantics, FAITHFUL: each annotated order maps to its own PTX
   fence (acquire/release added in PTX ISA 8.6 / SM_90; acq_rel/sc since PTX
   ISA 6.0 / SM_70, cluster since 7.8 / SM_90).  This differs from libcu++'s
   atomic_thread_fence, which collapses acquire/release -> fence.acq_rel.  A
   relaxed fence is a no-op with no PTX form; the corpus never emits one
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
   the PTX scope tokens (.cta/.gpu/.sys/.cluster). *)
let ptx_scope = function
  | "cta" -> "cta" | "gpu" -> "gpu" | "sys" -> "sys" | "cluster" -> "cluster"
  | s -> Warn.user_error "CudaLang: unknown fence scope %S" s

(* Minimum SM target for an (order,scope) fence (see availability table
   above): acquire/release OR cluster scope need SM_90; acq_rel/sc at
   cta/gpu/sys work on SM_70+.  Emitted as a trailing comment for the reader. *)
let fence_min_arch ord scp =
  if scp = "cluster" || ord = "acquire" || ord = "release"
  then "requires sm_90" else "sm_70+"

(* Split a Bell annotation list (e.g. ["release";"sys"]) into the
   (order, scope) pair.  Defaults are the strongest-context-neutral
   choices and only kick in for malformed input. *)
let order_scope_of annots =
  let ord =
    try List.find is_order annots with Not_found -> "relaxed"
  and scp =
    try List.find is_scope annots with Not_found -> "sys" in
  ord, scp

(* ------------------------------------------------------------------ *)
(* BellBase accessors                                                 *)
(* ------------------------------------------------------------------ *)

(* Turn a test name such as "MP-sys-F" into a valid C identifier. *)
let c_ident s =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') then c else '_') s

let reg_name = function
  | BellBase.GPRreg i -> sprintf "r%i" i
  | BellBase.Symbolic_reg s -> s (* should not survive register allocation *)

(* Bare variable name, for human-readable comments. *)
let var_of_reg_or_addr = function
  | BellBase.Abs s -> s
  | BellBase.Rega r -> reg_name r (* address held in register *)

let var_of_addr_op = function
  | BellBase.Addr_op_atom roa -> var_of_reg_or_addr roa
  | BellBase.Addr_op_add (roa, _) -> var_of_reg_or_addr roa

(* Kernel lvalue for atomic_ref binding.  Memory locations are passed to the
   kernel as int* parameters (managed memory), so every access dereferences:
   a global `x' becomes `*x', a register-held address `r0' becomes `*r0'. *)
let lvalue_of_addr_op ao = sprintf "*%s" (var_of_addr_op ao)

let value_of_roi = function
  | BellBase.Regi r -> reg_name r
  | BellBase.Imm i -> sprintf "%i" i

(* Flatten a pseudo (peel labels) into its straight-line instructions. *)
let rec instrs_of_pseudo = function
  | BellBase.Instruction i -> [i]
  | BellBase.Label (_, p) -> instrs_of_pseudo p
  | BellBase.Nop | BellBase.Symbolic _ | BellBase.Macro _
  | BellBase.Pagealign | BellBase.Skip _ -> []

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* ------------------------------------------------------------------ *)
(* Globals and per-proc result registers                              *)
(* ------------------------------------------------------------------ *)

let abs_of_addr_op = function
  | BellBase.Addr_op_atom (BellBase.Abs s)
  | BellBase.Addr_op_add (BellBase.Abs s, _) -> Some s
  | _ -> None

(* Memory locations touched anywhere in the test, in first-seen order. *)
let collect_globals prog =
  let seen = Hashtbl.create 8 and order = ref [] in
  let add s =
    if not (Hashtbl.mem seen s) then begin
      Hashtbl.add seen s () ; order := s :: !order
    end in
  List.iter
    (fun (_, code) ->
      List.iter
        (fun i -> match i with
          | BellBase.Pld (_, ao, _) | BellBase.Pst (ao, _, _)
          | BellBase.Prmw (_, _, ao, _) ->
              begin match abs_of_addr_op ao with Some s -> add s | None -> () end
          | _ -> ())
        (instrs_of_code code))
    prog ;
  List.rev !order

(* Destination registers of loads on a proc = its observable results. *)
let result_regs code =
  let seen = Hashtbl.create 4 and order = ref [] in
  List.iter
    (fun i -> match i with
      | BellBase.Pld (BellBase.GPRreg n, _, _) ->
          if not (Hashtbl.mem seen n) then begin
            Hashtbl.add seen n () ; order := n :: !order
          end
      | _ -> ())
    (instrs_of_code code) ;
  List.rev !order

(* ------------------------------------------------------------------ *)
(* Scope tree  ->  (proc -> (block,lane)) launch layout               *)
(*   A "block" is a maximal subtree rooted at a `cta' node; CTAs are   *)
(*   numbered in DFS order, lanes by proc order within the CTA.        *)
(*   MP-cta-F => P0 in cta0, P1 in cta1 => DISTINCT blocks: the        *)
(*   moral-strength (scope-mismatch) demonstration.                    *)
(* ------------------------------------------------------------------ *)

let rec subtree_procs (BellInfo.Tree (_, ps, ch)) =
  ps @ List.concat_map subtree_procs ch

let rec collect_ctas (BellInfo.Tree (name, _, ch) as t) =
  if name = "cta" then [t]
  else List.concat_map collect_ctas ch

(* returns (layout : (proc -> block*lane), n_blocks, block_dim) *)
let layout_of_scopes scopes procs =
  let blocks =
    match scopes with
    | Some tree ->
        let ctas = collect_ctas tree in
        List.map subtree_procs ctas
    | None -> [] in
  let tbl = Hashtbl.create 8 in
  List.iteri
    (fun bi plist ->
      List.iteri (fun li p -> Hashtbl.replace tbl p (bi, li)) (List.sort compare plist))
    blocks ;
  (* Any proc not placed by the tree: give it its own fresh block. *)
  let nb = ref (List.length blocks) in
  List.iter
    (fun p -> if not (Hashtbl.mem tbl p) then begin
        Hashtbl.replace tbl p (!nb, 0) ; incr nb
      end)
    procs ;
  let n_blocks = max 1 !nb in
  let block_dim =
    List.fold_left (fun m plist -> max m (List.length plist)) 1 blocks in
  (fun p -> try Hashtbl.find tbl p with Not_found -> (p, 0)), n_blocks, block_dim

(* ------------------------------------------------------------------ *)
(* exists / condition, as a human-readable comment                    *)
(* ------------------------------------------------------------------ *)

let cond_to_string cond =
  let pp_atom =
    ConstrGen.dump_atom
      MiscParser.dump_location MiscParser.dump_location
      (fun v -> ParsedConstant.pp_v v) (fun _ -> "") in
  ConstrGen.constraints_to_string pp_atom cond

(* ------------------------------------------------------------------ *)
(* HetLitmus B3: store-tagging context (K*_n + mu).                    *)
(* ------------------------------------------------------------------ *)

(* When [dump_instr] is given [~tag:(Some (iter,k,mu))] it emits the HetLitmus
   tagged/uint64 path: every store's value becomes the per-iteration tag
   (uint64_t)(K*iter + mu) (mu resolved per store node by the caller) and every
   load/store binds a cuda::atomic_ref<uint64_t> / .b64 inline PTX.  [~tag:None]
   is the standalone GPU-only path (int / .b32), left byte-for-byte unchanged.
   The context is a plain (iter,k,mu) tuple (not a record) so CudaLang and
   HipLang share the type structurally and the one gpu_dialect.gd_dump_instr
   field unifies across both.  See env-research/decisions/B3-decision.md. *)
type tag_ctx = (string * int * int) option

(* The tagged store value, computed in C: (uint64_t)K*iter + mu.  K is cast
   first so iter is promoted to 64-bit before the multiply (no int overflow at
   large N -- B3-decision Decision 2). *)
let tagged_value iter k mu = sprintf "((uint64_t)%d * %s + %d)" k iter mu

(* Element type of the scoped atomic_ref: widened to uint64_t on the het
   tag path (B3 Decision 3), plain int on the GPU-only path. *)
let ref_elt_type : tag_ctx -> string = function Some _ -> "uint64_t" | None -> "int"

(* PTX width suffix for the cluster inline-PTX arm: .b64 tagged, .b32 plain. *)
let ptx_width : tag_ctx -> string = function Some _ -> "b64" | None -> "b32"

(* Inline-PTX operand constraint for the cluster value/dest: "l" (64-bit) on
   the tagged path, "r" (32-bit) on the GPU-only path. *)
let ptx_val_constraint : tag_ctx -> string = function Some _ -> "l" | None -> "r"

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
      if scp = "cluster" then
        (* inline PTX: the operand is the bare pointer (an address), not the
           *deref lvalue the atomic_ref path binds. *)
        fprintf chan
          "%s  asm volatile(\"st.%s.cluster.%s [%%0],%%1;\" :: \"l\"(%s), \"%s\"(%s) : \"memory\"); // sm_90\n"
          ind (ptx_store_sem ord) (ptx_width tag) (var_of_addr_op ao)
          (ptx_val_constraint tag) v
      else begin
        scoped_ref ~tag (ind ^ "  ") chan (lvalue_of_addr_op ao) scp ;
        fprintf chan "%s  ref.store(%s, %s);\n" ind v (memory_order ord)
      end ;
      fprintf chan "%s}\n" ind
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s{ // r[%s,%s] %s %s\n" ind ord scp dst var ;
      if scp = "cluster" then
        fprintf chan
          "%s  asm volatile(\"ld.%s.cluster.%s %%0,[%%1];\" : \"=%s\"(%s) : \"l\"(%s) : \"memory\"); // sm_90\n"
          ind (ptx_load_sem ord) (ptx_width tag) (ptx_val_constraint tag) dst
          (var_of_addr_op ao)
      else begin
        scoped_ref ~tag (ind ^ "  ") chan (lvalue_of_addr_op ao) scp ;
        fprintf chan "%s  %s = ref.load(%s);\n" ind dst (memory_order ord)
      end ;
      fprintf chan "%s}\n" ind
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      (* Faithful fence: emit the annotated order as inline PTX at its scope
         (bypasses libcu++ atomic_thread_fence, which collapses
         acquire/release -> fence.acq_rel).  See the inline-PTX note above. *)
      fprintf chan "%sasm volatile(\"fence.%s.%s;\" ::: \"memory\"); // %s\n"
        ind (ptx_fence_sem ord) (ptx_scope scp) (fence_min_arch ord scp)
  | BellBase.Pnop -> ()
  | _ ->
      fprintf chan "%s// UNSUPPORTED: %s\n" ind (BellBase.dump_instruction i)

(* ------------------------------------------------------------------ *)
(* Whole-test emission                                                *)
(* ------------------------------------------------------------------ *)

let nregs_layout = 4 (* result slots reserved per proc in the out buffer *)

let dump chan tname parsed =
  let prog = parsed.MiscParser.prog in
  let procs = List.map (fun ((p, _, _), _) -> p) prog in
  let nprocs = List.length procs in
  let globals = collect_globals prog in
  let scopes =
    let rec find = function
      | MiscParser.BellExtra bi :: _ -> bi.BellInfo.scopes
      | _ :: rest -> find rest
      | [] -> None in
    find parsed.MiscParser.extra_data in
  let layout, n_blocks, block_dim = layout_of_scopes scopes procs in
  let p fmt = fprintf chan fmt in
  (* ---- banner ---- *)
  p "// ======================================================================\n" ;
  p "// CUDA litmus test: %s\n" tname ;
  p "// Generated by HetLitmus CudaLang from a LISA/Bell scoped test.\n" ;
  p "// DO NOT EDIT -- regenerate via hetlitmus/emit-cuda.sh\n" ;
  p "//\n" ;
  p "// LISA source program:\n" ;
  List.iter
    (fun ((proc, _, _), code) ->
      List.iter
        (fun i -> p "//   P%i: %s\n" proc (BellBase.dump_instruction i))
        (instrs_of_code code))
    prog ;
  (match scopes with
   | Some t -> p "// scopes: %s\n" (BellInfo.pp_scopes t)
   | None -> p "// scopes: (none given)\n") ;
  p "// condition: %s\n" (cond_to_string parsed.MiscParser.condition) ;
  p "// launch: <<<%d, %d>>>  (%d CTA(s), %d thread(s)/CTA)\n"
    n_blocks block_dim n_blocks block_dim ;
  p "// ======================================================================\n\n" ;
  p "#include <cuda/atomic>\n" ;
  p "#include <cstdio>\n\n" ;
  (* ---- kernel ---- *)
  let params =
    String.concat ", "
      (List.map (fun g -> sprintf "int* %s" g) globals @ ["int* __out"]) in
  p "__global__ void litmus_%s(%s) {\n" (c_ident tname) params ;
  List.iteri
    (fun idx ((proc, _, _), code) ->
      let blk, lane = layout proc in
      let instrs = instrs_of_code code in
      let regs = result_regs code in
      if idx > 0 then p "\n" ;
      p "  // ---- P%i  (CTA %d, lane %d) ----\n" proc blk lane ;
      p "  if (blockIdx.x == %d && threadIdx.x == %d) {\n" blk lane ;
      List.iter (fun n -> p "    int r%i = 0;\n" n) regs ;
      List.iter (fun i -> dump_instr chan ~tag:None "    " i) instrs ;
      List.iter
        (fun n -> p "    __out[%d * %d + %d] = r%i;\n" proc nregs_layout n n)
        regs ;
      p "  }\n")
    prog ;
  p "}\n\n" ;
  (* ---- minimal illustrative host harness (NOT nvcc-checked: Task 8/9
         are out of scope; this documents launch geometry + result slots) ---- *)
  p "// ---- host harness (illustrative; emit-only, not compiled here) ----\n" ;
  p "// Result buffer layout: __out[proc * %d + regIndex].\n" nregs_layout ;
  p "// Reset all globals to 0 before each launch; the weak outcome under\n" ;
  p "// test is exactly the `condition' line above.\n" ;
  p "int main(void) {\n" ;
  List.iter (fun g -> p "  int *%s;   cudaMallocManaged(&%s, sizeof(int));\n" g g) globals ;
  p "  int *__out; cudaMallocManaged(&__out, sizeof(int) * %d * %d);\n"
    (max 1 nprocs) nregs_layout ;
  p "  for (int it = 0; it < 100000; ++it) {\n" ;
  List.iter (fun g -> p "    *%s = 0;\n" g) globals ;
  p "    litmus_%s<<<%d, %d>>>(%s);\n"
    (c_ident tname) n_blocks block_dim
    (String.concat ", " (globals @ ["__out"])) ;
  p "    cudaDeviceSynchronize();\n" ;
  p "    // TODO(hardware, Task 9): tally __out against the condition.\n" ;
  p "  }\n" ;
  p "  return 0;\n" ;
  p "}\n" ;
  ()
