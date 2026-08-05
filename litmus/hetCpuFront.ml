(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetCpuFront: the per-CPU-ISA column frontend the het emitter is closed   *)
(* over (HetEmit.Make's CpuF parameter).  One module per supported CPU ISA, *)
(* holding the ISA label, the host/cross-compilation tokens, the            *)
(* single-column sub-parser and the two tagged-body hooks.  Nothing here    *)
(* mentions the Arch_litmus/Compile_litmus modules: the litmus7 `Het'       *)
(* dispatch arm pairs one of these with the matching module chain after     *)
(* HetArch.scan_cpu_isa has named the ISA.                                  *)
(*                                                                          *)
(* NO ORACLE LIVES HERE.  What a harness predicts belongs to the            *)
(* (CPU ISA x GPU dialect) PAIR, and litmus/hetOracle.ml is the table that  *)
(* keys it: expected-nvidia.csv is Grace(AArch64)+Hopper, expected-amd.csv  *)
(* is Zen-4(x86-64)+CDNA3, and the cells those two rows leave empty are     *)
(* refused or registered as NO-ORACLE rather than filled in from a          *)
(* neighbour.  These modules contribute [isa_name], one coordinate of that  *)
(* key, and nothing else about the model.                                   *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.       *)
(****************************************************************************)

(* Only [debug] is needed: the column sub-parsers drive an ISA lexer, and
   LexUtils.Config is that lexer's whole configuration. *)
module type Config = sig
  val debug : bool
end

module AArch64 (O:Config) = struct
  module Lexer =
    AArch64Lexer.Make (struct include O let is_morello = false end)

  let isa_name = "AArch64"
  let body_module = "hetCpuBody"
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

  (* B3: real tagged AArch64 body.  Cpu.pseudo = AArch64Base.pseudo here, so
     HetCpuBody matches directly after peeling. *)
  let het_analyze ~reg_env pseudos =
    HetCpuBody.analyze ~reg_env (HetCpuBody.instrs_of_code pseudos)
  let het_emit_body ch ~prefix ~proc ~k ~store_mu ~load_buf
        ~reg_env ~iter ~addr_params ~buf_params pseudos =
    HetCpuBody.emit_body ch ~prefix ~proc ~k ~store_mu
      ~load_buf ~reg_env ~iter ~addr_params ~buf_params
      (HetCpuBody.instrs_of_code pseudos)
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

  (* B3: real tagged x86-64 body (P2b).  Cpu.pseudo = X86_64Base.pseudo here,
     so HetCpuBodyX86 matches directly after peeling.  Was a compile-only stub
     until 2026-08-03: an x86 CPU proc emitted a no-op, which both untested the
     CPU thread and left 372 of the 411 x86 renderings unemittable (the
     condition could bind neither a read buffer nor a mu). *)
  let het_analyze ~reg_env pseudos =
    HetCpuBodyX86.analyze ~reg_env (HetCpuBodyX86.instrs_of_code pseudos)
  let het_emit_body ch ~prefix ~proc ~k ~store_mu ~load_buf
        ~reg_env ~iter ~addr_params ~buf_params pseudos =
    HetCpuBodyX86.emit_body ch ~prefix ~proc ~k ~store_mu
      ~load_buf ~reg_env ~iter ~addr_params ~buf_params
      (HetCpuBodyX86.instrs_of_code pseudos)
end
