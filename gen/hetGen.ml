(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus Tier-4: heterogeneous CPU-GPU litmus-test generator.           *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(* hetgen7 -- generate a single heterogeneous (compound) litmus test in the
   Tier-0 `Het` format.

   The diy cycle engine is monomorphic in one architecture, so a het test
   cannot be produced by a single run.  Instead this driver runs the engine
   ONCE PER DEVICE on a device-appropriate edge cycle of the SAME logical
   shape (e.g. MP):

     - the CPU run (`-cpu <edges>`, AArch64) generates plain accesses;
     - the GPU run (`-gpu <edges>`, LISA/Bell with -bell ptx.bell) generates
       scoped acquire/release accesses.

   Because both runs share the same cycle shape, diy assigns the same shared
   locations and the same per-proc roles in both.  We then keep, for each
   processor, the column produced by the run that OWNS that processor's device
   (`-devices cpu,gpu`), and merge the columns -- plus each proc's init atoms
   and condition atoms -- into one `Het` test.  Only the instruction ENCODING
   differs between the two runs; locations and the event graph do not, so the
   merge is well defined.

   This is the gen-side analogue of litmus/HetArch.ml: heterogeneity is added
   as a per-proc {device,scope} assignment over otherwise standard single-arch
   generation, with strings as the cross-arch erasure boundary (Code.het_cells).
*)

open Printf

(* --- extra command-line flags (the rest are reused from Config.diyone_spec) --- *)
let cpu_edges = ref ""
let gpu_edges = ref ""
let devices = ref "cpu,gpu"
let comment = ref None

let myspec =
  [
   "-cpu", Arg.String (fun s -> cpu_edges := s),
   "<edges> edge cycle for the CPU (AArch64) procs";
   "-gpu", Arg.String (fun s -> gpu_edges := s),
   "<edges> edge cycle for the GPU (LISA/Bell) procs";
   "-devices", Arg.String (fun s -> devices := s),
   sprintf "<d0,d1,..> per-proc device assignment (default %s)" !devices;
   "-com", Arg.String (fun s -> comment := Some s),
   "<text> documentation comment line for the test";
  ]

let () =
  Util.parse_cmdline
    ~usage_suffix:Config.diyone_parser_syntax_doc
    (myspec @ Config.diyone_spec ())
    (fun _ -> () (* het cycles arrive via -cpu/-gpu; ignore positionals *)) ;
  Config.validate_variant ()

(* --- small string helpers (kept dependency-free: no Str) --- *)

let split_tokens s =
  List.filter (fun x -> x <> "")
    (String.split_on_char ' ' (String.trim s))

let split_comma s =
  List.filter (fun x -> x <> "")
    (List.map String.trim (String.split_on_char ',' s))

(* split a condition body on the 2-char and-connective (slash backslash) *)
let split_and s =
  let sep = "/\\" in
  let n = String.length s and m = String.length sep in
  let rec go start i acc =
    if i > n - m then List.rev (String.sub s start (n-start) :: acc)
    else if String.sub s i m = sep then
      go (i+m) (i+m) (String.sub s start (i-start) :: acc)
    else go start (i+1) acc in
  if n = 0 then [] else go 0 0 []

(* the proc that a state/condition atom belongs to: the digits before its
   first ':' (e.g. "1:r0=1" -> Some 1); a global atom ("x=0") -> None *)
let proc_of_atom a =
  match String.index_opt a ':' with
  | Some k when k > 0
      && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub a 0 k) ->
      Some (int_of_string (String.sub a 0 k))
  | _ -> None

let parse_cond s =
  let s = String.trim s in
  match String.index_opt s '(' with
  | None -> (s,[])
  | Some i ->
      let quant = String.trim (String.sub s 0 i) in
      let j = String.rindex s ')' in
      let body = String.sub s (i+1) (j-i-1) in
      (quant, List.map String.trim (split_and body))

let () =
  (* Top_gen configuration, mirroring diyone's (DumpAll fields not needed). *)
  let module Co = struct
    let verbose = !Config.verbose
    let generator = Config.baseprog
    let debug = !Config.debug
    let hout = (match !Config.hout with None -> Hint.none | Some n -> Hint.open_out n)
    let cond = !Config.cond
    let neg = !Config.neg
    let nprocs = !Config.nprocs
    let eprocs = !Config.eprocs
    let do_observers = !Config.do_observers
    let obs_type = !Config.obs_type
    let optcond = !Config.optcond
    let overload = !Config.overload
    let poll = !Config.poll
    let optcoherence = !Config.optcoherence
    let docheck = !Config.docheck
    let typ = !Config.typ
    let hexa = !Config.hexa
    let variant = !Config.variant
    let cycleonly = false
    let metadata = false
    let same_loc = !Config.same_loc
  end in
  let module C = struct
    let verbose = !Config.verbose
    let show = !Config.show
    let same_loc = !Config.same_loc
    let unrollatomic = !Config.unrollatomic
    let allow_back = true
    let typ = !Config.typ
    let hexa = !Config.hexa
    let moreedges = !Config.moreedges
    let realdep = !Config.realdep
    let variant = !Config.variant
    let wildcard = false
  end in
  (* The two single-arch builders, instantiated exactly as in diyone.ml. *)
  let module Mcpu = Top_gen.Make(Co)(AArch64Compile_gen.Make(C)) in
  let module BellConfig = Config.ToLisa(Config) in
  let module Mgpu = Top_gen.Make(Co)(BellCompile.Make(C)(BellConfig)) in

  let name = match !Config.name with Some n -> n | None -> "HET" in

  let parse_cpu () =
    match
      Mcpu.R.parse_sequence_ast Parser.main (split_tokens !cpu_edges)
      |> Mcpu.R.parse_expand_relaxs ~ppo:Mcpu.ppo
    with
    | [x] -> x
    | _ -> Warn.fatal "-cpu must specify exactly one cycle" in
  let parse_gpu () =
    match
      Mgpu.R.parse_sequence_ast Parser.main (split_tokens !gpu_edges)
      |> Mgpu.R.parse_expand_relaxs ~ppo:Mgpu.ppo
    with
    | [x] -> x
    | _ -> Warn.fatal "-gpu must specify exactly one cycle" in

  if !cpu_edges = "" then Warn.fatal "missing -cpu <edges>" ;
  if !gpu_edges = "" then Warn.fatal "missing -gpu <edges>" ;
  if !Config.bell = None then
    Warn.fatal "missing -bell <ptx.bell> (the GPU side needs a Bell model)" ;

  let ccpu = Mcpu.het_cells (Mcpu.make_test name (parse_cpu ())) in
  let cgpu = Mgpu.het_cells (Mgpu.make_test name (parse_gpu ())) in

  let devs = split_comma !devices in
  let nprocs = List.length devs in
  let run_of = function
    | "cpu" -> ccpu
    | "gpu" -> cgpu
    | d -> Warn.fatal "unknown device '%s' (expected cpu|gpu)" d in
  (* Both runs must agree on the proc count, else the cycles are not the same
     shape and the column merge would be unsound. *)
  List.iter
    (fun (who,hc) ->
      if List.length hc.Code.hc_cols <> nprocs then
        Warn.fatal
          "device assignment has %d procs but the %s cycle has %d"
          nprocs who (List.length hc.Code.hc_cols))
    ["cpu",ccpu; "gpu",cgpu] ;

  (* Columns: each proc's cells come from the run owning that proc's device. *)
  let cols =
    List.mapi
      (fun i dev ->
        let hc = run_of dev in
        let cells =
          try List.assoc i hc.Code.hc_cols
          with Not_found -> Warn.fatal "%s run has no proc P%d" dev i in
        sprintf "P%d:%s" i dev :: cells)
      devs in
  let table = Misc.string_of_prog cols in

  (* Init: each proc's reg atoms from its owner; globals unioned (deduped). *)
  let per_proc_init =
    List.concat
      (List.mapi
        (fun i dev ->
          Misc.filter_map
            (fun (po,s) -> if po = Some i then Some s else None)
            (run_of dev).Code.hc_init)
        devs) in
  let globals_of hc =
    Misc.filter_map (fun (po,s) -> if po = None then Some s else None)
      hc.Code.hc_init in
  let global_init =
    List.fold_left
      (fun acc s -> if List.mem s acc then acc else acc @ [s])
      [] (globals_of ccpu @ globals_of cgpu) in
  let init_lines = global_init @ per_proc_init in

  (* Condition: each proc's atoms from its owner, globals from the cpu run. *)
  let merged_cond =
    let quant,_ = parse_cond ccpu.Code.hc_cond in
    let per_proc =
      List.concat
        (List.mapi
          (fun i dev ->
            let _,atoms = parse_cond (run_of dev).Code.hc_cond in
            List.filter (fun a -> proc_of_atom a = Some i) atoms)
          devs) in
    let _,cpu_atoms = parse_cond ccpu.Code.hc_cond in
    let globals = List.filter (fun a -> proc_of_atom a = None) cpu_atoms in
    sprintf "%s (%s)" quant (String.concat " /\\ " (per_proc @ globals)) in

  let buf = Buffer.create 512 in
  bprintf buf "Het %s\n" name ;
  (match !comment with
   | Some c -> bprintf buf "\"%s\"\n" c
   | None ->
       bprintf buf
         "\"Heterogeneous %s: per-proc device assignment %s (cpu=AArch64, gpu=LISA/PTX)\"\n"
         name !devices) ;
  bprintf buf "{\n" ;
  List.iter (fun l -> bprintf buf "%s;\n" l) init_lines ;
  bprintf buf "}\n" ;
  bprintf buf "%s" table ;
  bprintf buf "%s\n" merged_cond ;
  print_string (Buffer.contents buf)
