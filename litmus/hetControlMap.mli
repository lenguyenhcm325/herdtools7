(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map (hetlitmus/docs/positive-control.md). *)
(****************************************************************************)

(* The control-map.csv rows, keyed by test name. *)
type t

(* Read [csv] from [dir]; a missing or unreadable file yields an empty map,
   warned about at [verbose] >= 0 and named by [src_name].  [csv] is NOT
   hardwired to "control-map.csv": mu(T) is a weakening on a STRENGTH LATTICE
   and the lattice is the CPU column's, so the lane's CPU frontend names the
   file (litmus/hetCpuFront.ml). *)
val load : verbose:int -> dir:string -> csv:string -> src_name:string -> t

(* No row was read: the file was missing, unreadable or empty.  The render
   stamps HET_NO_CONTROL_MAP from this, which is what stops het_verdict.h from
   reading "nothing co-runs" as "this row IS the canary". *)
val is_empty : t -> bool

(* mu(T), the strictly weaker structural sibling to co-run as the positive
   control; None for BOTH sentinels -- "-" (no mu called for) and "none" (no
   Layer-A mutant exists at all).  See the .ml for why the two are distinguished
   by [no_mutant_exists] rather than collapsed. *)
val control_of : t -> string -> string option

(* True on the "none" sentinel: the corpus contains no usable weakening of this
   row, so the harness is canary-only BY DERIVATION and not because the map was
   missing.  The emitter says so out loud; a null from such a test is
   NOT-OBSERVED-CANARY-ONLY by construction. *)
val no_mutant_exists : t -> string -> bool

(* The canary to co-run; None for a `self' row, whose test IS the canary. *)
val canary_of : t -> string -> string option

(* Whether this test is itself the canary. *)
val is_self_canary : t -> string -> bool
