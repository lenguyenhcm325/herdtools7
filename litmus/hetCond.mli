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

(* HetLitmus: condition classification helpers.  Pure functions over a
   MiscParser condition proposition, consumed downstream by the
   observer-buffer set (condition_locations) and by the recovery/tally
   reporting tiers (perpetual_class + the het_confidence enum).  Side-effect
   free; never touches Skel.ml / ASMLang.ml and emits nothing itself.  The
   tiers are described in hetlitmus/docs/positive-control.md sec 6. *)

(* The Location_global atoms of a condition, in source order, de-duplicated
   by printed name.  Each is the observation of one ws/co (write->write
   coherence-order-external) edge -- exactly the location an observer buffer
   must snoop.  Register atoms are ignored.  A shape's cycle contributes one
   entry per `Coe' edge, so 2+2W's two give [x; y] and a cycle carrying none
   gives []. *)
val condition_locations : MiscParser.prop -> MiscParser.maybev list

(* Mechanism confidence tier.  Mechanism only: R and S are BOTH `Advisory
   here (each carries exactly one ws-location).  The reporting demotion of R's
   full-cycle result to the Exploratory floor is a reporting concern, applied
   by [reporting_class] and not here. *)
type mechanism_class = [ `Robust | `Advisory | `Exploratory ]

(* Robust      : no Location_global atom
   Advisory    : >= 1 register atom AND exactly 1 ws-location
   Exploratory : register-free, all atoms are Location_global (2+2W), and any
                 other unanticipated shape (lowest-confidence floor). *)
val perpetual_class : MiscParser.prop -> mechanism_class

(* Reporting tier -- what a null from this test may be claimed as.  R and S are
   mechanically alike, but only S's read is an rf read that decodes a synchrony
   point, so R is reported at the 2+2W floor
   (hetlitmus/docs/positive-control.md sec 6); this is NOT the mechanism tier
   and must not be folded back into perpetual_class.
   [has_rf_anchor]: does the condition carry a read atom whose tested value is
   some store's value, an rf edge the recovery scan can decode?  This module
   never sees the program, so the emitter supplies it. *)
val reporting_class : has_rf_anchor:bool -> mechanism_class -> mechanism_class

(* Map a mechanism_class to its C enum constant name (CONF_ROBUST etc.).  The C
   enum lives in litmus/het-runtime/het_verdict.h next to the het_obs_record it
   labels -- one definition, so the name emitted here cannot drift from the one
   the harness compiles. *)
val confidence_c_name : mechanism_class -> string
