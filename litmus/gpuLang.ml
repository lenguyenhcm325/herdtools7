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

(* HetLitmus: what the CUDA (.cu) and HIP (.hip) litmus renders share -- the
   annotation vocabulary, the BellBase accessors, the launch layout and the
   whole-test driver.  Both consume the *parsed* Bell program, NOT the litmus7
   Out template (hetlitmus/docs/cuda-emitter.md, "How it works (and why this
   shape)").  A [t] dialect record carries the per-instruction lowering and
   the differing emitted tokens, so CudaLang and HipLang are thin
   instantiations. *)

open Printf

(* Order / scope vocabulary, one table per instruction kind; the vocabulary's
   home is hetlitmus/bells/ptx.bell. *)

let load_orders = ["relaxed" ; "acquire" ; "sc"]
let store_orders = ["relaxed" ; "release" ; "sc"]
let fence_orders = ["acquire" ; "release" ; "acq_rel" ; "sc"]
let scope_names = ["cta" ; "gpu" ; "sys"]

let is_scope a = List.mem a scope_names

(* Bell annotation list -> (order, scope), total on an admitted instruction:
   check_program refuses every other annotation list. *)
let order_scope_of = function
  | [ord ; scp] -> ord, scp
  | _ -> assert false

(* BellBase accessors *)

(* Test name -> valid C identifier. *)
let c_ident s =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') then c else '_') s

let reg_name = function
  | BellBase.GPRreg i -> sprintf "r%i" i
  | BellBase.Symbolic_reg _ -> assert false

let var_of_reg_or_addr = function
  | BellBase.Abs s -> s
  | BellBase.Rega r -> reg_name r (* address held in register *)

let var_of_addr_op = function
  | BellBase.Addr_op_atom roa -> var_of_reg_or_addr roa
  | BellBase.Addr_op_add (roa, _) -> var_of_reg_or_addr roa

let value_of_roi = function
  | BellBase.Regi r -> reg_name r
  | BellBase.Imm i -> sprintf "%i" i

(* Peel labels to straight-line instructions.  NOT Pseudo.fold_pseudo_code:
   that asserts on a Macro instead of skipping it. *)
let rec instrs_of_pseudo = function
  | BellBase.Instruction i -> [i]
  | BellBase.Label (_, p) -> instrs_of_pseudo p
  | BellBase.Nop | BellBase.Symbolic _ | BellBase.Macro _
  | BellBase.Pagealign | BellBase.Skip _ -> []

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* GPU-column admissibility: the vocabulary hetlitmus/bells/ptx.bell declares,
   checked over a whole program BEFORE anything is written.
   hetlitmus/docs/het-emission.md, "Scope / limits". *)

let symbolic_reg = function
  | BellBase.Symbolic_reg _ -> true
  | BellBase.GPRreg _ -> false

let symbolic_roa = function
  | BellBase.Rega r -> symbolic_reg r
  | BellBase.Abs _ -> false

let symbolic_roi = function
  | BellBase.Regi r -> symbolic_reg r
  | BellBase.Imm _ -> false

let symbolic_addr_op = function
  | BellBase.Addr_op_atom roa -> symbolic_roa roa
  | BellBase.Addr_op_add (roa, roi) -> symbolic_roa roa || symbolic_roi roi

(* One order from this instruction's own set, THEN one scope: a Bell annotation
   group is positional. *)
let annots_admitted orders = function
  | [ord ; scp] -> List.mem ord orders && is_scope scp
  | _ -> false

let check_instr p i =
  let refuse why =
    Warn.user_error "HetLitmus: P%d (gpu) %s -- %s"
      p (BellBase.dump_instruction i) why in
  let check_annots kind orders annots =
    if not (annots_admitted orders annots) then
      refuse
        (sprintf "a %s takes one order from {%s} then one scope from {%s}"
           kind (String.concat "," orders) (String.concat "," scope_names)) in
  let check_regs symbolic =
    if symbolic then
      refuse "the GPU column takes numbered registers r0, r1, ..." in
  match i with
  | BellBase.Pnop -> ()
  | BellBase.Pld (r, ao, annots) ->
      check_annots "load" load_orders annots ;
      check_regs (symbolic_reg r || symbolic_addr_op ao)
  | BellBase.Pst (ao, roi, annots) ->
      check_annots "store" store_orders annots ;
      check_regs (symbolic_addr_op ao || symbolic_roi roi)
  | BellBase.Pfence (BellBase.Fence (annots, _)) ->
      check_annots "fence" fence_orders annots
  | BellBase.Pcall _ | BellBase.Prmw _ | BellBase.Pbranch _ | BellBase.Pmov _ ->
      refuse "the GPU column admits loads, stores and fences only"

let check_program prog =
  List.iter
    (fun ((p, _, _), code) -> List.iter (check_instr p) (instrs_of_code code))
    prog

(* Globals and per-proc result registers *)

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

(* Scope tree -> (proc -> (block,lane)) launch layout: a block is a maximal
   subtree rooted at a `cta' node (hetlitmus/docs/cuda-emitter.md,
   "Mappings"). *)

let rec subtree_procs (BellInfo.Tree (_, ps, ch)) =
  ps @ List.concat_map subtree_procs ch

let rec collect_ctas (BellInfo.Tree (name, _, ch) as t) =
  if name = "cta" then [t]
  else List.concat_map collect_ctas ch

(* The tree the test declared, [None] where it carries no `scopes:' row
   (hetlitmus/docs/het-litmus-format.md sec 3).  Both dispatch arms read it
   from here, so one launch geometry serves both. *)
let scopes_of extra_data =
  let rec find = function
    | MiscParser.BellExtra bi :: _ -> bi.BellInfo.scopes
    | _ :: rest -> find rest
    | [] -> None in
  find extra_data

(* A declared tree places the GPU procs and ONLY them: a proc it leaves out
   would be laid out by the no-tree fallback instead, and a proc it names
   twice would keep whichever placement came last. *)
let check_scopes scopes procs = match scopes with
  | None -> ()
  | Some tree ->
      let named = subtree_procs tree in
      let count p = List.length (List.filter (fun q -> q = p) named) in
      List.iter
        (fun p ->
          if not (List.mem p procs) then
            Warn.user_error
              "HetLitmus: the scopes tree places P%d, which is not a gpu proc"
              p ;
          if count p > 1 then
            Warn.user_error
              "HetLitmus: the scopes tree places P%d %d times" p (count p))
        named ;
      List.iter
        (fun p ->
          if not (List.mem p named) then
            Warn.user_error
              "HetLitmus: the scopes tree places no P%d; a declared tree \
               places every gpu proc" p)
        procs ;
      (* An empty cta is a block with no lane, so the block indices past it
         slide and no lane sits at (0,0). *)
      List.iter
        (fun cta ->
          if subtree_procs cta = [] then
            Warn.user_error
              "HetLitmus: the scopes tree declares a cta with no proc; a \
               declared cta places at least one gpu proc")
        (collect_ctas tree)

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

(* The exists condition, for the emitted banner. *)

let cond_to_string cond =
  let pp_atom =
    ConstrGen.dump_atom
      MiscParser.dump_location MiscParser.dump_location
      (fun v -> ParsedConstant.pp_v v) (fun _ -> "") in
  ConstrGen.constraints_to_string pp_atom cond

(* Slot-addressing context: [Some idx] addresses every access at iteration
   [idx]'s own slot (litmus/het-runtime/het_rdv.h), [None] is the GPU-only
   path's one word per location.  hetlitmus/docs/het-emission.md. *)
type het_ctx = string option

(* The dialect: what the two renders do not share.  Per-target behaviour is
   added as a field here, NEVER as a branch in [dump_test]. *)
type t = {
    gl_kind : string ;          (* banner word: "CUDA" | "HIP" *)
    gl_lang : string ;          (* emitting module: "CudaLang" | "HipLang" *)
    gl_emit_script : string ;   (* the regeneration script named in the banner *)
    gl_group : string ;         (* thread-block word: "CTA" | "workgroup" *)
    gl_include : string ;       (* the differing GPU runtime header *)
    gl_alloc : string -> string -> string ;  (* var, bytes -> checked alloc statement *)
    gl_alloc_def : string ;     (* file-scope allocator the host harness calls *)
    gl_launch : string -> int -> int -> string -> string ;
                                (* c-ident, blocks, block dim, args -> launch *)
    gl_sync : string ;          (* host-side device-sync statement *)
    gl_dump_instr :
      out_channel -> het:het_ctx -> string -> BellBase.instruction -> unit ;
    gl_fence_floor_guard : BellBase.instruction list -> string ;
                                (* target-floor #error the fences demand, or "" *)
  }

(* Whole-test emission *)

let nregs_layout = 4 (* result slots reserved per proc in the out buffer *)

let dump_test d chan tname parsed =
  let prog = parsed.MiscParser.prog in
  let procs = List.map (fun ((p, _, _), _) -> p) prog in
  let nprocs = List.length procs in
  let globals = collect_globals prog in
  let scopes = scopes_of parsed.MiscParser.extra_data in
  let layout, n_blocks, block_dim = layout_of_scopes scopes procs in
  let p fmt = fprintf chan fmt in
  (* Banner *)
  p "// ======================================================================\n" ;
  p "// %s litmus test: %s\n" d.gl_kind tname ;
  p "// Generated by HetLitmus %s from a LISA/Bell scoped test.\n" d.gl_lang ;
  p "// DO NOT EDIT -- regenerate via %s\n" d.gl_emit_script ;
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
  p "// launch: <<<%d, %d>>>  (%d %s(s), %d thread(s)/%s)\n"
    n_blocks block_dim n_blocks d.gl_group block_dim d.gl_group ;
  p "// ======================================================================\n\n" ;
  p "%s\n" d.gl_include ;
  p "#include <cstdio>\n#include <cstdlib>\n\n" ;
  p "%s"
    (d.gl_fence_floor_guard
       (List.concat_map (fun (_, code) -> instrs_of_code code) prog)) ;
  (* Kernel *)
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
      p "  // ---- P%i  (%s %d, lane %d) ----\n" proc d.gl_group blk lane ;
      p "  if (blockIdx.x == %d && threadIdx.x == %d) {\n" blk lane ;
      List.iter (fun n -> p "    int r%i = 0;\n" n) regs ;
      List.iter (fun i -> d.gl_dump_instr chan ~het:None "    " i) instrs ;
      List.iter
        (fun n -> p "    __out[%d * %d + %d] = r%i;\n" proc nregs_layout n n)
        regs ;
      p "  }\n")
    prog ;
  p "}\n\n" ;
  (* Host harness (illustrative) *)
  p "// ---- host harness (illustrative) ----\n" ;
  p "// Result buffer layout: __out[proc * %d + regIndex].\n" nregs_layout ;
  p "// Reset all globals to 0 before each launch; the weak outcome under\n" ;
  p "// test is exactly the `condition' line above.\n" ;
  p "%s\n\n" d.gl_alloc_def ;
  p "int main(void) {\n" ;
  List.iter
    (fun g -> p "  int *%s;   %s\n" g (d.gl_alloc g "sizeof(int)"))
    globals ;
  p "  int *__out; %s\n"
    (d.gl_alloc "__out" (sprintf "sizeof(int) * %d * %d"
                           (max 1 nprocs) nregs_layout)) ;
  p "  for (int it = 0; it < 100000; ++it) {\n" ;
  List.iter (fun g -> p "    *%s = 0;\n" g) globals ;
  p "    %s\n"
    (d.gl_launch (c_ident tname) n_blocks block_dim
       (String.concat ", " (globals @ ["__out"]))) ;
  p "    %s\n" d.gl_sync ;
  p "  }\n" ;
  p "  return 0;\n" ;
  p "}\n" ;
  ()
