(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetCpuPlan: the CPU-ISA-independent half of a tagged CPU thread body --  *)
(* the node list a per-ISA classifier produces, the plan HetEmit consumes,  *)
(* and the C frame both are rendered into.  A node's mnemonic is the one    *)
(* the test's own instruction column names (HetCpuFront's per-ISA           *)
(* sub-parser reads it), reproduced verbatim; only the store value (rebound *)
(* to the runtime tag K*iter+mu) and the load destination (a per-iteration  *)
(* buffer) change.  Every emitted datum is uint64_t so the tag cannot       *)
(* truncate (env-research/decisions/B3-decision.md, Decision 3).            *)
(*                                                                          *)
(* Not ASMLang.dump_fun: litmus7's own lowering bakes a store value as an   *)
(* immediate, leaving no runtime seam for the tag (B3-decision.md,          *)
(* Decision 1); each ISA module carries its own evidence for that.          *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.       *)
(****************************************************************************)

(* One CPU proc's program, classified: one node per source instruction, in
   program order.  A store's mu is keyed on its ORDINAL in this list
   (hetEmit.ml), so the plan below and the C frame further down have to agree
   on which instructions count -- they walk the one list, which is what makes
   them agree by construction instead of by two matchers staying in step.
   [Consumed] is an instruction this ISA's classifier absorbed because it
   performs no memory access and carries no ordering, so removing it removes no
   tested event.  The absorbed set is per-ISA: AArch64 absorbs the immediate
   MOV/MOVZ and refuses NOP, x86 absorbs NOP as well. *)
type node =
  | Store of { mnemonic : string ; global : string ; imm : int option }
  | Load of { mnemonic : string ; global : string ; dest : string }
  | Fence of string
  | Consumed
(* An instruction a classifier cannot map onto one of these nodes is refused,
   not approximated.  HetEmit classifies before it creates the harness
   directory, so the refusal leaves nothing behind; emitting the nearest node
   in the vocabulary instead would ship a body that tests LESS than the test
   says. *)

(* What HetEmit consumes: one proc's store/load structure in program order with
   addresses resolved to their global C name.  Device-agnostic (plain strings
   and ints) so the generic emitter can build the mu map, the read-buffer plan
   and the (loc,value)->mu recovery map. *)
type cpu_plan = {
    (* (address global, the immediate the store's value register still held) *)
    stores : (string * int option) list ;
    (* (address global, the destination register as the CONDITION spells it).
       That register is what binds a condition atom (`1:X0=0') to this load's
       read buffer; each ISA's classifier states how it spells one. *)
    loads : (string * string) list ;
  }

let plan_of_nodes nodes =
  { stores =
      List.filter_map
        (function Store {global;imm;_} -> Some (global,imm) | _ -> None)
        nodes ;
    loads =
      List.filter_map
        (function Load {global;dest;_} -> Some (global,dest) | _ -> None)
        nodes ; }

(* The two one-line renderers an ISA supplies: the asm text of one store and of
   one load.  [idx] is the node's ordinal among stores (resp. loads), naming
   the C temporary `_v<idx>' (resp. `_t<idx>') the frame declared for it. *)
type lowering = {
    store_line : mnemonic:string -> idx:int -> global:string -> string ;
    load_line : mnemonic:string -> idx:int -> global:string -> string ;
  }

(* emit_frame: the tagged het_run_<prefix>P<proc>, everything except the two
   asm operand shapes.  [store_mu]/[load_buf] map a 0-based store/load ordinal
   to its mu and to the C buffer param the load is recorded into; [iter] is the
   C tag-index expression (the caller passes "(_n + 1)", so i=0 stays the
   init/stale marker); [addr_params]/[buf_params] are the (decl,name) lists
   top_litmus also uses for the .cu extern decl and the driver call;
   [prologue] is asm text emitted before the first instruction ("" for none),
   for an assembler directive a mnemonic needs; [prefix] keeps a co-run
   harness' three instances apart -- without it T's P0 and mu(T)'s P0 are both
   `het_run_P0'. *)
let emit_frame chan ~prefix ~proc ~k ~store_mu ~load_buf ~iter
      ~addr_params ~buf_params ~lowering ~prologue nodes =
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
     | Fence _ | Consumed -> ())
    nodes ;
  (* The single asm block: tested mnemonics verbatim, 64-bit operands. *)
  s "  asm __volatile__(\n" ;
  s prologue ;
  let globals_used = ref [] in
  let use_global g =
    if not (List.mem g !globals_used) then globals_used := g :: !globals_used in
  let si = ref 0 and li = ref 0 in
  List.iter
    (function
     | Store {mnemonic;global;_} ->
        use_global global ;
        s (lowering.store_line ~mnemonic ~idx:!si ~global) ;
        incr si
     | Load {mnemonic;global;_} ->
        use_global global ;
        s (lowering.load_line ~mnemonic ~idx:!li ~global) ;
        incr li
     | Fence m -> s (Printf.sprintf "    \"%s\\n\"\n" m)
     | Consumed -> ())
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
