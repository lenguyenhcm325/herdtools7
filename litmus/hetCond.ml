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

(* HetLitmus: the condition's location set and its compilation to a C
   predicate; contract in hetCond.mli. *)

(* fold_prop folds right over And/Or children, so prepending yields source
   order; the de-dup afterwards keeps each name's first occurrence. *)
let condition_locations p =
  let add atom acc =
    match atom with
    | ConstrGen.LV (rloc, _) ->
       (match ConstrGen.loc_of_rloc rloc with
        | MiscParser.Location_global g -> g :: acc
        | MiscParser.Location_reg _ | MiscParser.Location_sreg _ -> acc)
    | ConstrGen.LL _ | ConstrGen.FF _ -> acc in
  let locs = ConstrGen.fold_prop add p [] in
  let seen = Hashtbl.create 8 in
  List.filter
    (fun g ->
      let k = MiscParser.dump_value g in
      if Hashtbl.mem seen k then false else (Hashtbl.add seen k () ; true))
    locs

(* A value as C spells it, and as an int when it is one. *)
let cval v = ParsedConstant.pp_v v
let cint v = int_of_string_opt (ParsedConstant.pp_v v)

(* Folding every connective over constant parts keeps the emitted predicate
   readable, and is what lets a whole condition collapse to "0" or "1".  The
   emitter refuses a constant predicate (hetEmit.ml) by reading that collapse,
   so a connective that does NOT fold hides a constant detector from it. *)
let is_true s =
  s = "1" || (String.length s >= 2 && s.[0]='1' && s.[1]=' ')
let is_false s =
  s = "0" || (String.length s >= 2 && s.[0]='0' && s.[1]=' ')
let mk_and parts =
  if List.exists is_false parts then "0"
  else match List.filter (fun p -> not (is_true p)) parts with
  | [] -> "1"
  | [p] -> p
  | ps -> "(" ^ String.concat " && " ps ^ ")"
let mk_or parts =
  if List.exists is_true parts then "1"
  else match List.filter (fun p -> not (is_false p)) parts with
    | [] -> "0"
    | [p] -> p
    | ps -> "(" ^ String.concat " || " ps ^ ")"
let mk_not e =
  if is_true e then "0" else if is_false e then "1"
  else Printf.sprintf "(!%s)" e
let mk_implies a b =
  if is_false a || is_true b then "1"
  else if is_true a then b
  else Printf.sprintf "(!(%s) || %s)" a b

let predicate_is_constant e = is_true e || is_false e

let c_predicate ~reg_slots ~loc_slots p =
  let n_reg = List.length reg_slots in
  let slot_of_reg pr r =
    let rec f i = function
      | (p,rr)::rest -> if p=pr && rr=r then Some i else f (i+1) rest
      | [] -> None in
    f 0 reg_slots in
  let slot_of_loc name =
    let rec f i = function
      | g::rest -> if g=name then Some (n_reg+i) else f (i+1) rest
      | [] -> None in
    f 0 loc_slots in
  let rec c_slot_of_prop p =
    let open ConstrGen in
    match p with
    | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
       let i = match slot_of_reg pr r with
         | Some i -> i
         | None ->
            Warn.fatal
              "hetlitmus: condition names %d:%s but proc %d makes no \
               such value observable (no read buffer to bind)" pr r pr in
       (match cint v with
        | Some n -> Printf.sprintf "(_o[%d] == %d)" i n
        | None ->
           Warn.fatal
             "hetlitmus: condition value for %d:%s is not an integer"
             pr r)
    | Atom (LV (Loc (MiscParser.Location_global g),v)) ->
       let name = MiscParser.dump_value g in
       let i = match slot_of_loc name with
         | Some i -> i
         | None ->
            Warn.fatal
              "hetlitmus: condition observes [%s]=%s but no proc of \
               this test touches that location (no slot backs it)"
              name (cval v) in
       (match cint v with
        | Some n -> Printf.sprintf "(_o[%d] == %d)" i n
        | None ->
           Warn.fatal
             "hetlitmus: condition value for [%s] is not an integer"
             name)
    | Atom _ ->
       Warn.fatal "hetlitmus: unsupported condition atom (not loc=v)"
    | Not q -> mk_not (c_slot_of_prop q)
    | And ps -> mk_and (List.map c_slot_of_prop ps)
    | Or ps -> mk_or (List.map c_slot_of_prop ps)
    | Implies (a,b) -> mk_implies (c_slot_of_prop a) (c_slot_of_prop b) in
  c_slot_of_prop p
