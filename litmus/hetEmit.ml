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
         val toolchain : HetCpuFront.toolchain
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

      (* ================= derivation ================= *)
      (* One parsed het test becomes a HetHarness.t through the named steps
         below; each yields one sub-record, and every refusal fires in one of
         them -- before `run' creates the directory. *)

      let prop_of = function
        | ConstrGen.ForallStates p | ConstrGen.ExistsState p
        | ConstrGen.NotExistsState p -> p

      (* The CPU half as a MiscParser test litmus7's own compiler accepts: the
         cpu-tagged procs, the init lines that reach them, and the condition
         atoms naming one of their registers. *)
      let cpu_projection parsed =
        let dev_of_proc p =
          let rec find = function
            | ((q,annot,_),_)::_ when q=p ->
               (match annot with Some (d::_) -> d | _ -> "?")
            | _::rest -> find rest
            | [] -> "?" in
          find parsed.MiscParser.prog in
        let is_cpu p = dev_of_proc p = "cpu" in
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
        { MiscParser.info = parsed.MiscParser.info ;
          init = cpu_init ;
          prog = cpu_prog ;
          filter = None ;
          condition = ConstrGen.ExistsState cpu_prop ;
          locations = [] ;
          extra_data = MiscParser.empty_extra ; }

      (* Compiling that projection: the global environment ASMLang dumps
         against -- an array global by element type, as dump_fun takes them --
         and one (proc, template, env) per CPU proc. *)
      let compile_cpu doc cpu_parsed =
        let cpu_allocated = AllocCpu.allocate_regs cpu_parsed in
        let cpu_globals, cpu_code = CpuKit.compile_code doc cpu_allocated in
        let global_env =
          List.map
            (fun (loc,t) ->
              let t = match t with
                | CType.Array (b,_) -> CType.Base b
                | _ -> t in
              loc,t)
            cpu_globals in
        let params =
          List.map
            (fun (proc,(out,(_outregs,envV))) -> (proc, out, envV))
            cpu_code in
        global_env, params

      let cpu_addr_params global_env out =
        let addrs,_ptes = Cpu.Out.get_addrs out in
        List.map
          (fun a ->
            let ty =
              try List.assoc a global_env with Not_found -> Compile.base in
            (Printf.sprintf "%s *%s" (SkelUtil.dump_global_type a ty) a, a))
          addrs

      (* (declaration, name, the register as a condition spells it, type) *)
      let cpu_out_infos out proc =
        List.map
          (fun reg ->
            let t = Cpu.Out.RegMap.find reg out.Cpu.Out.ty_env in
            let t = if CType.is_tag_ptr t then CType.pointer_type t else t in
            let ty = CType.dump t in
            let n = Cpu.Out.dump_out_reg proc reg in
            (Printf.sprintf "%s *%s" ty n, n, Cpu.pp_reg reg, ty))
          out.Cpu.Out.final

      let cpu_procs global_env params =
        List.map
          (fun (proc,out,envV) ->
            { cp_proc = proc ;
              cp_addrs = cpu_addr_params global_env out ;
              cp_outs =
                List.map (fun (d,n,_,_) -> (d,n)) (cpu_out_infos out proc) ;
              cp_dump =
                (fun ch ->
                  CpuKit.dump_fun ch Template.no_extra_args global_env envV
                    proc out) })
          params

      (* The GPU half (reuse CudaLang translation): its procs in program
         order, the locations they touch, and the launch geometry the scope
         tree places them in. *)
      let gpu_projection parsed =
        let gpu_prog =
          List.filter_map
            (fun ((p,annot,f),code) -> match annot with
              | Some ("gpu"::_) ->
                 Some ((p,annot,f),List.map Arch'.to_gpu_pseudo code)
              | _ -> None)
            parsed.MiscParser.prog in
        let gpu_globals = CudaLang.collect_globals gpu_prog in
        let layout,n_blocks,block_dim =
          CudaLang.layout_of_scopes None
            (List.map (fun ((p,_,_),_) -> p) gpu_prog) in
        let gpus =
          List.map
            (fun ((p,_,_),code) ->
              let blk,lane = layout p in
              { gp_proc = p ; gp_blk = blk ; gp_lane = lane ;
                gp_instrs = CudaLang.instrs_of_code code ;
                gp_regs = CudaLang.result_regs code })
            gpu_prog in
        gpus, gpu_globals, n_blocks, block_dim

      (* What each proc makes observable, in outcome-column order: a CPU
         proc's `Out.final' registers -- those the synthesized CPU condition
         names, and only those -- and a GPU proc's load destinations. *)
      let observable_columns parsed params =
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
             parsed.MiscParser.prog)

      (* What the driver allocates: the shared globals both devices race on,
         each once, and one read buffer of SIZE_OF_TEST per observable
         column. *)
      let memory_map global_env params gpu_globals proc_infos =
        let read_buffers =
          List.concat_map
            (fun (p,dev,obs) ->
              List.mapi
                (fun li (_,ty) ->
                  { rb_proc = p ; rb_name = buf_name_of p li ;
                    rb_dev = dev ; rb_type = ty })
                obs)
            proc_infos in
        let cpu_addrs =
          List.concat_map
            (fun (_,out,_) -> List.map snd (cpu_addr_params global_env out))
            params in
        let all_globals =
          let seen = Hashtbl.create 8 in
          List.filter
            (fun g -> if Hashtbl.mem seen g then false
                      else (Hashtbl.add seen g () ; true))
            (cpu_addrs @ gpu_globals) in
        { me_gpu_globals = gpu_globals ; me_all_globals = all_globals ;
          me_bufs = read_buffers }

      (* The outcome columns -- registers first, then the condition's
         locations -- and the condition compiled against those indices. *)
      let outcome_vector tname parsed memory proc_infos =
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
        let loc_slots =
          List.filter_map
            (fun g ->
              let name = MiscParser.dump_value g in
              if List.mem name memory.me_all_globals then Some name else None)
            (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
        let weak_expr =
          HetCond.c_predicate
            ~reg_slots:(List.map fst slots) ~loc_slots
            (prop_of parsed.MiscParser.condition) in
        if HetCond.predicate_is_constant weak_expr then
          Warn.fatal
            "hetlitmus: %s would emit a CONSTANT weak-behaviour detector \
             (_weak = %s) -- refusing to emit"
            tname weak_expr ;
        { oc_reg_columns = slots ; oc_loc_columns = loc_slots ;
          oc_weak_expr = weak_expr }

      (* The names every rendered file stamps, including the (CPU ISA x GPU
         dialect) pair this harness is built for.  A het test has at least one
         gpu proc. *)
      let harness_identity parsed tname dialects =
        let has_gpu =
          List.exists
            (fun ((_,annot,_),_) ->
              match annot with Some ("gpu"::_) -> true | _ -> false)
            parsed.MiscParser.prog in
        if not has_gpu then
          Warn.fatal
            "hetlitmus: %s has no gpu proc; a het test needs at least one, \
             and an all-CPU test is litmus7's own %s path"
            tname CpuF.toolchain.HetCpuFront.isa_name ;
        { id_name = tname ;
          id_ident = CudaLang.c_ident tname ;
          id_pair_label =
            Printf.sprintf "(%s, %s)"
              CpuF.toolchain.HetCpuFront.isa_name
              (List.hd dialects).gd_target }

      (* The file emitters' whole input: none of them reads the functor.  This
         is the one step holding every intermediate at once. *)
      let derive_harness doc parsed identity dialects =
        let global_env,params = compile_cpu doc (cpu_projection parsed) in
        let gpus,gpu_globals,n_blocks,block_dim = gpu_projection parsed in
        let proc_infos = observable_columns parsed params in
        let memory = memory_map global_env params gpu_globals proc_infos in
        let outcome =
          outcome_vector identity.id_name parsed memory proc_infos in
        { h_identity = identity ;
          h_geometry =
            { ge_size = Cfg.size ; ge_runs = Cfg.runs ;
              ge_bdim = block_dim ;
              ge_npart = List.length params + List.length gpus ;
              ge_blocks = n_blocks ;
              ge_lanes = List.length gpus } ;
          h_procs =
            { pr_cpus = cpu_procs global_env params ; pr_gpus = gpus ;
              pr_participants =
                List.map (fun (p,dev,_) -> (p,dev)) proc_infos } ;
          h_memory = memory ;
          h_outcome = outcome ;
          h_toolchain = CpuF.toolchain ;
          h_dialects = dialects }

      (* The plan litmus7 prints before anything is written. *)
      let report_plan parsed identity =
        Printf.eprintf
          "HetLitmus: emitting CPU+GPU harness for %s (%d procs, CPU=%s)\n%!"
          identity.id_name (List.length parsed.MiscParser.prog)
          CpuF.toolchain.HetCpuFront.isa_name ;
        List.iter
          (fun ((p,annot,_),_code) ->
            let dev = match annot with Some (d::_) -> d | _ -> "?" in
            Printf.eprintf "  P%d device=%s -> %s\n%!" p dev
              (match dev with
               | "cpu" ->
                  Printf.sprintf "CPU pthread (litmus7 %s asm)"
                    CpuF.toolchain.HetCpuFront.isa_name
               | "gpu" -> "GPU kernel (LISA/PTX via CudaLang/HipLang)"
               | _ -> "unknown"))
          parsed.MiscParser.prog ;
        Printf.eprintf "  pair: %s\n%!" identity.id_pair_label

      let run _hash_env src_name in_chan _out_chan splitted =
        try
          let dialects = HetDialect.select ~key:(fun d -> d.gd_target) dialects in
          let parsed = P.parse in_chan splitted in
          close_in in_chan ;
          let tname = splitted.Splitter.name.Name.name in
          let identity = harness_identity parsed tname dialects in
          let h =
            derive_harness splitted.Splitter.name parsed identity dialects in
          if O.verbose >= 0 then report_plan parsed identity ;

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
