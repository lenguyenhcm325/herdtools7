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

    let compile _hash_env name in_chan _out_chan splitted =
      try
        let parsed = P.parse in_chan splitted in
        close_in in_chan ;
        let tname = splitted.Splitter.name.Name.name in
        let outname = Tar.outname (MyName.outname name ".cu") in
        Misc.output_protect
          (fun chan -> CudaLang.dump chan tname parsed)
          outname ;
        if O.verbose >= 0 then
          Printf.eprintf "HetLitmus: emitted CUDA %s\n%!" outname ;
        (* AMD sibling: emit a HIP (.hip) kernel from the same parsed
           scoped test (HipLang).  Emit-only -- the hipcc compile is
           the HIP analog of Task 8, deferred (no ROCm here). *)
        let hipname = Tar.outname (MyName.outname name ".hip") in
        Misc.output_protect
          (fun chan -> HipLang.dump chan tname parsed)
          hipname ;
        if O.verbose >= 0 then
          Printf.eprintf "HetLitmus: emitted HIP %s\n%!" hipname ;
        Answer.Absent
      (* FAIL-CLOSED: the emitted .cu/.hip pair is this function's ONLY
         deliverable, so a refusal must not be reported as success.  See
         HetArch.refused. *)
      with e ->
        if O.nocatch then raise e ;
        HetArch.refused "gpu-only" name e
  end
