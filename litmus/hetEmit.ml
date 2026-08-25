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

(* HetLitmus: the compound (CPU+GPU) harness emitter.
   Design: hetlitmus/docs/het-emission.md. *)

open Answer

open HetDialect

module type Config = sig
  include GenParser.Config
  val size : int
  val runs : int
end

  module Make
      (Cfg : Config)
      (O : sig
         val verbose : int
         val nocatch : bool
         val is_out : bool
         val tarname : string
         val check_rename : string -> string option
       end)
      (Cpu : Arch_litmus.S)
      (CpuF : sig
         val parse_column : int -> string -> Cpu.parsedPseudo list
         val isa_name : string
         val host_macro : string       (* CPP macro true on the CPU host ISA *)
         (* (clang triple, -std) cross-assembling the CPU asm; None for
            x86_64 (hetlitmus/docs/het-emission.md,
            "The CPU object: native vs. cross-assembly"). *)
         val cross : (string * string) option
         val cpu_cflags : string
       end)
      (CpuKit : sig
         val compile_code :
           Name.t ->
           (Cpu.location, Cpu.V.v, Cpu.pseudo, Cpu.FaultType.t) MiscParser.r3 ->
           (string * CType.t) list
           * (Proc.t * (Cpu.Out.t * ((Cpu.reg * CType.t) list * string list)))
               list
         val dump_fun :
           out_channel -> Template.extra_args -> (string * CType.t) list ->
           string list -> Proc.t -> Cpu.Out.t -> unit
       end) =
    struct
      (* GPU side is fixed: LISA/Bell frontend + CudaLang/HipLang lowering. *)
      module GpuInstr = Instr.No(struct type instr = BellBase.instruction end)
      module GpuV = Int64Constant.Make(GpuInstr)
      module Gpu = LISAArch_litmus.Make(GpuV)
      module Arch' = HetArch.Make(Cpu)(Gpu)
      module LexConfig = struct
        let debug = O.verbose > 2
        let check_rename = O.check_rename
      end
      module GpuLexer = BellLexer.Make(LexConfig)

      let parse_cpu p txt = List.map Arch'.of_cpu_parsed (CpuF.parse_column p txt)
      let parse_gpu p txt =
        let lexbuf = Lexing.from_string txt in
        (try
           List.map Arch'.of_gpu_parsed
             (LISAParser.instr_option_seq GpuLexer.token lexbuf)
         with
         | Parsing.Parse_error ->
            Warn.user_error
              "HetLitmus: P%d (gpu, LISA/Bell) parse error near offset %d \
               of its instruction column %S"
              p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
         | LexMisc.Error (msg,_) ->
            Warn.user_error
              "HetLitmus: P%d (gpu, LISA/Bell) lexing error: %s (in column %S)"
              p msg txt)

      module LexParse = struct
          type instruction = Arch'.parsedPseudo
          type token = unit
          let lexer = fun _ -> ()
          let parser = Arch'.het_parser ~cpu:parse_cpu ~gpu:parse_gpu
        end
      module P = GenParser.Make(Cfg)(Arch')(LexParse)

      module AllocArchCpu = struct
          include Cpu
          type v = Cpu.V.v
          let maybevToV = Cpu.maybevToV
          type global = Global_litmus.t
          let maybevToGlobal = Cpu.tr_global
        end
      module AllocCpu = SymbReg.Make(AllocArchCpu)

      (* Verbatim payloads: litmus/libdir/_outs.{h,c} and litmus/het-runtime/*.h. *)
      let outs_h_content = HetPayloads.outs_h
      let outs_c_content = HetPayloads.outs_c
      let het_stress_content = HetPayloads.het_stress_h
      let het_cpu_stress_content = HetPayloads.het_cpu_stress_h
      let het_verdict_content = HetPayloads.het_verdict_h
      let het_rdv_content = HetPayloads.het_rdv_h

      type dev = [ `Cpu | `Gpu ]

      (* Plain strings and a printer: no arch-polymorphic type in the record. *)
      type cpu_proc = {
          cp_proc : int ;
          cp_addrs : (string * string) list ;  (* address params, ASMLang order *)
          cp_outs : (string * string) list ;   (* one pointer per final register *)
          cp_dump : out_channel -> unit ;
        }

      (* [gp_blk] is the proc's block index in the launched grid. *)
      type gpu_proc = {
          gp_proc : int ;
          gp_blk : int ; gp_lane : int ;
          gp_instrs : BellBase.instruction list ;
          gp_regs : int list ;
        }

      type inst = {
          i_cpus : cpu_proc list ;
          i_gpus : gpu_proc list ;
          i_gpu_globals : string list ;
          i_all_globals : string list ;
          i_bdim : int ;
          i_npart : int ;                (* cpu procs + gpu procs *)
          i_blocks : int ;               (* GPU test blocks *)
          i_lanes : int ;                (* GPU test lanes *)
          (* read buffers: (proc, index, name, device, element type) *)
          i_bufs : (int * int * string * dev * string) list ;
          i_readout : string ;           (* the whole pre-rendered slot readout *)
          i_labels : string ;            (* _labels + _dump_one *)
          i_nslots : int ;
        }

      (* Naming helpers, shared by derive and the emitters *)
      let buf_name_of p li = Printf.sprintf "bufP%d_%d" p li
      (* 1 iff that participant's rendezvous reached its target on iteration n. *)
      let rdv_gpu_name p = Printf.sprintf "_rdvG_P%d" p
      let rdv_cpu_name p = Printf.sprintf "_rdvC_P%d" p

      let run _hash_env src_name in_chan _out_chan splitted =
        try
          let dialects = HetDialect.select ~key:(fun d -> d.gd_target) dialects in
          let parsed = P.parse in_chan splitted in
          close_in in_chan ;
          let tname = splitted.Splitter.name.Name.name in
          let doc = splitted.Splitter.name in
          let nprocs_total = List.length parsed.MiscParser.prog in
          let cpu_only =
            parsed.MiscParser.prog <> [] &&
            List.for_all
              (fun ((_,annot,_),_) ->
                match annot with Some ("cpu"::_) -> true | _ -> false)
              parsed.MiscParser.prog in
          (* The (CPU ISA x GPU dialect) pair this harness is built for. *)
          let pair_label =
            Printf.sprintf "(%s, %s)"
              CpuF.isa_name (List.hd dialects).gd_target in
          (* Derive the harness shape from the parsed het test *)
          let it =
            (* Classify processors by device tag *)
            let dev_of_proc p =
              let rec find = function
                | ((q,annot,_),_)::_ when q=p ->
                   (match annot with Some (d::_) -> d | _ -> "?")
                | _::rest -> find rest
                | [] -> "?" in
              find parsed.MiscParser.prog in
            let is_cpu p = dev_of_proc p = "cpu" in
            (* CPU-only projection -> compile -> templates *)
            let cpu_prog =
              List.filter_map
                (fun ((p,annot,f),code) -> match annot with
                  | Some ("cpu"::_) ->
                     Some ((p,annot,f),List.map Arch'.to_cpu_pseudo code)
                  | _ -> None)
                parsed.MiscParser.prog in
            let cpu_init =
              List.filter
                (fun (loc,_) -> match loc with
                  | MiscParser.Location_reg (p,_) -> is_cpu p
                  | _ -> true)
                parsed.MiscParser.init in
            let prop_of = function
              | ConstrGen.ForallStates p | ConstrGen.ExistsState p
              | ConstrGen.NotExistsState p -> p in
            let rec filt_cpu p =
              let open ConstrGen in
              match p with
              | Atom (LV (Loc (MiscParser.Location_reg (pr,_)),_)) ->
                 if is_cpu pr then Some p else None
              | Atom _ -> None
              | Not q -> (match filt_cpu q with Some q' -> Some (Not q') | None -> None)
              | And ps -> Some (And (List.filter_map filt_cpu ps))
              | Or ps ->
                 (match List.filter_map filt_cpu ps with [] -> None | xs -> Some (Or xs))
              | Implies (a,b) ->
                 (match filt_cpu a, filt_cpu b with
                  | Some a',Some b' -> Some (Implies (a',b')) | _ -> None) in
            let cpu_prop =
              match filt_cpu (prop_of parsed.MiscParser.condition) with
              | Some p -> p | None -> ConstrGen.And [] in
            let cpu_parsed =
              { MiscParser.info = parsed.MiscParser.info ;
                init = cpu_init ;
                prog = cpu_prog ;
                filter = None ;
                condition = ConstrGen.ExistsState cpu_prop ;
                locations = [] ;
                extra_data = MiscParser.empty_extra ; } in
            let cpu_allocated = AllocCpu.allocate_regs cpu_parsed in
            let cpu_globals, cpu_code = CpuKit.compile_code doc cpu_allocated in
            (* As ASMLang.dump_fun takes them: an array global by element type. *)
            let global_env =
              List.map
                (fun (loc,t) ->
                  let t = match t with
                    | CType.Array (b,_) -> CType.Base b
                    | _ -> t in
                  loc,t)
                cpu_globals in

            let cpu_addr_params out =
              let addrs,_ptes = Cpu.Out.get_addrs out in
              List.map
                (fun a ->
                  let ty =
                    try List.assoc a global_env with Not_found -> Compile.base in
                  (Printf.sprintf "%s *%s" (SkelUtil.dump_global_type a ty) a, a))
                addrs in

            (* (declaration, name, the register as a condition spells it, type) *)
            let cpu_out_infos out proc =
              List.map
                (fun reg ->
                  let t = Cpu.Out.RegMap.find reg out.Cpu.Out.ty_env in
                  let t = if CType.is_tag_ptr t then CType.pointer_type t else t in
                  let ty = CType.dump t in
                  let n = Cpu.Out.dump_out_reg proc reg in
                  (Printf.sprintf "%s *%s" ty n, n, Cpu.pp_reg reg, ty))
                out.Cpu.Out.final in
            let params =
              List.map
                (fun (proc,(out,(_outregs,envV))) -> (proc, out, envV))
                cpu_code in
            (* GPU-only projection (reuse CudaLang translation) *)
            let gpu_prog =
              List.filter_map
                (fun ((p,annot,f),code) -> match annot with
                  | Some ("gpu"::_) ->
                     Some ((p,annot,f),List.map Arch'.to_gpu_pseudo code)
                  | _ -> None)
                parsed.MiscParser.prog in
            let gpu_globals = CudaLang.collect_globals gpu_prog in
            let gpu_procs = List.map (fun ((p,_,_),_) -> p) gpu_prog in
            let layout,n_blocks,block_dim =
              CudaLang.layout_of_scopes None gpu_procs in
            (* What each proc makes observable, in outcome-column order: a CPU
               proc's `Out.final' registers -- those the synthesized CPU
               condition names, and only those -- and a GPU proc's load
               destinations. *)
            let proc_infos =
              List.filter_map
                (fun ((p,annot,_),code) -> match annot with
                  | Some ("cpu"::_) ->
                     let obs =
                       match List.find_opt (fun (q,_,_) -> q=p) params with
                       | Some (_,out,_) ->
                          List.map (fun (_,_,r,ty) -> (r,ty)) (cpu_out_infos out p)
                       | None -> [] in
                     Some (p, `Cpu, obs)
                  | Some ("gpu"::_) ->
                     let code = List.map Arch'.to_gpu_pseudo code in
                     Some (p, `Gpu,
                           List.map
                             (fun n -> (Printf.sprintf "r%d" n, "int"))
                             (CudaLang.result_regs code))
                  | _ -> None)
                (List.sort
                   (fun ((a,_,_),_) ((b,_,_),_) -> compare a b)
                   parsed.MiscParser.prog) in

            (* Read buffers: one per observable column, size N. *)
            let read_buffers =
              List.concat_map
                (fun (p,dev,obs) ->
                  List.mapi
                    (fun li (_,ty) -> (p, li, buf_name_of p li, dev, ty))
                    obs)
                proc_infos in
            (* Shared globals (allocated once, coherent to both) *)
            let cpu_addrs =
              List.concat_map
                (fun (_,out,_) -> List.map snd (cpu_addr_params out))
                params in
            let all_globals =
              let seen = Hashtbl.create 8 in
              List.filter
                (fun g -> if Hashtbl.mem seen g then false
                          else (Hashtbl.add seen g () ; true))
                (cpu_addrs @ gpu_globals) in
            (* Outcome columns: registers, then the condition's locations. *)
            let dev_slots want =
              List.concat_map
                (fun (p,dev,obs) ->
                  if dev = want then
                    List.mapi
                      (fun li (r,_) ->
                        ((p,r),
                         match dev with
                         | `Gpu -> buf_name_of p li ^ "_h"
                         | `Cpu -> buf_name_of p li))
                      obs
                  else [])
                proc_infos in
            let slots = dev_slots `Cpu @ dev_slots `Gpu in
            let n_reg = List.length slots in
            let loc_slots =
              List.filter_map
                (fun g ->
                  let name = MiscParser.dump_value g in
                  if List.mem name all_globals then Some name else None)
                (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
            let nslots = n_reg + List.length loc_slots in

            (* Condition -> C predicate over the outcome vector *)
            let cval v = ParsedConstant.pp_v v in
            let cint v = int_of_string_opt (ParsedConstant.pp_v v) in
            let is_true s =
              s = "1" || (String.length s >= 2 && s.[0]='1' && s.[1]=' ') in
            let is_false s =
              s = "0" || (String.length s >= 2 && s.[0]='0' && s.[1]=' ') in
            let mk_and parts =
              if List.exists is_false parts then "0"
              else match List.filter (fun p -> not (is_true p)) parts with
              | [] -> "1"
              | [p] -> p
              | ps -> "(" ^ String.concat " && " ps ^ ")" in
            let mk_or parts =
              if List.exists is_true parts then "1"
              else match List.filter (fun p -> not (is_false p)) parts with
                | [] -> "0"
                | [p] -> p
                | ps -> "(" ^ String.concat " || " ps ^ ")" in
            let slot_of_reg pr r =
              let rec f i = function
                | ((p,rr),_)::rest -> if p=pr && rr=r then Some i else f (i+1) rest
                | [] -> None in
              f 0 slots in
            let slot_of_loc name =
              let rec f i = function
                | g::rest -> if g=name then Some (n_reg+i) else f (i+1) rest
                | [] -> None in
              f 0 loc_slots in

            let rec c_slot_of_prop p =
              let open ConstrGen in
              match p with
              | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
                 let i = match slot_of_reg pr r with
                   | Some i -> i
                   | None ->
                      Warn.fatal
                        "hetlitmus: condition names %d:%s but proc %d makes no \
                         such value observable (no read buffer to bind)" pr r pr in
                 (match cint v with
                  | Some n -> Printf.sprintf "(_o[%d] == %d)" i n
                  | None ->
                     Warn.fatal
                       "hetlitmus: condition value for %d:%s is not an integer"
                       pr r)
              | Atom (LV (Loc (MiscParser.Location_global g),v)) ->
                 let name = MiscParser.dump_value g in
                 let i = match slot_of_loc name with
                   | Some i -> i
                   | None ->
                      Warn.fatal
                        "hetlitmus: condition observes [%s]=%s but no proc of \
                         this test touches that location (no slot backs it)"
                        name (cval v) in
                 (match cint v with
                  | Some n -> Printf.sprintf "(_o[%d] == %d)" i n
                  | None ->
                     Warn.fatal
                       "hetlitmus: condition value for [%s] is not an integer"
                       name)
              | Atom _ ->
                 Warn.fatal "hetlitmus: unsupported condition atom (not loc=v)"
              | Not q -> Printf.sprintf "(!%s)" (c_slot_of_prop q)
              | And ps -> mk_and (List.map c_slot_of_prop ps)
              | Or ps -> mk_or (List.map c_slot_of_prop ps)
              | Implies (a,b) ->
                 Printf.sprintf "(!(%s) || %s)"
                   (c_slot_of_prop a) (c_slot_of_prop b) in

            let weak_expr = c_slot_of_prop (prop_of parsed.MiscParser.condition) in
            if is_true weak_expr || is_false weak_expr then
              Warn.fatal
                "hetlitmus: %s would emit a CONSTANT weak-behaviour detector \
                 (_weak = %s) -- refusing to emit"
                tname weak_expr ;

            (* The pre-rendered _labels / _dump_one *)
            let labels =
              let b = Buffer.create 256 in
              let s = Buffer.add_string b in
              let labelstr =
                String.concat ", "
                  (List.map (fun ((p,r),_) -> Printf.sprintf "\"%d:%s\"" p r) slots
                   @ List.map (Printf.sprintf "\"[%s]\"") loc_slots) in
              s (Printf.sprintf "static const char* _labels[%d] = { %s };\n"
                   (max 1 nslots) labelstr) ;
              s {ocaml|static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
  fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
|ocaml} ;
              if nslots = 0 then s "  (void)o;\n"
              else begin
                s (Printf.sprintf "  for (int i=0;i<%d;i++)" nslots) ;
                s {ocaml| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
|ocaml}
              end ;
              s {ocaml|  fprintf(_ch, "\n");
}

|ocaml} ;
              Buffer.contents b in
            (* The pre-rendered slot readout: iteration n's vector comes
               from slot n, and the arrival flags are ANDed first, so an
               iteration ONLY one side started is discarded unread. *)
            let readout =
              let b = Buffer.create 1024 in
              let s = Buffer.add_string b in
              let nsl = max 1 nslots in
              s (Printf.sprintf "    intmax_t _first[%d]; int _seen_first = 0;\n" nsl) ;
              s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
              s "      int _ok = 1;\n" ;
              List.iter
                (fun (p,dev,_) ->
                  match dev with
                  | `Gpu ->
                     s (Printf.sprintf
                          "      if (!%s_h[_n]) { _ok = 0; _rec.rdv_cap_gpu++; }\n"
                          (rdv_gpu_name p))
                  | `Cpu ->
                     s (Printf.sprintf
                          "      if (!%s[_n]) { _ok = 0; _rec.rdv_cap_cpu++; }\n"
                          (rdv_cpu_name p)))
                proc_infos ;
              s "      if (!_ok) { _rec.iters_discarded++; continue; }\n" ;
              s "      _rec.iters_scored++;\n" ;
              s (Printf.sprintf "      intmax_t _o[%d];\n" nsl) ;
              List.iteri
                (fun i (_,buf) ->
                  s (Printf.sprintf "      _o[%d] = (intmax_t)%s[_n];\n" i buf))
                slots ;
              List.iteri
                (fun j g ->
                  s (Printf.sprintf
                       "      _o[%d] = (intmax_t)%s[(size_t)_n*HET_SLOT_STRIDE_WORDS];\n"
                       (n_reg+j) g))
                loc_slots ;
              if nslots = 0 then s "      _o[0] = 0;\n" ;
              s (Printf.sprintf "      int _weak = %s;\n" weak_expr) ;
              s "      if (_weak) _rec.target_count++;\n" ;
              s (Printf.sprintf
                   "      hist = add_outcome_outs(hist, _o, %d, 1, _weak);\n" nslots) ;

              (* outcomes_vary = 0 iff every scored iteration read the same vector. *)
              s "      if (!_seen_first) { memcpy(_first, _o, sizeof _o); _seen_first = 1; }\n" ;
              s "      else if (memcmp(_first, _o, sizeof _o) != 0) _rec.outcomes_vary = 1;\n" ;
              s "    }\n" ;
              (* Marks the readout as having run
                 (hetlitmus/docs/00-environment-design.md sec 4). *)
              s "    _rec.rdv_valid = 1;\n" ;
              Buffer.contents b in
            let cpus =
              List.map
                (fun (proc,out,envV) ->
                  { cp_proc = proc ;
                    cp_addrs = cpu_addr_params out ;
                    cp_outs =
                      List.map (fun (d,n,_,_) -> (d,n)) (cpu_out_infos out proc) ;
                    cp_dump =
                      (fun ch ->
                        CpuKit.dump_fun ch Template.no_extra_args global_env envV
                          proc out) })
                params in
            let gpus =
              List.map
                (fun ((p,_,_),code) ->
                  let blk,lane = layout p in
                  { gp_proc = p ; gp_blk = blk ; gp_lane = lane ;
                    gp_instrs = CudaLang.instrs_of_code code ;
                    gp_regs = CudaLang.result_regs code })
                gpu_prog in
            { i_cpus = cpus ; i_gpus = gpus ;
              i_gpu_globals = gpu_globals ; i_all_globals = all_globals ;
              i_bdim = block_dim ;
              i_npart = List.length params + List.length gpu_prog ;
              i_blocks = n_blocks ;
              i_lanes = List.length gpu_prog ;
              i_bufs = read_buffers ;
              i_readout = readout ; i_labels = labels ;
              i_nslots = nslots ; } in

          if O.verbose >= 0 then begin
            Printf.eprintf
              "HetLitmus: emitting CPU+GPU harness for %s (%d procs, CPU=%s)\n%!"
              tname nprocs_total CpuF.isa_name ;
            List.iter
              (fun ((p,annot,_),_code) ->
                let dev = match annot with Some (d::_) -> d | _ -> "?" in
                Printf.eprintf "  P%d device=%s -> %s\n%!" p dev
                  (match dev with
                   | "cpu" ->
                      Printf.sprintf "CPU pthread (litmus7 %s asm)"
                        CpuF.isa_name
                   | "gpu" -> "GPU kernel (LISA/PTX via CudaLang/HipLang)"
                   | _ -> "unknown"))
              parsed.MiscParser.prog ;
            Printf.eprintf
              "  pair: %s%s\n%!" pair_label
              (if cpu_only then "  [CPU-only cycle]" else "")
          end ;
          let id = CudaLang.c_ident tname in

          (* ================= file emission ================= *)
          let base =
            if O.is_out && (try Sys.is_directory O.tarname with _ -> false)
            then O.tarname else Sys.getcwd () in
          let dir = Filename.concat base tname in
          if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
          let write fname f =
            Misc.output_protect f (Filename.concat dir fname) in

          (* het_run_P<p> wraps code<p>: its declaration, args struct, call
             and read buffers all come from cp_addrs @ cp_outs, in that order. *)
          let cpu_bufs cp =
            List.filter_map
              (fun (p,_,name,dev,ty) ->
                if p = cp.cp_proc && dev = `Cpu
                then Some (Printf.sprintf "%s *%s" ty name, name) else None)
              it.i_bufs in
          let cpu_sig cp =
            String.concat "," (List.map fst (cp.cp_addrs @ cp.cp_outs)) in
          let kernel_globals = it.i_gpu_globals in
          (* <tname>_cpu.c : the CPU threads (litmus7's own asm) *)
          let dump_cpu_file ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "/* HetLitmus: the CPU threads of %s (%s).\n   \
                  Bodies compiled and printed by litmus7 itself\n   \
                  (Compile.Make -> ASMLang.dump_fun); het_run_P<n> is the\n   \
                  non-static entry point its caller hands iteration n's slot\n   \
                  address for every location.  DO NOT EDIT. */\n"
                 tname CpuF.isa_name) ;

            (* _GNU_SOURCE before EVERY libc header: glibc hides the cpu_set_t
               and sched_setaffinity that het_cpu_stress.h needs. *)
            s "#define _GNU_SOURCE\n" ;
            s "#include <stdint.h>\n\n" ;
            (* HET_CPU_STRESS_IMPL: the CPU stress bodies land in this file. *)
            s "#define HET_CPU_STRESS_IMPL\n" ;
            s "#include \"het_cpu_stress.h\"\n\n" ;
            s (Printf.sprintf "#if defined(%s)\n" CpuF.host_macro) ;
            List.iter (fun cp -> cp.cp_dump ch) it.i_cpus ;
            s "#else\n" ;
            s (Printf.sprintf
                 "/* Stub for a non-%s host; the tested body is the asm above. */\n"
                 CpuF.isa_name) ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "static void code%d(%s) {\n"
                     cp.cp_proc (cpu_sig cp)) ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n))
                  cp.cp_addrs ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  *%s = 0;\n" n))
                  cp.cp_outs ;
                s "}\n")
              it.i_cpus ;
            s "#endif\n\n" ;

            (* The non-static entry points the GPU-side driver calls. *)
            List.iter
              (fun cp ->
                let args =
                  String.concat "," (List.map snd (cp.cp_addrs @ cp.cp_outs)) in
                s (Printf.sprintf "void het_run_P%d(%s) { code%d(%s); }\n"
                     cp.cp_proc (cpu_sig cp) cp.cp_proc args))
              it.i_cpus in

          (* Every shared global is SIZE_OF_TEST slots wide, one per iteration. *)
          let global_bytes = "sizeof(int)*SIZE_OF_TEST*HET_SLOT_STRIDE_WORDS" in
          let buf_bytes ty = Printf.sprintf "sizeof(%s)*SIZE_OF_TEST" ty in
          let rdv_bytes = "sizeof(uint8_t)*SIZE_OF_TEST" in
          let gpu_bufs =
            List.filter (fun (_,_,_,dev,_) -> dev = `Gpu) it.i_bufs in

          (* The emitted main(): allocation, launch, the run loop,
                 the slot readout and teardown *)
          let dump_gpu_main dialect s =
            s "int main(void){\n" ;
            (* One gd_alloc_shared per location, so the free matches it. *)
            List.iter
              (fun g ->
                s (Printf.sprintf
                     "  int *%s; gd_alloc_shared((void**)&%s, %s);\n"
                     g g global_bytes))
              it.i_all_globals ;

            (* The rendezvous counter gets a slot of its own *)
            s "  uint64_t *barrier; gd_alloc_shared((void**)&barrier, sizeof(int)*HET_SLOT_STRIDE_WORDS);\n" ;
            (* read buffers -- OFF the coherent race path. *)
            List.iter
              (fun (_,_,name,dev,ty) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  %s *%s; %s\n" ty name
                        (dialect.gd_dev_malloc name (buf_bytes ty))) ;
                   s (Printf.sprintf
                        "  %s *%s_h = (%s*)malloc_check(%s);\n"
                        ty name ty (buf_bytes ty))
                | `Cpu ->
                   s (Printf.sprintf
                        "  %s *%s = (%s*)malloc_check(%s);\n"
                        ty name ty (buf_bytes ty)))
              it.i_bufs ;
            (* rendezvous flags, each on the side that writes it. *)
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "  uint8_t *%s; %s\n" g
                     (dialect.gd_dev_malloc g rdv_bytes)) ;
                s (Printf.sprintf "  uint8_t *%s_h = (uint8_t*)malloc_check(%s);\n"
                     g rdv_bytes))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  uint8_t *%s = (uint8_t*)malloc_check(%s);\n"
                     (rdv_cpu_name cp.cp_proc) rdv_bytes))
              it.i_cpus ;

            (* cooperative-launch prelude *)
            s "  int _coop = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_coop, %s, 0);\n"
                 dialect.gd_dev_attr dialect.gd_attr_coop) ;
            s "  if (!_coop) { fprintf(stderr, \"cooperative launch unsupported on this device\\n\"); return 2; }\n" ;
            s "  int _nsm = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_nsm, %s, 0);\n"
                 dialect.gd_dev_attr dialect.gd_attr_smcount) ;
            s "  int _bpsm = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_bpsm, litmus_%s, HET_BLOCK_DIM, 0);\n"
                 dialect.gd_occupancy id) ;
            s "  int _maxGrid = _bpsm * _nsm;\n" ;
            s "  int _testBlocks = HET_TEST_BLOCKS;\n" ;
            s "  int _noiseBlocks = HET_NOISE_GPU_BLOCKS;\n" ;
            s "  if (_noiseBlocks < 0) _noiseBlocks = 0;\n" ;
            s "  int _stressBlocks = (HET_STRESS_BLOCKS >= 0) ? HET_STRESS_BLOCKS\n\
               \                                              : (_maxGrid - _testBlocks - _noiseBlocks);\n" ;
            s "  if (_stressBlocks < 0) _stressBlocks = 0;\n" ;
            s "  int _grid = _testBlocks + _noiseBlocks + _stressBlocks;\n" ;
            s "  if (_grid > _maxGrid) { fprintf(stderr, \"grid %d exceeds co-resident cap %d\\n\", _grid, _maxGrid); return 2; }\n" ;
            (* [Alglave15 sec 4.3.1 Tab. 6] *)
            s "  if (HET_MEM_STRESS_PCT > 0 && _stressBlocks == 0)\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: the mem-stress population is EMPTY (test=%d + noise=%d fills the co-resident cap %d).  HET_MEM_STRESS_PCT=%d asks for scratchpad stress and NO block will do any.\\n\",\n\
               \            _testBlocks, _noiseBlocks, _maxGrid, (int)HET_MEM_STRESS_PCT);\n" ;
            s "  uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;\n" ;
            s "  uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;\n" ;
            s "  fprintf(stderr, \"HetLitmus: blockDim=%d grid=%d (test=%d stress=%d, co-resident cap=%d) pre_pat=%u mem_pat=%u\\n\",\n\
               \          (int)HET_BLOCK_DIM, _grid, _testBlocks, _stressBlocks, _maxGrid,\n\
               \          _pre_pat, _mem_pat);\n" ;
            s (Printf.sprintf "  uint32_t *_scratch; %s\n"
                 (dialect.gd_dev_malloc "_scratch" "sizeof(uint32_t)*HET_SCRATCH_SIZE")) ;
            s (Printf.sprintf "  uint32_t *_scratch_loc; %s\n"
                 (dialect.gd_dev_malloc "_scratch_loc" "sizeof(uint32_t)*_grid")) ;
            s (Printf.sprintf "  uint32_t *_gpu_done; %s\n"
                 (dialect.gd_dev_malloc "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "  uint32_t *_stress_tally; %s\n"
                 (dialect.gd_dev_malloc "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "  uint32_t _stress_tally_h[HET_TALLY_N];\n" ;
            s "  uint32_t *_scratch_loc_h = (uint32_t*)malloc_check(sizeof(uint32_t)*_grid);\n" ;
            (* The CPU stress population *)
            let n_cpu_threads = List.length it.i_cpus in
            s "  int _ncores = het_cpu_ncores();\n" ;
            s "  int _aff = HET_CPU_AFFINITY;\n" ;
            s (Printf.sprintf "  int _nCpuTest = %d;\n" n_cpu_threads) ;
            s "  int _nEnemy = HET_CPU_ENEMIES;\n" ;
            s "  if (_nEnemy < 0) {\n" ;
            s "    _nEnemy = _ncores - _nCpuTest - (HET_NOISE_CPU ? 1 : 0) - HET_CPU_RESERVE_CORES;\n" ;
            s "    if (_nEnemy < 0) _nEnemy = 0;\n" ;
            s "  }\n" ;
            s "  het_cpu_tally _ct;\n" ;
            s "  int _stress_go = 0;\n" ;
            s "  uint64_t *_cpu_scratch =\n\
               \    (uint64_t*)malloc_check(sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);\n" ;
            s "  memset(_cpu_scratch, 0, sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);\n" ;
            s "  uint32_t _cpu_nregions = (uint32_t)(HET_CPU_SCRATCH_WORDS / HET_CPU_STRIDE);\n" ;
            s "  if (_cpu_nregions < 1) _cpu_nregions = 1;\n" ;
            s "  uint32_t _cpu_spread = HET_CPU_SPREAD;\n" ;
            s "  if (_cpu_spread > _cpu_nregions) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: realised CPU stress spread is %u region(s), not HET_CPU_SPREAD=%d -- the enemy scratchpad (HET_CPU_SCRATCH_WORDS/HET_CPU_STRIDE) holds only %u.  The CPU stress is weaker than the configuration says.\\n\",\n\
               \            _cpu_nregions, (int)HET_CPU_SPREAD, _cpu_nregions);\n" ;
            s "    _cpu_spread = _cpu_nregions;\n" ;
            s "  }\n" ;
            s "  uint32_t *_cpu_idx = (uint32_t*)malloc_check(sizeof(uint32_t)*_cpu_nregions);\n" ;
            s "  het_cpu_enemy_args *_ea = (het_cpu_enemy_args*)malloc_check(sizeof(het_cpu_enemy_args)*(_nEnemy>0?_nEnemy:1));\n" ;
            s "  pthread_t *_eth = (pthread_t*)malloc_check(sizeof(pthread_t)*(_nEnemy>0?_nEnemy:1));\n" ;
            s "  uint64_t _noise_words = (uint64_t)HET_NOISE_MB * 1024ull * 1024ull / sizeof(uint64_t);\n" ;
            s "  uint32_t _noise_blocks = (uint32_t)_noiseBlocks;\n" ;
            s "  uint32_t _noise_chunk = (uint32_t)HET_NOISE_CHUNK;\n" ;
            s "  uint32_t _noise_stride = (uint32_t)HET_NOISE_STRIDE;\n" ;
            s "  uint64_t *_noise_ddr = NULL;   /* CPU-homed: the GPU streams it */\n" ;
            s "  uint64_t *_noise_hbm = NULL;   /* GPU-homed: the CPU streams it */\n" ;
            s "  het_cpu_noise_args _na; pthread_t _nth; int _noise_cpu_on = 0;\n" ;

            s "  if (HET_NOISE_MB < HET_LLC_MB) {\n" ;
            s "#if HET_LLC_MB_IS_FALLBACK\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%d is below the %d MB threshold -- a FALLBACK figure, measured on another part, not a last-level-cache capacity for this target (build with -DHET_LLC_MB=<MB> to supply it).  A noise buffer that fits in the last-level cache is served locally and crosses no %s, so this run may not be stressed at all.\\n\",\n\
               \            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);\n" ;
            s "#else\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%d is BELOW the HET_LLC_MB supplied for this build (%d MB) -- the noise buffers fit in the last-level cache, so the reads are served locally and generate NO interconnect traffic.  This run is NOT %s-stressed.\\n\",\n\
               \            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);\n" ;
            s "#endif\n" ;
            s "  }\n" ;
            s "  if (_noiseBlocks > 0) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_ddr, (size_t)_noise_words*sizeof(uint64_t), 2);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB DDR noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB, HET_DEV_HALF, HET_LINK_NAME); _noise_ddr = NULL; _noise_blocks = 0; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the DDR noise buffer could not be homed on the CPU -- this device has no interconnect-stress lever (no ATS/coherent host-device link), so %s of the noise is exercising plumbing, not the %s.\\n\", HET_DEV_HALF, HET_LINK_NAME);\n" ;
            s "  }\n" ;
            s "  if (HET_NOISE_CPU) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_hbm, (size_t)_noise_words*sizeof(uint64_t), 1);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB HBM noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB, HET_HOST_HALF, HET_LINK_NAME); _noise_hbm = NULL; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the HBM noise buffer could not be homed on the GPU -- %s of the noise is exercising plumbing, not the %s.\\n\", HET_HOST_HALF, HET_LINK_NAME);\n" ;
            s "  }\n" ;
            s "  fprintf(stderr, \"HetLitmus cpu-stress: cores=%d test=%d enemies=%d spread=%u stride=%d seq=%d preload=%d%% aff=%d | noise: gpu_blocks=%u cpu=%d words=%llu (%d MB) place=%d\\n\",\n\
               \          _ncores, _nCpuTest, _nEnemy, _cpu_spread, (int)HET_CPU_STRIDE,\n\
               \          (int)HET_CPU_ENEMY_SEQ, (int)HET_CPU_PRELOAD_PCT, _aff,\n\
               \          _noise_blocks, (int)HET_NOISE_CPU,\n\
               \          (unsigned long long)_noise_words, (int)HET_NOISE_MB, (int)HET_PLACE);\n" ;
            s "  outs_t* hist = NULL;\n" ;

            (* One counter per run (hetlitmus/docs/harness-reporting.md sec 5). *)
            s "  het_obs_record _recs[NUMBER_OF_RUN];\n" ;
            s "  memset(_recs, 0, sizeof _recs);\n" ;
            (* Campaign knobs read through getenv, never -D: a retune needs
               no rebuild and no branch folds away.  See het_verdict.h. *)
            s "  int _runs_budget = (int)het_env_long(\"HET_RUNS_MAX\", NUMBER_OF_RUN);\n" ;
            s "  if (_runs_budget > NUMBER_OF_RUN) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_RUNS_MAX=%d exceeds the compiled NUMBER_OF_RUN=%d -- clamped.  Grow R by re-invoking with a FRESH HET_SEED (hetlitmus/campaign.py), never by replaying the same seeds.\\n\", _runs_budget, (int)NUMBER_OF_RUN);\n" ;
            s "    _runs_budget = NUMBER_OF_RUN;\n" ;
            s "  }\n" ;
            s "  if (_runs_budget < 1) _runs_budget = 1;\n" ;
            s "  int _adaptive = (int)het_env_long(\"HET_ADAPTIVE\", 0);\n" ;
            s "  int _rate_mode = (int)het_env_long(\"HET_RATE\", 0);\n" ;
            s "  int _confirm_runs = (int)het_env_long(\"HET_CONFIRM_RUNS\", 30);\n" ;
            s "  uint32_t _seed0 = (uint32_t)het_env_long(\"HET_SEED\", (long)HET_SEED);\n" ;

            (* The rendezvous spin caps. *)
            s "  long _cap_cpu = het_env_long(\"HET_CAP_CPU\", (long)HET_CAP_CPU);\n" ;
            s "  long _cap_gpu_env = het_env_long(\"HET_CAP_GPU\", (long)HET_CAP_GPU);\n" ;
            s "  if (_cap_cpu < 0) _cap_cpu = 0;\n" ;
            s "  if (_cap_gpu_env < 0) _cap_gpu_env = 0;\n" ;
            s "  unsigned long _cap_cpu_u = (unsigned long)_cap_cpu;\n" ;
            s "  unsigned long _cap_gpu_u = (unsigned long)_cap_gpu_env;\n" ;
            s "  if (_cap_cpu_u > 0xffffffffUL) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_CAP_CPU=%lu exceeds the %lu polls the record can carry -- clamped.\\n\", _cap_cpu_u, 0xffffffffUL);\n" ;
            s "    _cap_cpu_u = 0xffffffffUL; _cap_cpu = (long)_cap_cpu_u;\n" ;
            s "  }\n" ;
            s "  if (_cap_gpu_u > 0xffffffffUL) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_CAP_GPU=%lu exceeds the %lu polls a lane can carry -- clamped.\\n\", _cap_gpu_u, 0xffffffffUL);\n" ;
            s "    _cap_gpu_u = 0xffffffffUL;\n" ;
            s "  }\n" ;
            s "  uint32_t _cap_gpu = (uint32_t)_cap_gpu_u;\n" ;
            s "  int _nrec = 0;\n" ;
            s "  for (int _run=0; _run<_runs_budget; ++_run) {\n" ;

            (* Every shared location is zeroed over all its slots, once per run. *)
            List.iter
              (fun g ->
                s (Printf.sprintf "    memset(%s, 0, %s);\n" g global_bytes))
              it.i_all_globals ;
            s "    *barrier = 0;\n" ;
            s "    uint32_t _seed = _seed0 + (uint32_t)_run;\n" ;
            s "    srand((unsigned int)_seed);\n" ;
            s "    het_set_scratch_locations(_scratch_loc_h, _grid);\n" ;

            (* The CPU stress population, spawned BEFORE the test threads. *)
            s "    memset(&_ct, 0, sizeof _ct);\n" ;

            (* A host with no cache primitives issues zero preload hints. *)
            s "    _ct.preload_inert = !het_cpu_preload_live();\n" ;
            s "    het_cpu_shuffle(_cpu_idx, _cpu_nregions);   /* reshuffled per run, off the run seed */\n" ;
            s "    __atomic_store_n(&_stress_go, 1, __ATOMIC_RELAXED);\n" ;
            s "    int _ecore0 = HET_CPU_TEST_CORE0 + _nCpuTest + (HET_NOISE_CPU ? 1 : 0);\n" ;
            s "    if (_aff && _ecore0 + _nEnemy > _ncores)\n" ;
            s "      fprintf(stderr, \"HetLitmus WARNING: %d enemy thread(s) from core %d exceed %d core(s) -- enemy pins WRAP onto the test threads' cores, so the test threads no longer have a core to themselves and the stress topology is not the one being tuned.\\n\",\n\
               \              _nEnemy, _ecore0, _ncores);\n" ;
            s "    for (int _e = 0; _e < _nEnemy; ++_e) {\n" ;
            s "      uint32_t _off = (_cpu_nregions > _cpu_spread)\n\
               \                    ? ((uint32_t)_e * _cpu_spread) % (_cpu_nregions - _cpu_spread + 1)\n\
               \                    : 0u;\n" ;
            s "      _ea[_e].scratch = _cpu_scratch;\n" ;
            s "      _ea[_e].idx     = _cpu_idx + _off;\n" ;
            s "      _ea[_e].nidx    = _cpu_spread;\n" ;
            s "      _ea[_e].stride  = (uint32_t)HET_CPU_STRIDE;\n" ;
            s "      _ea[_e].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;\n" ;
            s "      _ea[_e].core    = _aff ? ((_ecore0 + _e) % _ncores) : -1;\n" ;
            s "      _ea[_e].go      = &_stress_go;\n" ;
            s "      _ea[_e].tally   = &_ct;\n" ;
            s "      pthread_create(&_eth[_e], NULL, het_cpu_enemy, &_ea[_e]);\n" ;
            s "    }\n" ;
            s "    _noise_cpu_on = 0;\n" ;
            s "    if (HET_NOISE_CPU && _noise_hbm != NULL) {\n" ;
            s "      _na.buf    = (volatile const uint64_t*)_noise_hbm;\n" ;
            s "      _na.words  = _noise_words;\n" ;
            s "      _na.chunk  = _noise_chunk;\n" ;
            s "      _na.stride = _noise_stride;\n" ;
            s "      _na.core   = _aff ? ((HET_CPU_TEST_CORE0 + _nCpuTest) % _ncores) : -1;\n" ;
            s "      _na.go     = &_stress_go;\n" ;
            s "      _na.tally  = &_ct;\n" ;
            s "      pthread_create(&_nth, NULL, het_cpu_noise, &_na);\n" ;
            s "      _noise_cpu_on = 1;\n" ;
            s "    }\n" ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_memcpy_h2d "_scratch_loc" "_scratch_loc_h"
                    "sizeof(uint32_t)*_grid")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_scratch" "sizeof(uint32_t)*HET_SCRATCH_SIZE")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            List.iter
              (fun (_,_,name,dev,ty) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "    %s\n"
                        (dialect.gd_dev_memset0 name (buf_bytes ty)))
                | `Cpu ->
                   s (Printf.sprintf "    memset(%s, 0, %s);\n"
                        name (buf_bytes ty)))
              it.i_bufs ;
            List.iter
              (fun gp ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_dev_memset0 (rdv_gpu_name gp.gp_proc) rdv_bytes)))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "    memset(%s, 0, %s);\n"
                     (rdv_cpu_name cp.cp_proc) rdv_bytes))
              it.i_cpus ;
            (* Cores go out in emission order, so no two test threads share one. *)
            let ti = ref 0 in
            List.iter
              (fun cp ->
                let proc = cp.cp_proc in
                let addr = cp.cp_addrs and bufs = cpu_bufs cp in
                let core =
                  Printf.sprintf
                    "(_aff ? ((HET_CPU_TEST_CORE0 + %d) %% _ncores) : -1)" !ti in
                incr ti ;
                let fields =
                  String.concat ", "
                    (List.map snd addr
                     @ ["barrier"] @ List.map snd bufs
                     @ [rdv_cpu_name proc ; "_cap_cpu"]
                     @ [core ; "_seed" ; "&_ct"]) in
                s (Printf.sprintf "    cpu_args_P%d _ca%d = { %s };\n"
                     proc proc fields) ;
                s (Printf.sprintf
                     "    pthread_t _th%d; pthread_create(&_th%d, NULL, cpu_thread_P%d, &_ca%d);\n"
                     proc proc proc proc))
              it.i_cpus ;

            (* args[] in kernel-parameter order. *)
            let args_addrs =
              String.concat ", "
                (List.map (fun g -> "&" ^ g) kernel_globals
                 @ List.map (fun (_,_,name,_,_) -> "&"^name) gpu_bufs
                 @ List.map (fun gp -> "&" ^ rdv_gpu_name gp.gp_proc) it.i_gpus
                 @ ["&barrier" ; "&_cap_gpu"]
                 @ ["&_scratch" ; "&_scratch_loc" ; "&_gpu_done" ;
                    "&_stress_tally" ; "&_seed" ; "&_pre_pat" ; "&_mem_pat" ;
                    "&_noise_ddr" ; "&_noise_words" ; "&_noise_blocks" ;
                    "&_noise_chunk" ; "&_noise_stride"]) in
            s (Printf.sprintf "    void* _args[] = { %s };\n" args_addrs) ;
            s (Printf.sprintf
                 "    %s _e = %s((void*)litmus_%s, dim3(_grid), dim3(HET_BLOCK_DIM), _args, 0, 0);\n"
                 dialect.gd_err_t dialect.gd_coop_launch id) ;
            s (Printf.sprintf
                 "    if (_e != %s) { fprintf(stderr, \"coop launch: %%s\\n\", %s(_e)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "    pthread_join(_th%d, NULL);\n" cp.cp_proc))
              it.i_cpus ;
            s (Printf.sprintf "    %s _s = %s\n" dialect.gd_err_t dialect.gd_device_sync) ;
            s (Printf.sprintf
                 "    if (_s != %s) { fprintf(stderr, \"sync: %%s\\n\", %s(_s)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            s "    __atomic_store_n(&_stress_go, 0, __ATOMIC_RELAXED);\n" ;
            s "    for (int _e = 0; _e < _nEnemy; ++_e) pthread_join(_eth[_e], NULL);\n" ;
            s "    if (_noise_cpu_on) pthread_join(_nth, NULL);\n" ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_memcpy_d2h "_stress_tally_h" "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "    {\n" ;
            s "      unsigned long long _er = _ct.enemy_rounds;\n" ;
            s "      unsigned long long _pl = _ct.preload_ops;\n" ;
            s "      unsigned long long _nc = _ct.noise_cpu_rounds;\n" ;
            s "      uint32_t _ng = _stress_tally_h[HET_TALLY_NOISE];\n" ;
            s "      fprintf(stderr, \"HetLitmus cpu-stress: enemies=%u rounds=%llu accesses=%llu preload_hints=%llu | noise: cpu_rounds=%llu gpu_blocks=%u (max %u rounds) | aff_fail=%u place_fail=%d\\n\",\n\
               \              _ct.enemies_realised, _er, (unsigned long long)_ct.enemy_accesses,\n\
               \              _pl, _nc, _ng, _stress_tally_h[HET_TALLY_NOISE_ROUNDS],\n\
               \              _ct.aff_failures, _het_place_failures);\n" ;
            s "      if (_nEnemy > 0 && _er == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds -- the CPU-side stress did NOT run.  Its non-observations are not those of a CPU-stressed run.\\n\", _nEnemy);\n" ;
            s "      if (HET_CPU_PRELOAD_PCT > 0 && _pl == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: HET_CPU_PRELOAD_PCT=%d but ZERO preload hints were issued -- the cache preload is INERT (this host may have no cache primitives; see het_cpu_stress.h HET_CPU_PRELOAD_LIVE).\\n\", (int)HET_CPU_PRELOAD_PCT);\n" ;
            s "      if (_noise_blocks > 0 && _ng == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u device-side noise block(s) were launched but NONE completed a round -- %s of the %s noise did NOT run.  This run is not interconnect-stressed.\\n\", _noise_blocks, HET_DEV_HALF, HET_LINK_NAME);\n" ;
            s "      if (_ct.aff_failures)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u sched_setaffinity call(s) FAILED -- those threads are wherever the scheduler put them.  The pinning is fiction and the stress topology is not the one being tuned.\\n\", _ct.aff_failures);\n" ;
            s "    }\n" ;

            List.iter
              (fun (_,_,name,_,ty) ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (name^"_h") name (buf_bytes ty))))
              gpu_bufs ;
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (g^"_h") g rdv_bytes)))
              it.i_gpus ;
            (* ======== the slot readout ======================================== *)
            s "    het_obs_record _rec; memset(&_rec, 0, sizeof _rec);\n" ;
            s (Printf.sprintf
                 "    _rec.test_name = \"%s\"; _rec.instance_id = 0; _rec.run_id = _run;\n"
                 tname) ;
            s "    _rec.N = SIZE_OF_TEST;\n" ;
            (* het_verdict() refuses an unstamped record
               (hetlitmus/docs/harness-reporting.md sec 2). *)
            s "    _rec.rec_magic = HET_REC_MAGIC;\n" ;
            s (Printf.sprintf
                 "    _rec.cpu_only = %d;  /* 1 iff EVERY proc is a CPU proc */\n"
                 (if cpu_only then 1 else 0)) ;

            (* gpu_lanes is a build fact, NOT cpu_only's cycle fact; het_verdict
               keys the absent-GPU-stress caveat on it. *)
            s "    _rec.gpu_lanes = HET_GPU_LANES;\n" ;

            (* A mechanism is requested ONLY where it can run: a standing
               request that nothing performs reads as dead
               (hetlitmus/docs/harness-reporting.md sec 3). *)
            s "    _rec.stress_requested =\n\
               \        ((HET_GPU_LANES > 0 && (HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0)) ? HET_REQ_GPU_STRESS : 0u)\n\
               \      | ((_nEnemy > 0) ? HET_REQ_CPU_ENEMY : 0u)\n\
               \      | ((HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) ? HET_REQ_CPU_PRELOAD : 0u)\n\
               \      | ((HET_NOISE_CPU && _noise_cpu_on) ? HET_REQ_NOISE_CPU : 0u)\n\
               \      | ((_noise_blocks > 0) ? HET_REQ_NOISE_GPU : 0u);\n" ;
            s "    _rec.stress_truncated = _stress_tally_h[HET_TALLY_TRUNC];\n" ;
            s "    _rec.gpu_stress_rounds = _stress_tally_h[HET_TALLY_STRESS_ROUNDS];\n" ;
            s "    _rec.cpu_enemies = _ct.enemies_realised;\n" ;
            s "    _rec.cpu_enemy_rounds = _ct.enemy_rounds;\n" ;
            s "    _rec.cpu_enemy_accesses = _ct.enemy_accesses;\n" ;
            s "    _rec.cpu_preload_ops = _ct.preload_ops;\n" ;
            s "    _rec.noise_cpu_rounds = _ct.noise_cpu_rounds;\n" ;
            s "    _rec.noise_cpu_words = _ct.noise_cpu_words;\n" ;
            s "    _rec.noise_gpu_blocks = _stress_tally_h[HET_TALLY_NOISE];\n" ;
            s "    _rec.noise_gpu_rounds = _stress_tally_h[HET_TALLY_NOISE_ROUNDS];\n" ;
            s "    _rec.cpu_aff_failures = _ct.aff_failures;\n" ;
            s "    _rec.place_failures = (uint32_t)_het_place_failures;\n" ;
            s "    _rec.noise_ws_mb = (uint32_t)HET_NOISE_MB;\n" ;
            s "    _rec.place_mode = (uint32_t)HET_PLACE;\n" ;

            s "    _rec.cap_cpu = (uint32_t)_cap_cpu;\n" ;
            s "    _rec.cap_gpu = _cap_gpu;\n" ;
            s "    _rec.cap_calibrated = HET_CAP_CALIBRATED;\n" ;
            s it.i_readout ;

            s "    fprintf(stderr, \"HetLitmus rendezvous: scored=%llu discarded=%llu (cap_cpu=%llu cap_gpu=%llu) caps=%lu/%u jitter=%d discard_max=%d%% %s\\n\",\n\
               \            (unsigned long long)_rec.iters_scored,\n\
               \            (unsigned long long)_rec.iters_discarded,\n\
               \            (unsigned long long)_rec.rdv_cap_cpu,\n\
               \            (unsigned long long)_rec.rdv_cap_gpu,\n\
               \            (unsigned long)_cap_cpu, _cap_gpu, (int)HET_RELEASE_JITTER,\n\
               \            (int)HET_RDV_MAX_DISCARD_PCT,\n\
               \            HET_CAP_CALIBRATED ? \"caps calibrated\" : \"caps UNCALIBRATED\");\n" ;
            s "    het_obs_record_print(stdout, &_rec);\n" ;

            s "    het_verdict_print(stdout, &_rec);\n" ;
            s "    _recs[_nrec++] = _rec;\n" ;

            (* Early stop after each run, decided from the records so far
               (het_verdict.h); with HET_ADAPTIVE unset the loop runs to budget. *)
            s "    if (_adaptive) {\n" ;
            s "      het_campaign_stop_t _stop = het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs);\n" ;
            s "      if (_stop != HET_CAMPAIGN_CONTINUE) {\n" ;
            s (Printf.sprintf
                 "        printf(\"HetCampaign %s stop=%%s runs=%%d budget=%%d\\n\",\n\
                  \               het_campaign_stop_name(_stop), _nrec, _runs_budget);\n"
                 tname) ;
            s "        { const char *_why = het_campaign_stop_why(_stop);\n" ;
            s "          if (*_why) printf(\"  %s.\\n\", _why); }\n" ;
            s "        break;\n" ;
            s "      }\n" ;
            s "    }\n" ;
            s "  }\n" ;

            (* The aggregate reuses het_verdict() per record, so it inherits
               every disqualifier (hetlitmus/docs/harness-reporting.md sec 5). *)
            s "  {\n" ;
            s "    het_stats_t _st;\n" ;
            s "    het_stats_compute(_recs, _nrec, &_st);\n" ;
            s "    het_stats_print(stdout, &_st);\n" ;
            s "  }\n" ;
            s (Printf.sprintf "  intmax_t _buff[%d];\n" (max 1 it.i_nslots)) ;
            s (Printf.sprintf "  printf(\"Test %s\\n\");\n" tname) ;
            s (Printf.sprintf "  dump_outs(stdout, _dump_one, hist, _buff, %d);\n"
                 it.i_nslots) ;
            s "  free_outs(hist);\n" ;
            List.iter
              (fun g -> s (Printf.sprintf "  gd_free_shared(%s);\n" g))
              it.i_all_globals ;
            s "  gd_free_shared(barrier);\n" ;
            List.iter
              (fun (_,_,name,dev,_) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  %s free(%s_h);\n"
                        (dialect.gd_free name) name)
                | `Cpu -> s (Printf.sprintf "  free(%s);\n" name))
              it.i_bufs ;
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free g) g))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  free(%s);\n" (rdv_cpu_name cp.cp_proc)))
              it.i_cpus ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch_loc")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_gpu_done")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_stress_tally")) ;
            s "  free(_scratch_loc_h);\n" ;
            s "  free(_cpu_scratch);\n" ;
            s "  free(_cpu_idx);\n" ;
            s "  free(_ea);\n" ;
            s "  free(_eth);\n" ;
            s "  gd_free_noise(_noise_ddr);\n" ;
            s "  gd_free_noise(_noise_hbm);\n" ;
            s "  return 0;\n}\n" in

          (* <tname>.{cu,hip} : GPU kernel + driver *)
          let dump_gpu_file dialect ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "// HetLitmus GPU kernel + driver for %s (%s dialect).\n"
                 tname dialect.gd_name) ;
            s "// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
            s "// Iteration _n of both sides touches slot _n of every location and\n" ;
            s "// records its loads at index _n; the post-run readout reads the\n" ;
            s "// outcome of iteration _n out of slot _n into a het_obs_record.\n" ;
            s dialect.gd_shared_mem_note ;
            s "// every iteration begins at a relaxed system-scope counter rendezvous.\n" ;
            s (Printf.sprintf
                 "// Compile-only by default (%s -c); comp.sh %s-link / make %s-bin\n"
                 dialect.gd_compiler dialect.gd_target dialect.gd_target) ;
            s "// link the runnable binary, guarded by uname -m.  DO NOT EDIT.\n" ;
            s (dialect.gd_runtime_include ^ "\n") ;
            s "#include <cstdio>\n#include <cstdint>\n#include <cstdlib>\n" ;
            s "#include <cstring>\n#include <cmath>\n" ;
            s "#include <pthread.h>\n#include <inttypes.h>\n" ;

            s (Printf.sprintf "#define HET_PAIR_NAME %S\n" pair_label) ;
            (match dialect.gd_place_lever with
             | Some lever -> s (Printf.sprintf "#define HET_PLACE_LEVER %S\n" lever)
             | None -> ()) ;
            s "#include \"het_stress.h\"\n" ;
            s "#include \"het_cpu_stress.h\"\n" ;
            s "#include \"het_verdict.h\"\n" ;
            s "#include \"het_rdv.h\"\n" ;
            s "extern \"C\" {\n" ;
            s "#include \"outs.h\"\n" ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  void het_run_P%d(%s);\n"
                     cp.cp_proc (cpu_sig cp)))
              it.i_cpus ;
            s "}\n" ;
            s {ocaml|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|ocaml} ;
            s (Printf.sprintf "\n#define NPART %d\n" it.i_npart) ;
            s (Printf.sprintf "#define SIZE_OF_TEST %d\n" Cfg.size) ;
            s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" Cfg.runs) ;
            s "\n" ;
            s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
                 (max 1 it.i_bdim)) ;
            s (Printf.sprintf "#define HET_TEST_BLOCKS %d\n" it.i_blocks) ;
            s (Printf.sprintf "#define HET_GPU_LANES %d\n\n" it.i_lanes) ;
            (* The kernel *)
            let kparams =
              String.concat ", "
                (List.map (fun g -> Printf.sprintf "int* %s" g) kernel_globals
                 @ List.map
                     (fun (_,_,name,_,ty) -> Printf.sprintf "%s* %s" ty name)
                     gpu_bufs
                 @ List.map
                     (fun gp -> Printf.sprintf "uint8_t* %s" (rdv_gpu_name gp.gp_proc))
                     it.i_gpus
                 @ ["uint64_t* barrier" ; "uint32_t _cap_gpu"]
                 @ ["uint32_t* _scratch" ; "uint32_t* _scratch_loc" ;
                    "uint32_t* _gpu_done" ;
                    "uint32_t* _stress_tally" ;
                    "uint32_t _seed" ; "uint32_t _pre_pat" ; "uint32_t _mem_pat" ;
                    "uint64_t* _noise_ddr" ; "uint64_t _noise_words" ;
                    "uint32_t _noise_blocks" ; "uint32_t _noise_chunk" ;
                    "uint32_t _noise_stride"]) in
            s (Printf.sprintf "__global__ void litmus_%s(%s) {\n" id kparams) ;
            s "  het_rng_t _rng = het_rng_init(_seed, blockIdx.x * blockDim.x + threadIdx.x);\n" ;

            (* the GPU test lanes *)
            List.iter
              (fun gp ->
                s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n"
                     gp.gp_blk gp.gp_lane) ;
                List.iter (fun n -> s (Printf.sprintf "    int r%d = 0;\n" n))
                  gp.gp_regs ;
                (* #pragma unroll 1 -- hetlitmus/docs/amd-faithfulness.md,
                   "The mapping". *)
                s "    #pragma unroll 1\n" ;
                s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                s "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n" ;
                s "        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally);\n" ;

                (* Rendezvous, jitter, then the tested ops; nothing is placed
                   between two tested accesses
                   (hetlitmus/docs/00-environment-design.md sec 3.6). *)
                s (Printf.sprintf
                     "      %s[_n] = het_rdv_device(barrier, (uint64_t)NPART*(uint64_t)(_n+1), _cap_gpu);\n"
                     (rdv_gpu_name gp.gp_proc)) ;
                s "      het_rdv_jitter(&_rng, HET_RELEASE_JITTER);\n" ;
                List.iter
                  (fun instr -> dialect.gd_dump_instr ch ~het:(Some "_n") "      " instr)
                  gp.gp_instrs ;
                List.iteri
                  (fun li n ->
                    s (Printf.sprintf "      %s[_n] = r%d;\n"
                         (buf_name_of gp.gp_proc li) n))
                  gp.gp_regs ;
                s "    }\n" ;
                s "    het_scratch_bump(_gpu_done);\n" ;
                s "  }\n")
              it.i_gpus ;

            (* =============== the pure stressing workgroups =================== *)
            s "  if (blockIdx.x >= HET_TEST_BLOCKS) {\n" ;
            s "    if (_noise_ddr != NULL && blockIdx.x < HET_TEST_BLOCKS + _noise_blocks) {\n" ;
            s "      volatile const uint64_t* _nb = (volatile const uint64_t*)_noise_ddr;\n" ;
            s "      uint64_t _t = (uint64_t)(blockIdx.x - HET_TEST_BLOCKS) * blockDim.x + threadIdx.x;\n" ;
            s "      uint64_t _step = (uint64_t)_noise_blocks * blockDim.x * _noise_stride;\n" ;
            s "      uint64_t _i = (_noise_words > 0) ? (_t % _noise_words) : 0;\n" ;
            s "      uint64_t _acc = 0;\n" ;
            s "      uint32_t _r = 0;\n" ;
            s "      for (;\n\
               \           _r < HET_STRESS_MAX_ROUNDS && het_scratch_read(_gpu_done) < HET_GPU_LANES;\n\
               \           ++_r) {\n" ;
            s "        for (uint32_t _c = 0; _c < _noise_chunk; ++_c) {\n" ;
            s "          _acc += _nb[_i];\n" ;
            s "          _i += _step;\n" ;
            s "          if (_i >= _noise_words) _i = (_noise_words > 0) ? (_i % _noise_words) : 0;\n" ;
            s "        }\n" ;
            s "      }\n" ;
            s "      if (_r > 0) het_scratch_bump(&_stress_tally[HET_TALLY_NOISE]);\n" ;
            s "      het_scratch_max(&_stress_tally[HET_TALLY_NOISE_ROUNDS], _r);\n" ;
            s "      if (_acc == 0xFFFFFFFFFFFFFFFFull)\n" ;
            s "        het_scratch_bump(&_stress_tally[HET_TALLY_NOISE]);  /* sink: force _acc to escape */\n" ;
            s "    } else {\n" ;
            s "    uint32_t _s = 0;\n" ;
            s "    for (;\n\
               \         _s < HET_STRESS_MAX_ROUNDS && het_scratch_read(_gpu_done) < HET_GPU_LANES;\n\
               \         ++_s) {\n" ;
            s "      if (het_rng_pct(&_rng, HET_MEM_STRESS_PCT))\n" ;
            s "        het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally);\n" ;
            s "    }\n" ;
            s "    if (_s >= HET_STRESS_MAX_ROUNDS)\n" ;
            s "      het_scratch_bump(&_stress_tally[HET_TALLY_TRUNC]);\n" ;
            s "    }\n" ;
            s "  }\n" ;
            s "}\n\n" ;

            (* The CPU pthread wrappers *)
            s dialect.gd_poke_def ;
            let cpu_ord = ref 0 in
            List.iter
              (fun cp ->
                let proc = cp.cp_proc in
                let addr = cp.cp_addrs and bufs = cpu_bufs cp in
                s (Printf.sprintf "struct cpu_args_P%d {\n" proc) ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr ;
                s "  uint64_t* barrier;\n" ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) bufs ;
                s "  uint8_t* _rdv; long _cap;\n" ;
                s "  int _core; uint32_t _seed; het_cpu_tally* _tally;\n" ;
                s "};\n" ;
                s (Printf.sprintf "static void* cpu_thread_P%d(void* _a) {\n" proc) ;
                s (Printf.sprintf "  cpu_args_P%d* a = (cpu_args_P%d*)_a;\n" proc proc) ;
                s "  het_cpu_affinity(a->_core, a->_tally);\n" ;
                let npl = List.length addr in
                if npl > 0 then begin
                  s (Printf.sprintf
                       "  uint32_t _plrng = het_cpu_rng_init(a->_seed, %du);\n" proc) ;
                  s "  uint64_t _plops = 0;\n"
                end ;
                (* Its own jitter stream: a GPU lane's delays would shift both
                   sides together, leaving the relative phase unchanged.  Lanes
                   past HET_TEST_BLOCKS*HET_BLOCK_DIM are no test lane's. *)
                s (Printf.sprintf
                     "  het_rng_t _jrng = het_rng_init(a->_seed, (uint32_t)(HET_TEST_BLOCKS*HET_BLOCK_DIM + %d));\n"
                     !cpu_ord) ;
                incr cpu_ord ;
                let call_args =
                  String.concat ","
                    (List.map (fun (_,a) -> Printf.sprintf "a->%s + _slot" a) addr
                     @ List.map (fun (_,b) -> Printf.sprintf "a->%s + _n" b) bufs) in
                s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                s "    size_t _slot = (size_t)_n * HET_SLOT_STRIDE_WORDS;\n" ;

                if npl > 0 then begin
                  (* The hint must name the line this iteration touches, so
                     the array is rebuilt per iteration. *)
                  s (Printf.sprintf "    void* const _pl[%d] = { %s };\n" npl
                       (String.concat ", "
                          (List.map
                             (fun (_,n) -> Printf.sprintf "(void*)(a->%s + _slot)" n)
                             addr))) ;
                  s (Printf.sprintf
                       "    _plops += het_cpu_preload(_pl, %d, &_plrng, HET_CPU_PRELOAD_PCT);\n"
                       npl)
                end ;
                s (Printf.sprintf
                     "    a->_rdv[_n] = het_rdv_host(a->barrier, (uint64_t)NPART*(uint64_t)(_n+1), a->_cap, %s);\n"
                     dialect.gd_poke_arg) ;
                s "    het_rdv_jitter(&_jrng, HET_RELEASE_JITTER);\n" ;
                s (Printf.sprintf "    het_run_P%d(%s);\n" proc call_args) ;
                s "  }\n" ;
                if npl > 0 then
                  s "  __atomic_fetch_add(&a->_tally->preload_ops, _plops, __ATOMIC_RELAXED);\n" ;
                s "  return NULL;\n}\n\n")
              it.i_cpus ;
            s it.i_labels ;
            s "/* Placement refusals.  Incremented only where placement EXISTS (the\n\
               \   CUDA render's cudaMemAdvise); stays 0 on the HIP render, which\n\
               \   carries no placement code. */\n" ;
            s "static int _het_place_failures = 0;\n\n" ;
            s dialect.gd_shared_mem_defs ;
            s "\n" ;
            s dialect.gd_noise_mem_defs ;
            s "\n" ;
            dump_gpu_main dialect s in

          (* comp.sh / Makefile / README *)
          (* `uname -m' of the rendered CPU ISA; an unknown macro maps to
             itself, which no uname matches: fail closed
             (hetlitmus/docs/het-emission.md,
             "Why both link paths refuse a foreign host"). *)
          let host_uname = match CpuF.host_macro with
            | "__aarch64__" -> "aarch64"
            | "__x86_64__" -> "x86_64"
            | m -> m in

          (* The build files' per-vendor vocabulary, folded over the filtered
             [dialects]; [d0] is the head they default to. *)
          let d0 = List.hd dialects in
          let targets = List.map (fun d -> d.gd_target) dialects in
          let comp_args =
            String.concat "|"
              (targets @ List.map (fun t -> t ^ "-link") targets) in

          let n_d = List.length dialects in
          let plural sing plur = if n_d = 1 then sing else plur in
          let enum l = match List.rev l with
            | [] -> ""
            | [x] -> x
            | x :: rest -> String.concat ", " (List.rev rest) ^ " and " ^ x in
          let count_word = function
            | 1 -> "The one" | 2 -> "Both" | 3 -> "All three" | 4 -> "All four"
            | k -> Printf.sprintf "All %d" k in

          let dump_comp ch =
            let s = output_string ch in
            s "#!/bin/sh\n" ;
            s (Printf.sprintf
                 "# Compile-only check for HetLitmus harness '%s' (%s render).\n"
                 tname (enum (List.map (fun d -> d.gd_name) dialects))) ;
            s (Printf.sprintf
                 "# COMPILE-ONLY by default (-c, no link, no GPU run); %s links ./%s too.\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`%s-link'" t) targets))
                 tname) ;
            s (Printf.sprintf "# Usage: sh comp.sh [%s]   (default %s)\n"
                 comp_args d0.gd_target) ;
            s (Printf.sprintf
                 "# Why the link is guarded, why every render writes ./%s, and the build\n"
                 tname) ;
            s "# knobs: hetlitmus/docs/het-emission.md\n" ;
            s "set -e\n" ;
            s (Printf.sprintf "TARGET=\"${1:-%s}\"\n" d0.gd_target) ;

            (* one `compiler ; arch' line per dialect *)
            let var_line d =
              Printf.sprintf "%s=\"${%s:-%s}\" ; %s=\"${%s:-%s}\""
                d.gd_compiler_var d.gd_compiler_var d.gd_compiler
                d.gd_arch_var d.gd_arch_var d.gd_arch_default in
            let var_w =
              List.fold_left
                (fun w d -> max w (String.length (var_line d))) 0 dialects in
            List.iter
              (fun d ->
                let v = var_line d in
                s (Printf.sprintf "%s%s # %s\n"
                     v (String.make (var_w - String.length v) ' ')
                     ("default arch " ^ d.gd_arch_default)))
              dialects ;
            s (Printf.sprintf
                 "HET_HOST_ISA=\"%s\"   # uname -m of this test's CPU ISA (%s)\n"
                 host_uname CpuF.isa_name) ;

            (* The ISA flags litmus7's lowering needs (e.g. rcpc): the cross
               line always, the host line only when the host IS this ISA. *)
            s (Printf.sprintf
                 "HET_CPU_CFLAGS=\"${HET_CPU_CFLAGS:-%s}\"\n" CpuF.cpu_cflags) ;
            s "HET_HOST_CFLAGS=\"\"\n" ;
            s "if [ \"$(uname -m)\" = \"$HET_HOST_ISA\" ]; then HET_HOST_CFLAGS=\"$HET_CPU_CFLAGS\"; fi\n" ;
            s "echo \"+ gcc -c outs.c\"\ngcc -c outs.c -o outs.o\n" ;
            s (Printf.sprintf
                 "echo \"+ gcc $HET_HOST_CFLAGS -c %s_cpu.c  (host build; %s asm under #if defined(%s))\"\n"
                 tname CpuF.isa_name CpuF.host_macro) ;
            s (Printf.sprintf "gcc $HET_HOST_CFLAGS -c %s_cpu.c -o %s_cpu_host.o\n"
                 tname tname) ;
            (match CpuF.cross with
             | Some (triple,std) ->
                s "if command -v clang >/dev/null 2>&1; then\n" ;
                s (Printf.sprintf
                     "  echo \"+ clang --target=%s $HET_CPU_CFLAGS -c %s_cpu.c  (real %s asm)\"\n"
                     triple tname CpuF.isa_name) ;
                s (Printf.sprintf
                     "  clang --target=%s -std=%s $HET_CPU_CFLAGS -c %s_cpu.c -o %s_cpu.o\n"
                     triple std tname tname) ;
                s (Printf.sprintf
                     "else\n  echo \"(no clang: skipped %s cross-assembly of %s_cpu.c)\"\nfi\n"
                     CpuF.isa_name tname)
             | None ->
                s (Printf.sprintf
                     "# (%s host == build host: the gcc -c above already assembled the real %s asm)\n"
                     CpuF.isa_name CpuF.isa_name)) ;
            s "case \"$TARGET\" in\n" ;
            List.iter
              (fun d ->
                let cc = "$" ^ d.gd_compiler_var
                and arch = "$" ^ d.gd_arch_var
                and obj = gpu_obj d tname in
                s (Printf.sprintf "  %s|%s-link)\n" d.gd_target d.gd_target) ;
                s (Printf.sprintf
                     "    if [ \"$TARGET\" = %s-link ] && [ \"$(uname -m)\" != \"$HET_HOST_ISA\" ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"error: comp.sh %s-link refuses on $(uname -m): %s_cpu_host.o here is the PORTABLE SHIM, not %s asm, so the binary would test nothing -- link on a $HET_HOST_ISA host\" >&2\n"
                     d.gd_target tname CpuF.isa_name) ;
                s "      exit 3\n" ;
                s "    fi\n" ;
                s (Printf.sprintf
                     "    command -v \"%s\" >/dev/null 2>&1 || { echo \"error: %s not found (%s toolchain absent)\" >&2 ; exit 1 ; }\n"
                     cc cc d.gd_toolchain) ;
                s (Printf.sprintf "    echo \"+ %s %s -c %s.%s\"\n"
                     cc (gpu_cflags d arch) tname d.gd_ext) ;
                s (Printf.sprintf "    %s %s -c %s.%s -o %s\n"
                     cc (gpu_cflags d arch) tname d.gd_ext obj) ;
                s (Printf.sprintf "    if [ \"$TARGET\" = %s-link ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"+ %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\"\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s (Printf.sprintf
                     "      %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s "    fi ;;\n")
              dialects ;
 
            s (Printf.sprintf
                 "  *) echo \"comp.sh: unknown target \\\"$TARGET\\\" -- this directory is %s-only (accepted: %s)\" >&2 ; exit 2 ;;\n"
                 (String.concat "/" targets) comp_args) ;
            s "esac\n" ;
            s (Printf.sprintf "if %s; then\n"
                 (String.concat " || "
                    (List.map
                       (fun t -> Printf.sprintf "[ \"$TARGET\" = %s-link ]" t)
                       targets))) ;
            s (Printf.sprintf "  echo \"HetLitmus: link OK -> ./%s\"\n" tname) ;
            s "else\n" ;
            s "  echo 'HetLitmus: compile OK'\n" ;
            s "fi\n" in
          let dump_makefile ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "# HetLitmus harness '%s' -- objects by default (`make %s');\n"
                 tname d0.gd_target) ;
            s (Printf.sprintf
                 "# %s %s ./%s, guarded by uname -m.\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s-bin'" t)
                       targets))
                 (plural "links" "link") tname) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s ?= %s\n%s ?= %s\n"
                     d.gd_compiler_var d.gd_compiler
                     d.gd_arch_var d.gd_arch_default))
              dialects ;
            s "CC ?= gcc\n" ;
            s (Printf.sprintf "HET_CPU_CFLAGS ?= %s\n" CpuF.cpu_cflags) ;
            s (Printf.sprintf
                 "# uname -m of this test's CPU ISA (%s); the %s-bin guard compares it.\n"
                 CpuF.isa_name d0.gd_target) ;
            s (Printf.sprintf "HET_HOST_ISA ?= %s\n" host_uname) ;
            (* Keyed on the literal uname word, not on HET_HOST_ISA: overriding
               that to link on a foreign host must not hand its gcc this -march. *)
            s (Printf.sprintf
                 "HET_HOST_CFLAGS := $(if $(filter %s,$(shell uname -m)),$(HET_CPU_CFLAGS))\n\n"
                 host_uname) ;
            s (Printf.sprintf "all: %s\n\n" d0.gd_target) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname))
              dialects ;
            s "\n" ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s.%s\n\t$(%s) %s -c $< -o $@\n\n"
                     (gpu_obj d tname) tname d.gd_ext d.gd_compiler_var
                     (gpu_cflags d (Printf.sprintf "$(%s)" d.gd_arch_var))))
              dialects ;
            s "outs.o: outs.c\n\t$(CC) -c $< -o $@\n\n" ;
            s (Printf.sprintf
                 "%s_cpu_host.o: %s_cpu.c\n\t$(CC) $(HET_HOST_CFLAGS) -c $< -o $@\n\n"
                 tname tname) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s-bin: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname) ;
                s (Printf.sprintf
                     "\t@ test \"$$(uname -m)\" = \"$(HET_HOST_ISA)\" || { echo \"error: %s-bin refuses on $$(uname -m): %s_cpu_host.o here is the PORTABLE SHIM, not %s asm, so the binary would test nothing -- link on a $(HET_HOST_ISA) host\" >&2 ; exit 3 ; }\n"
                     d.gd_target tname CpuF.isa_name) ;
                s (Printf.sprintf "\t$(%s) %s$(%s) $^ -o %s -lpthread -lm\n\n"
                     d.gd_compiler_var d.gd_arch_flag d.gd_arch_var tname))
              dialects ;
            s ".SUFFIXES:\n\n" ;
            s (Printf.sprintf "%s:\n" tname) ;
            s (Printf.sprintf
                 "\t@ echo \"error: \\`make %s' is not a build target: it would bypass the uname -m guard.  Link it with %s, %s uname -m first.\" >&2 ; exit 3\n\n"
                 tname
                 (String.concat " or "
                    (List.map
                       (fun d -> Printf.sprintf "\\`make %s-bin' (%s)"
                                   d.gd_target d.gd_vendor)
                       dialects))
                 (plural "which checks" "which all check")) ;
            s (Printf.sprintf
                 ".PHONY: all %s clean %s\nclean:\n\trm -f *.o %s\n"
                 (String.concat " "
                    (List.map (fun t -> Printf.sprintf "%s %s-bin" t t)
                       targets))
                 tname tname) in
          let dump_readme ch =
            let s = output_string ch in
            s (Printf.sprintf "# HetLitmus heterogeneous harness: %s\n\n" tname) ;
            s (Printf.sprintf "CPU ISA: %s.  GPU dialect%s: %s.\n\n"
                 CpuF.isa_name (plural "" "s")
                 (String.concat " + "
                    (List.map
                       (fun d -> Printf.sprintf "%s (`.%s`)" d.gd_name d.gd_ext)
                       dialects))) ;
            s "Files:\n" ;
            let ext_w =
              List.fold_left
                (fun w d -> max w (String.length d.gd_ext)) 0 dialects + 4 in
            List.iter
              (fun d ->
                s (Printf.sprintf "- `%s.%s`%s%s" tname d.gd_ext
                     (String.make (ext_w - String.length d.gd_ext) ' ')
                     d.gd_readme_files))
              dialects ;
            s (Printf.sprintf
                 "- `%s_cpu.c`  CPU thread(s): litmus7's own %s inline asm (ASMLang).\n"
                 tname CpuF.isa_name) ;
            s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
            s (Printf.sprintf
                 "- `comp.sh` / `Makefile`  compile-only build, plus %s guarded link target%s.\n\n"
                 (plural "the" "the two") (plural "" "s")) ;
            s (Printf.sprintf
                 "Build (compile-only, no GPU): `sh comp.sh [%s]` (default %s), or %s.\n"
                 (String.concat "|" targets) d0.gd_target
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s`" t)
                       targets))) ;
            List.iter
              (fun d ->
                s (Printf.sprintf
                     "Link: `sh comp.sh %s-link` or `make %s-bin` writes `./%s` from `%s`\n"
                     d.gd_target d.gd_target tname (gpu_obj d tname)) ;
                s (Printf.sprintf "  (%s: `$%s %s$%s`, %s).\n"
                     d.gd_vendor d.gd_compiler_var d.gd_arch_flag d.gd_arch_var
                     ("default " ^ d.gd_arch_default)))
              dialects ;
            s (Printf.sprintf
                 "%s link paths REFUSE unless `uname -m` is `%s`: elsewhere\n"
                 (count_word (2 * n_d)) host_uname) ;
            s (Printf.sprintf
                 "`%s_cpu_host.o` is the portable shim, not the %s asm, and the binary\n"
                 tname CpuF.isa_name) ;
            s "would test nothing.\n\n" ;
            s (Printf.sprintf
                 "The build knobs and why `make %s` refuses:\n" tname) ;
            s "`hetlitmus/docs/het-emission.md`.\n\n" ;
            s (Printf.sprintf "Target%s: %s.\n" (plural "" "s")
                 (enum
                    (List.map
                       (fun d -> Printf.sprintf "%s %s" d.gd_vendor d.gd_name)
                       dialects))) ;
            s (Printf.sprintf
                 "Pair: `%s` -- the CPU ISA and GPU dialect this harness was built\n"
                 pair_label) ;
            s "for, stamped as HET_PAIR_NAME; results are filed under it, and it names\n" ;
            s "no machine.\n" in
          write "outs.h" (fun ch -> output_string ch outs_h_content) ;
          write "outs.c" (fun ch -> output_string ch outs_c_content) ;
          write "het_stress.h" (fun ch -> output_string ch het_stress_content) ;
          write "het_cpu_stress.h"
            (fun ch -> output_string ch het_cpu_stress_content) ;
          write "het_verdict.h"
            (fun ch -> output_string ch het_verdict_content) ;
          write "het_rdv.h" (fun ch -> output_string ch het_rdv_content) ;
          write (tname ^ "_cpu.c") dump_cpu_file ;
          let renders =
            List.map (fun d -> Printf.sprintf "%s.%s" tname d.gd_ext) dialects in
          List.iter
            (fun d -> write (Printf.sprintf "%s.%s" tname d.gd_ext)
                        (dump_gpu_file d))
            dialects ;
          write "comp.sh" dump_comp ;
          write "Makefile" dump_makefile ;
          write "README.md" dump_readme ;
          if O.verbose >= 0 then
            Printf.eprintf
              "HetLitmus: emitted harness directory %s (%s)\n%!"
              dir (String.concat " + " renders) ;
          Absent
        with e ->
          if O.nocatch then raise e ;
          HetArch.refused "het" src_name e
    end
