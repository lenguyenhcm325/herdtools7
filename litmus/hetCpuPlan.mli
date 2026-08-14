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

(* HetLitmus: the CPU-ISA-independent half of a tagged CPU thread body,
   shared by hetCpuBodyA64 and hetCpuBodyX86.  What every name below means is
   stated once, at its definition in hetCpuPlan.ml. *)

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
