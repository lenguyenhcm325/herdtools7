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

(* HetLitmus: the tagged CPU thread body for x86-64, the twin of
   hetCpuBodyA64.  One matcher over the fixed het vocabulary {MOV $imm,(g) |
   MOV (g),%r | MOV %r,(g) | MFENCE|SFENCE|LFENCE}; anything else is refused at
   classification, before a harness directory exists.  Never touches Skel.ml /
   ASMLang.ml / the shared arch backends.  Consumed by top_litmus's HetEmit
   through HetCpuFront.X86_64's het_analyze / het_emit_body hooks; the node
   type, the plan and the C frame are hetCpuPlan's. *)

(* Peel labels/nops off a pseudo list into its straight-line instructions. *)
val instrs_of_code :
  X86_64Base.pseudo list -> X86_64Base.instruction list

(* Resolve one proc's stores/loads into the SHARED plan type the generic
   emitter consumes.  [reg_env] maps an address register name to the global C
   name; the het corpus addresses its globals absolutely (`(x)'), so reg_env is
   consulted only for a zero-offset register deref. *)
val analyze :
  reg_env:(string -> string) -> X86_64Base.instruction list ->
  HetCpuPlan.cpu_plan

(* Emit the tagged het_run_<prefix>P<proc> -- see hetCpuPlan.emit_frame for
   what each label means.  Operands are widened to 64 bits (`movq'); see
   hetCpuPlan for why. *)
val emit_body :
  out_channel -> prefix:string -> proc:int -> k:int -> store_mu:(int -> int) ->
  load_buf:(int -> string) -> reg_env:(string -> string) -> iter:string ->
  addr_params:(string * string) list -> buf_params:(string * string) list ->
  X86_64Base.instruction list -> unit
