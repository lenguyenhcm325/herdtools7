(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map.  See hetControlMap.mli for the      *)
(* contract and hetlitmus/docs/positive-control.md for the design.          *)
(****************************************************************************)

(* The harness co-runs mu(T), T's structural twin at the lattice floor, so that
   `target_count = 0' means "not observed on a harness that demonstrably
   produced an interleaving of this shape" rather than nothing at all.

   mu(T) is looked up in the control map beside the input .litmus, derived from
   the corpus sources by hetlitmus/verify/controlmap.py (gated by `make
   hetlitmus-controlmap').  It is not recomputed here at all: the two non-grid
   reference tests have a floor sibling no rewrite of their name produces, and
   which rows have one is a fact about the corpus, not about the spelling
   (positive-control.md sec 3).

   With no map no control is named, control_compiled_in stays 0, and
   het_verdict() returns COLD and says so; it never quietly proceeds. *)

type t = (string, string * string) Hashtbl.t

(* The schema, asserted verbatim.  The retired 8-column map put a verdict in
   field 2 and its canary in field 8; read with these column meanings its Mu
   column would be a verdict string and its canary a rule fragment, and every
   harness would co-run a test named "Allowed".  So the header is a gate, not a
   comment: a file that does not open with this line is refused. *)
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
