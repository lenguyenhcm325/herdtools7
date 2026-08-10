(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetMachine: WHICH SILICON A COMPOUND HARNESS MAY NAME.  A harness is a   *)
(* CPU ISA and a GPU dialect, and the machine it names belongs to THE PAIR: *)
(* an AArch64 host is a Grace only opposite a Hopper, so a dialect-keyed    *)
(* host half would name one on the (X86_64, cuda) emission.  A pair with no *)
(* row here names no machine and emits anyway -- the tool characterizes, so *)
(* the render that claims least is the one that is always correct.          *)
(* Design: hetlitmus/docs/het-emission.md.                                  *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

(* The words and figures ONE machine is entitled to have printed about it.
   Every field below reaches a reader as a #define het_verdict.h prints from,
   so every field is a claim about silicon. *)
type machine = {
    mc_link_name : string ;   (* no leading article: use sites supply their own *)
    mc_host_half : string ;
    mc_dev_half : string ;
    mc_alglave_zero : bool ;  (* the "zero without stress" figure was measured here *)
    mc_llc_mb : int option ;  (* last level a noise buffer must EXCEED, in MB *)
    mc_llc_note : string ;    (* the parenthetical printed after that warning *)
  }

(* The machine a pair may name, and [None] where no row backs one.  A render
   resolving to [None] stamps no machine define at all, so het_verdict.h's
   #ifndef defaults -- which name the mechanism instead of a brand -- stand. *)
type t = machine option

(* The wording [None] prints from before any define exists.  It claims least:
   it names the MECHANISM, never a brand. *)
val generic_machine : machine

(* The pair's machine, and whether the pair is a REGISTERED row.  An
   unregistered pair resolves to [None, false] and one stderr warning at
   [verbose] >= 0; emission then proceeds. *)
val resolve : verbose:int -> cpu_isa:string -> target:string -> t * bool

(* The short (ISA, dialect) label every render stamps as HET_PAIR_NAME. *)
val pair_name : cpu_isa:string -> target:string -> string
