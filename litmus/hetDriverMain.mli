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

(* HetLitmus: the emitted driver's main() -- allocation, launch, the run loop,
   the slot readout and teardown -- written in one GPU dialect.
   Design: hetlitmus/docs/het-emission.md. *)

(* Write the main() that closes a render, in that render's dialect.  The phase
   functions the run loop is sequenced from are the file's own. *)
val dump : HetHarness.t -> HetDialect.gpu_dialect -> out_channel -> unit
