(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: condition classification helpers (env-research/decisions/      *)
(* taskP-decision.md 7b).  Pure functions over a MiscParser condition        *)
(* proposition, consumed downstream by the observer-buffer set               *)
(* (condition_locations) and by the recovery/tally reporting tiers           *)
(* (perpetual_class + the het_confidence enum).  Tiny and side-effect free;  *)
(* never touches Skel.ml / ASMLang.ml and emits nothing itself.              *)
(****************************************************************************)

(* The Location_global atoms of a condition, in source order, de-duplicated
   by printed name.  Each is the observation of one ws/co (write->write
   coherence-order-external) edge -- exactly the location an observer buffer
   must snoop.  Register atoms are ignored.
   2+2W -> [x; y] ; R -> [y] ; S -> [x] ; every other shape -> []. *)
val condition_locations : MiscParser.prop -> MiscParser.maybev list

(* Mechanism confidence tier.  Mechanism only: R and S are BOTH `Advisory
   here (each carries exactly one ws-location).  The reporting demotion of R's
   full-cycle result to the Exploratory floor is a reporting concern, applied
   by [reporting_class] and not here. *)
type mechanism_class = [ `Robust | `Advisory | `Exploratory ]

(* Robust      : no Location_global atom (all shapes but 2+2W, R, S)
   Advisory    : >= 1 register atom AND exactly 1 ws-location (R, S)
   Exploratory : register-free, all atoms are Location_global (2+2W), and any
                 other unanticipated shape (lowest-confidence floor). *)
val perpetual_class : MiscParser.prop -> mechanism_class

(* Reporting tier -- what a null from this test may be CLAIMED as.  It is not
   the mechanism tier and must not be folded back into perpetual_class.

   R and S are both mechanically `Advisory (one ws-location + >= 1 register)
   but are not equally trustworthy.  S's read is an rf read: it observes a
   real writer's tag, which decodes a synchrony point.  R has no rf edge -- its
   only read is the fr-against-init read, which in the weak case returns the
   init value, whose tag is 0: no writer, no iteration, no synchrony.  R must
   therefore borrow both its synchrony point and its ws edge from the fragile
   observer, exactly as 2+2W does, so its full-cycle result is reported at the
   2+2W floor (taskP-decision.md 0, per B3-decision.md 4.2).  That memo also
   carries the per-tier test counts, which move with the corpus size.

   [has_rf_anchor]: does the condition carry at least one read atom whose tested
   value is some store's value -- i.e. a real rf edge the recovery scan can decode?
   This module never sees the program, so the emitter (which holds the store-value
   map) supplies it. *)
val reporting_class : has_rf_anchor:bool -> mechanism_class -> mechanism_class

(* Map a mechanism_class to its C enum constant name (CONF_ROBUST etc.).  The C
   enum lives in het_verdict.h (HetArch.het_verdict_h) next to the
   het_obs_record it labels -- one definition, shared by the harness and the
   verdictcheck unit test. *)
val confidence_c_name : mechanism_class -> string
