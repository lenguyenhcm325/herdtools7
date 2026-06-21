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

(** Split litmus files into their various components *)

(* BEWARE: This interface files is common to memevents and litmus *)

(* The splitter
   - Parses the first (significant) line of litmus files,
     which includes the critical arch information and
     a bunch of names
   - Identify the four sections of litmus files:
      1. Initial state specification.
      2. Program
      3. Condition to be checked after the run.
      4. Various command and option settings [aka "configs"] whose
         semantics is totally unclear to me (LM).
   - As apparent from the signature Config, handles test renaming.
*)


(*  Result of splitter *)
type info = string * string
type result =
  {
   (* architecture.  HetLitmus Tier-0: this stays a SINGLE Archs.t even for a
      heterogeneous CPU-GPU test -- fork (a) introduces one compound value
      [`Het] whose CPU-vs-GPU split is hidden inside the HetArch functor and a
      per-processor device tag (e.g. "P0:cpu | P1:gpu") in the program header.
      So the splitter, and the whole pipeline, stay single-arch-typed; the
      first-line token "Het" is parsed here exactly like any other arch (via
      Archs.parse).  See litmus/HetArch.ml and hetlitmus/docs/het-litmus-format.md. *)
    arch : Archs.t ;
   (* All names of the test grouped *)
    name : Name.t ;
   (* Additional information as (key * value) pairs *)
    info : info list ;
    (* The four sections of a litmus file *)
    locs : Pos.pos2 * Pos.pos2 * Pos.pos2  * Pos.pos2;
    (* Initial position *)
    start : Lexing.position ;
  }

module type Config = sig
  include LexUtils.Config
  val check_rename : string -> string option
end

module Default : Config

module Make : functor (O:Config) -> sig
  val split : string -> in_channel -> result
  val split_string : string -> string -> result

  (* Init section with info changed or added *)
  val reinfo : info -> Lexing.lexbuf -> string
  val rehash : string -> Lexing.lexbuf -> string
end
