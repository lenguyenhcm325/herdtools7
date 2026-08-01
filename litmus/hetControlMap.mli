(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map (hetlitmus/docs/positive-control.md). *)
(****************************************************************************)

(* The control-map.csv rows, keyed by test name. *)
type t

(* Read control-map.csv from [dir]; a missing or unreadable file yields an
   empty map, warned about at [verbose] >= 0 and named by [src_name]. *)
val load : verbose:int -> dir:string -> src_name:string -> t

(* mu(T), the Allowed grid neighbour to co-run as the positive control; None
   where the row names none. *)
val control_of : t -> string -> string option

(* The canary to co-run; None for a `self' row, whose test IS the canary. *)
val canary_of : t -> string -> string option

(* The oracle class as the C enum name of het_verdict.h; a test with no row
   yields "ORACLE_UNSET", which het_verdict() fails closed on. *)
val oracle_of : t -> string -> string

(* Whether this test is itself the canary. *)
val is_self_canary : t -> string -> bool
