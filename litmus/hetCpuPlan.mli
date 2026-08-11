(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the CPU-ISA-independent half of a tagged CPU thread body,     *)
(* shared by hetCpuBodyA64 and hetCpuBodyX86.  What every name below means  *)
(* is stated once, at its definition in hetCpuPlan.ml.                      *)
(****************************************************************************)

type node =
  | Store of { mnemonic : string ; global : string ; imm : int option }
  | Load of { mnemonic : string ; global : string ; dest : string }
  | Fence of string
  | Consumed

type cpu_plan = {
    stores : (string * int option) list ;
    loads : (string * string) list ;
  }

val plan_of_nodes : node list -> cpu_plan

type lowering = {
    store_line : mnemonic:string -> idx:int -> global:string -> string ;
    load_line : mnemonic:string -> idx:int -> global:string -> string ;
  }

val emit_frame :
  out_channel -> prefix:string -> proc:int -> k:int -> store_mu:(int -> int) ->
  load_buf:(int -> string) -> iter:string ->
  addr_params:(string * string) list -> buf_params:(string * string) list ->
  lowering:lowering -> prologue:string -> node list -> unit
