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

(* HetLitmus: the positive-control map.  See hetControlMap.mli for the
   contract and hetlitmus/docs/positive-control.md for the design. *)

(* The harness co-runs mu(T), T's structural twin at the lattice floor, so that
   `target_count = 0' means "not observed on a harness that demonstrably
   produced an interleaving of this shape" rather than nothing at all.  mu(T)
   is read from the control map beside the input .litmus, which
   hetlitmus/verify/controlmap.py derives from the corpus sources.  It is not
   recomputed here, because which rows have a floor sibling, and what that
   sibling is called, are facts about the corpus rather than about the name
   (hetlitmus/docs/positive-control.md sec 3). *)

type t = (string, string * string) Hashtbl.t

(* The schema, asserted verbatim.  A file carrying the legacy 8-column schema
   binds Mu to a verdict string and the canary to a rule fragment under these
   column meanings, so every harness would co-run a test named "Allowed".  The
   header is therefore a gate, not a comment: a file that does not open with
   this line is refused rather than read. *)
let header = "Test,Mu,MuRule,MuAlt,MuRelaxed,Canary"

let read_lines ch =
  let rec go acc =
    match input_line ch with
    | l -> go (l::acc)
    | exception End_of_file -> List.rev acc in
  go []

let load ~verbose ~dir ~csv ~src_name =
  let f = Filename.concat dir csv in
  match open_in f with
  | exception Sys_error _ ->
     (* Say it out loud: the harness does fail closed without the map
        (control_compiled_in stays 0, so het_verdict returns COLD), but a
        control nobody can name is a control nobody notices is missing. *)
     if verbose >= 0 then
       Printf.eprintf
         "HetLitmus WARNING: no %s next to %s -- this \
          harness names NO positive control, so every null it produces \
          is uninterpretable (het_verdict will return COLD-INVALID).  \
          Regenerate with hetlitmus/verify/controlmap.py --emit.\n%!"
         csv src_name ;
     None
  | ch ->
     let lines = read_lines ch in
     close_in ch ;
     let rows =
       List.filter
         (fun l -> String.length l > 0 && l.[0] <> '#')
         (List.map String.trim lines) in
     (match rows with
      | h :: _ when h = header -> ()
      | h :: _ ->
         Warn.user_error
           "%s: header is %S, expected %S.  This is the retired 8-column \
            schema or a hand-edit; its columns do not mean what this reader \
            would read them as, so the map is refused rather than mis-bound."
           f h header
      | [] -> Warn.user_error "%s: holds no rows at all" f) ;
     let tbl = Hashtbl.create 512 in
     List.iter
       (fun l ->
         if l <> header then
           match String.split_on_char ',' l with
           | [t;mu;_rule;_alt;_rlx;can] -> Hashtbl.replace tbl t (mu,can)
           | fs ->
              Warn.user_error
                "%s: row %S has %d fields, expected 6 (%s)"
                f l (List.length fs) header)
       rows ;
     Some tbl

(* ONE sentinel, and it says one thing: "none" = T is itself at the lattice
   floor, so no strictly weaker structural sibling can exist.  Such a test
   co-runs the Layer-B canary alone and its null is correspondingly weaker.
   Anything else in the Mu column is a test name that must resolve to a
   .litmus beside this one. *)
let control_of tbl t = match tbl with
  | None -> None
  | Some tbl ->
     (match Hashtbl.find_opt tbl t with
      | Some (mu,_) when mu <> "none" -> Some mu
      | _ -> None)

let has_row tbl t = match tbl with
  | None -> false
  | Some tbl -> Hashtbl.mem tbl t

let at_lattice_floor tbl t = match tbl with
  | None -> false
  | Some tbl ->
     (match Hashtbl.find_opt tbl t with
      | Some ("none",_) -> true
      | _ -> false)

(* A `self' row is NOT a canary to co-run: those tests ARE the Layer-B canary
   and cannot co-run themselves.  They are still NAMED by the emitter, but no
   canary instance is built, so HET_CANARY_COMPILED_IN is 0 and het_verdict()
   calls their nulls COLD -- which is what "the most observable het shape did
   not fire" means. *)
let canary_of tbl t = match tbl with
  | None -> None
  | Some tbl ->
     (match Hashtbl.find_opt tbl t with
      | Some (_,can) when can <> "self" -> Some can
      | _ -> None)

(* The `self' rows name themselves.  het_verdict.h separates the designed case
   (this test IS the canary) from the bug case (the canary went missing) by
   comparing canary_name with test_name, so the name must be honest even where
   no canary instance is built. *)
let is_self_canary tbl t = match tbl with
  | None -> false
  | Some tbl ->
     (match Hashtbl.find_opt tbl t with
      | Some (_,"self") -> true
      | _ -> false)
