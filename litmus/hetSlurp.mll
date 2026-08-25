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

(* HetLitmus: read a bounded lexbuf section into a string.  HetArch re-lexes
   the program section per processor with each column's own sub-architecture
   lexer, so it first slurps the section verbatim
   (hetlitmus/docs/het-litmus-format.md sec 4). *)

{ }

rule slurp buf = parse
| eof    { Buffer.contents buf }
| _ as c { Buffer.add_char buf c ; slurp buf lexbuf }
