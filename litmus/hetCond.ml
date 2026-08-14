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

(* HetLitmus: condition classification helpers.  See hetCond.mli for the
   contract. *)

(* Collect the Location_global payloads referenced by the condition's atoms.
   fold_prop uses List.fold_right over And/Or children, so prepending yields
   source order; de-dup afterwards keeps the first occurrence of each name. *)
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

type mechanism_class = [ `Robust | `Advisory | `Exploratory ]

let perpetual_class p =
  let nregs = ref 0 and nlocs = ref 0 in
  ConstrGen.fold_prop
    (fun atom () ->
      match atom with
      | ConstrGen.LV (rloc, _) ->
         (match ConstrGen.loc_of_rloc rloc with
          | MiscParser.Location_global _ -> incr nlocs
          | MiscParser.Location_reg _ | MiscParser.Location_sreg _ -> incr nregs)
      | ConstrGen.LL _ | ConstrGen.FF _ -> ())
    p () ;
  if !nlocs = 0 then `Robust
  else if !nregs >= 1 && !nlocs = 1 then `Advisory
  else `Exploratory

(* The reporting tier is not the mechanism tier: R is demoted here and
   perpetual_class above is left alone.  Why, in hetCond.mli. *)
let reporting_class ~has_rf_anchor m = match m with
  | `Advisory when not has_rf_anchor -> `Exploratory
  | (`Robust | `Advisory | `Exploratory) as c -> c

let confidence_c_name = function
  | `Robust -> "CONF_ROBUST"
  | `Advisory -> "CONF_ADVISORY"
  | `Exploratory -> "CONF_EXPLORATORY"
