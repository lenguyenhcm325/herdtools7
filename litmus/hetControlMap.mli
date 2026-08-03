(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map (hetlitmus/docs/positive-control.md). *)
(****************************************************************************)

(* The control-map.csv rows, keyed by test name. *)
type t

(* Read [csv] from [dir]; a missing or unreadable file yields an empty map,
   warned about at [verbose] >= 0 and named by [src_name].  [csv] is NOT
   hardwired to "control-map.csv": the x86 lattice has its own map
   (control-map-amd.csv), because on x86 the CPU strength lattice loses its
   middle rung and a mu(T) derived on the AArch64 lattice is not a weakening
   there (memo PORT2-R2 7.D11).  The lane's CPU frontend names the file. *)
val load : verbose:int -> dir:string -> csv:string -> src_name:string -> t

(* mu(T), the Allowed grid neighbour to co-run as the positive control; None
   for BOTH sentinels -- "-" (no mu called for) and "none" (a Disallowed row
   for which no Layer-A mutant exists at all).  See the .ml for why the two are
   distinguished by [no_mutant_exists] rather than collapsed. *)
val control_of : t -> string -> string option

(* True on the "none" sentinel: this row IS Disallowed and the corpus contains
   no usable weakening of it, so the harness is canary-only BY DERIVATION and
   not because the map was missing.  The emitter says so out loud; a null from
   such a test is a WEAK-NULL by construction. *)
val no_mutant_exists : t -> string -> bool

(* The canary to co-run; None for a `self' row, whose test IS the canary. *)
val canary_of : t -> string -> string option

(* The oracle class as the C enum name of het_verdict.h; a test with no row
   yields "ORACLE_UNSET", which het_verdict() fails closed on. *)
val oracle_of : t -> string -> string

(* Whether this test is itself the canary. *)
val is_self_canary : t -> string -> bool
