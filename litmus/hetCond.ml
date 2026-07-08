(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus (Task P, decisions/taskP-decision.md 7b): condition            *)
(* classification helpers.  See hetCond.mli for the contract.               *)
(****************************************************************************)

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
  if !nlocs = 0 then `Robust                          (* 266 pure-register    *)
  else if !nregs >= 1 && !nlocs = 1 then `Advisory    (* R / S: one ws-location *)
  else `Exploratory                                   (* 2+2W + any other shape *)

let het_confidence_enum_c =
  "typedef enum { CONF_ROBUST, CONF_ADVISORY, CONF_EXPLORATORY } het_confidence;"

let confidence_c_name = function
  | `Robust -> "CONF_ROBUST"
  | `Advisory -> "CONF_ADVISORY"
  | `Exploratory -> "CONF_EXPLORATORY"
