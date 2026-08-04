(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetGpuOnly: the GPU-only (`LISA) dispatch arm of litmus7.  A scoped      *)
(* LISA/Bell test is parsed once and rendered twice, as a CUDA .cu          *)
(* (CudaLang) and a HIP .hip (HipLang) kernel.  Route B of the HetLitmus    *)
(* frontend: the GPU frontend is the Bell scoped IR, not a native PTX arch  *)
(* (memory hetlitmus-route-b-frontend).  Upstream litmus7 has no LISA path  *)
(* -- that branch was `assert false'.                                       *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.       *)
(****************************************************************************)

module Make
    (Cfg : GenParser.Config)
    (O : sig
       val verbose : int
       val nocatch : bool
     end)
    (Tar : Tar.S) =
  struct
    module LISAInstr =
      Instr.No(struct type instr = BellBase.instruction end)
    module V = Int64Constant.Make(LISAInstr)
    module Arch' = LISAArch_litmus.Make(V)
    module LexParse = struct
        type instruction = Arch'.parsedPseudo
        type token = LISAParser.token
        module Lexer = BellLexer.Make(struct let debug = Cfg.debuglexer end)
        let lexer = Lexer.token
        let parser = LISAParser.main
      end
    module P = GenParser.Make(Cfg)(Arch')(LexParse)

    (* The GPU-only registry, the counterpart of hetEmit's [dialects]: one
       (extension, banner word, renderer) per dialect, all rendered from the one
       parse.  Emission folds over it, so a vendor is an entry. *)
    let dialects = [
        ".cu",  CudaLang.dialect.GpuLang.gl_kind, CudaLang.dump ;
        ".hip", HipLang.dialect.GpuLang.gl_kind,  HipLang.dump ;
      ]

    let compile _hash_env name in_chan _out_chan splitted =
      try
        let parsed = P.parse in_chan splitted in
        close_in in_chan ;
        let tname = splitted.Splitter.name.Name.name in
        List.iter
          (fun (ext,kind,dump) ->
            let outname = Tar.outname (MyName.outname name ext) in
            Misc.output_protect (fun chan -> dump chan tname parsed) outname ;
            if O.verbose >= 0 then
              Printf.eprintf "HetLitmus: emitted %s %s\n%!" kind outname)
          dialects ;
        Answer.Absent
      (* FAIL-CLOSED: the emitted .cu/.hip pair is this function's ONLY
         deliverable, so a refusal must not be reported as success.  See
         HetArch.refused. *)
      with e ->
        if O.nocatch then raise e ;
        HetArch.refused "gpu-only" name e
  end
