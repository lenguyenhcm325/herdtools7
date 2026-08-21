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
   the ISA label, the host/cross-compilation tokens, the single-column
   sub-parser and the two tagged-body hooks.  Nothing here mentions the
   Arch_litmus/Compile_litmus modules: the litmus7 `Het' dispatch arm pairs one
   of these with the matching module chain after HetArch.scan_cpu_isa has named
   the ISA.

   No machine lives here.  Which silicon a harness may name belongs to the
   (CPU ISA x GPU dialect) pair (litmus/hetMachine.ml); these modules
   contribute [isa_name], one coordinate of that key. *)

(* Only [debug] is needed: the column sub-parsers drive an ISA lexer, and
   LexUtils.Config is that lexer's whole configuration. *)
module type Config = sig
  val debug : bool
end

module AArch64 (O:Config) = struct
  module Lexer =
    AArch64Lexer.Make (struct include O let is_morello = false end)

  let isa_name = "AArch64"
  let body_module = "hetCpuBodyA64"
  let host_macro = "__aarch64__"
  let cross = Some ("aarch64-linux-gnu","gnu11")

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

  (* Cpu.pseudo = AArch64Base.pseudo here, so HetCpuBodyA64 matches directly
     after peeling. *)
  let het_analyze ~reg_env pseudos =
    HetCpuBodyA64.analyze ~reg_env (HetCpuBodyA64.instrs_of_code pseudos)
  let het_emit_body ch ~proc ~k ~store_mu ~load_buf
        ~reg_env ~iter ~addr_params ~buf_params pseudos =
    HetCpuBodyA64.emit_body ch ~proc ~k ~store_mu
      ~load_buf ~reg_env ~iter ~addr_params ~buf_params
      (HetCpuBodyA64.instrs_of_code pseudos)
end

module X86_64 (O:Config) = struct
  module Lexer = X86_64Lexer.Make (O)

  let isa_name = "X86_64"
  let body_module = "hetCpuBodyX86"
  let host_macro = "__x86_64__"
  let cross = None

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

  (* Cpu.pseudo = X86_64Base.pseudo here, so HetCpuBodyX86 matches directly
     after peeling.  A CPU proc that emitted no body would leave the CPU thread
     untested and most x86 renderings unemittable, because the condition could
     bind neither a read buffer nor a mu. *)
  let het_analyze ~reg_env pseudos =
    HetCpuBodyX86.analyze ~reg_env (HetCpuBodyX86.instrs_of_code pseudos)
  let het_emit_body ch ~proc ~k ~store_mu ~load_buf
        ~reg_env ~iter ~addr_params ~buf_params pseudos =
    HetCpuBodyX86.emit_body ch ~proc ~k ~store_mu
      ~load_buf ~reg_env ~iter ~addr_params ~buf_params
      (HetCpuBodyX86.instrs_of_code pseudos)
end
