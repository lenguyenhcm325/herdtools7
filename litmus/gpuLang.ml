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

open Printf

let load_orders = ["relaxed" ; "acquire" ; "sc"]
let store_orders = ["relaxed" ; "release" ; "sc"]
let fence_orders = ["acquire" ; "release" ; "acqrel" ; "sc"]
let scope_names = ["cta" ; "gpu" ; "sys"]

let is_scope a = List.mem a scope_names

let order_scope_of = function
  | [ord ; scp] -> ord, scp
  | _ -> assert false

let c_ident s =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') then c else '_') s

let reg_name = function
  | BellBase.GPRreg i -> sprintf "r%i" i
  | BellBase.Symbolic_reg _ -> assert false

let var_of_reg_or_addr = function
  | BellBase.Abs s -> s
  | BellBase.Rega r -> reg_name r

let var_of_addr_op = function
  | BellBase.Addr_op_atom roa -> var_of_reg_or_addr roa
  | BellBase.Addr_op_add (roa, _) -> var_of_reg_or_addr roa

let value_of_roi = function
  | BellBase.Regi r -> reg_name r
  | BellBase.Imm i -> sprintf "%i" i

let rec instrs_of_pseudo = function
  | BellBase.Instruction i -> [i]
  | BellBase.Label (_, p) -> instrs_of_pseudo p
  | BellBase.Nop | BellBase.Symbolic _ | BellBase.Macro _
  | BellBase.Pagealign | BellBase.Skip _ -> []

let instrs_of_code code = List.concat_map instrs_of_pseudo code

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

let rec subtree_procs (BellInfo.Tree (_, ps, ch)) =
  ps @ List.concat_map subtree_procs ch

let rec collect_ctas (BellInfo.Tree (name, _, ch) as t) =
  if name = "cta" then [t]
  else List.concat_map collect_ctas ch

let scopes_of extra_data =
  let rec find = function
    | MiscParser.BellExtra bi :: _ -> bi.BellInfo.scopes
    | _ :: rest -> find rest
    | [] -> None in
  find extra_data

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
      List.iter
        (fun cta ->
          if subtree_procs cta = [] then
            Warn.user_error
              "HetLitmus: the scopes tree declares a cta with no proc; a \
               declared cta places at least one gpu proc")
        (collect_ctas tree)

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

let cond_to_string cond =
  let pp_atom =
    ConstrGen.dump_atom
      MiscParser.dump_location MiscParser.dump_location
      (fun v -> ParsedConstant.pp_v v) (fun _ -> "") in
  ConstrGen.constraints_to_string pp_atom cond

type het_ctx = string option

type t = {
    gl_kind : string ;
    gl_lang : string ;
    gl_emit_script : string ;
    gl_group : string ;
    gl_include : string ;
    gl_alloc : string -> string -> string ;
    gl_alloc_def : string ;
    gl_launch : string -> int -> int -> string -> string ;
    gl_sync : string ;
    gl_dump_instr :
      out_channel -> het:het_ctx -> string -> BellBase.instruction -> unit ;
    gl_fence_floor_guard : BellBase.instruction list -> string ;
  }

let nregs_layout = 8

let dump_test d chan tname parsed =
  let prog = parsed.MiscParser.prog in
  let procs = List.map (fun ((p, _, _), _) -> p) prog in
  let nprocs = List.length procs in
  let globals = collect_globals prog in
  let scopes = scopes_of parsed.MiscParser.extra_data in
  let layout, n_blocks, block_dim = layout_of_scopes scopes procs in
  let p fmt = fprintf chan fmt in
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
