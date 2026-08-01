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
   generation, with strings as the cross-arch erasure boundary (HetCells.t).
*)

open Printf

(* --- extra command-line flags (the rest are reused from Config.diyone_spec) --- *)
let cpu_edges = ref ""
let gpu_edges = ref ""
let devices = ref "cpu,gpu"
let comment = ref None
(* HetLitmus Phase A: the CPU ISA the cpu-tagged procs are generated for.  The
   emitted device tag names this ISA so litmus7's `Het' arm can pick the
   matching CPU sub-parser/compiler.  Default AArch64 keeps pre-Phase-A output
   byte-identical (cpu procs still tagged `cpu', the AArch64 back-compat alias). *)
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
  (* The GPU builder is fixed (LISA/Bell); the CPU builder is dispatched by
     -cpu-arch below.  Both instantiated exactly as in diyone.ml. *)
  let module BellConfig = Config.ToLisa(Config) in
  let module Mgpu = Top_gen.Make(Co)(BellCompile.Make(C)(BellConfig)) in

  let name = match !Config.name with Some n -> n | None -> "HET" in

  (* One device's run: parse its -cpu / -gpu edge list into the single cycle
     the merge assumes, build the test, erase it to cells.  [opt] names the
     flag the edges came from, so the arity error points at the right one. *)
  let module HetRun (M:Builder.S) = struct
    let cells opt edges =
      let cy =
        match
          M.R.parse_sequence_ast Parser.main (split_tokens edges)
          |> M.R.parse_expand_relaxs ~ppo:M.ppo
        with
        | [x] -> x
        | _ -> Warn.fatal "%s must specify exactly one cycle" opt in
      M.het_cells (M.make_test name cy)
  end in

  if !cpu_edges = "" then Warn.fatal "missing -cpu <edges>" ;
  if !gpu_edges = "" then Warn.fatal "missing -gpu <edges>" ;
  if !Config.bell = None then
    Warn.fatal "missing -bell <ptx.bell> (the GPU side needs a Bell model)" ;

  (* CPU side: dispatch the single-arch Compile_gen module by -cpu-arch, exactly
     as diyone.ml dispatches by -arch.  het_cells erases the arch to strings, so
     ccpu's type is ISA-independent regardless of which branch builds it. *)
  let ccpu =
    match !cpu_arch with
    | `AArch64 ->
       let module R = HetRun(Top_gen.Make(Co)(AArch64Compile_gen.Make(C))) in
       R.cells "-cpu" !cpu_edges
    | `X86_64 ->
       let module R = HetRun(Top_gen.Make(Co)(X86_64Compile_gen.Make(C))) in
       R.cells "-cpu" !cpu_edges in
  let cgpu = let module R = HetRun(Mgpu) in R.cells "-gpu" !gpu_edges in

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
      if List.length hc.HetCells.hc_cols <> nprocs then
        Warn.fatal
          "device assignment has %d procs but the %s cycle has %d"
          nprocs who (List.length hc.HetCells.hc_cols))
    ["cpu",ccpu; "gpu",cgpu] ;

  (* The emitted header tag for a cpu proc NAMES its ISA (Phase A): default
     AArch64 keeps the back-compat `cpu' alias, x86_64 names itself.  gpu procs
     keep their `gpu' tag.  (run_of still keys on the device class cpu|gpu.) *)
  let cpu_tag = match !cpu_arch with `AArch64 -> "cpu" | `X86_64 -> "x86_64" in
  let header_tag = function "cpu" -> cpu_tag | other -> other in

  (* Columns: each proc's cells come from the run owning that proc's device. *)
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

  (* Init: each proc's reg atoms from its owner; globals unioned (deduped). *)
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

  (* Condition: each proc's atoms from its owner; global atoms (proc = None)
     unioned across BOTH runs and de-duplicated -- mirroring [global_init]
     above.  Taking globals from the cpu run alone dropped any global condition
     atom that only the gpu run carries (e.g. a location condition [x]=N on the
     GPU column), silently weakening the merged test's condition. *)
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
    (* Guard: an empty atom list would emit a malformed "exists ()".  herd and
       litmus spell the trivially-true condition "<quant> (true)" (the grammar
       reduces prop: TRUE -> And [], i.e. ConstrGen.constr_true). *)
    if atoms = [] then sprintf "%s (true)" quant
    else sprintf "%s (%s)" quant (String.concat " /\\ " atoms) in

  (* HetLitmus Task 8: a parseable nested `scopes:' body tree (grammar
     lib/scopeRules.mly).  diy's `Scopes=' header info field is NOT herd-
     parseable, so we follow the gpu-only generate.sh precedent and emit the
     tree into the test body instead.  Each GPU-owned proc nests in its own CTA
     under the GPU device: (sys (gpu (cta P<i>) ...)).  CPU procs are
     system-scope and are therefore omitted -- a proc absent from every
     sub-scope group sits at the sys root by default (the scope grammar makes a
     node either all-procs or all-subtrees, so a CPU proc cannot share the sys
     node with the gpu subtree anyway).  With no GPU proc the tree degenerates
     to (sys). *)
  let gpu_procs =
    Misc.filter_map (fun (i,dev) -> if dev = "gpu" then Some i else None)
      (List.mapi (fun i dev -> (i,dev)) devs) in
  let scopes_line =
    match gpu_procs with
    | [] -> "scopes: (sys)"
    | ps ->
        sprintf "scopes: (sys (gpu %s))"
          (String.concat " " (List.map (fun i -> sprintf "(cta P%d)" i) ps)) in

  let buf = Buffer.create 512 in
  bprintf buf "Het %s\n" name ;
  (match !comment with
   | Some c -> bprintf buf "\"%s\"\n" c
   | None ->
       let cpu_arch_name =
         match !cpu_arch with `AArch64 -> "AArch64" | `X86_64 -> "x86_64" in
       bprintf buf
         "\"Heterogeneous %s: per-proc device assignment %s (cpu=%s, gpu=LISA/PTX)\"\n"
         name !devices cpu_arch_name) ;
  bprintf buf "{\n" ;
  List.iter (fun l -> bprintf buf "%s;\n" l) init_lines ;
  bprintf buf "}\n" ;
  bprintf buf "%s" table ;
  bprintf buf "%s\n" scopes_line ;
  bprintf buf "%s\n" merged_cond ;
  print_string (Buffer.contents buf)
