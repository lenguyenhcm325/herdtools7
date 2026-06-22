(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2010-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(***********************************************)
(* Parse a source file for the needs of litmus *)
(* (And then compile test)                     *)
(***********************************************)

open Answer

module type CommonConfig = sig
  val verbose : int
  val limit : bool
  val timeloop : int
  val stride : Stride.t
  val avail : int option
  val runs : int
  val size : int
  val noccs : int
  val timelimit : float option
  val isync : bool
  val speedcheck : Speedcheck.t
  val safer : Safer.t
  val cautious : bool
  val preload : Preload.t
  val memory : Memory.t
  val alloc : Alloc.t
  val doublealloc : bool
  val threadstyle : ThreadStyle.t
  val launch : Launch.t
  val barrier : Barrier.t
  val linkopt : string
  val logicalprocs : int list option
  val affinity : Affinity.t
  val targetos : TargetOS.t
  val is_out : bool
  val exit_cond : bool
  val sleep : int
  val driver : Driver.t
  val crossrun : Crossrun.t
  val adbdir : string
  val makevar : string list
  val gcc : string
  val c11 : bool
  val ascall : bool
  val fault_handling : Fault.Handling.t
  val mte_precision : Precision.t
  val variant : Variant_litmus.t -> bool
  val nocatch : bool
  val stdio : bool
  val xy : bool
  val morearch : MoreArch.t
  val carch : Archs.System.t
  val syncconst : int
  val numeric_labels : bool
  val kind : bool
  val force_affinity : bool
  val smtmode : Smt.t
  val smt : int
  val nsockets : int
  val contiguous : bool
  val noalign : Align.t option
  val syncmacro : int option
  val collect : Collect.t
  val hexa : bool
  val verbose_barrier : bool
  val verbose_prelude : bool
  val check_kind : string -> ConstrGen.kind option
  val check_cond : string -> string option
  val check_nstates : string -> int option
  val cross : bool
  val tarname : string
  val hint : string option
  val no : string option
  val index : string option
  val outnames : string option
end

module type TopConfig = sig
  include CommonConfig
  val platform : string
  val check_name : string -> bool
  val check_rename : string -> string option
  (* Arch dependent options *)
  val mkopt : Option.opt -> Option.opt
  (* Mode *)
  val mode : Mode.t
  (* usearch *)
  val usearch : UseArch.t
  (* Hum *)
  val asmcomment : string option
  val asmcommentaslabel : bool
end

module type Config = sig
  include GenParser.Config
  include Compile.Config
  val asmcommentaslabel : bool
  val sysarch : Archs.System.t
  (* Additions for Presi *)
  val line : int
  val noccs : int
  val timelimit : float option
  val check_nstates : string -> int option
  val fault_handling : Fault.Handling.t
  (* End of additions *)
  include Skel.Config
  include Run_litmus.Config
  val limit : bool
  val word : Word.t
  val noinline : bool
end

module Top (OT:TopConfig) (Tar:Tar.S) : sig
  val from_files : string list -> unit
end = struct

  (************************************************************)
  (* Some configuration dependent stuff, to be performed once *)
  (************************************************************)

  (* Avoid cycles *)
  let read_no fname =
    Misc.input_protect
      (fun chan -> MySys.read_list chan (fun s -> Some s))
      fname

  let avoid_cycle =
    let xs = match OT.no with
      | None -> []
      | Some fname -> read_no fname in
    let set = StringSet.of_list xs in
    fun cy -> StringSet.mem cy set

  (* hints *)
  let hint = match OT.hint with
    | None -> Hint.empty
    | Some fname -> Hint.read fname

  module W = Warn.Make(OT)


  module Utils (O:Config) (A':Arch_litmus.Base)
           (Lang:Language.S with type t = A'.Out.t)
           (Pseudo:PseudoAbstract.S with type ins = A'.instruction) =
    struct

      module T = Test_litmus.Make(O)(A')(Pseudo)
      module R = Run_litmus.Make(O)(Tar)(T.D)
      module H = LitmusUtils.Hash(O)

      let get_cycle t =
        let info = t.MiscParser.info in
        List.assoc "Cycle" info

      let cycle_ok avoid t =
        try
          let cy = get_cycle t in
          not (avoid cy)
        with Not_found -> true


      let change_hint hint name t =
        try
          let more_info = Hint.get hint name in
          let info =
            more_info @
              List.filter
                (fun (k,_) ->
                  try
                    let _ = List.assoc k more_info in
                    false
                  with Not_found -> true)
                t.MiscParser.info in
          { t with MiscParser.info = info; }
        with Not_found -> t

      let dump source doc compiled =
        let outname = Tar.outname source in
        try
          Misc.output_protect
            (fun chan ->
              let module Out =
                Indent.Make(struct let hexa = O.hexa let out = chan end) in
              let dump =
                match OT.mode with
                | Mode.Std ->
                    let module S = Skel.Make(O)(Pseudo)(A')(T)(Out)(Lang) in
                    S.dump
                | Mode.PreSi|Mode.Kvm ->
                    let module O =
                      struct
                        include O
                        let is_kvm = match OT.mode with
                        | Mode.Kvm -> true
                        | Mode.PreSi -> false
                        | Mode.Std -> assert false
                        let is_tb = match OT.barrier with
                        | Barrier.TimeBase  -> true
                        | _ -> false
                      end  in
                    let module S = PreSi.Make(O)(Pseudo)(A')(T)(Out)(Lang) in
                    S.dump in
              dump doc compiled)
            outname
        with e ->
          begin try Sys.remove outname with _ -> () end ;
          raise e

      let check_variant v a =
        if O.variant v && not (Variant_litmus.ok v a) then
          Warn.user_error
            "variant %s does not apply to arch %s"
            (Variant_litmus.pp v)
            (Archs.pp a) ;
        let v = Variant_litmus.Vmsa in
        if O.variant v && O.mode != Mode.Kvm then
          Warn.user_error
            "(optional) variant %s not compatible with mode %s"
            (Variant_litmus.pp v)
            (Mode.pp O.mode)

      let limit_ok nprocs = match O.avail with
        | None|Some 0 -> true
        | Some navail -> not O.limit || nprocs <= navail

      let warn_limit name nprocs = match O.avail with
        | None|Some 0 -> ()
        | Some navail ->
           if nprocs > navail then
             Warn.warn_always
               "%stest with more threads (%i) than available (%i) is compiled"
               (Pos.str_pos0 name.Name.file) nprocs navail

      let compile
            parse count_procs compile allocate
            hash_env
            name in_chan out_chan splitted =
        try begin
            check_variant Variant_litmus.Self splitted.Splitter.arch ;
            let parsed = parse in_chan splitted in
            let doc = splitted.Splitter.name in
            let tname = doc.Name.name in
            close_in in_chan ;
            let nprocs = count_procs parsed.MiscParser.prog in
            let hash =  H.mk_hash_info name parsed.MiscParser.info in
            let cycle_ok = cycle_ok avoid_cycle parsed
            and hash_ok = H.hash_ok hash_env tname hash
            and limit_ok = limit_ok nprocs in
            if
              cycle_ok && hash_ok && limit_ok
            then begin
                warn_limit doc nprocs ;
                let parsed = change_hint hint doc.Name.name parsed in
                let allocated = allocate parsed in
                let compiled = compile doc allocated in
                let src = MyName.outname name ".c" in
                let flags =
                  { Flags.pac = O.variant (Variant_litmus.PacVersion `PAuth1) ||
                                O.variant (Variant_litmus.PacVersion `PAuth2);
                    Flags.self = O.variant Variant_litmus.Self;
                    Flags.memtag = O.variant Variant_litmus.MemTag;
                    Flags.exs = O.variant Variant_litmus.ExS;
                    Flags.ets = O.variant Variant_litmus.ETS2 } in
                dump src doc compiled;
                if not OT.is_out then begin
                    let _utils =
                      let module OO = struct
                        include OT
                        let arch = A'.arch
                        let sysarch = Archs.get_sysarch A'.arch OT.carch
                        let cached =
                          match threadstyle with
                          | ThreadStyle.Cached -> true
                          | _ -> false
                      end in
                      let module Obj = ObjUtil.Make(OO)(Tar) in
                      Obj.dump flags in
                    ()
                  end ;
                R.run name out_chan doc allocated src ;
                Completed
                  { arch = A'.arch; doc; src; fullhash = hash ;
                    nprocs; flags; }
              end else begin
                let cause = if limit_ok then "" else " (too many threads)" in
                Warn.warn_always "%s test not compiled%s"
                  (Pos.str_pos0 doc.Name.file) cause ;
                Absent
              end
          end with e -> if OT.nocatch then raise e ; Interrupted e
    end


  module Make
           (O:Config)
           (A:Arch_litmus.S)
           (L:GenParser.LexParse with type instruction = A.parsedPseudo)
           (XXXComp : XXXCompile_litmus.S with module A = A) =
    struct
      module Pseudo = LitmusUtils.Pseudo(A)
      module ALang = struct
        include A.I
        module RegSet = A.Out.RegSet
        module RegMap = A.Out.RegMap
      end
      module Lang = ASMLang.Make(O)(ALang)(A.Out)(A)
      module Utils = Utils(O)(A)(Lang)(Pseudo)
      module P = GenParser.Make(O)(A) (L)
      module Comp = Compile.Make (O)(A)(Utils.T)(XXXComp)

      module AllocArch = struct
        include A
        type v = A.V.v
        let maybevToV = A.maybevToV
        type global = Global_litmus.t
        let maybevToGlobal = A.tr_global
      end

      let compile =
        let allocate parsed =
          let module Alloc = SymbReg.Make(AllocArch) in
          Alloc.allocate_regs parsed in
        Utils.compile P.parse MiscParser.count_procs Comp.compile allocate
    end


  module Make'
           (O:Config)
           (A:sig val comment : string end) =
    struct
      module L = struct
        type token = CParser.token
        module CL = CLexer.Make(struct let debug = false end)
        let lexer = CL.token false
        let parser lexer buf = fst (CParser.shallow_main lexer buf)
      end

      module A' = CArch_litmus.Make(O)

      module Pseudo =
        struct
          type ins = A'.instruction
          include DumpCAst
          let code_exists _ _ = assert false
          let exported_labels_code _ = Label.Full.Set.empty
          let from_labels _ _ = []
          let all_labels _ = []
        end

      module Lang =
        CLang.Make
          (struct
            let comment = A.comment
            let memory = O.memory
            let mode = O.mode
            let asmcommentaslabel = O.asmcommentaslabel
          end)
          (struct
            let verbose = O.verbose
            let noinline = true
            let simple = false
          end)
      module Utils = Utils(O)(A')(Lang)(Pseudo)
      module P = CGenParser_litmus.Make(O)(Pseudo)(A')(L)
      module Comp =
        CCompile_litmus.Make
          (struct include O let kernel = false let rcu = false end)(Utils.T)

      let compile =
        let allocate parsed =
          let module Alloc = CSymbReg.Make(A') in
          Alloc.allocate_regs parsed in
        Utils.compile P.parse A'.count_procs Comp.compile allocate
    end

  let debuglexer =  OT.verbose > 2

  module LexConfig =
    struct
      let debug = debuglexer
      let check_rename = OT.check_rename
    end


  module SP = Splitter.Make(LexConfig)

  let from_chan hash_env name in_chan out_chan =
    (* First split the input file in sections *)
    let { Splitter.arch=arch ; _ } as splitted =
      SP.split name in_chan in
    let tname = splitted.Splitter.name.Name.name in
    if OT.check_name tname then begin
        (* Read variant field in test *)
        let module TestConf =
          TestVariant.Make
            (struct
              module Opt = Variant_litmus
              let info = splitted.Splitter.info
              let variant = OT.variant
              let mte_precision = OT.mte_precision
              let mte_store_only = false
              let fault_handling = OT.fault_handling
              let sve_vector_length = 0
              let sme_vector_length = 0
            end) in
        (* Then call appropriate compiler, depending upon arch *)
        let opt = OT.mkopt (Option.get_default arch) in
        let word = Option.get_word opt in
        let module ODep = struct
            let word = word
            let line = Option.get_line opt
            let delay = Option.get_delay opt
            let gccopts = Option.get_gccopts opt
          end in
        (* Compile configuration, must also be used to configure arch modules *)
        let module OC = struct
          let verbose = OT.verbose
          let word = word
          let syncmacro =OT.syncmacro
          let syncconst = OT.syncconst
          let memory = OT.memory
          let morearch = OT.morearch
          let cautious = OT.cautious
          let asmcomment = OT.asmcomment
          let hexa = OT.hexa
          let mode = OT.mode
          let precision = TestConf.fault_handling
        end in
        let module Cfg = struct
          include GenParser.DefaultConfig
          include OT
          let hash = HashInfo.Std
          let precision = TestConf.fault_handling
          let tagcheck = TestConf.mte_precision
          let variant = TestConf.variant
          include ODep
          let debuglexer = debuglexer
          let sysarch =
            match arch,Archs.get_sysarch arch  OT.carch with
            | `C,`Unknown->
                if not OT.c11 then
                Warn.user_error "Test %s in C not performed, because no option -carch <arch> or -c11 true is present" tname ;
                `Unknown
            | _,a -> a
          let noinline = true
          end in
        let aux = function
          | `PPC ->
             begin match OT.usearch with
             | UseArch.Trad ->
                let module V = Int64Constant.Make(PPCInstr) in
                let module Arch' = PPCArch_litmus.Make(OC)(V) in
                let module LexParse = struct
                    type instruction = Arch'.parsedPseudo
                    type token = PPCParser.token
                    module Lexer = PPCLexer.Make(LexConfig)
                    let lexer = Lexer.token
                    let parser = MiscParser.mach2generic PPCParser.main
                  end in
                let module Compile = PPCCompile_litmus.Make(V)(OC) in
                let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
                X.compile
             | UseArch.Gen ->
                assert false
             (*
  let module Arch' = PPCGenArch.Make(OC)(V) in
  let module LexParse = struct
  type instruction = Arch'.pseudo
  type token = PPCGenParser.token
  module Lexer = PPCGenLexer.Make(LexConfig)
  let lexer = Lexer.token
  let parser = PPCGenParser.main
  end in
  let module Compile = PPCGenCompile.Make(V)(OC) in
  let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
  X.compile
              *)
             end
          | `X86 ->
             let module V = Int32Constant.Make(X86Base.Instr) in
             let module Arch' = X86Arch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = X86Parser.token
                 module Lexer = X86Lexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic X86Parser.main
               end in
             let module Compile = X86Compile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `X86_64 ->
             let module V = Int64Constant.Make(X86_64Base.Instr) in
             let module Arch' = X86_64Arch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = X86_64Parser.token
                 module Lexer = X86_64Lexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic X86_64Parser.main
               end in
             let module X86_64Config = struct
                 let sse =
                   match OT.mode with
                   | Mode.Kvm -> false
                   | Mode.PreSi|Mode.Std -> true
                 let reason = "-mode kvm"
               end in
             let module Compile =
               X86_64Compile_litmus.Make(X86_64Config)(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `ARM ->
             let module V = Int32Constant.Make(ARMInstr) in
             let module Arch' = ARMArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = ARMParser.token
                 module Lexer = ARMLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic ARMParser.main
               end in
             let module Compile = ARMCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `AArch64 ->
             begin match OT.usearch with
             | UseArch.Trad ->
                let module V =
                  SymbConstant.Make
                    (Int64Scalar)(AArch64PteVal)(AArch64AddrReg)
                    (AArch64Instr.Std) in
                let module Arch' = AArch64Arch_litmus.Make(OC)(V) in
                let module LexParse = struct
                  type instruction = Arch'.parsedPseudo
                  type token = AArch64Parser.token
                  module Lexer =
                    AArch64Lexer.Make
                      (struct include LexConfig let is_morello = false end)
                  let lexer = Lexer.token
                  let parser = (*MiscParser.mach2generic*) AArch64Parser.main
                end in
                let module Compile = AArch64Compile_litmus.Make(V)(OC) in
                let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
                X.compile
             | UseArch.Gen ->
                assert false
             end
          | `MIPS ->
             let module V = Int64Constant.Make(MIPSBase.Instr) in
             let module Arch' = MIPSArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = MIPSParser.token
                 module Lexer = MIPSLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic MIPSParser.main
               end in
             let module Compile = MIPSCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `RISCV ->
             let module V = Int64Constant.Make(RISCVBase.Instr) in
             let module Arch' = RISCVArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = RISCVParser.token
                 module Lexer = RISCVLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic RISCVParser.main
               end in
             let module Compile = RISCVCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `C ->
             let module Arch' = struct
                 let comment =  match OT.asmcomment with
                   | Some c -> c
                   | None ->
                      begin match Cfg.sysarch with
                      | `PPC -> PPCArch_litmus.comment
                      | `X86 -> X86Arch_litmus.comment
                      | `X86_64 -> X86_64Arch_litmus.comment
                      | `ARM -> ARMArch_litmus.comment
                      | `AArch64 -> AArch64Arch_litmus.comment
                      | `MIPS -> MIPSArch_litmus.comment
                      | `RISCV -> RISCVArch_litmus.comment
                      | `BPF
                      | `Unknown -> "#"
                      end
               end in
             let module X = Make'(Cfg)(Arch') in
             X.compile
          | `LISA ->
             (* HetLitmus Route B: parse the scoped LISA/Bell test and emit a
                CUDA (.cu) litmus kernel via CudaLang.  litmus7 had no LISA
                path (this branch was `assert false'); GPU codegen reuses the
                Bell scoped IR rather than a native PTX arch.  See memory
                hetlitmus-route-b-frontend. *)
             let module LISAInstr =
               Instr.No(struct type instr = BellBase.instruction end) in
             let module V = Int64Constant.Make(LISAInstr) in
             let module Arch' = LISAArch_litmus.Make(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = LISAParser.token
                 module Lexer = BellLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = LISAParser.main
               end in
             let module P = GenParser.Make(Cfg)(Arch')(LexParse) in
             (fun _hash_env name in_chan _out_chan splitted ->
               try
                 let parsed = P.parse in_chan splitted in
                 close_in in_chan ;
                 let tname = splitted.Splitter.name.Name.name in
                 let outname = Tar.outname (MyName.outname name ".cu") in
                 Misc.output_protect
                   (fun chan -> CudaLang.dump chan tname parsed)
                   outname ;
                 if OT.verbose >= 0 then
                   Printf.eprintf "HetLitmus: emitted CUDA %s\n%!" outname ;
                 (* AMD sibling: emit a HIP (.hip) kernel from the same parsed
                    scoped test (HipLang).  Emit-only -- the hipcc compile is
                    the HIP analog of Task 8, deferred (no ROCm here). *)
                 let hipname = Tar.outname (MyName.outname name ".hip") in
                 Misc.output_protect
                   (fun chan -> HipLang.dump chan tname parsed)
                   hipname ;
                 if OT.verbose >= 0 then
                   Printf.eprintf "HetLitmus: emitted HIP %s\n%!" hipname ;
                 Absent
               with e -> if OT.nocatch then raise e ; Interrupted e)
          | `Het ->
             (* HetLitmus Tier-0/Tier-2: the compound pseudo-arch + cross-device
                harness emitter.  Instantiate the HetArch functor for the GH200
                pairing -- AArch64 (CPU) + LISA/PTX (GPU) -- route each
                processor's cells to its backend's sub-parser (Tier-0), then
                emit ONE compilable CPU+GPU harness directory (Tier-2):
                  * each CPU processor -> a pthread running real AArch64 inline
                    asm produced by the genuine litmus7 AArch64 compile pipeline
                    + ASMLang.dump_fun (reused, not reimplemented);
                  * each GPU processor -> a CUDA kernel built from CudaLang's
                    scoped-atomic translation (reused);
                  * shared vars in cudaMallocManaged (CPU/GPU-coherent on GH200);
                  * a system-scope (thread_scope_system) rendezvous barrier so
                    the CPU and GPU race in the same window;
                  * GPU register readback merged with the CPU asm outputs into
                    litmus7's own outs.c outcome histogram.
                The compile check is COMPILE-ONLY (nvcc -c + gcc -c, clang
                cross-assembles the AArch64 thread); execution on real hardware
                is Task 9.  All het logic lives here + in litmus/HetArch.ml; see
                hetlitmus/docs/het-emission.md. *)
             let module CpuV =
               SymbConstant.Make
                 (Int64Scalar)(AArch64PteVal)(AArch64AddrReg)
                 (AArch64Instr.Std) in
             let module Cpu = AArch64Arch_litmus.Make(OC)(CpuV) in
             let module GpuInstr =
               Instr.No(struct type instr = BellBase.instruction end) in
             let module GpuV = Int64Constant.Make(GpuInstr) in
             let module Gpu = LISAArch_litmus.Make(GpuV) in
             let module Arch' = HetArch.Make(Cpu)(Gpu) in
             let module CpuLexer =
               AArch64Lexer.Make
                 (struct include LexConfig let is_morello = false end) in
             let module GpuLexer = BellLexer.Make(LexConfig) in
             (* per-column sub-parsers: one column's ';'-separated cells -> a
                list of compound parsed pseudos, tagged for its device.  A
                sub-parser failure is caught here and re-raised naming the
                processor + ISA + offending column text: without this, the bare
                Parsing.Parse_error propagates to genParser's call_parser, which
                reports the position of the *outer* (already slurped-to-EOF)
                lexbuf -- i.e. an identical, useless "unexpected '' (in prog)"
                regardless of which cell on which side is malformed. *)
             let parse_cpu p txt =
               let lexbuf = Lexing.from_string txt in
               (try
                  List.map Arch'.of_cpu_parsed
                    (AArch64Parser.instr_option_seq CpuLexer.token lexbuf)
                with
                | Parsing.Parse_error ->
                   Warn.user_error
                     "HetLitmus: P%d (cpu, AArch64) parse error near offset %d \
                      of its instruction column %S"
                     p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
                | LexMisc.Error (msg,_) ->
                   Warn.user_error
                     "HetLitmus: P%d (cpu, AArch64) lexing error: %s (in column %S)"
                     p msg txt) in
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
                     p msg txt) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = unit
                 let lexer = fun _ -> ()
                 let parser = Arch'.het_parser ~cpu:parse_cpu ~gpu:parse_gpu
               end in
             let module P = GenParser.Make(Cfg)(Arch')(LexParse) in
             (* Tier-2 CPU backend: the REAL litmus7 AArch64 compile pipeline,
                reused so the CPU thread's inline asm comes from ASMLang (not a
                hand-rolled emitter).  We drive Comp.compile + Lang.dump_fun on a
                CPU-only projection of the parsed het test. *)
             let module CpuLexParse = struct
                 type instruction = Cpu.parsedPseudo
                 type token = AArch64Parser.token
                 let lexer = CpuLexer.token
                 let parser = AArch64Parser.main
               end in
             let module CpuComp = AArch64Compile_litmus.Make(CpuV)(OC) in
             let module CpuX = Make(Cfg)(Cpu)(CpuLexParse)(CpuComp) in
             let module AllocArchCpu = struct
                 include Cpu
                 type v = Cpu.V.v
                 let maybevToV = Cpu.maybevToV
                 type global = Global_litmus.t
                 let maybevToGlobal = Cpu.tr_global
               end in
             let module AllocCpu = SymbReg.Make(AllocArchCpu) in
             (* litmus7's own outcome histogram, embedded verbatim from
                litmus/libdir/_outs.{c,h} so the harness is self-contained
                (the repro uses -set-libdir herd/libdir, which lacks them). *)
             let outs_h_content = HetArch.outs_h in
             let outs_c_content = HetArch.outs_c in
             (fun _hash_env _name in_chan _out_chan splitted ->
               try
                 let parsed = P.parse in_chan splitted in
                 close_in in_chan ;
                 let tname = splitted.Splitter.name.Name.name in
                 let doc = splitted.Splitter.name in
                 let nprocs_total = List.length parsed.MiscParser.prog in
                 (* ---- classify processors by device tag ---- *)
                 let dev_of_proc p =
                   let rec find = function
                     | ((q,annot,_),_)::_ when q=p ->
                        (match annot with Some (d::_) -> d | _ -> "?")
                     | _::rest -> find rest
                     | [] -> "?" in
                   find parsed.MiscParser.prog in
                 let is_cpu p = dev_of_proc p = "cpu" in
                 if OT.verbose >= 0 then begin
                   Printf.eprintf
                     "HetLitmus: emitting Tier-2 harness for %s (%d procs)\n%!"
                     tname nprocs_total ;
                   List.iter
                     (fun ((p,annot,_),_code) ->
                       let dev = match annot with Some (d::_) -> d | _ -> "?" in
                       Printf.eprintf "  P%d device=%s -> %s\n%!" p dev
                         (match dev with
                          | "cpu" -> "CPU pthread (AArch64 asm via ASMLang)"
                          | "gpu" -> "GPU kernel (LISA/PTX via CudaLang)"
                          | _ -> "unknown"))
                     parsed.MiscParser.prog
                 end ;
                 (* ---- CPU-only projection -> AArch64 compile -> templates ---- *)
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
                 let cpu_compiled = CpuX.Comp.compile doc cpu_allocated in
                 let global_env =
                   List.map
                     (fun (loc,t) ->
                       let t = match t with CType.Array (b,_) -> CType.Base b | _ -> t in
                       loc,t)
                     cpu_compiled.CpuX.Utils.T.globals in
                 (* per-CPU-proc inline-asm function signature (mirrors exactly
                    what ASMLang.dump_fun emits: addresses then output regs). *)
                 let cpu_param_types out proc =
                   let addrs,_ptes = Cpu.Out.get_addrs out in
                   let addr_params =
                     List.map
                       (fun a ->
                         let ty = try List.assoc a global_env with Not_found -> Compile.base in
                         (Printf.sprintf "%s *%s" (SkelUtil.dump_global_type a ty) a), a)
                       addrs in
                   let out_params =
                     List.map
                       (fun reg ->
                         let ty =
                           let t = Cpu.Out.RegMap.find reg out.Cpu.Out.ty_env in
                           if CType.is_tag_ptr t then CType.pointer_type t else t in
                         (Printf.sprintf "%s *%s" (CType.dump ty) (Cpu.Out.dump_out_reg proc reg)),
                         (Cpu.Out.dump_out_reg proc reg))
                       out.Cpu.Out.final in
                   addr_params, out_params in
                 let params =
                   List.map
                     (fun (proc,(out,(_outregs,envV))) ->
                       (proc,out,envV,cpu_param_types out proc))
                     cpu_compiled.CpuX.Utils.T.code in
                 (* ---- GPU-only projection (reuse CudaLang translation) ---- *)
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
                 let gpu_slots =
                   List.concat_map
                     (fun ((p,_,_),code) ->
                       List.map
                         (fun n ->
                           (p, Printf.sprintf "r%d" n,
                            Printf.sprintf "__out[%d*%d+%d]" p CudaLang.nregs_layout n))
                         (CudaLang.result_regs code))
                     gpu_prog in
                 let cpu_slots =
                   List.concat_map
                     (fun (proc,out,_,_) ->
                       List.mapi
                         (fun i reg ->
                           (proc, Cpu.pp_reg reg,
                            Printf.sprintf "cpu_outs_P%d[%d]" proc i))
                         out.Cpu.Out.final)
                     params in
                 let slots = cpu_slots @ gpu_slots in
                 let nslots = List.length slots in
                 (* ---- condition -> C predicate over the outcome vector ---- *)
                 let slot_index =
                   let tbl = Hashtbl.create 8 in
                   List.iteri (fun i (p,r,_) -> Hashtbl.replace tbl (p,r) i) slots ;
                   fun p r -> Hashtbl.find_opt tbl (p,r) in
                 let cval v = ParsedConstant.pp_v v in
                 let rec c_of_prop p =
                   let open ConstrGen in
                   match p with
                   | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
                      (match slot_index pr r with
                       | Some i -> Printf.sprintf "(o[%d] == %s)" i (cval v)
                       | None -> "1 /*unmapped*/")
                   | Atom _ -> "1 /*unsupported atom*/"
                   | Not q -> Printf.sprintf "(!%s)" (c_of_prop q)
                   | And [] -> "1"
                   | And ps -> "(" ^ String.concat " && " (List.map c_of_prop ps) ^ ")"
                   | Or [] -> "0"
                   | Or ps -> "(" ^ String.concat " || " (List.map c_of_prop ps) ^ ")"
                   | Implies (a,b) ->
                      Printf.sprintf "(!(%s) || %s)" (c_of_prop a) (c_of_prop b) in
                 let cond_expr = c_of_prop (prop_of parsed.MiscParser.condition) in
                 (* ---- shared globals (allocated once, coherent to both) ---- *)
                 let cpu_addrs =
                   List.concat_map (fun (_,_,_,(ap,_)) -> List.map snd ap) params in
                 let all_globals =
                   let seen = Hashtbl.create 8 in
                   List.filter
                     (fun g -> if Hashtbl.mem seen g then false
                               else (Hashtbl.add seen g () ; true))
                     (cpu_addrs @ gpu_globals) in
                 let npart = List.length params + List.length gpu_prog in
                 (* ================= file emission ================= *)
                 let base =
                   if OT.is_out && (try Sys.is_directory OT.tarname with _ -> false)
                   then OT.tarname else Sys.getcwd () in
                 let dir = Filename.concat base tname in
                 if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
                 let write fname f =
                   Misc.output_protect f (Filename.concat dir fname) in
                 (* ---- <tname>_cpu.c : the CPU threads (AArch64 asm) ---- *)
                 let dump_cpu_file ch =
                   let s = output_string ch in
                   s (Printf.sprintf
                        "/* HetLitmus Tier-2: CPU threads for %s (AArch64).\n   \
                         The bodies below are emitted by litmus7 ASMLang.dump_fun\n   \
                         (genuine litmus7 AArch64 compile pipeline); assembled on\n   \
                         aarch64 hosts (GH200 Grace) -- or here via\n   \
                         'clang --target=aarch64-linux-gnu'.  DO NOT EDIT. */\n"
                        tname) ;
                   s "#include <stdint.h>\n\n" ;
                   s "#if defined(__aarch64__)\n" ;
                   List.iter
                     (fun (proc,out,envV,_sig) ->
                       CpuX.Lang.dump_fun ch Template.no_extra_args global_env envV proc out)
                     params ;
                   s "#else\n" ;
                   s "/* Portable shim so the harness also compiles on a non-aarch64\n   \
                      dev host.  NOT the tested path -- the AArch64 asm above is the\n   \
                      real CPU thread; build on aarch64 to assemble it. */\n" ;
                   List.iter
                     (fun (proc,_out,_envV,(addr_params,out_params)) ->
                       let ps =
                         String.concat ","
                           (List.map fst (addr_params @ out_params)) in
                       s (Printf.sprintf "static void code%d(%s) {\n" proc ps) ;
                       List.iter (fun (_,a) -> s (Printf.sprintf "  (void)%s;\n" a)) addr_params ;
                       List.iter (fun (_,nm) -> s (Printf.sprintf "  *%s = 0;\n" nm)) out_params ;
                       s "}\n")
                     params ;
                   s "#endif\n\n" ;
                   (* non-static entry points the GPU-side driver calls *)
                   List.iter
                     (fun (proc,_out,_envV,(addr_params,out_params)) ->
                       let ps = String.concat "," (List.map fst (addr_params @ out_params)) in
                       let args = String.concat "," (List.map snd (addr_params @ out_params)) in
                       s (Printf.sprintf "void het_run_P%d(%s) { code%d(%s); }\n"
                            proc ps proc args))
                     params in
                 (* ---- <tname>.cu : GPU kernel + driver ---- *)
                 let id = CudaLang.c_ident tname in
                 let dump_cu_file ch =
                   let s = output_string ch in
                   s (Printf.sprintf "// HetLitmus Tier-2 GPU kernel + driver for %s.\n" tname) ;
                   s "// P(gpu) run as a CUDA kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
                   s "// Shared vars are cudaMallocManaged (CPU/GPU-coherent on GH200);\n" ;
                   s "// a system-scope atomic barrier rendezvouses both sides.\n" ;
                   s "// COMPILE-ONLY (nvcc -c); GPU execution is Task 9.  DO NOT EDIT.\n" ;
                   s "#include <cuda/atomic>\n#include <cstdio>\n#include <cstdint>\n" ;
                   s "#include <cstdlib>\n#include <pthread.h>\n#include <inttypes.h>\n" ;
                   s "extern \"C\" {\n" ;
                   s "#include \"outs.h\"\n" ;
                   List.iter
                     (fun (proc,_out,_envV,(addr_params,out_params)) ->
                       let ps = String.concat "," (List.map fst (addr_params @ out_params)) in
                       s (Printf.sprintf "  void het_run_P%d(%s);\n" proc ps))
                     params ;
                   s "}\n" ;
                   s {ocaml|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|ocaml} ;
                   s (Printf.sprintf "\n#define NPART %d\n\n" npart) ;
                   (* kernel *)
                   let kparams =
                     String.concat ", "
                       (List.map (fun g -> Printf.sprintf "int* %s" g) gpu_globals
                        @ ["int* __out"; "int* barrier"]) in
                   s (Printf.sprintf "__global__ void litmus_%s(%s) {\n" id kparams) ;
                   List.iter
                     (fun ((proc,_,_),code) ->
                       let blk,lane = layout proc in
                       let instrs = CudaLang.instrs_of_code code in
                       let regs = CudaLang.result_regs code in
                       s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n" blk lane) ;
                       s "    cuda::atomic_ref<int, cuda::thread_scope_system> _bar(*barrier);\n" ;
                       s "    _bar.fetch_add(1, cuda::memory_order_seq_cst);\n" ;
                       s "    while (_bar.load(cuda::memory_order_seq_cst) < NPART) { }\n" ;
                       List.iter (fun n -> s (Printf.sprintf "    int r%d = 0;\n" n)) regs ;
                       List.iter (fun i -> CudaLang.dump_instr ch "    " i) instrs ;
                       List.iter
                         (fun n ->
                           s (Printf.sprintf "    __out[%d*%d+%d] = r%d;\n"
                                proc CudaLang.nregs_layout n n))
                         regs ;
                       s "  }\n")
                     gpu_prog ;
                   s "}\n\n" ;
                   (* CPU pthread wrappers (arrive at barrier, then run asm) *)
                   List.iter
                     (fun (proc,_out,_envV,(addr_params,out_params)) ->
                       s (Printf.sprintf "struct cpu_args_P%d {\n" proc) ;
                       List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr_params ;
                       s "  int* barrier;\n" ;
                       List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) out_params ;
                       s "};\n" ;
                       s (Printf.sprintf "static void* cpu_thread_P%d(void* _a) {\n" proc) ;
                       s (Printf.sprintf "  cpu_args_P%d* a = (cpu_args_P%d*)_a;\n" proc proc) ;
                       s "  cuda::atomic_ref<int, cuda::thread_scope_system> _bar(*a->barrier);\n" ;
                       s "  _bar.fetch_add(1, cuda::memory_order_seq_cst);\n" ;
                       s "  while (_bar.load(cuda::memory_order_seq_cst) < NPART) { }\n" ;
                       let call_args =
                         String.concat ","
                           (List.map (fun (_,a) -> "a->"^a) (addr_params @ out_params)) in
                       s (Printf.sprintf "  het_run_P%d(%s);\n  return NULL;\n}\n\n" proc call_args))
                     params ;
                   (* outcome labels, condition, dump callback *)
                   let labelstr =
                     String.concat ", "
                       (List.map (fun (p,r,_) -> Printf.sprintf "\"%d:%s\"" p r) slots) in
                   s (Printf.sprintf "static const char* _labels[%d] = { %s };\n"
                        (max 1 nslots) labelstr) ;
                   s (Printf.sprintf
                        "static int _cond(intmax_t* o){ (void)o; return %s; }\n" cond_expr) ;
                   s {ocaml|static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
  fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
|ocaml} ;
                   s (Printf.sprintf "  for (int i=0;i<%d;i++)" nslots) ;
                   s {ocaml| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
  fprintf(_ch, "\n");
}

|ocaml} ;
                   (* driver *)
                   s "int main(void){\n" ;
                   List.iter
                     (fun g ->
                       s (Printf.sprintf
                            "  int *%s; cudaMallocManaged(&%s, sizeof(int));\n" g g))
                     all_globals ;
                   s (Printf.sprintf
                        "  int *__out; cudaMallocManaged(&__out, sizeof(int)*%d*%d);\n"
                        (max 1 nprocs_total) CudaLang.nregs_layout) ;
                   s "  int *barrier; cudaMallocManaged(&barrier, sizeof(int));\n" ;
                   List.iter
                     (fun (proc,_out,_envV,(_ap,out_params)) ->
                       if out_params <> [] then
                         s (Printf.sprintf "  int cpu_outs_P%d[%d];\n"
                              proc (List.length out_params)))
                     params ;
                   s "  outs_t* hist = NULL;\n  const int iterations = 100000;\n" ;
                   s "  for (int _it=0; _it<iterations; ++_it) {\n" ;
                   List.iter (fun g -> s (Printf.sprintf "    *%s = 0;\n" g)) all_globals ;
                   s "    *barrier = 0;\n" ;
                   s (Printf.sprintf "    for (int _k=0;_k<%d*%d;_k++) __out[_k]=0;\n"
                        (max 1 nprocs_total) CudaLang.nregs_layout) ;
                   List.iter
                     (fun (proc,_out,_envV,(addr_params,out_params)) ->
                       let fields =
                         String.concat ", "
                           (List.map snd addr_params
                            @ ["barrier"]
                            @ List.mapi
                                (fun i _ -> Printf.sprintf "&cpu_outs_P%d[%d]" proc i)
                                out_params) in
                       s (Printf.sprintf "    cpu_args_P%d _ca%d = { %s };\n" proc proc fields) ;
                       s (Printf.sprintf
                            "    pthread_t _th%d; pthread_create(&_th%d, NULL, cpu_thread_P%d, &_ca%d);\n"
                            proc proc proc proc))
                     params ;
                   let kargs = String.concat ", " (gpu_globals @ ["__out"; "barrier"]) in
                   s (Printf.sprintf "    litmus_%s<<<%d, %d>>>(%s);\n"
                        id n_blocks block_dim kargs) ;
                   List.iter
                     (fun (proc,_,_,_) -> s (Printf.sprintf "    pthread_join(_th%d, NULL);\n" proc))
                     params ;
                   s "    cudaDeviceSynchronize();\n" ;
                   s (Printf.sprintf "    intmax_t _o[%d];\n" (max 1 nslots)) ;
                   List.iteri
                     (fun i (_p,_r,src) -> s (Printf.sprintf "    _o[%d] = %s;\n" i src))
                     slots ;
                   s (Printf.sprintf
                        "    hist = add_outcome_outs(hist, _o, %d, 1, _cond(_o));\n" nslots) ;
                   s "  }\n" ;
                   s (Printf.sprintf "  intmax_t _buff[%d];\n" (max 1 nslots)) ;
                   s (Printf.sprintf "  printf(\"Test %s\\n\");\n" tname) ;
                   s (Printf.sprintf "  dump_outs(stdout, _dump_one, hist, _buff, %d);\n" nslots) ;
                   s "  free_outs(hist);\n" ;
                   List.iter (fun g -> s (Printf.sprintf "  cudaFree(%s);\n" g)) all_globals ;
                   s "  cudaFree(__out); cudaFree(barrier);\n  return 0;\n}\n" in
                 (* ---- comp.sh / Makefile / README ---- *)
                 let dump_comp ch =
                   let s = output_string ch in
                   s "#!/bin/sh\n" ;
                   s (Printf.sprintf
                        "# Compile-only check for HetLitmus Tier-2 harness '%s'.\n" tname) ;
                   s "# COMPILE-ONLY (-c, no link, no GPU run -- execution is Task 9).\n" ;
                   s "set -e\nNVCC=\"${NVCC:-nvcc}\"\nCUDA_ARCH=\"${CUDA_ARCH:-sm_90}\"  # GH200=sm_90\n" ;
                   s (Printf.sprintf "echo \"+ $NVCC -std=c++17 -arch=$CUDA_ARCH -c %s.cu\"\n" tname) ;
                   s (Printf.sprintf "$NVCC -std=c++17 -arch=$CUDA_ARCH -c %s.cu -o %s.o\n" tname tname) ;
                   s "echo \"+ gcc -c outs.c\"\ngcc -c outs.c -o outs.o\n" ;
                   s (Printf.sprintf
                        "echo \"+ gcc -c %s_cpu.c  (host build; AArch64 asm under #ifdef)\"\n" tname) ;
                   s (Printf.sprintf "gcc -c %s_cpu.c -o %s_cpu_host.o\n" tname tname) ;
                   s "if command -v clang >/dev/null 2>&1; then\n" ;
                   s (Printf.sprintf
                        "  echo \"+ clang --target=aarch64-linux-gnu -c %s_cpu.c  (real AArch64 asm)\"\n" tname) ;
                   s (Printf.sprintf
                        "  clang --target=aarch64-linux-gnu -std=gnu11 -c %s_cpu.c -o %s_cpu.o\n" tname tname) ;
                   s (Printf.sprintf
                        "else\n  echo \"(no clang: skipped AArch64 cross-assembly of %s_cpu.c)\"\nfi\n" tname) ;
                   s "echo 'HetLitmus: compile OK'\n" in
                 let dump_makefile ch =
                   let s = output_string ch in
                   s (Printf.sprintf
                        "# HetLitmus Tier-2 harness '%s' -- compile-only (objects; no link/run).\n" tname) ;
                   s "NVCC ?= nvcc\nCUDA_ARCH ?= sm_90\nCC ?= gcc\n\n" ;
                   s (Printf.sprintf "all: %s.o outs.o %s_cpu_host.o\n\n" tname tname) ;
                   s (Printf.sprintf "%s.o: %s.cu\n\t$(NVCC) -std=c++17 -arch=$(CUDA_ARCH) -c $< -o $@\n\n" tname tname) ;
                   s "outs.o: outs.c\n\t$(CC) -c $< -o $@\n\n" ;
                   s (Printf.sprintf "%s_cpu_host.o: %s_cpu.c\n\t$(CC) -c $< -o $@\n\n" tname tname) ;
                   s "clean:\n\trm -f *.o\n" in
                 let dump_readme ch =
                   let s = output_string ch in
                   s (Printf.sprintf "# HetLitmus Tier-2 harness: %s\n\n" tname) ;
                   s "Heterogeneous CPU+GPU litmus harness emitted by litmus7 (`Het` arch).\n\n" ;
                   s "Files:\n" ;
                   s (Printf.sprintf "- `%s.cu`     GPU kernel + host driver (cudaMallocManaged, system-scope\n" tname) ;
                   s "             rendezvous barrier, pthread launch, kernel launch, readback).\n" ;
                   s (Printf.sprintf "- `%s_cpu.c`  CPU thread(s): real AArch64 inline asm (litmus7 ASMLang).\n" tname) ;
                   s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
                   s "- `comp.sh` / `Makefile`  compile-only build (nvcc -c + gcc -c).\n\n" ;
                   s "Build (compile-only; no GPU needed): `sh comp.sh`.\n" ;
                   s "Target: NVIDIA GH200 Grace-Hopper (aarch64 host + Hopper GPU).\n" in
                 write "outs.h" (fun ch -> output_string ch outs_h_content) ;
                 write "outs.c" (fun ch -> output_string ch outs_c_content) ;
                 write (tname ^ "_cpu.c") dump_cpu_file ;
                 write (tname ^ ".cu") dump_cu_file ;
                 write "comp.sh" dump_comp ;
                 write "Makefile" dump_makefile ;
                 write "README.md" dump_readme ;
                 if OT.verbose >= 0 then
                   Printf.eprintf
                     "HetLitmus: emitted harness directory %s\n%!" dir ;
                 Absent
               with e -> if OT.nocatch then raise e ; Interrupted e)
          | `CPP | `JAVA | `ASL | `BPF -> assert false
        in
        aux arch hash_env name in_chan out_chan splitted
      end else begin (* Excluded explicitely, (check_tname), do not warn *)
        Absent
      end

  let from_file hash_env name out_chan =
    Misc.input_protect
      (fun in_chan -> from_chan hash_env name in_chan out_chan)
      name

  (* Call generic tar builder/runner *)
  module DF = DumpRun.Make (OT)(Tar) (struct let from_file = from_file end)

  let from_files = DF.from_files
end
