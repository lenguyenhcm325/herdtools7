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

(* B6 REPORTING tier -- what a null from this test may be CLAIMED as.  It is NOT
   the mechanism tier and must not be folded back into perpetual_class.

   R and S are both mechanically `Advisory (one ws-location + >= 1 register), but
   they are not equally trustworthy.  S's read is an `rf' read: it observes a real
   writer's tag, which DECODES a synchrony point.  R has ZERO rf edges -- its only
   read is the `fr'-against-init read, and in the WEAK case (the only case we care
   about) that read returns the init value, whose tag is 0: no writer, no
   iteration, no synchrony.  R must therefore borrow BOTH its synchrony point and
   its ws edge from the fragile observer, exactly as 2+2W does, so its full-cycle
   result is reported at the 2+2W floor (B3-decision 4.2, worked against
   Srivastava's Read/Store derivations).

   Resulting tiers over the 338 het tests:
     ROBUST      266   (no ws-location at all)
     ADVISORY     25   (S)
     EXPLORATORY  47   (2+2W 22 + R 25)

   [has_rf_anchor]: does the condition carry at least one read atom whose tested
   value is some store's value -- i.e. a real rf edge the recovery scan can decode?
   This module never sees the program, so the emitter (which holds the store-value
   map) supplies it. *)
val reporting_class : has_rf_anchor:bool -> mechanism_class -> mechanism_class

(* Map a mechanism_class to its C enum constant name (CONF_ROBUST etc.).  The C
   enum itself now lives in het_verdict.h (HetArch.het_verdict_h), next to the
   het_obs_record it labels -- one definition, shared by the harness and the
   verdictcheck unit test. *)
val confidence_c_name : mechanism_class -> string
