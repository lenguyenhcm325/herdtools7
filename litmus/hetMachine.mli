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
    (* THIS MACHINE'S OWN WORDS, by the name of the hole each one fills.  A
       dialect payload (litmus/het-runtime/*.inc) is pasted into the render
       verbatim except for its `@NAME@' holes, and the emitted README and
       comp.sh are written with the same holes, so one row spells the machine
       everywhere a reader meets it.  A payload sentence therefore cannot reach
       a reader naming silicon its pair has no row for: the hole is filled from
       the row that resolved, and a hole no row owns REFUSES the emission. *)
    mc_words : (string * string) list ;
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

(* One word of [mc_words], and [None] where this machine has none.  "PART" is
   the one hole [generic_machine] deliberately lacks, so this is how a site asks
   "may this render name a part at all?". *)
val word : machine -> string -> string option

(* Every `@NAME@' hole of a payload or an emitted sentence, filled from this
   machine.  A hole the machine has no word for is a [Warn.user_error], which
   the emitter turns into a refusal: an unfilled hole must never be emitted. *)
val fill : machine -> string -> string
