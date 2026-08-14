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

(* HetLitmus: a single-arch test rendered as device-neutral string fragments,
   so that a heterogeneous driver (gen/hetGen.ml) can merge per-proc columns
   taken from two single-arch runs (one per device) into one `Het` test.
   Strings, not arch-typed values, are the erasure boundary that lets the
   AArch64 and LISA builders -- two different `A` modules -- be combined.
   Design: hetlitmus/docs/het-generation.md. *)
type t = {
  (* Initial state atoms with their owning proc: (Some p,"0:X1=x") is proc-p's,
     (None,"x=0") is a global.  No trailing ';'. *)
  hc_init : (int option * string) list ;
  (* Per proc: (proc index, instruction-cell strings in that arch's syntax). *)
  hc_cols : (int * string list) list ;
  (* The whole final condition, e.g. "exists (1:r0=1 /\\ 1:r1=0)". *)
  hc_cond : string ;
}
