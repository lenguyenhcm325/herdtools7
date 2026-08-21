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

(* HetLitmus: the x86-64 half of a tagged CPU thread body -- one classifier
   over X86_64Base.instruction (= Cpu.instruction here) and the two asm operand
   shapes (AT&T, memory operand `(%[g])').  The node type, the plan HetEmit
   consumes and the C frame are hetCpuPlan's; the AArch64 twin is
   hetCpuBodyA64.

   Evidence for the bespoke body (rationale in hetCpuPlan):
   X86_64Compile_litmus.ml's [move] builds `movl $1,(x)' from
   [Operand_immediate] through [compile_op], so the store value never becomes
   an asm operand.  Widening to `movq' costs nothing here: an aligned 8-byte
   access is atomic [IntelSDM 9.1.1] and the ordering rules are stated over
   reads and writes, not over widths [IntelSDM 9.2.2]. *)

open X86_64Base

(* ------------------------------------------------------------------ *)
(* Peel labels / nops etc. off a pseudo into its straight-line instrs. *)
(* The X86_64Base twin of HetCpuBodyA64.instrs_of_pseudo (both arches   *)
(* get their pseudo type from the same Pseudo.Make functor, so the      *)
(* shape of this walk is identical; the constructors are not the same   *)
(* type).                                                               *)
(* ------------------------------------------------------------------ *)

let rec instrs_of_pseudo = function
  | Nop | Symbolic _ | Macro _ | Pagealign | Skip _ -> []
  | Instruction i -> [i]
  | Label (_, p) -> instrs_of_pseudo p

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* Name of a register as the test's CONDITION spells it.  litmus7's x86-64
   frontend parses a condition register through X86_64Base.parse_reg, whose
   [parse_list64] holds 64-bit names only, so `1:rax' is Ireg (AX,R64b)
   whatever width the load used: `movl (x),%eax' is Ireg (AX,R32b) and must
   still record "rax". *)
let reg_name = function
  | Ireg (b,_) -> reg64_string b
  | r -> pp_reg r

(* Is this effective address a MEMORY operand?  Rm64_reg is a register operand
   and performs no access (X86_64Base.get_naccs_rm64). *)
let is_mem = function
  | Rm64_reg _ -> false
  | Rm64_abs _ | Rm64_deref _ | Rm64_scaled _ -> true

(* The global C name behind a memory operand.  `(x)' parses to Rm64_abs
   (X86_64Parser.mly `LPAR NAME RPAR'), which is how the whole het corpus
   addresses its shared locations; Rm64_deref is accepted at offset 0 so a
   register-held address still resolves through [reg_env] exactly as on
   AArch64.  Anything else is refused rather than guessed at. *)
let global_of_rm ~reg_env = function
  | Rm64_abs v -> pp_abs v
  | Rm64_deref (r,0) -> reg_env (reg_name r)
  | rm ->
     Warn.fatal
       "hetCpuBodyX86: unsupported memory operand %s (het vocabulary is a \
        bare global `(x)' or a zero-offset register deref)"
       (dump_instruction (I_EFF_OP (I_MOV,I64b,Effaddr_rm64 rm,
                                    Operand_immediate 0)))

(* One classification pass, and the only place an x86-64 instruction is
   matched.  [imm] memoises the last immediate MOV'd into each register, keyed
   by its 64-bit name; it is a VALUE memo, so every redefinition of a tracked
   register must invalidate it, or `movl $5,%eax ; movl (x),%eax ;
   movl %eax,(y)' records the store's value as 5 and the (loc,value)->mu
   recovery map decodes the wrong mu.  A load's destination is therefore
   cleared, yielding [None] = "value not statically known" -- an arm the
   corpus renderings never reach, but one the .mli advertises. *)
let nodes_of ~reg_env instrs =
  let imm = Hashtbl.create 8 in
  let set_imm r v = Hashtbl.replace imm (reg_name r) v in
  let clr_imm r = Hashtbl.remove imm (reg_name r) in
  let get_imm r = Hashtbl.find_opt imm (reg_name r) in
  let node i = match i with
    (* X86_64Parser.mly:147 `I_MOV operand COMMA effaddr' -> I_EFF_OP (I_MOV,
       sz, $4, $2): the EFFADDR is the destination and the OPERAND is the
       source, i.e. AT&T order.  The four arms below are exactly the four
       (dest,src) shapes a MOV can take. *)
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 (Rm64_reg r),Operand_immediate k) ->
       set_imm r k ; HetCpuPlan.Consumed
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 (Rm64_reg rt),
                Operand_effaddr (Effaddr_rm64 src)) when is_mem src ->
       clr_imm rt ;
       HetCpuPlan.Load { mnemonic = "movq" ;
                         global = global_of_rm ~reg_env src ;
                         dest = reg_name rt }
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 dst,Operand_immediate k) when is_mem dst ->
       HetCpuPlan.Store { mnemonic = "movq" ;
                          global = global_of_rm ~reg_env dst ; imm = Some k }
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 dst,
                Operand_effaddr (Effaddr_rm64 (Rm64_reg rv))) when is_mem dst ->
       HetCpuPlan.Store { mnemonic = "movq" ;
                          global = global_of_rm ~reg_env dst ; imm = get_imm rv }
    (* Spelled as litmus7's own x86-64 lowering spells it: X86_64Base.pp_barrier
       maps MFENCE|SFENCE|LFENCE to their mnemonics, and X86_64Compile_litmus.ml
       emits `{ memo = pp_barrier b }' for I_FENCE.  All three are base x86-64
       (SSE2), so none needs an assembler directive. *)
    | I_FENCE b -> HetCpuPlan.Fence (pp_barrier b)
    | I_NOP -> HetCpuPlan.Consumed
    | i ->
       (* Fail closed at classification; hetCpuPlan says why. *)
       Warn.fatal
         "hetCpuBodyX86: unsupported CPU instruction %s (het vocabulary is \
          MOV load/store + MFENCE|SFENCE|LFENCE)"
         (dump_instruction i) in
  List.map node instrs

let analyze ~reg_env instrs =
  HetCpuPlan.plan_of_nodes (nodes_of ~reg_env instrs)

let lowering =
  { HetCpuPlan.store_line =
      (fun ~mnemonic ~idx ~global ->
        Printf.sprintf "    \"%s %%[_v%d],(%%[%s])\\n\"\n" mnemonic idx global) ;
    HetCpuPlan.load_line =
      (fun ~mnemonic ~idx ~global ->
        Printf.sprintf "    \"%s (%%[%s]),%%[_t%d]\\n\"\n" mnemonic global idx) ;
  }

let emit_body chan ~proc ~k ~store_mu ~load_buf ~reg_env ~iter
      ~addr_params ~buf_params instrs =
  HetCpuPlan.emit_frame chan ~proc ~k ~store_mu ~load_buf ~iter
    ~addr_params ~buf_params ~lowering ~prologue:""
    (nodes_of ~reg_env instrs)
