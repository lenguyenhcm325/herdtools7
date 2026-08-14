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

(* HetLitmus: the AArch64 half of a tagged CPU thread body -- one classifier
   over AArch64Base.instruction (Cpu.instruction = int
   AArch64Base.kinstruction) and the two asm operand shapes, widened to 64-bit
   `%x' registers because the shared globals are uint64_t.  The node type, the
   plan HetEmit consumes and the C frame are hetCpuPlan's; the x86_64 twin is
   hetCpuBodyX86.

   Evidence for the bespoke body (rationale in hetCpuPlan): ASMLang bakes a
   store value in as a `mov #imm' immediate and declares the value register a
   trashed output operand. *)

open AArch64Base

(* Pretty-printer for diagnostics (dump_instruction lives in the MakePP
   sub-functor, not raw AArch64Base; NoMorello matches the litmus CPU arch). *)
module PP = MakePP (struct let is_morello = false end)
let dump_instruction = PP.dump_instruction

(* Peel labels / nops etc. off a pseudo into its straight-line instrs.  Not
   Pseudo.fold_pseudo_code: that one asserts on a Macro rather than skipping
   it.  (GpuLang.instrs_of_pseudo is the Bell twin; kept local so this module
   is self-contained and never depends on the GPU emitters.) *)
let rec instrs_of_pseudo = function
  | Nop | Symbolic _ | Macro _ | Pagealign | Skip _ -> []
  | Instruction i -> [i]
  | Label (_, p) -> instrs_of_pseudo p

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* How AArch64 spells a register here: pp_reg routes integer regs through
   pp_xreg, which matches the "0:X1=x" init convention and is width-agnostic,
   so a `LDAPR W0' destination is recorded as "X0" -- exactly how a condition
   atom names it. *)
let reg_name r = pp_reg r

(* One classification pass, and the only place an AArch64 instruction is
   matched.  [imm] memoises the last immediate MOV'd into each register; it is
   a VALUE memo, so every redefinition of a tracked register must invalidate
   it, or `MOV W0,#5 ; LDR W0,[X1] ; STR W0,[X2]' records the store as writing
   5 and HetEmit's (loc,value)->mu recovery map decodes the wrong mu.  Clearing
   on a load destination is exhaustive here: of the accepted shapes only
   MOV/MOVZ writes a tracked register and only a LDR/LDAR destination redefines
   one, the zero-offset [Xn] form having no base writeback. *)
let nodes_of ~reg_env instrs =
  let imm = Hashtbl.create 8 in
  let set_imm r v = Hashtbl.replace imm (reg_name r) v in
  let clr_imm r = Hashtbl.remove imm (reg_name r) in
  let get_imm r = Hashtbl.find_opt imm (reg_name r) in
  let store mnemonic rval raddr =
    HetCpuPlan.Store
      { mnemonic ; global = reg_env (reg_name raddr) ; imm = get_imm rval } in
  let load mnemonic rt raddr =
    let global = reg_env (reg_name raddr) in
    clr_imm rt ;
    HetCpuPlan.Load { mnemonic ; global ; dest = reg_name rt } in
  let node i = match i with
    | I_MOV (_, r, K k) -> set_imm r k ; HetCpuPlan.Consumed
    | I_MOVZ (_, r, k, S_NOEXT) -> set_imm r k ; HetCpuPlan.Consumed
    (* AArch64Parser.mly:509-519 is the mem_idx rule: only its first form is a
       bare [Xn].  The other four carry an offset (`MUL VL' included) or, for
       PreIdx/PostIdx, also mutate the base register, and neither the plan nor
       the operand shapes below can express any of that. *)
    | I_STR (_, rval, raddr, MemExt.Imm (0, Idx)) -> store "str" rval raddr
    | I_STLR (_, rval, raddr) -> store "stlr" rval raddr
    | I_LDR (_, rt, raddr, MemExt.Imm (0, Idx)) -> load "ldr" rt raddr
    | I_LDAR (_, AA, rt, raddr) -> load "ldar" rt raddr
    | I_LDAR (_, AQ, rt, raddr) -> load "ldapr" rt raddr
    (* Spelled as litmus7's own AArch64 lowering spells them --
       AArch64Compile_litmus.ml:1677 `Misc.lowercase (A.pp_barrier f)' with
       AArch64Base.pp_option mapping (SY,ST) -> "ST" and (SY,LD) -> "LD".
       `DMB ST' orders store->store only and `DMB LD' load->{load,store} only,
       so each is the CPU half of a one-role morally-strong pair (the ARM
       analogue of PTX's fence.release.sys / fence.acquire.sys). *)
    | I_FENCE (DMB (SY, FULL)) -> HetCpuPlan.Fence "dmb sy"
    | I_FENCE (DMB (SY, ST)) -> HetCpuPlan.Fence "dmb st"
    | I_FENCE (DMB (SY, LD)) -> HetCpuPlan.Fence "dmb ld"
    | i ->
       (* Fail closed at classification; hetCpuPlan says why. *)
       Warn.fatal
         "hetCpuBodyA64: unsupported CPU instruction %s (het vocabulary is \
          MOV|MOVZ #imm, STR|STLR|LDR|LDAR|LDAPR at a bare [Xn], \
          DMB SY|ST|LD)"
         (dump_instruction i) in
  List.map node instrs

let analyze ~reg_env instrs =
  HetCpuPlan.plan_of_nodes (nodes_of ~reg_env instrs)

let lowering =
  { HetCpuPlan.store_line =
      (fun ~mnemonic ~idx ~global ->
        Printf.sprintf "    \"%s %%x[_v%d],[%%[%s]]\\n\"\n" mnemonic idx global) ;
    HetCpuPlan.load_line =
      (fun ~mnemonic ~idx ~global ->
        Printf.sprintf "    \"%s %%x[_t%d],[%%[%s]]\\n\"\n" mnemonic idx global) ;
  }

(* LDAPR is RCpc (ARMv8.3); the rest of the het vocabulary
   (str/stlr/ldr/ldar/dmb sy|st|ld) is base ARMv8.0.  The harness compiles with
   no -march/-mcpu override, so RCpc is off and an LDAPR in inline asm does not
   assemble, which would leave every two-sided test unbuildable.  The extension
   is enabled only for a proc that uses it, so a body without LDAPR carries no
   directive. *)
let prologue instrs =
  if List.exists (function I_LDAR (_,AQ,_,_) -> true | _ -> false) instrs then
    "    \".arch_extension rcpc\\n\"\n"
  else ""

let emit_body chan ~prefix ~proc ~k ~store_mu ~load_buf ~reg_env ~iter
      ~addr_params ~buf_params instrs =
  HetCpuPlan.emit_frame chan ~prefix ~proc ~k ~store_mu ~load_buf ~iter
    ~addr_params ~buf_params ~lowering ~prologue:(prologue instrs)
    (nodes_of ~reg_env instrs)
