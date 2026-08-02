(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetCpuBody: emit one CPU proc of a heterogeneous litmus test as a single *)
(* asm __volatile__ block.  The mnemonics litmus7 selected and their order   *)
(* are reproduced verbatim (str/stlr/ldr/ldar/ldapr/dmb sy|st|ld); only two  *)
(* things change: each store value is rebound to a runtime tag operand       *)
(* K*iter+mu, and each load is redirected into a per-iteration buffer.       *)
(*                                                                          *)
(* Not ASMLang.dump_fun: ASMLang bakes a store value as a `mov #imm'         *)
(* immediate and declares the value register a trashed output operand, so    *)
(* there is no runtime seam for the tag short of rewriting the shared        *)
(* AArch64 lowering (env-research/decisions/B3-decision.md, Decision 1).     *)
(*                                                                          *)
(* AArch64-specific: it pattern-matches AArch64Base.instruction directly     *)
(* (Cpu.instruction = int AArch64Base.kinstruction).  The x86_64 twin is     *)
(* hetCpuBodyX86, which shares [cpu_plan] and emits the same C shape from    *)
(* X86_64Base instructions.  Never touches Skel.ml / ASMLang.ml / the shared *)
(* arch backends.                                                            *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.       *)
(****************************************************************************)

open AArch64Base

(* Pretty-printer for diagnostics (dump_instruction lives in the MakePP
   sub-functor, not raw AArch64Base; NoMorello matches the litmus CPU arch). *)
module PP = MakePP (struct let is_morello = false end)
let dump_instruction = PP.dump_instruction

(* ------------------------------------------------------------------ *)
(* Plan: the store/load structure of one CPU proc, in program order,  *)
(* with address globals resolved.  Device-agnostic (plain strings /   *)
(* ints) so the generic HetEmit functor can consume it for the mu map,*)
(* the read-buffer plan and the (loc,value)->mu recovery map.         *)
(* ------------------------------------------------------------------ *)

type cpu_plan = {
    (* one entry per tagged store node, program order:
       (address global, original immediate value if a `mov #imm' fed it) *)
    stores : (string * int option) list ;
    (* one entry per recorded load node, program order:
       (address global, destination register under pp_reg -- "X0").  The reg
       is how the recovery scan maps a condition atom `1:X0=0' back to THIS
       load's read buffer; pp_reg is width-agnostic, so `LDAPR W0' records
       "X0", exactly how the condition names it. *)
    loads : (string * string) list ;
  }

(* Peel labels / nops etc. off a pseudo into its straight-line instrs.  Not
   Pseudo.fold_pseudo_code: that one asserts on a Macro rather than skipping
   it.  (GpuLang.instrs_of_pseudo is the Bell twin; kept local so this module
   is self-contained and never depends on the GPU emitters.) *)
let rec instrs_of_pseudo = function
  | Nop | Symbolic _ | Macro _ | Pagealign | Skip _ -> []
  | Instruction i -> [i]
  | Label (_, p) -> instrs_of_pseudo p

let instrs_of_code code = List.concat_map instrs_of_pseudo code

(* Name of the (X-)register that holds an address, as it appears in the
   test's init map (e.g. "X1").  pp_reg routes integer regs through
   pp_xreg, matching the "0:X1=x" init convention (verified on the emitted
   corpus). *)
let addr_reg_name r = pp_reg r

(* The mnemonic litmus7 selected for this store node, reproduced verbatim and
   widened to 64-bit `%x' operands (B3-decision.md, Decision 3); the
   release/plain distinction (stlr vs str) is preserved exactly. *)
let store_mnemonic = function
  | I_STR _ -> "str"
  | I_STLR _ -> "stlr"
  | i ->
     Warn.fatal
       "hetCpuBody: unsupported CPU store %s (het vocabulary is STR|STLR)"
       (dump_instruction i)

let load_mnemonic = function
  | I_LDR _ -> "ldr"
  | I_LDAR (_, AA, _, _) -> "ldar"
  | I_LDAR (_, AQ, _, _) -> "ldapr"
  | i ->
     Warn.fatal
       "hetCpuBody: unsupported CPU load %s (het vocabulary is LDR|LDAR|LDAPR)"
       (dump_instruction i)

(* ------------------------------------------------------------------ *)
(* analyze: walk one proc's instrs, resolving each store/load's global *)
(* via [reg_env] (addr-reg-name -> global C name) and each store's     *)
(* original immediate via the last `mov #imm' into its value register. *)
(* ------------------------------------------------------------------ *)

let analyze ~reg_env instrs =
  (* last immediate MOV'd into each register, keyed by pp name *)
  let imm = Hashtbl.create 8 in
  let set_imm r v = Hashtbl.replace imm (pp_reg r) v in
  let get_imm r = Hashtbl.find_opt imm (pp_reg r) in
  let stores = ref [] and loads = ref [] in
  List.iter
    (fun i -> match i with
      | I_MOV (_, r, K k) -> set_imm r k
      | I_MOVZ (_, r, k, S_NOEXT) -> set_imm r k
      | I_STR (_, rval, raddr, _) | I_STLR (_, rval, raddr) ->
         let g = reg_env (addr_reg_name raddr) in
         stores := (g, get_imm rval) :: !stores
      | I_LDR (_, rt, raddr, _) | I_LDAR (_, _, rt, raddr) ->
         let g = reg_env (addr_reg_name raddr) in
         loads := (g, pp_reg rt) :: !loads
      | _ -> ())
    instrs ;
  { stores = List.rev !stores ; loads = List.rev !loads }

(* ------------------------------------------------------------------ *)
(* emit_body: the tagged het_run_P<proc> function.                     *)
(* ------------------------------------------------------------------ *)

(* store_mu   : 0-based store index (program order) -> its mu             *)
(* load_buf   : 0-based load  index -> the C buffer param name to record  *)
(* reg_env    : addr-reg-name -> global C name (the C pointer param)      *)
(* iter       : the C loop-index expression used inside the tag; the      *)
(*              caller passes "(_n + 1)" so tag iterations start at 1 and *)
(*              i=0 stays the init/stale marker (B3-decision.md, 3).      *)
(* addr_params/buf_params : (decl, name) for the het_run signature -- the *)
(*              same lists top_litmus uses for the .cu extern decl + call.*)
let emit_body chan ~prefix ~proc ~k ~store_mu ~load_buf ~reg_env ~iter
      ~addr_params ~buf_params instrs =
  let s = output_string chan in
  let params =
    String.concat ", "
      (List.map fst addr_params @ List.map fst buf_params @ ["int _n"]) in
  s (Printf.sprintf "void het_run_%sP%d(%s) {\n" prefix proc params) ;
  (* Tag values + load temps, materialised in C BEFORE the single asm block
     (so the block contains ONLY the tested instructions, in order). *)
  let n_stores = ref 0 and n_loads = ref 0 in
  let store_idx = Hashtbl.create 8 and load_idx = Hashtbl.create 8 in
  List.iteri
    (fun pos i -> match i with
      | I_STR _ | I_STLR _ ->
         let si = !n_stores in incr n_stores ;
         Hashtbl.replace store_idx pos si ;
         s (Printf.sprintf "  uint64_t _v%d = (uint64_t)%d * %s + %d;\n"
              si k iter (store_mu si))
      | I_LDR _ | I_LDAR _ ->
         let li = !n_loads in incr n_loads ;
         Hashtbl.replace load_idx pos li ;
         s (Printf.sprintf "  uint64_t _t%d = 0;\n" li)
      | _ -> ())
    instrs ;
  (* The single asm block: tested mnemonics verbatim, 64-bit operands. *)
  s "  asm __volatile__(\n" ;
  (* LDAPR is RCpc (ARMv8.3); the rest of the het vocabulary
     (str/stlr/ldr/ldar/dmb sy|st|ld) is base ARMv8.0.  The harness compiles
     with no -march/-mcpu override, so RCpc is off and an LDAPR in inline asm
     fails to assemble ("instruction requires: rcpc"), which would make every
     two-sided test unbuildable.  Enable the extension only for a proc that
     uses it, so a plain-LDR body stays byte-identical. *)
  if List.exists (function I_LDAR (_,AQ,_,_) -> true | _ -> false) instrs then
    s "    \".arch_extension rcpc\\n\"\n" ;
  let globals_used = ref [] in
  let use_global g =
    if not (List.mem g !globals_used) then globals_used := g :: !globals_used in
  List.iteri
    (fun pos i -> match i with
      | I_STR (_, _, raddr, _) | I_STLR (_, _, raddr) ->
         let si = Hashtbl.find store_idx pos in
         let g = reg_env (addr_reg_name raddr) in
         use_global g ;
         s (Printf.sprintf "    \"%s %%x[_v%d],[%%[%s]]\\n\"\n"
              (store_mnemonic i) si g)
      | I_LDR (_, _, raddr, _) | I_LDAR (_, _, _, raddr) ->
         let li = Hashtbl.find load_idx pos in
         let g = reg_env (addr_reg_name raddr) in
         use_global g ;
         s (Printf.sprintf "    \"%s %%x[_t%d],[%%[%s]]\\n\"\n"
              (load_mnemonic i) li g)
      | I_FENCE (DMB (SY, FULL)) | I_FENCE (DSB (SY, FULL)) ->
         s "    \"dmb sy\\n\"\n"
      (* The partial system barriers: `DMB ST' orders store->store only and
         `DMB LD' load->{load,store} only, so each is the CPU half of a
         one-role morally-strong pair (the ARM analogue of PTX's
         fence.release.sys / fence.acquire.sys).  Spelled as litmus7's own
         AArch64 lowering spells them -- AArch64Compile_litmus.ml:1677
         `Misc.lowercase (A.pp_barrier f)' with AArch64Base.pp_option mapping
         (SY,ST) -> "ST" and (SY,LD) -> "LD". *)
      | I_FENCE (DMB (SY, ST)) ->
         s "    \"dmb st\\n\"\n"
      | I_FENCE (DMB (SY, LD)) ->
         s "    \"dmb ld\\n\"\n"
      | I_FENCE _ as i ->
         Warn.fatal "hetCpuBody: unsupported CPU fence %s (het vocabulary is DMB SY|ST|LD)"
           (dump_instruction i)
      | I_MOV _ | I_MOVZ _ -> ()   (* dropped: value now comes from the tag operand *)
      | _ ->
         Warn.fatal "hetCpuBody: unsupported CPU instruction %s"
           (dump_instruction i))
    instrs ;
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
