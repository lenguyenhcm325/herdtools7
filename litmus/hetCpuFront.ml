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

(* HetLitmus: the per-CPU-ISA column frontend the het emitter is closed over
   (HetEmit.Make's CpuF parameter).  One module per supported CPU ISA, holding
   the ISA label, the host/cross-compilation tokens and the single-column
   sub-parser.  Nothing here mentions the Arch_litmus/Compile_litmus modules:
   the litmus7 `Het' dispatch arm pairs one of these with the matching module
   chain after HetArch.scan_cpu_isa has named the ISA.

   No machine lives here: a harness names none.  These modules contribute
   [isa_name], one coordinate of the pair stamped as HET_PAIR_NAME. *)

(* Only [debug] is needed: the column sub-parsers drive an ISA lexer, and
   LexUtils.Config is that lexer's whole configuration. *)
module type Config = sig
  val debug : bool
end

module AArch64 (O:Config) = struct
  module Lexer =
    AArch64Lexer.Make (struct include O let is_morello = false end)

  let isa_name = "AArch64"
  let host_macro = "__aarch64__"
  let cross = Some ("aarch64-linux-gnu","gnu11")
  (* LDAPR is RCpc, an ARMv8.3 extension, and litmus7 lowers a `-2s' test's
     acquire read to it; the base architecture the assembler defaults to does
     not accept one.  Upstream's own mechanism for that is a compile flag
     (litmus/libdir/armv8.3.cfg: ccopts = -O2 -march=armv8.3-a), so the emitted
     build files carry it on every compilation of <t>_cpu.c. *)
  let cpu_cflags = "-march=armv8.3-a"

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

  let isa_name = "X86_64"
  let host_macro = "__x86_64__"
  let cross = None
  (* The x86_64 vocabulary litmus7 lowers this corpus into is base AMD64, so
     no extension flag is owed. *)
  let cpu_cflags = ""

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
