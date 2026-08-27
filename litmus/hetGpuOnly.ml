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

(* HetLitmus: the GPU-only (`LISA) dispatch arm.  One parse of a scoped
   LISA/Bell test, rendered in the one dialect `-gpu-target' names.  Upstream
   litmus7 has no LISA emission path at all -- its arm is `assert false' and
   LISA reaches only klitmus7.  hetlitmus/docs/cuda-emitter.md. *)

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

    (* One (hetDialect row, banner word, renderer) per vendor.  The row is
       hetDialect's own, so the extension and the `-gpu-target' word have one
       definition, shared with the compound emitter. *)
    let dialects = [
        HetDialect.cuda_dialect, CudaLang.dialect.GpuLang.gl_kind, CudaLang.dump ;
        HetDialect.hip_dialect,  HipLang.dialect.GpuLang.gl_kind,  HipLang.dump ;
      ]

    (* A compile-only pass parses and checks the test -- so it takes every
       refusal this arm can raise -- and renders nothing. *)
    let compile compileonly _hash_env name in_chan _out_chan splitted =
      let written = ref [] in
      try
        (* `-gpu-target' filtered: one emission, one dialect (hetDialect.ml). *)
        let dialects =
          HetDialect.select ~key:(fun (d,_,_) -> d.HetDialect.gd_target) dialects in
        let parsed = P.parse in_chan splitted in
        close_in in_chan ;
        GpuLang.check_program parsed.MiscParser.prog ;
        GpuLang.check_scopes
          (GpuLang.scopes_of parsed.MiscParser.extra_data)
          (List.map (fun ((p,_,_),_) -> p) parsed.MiscParser.prog) ;
        if compileonly then Answer.Absent
        else begin
          let tname = splitted.Splitter.name.Name.name in
          List.iter
            (fun (d,kind,dump) ->
              let ext = "." ^ d.HetDialect.gd_ext in
              let outname = Tar.outname (MyName.outname name ext) in
              written := outname :: !written ;
              Misc.output_protect (fun chan -> dump chan tname parsed) outname ;
              if O.verbose >= 0 then
                Printf.eprintf "HetLitmus: emitted %s %s\n%!" kind outname)
            dialects ;
          Answer.Absent
        end
      (* The render is this function's ONLY deliverable, so a refusal must
         neither be reported as success (HetArch.refused) nor leave a render. *)
      with e ->
        List.iter (fun f -> try Sys.remove f with Sys_error _ -> ()) !written ;
        if O.nocatch then raise e ;
        HetArch.refused "gpu-only" name e
  end
