(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map (hetlitmus/docs/positive-control.md). *)
(****************************************************************************)

(* The control-map rows, keyed by test name. *)
type t

(* Read [csv] from [dir].  [None] = the file was not there, warned about at
   [verbose] >= 0 and named by [src_name]; the render stamps HET_NO_CONTROL_MAP
   from that, which is what stops het_verdict.h from reading "nothing co-runs"
   as "this row IS the canary".  A file that IS there but does not open with the
   6-column header, or holds a row of another arity, is a Warn.user_error: its
   columns do not mean what this reader would read them as, and a mis-bound map
   names controls that are not controls.
   [csv] is NOT hardwired: mu(T) is a weakening on a STRENGTH LATTICE and the
   lattice is the CPU column's, so the lane's CPU frontend names the file
   (litmus/hetCpuFront.ml). *)
val load : verbose:int -> dir:string -> csv:string -> src_name:string -> t option

(* Each reader takes the [load] result directly, so a lane with no map behaves
   as a lane whose rows name nothing -- the distinction lives in the [None] the
   caller already holds, not in a second copy of it here. *)

(* mu(T), the lattice-floor structural sibling to co-run as the positive
   control; None on the `none' sentinel and where no map was read. *)
val control_of : t option -> string -> string option

(* Whether the map read carries a row for this test at all.  A map that covers
   the corpus except this one test would leave it co-running nothing, silently,
   which is the failure the whole layer exists to prevent -- so the emitter
   refuses instead, and the two reasons a harness can name no mu(T) stay exactly
   two: no map beside the test, or the test is at the lattice floor. *)
val has_row : t option -> string -> bool

(* True on the `none' sentinel: this test is itself at the lattice floor, so no
   strictly weaker structural sibling can exist and the harness is canary-only
   BY DERIVATION rather than because the map was missing.  The emitter says so
   out loud; a null from such a test is NOT-OBSERVED-CANARY-ONLY by
   construction. *)
val at_lattice_floor : t option -> string -> bool

(* The canary to co-run; None for a `self' row, whose test IS the canary. *)
val canary_of : t option -> string -> string option

(* Whether this test is itself the canary. *)
val is_self_canary : t option -> string -> bool
