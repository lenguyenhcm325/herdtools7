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

(* HetLitmus: the compound (CPU+GPU) harness emitter -- it parses the test,
   derives the harness record its file emitters render, and writes the
   directory.  Design: hetlitmus/docs/het-emission.md. *)

open Answer

open HetDialect

open HetHarness

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
          (* `uname -m' of the rendered CPU ISA; an unknown macro maps to
             itself, which no uname matches: fail closed
             (hetlitmus/docs/het-emission.md,
             "Why both link paths refuse a foreign host"). *)
          let host_uname = match CpuF.host_macro with
            | "__aarch64__" -> "aarch64"
            | "__x86_64__" -> "x86_64"
            | m -> m in
          (* The file emitters' whole input: none of them reads the functor. *)
          let h =
            { h_name = tname ; h_ident = id ; h_pair_label = pair_label ;
              h_cpu_only = cpu_only ; h_shape = it ;
              h_size = Cfg.size ; h_runs = Cfg.runs ;
              h_toolchain =
                { HetCpuFront.isa_name = CpuF.isa_name ;
                  host_macro = CpuF.host_macro ; host_uname ;
                  cross = CpuF.cross ; cpu_cflags = CpuF.cpu_cflags } ;
              h_dialects = dialects } in

          (* ================= file emission ================= *)
          let base =
            if O.is_out && (try Sys.is_directory O.tarname with _ -> false)
            then O.tarname else Sys.getcwd () in
          let dir = Filename.concat base tname in
          if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
          let write fname f =
            Misc.output_protect f (Filename.concat dir fname) in

          write "outs.h" (fun ch -> output_string ch outs_h_content) ;
          write "outs.c" (fun ch -> output_string ch outs_c_content) ;
          write "het_stress.h" (fun ch -> output_string ch het_stress_content) ;
          write "het_cpu_stress.h"
            (fun ch -> output_string ch het_cpu_stress_content) ;
          write "het_verdict.h"
            (fun ch -> output_string ch het_verdict_content) ;
          write "het_rdv.h" (fun ch -> output_string ch het_rdv_content) ;
          write (tname ^ "_cpu.c") (HetCpuFile.dump h) ;
          let renders =
            List.map (fun d -> Printf.sprintf "%s.%s" tname d.gd_ext) dialects in
          List.iter
            (fun d -> write (Printf.sprintf "%s.%s" tname d.gd_ext)
                        (HetGpuFile.dump h d))
            dialects ;
          write "comp.sh" (HetBuildFiles.dump_comp h) ;
          write "Makefile" (HetBuildFiles.dump_makefile h) ;
          write "README.md" (HetBuildFiles.dump_readme h) ;
          if O.verbose >= 0 then
            Printf.eprintf
              "HetLitmus: emitted harness directory %s (%s)\n%!"
              dir (String.concat " + " renders) ;
          Absent
        with e ->
          if O.nocatch then raise e ;
          HetArch.refused "het" src_name e
    end
