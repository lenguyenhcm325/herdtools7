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

(* HetLitmus: the condition's location set -- one pure function over a
   MiscParser proposition, telling the emitter which locations a harness reads
   back per iteration. *)

(* The Location_global atoms of a condition, in source order, de-duplicated by
   printed name: one outcome column each.  Register atoms are ignored, so a
   cycle whose condition names no location gives []
   (hetlitmus/docs/corpus-grid.md, "The shape catalogue"). *)
val condition_locations : MiscParser.prop -> MiscParser.maybev list
