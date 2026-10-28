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

open Printf

let cpu_edges = ref ""
let gpu_edges = ref ""
let devices = ref "cpu,gpu"
let comment = ref None
let cpu_arch = ref `AArch64

let myspec =
  [
   "-cpu-arch",
   Arg.String
     (fun s -> cpu_arch :=
        (match String.lowercase_ascii s with
         | "aarch64" | "arm" | "cpu" -> `AArch64
         | "x86_64" | "x86-64" | "amd64" | "x64" -> `X86_64
         | _ -> Warn.fatal "-cpu-arch: unknown ISA %S (use aarch64|x86_64)" s)),
   "<isa> CPU ISA for cpu-tagged procs (aarch64|x86_64; default aarch64)";
   "-cpu", Arg.String (fun s -> cpu_edges := s),
   "<edges> edge cycle for the CPU (AArch64) procs";
   "-gpu", Arg.String (fun s -> gpu_edges := s),
   "<edges> edge cycle for the GPU (LISA/Bell) procs";
   "-devices", Arg.String (fun s -> devices := s),
   sprintf "<d0,d1,..> per-proc device assignment (default %s)" !devices;
   "-com", Arg.String (fun s -> comment := Some s),
   "<text> documentation comment line for the test";
  ]

let spec () =
  myspec @
  List.filter_map
    (fun (key,act,doc) -> match key with
     | "-unicond" -> None
     | "-cond" ->
        Some (key,act,"<cycle> style of final condition, the only style the \
                       het merge takes")
     | _ -> Some (key,act,doc))
    (Config.diyone_spec ())

let split_tokens s =
  List.filter (fun x -> x <> "")
    (String.split_on_char ' ' (String.trim s))

let split_comma s =
  List.filter (fun x -> x <> "")
    (List.map String.trim (String.split_on_char ',' s))

let split_and s =
  let sep = "/\\" in
  let n = String.length s and m = String.length sep in
  let rec go start i acc =
    if i > n - m then List.rev (String.sub s start (n-start) :: acc)
    else if String.sub s i m = sep then
      go (i+m) (i+m) (String.sub s start (i-start) :: acc)
    else go start (i+1) acc in
  if n = 0 then [] else go 0 0 []

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

let generate () =
  (match !Config.cond with
   | Config.Cycle -> ()
   | Config.Unicond | Config.Observe ->
      Warn.fatal
        "-cond unicond/observe is unsupported: the het merge splices a flat \
         conjunction of per-proc atoms, which only -cond cycle produces") ;
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
  let module BellConfig = Config.ToLisa(Config) in
  let module Mgpu = Top_gen.Make(Co)(BellCompile.Make(C)(BellConfig)) in

  let name = match !Config.name with Some n -> n | None -> "HET" in

  let module HetRun (M:Builder.S) = struct
    let skeleton opt i e =
      let refuse what =
        Warn.fatal
          "%s edge %d is %s, whose kind is an architecture-specific payload \
           the shape check cannot compare across the two runs"
          opt (i+1) what in
      let kind = match e.M.E.edge with
      | M.E.Po _|M.E.Fenced _ -> "Po"
      | M.E.Communication (c,_) -> Code.pp_com c
      | M.E.Leave c -> Code.pp_com c ^ "Leave"
      | M.E.Back c -> Code.pp_com c ^ "Back"
      | M.E.Hat -> "Hat"
      | M.E.Id -> "Id"
      | M.E.Store -> "Store"
      | M.E.Node _ -> "Node"
      | M.E.Dp _ -> refuse "a dependency"
      | M.E.Insert _ -> refuse "a standalone fence"
      | M.E.Rmw _ -> refuse "a read-modify-write" in
      sprintf "%s:%s%s:%s>%s" kind
        (Code.pp_sd (M.E.loc_sd e)) (Code.pp_ie (M.E.get_ie e))
        (Code.pp_extr (M.E.dir_src e)) (Code.pp_extr (M.E.dir_tgt e))

    let cells opt edges =
      let cy =
        match
          M.R.parse_sequence_ast Parser.main (split_tokens edges)
          |> M.R.parse_expand_relaxs ~ppo:M.ppo
        with
        | [x] -> x
        | _ -> Warn.fatal "%s must specify exactly one cycle" opt in
      let shape = List.mapi (skeleton opt) cy in
      (shape, M.het_cells (M.make_test name cy))
  end in

  if !cpu_edges = "" then Warn.fatal "missing -cpu <edges>" ;
  if !gpu_edges = "" then Warn.fatal "missing -gpu <edges>" ;
  if !Config.bell = None then
    Warn.fatal "missing -bell <gpu.bell> (the GPU side needs a Bell model)" ;

  let cpu_shape,ccpu =
    match !cpu_arch with
    | `AArch64 ->
       let module R = HetRun(Top_gen.Make(Co)(AArch64Compile_gen.Make(C))) in
       R.cells "-cpu" !cpu_edges
    | `X86_64 ->
       let module R = HetRun(Top_gen.Make(Co)(X86_64Compile_gen.Make(C))) in
       R.cells "-cpu" !cpu_edges in
  let gpu_shape,cgpu = let module R = HetRun(Mgpu) in R.cells "-gpu" !gpu_edges in

  let rec first_diff i cs gs = match cs,gs with
  | [],[] -> None
  | c::cs,g::gs ->
      if String.equal c g then first_diff (i+1) cs gs else Some (i,c,g)
  | c::_,[] -> Some (i,c,"none")
  | [],g::_ -> Some (i,"none",g) in
  (match first_diff 1 cpu_shape gpu_shape with
   | None -> ()
   | Some (i,c,g) ->
      Warn.fatal
        "-cpu and -gpu cycles differ in shape at edge %d (cpu %s, gpu %s): \
         cpu [%s], gpu [%s]"
        i c g
        (String.concat " " cpu_shape) (String.concat " " gpu_shape)) ;

  let devs = split_comma !devices in
  if not (List.mem "gpu" devs) then
    Warn.fatal
      "-devices %s names no gpu proc; a het test needs at least one, and an \
       all-CPU cycle is diyone7's own -arch X86_64/AArch64"
      !devices ;
  let nprocs = List.length devs in
  let run_of = function
    | "cpu" -> ccpu
    | "gpu" -> cgpu
    | d -> Warn.fatal "unknown device '%s' (expected cpu|gpu)" d in
  List.iter
    (fun (who,hc) ->
      if List.length hc.HetCells.hc_cols <> nprocs then
        Warn.fatal
          "device assignment has %d procs but the %s cycle has %d"
          nprocs who (List.length hc.HetCells.hc_cols))
    ["cpu",ccpu; "gpu",cgpu] ;

  let cpu_tag = match !cpu_arch with `AArch64 -> "cpu" | `X86_64 -> "x86_64" in
  let header_tag = function "cpu" -> cpu_tag | other -> other in

  let cols =
    List.mapi
      (fun i dev ->
        let hc = run_of dev in
        let cells =
          try List.assoc i hc.HetCells.hc_cols
          with Not_found -> Warn.fatal "%s run has no proc P%d" dev i in
        sprintf "P%d:%s" i (header_tag dev) :: cells)
      devs in
  let table = Misc.string_of_prog cols in

  let per_proc_init =
    List.concat
      (List.mapi
        (fun i dev ->
          Misc.filter_map
            (fun (po,s) -> if po = Some i then Some s else None)
            (run_of dev).HetCells.hc_init)
        devs) in
  let globals_of hc =
    Misc.filter_map (fun (po,s) -> if po = None then Some s else None)
      hc.HetCells.hc_init in
  let global_init =
    List.fold_left
      (fun acc s -> if List.mem s acc then acc else acc @ [s])
      [] (globals_of ccpu @ globals_of cgpu) in
  let init_lines = global_init @ per_proc_init in

  (* Global atoms come from both runs: one run alone can miss an atom only the
     other carries. *)
  let merged_cond =
    let quant,_ = parse_cond ccpu.HetCells.hc_cond in
    let per_proc =
      List.concat
        (List.mapi
          (fun i dev ->
            let _,atoms = parse_cond (run_of dev).HetCells.hc_cond in
            List.filter (fun a -> proc_of_atom a = Some i) atoms)
          devs) in
    let cond_globals_of hc =
      let _,atoms = parse_cond hc.HetCells.hc_cond in
      List.filter (fun a -> proc_of_atom a = None) atoms in
    let globals =
      List.fold_left
        (fun acc s -> if List.mem s acc then acc else acc @ [s])
        [] (cond_globals_of ccpu @ cond_globals_of cgpu) in
    let atoms = per_proc @ globals in
    if atoms = [] then sprintf "%s (true)" quant
    else sprintf "%s (%s)" quant (String.concat " /\\ " atoms) in

  let gpu_procs =
    Misc.filter_map (fun (i,dev) -> if dev = "gpu" then Some i else None)
      (List.mapi (fun i dev -> (i,dev)) devs) in
  let scopes_line =
    sprintf "scopes: (sys (gpu %s))"
      (String.concat " "
         (List.map (fun i -> sprintf "(cta P%d)" i) gpu_procs)) in

  let buf = Buffer.create 512 in
  bprintf buf "Het %s\n" name ;
  (match !comment with
   | Some c -> bprintf buf "\"%s\"\n" c
   | None ->
       let cpu_arch_name =
         match !cpu_arch with `AArch64 -> "AArch64" | `X86_64 -> "x86_64" in
       bprintf buf
         "\"Heterogeneous %s: per-proc device assignment %s (cpu=%s, gpu=LISA)\"\n"
         name !devices cpu_arch_name) ;
  bprintf buf "{\n" ;
  List.iter (fun l -> bprintf buf "%s;\n" l) init_lines ;
  bprintf buf "}\n" ;
  bprintf buf "%s" table ;
  bprintf buf "%s\n" scopes_line ;
  bprintf buf "%s\n" merged_cond ;
  print_string (Buffer.contents buf)

let () =
  try
    Util.parse_cmdline
      ~usage_suffix:Config.diyone_parser_syntax_doc
      (spec ())
      (fun _ -> ()) ;
    Config.validate_variant () ;
    generate ()
  with
  | Misc.Exit -> exit 2
  | Misc.Fatal msg | Misc.UserError msg ->
      eprintf "%s: Fatal error: %s\n" Config.prog msg ;
      exit 2
