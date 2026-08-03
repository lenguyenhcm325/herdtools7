(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the oracle CSV's PROVENANCE grade (P2d).                      *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

(* The oracle CSV's rows, keyed by test name, carrying only what the harness
   needs at run time: the claim-strength grade.  The VERDICT itself keeps
   coming from the control map (field 2), which is what the emitter already
   parses for mu(T); this module adds the second half of the row that
   PORT2-R2-amd-oracle.md 9.2 requires the printer to switch on. *)
type t

(* Read [csv] from [dir].  [model] is the `Model' string every row must carry;
   a row that carries a different one is a build pointed at the WRONG vendor's
   oracle and is fatal, not a warning.  A missing/unreadable file yields a map
   in which every test is [PROV_UNSET], warned about at [verbose] >= 0. *)
val load :
  verbose:int -> dir:string -> csv:string -> model:string -> src_name:string -> t

(* The claim-strength grade as the C enum name of het_verdict.h.  Full strength
   ("PROV_ARTIFACT") is licensed by exactly one grade; everything recognised
   and weaker is "PROV_CAPPED"; an absent row, an absent Provenance column and
   an unrecognised grade string are all "PROV_UNSET", which the printer treats
   as the WEAKEST claim of the three. *)
val prov_enum : t -> string -> string

(* The grade string to PRINT, so the harness names the grade it was tagged with
   rather than only its enum.  Recognised grades print verbatim; the three
   fail-closed cases print "ABSENT", "NO-COLUMN" or "UNKNOWN:<raw>", so the
   printout says WHICH kind of unset it is. *)
val prov_name : t -> string -> string

(* "<csv>:<model>", or "(no oracle CSV)".  Printed by every harness so a run
   log says which oracle file the harness was tagged from. *)
val source : t -> string

(* Whether the CSV had the 5-column header whose field 4 is `Provenance'.
   Detected, never assumed: expected-nvidia.csv is 4-column and its field 4 is
   free text that happens to contain commas. *)
val has_provenance : t -> bool
