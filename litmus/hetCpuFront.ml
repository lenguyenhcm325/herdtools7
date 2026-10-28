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

type toolchain = {
    isa_name : string ;
    host_macro : string ;
    host_uname : string ;
    cross : string * string ;
    cpu_cflags : string ;
  }

module type Config = sig
  val debug : bool
end

module AArch64 (O:Config) = struct
  module Lexer =
    AArch64Lexer.Make (struct include O let is_morello = false end)

  let toolchain = {
      isa_name = "AArch64" ;
      host_macro = "__aarch64__" ;
      host_uname = "aarch64" ;
      cross = ("aarch64-linux-gnu","gnu11") ;
      (* litmus7 lowers the `ra' acquire read to LDAPR (ARMv8.3), which the
         default -march rejects. *)
      cpu_cflags = "-march=armv8.3-a" ;
    }

  let parse_column p txt =
    let lexbuf = Lexing.from_string txt in
    (try AArch64Parser.instr_option_seq Lexer.token lexbuf
     with
     | Parsing.Parse_error ->
        Warn.user_error
          "HetLitmus: P%d (cpu, AArch64) parse error near offset %d \
           of its instruction column %S"
          p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
     | LexMisc.Error (msg,_) ->
        Warn.user_error
          "HetLitmus: P%d (cpu, AArch64) lexing error: %s (in column %S)"
          p msg txt)
end

module X86_64 (O:Config) = struct
  module Lexer = X86_64Lexer.Make (O)

  let toolchain = {
      isa_name = "X86_64" ;
      host_macro = "__x86_64__" ;
      host_uname = "x86_64" ;
      cross = ("x86_64-linux-gnu","gnu11") ;
      cpu_cflags = "" ;
    }

  let parse_column p txt =
    let lexbuf = Lexing.from_string txt in
    (try X86_64Parser.instr_option_seq Lexer.token lexbuf
     with
     | Parsing.Parse_error ->
        Warn.user_error
          "HetLitmus: P%d (cpu, X86_64) parse error near offset %d \
           of its instruction column %S"
          p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
     | LexMisc.Error (msg,_) ->
        Warn.user_error
          "HetLitmus: P%d (cpu, X86_64) lexing error: %s (in column %S)"
          p msg txt)
end
