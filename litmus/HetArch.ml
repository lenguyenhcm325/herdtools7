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

(* HetLitmus: the compound pseudo-architecture.  herdtools7 assumes ONE ISA per
   test, so this functor sums the two backends' instruction types (CPUins /
   GPUins) and delegates per constructor, keeping the rest of the pipeline
   single-arch-typed.  Scope here is representation + parse; cross-device
   emission is litmus/hetEmit.ml and the file emitters it drives.
   hetlitmus/docs/het-litmus-format.md. *)

(* The CPU-ISA tag vocabulary (hetlitmus/docs/het-litmus-format.md sec 3).
   Top-level, outside the functor: the litmus7 `Het' arm picks the CPU ISA --
   and so which modules to feed the functor -- before any application exists.
   None for a GPU tag, so parse_device reuses this as the CPU/GPU test. *)
type cpu_isa = IsaAArch64 | IsaX86_64

let cpu_isa_of_tag s = match String.lowercase_ascii (String.trim s) with
  | "cpu" | "aarch64" | "arm" -> Some IsaAArch64
  | "x86_64" | "x86-64" | "amd64" | "x64" -> Some IsaX86_64
  | _ -> None

let cpu_isa_tag = function IsaAArch64 -> "aarch64" | IsaX86_64 -> "x86_64"

(* Pre-scan the program header for the ONE CPU ISA its CPU columns share: the
   first CPU column's, AArch64 where the test has no CPU column. *)
let scan_cpu_isa prog_text =
  let is_blank s = String.trim s = "" in
  let rows =
    List.filter (fun r -> not (is_blank r))
      (String.split_on_char ';' prog_text) in
  match rows with
  | [] -> IsaAArch64
  | header :: _ ->
     let cells = String.split_on_char '|' header in
     let tag_of cell =
       match String.split_on_char ':' (String.trim cell) with
       | [_;d] -> String.trim d
       | _ -> "" in
     let rec first = function
       | [] -> IsaAArch64
       | cell :: rest ->
          (match cpu_isa_of_tag (tag_of cell) with
           | Some isa -> isa
           | None -> first rest) in
     first cells

(* The pre-scan's input.  The splitter reports only the section's byte span, so
   re-read it from the file: the scan runs before any parser exists. *)
let prog_section_text splitted name =
  let (_,prog_loc,_,_) = splitted.Splitter.locs in
  let (p1,p2) = prog_loc in
  let a = p1.Lexing.pos_cnum and b = p2.Lexing.pos_cnum in
  let ic = open_in_bin name in
  let len = max 0 (b - a) in
  seek_in ic a ;
  let txt = really_input_string ic len in
  close_in ic ; txt

(* Fail-closed refusal, the exit every het emission boundary takes: a het test
   that emitted nothing must NOT report success.
   hetlitmus/docs/het-emission.md, "Scope / limits". *)
let refused what name e =
  let msg = match e with
    | Misc.Fatal msg | Misc.UserError msg -> msg
    | Misc.Exit -> "aborted without emitting anything"
    | e -> Printf.sprintf "exception %s" (Printexc.to_string e) in
  Printf.eprintf "HetLitmus REFUSED (%s) %s: %s\n%!" what name msg ;
  exit 3

module Make (Cpu:Arch_litmus.S) (Gpu:Arch_litmus.S) = struct

  let arch = `Het
  let base_type = Cpu.base_type

  (* Sum types *)

  type reg = CPUreg of Cpu.reg | GPUreg of Gpu.reg
  type barrier = CPUbar of Cpu.barrier | GPUbar of Gpu.barrier
  type instruction = CPUins of Cpu.instruction | GPUins of Gpu.instruction
  type parsedInstruction =
    | CPUpins of Cpu.parsedInstruction
    | GPUpins of Gpu.parsedInstruction

  (* Registers *)

  let parse_reg s = match Cpu.parse_reg s with
    | Some r -> Some (CPUreg r)
    | None ->
       begin match Gpu.parse_reg s with
       | Some r -> Some (GPUreg r)
       | None -> None
       end

  let pp_reg = function CPUreg r -> Cpu.pp_reg r | GPUreg r -> Gpu.pp_reg r

  let reg_compare r1 r2 = match r1,r2 with
    | CPUreg r1,CPUreg r2 -> Cpu.reg_compare r1 r2
    | GPUreg r1,GPUreg r2 -> Gpu.reg_compare r1 r2
    | CPUreg _,GPUreg _ -> -1
    | GPUreg _,CPUreg _ -> 1

  let symb_reg_name = function
    | CPUreg r -> Cpu.symb_reg_name r
    | GPUreg r -> Gpu.symb_reg_name r

  (* Reachable only from symbolic-register allocation in the emitter; the
     parser's registers arrive device-tagged.  Default to the CPU. *)
  let symb_reg s = CPUreg (Cpu.symb_reg s)

  let type_reg = function
    | CPUreg r -> Cpu.type_reg r
    | GPUreg r -> Gpu.type_reg r

  let allowed_for_symb =
    List.map (fun r -> CPUreg r) Cpu.allowed_for_symb
    @ List.map (fun r -> GPUreg r) Gpu.allowed_for_symb

  (* Barriers *)

  let pp_barrier = function
    | CPUbar b -> Cpu.pp_barrier b
    | GPUbar b -> Gpu.pp_barrier b

  let barrier_compare b1 b2 = match b1,b2 with
    | CPUbar b1,CPUbar b2 -> Cpu.barrier_compare b1 b2
    | GPUbar b1,GPUbar b2 -> Gpu.barrier_compare b1 b2
    | CPUbar _,GPUbar _ -> -1
    | GPUbar _,CPUbar _ -> 1

  (* Instructions *)

  (* No canonical device-agnostic nop / immediate branch for the compound arch. *)
  let nop = None
  let mk_imm_branch _ = None

  let is_nop = function CPUins i -> Cpu.is_nop i | GPUins i -> Gpu.is_nop i

  let pp_instruction m = function
    | CPUins i -> Cpu.pp_instruction m i
    | GPUins i -> Gpu.pp_instruction m i

  let dump_instruction = function
    | CPUins i -> Cpu.dump_instruction i
    | GPUins i -> Gpu.dump_instruction i

  let dump_instruction_hash = function
    | CPUins i -> Cpu.dump_instruction_hash i
    | GPUins i -> Gpu.dump_instruction_hash i

  (* Register / address traversals *)

  let fold_regs (freg,fsymb) acc = function
    | CPUins i ->
       Cpu.fold_regs ((fun r a -> freg (CPUreg r) a),fsymb) acc i
    | GPUins i ->
       Gpu.fold_regs ((fun r a -> freg (GPUreg r) a),fsymb) acc i

  (* A register belongs to exactly one processor, so the cross-device arms are
     unreachable for a well-formed test. *)
  let map_regs freg fsymb = function
    | CPUins i ->
       CPUins
         (Cpu.map_regs
            (fun r -> match freg (CPUreg r) with CPUreg r -> r | GPUreg _ -> r)
            (fun s -> match fsymb s with CPUreg r -> r | GPUreg _ -> Cpu.symb_reg s)
            i)
    | GPUins i ->
       GPUins
         (Gpu.map_regs
            (fun r -> match freg (GPUreg r) with GPUreg r -> r | CPUreg _ -> r)
            (fun s -> match fsymb s with GPUreg r -> r | CPUreg _ -> Gpu.symb_reg s)
            i)

  let fold_addrs f acc = function
    | CPUins i -> Cpu.fold_addrs f acc i
    | GPUins i -> Gpu.fold_addrs f acc i

  let map_addrs f = function
    | CPUins i -> CPUins (Cpu.map_addrs f i)
    | GPUins i -> GPUins (Gpu.map_addrs f i)

  (* InstrUtils.S *)

  let norm_ins = function
    | CPUins i -> CPUins (Cpu.norm_ins i)
    | GPUins i -> GPUins (Gpu.norm_ins i)

  let is_valid = function
    | CPUins i -> Cpu.is_valid i
    | GPUins i -> Gpu.is_valid i

  let get_exported_label = function
    | CPUins i -> Cpu.get_exported_label i
    | GPUins i -> Gpu.get_exported_label i

  (* Pseudo layer.
     Pseudo.Make over the instruction-level delegates, each routing to a
     sub-architecture's own Pseudo.S output; parsed_tr recovers a sub-arch's
     parsed->internal translation by round-tripping a singleton [Instruction].
     hetlitmus/docs/het-litmus-format.md sec 4. *)

  include Pseudo.Make (struct
    type ins = instruction
    type pins = parsedInstruction
    type reg_arg = reg

    let parsed_tr = function
      | CPUpins p ->
         CPUins
           (match Cpu.pseudo_parsed_tr (Cpu.Instruction p) with
            | Cpu.Instruction i -> i
            | _ -> assert false)
      | GPUpins p ->
         GPUins
           (match Gpu.pseudo_parsed_tr (Gpu.Instruction p) with
            | Gpu.Instruction i -> i
            | _ -> assert false)

    let get_naccesses = function
      | CPUins i -> Cpu.get_naccesses [Cpu.Instruction i]
      | GPUins i -> Gpu.get_naccesses [Gpu.Instruction i]

    let size_of_ins = function
      | CPUins i -> Cpu.size_of_ins i
      | GPUins i -> Gpu.size_of_ins i

    let fold_labels acc f = function
      | CPUins i -> Cpu.fold_labels f acc (Cpu.Instruction i)
      | GPUins i -> Gpu.fold_labels f acc (Gpu.Instruction i)

    let map_labels f = function
      | CPUins i -> CPUins (Cpu.map_labels_base f i)
      | GPUins i -> GPUins (Gpu.map_labels_base f i)
  end)

  (* Arch-specific assembler conveniences; the het corpus uses none. *)
  let get_macro name =
    fun _ _ -> Warn.fatal "HetArch: macro %s is unsupported in heterogeneous tests" name

  let hash_pteval p = Cpu.hash_pteval p

  (* Parser support.
     of_{cpu,gpu}_parsed tag a sub-arch's parsed pseudo into the compound one;
     the structural skeleton is device-agnostic.  The per-processor sub-parsing
     lives at the litmus7 `Het' arm, where the concrete parsers are in scope.
     hetlitmus/docs/het-litmus-format.md sec 4. *)

  let rec of_cpu_parsed : Cpu.parsedPseudo -> parsedPseudo = function
    | Cpu.Nop -> Nop
    | Cpu.Instruction i -> Instruction (CPUpins i)
    | Cpu.Label (l,k) -> Label (l,of_cpu_parsed k)
    | Cpu.Macro (s,rs) -> Macro (s,List.map (fun r -> CPUreg r) rs)
    | Cpu.Symbolic s -> Symbolic s
    | Cpu.Pagealign -> Pagealign
    | Cpu.Skip n -> Skip n

  let rec of_gpu_parsed : Gpu.parsedPseudo -> parsedPseudo = function
    | Gpu.Nop -> Nop
    | Gpu.Instruction i -> Instruction (GPUpins i)
    | Gpu.Label (l,k) -> Label (l,of_gpu_parsed k)
    | Gpu.Macro (s,rs) -> Macro (s,List.map (fun r -> GPUreg r) rs)
    | Gpu.Symbolic s -> Symbolic s
    | Gpu.Pagealign -> Pagealign
    | Gpu.Skip n -> Skip n

  (* Emission support.
     to_{cpu,gpu}_pseudo project one processor's column back onto its native
     sub-architecture, so it can be fed to that backend's own compiler/emitter.
     The cross-device arms are unreachable for a well-formed test -- the parser
     tagged every cell with its column's device -- and fail loudly. *)

  let cpu_reg_of = function
    | CPUreg r -> r
    | GPUreg _ -> Warn.fatal "HetArch: GPU register on a CPU processor"
  let gpu_reg_of = function
    | GPUreg r -> r
    | CPUreg _ -> Warn.fatal "HetArch: CPU register on a GPU processor"

  let rec to_cpu_pseudo : pseudo -> Cpu.pseudo = function
    | Nop -> Cpu.Nop
    | Instruction (CPUins i) -> Cpu.Instruction i
    | Instruction (GPUins _) ->
       Warn.fatal "HetArch: a GPU instruction appears on a CPU processor"
    | Label (l,k) -> Cpu.Label (l,to_cpu_pseudo k)
    | Macro (s,rs) -> Cpu.Macro (s,List.map cpu_reg_of rs)
    | Symbolic s -> Cpu.Symbolic s
    | Pagealign -> Cpu.Pagealign
    | Skip n -> Cpu.Skip n

  let rec to_gpu_pseudo : pseudo -> Gpu.pseudo = function
    | Nop -> Gpu.Nop
    | Instruction (GPUins i) -> Gpu.Instruction i
    | Instruction (CPUins _) ->
       Warn.fatal "HetArch: a CPU instruction appears on a GPU processor"
    | Label (l,k) -> Gpu.Label (l,to_gpu_pseudo k)
    | Macro (s,rs) -> Gpu.Macro (s,List.map gpu_reg_of rs)
    | Symbolic s -> Gpu.Symbolic s
    | Pagealign -> Gpu.Pagealign
    | Skip n -> Gpu.Skip n

  type device = DevCpu | DevGpu

  let device_tag = function DevCpu -> "cpu" | DevGpu -> "gpu"

  (* Device class only.  Which CPU ISA a tag names is cpu_isa_of_tag's, so the
     litmus7 `Het' arm can pick it before this functor is applied. *)
  let parse_device s =
    match cpu_isa_of_tag s with
    | Some _ -> DevCpu
    | None ->
       begin match String.lowercase_ascii (String.trim s) with
       | "gpu" | "lisa" | "ptx" | "hip" -> DevGpu
       | d ->
          Warn.user_error
            "HetArch: unknown device tag %S (use aarch64|x86_64|cpu|gpu)" d
       end

  (* "P0:cpu" -> (0, DevCpu); hetlitmus/docs/het-litmus-format.md sec 3. *)
  let parse_proc_cell s =
    let s = String.trim s in
    match String.split_on_char ':' s with
    | [p;d] ->
       let p = String.trim p in
       let p =
         if String.length p > 0 && (p.[0] = 'P' || p.[0] = 'p')
         then String.sub p 1 (String.length p-1)
         else p in
       begin
         try (int_of_string (String.trim p),parse_device d)
         with Failure _ ->
           Warn.user_error "HetArch: cannot read processor number in %S" s
       end
    | _ ->
       Warn.user_error
         "HetArch: every processor needs a device tag, e.g. P0:cpu (got %S)" s

  let het_parser ~cpu ~gpu _lexer lexbuf =
    let text = HetSlurp.slurp (Buffer.create 256) lexbuf in
    let is_blank s = String.trim s = "" in
    (* A `scopes:' tree sits in the program section and HetSlurp pulls it in;
       carrying no `;', it would survive as a spurious trailing row.  Drop it:
       nothing here consumes it (hetlitmus/docs/het-generation.md sec 4). *)
    let is_scopes s =
      let t = String.trim s in
      String.length t >= 7 && String.sub t 0 7 = "scopes:" in
    let rows =
      List.filter (fun r -> not (is_blank r) && not (is_scopes r))
        (String.split_on_char ';' text) in
    match rows with
    | [] -> Warn.user_error "HetArch: empty heterogeneous program"
    | header::instr_rows ->
       let procs_dev = List.map parse_proc_cell (String.split_on_char '|' header) in
       let nprocs = List.length procs_dev in
       let row_cells =
         List.map
           (fun r ->
             let cells = String.split_on_char '|' r in
             if List.length cells <> nprocs then
               Warn.user_error
                 "HetArch: program row %S has %d cells but there are %d procs"
                 r (List.length cells) nprocs ;
             cells)
           instr_rows in
       let columns =
         List.init nprocs
           (fun j -> List.map (fun cells -> List.nth cells j) row_cells) in
       let parsed_columns =
         List.map2
           (fun (p,dev) col ->
             let txt = String.concat " ; " col in
             (* the proc number rides along so a malformed cell names its proc *)
             match dev with DevCpu -> cpu p txt | DevGpu -> gpu p txt)
           procs_dev columns in
       (* genParser transposes rows -> columns again, so hand it rows *)
       let prog_rows =
         match instr_rows with [] -> [] | _ -> Misc.transpose parsed_columns in
       let procs =
         List.map
           (fun (p,dev) -> (p,Some [device_tag dev],MiscParser.Main))
           procs_dev in
       (procs,prog_rows,MiscParser.empty_extra)
end
