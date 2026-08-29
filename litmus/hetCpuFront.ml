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
   (HetEmit.Make's CpuF parameter) -- the ISA label, the host/cross-compilation
   tokens and the single-column sub-parser, one module per ISA.  Nothing here
   names an Arch_litmus/Compile_litmus module: the litmus7 `Het' arm pairs one
   of these with the matching chain once scan_cpu_isa has named the ISA.
   hetlitmus/docs/het-emission.md, "CPU ISA from the device tag". *)

(* The CPU toolchain facts an emitted harness carries: the ISA label, the two
   host-detection tokens, the cross-assembly pair and the CPU compile flags.
   Each ISA module below provides one; the file emitters read it. *)
type toolchain = {
    isa_name : string ;
    host_macro : string ;          (* CPP macro true on the CPU host ISA *)
    host_uname : string ;          (* `uname -m' on a host of this ISA *)
    (* (clang triple, -std) cross-assembling the CPU asm off that host
       (hetlitmus/docs/het-emission.md,
       "The CPU object: native vs. cross-assembly"). *)
    cross : string * string ;
    cpu_cflags : string ;
  }

(* The column sub-parsers drive an ISA lexer, whose whole config is [debug]. *)
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
      (* litmus7 lowers a two-sided test's acquire read to LDAPR, which is
         ARMv8.3 RCpc and the assembler's default base architecture rejects;
         upstream's mechanism is a compile flag (litmus/libdir/armv8.3.cfg). *)
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
      (* litmus7 lowers this corpus into base AMD64; no extension flag is
         owed. *)
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
