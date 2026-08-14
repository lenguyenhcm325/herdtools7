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

(* HetLitmus: the machine table.  Contract and rationale in the .mli. *)

type machine = {
    mc_link_name : string ;   (* no leading article: use sites supply their own *)
    mc_host_half : string ;
    mc_dev_half : string ;
    (* "Zero without stress" is a measurement on NVIDIA silicon
       [Alglave15 sec 4.3.1].  True only where it was measured; everywhere else
       the gap is stated instead of the number being borrowed. *)
    mc_alglave_zero : bool ;
    (* The last-level cache a noise buffer must EXCEED to cross anything on this
       part, in MB, and the parenthetical printed after that warning.  [None]
       means no figure is published for the target: the warning then names the
       mechanism and discloses that its threshold is a fallback measured
       elsewhere, rather than passing another part's capacity off as this one's. *)
    mc_llc_mb : int option ;
    mc_llc_note : string ;
    (* This machine's words, by the name of the hole each one fills.  Contract
       in the .mli; [generic_machine] below is the row a nameless render fills
       them from. *)
    mc_words : (string * string) list ;
  }

type t = machine option

(* THE FALLBACK, and it claims least: it names the MECHANISM, never a brand.  A
   pair with no machine row gets this and stamps no machine defines at all, so
   het_verdict.h's #ifndef defaults -- which are these same words -- stand.  It
   carries a word for every hole any dialect payload spells, and deliberately no
   PART: a render with no machine row names no silicon, so the sites that would
   have printed a part print nothing there instead. *)
let generic_machine = {
    mc_link_name = "host-device interconnect" ;
    mc_host_half = "the host half" ;
    mc_dev_half = "the device half" ;
    mc_alglave_zero = false ;
    mc_llc_mb = None ;
    mc_llc_note =
      " (the local-cache argument is target-independent; no measured \
       last-level-cache behaviour is claimed for this target)" ;
    mc_words = [
        "HOST", "host" ;
        "LINK", "interconnect" ;
        "LINK_OBJ", "the interconnect" ;
        "MALLOC_SITE", "system malloc where the GPU reaches pageable memory" ;
        "HIP_RENDER", "HIP" ;
        "NO_PLACE_WHY", "This render has no page-placement API to call" ;
        "APU_CLASS", "integrated" ;
        "DGPU_CLASS", "not-integrated" ;
        "DGPU_NAME", "not integrated" ;
        "APU_NAME", "an integrated APU" ;
        "APU_RESULT", "an integrated-APU result" ;
      ] ;
  }

(* GH200: Grace (AArch64) + Hopper over NVLink-C2C.  Hopper's L2 caches HBM
   whether the line is local or peer [Fusco24 sec III-E.1]. *)
let gh200_machine = {
    mc_link_name = "NVLink-C2C" ;
    mc_host_half = "the Grace half" ;
    mc_dev_half = "the Hopper half" ;
    mc_alglave_zero = true ;
    (* max(Grace L3 114 MB, Hopper L2 51 MB) [Bagchi26 Table 1]. *)
    mc_llc_mb = Some 114 ;
    mc_llc_note = " (Fusco: Hopper L2 caches HBM, local and peer)" ;
    mc_words = [
        "PART", "GH200" ;
        "HOST", "Grace" ;
        "LINK", "C2C" ;
        "LINK_OBJ", "C2C" ;
        "MALLOC_SITE", "system malloc on GH200" ;
      ] ;
  }

(* MI300A: Zen-4 x86-64 CCDs + CDNA3 XCDs on one package over Infinity Fabric.
   "Zero without stress" stays withheld: no equivalent figure is published for
   this part.  The LLC figure is not withheld, because one IS published for it
   -- 256 MB, and the Grace 114 MB it replaces under-fires here, so this
   part's own figure is at once the published one and the conservative one. *)
let mi300a_machine = {
    mc_link_name = "Infinity Fabric" ;
    mc_host_half = "the x86 half" ;
    mc_dev_half = "the MI300A device half" ;
    mc_alglave_zero = false ;
    (* The MALL / AMD Infinity Cache on the I/O die is this part's last level,
       256 MB above the per-XCD 4 MB L2 [Tee25 Table 1]. *)
    mc_llc_mb = Some 256 ;
    mc_llc_note =
      " (the MALL / AMD Infinity Cache, 256 MB -- Tee et al., The MALL is \
       Open, SC-W'25 Table 1)" ;
    mc_words = [
        "PART", "MI300A" ;
        "HOST", "x86" ;
        "LINK", "Infinity Fabric" ;
        "LINK_OBJ", "Infinity Fabric" ;
        "HIP_RENDER", "HIP/MI300A" ;
        "NO_PLACE_WHY", "MI300A has one HBM pool and nothing to place" ;
        "APU_CLASS", "MI300A-class" ;
        "DGPU_CLASS", "MI300X-class" ;
        "DGPU_NAME", "MI300X class" ;
        "APU_NAME", "the MI300A APU" ;
        "APU_RESULT", "an MI300A result" ;
      ] ;
  }

(* THE TABLE.  Adding a machine is adding a row here; nothing else in the
   emitter knows a pair exists.  A row with no machine is REGISTERED all the
   same -- it says the pair is expected and deliberately nameless, which an
   absent row cannot say. *)
let table = [
    ("AArch64", "cuda"), Some gh200_machine ;
    ("X86_64", "hip"), Some mi300a_machine ;
    (* The dev box is an x86-64 host with an NVIDIA GPU, so this pair is what the
       runtime gates in this tree actually execute.  It is neither part above,
       and there is no third machine to name it after. *)
    ("X86_64", "cuda"), None ;
  ]

let pair_name ~cpu_isa ~target = Printf.sprintf "(%s, %s)" cpu_isa target

let word m name = List.assoc_opt name m.mc_words

(* FILL, AND REFUSE ON A HOLE NOBODY OWNS.  A hole is `@NAME@' with NAME over
   [A-Z0-9_]; anything else beginning with `@' is copied through, because C text
   is free to contain the character. *)
let fill m s =
  let n = String.length s in
  let b = Buffer.create n in
  let is_name c =
    (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' in
  let rec go i =
    if i >= n then Buffer.contents b
    else if s.[i] <> '@' then (Buffer.add_char b s.[i] ; go (i+1))
    else begin
      let j = ref (i+1) in
      while !j < n && is_name s.[!j] do incr j done ;
      if !j > i+1 && !j < n && s.[!j] = '@' then begin
        let name = String.sub s (i+1) (!j-i-1) in
        (match word m name with
         | Some w -> Buffer.add_string b w
         | None ->
            Warn.user_error
              "an emitted payload spells the machine-word hole @%s@ and the row \
               that resolved has no word for it, so the render would reach a \
               reader with the hole still in it.  Give %s a word in mc_words \
               (litmus/hetMachine.ml) -- in generic_machine too, which is what a \
               pair with no machine row prints from"
              name name) ;
        go (!j+1)
      end else (Buffer.add_char b '@' ; go (i+1))
    end in
  go 0

let registered_doc () =
  String.concat ", "
    (List.map (fun ((c,t),_) -> pair_name ~cpu_isa:c ~target:t) table)

(* WARN, NEVER REFUSE.  The pair decides which silicon may be named, not whether
   the machine can be measured: a harness that names none characterizes exactly
   as well, so the only thing an unregistered pair loses is the machine prose.
   One line, because a per-test refusal is what this replaced. *)
let resolve ~verbose ~cpu_isa ~target =
  match List.assoc_opt (cpu_isa,target) table with
  | Some m -> m, true
  | None ->
     if verbose >= 0 then
       Printf.eprintf
         "HetLitmus WARNING: the (CPU ISA x GPU dialect) pair %s is in no row of \
          litmus/hetMachine.ml, so this harness NAMES NO MACHINE: it stamps no \
          machine define, and wherever it would have printed one the runtime \
          headers' own #ifndef fallbacks stand -- het_verdict.h's wording for \
          the interconnect and its two halves, and het_cpu_stress.h's HET_LLC_MB, \
          which is a cache size measured on another part rather than a name.  \
          Registered pairs: %s.\n%!"
         (pair_name ~cpu_isa ~target) (registered_doc ()) ;
     None, false
