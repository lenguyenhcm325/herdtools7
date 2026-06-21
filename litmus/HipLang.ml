(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* HipLang: emit an AMD HIP C++ (.hip) litmus kernel from a parsed          *)
(* LISA/Bell scoped test.  The AMD sibling of CudaLang (Route B of the      *)
(* HetLitmus frontend, memory hetlitmus-route-b-frontend): reuse the        *)
(* Bell/LISA scoped IR as the GPU frontend and translate its scoped         *)
(* loads/stores/fences into HIP scoped-atomic builtins                      *)
(* __hip_atomic_load/store(..., order, __HIP_MEMORY_SCOPE_<s>).             *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software.                   *)
(****************************************************************************)

(* Like CudaLang, the emitter consumes the *parsed* Bell program
   (BellBase.pseudo, ints), not the litmus7 Out template: the template
   flattens a scoped load/store into an opaque `memo' string and loses the
   structured order+scope annotation.  Working on BellBase.Pld/Pst directly
   keeps the scope/order mapping exact.  The BellBase accessors below mirror
   CudaLang's on purpose -- HipLang is kept self-contained so the CUDA and
   HIP emitters evolve independently. *)

open Printf

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

let is_order = function
  | "relaxed" | "acquire" | "release" | "acq_rel" | "sc" -> true
  | _ -> false

let is_scope = function
  | "cta" | "gpu" | "sys" | "cluster" -> true
  | _ -> false

let hip_memory_order = function
  | "relaxed" -> "__ATOMIC_RELAXED"
  | "acquire" -> "__ATOMIC_ACQUIRE"
  | "release" -> "__ATOMIC_RELEASE"
  | "acq_rel" -> "__ATOMIC_ACQ_REL"
  | "sc"      -> "__ATOMIC_SEQ_CST"
  | s -> Warn.user_error "HipLang: unknown memory order %S" s

(* Cluster scope on AMD: the LLVM AMDGPU memory model DOES define a "cluster"
   synchronization scope (syncscope("cluster")/"cluster-one-as"), sitting
   BETWEEN workgroup and agent and degrading to "agent" on targets without
   workgroup-cluster launch support (LLVM AMDGPUUsage, "Memory Scopes").
   BUT it is NOT exposed in HIP source: amd_hip_atomic.h has no
   __HIP_MEMORY_SCOPE_CLUSTER (only SINGLETHREAD/WAVEFRONT/WORKGROUP/AGENT/
   SYSTEM).  It is reachable only at the LLVM-IR level.  So a cluster-scoped
   HIP atomic cannot name its true scope from C++; HipLang emits the nearest
   source-expressible scope that is never weaker -- AGENT (which is exactly the
   documented hardware degradation) -- and flags it inline + in the doc.  This
   is the AMD counterpart of CudaLang's libcu++ cluster gap (there NVIDIA could
   drop to inline PTX `.cluster'; AMD source has no equivalent token).  See
   memory hetlitmus-amd-oracle-task7 and hetlitmus/docs/hip-emitter.md. *)
let scope_is_cluster scp = (scp = "cluster")

let hip_scope = function
  | "cta"     -> "__HIP_MEMORY_SCOPE_WORKGROUP"
  | "gpu"     -> "__HIP_MEMORY_SCOPE_AGENT"
  | "sys"     -> "__HIP_MEMORY_SCOPE_SYSTEM"
  | "cluster" -> "__HIP_MEMORY_SCOPE_AGENT" (* degradation, see above *)
  | s -> Warn.user_error "HipLang: unknown scope %S" s

(* HIP scoped thread fences (ROCm HIP C++ language extensions): __threadfence
   primitives carry a SCOPE but not a memory order (they are full fences at
   that scope).  cta -> __threadfence_block (workgroup), gpu -> __threadfence
   (agent/device), sys -> __threadfence_system (system).  cluster degrades to
   the agent-scope __threadfence (same rule as the atomics above).  The corpus
   uses no fences (the -F variants synchronise with release/acquire atomics,
   not fences -- memory hetlitmus-amd-oracle-task7); this path exists only for
   parity with hand-written fence tests. *)
let hip_threadfence = function
  | "cta"     -> "__threadfence_block()"
  | "gpu"     -> "__threadfence()"
  | "sys"     -> "__threadfence_system()"
  | "cluster" -> "__threadfence()" (* cluster -> agent, see hip_scope *)
  | s -> Warn.user_error "HipLang: unknown fence scope %S" s

(* Split a Bell annotation list into the (order, scope) pair, same defaults
   as CudaLang (strongest-context-neutral; only kick in for malformed input). *)
let order_scope_of annots =
  let ord =
    try List.find is_order annots with Not_found -> "relaxed"
  and scp =
    try List.find is_scope annots with Not_found -> "sys" in
  ord, scp

(* ------------------------------------------------------------------ *)
(* BellBase accessors (mirror CudaLang)                               *)
(* ------------------------------------------------------------------ *)

let c_ident s =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') then c else '_') s

let reg_name = function
  | BellBase.GPRreg i -> sprintf "r%i" i
  | BellBase.Symbolic_reg s -> s

let var_of_reg_or_addr = function
  | BellBase.Abs s -> s
  | BellBase.Rega r -> reg_name r

let var_of_addr_op = function
  | BellBase.Addr_op_atom roa -> var_of_reg_or_addr roa
  | BellBase.Addr_op_add (roa, _) -> var_of_reg_or_addr roa

(* The pointer passed to __hip_atomic_*: memory locations are kernel int*
   parameters, so a global `x' is already the pointer (no `&' / no deref). *)
let ptr_of_addr_op = var_of_addr_op

let value_of_roi = function
  | BellBase.Regi r -> reg_name r
  | BellBase.Imm i -> sprintf "%i" i

let rec instrs_of_pseudo = function
  | BellBase.Instruction i -> [i]
  | BellBase.Label (_, p) -> instrs_of_pseudo p
  | BellBase.Nop | BellBase.Symbolic _ | BellBase.Macro _
  | BellBase.Pagealign | BellBase.Skip _ -> []

let instrs_of_code code = List.concat_map instrs_of_pseudo code

let abs_of_addr_op = function
  | BellBase.Addr_op_atom (BellBase.Abs s)
  | BellBase.Addr_op_add (BellBase.Abs s, _) -> Some s
  | _ -> None

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
(* Scope tree -> (proc -> (block,lane)) launch layout (mirror CudaLang) *)
(* ------------------------------------------------------------------ *)

let rec subtree_procs (BellInfo.Tree (_, ps, ch)) =
  ps @ List.concat_map subtree_procs ch

let rec collect_ctas (BellInfo.Tree (name, _, ch) as t) =
  if name = "cta" then [t]
  else List.concat_map collect_ctas ch

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
(* Instruction translation                                            *)
(* ------------------------------------------------------------------ *)

(* Inline tail comment flagging the cluster->agent degradation. *)
let cluster_note scp =
  if scope_is_cluster scp then
    "  // cluster -> AGENT (HIP has no __HIP_MEMORY_SCOPE_CLUSTER; see hip-emitter.md)"
  else ""

let dump_instr chan ind i = match i with
  | BellBase.Pst (ao, roi, annots) ->
      let var = var_of_addr_op ao
      and v = value_of_roi roi in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// w[%s,%s] %s %s\n" ind ord scp var v ;
      fprintf chan "%s__hip_atomic_store(%s, %s, %s, %s);%s\n"
        ind (ptr_of_addr_op ao) v (hip_memory_order ord) (hip_scope scp)
        (cluster_note scp)
  | BellBase.Pld (r, ao, annots) ->
      let var = var_of_addr_op ao
      and dst = reg_name r in
      let ord, scp = order_scope_of annots in
      fprintf chan "%s// r[%s,%s] %s %s\n" ind ord scp dst var ;
      fprintf chan "%s%s = __hip_atomic_load(%s, %s, %s);%s\n"
        ind dst (ptr_of_addr_op ao) (hip_memory_order ord) (hip_scope scp)
        (cluster_note scp)
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      let ord, scp = order_scope_of annots in
      (* HIP scoped threadfences carry scope but not order: note the annotated
         order in a comment for traceability. *)
      fprintf chan "%s%s; // f[%s,%s]%s\n"
        ind (hip_threadfence scp) ord scp (cluster_note scp)
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
  p "// HIP litmus test: %s\n" tname ;
  p "// Generated by HetLitmus HipLang from a LISA/Bell scoped test.\n" ;
  p "// DO NOT EDIT -- regenerate via hetlitmus/emit-hip.sh\n" ;
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
  p "// launch: <<<%d, %d>>>  (%d workgroup(s), %d thread(s)/workgroup)\n"
    n_blocks block_dim n_blocks block_dim ;
  p "// ======================================================================\n\n" ;
  p "#include <hip/hip_runtime.h>\n" ;
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
      p "  // ---- P%i  (workgroup %d, lane %d) ----\n" proc blk lane ;
      p "  if (blockIdx.x == %d && threadIdx.x == %d) {\n" blk lane ;
      List.iter (fun n -> p "    int r%i = 0;\n" n) regs ;
      List.iter (fun i -> dump_instr chan "    " i) instrs ;
      List.iter
        (fun n -> p "    __out[%d * %d + %d] = r%i;\n" proc nregs_layout n n)
        regs ;
      p "  }\n")
    prog ;
  p "}\n\n" ;
  (* ---- minimal illustrative host harness.  The device kernel + this harness
         are compile-checked for the MI300A ISA (gfx942) by
         hetlitmus/compile-hip.sh (the HIP analog of CUDA Task 8); hardware
         execution stays Task 9 / MI300A-gated.  See hetlitmus/docs/hip-emitter.md. *)
  p "// ---- host harness (illustrative; compile-checked for gfx942 via hetlitmus/compile-hip.sh; run = Task 9, MI300A) ----\n" ;
  p "// Result buffer layout: __out[proc * %d + regIndex].\n" nregs_layout ;
  p "// Reset all globals to 0 before each launch; the weak outcome under\n" ;
  p "// test is exactly the `condition' line above.\n" ;
  p "int main(void) {\n" ;
  List.iter (fun g -> p "  int *%s;   (void)hipMallocManaged(&%s, sizeof(int));\n" g g) globals ;
  p "  int *__out; (void)hipMallocManaged(&__out, sizeof(int) * %d * %d);\n"
    (max 1 nprocs) nregs_layout ;
  p "  for (int it = 0; it < 100000; ++it) {\n" ;
  List.iter (fun g -> p "    *%s = 0;\n" g) globals ;
  p "    hipLaunchKernelGGL(litmus_%s, dim3(%d), dim3(%d), 0, 0, %s);\n"
    (c_ident tname) n_blocks block_dim
    (String.concat ", " (globals @ ["__out"])) ;
  p "    (void)hipDeviceSynchronize();\n" ;
  p "    // TODO(hardware, Task 9): tally __out against the condition.\n" ;
  p "  }\n" ;
  p "  return 0;\n" ;
  p "}\n" ;
  ()
