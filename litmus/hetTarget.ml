(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetTarget: litmus7's `-gpu-target' option -- WHICH GPU dialect an        *)
(* emission renders.  Both GPU-emitting arms (hetEmit's compound harness    *)
(* directory, hetGpuOnly's scoped-LISA renders) filter their dialect        *)
(* registry through [select], so one emission produces one vendor's render  *)
(* and one vendor's build arms.  The accepted vocabulary is not spelled     *)
(* here: it is the registry's own target column, so a vendor becomes        *)
(* accepted by being registered.  Nothing outside those two arms reads      *)
(* this, which is what keeps CPU-only litmus7 runs unaffected.              *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

let requested : string option ref = ref None

let set t = requested := Some t

(* [key] names an entry's target word.  Fails closed twice over -- no target
   given, and a target no entry answers to -- because the caller's ONLY
   deliverable is the emitted render; the emission arms turn the error into a
   refusal (HetArch.refused: exit 3, never a silent 0). *)
let select ~key entries =
  let accepted = String.concat "|" (List.map key entries) in
  match !requested with
  | None ->
     Warn.user_error
       "-gpu-target <%s> is required: an emission renders ONE GPU dialect, \
        and the harness it writes carries only that vendor's render and \
        build targets"
       accepted
  | Some t ->
     begin match List.filter (fun e -> String.equal (key e) t) entries with
     | [] ->
        Warn.user_error "unknown -gpu-target %S (accepted: %s)" t accepted
     | l -> l
     end
