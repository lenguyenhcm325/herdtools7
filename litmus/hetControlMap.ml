(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the positive-control map.  See hetControlMap.mli for the      *)
(* contract and hetlitmus/docs/positive-control.md for the design.          *)
(****************************************************************************)

(* The harness co-runs mu(T), a strictly weaker structurally identical sibling
   of T, so that `target_count = 0' means "not observed on a demonstrably hot
   harness" rather than nothing at all.

   mu(T) is looked up in tests/het/control-map.csv, which sits next to the
   input .litmus and is derived from the corpus sources by
   hetlitmus/verify/controlmap.py (gated by `make hetlitmus-controlmap').  It
   is NOT recomputed by rewriting T's name: the one-sided grid variants are
   named for the op THE GPU performs and the GPU's role flips with the device
   cut, so several `-sys-acquire' cells simply do not exist and a name rewrite
   would point at a nonexistent test (positive-control.md sec 3).

   With no map no control is named, control_compiled_in stays 0, and
   het_verdict() returns COLD and says so; it never quietly proceeds. *)

type t = (string, string * string * string) Hashtbl.t

let is_empty (tbl:t) = Hashtbl.length tbl = 0

let load ~verbose ~dir ~csv ~src_name =
  let tbl = Hashtbl.create 512 in
  let f = Filename.concat dir csv in
  (try
     let ch = open_in f in
     (try
        while true do
          let line = input_line ch in
          if String.length line > 0 && line.[0] <> '#' then
            match String.split_on_char ',' line with
            (* Field 2 is bound but unread: nothing in an emitted harness
               carries a verdict any more.  The column stays in the schema until
               the map is regenerated, so the arity of this pattern is what
               keeps the later fields on their own meanings. *)
            | t :: exp :: mu :: _muexp :: _rule :: _alt :: _rlx :: can :: _
                 when t <> "Test" ->
               Hashtbl.replace tbl t (exp, mu, can)
            | _ -> ()
        done
      with End_of_file -> ()) ;
     close_in ch
   with Sys_error _ ->
     (* Say it out loud: the harness does fail closed without the map
        (control_compiled_in stays 0, so het_verdict returns COLD), but a
        control nobody can name is a control nobody notices is missing. *)
     if verbose >= 0 then
       Printf.eprintf
         "HetLitmus WARNING: no %s next to %s -- this \
          harness names NO positive control, so every null it produces \
          is uninterpretable (het_verdict will return COLD-INVALID).  \
          Regenerate with hetlitmus/verify/controlmap.py --emit.\n%!"
         csv src_name) ;
  tbl

(* TWO sentinels, and they are NOT the same statement.

   "-"    the row calls for no mu at all.
   "none" NO Layer-A mutant EXISTS for this row: the test is already at the
          lattice minimum on both sides, or every weaker structural sibling is
          itself unusable.  The MuRule column says which.  Such a test co-runs
          the Layer-B canary alone, and its null is correspondingly weaker.

   MEASURED 2026-08-03: control-map.csv (AArch64 lattice) uses only "-";
   control-map-amd.csv uses "none" on 16 rows (IRIW-cgcc / IRIW-cgcg / WRC-ccg
   / WRC3-cccg at sys scope).  Before this
   function knew the second sentinel, wiring the AMD map into the emitter made
   those 16 tests refuse to emit -- "names the control none, but ./none.litmus
   does not exist" -- because anything other than "-" was read as a test name.
   Fail-closed, and caught by P2b's refusal, but a refusal all the same. *)
let control_of tbl t = match Hashtbl.find_opt tbl t with
  | Some (_,mu,_) when mu <> "-" && mu <> "none" -> Some mu
  | _ -> None

let no_mutant_exists tbl t = match Hashtbl.find_opt tbl t with
  | Some (_,"none",_) -> true
  | _ -> false

(* A `self' row is NOT a canary to co-run: those tests ARE the Layer-B canary
   and cannot co-run themselves.  They are still NAMED by the emitter, but no
   canary instance is built, so HET_CANARY_COMPILED_IN is 0 and het_verdict()
   calls their nulls COLD -- which is what "the most observable het shape did
   not fire" means. *)
let canary_of tbl t = match Hashtbl.find_opt tbl t with
  | Some (_,_,can) when can <> "-" && can <> "self" -> Some can
  | _ -> None

(* The `self' rows name themselves.  het_verdict.h separates the designed case
   (this test IS the canary) from the bug case (the canary went missing) by
   comparing canary_name with test_name, so the name must be honest even where
   no canary instance is built. *)
let is_self_canary tbl t = match Hashtbl.find_opt tbl t with
  | Some (_,_,"self") -> true
  | _ -> false
