(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus (Task P, decisions/taskP-decision.md 7b): condition            *)
(* classification helpers.  Pure functions over a MiscParser condition      *)
(* proposition, consumed by the downstream het tasks:                       *)
(*   - B3 (observer-buffer set)  via condition_locations                    *)
(*   - B6 (recovery/tally + reporting tiers) via perpetual_class + the      *)
(*     het_confidence enum.                                                  *)
(* This module is deliberately tiny and side-effect free; it never touches  *)
(* Skel.ml / ASMLang.ml and does not emit anything itself.                  *)
(****************************************************************************)

(* The Location_global atoms of a condition, in source order, de-duplicated
   by printed name.  Each is the observation of one ws/co (write->write
   coherence-order-external) edge -- i.e. exactly the location an observer
   buffer must snoop (taskP 0, 2.2).  Register atoms are ignored.
   2+2W -> [x; y] ; R -> [y] ; S -> [x] ; the 266 pure-register tests -> []. *)
val condition_locations : MiscParser.prop -> MiscParser.maybev list

(* Mechanism confidence tier (taskP 0 table).  This is the *mechanism*
   classifier only: R and S are BOTH `Advisory here (each carries exactly one
   ws-location).  The B6 reporting demotion of R's full-cycle result to the
   EXPLORATORY floor is a reporting concern and is NOT applied here. *)
type mechanism_class = [ `Robust | `Advisory | `Exploratory ]

(* Robust      : no Location_global atom                    (266 pure-register)
   Advisory    : >= 1 register atom AND exactly 1 ws-location (R / S, 50)
   Exploratory : register-free, all atoms are Location_global (2+2W, 22),
                 and any other unanticipated shape (lowest-confidence floor). *)
val perpetual_class : MiscParser.prop -> mechanism_class

(* The C enum introduced for B6's het_obs_record.confidence field.  P-fix only
   *introduces* it here; B6 owns emitting it alongside het_obs_record. *)
val het_confidence_enum_c : string

(* Map a mechanism_class to its C enum constant name (CONF_ROBUST etc.). *)
val confidence_c_name : mechanism_class -> string
