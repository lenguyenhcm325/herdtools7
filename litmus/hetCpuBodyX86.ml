(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetCpuBodyX86: the x86-64 twin of hetCpuBody.  Same contract, same       *)
(* emitted C shape, same B3 store-tagging; only the mnemonics and the       *)
(* operand syntax differ (AT&T, memory operand written `(%[g])').           *)
(*                                                                          *)
(* Why a bespoke body here too (B3-decision.md, Decision 1, restated for    *)
(* x86): litmus7's own x86-64 lowering bakes the store value as an          *)
(* immediate -- X86_64Compile_litmus.ml:172-180 builds `movl $1,(x)' from   *)
(* [Operand_immediate] through [compile_op] (`sprintf "$%i"'), so the value  *)
(* never becomes an asm operand and there is no runtime seam for the        *)
(* K*iter+mu tag.  As on AArch64 the fix is to keep litmus7's instruction   *)
(* SELECTION (which mov, which fence, in which order) and rebind only the   *)
(* store value and the load destination.                                    *)
(*                                                                          *)
(* Two deliberate departures from a byte-faithful replay, both inherited    *)
(* from the AArch64 side rather than invented here:                         *)
(*                                                                          *)
(*  1. 64-bit operands (`movq', not the corpus' `movl').  B3-decision.md    *)
(*     Decision 3 widened every het datum to uint64_t so K*iter+mu cannot   *)
(*     overflow; the shared globals ARE uint64_t, and AArch64 widens `%w'   *)
(*     to `%x' for exactly this reason.  Width is not a memory-model        *)
(*     parameter on x86-TSO: an aligned 8-byte MOV is a single access and   *)
(*     is ordered by the same rules as a 4-byte one (SDM Vol.3A 9.2.3       *)
(*     "Memory Ordering" is stated over accesses, not widths).              *)
(*                                                                          *)
(*  2. The value register is dropped.  `movl $1,%eax ; movl %eax,(x)'       *)
(*     becomes one store whose value operand is the tag; the feeding        *)
(*     `mov $imm,%reg' carries no memory access (X86_64Base.get_naccs_rm64  *)
(*     gives Rm64_reg -> 0) so removing it removes no tested event.         *)
(*                                                                          *)
(* x86_64-specific: it pattern-matches X86_64Base.instruction directly      *)
(* (Cpu.instruction = X86_64Base.instruction).  Never touches Skel.ml /     *)
(* ASMLang.ml / the shared arch backends.                                   *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.       *)
(****************************************************************************)

open X86_64Base

(* ------------------------------------------------------------------ *)
(* Peel labels / nops etc. off a pseudo into its straight-line instrs. *)
(* The X86_64Base twin of HetCpuBody.instrs_of_pseudo (both arches get  *)
(* their pseudo type from the same Pseudo.Make functor, so the shape of *)
(* this walk is identical; the constructors are not the same type).     *)
(* ------------------------------------------------------------------ *)

let rec instrs_of_pseudo = function
  | Nop | Symbolic _ | Macro _ | Pagealign | Skip _ -> []
  | Instruction i -> [i]
  | Label (_, p) -> instrs_of_pseudo p

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* Name of a register as the test's CONDITION spells it.  litmus7's x86-64
   frontend parses a condition register with [parse_list64] (X86_64Base.ml:187,
   64-bit names only), so `1:rax' is Ireg (AX,R64b) whatever width the load
   used: `movl (x),%eax' is Ireg (AX,R32b) and must still record "rax".  This
   is the x86 analogue of HetCpuBody's pp_reg/pp_xreg note. *)
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

(* ------------------------------------------------------------------ *)
(* One classification pass, shared by [analyze] and [emit_body].       *)
(*                                                                     *)
(* The AArch64 twin matches instructions twice (once to build the plan, *)
(* once to emit) and relies on the two matchers staying in step, which  *)
(* they must because store_mu is indexed by PROGRAM-ORDER POSITION: a   *)
(* store the plan counts and the body does not (or vice versa) silently *)
(* shifts every later mu.  Here the two consumers walk ONE node list,   *)
(* so they agree by construction.                                       *)
(* ------------------------------------------------------------------ *)

type node =
  | Store of string * int option  (* global, immediate value when known *)
  | Load of string * string       (* global, destination reg ("rax")    *)
  | Fence of string               (* mnemonic, verbatim                 *)
  | SetImm                        (* mov $imm,%reg: consumed, not emitted *)

let nodes_of ~reg_env instrs =
  (* Last immediate MOV'd into each register, keyed by its 64-bit name.  This
     is a *value* memo, so it must be INVALIDATED by anything that redefines
     the register -- otherwise `movl $5,%eax ; movl (x),%eax ; movl %eax,(y)'
     would record the store's value as 5 rather than "unknown", and the
     (loc,value)->mu recovery map HetEmit builds from [analyze] would decode
     that store to the wrong mu.  A load's destination is therefore CLEARED,
     which yields [None] = "value not statically known", the honest answer.
     (Unreachable from today's corpus -- measured over all 411 x86 renderings
     the whole instruction vocabulary is {movl $imm,(g), movl (g),%eax,
     movl (g),%ebx, mfence}, with zero `movl %reg,(g)' -- but the .mli
     advertises `MOV %r,(g)' as supported, so the arm must be correct, not
     merely unexercised.) *)
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
       set_imm r k ; SetImm
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 (Rm64_reg rt),
                Operand_effaddr (Effaddr_rm64 src)) when is_mem src ->
       clr_imm rt ;
       Load (global_of_rm ~reg_env src, reg_name rt)
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 dst,Operand_immediate k) when is_mem dst ->
       Store (global_of_rm ~reg_env dst, Some k)
    | I_EFF_OP (I_MOV,_,Effaddr_rm64 dst,
                Operand_effaddr (Effaddr_rm64 (Rm64_reg rv))) when is_mem dst ->
       Store (global_of_rm ~reg_env dst, get_imm rv)
    (* Spelled as litmus7's own x86-64 lowering spells it: X86_64Base.pp_barrier
       maps MFENCE|SFENCE|LFENCE to their mnemonics, and X86_64Compile_litmus.ml
       emits `{ memo = pp_barrier b }' for I_FENCE.  All three are base x86-64
       (SSE2), so none needs an assembler directive. *)
    | I_FENCE b -> Fence (pp_barrier b)
    | I_NOP -> SetImm
    | i ->
       (* Fail closed.  A CPU proc carrying an instruction outside the het
          vocabulary would otherwise be emitted as a body that tests LESS than
          the test says, which is the failure this module exists to remove. *)
       Warn.fatal
         "hetCpuBodyX86: unsupported CPU instruction %s (het vocabulary is \
          MOV load/store + MFENCE|SFENCE|LFENCE)"
         (dump_instruction i) in
  List.map node instrs

(* ------------------------------------------------------------------ *)
(* analyze: the plan HetEmit consumes for the mu map, the read-buffer  *)
(* plan and the (loc,value)->mu recovery map.                          *)
(* ------------------------------------------------------------------ *)

let analyze ~reg_env instrs =
  let nodes = nodes_of ~reg_env instrs in
  { HetCpuBody.stores =
      List.filter_map (function Store (g,v) -> Some (g,v) | _ -> None) nodes ;
    HetCpuBody.loads =
      List.filter_map (function Load (g,r) -> Some (g,r) | _ -> None) nodes ; }

(* ------------------------------------------------------------------ *)
(* emit_body: the tagged het_run_<prefix>P<proc> function.             *)
(* Argument contract is HetCpuBody.emit_body's, verbatim.              *)
(* ------------------------------------------------------------------ *)

let emit_body chan ~prefix ~proc ~k ~store_mu ~load_buf ~reg_env ~iter
      ~addr_params ~buf_params instrs =
  let nodes = nodes_of ~reg_env instrs in
  let s = output_string chan in
  let params =
    String.concat ", "
      (List.map fst addr_params @ List.map fst buf_params @ ["int _n"]) in
  s (Printf.sprintf "void het_run_%sP%d(%s) {\n" prefix proc params) ;
  (* Tag values + load temps, materialised in C BEFORE the single asm block
     (so the block contains ONLY the tested instructions, in order). *)
  let n_stores = ref 0 and n_loads = ref 0 in
  List.iter
    (function
     | Store _ ->
        let si = !n_stores in incr n_stores ;
        s (Printf.sprintf "  uint64_t _v%d = (uint64_t)%d * %s + %d;\n"
             si k iter (store_mu si))
     | Load _ ->
        let li = !n_loads in incr n_loads ;
        s (Printf.sprintf "  uint64_t _t%d = 0;\n" li)
     | Fence _ | SetImm -> ())
    nodes ;
  (* The single asm block: tested mnemonics verbatim, 64-bit operands. *)
  s "  asm __volatile__(\n" ;
  let globals_used = ref [] in
  let use_global g =
    if not (List.mem g !globals_used) then globals_used := g :: !globals_used in
  let si = ref 0 and li = ref 0 in
  List.iter
    (function
     | Store (g,_) ->
        use_global g ;
        s (Printf.sprintf "    \"movq %%[_v%d],(%%[%s])\\n\"\n" !si g) ;
        incr si
     | Load (g,_) ->
        use_global g ;
        s (Printf.sprintf "    \"movq (%%[%s]),%%[_t%d]\\n\"\n" g !li) ;
        incr li
     | Fence m -> s (Printf.sprintf "    \"%s\\n\"\n" m)
     | SetImm -> ())
    nodes ;
  (* output operands: one per recorded load *)
  let load_outs =
    List.init !n_loads (fun li -> Printf.sprintf "[_t%d]\"=&r\"(_t%d)" li li) in
  s (Printf.sprintf "    : %s\n" (String.concat "," load_outs)) ;
  (* input operands: store-value tags, then each address global once *)
  let store_ins =
    List.init !n_stores (fun si -> Printf.sprintf "[_v%d]\"r\"(_v%d)" si si) in
  let addr_ins =
    List.rev_map (fun g -> Printf.sprintf "[%s]\"r\"(%s)" g g) !globals_used in
  s (Printf.sprintf "    : %s\n" (String.concat "," (store_ins @ addr_ins))) ;
  s "    : \"memory\",\"cc\");\n" ;
  (* record each load into its per-iteration buffer (indexed by _n, the
     0-based loop var; the tag it holds decodes the writer's iteration). *)
  for li = 0 to !n_loads - 1 do
    s (Printf.sprintf "  %s[_n] = _t%d;\n" (load_buf li) li)
  done ;
  s "}\n"
