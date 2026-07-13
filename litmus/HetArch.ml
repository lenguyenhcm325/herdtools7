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

(* HetLitmus Tier-0: the compound pseudo-architecture (design fork (a)).

   herdtools7 hard-assumes ONE ISA per litmus test: a parsed test is
   monomorphic in a single ['pseudo], and the litmus7 dispatch instantiates one
   functor stack that fixes that ['pseudo] for the whole test.  Heterogeneous
   CPU-GPU tests have no representation under that assumption.

   Fork (a) breaks the assumption WITHOUT making the rest of litmus7
   multi-arch: the per-processor CPU-vs-GPU split is hidden INSIDE one
   architecture module whose instruction type is a SUM,

       instruction = CPUins of Cpu.instruction | GPUins of Gpu.instruction

   so the pipeline stays single-arch-typed (one [`Het] value of Archs.t, one
   ['pseudo]).  This functor takes the two real backend architectures as
   arguments and delegates every Arch_litmus.S operation per constructor.  The
   GH200 pairing is AArch64 (CPU) + LISA/PTX (GPU); other pairings are just
   different applications of this functor at a litmus7 dispatch arm.

   SCOPE (Tier 0): representation + parse + the type-level (a) implementation.
   Cross-device code EMISSION (asymmetric launch, coherent allocation,
   rendezvous barrier, result readback) is Tier 2 and out of scope here; the
   members that only feed emission (register init/class, macros, ...) are
   deliberately inert and flagged below.  See hetlitmus/docs/het-litmus-format.md. *)

(* HetLitmus Phase A: the per-column device tag NAMES the CPU ISA.  `cpu' stays
   a back-compat alias for AArch64 (so pre-Phase-A tests and hetgen7 output are
   byte-unchanged); `aarch64'/`x86_64' name the ISA explicitly.  These are
   top-level (outside the Make functor) because the litmus7 `Het' dispatch arm
   must pick the CPU ISA -- and so which CPU modules to feed the functor -- by
   pre-scanning the program header BEFORE any HetArch.Make application exists.
   cpu_isa_of_tag returns None for GPU tags, so it doubles as the CPU/GPU test. *)
type cpu_isa = IsaAArch64 | IsaX86_64

let cpu_isa_of_tag s = match String.lowercase_ascii (String.trim s) with
  | "cpu" | "aarch64" | "arm" -> Some IsaAArch64
  | "x86_64" | "x86-64" | "amd64" | "x64" -> Some IsaX86_64
  | _ -> None

let cpu_isa_tag = function IsaAArch64 -> "aarch64" | IsaX86_64 -> "x86_64"

(* Pre-scan the program-section header ("P0:aarch64 | P1:gpu ; ...") to pick the
   ONE CPU ISA the test's CPU columns share.  Returns the first CPU column's
   ISA; defaults to AArch64 (back-compat) if the test has no CPU column. *)
let scan_cpu_isa prog_text =
  let is_blank s = String.trim s = "" in
  let rows =
    List.filter (fun r -> not (is_blank r))
      (String.split_on_char ';' prog_text) in
  match rows with
  | [] -> IsaAArch64
  | header :: _ ->
     let cells = String.split_on_char '|' header in
     let tag_of cell =
       match String.split_on_char ':' (String.trim cell) with
       | [_;d] -> String.trim d
       | _ -> "" in
     let rec first = function
       | [] -> IsaAArch64
       | cell :: rest ->
          (match cpu_isa_of_tag (tag_of cell) with
           | Some isa -> isa
           | None -> first rest) in
     first cells

module Make (Cpu:Arch_litmus.S) (Gpu:Arch_litmus.S) = struct

  (* Who am I *)
  let arch = `Het
  let base_type = Cpu.base_type

  (* ---------------- Sum types (the (a) core) ---------------- *)

  type reg = CPUreg of Cpu.reg | GPUreg of Gpu.reg
  type barrier = CPUbar of Cpu.barrier | GPUbar of Gpu.barrier
  type instruction = CPUins of Cpu.instruction | GPUins of Gpu.instruction
  type parsedInstruction =
    | CPUpins of Cpu.parsedInstruction
    | GPUpins of Gpu.parsedInstruction

  (* ---------------- Registers ---------------- *)

  let parse_reg s = match Cpu.parse_reg s with
    | Some r -> Some (CPUreg r)
    | None ->
       begin match Gpu.parse_reg s with
       | Some r -> Some (GPUreg r)
       | None -> None
       end

  let pp_reg = function CPUreg r -> Cpu.pp_reg r | GPUreg r -> Gpu.pp_reg r

  let reg_compare r1 r2 = match r1,r2 with
    | CPUreg r1,CPUreg r2 -> Cpu.reg_compare r1 r2
    | GPUreg r1,GPUreg r2 -> Gpu.reg_compare r1 r2
    | CPUreg _,GPUreg _ -> -1
    | GPUreg _,CPUreg _ -> 1

  let symb_reg_name = function
    | CPUreg r -> Cpu.symb_reg_name r
    | GPUreg r -> Gpu.symb_reg_name r

  (* fresh symbolic register: only reachable from symbolic-register allocation
     in the (Tier-2) emission path, never from the het parser, where registers
     arrive already device-tagged from the sub-parsers.  Default to the CPU. *)
  let symb_reg s = CPUreg (Cpu.symb_reg s)

  let type_reg = function
    | CPUreg r -> Cpu.type_reg r
    | GPUreg r -> Gpu.type_reg r

  let reg_to_string = function
    | CPUreg r -> Cpu.reg_to_string r
    | GPUreg r -> Gpu.reg_to_string r

  let allowed_for_symb =
    List.map (fun r -> CPUreg r) Cpu.allowed_for_symb
    @ List.map (fun r -> GPUreg r) Gpu.allowed_for_symb

  (* ---------------- Barriers ---------------- *)

  let pp_barrier = function
    | CPUbar b -> Cpu.pp_barrier b
    | GPUbar b -> Gpu.pp_barrier b

  let barrier_compare b1 b2 = match b1,b2 with
    | CPUbar b1,CPUbar b2 -> Cpu.barrier_compare b1 b2
    | GPUbar b1,GPUbar b2 -> Gpu.barrier_compare b1 b2
    | CPUbar _,GPUbar _ -> -1
    | GPUbar _,CPUbar _ -> 1

  (* ---------------- Instructions ---------------- *)

  (* No canonical device-agnostic nop / immediate branch for the compound arch. *)
  let nop = None
  let mk_imm_branch _ = None

  let is_nop = function CPUins i -> Cpu.is_nop i | GPUins i -> Gpu.is_nop i

  let pp_instruction m = function
    | CPUins i -> Cpu.pp_instruction m i
    | GPUins i -> Gpu.pp_instruction m i

  let dump_instruction = function
    | CPUins i -> Cpu.dump_instruction i
    | GPUins i -> Gpu.dump_instruction i

  let dump_instruction_hash = function
    | CPUins i -> Cpu.dump_instruction_hash i
    | GPUins i -> Gpu.dump_instruction_hash i

  (* ---------------- Register / address traversals ---------------- *)

  let fold_regs (freg,fsymb) acc = function
    | CPUins i ->
       Cpu.fold_regs ((fun r a -> freg (CPUreg r) a),fsymb) acc i
    | GPUins i ->
       Gpu.fold_regs ((fun r a -> freg (GPUreg r) a),fsymb) acc i

  (* Registers do not cross devices (a shared variable is one physical
     location, but a register belongs to exactly one processor); the
     cross-device arms below are therefore unreachable for well-formed tests. *)
  let map_regs freg fsymb = function
    | CPUins i ->
       CPUins
         (Cpu.map_regs
            (fun r -> match freg (CPUreg r) with CPUreg r -> r | GPUreg _ -> r)
            (fun s -> match fsymb s with CPUreg r -> r | GPUreg _ -> Cpu.symb_reg s)
            i)
    | GPUins i ->
       GPUins
         (Gpu.map_regs
            (fun r -> match freg (GPUreg r) with GPUreg r -> r | CPUreg _ -> r)
            (fun s -> match fsymb s with GPUreg r -> r | CPUreg _ -> Gpu.symb_reg s)
            i)

  let fold_addrs f acc = function
    | CPUins i -> Cpu.fold_addrs f acc i
    | GPUins i -> Gpu.fold_addrs f acc i

  let map_addrs f = function
    | CPUins i -> CPUins (Cpu.map_addrs f i)
    | GPUins i -> GPUins (Gpu.map_addrs f i)

  (* ---------------- InstrUtils.S ---------------- *)

  let norm_ins = function
    | CPUins i -> CPUins (Cpu.norm_ins i)
    | GPUins i -> GPUins (Gpu.norm_ins i)

  let is_valid = function
    | CPUins i -> Cpu.is_valid i
    | GPUins i -> Gpu.is_valid i

  let get_exported_label = function
    | CPUins i -> Cpu.get_exported_label i
    | GPUins i -> Gpu.get_exported_label i

  (* ---------------- Pseudo layer ----------------

     Generated by Pseudo.Make from the instruction-level delegates.  Every
     input is delegated FAITHFULLY through a sub-architecture's exposed
     Pseudo.S output (no placeholders): per-instruction memory-access counts
     via [get_naccesses [Instruction i]], [size_of_ins], [fold_labels] and
     [map_labels_base].  parsed_tr recovers the sub-arch's parsed->internal
     translation by round-tripping a singleton [Instruction] pseudo. *)

  include Pseudo.Make (struct
    type ins = instruction
    type pins = parsedInstruction
    type reg_arg = reg

    let parsed_tr = function
      | CPUpins p ->
         CPUins
           (match Cpu.pseudo_parsed_tr (Cpu.Instruction p) with
            | Cpu.Instruction i -> i
            | _ -> assert false)
      | GPUpins p ->
         GPUins
           (match Gpu.pseudo_parsed_tr (Gpu.Instruction p) with
            | Gpu.Instruction i -> i
            | _ -> assert false)

    let get_naccesses = function
      | CPUins i -> Cpu.get_naccesses [Cpu.Instruction i]
      | GPUins i -> Gpu.get_naccesses [Gpu.Instruction i]

    let size_of_ins = function
      | CPUins i -> Cpu.size_of_ins i
      | GPUins i -> Gpu.size_of_ins i

    let fold_labels acc f = function
      | CPUins i -> Cpu.fold_labels f acc (Cpu.Instruction i)
      | GPUins i -> Gpu.fold_labels f acc (Gpu.Instruction i)

    let map_labels f = function
      | CPUins i -> CPUins (Cpu.map_labels_base f i)
      | GPUins i -> GPUins (Gpu.map_labels_base f i)
  end)

  (* Macros are arch-specific assembler conveniences; the Tier-0 het corpus
     uses none.  Reached only if a Macro pseudo survives to expansion. *)
  let get_macro name =
    fun _ _ -> Warn.fatal "HetArch: macro %s is unsupported in heterogeneous tests" name

  let hash_pteval p = Cpu.hash_pteval p

  (* ---------------- Values, errors, ArchExtra ---------------- *)

  (* One value module over the compound instruction.  Both realistic backends
     (AArch64 and LISA) already agree on Int64Constant, so a shared litmus
     variable needs no width reconciliation. *)
  module V = Int64Constant.Make (Instr.No (struct type instr = instruction end))

  module FaultType = FaultType.No

  let error t1 t2 = Cpu.error t1 t2 || Gpu.error t1 t2
  let warn t1 t2 = Cpu.warn t1 t2 || Gpu.warn t1 t2

  include
    ArchExtra_litmus.Make
      (struct
        include Template.DefaultConfig
        let asmcomment = None
      end)
      (struct
        module V = V
        type arch_reg = reg
        let arch = `Het
        let forbidden_regs = []
        let pp_reg = pp_reg
        let reg_compare = reg_compare
        let reg_to_string = reg_to_string
        (* register init / classification feed ASM emission only (Tier 2) *)
        let internal_init _ _ = None
        let reg_class _ = ""
        let reg_class_stable _ _ = ""
        let comment = "//"
      end)

  let features = []

  include HardwareExtra.No

  module GetInstr = GetInstr.No (struct type instr = instruction end)

  (* ---------------- Parser support (Tier-0) ----------------

     of_{cpu,gpu}_parsed lift a sub-architecture's parsed pseudo into the
     compound parsed pseudo; the structural kpseudo skeleton (labels, nop) is
     device-agnostic, only the instruction payload is tagged.  The actual
     per-processor sub-parsing lives at the litmus7 dispatch arm (where the
     concrete AArch64Parser / LISAParser are in scope); het_parser then
     stitches the columns back into the (proc list, rows, extra) triple that
     lib/genParser.ml expects. *)

  let rec of_cpu_parsed : Cpu.parsedPseudo -> parsedPseudo = function
    | Cpu.Nop -> Nop
    | Cpu.Instruction i -> Instruction (CPUpins i)
    | Cpu.Label (l,k) -> Label (l,of_cpu_parsed k)
    | Cpu.Macro (s,rs) -> Macro (s,List.map (fun r -> CPUreg r) rs)
    | Cpu.Symbolic s -> Symbolic s
    | Cpu.Pagealign -> Pagealign
    | Cpu.Skip n -> Skip n

  let rec of_gpu_parsed : Gpu.parsedPseudo -> parsedPseudo = function
    | Gpu.Nop -> Nop
    | Gpu.Instruction i -> Instruction (GPUpins i)
    | Gpu.Label (l,k) -> Label (l,of_gpu_parsed k)
    | Gpu.Macro (s,rs) -> Macro (s,List.map (fun r -> GPUreg r) rs)
    | Gpu.Symbolic s -> Symbolic s
    | Gpu.Pagealign -> Pagealign
    | Gpu.Skip n -> Skip n

  (* ---------------- Tier-2 emission support ----------------

     A compound (internal) pseudo carries one device's instruction in its
     [Instruction] payload; the structural skeleton (labels, nop, skip) is
     device-agnostic.  to_{cpu,gpu}_pseudo project a single processor's column
     back onto its native sub-architecture's pseudo, so that processor can be
     fed to that backend's *own* compiler/emitter (AArch64 -> ASMLang,
     LISA/Bell -> CudaLang).  The cross-device arms are unreachable for a
     well-formed test (the het parser tags every cell with its column's device)
     and fail loudly if reached.  This is the projection inverse of
     of_{cpu,gpu}_parsed, one level down (internal pseudo, not parsed). *)

  let cpu_reg_of = function
    | CPUreg r -> r
    | GPUreg _ -> Warn.fatal "HetArch: GPU register on a CPU processor"
  let gpu_reg_of = function
    | GPUreg r -> r
    | CPUreg _ -> Warn.fatal "HetArch: CPU register on a GPU processor"

  let rec to_cpu_pseudo : pseudo -> Cpu.pseudo = function
    | Nop -> Cpu.Nop
    | Instruction (CPUins i) -> Cpu.Instruction i
    | Instruction (GPUins _) ->
       Warn.fatal "HetArch: a GPU instruction appears on a CPU processor"
    | Label (l,k) -> Cpu.Label (l,to_cpu_pseudo k)
    | Macro (s,rs) -> Cpu.Macro (s,List.map cpu_reg_of rs)
    | Symbolic s -> Cpu.Symbolic s
    | Pagealign -> Cpu.Pagealign
    | Skip n -> Cpu.Skip n

  let rec to_gpu_pseudo : pseudo -> Gpu.pseudo = function
    | Nop -> Gpu.Nop
    | Instruction (GPUins i) -> Gpu.Instruction i
    | Instruction (CPUins _) ->
       Warn.fatal "HetArch: a CPU instruction appears on a GPU processor"
    | Label (l,k) -> Gpu.Label (l,to_gpu_pseudo k)
    | Macro (s,rs) -> Gpu.Macro (s,List.map gpu_reg_of rs)
    | Symbolic s -> Gpu.Symbolic s
    | Pagealign -> Gpu.Pagealign
    | Skip n -> Gpu.Skip n

  type device = DevCpu | DevGpu

  let device_tag = function DevCpu -> "cpu" | DevGpu -> "gpu"

  (* parse_device classifies a raw column tag into the CPU/GPU device class.
     The ISA naming itself (which CPU ISA a `cpu'/`aarch64'/`x86_64' tag means)
     lives in the top-level cpu_isa_of_tag / scan_cpu_isa, so the litmus7 `Het'
     dispatch arm can pick the ISA BEFORE this functor is even applied. *)
  let parse_device s =
    match cpu_isa_of_tag s with
    | Some _ -> DevCpu
    | None ->
       begin match String.lowercase_ascii (String.trim s) with
       | "gpu" | "lisa" | "ptx" | "hip" -> DevGpu
       | d ->
          Warn.user_error
            "HetArch: unknown device tag %S (use aarch64|x86_64|cpu|gpu)" d
       end

  (* "P0:cpu" -> (0, DevCpu).  The per-proc device tag is the compound test's
     only extra syntax; see hetlitmus/docs/het-litmus-format.md. *)
  let parse_proc_cell s =
    let s = String.trim s in
    match String.split_on_char ':' s with
    | [p;d] ->
       let p = String.trim p in
       let p =
         if String.length p > 0 && (p.[0] = 'P' || p.[0] = 'p')
         then String.sub p 1 (String.length p-1)
         else p in
       begin
         try (int_of_string (String.trim p),parse_device d)
         with Failure _ ->
           Warn.user_error "HetArch: cannot read processor number in %S" s
       end
    | _ ->
       Warn.user_error
         "HetArch: every processor needs a device tag, e.g. P0:cpu (got %S)" s

  let het_parser ~cpu ~gpu _lexer lexbuf =
    let text = HetSlurp.slurp (Buffer.create 256) lexbuf in
    let is_blank s = String.trim s = "" in
    (* A `scopes:' tree (HetLitmus Task 8) sits in the program section between
       the last instruction row and the condition, so HetSlurp pulls it in
       here.  It carries no `;', so it would survive as a spurious trailing
       "row"; drop it.  het tests are not herd-ingested (the single-arch
       assumption blocks that), so the tree is documentary -- the CPU emission
       does not consume it. *)
    let is_scopes s =
      let t = String.trim s in
      String.length t >= 7 && String.sub t 0 7 = "scopes:" in
    let rows =
      List.filter (fun r -> not (is_blank r) && not (is_scopes r))
        (String.split_on_char ';' text) in
    match rows with
    | [] -> Warn.user_error "HetArch: empty heterogeneous program"
    | header::instr_rows ->
       let procs_dev = List.map parse_proc_cell (String.split_on_char '|' header) in
       let nprocs = List.length procs_dev in
       let row_cells =
         List.map
           (fun r ->
             let cells = String.split_on_char '|' r in
             if List.length cells <> nprocs then
               Warn.user_error
                 "HetArch: program row %S has %d cells but there are %d procs"
                 r (List.length cells) nprocs ;
             cells)
           instr_rows in
       (* per-processor columns of cell text *)
       let columns =
         List.init nprocs
           (fun j -> List.map (fun cells -> List.nth cells j) row_cells) in
       (* parse each column with its device's sub-architecture *)
       let parsed_columns =
         List.map2
           (fun (p,dev) col ->
             let txt = String.concat " ; " col in
             (* the proc number rides into the sub-parser so a malformed cell
                names its processor + ISA instead of failing at the section EOF *)
             match dev with DevCpu -> cpu p txt | DevGpu -> gpu p txt)
           procs_dev columns in
       (* genParser wants rows (it transposes rows -> columns internally) *)
       let prog_rows =
         match instr_rows with [] -> [] | _ -> Misc.transpose parsed_columns in
       let procs =
         List.map
           (fun (p,dev) -> (p,Some [device_tag dev],MiscParser.Main))
           procs_dev in
       (procs,prog_rows,MiscParser.empty_extra)
end

(* Compile-time proof that the functor's result satisfies Arch_litmus.S for any
   pair of backend architectures (this functor is never applied; type-checking
   it is the assertion).  Make itself stays unsealed so the litmus7 dispatch
   arm can reach the parser helpers above. *)
module Check (Cpu:Arch_litmus.S) (Gpu:Arch_litmus.S) : Arch_litmus.S =
  Make (Cpu) (Gpu)

(* ---------------- Tier-2 emission: embedded litmus7 histogram ----------------

   The emitted het harness reuses litmus7's OWN outcome histogram
   (litmus/libdir/_outs.{c,h}) to tally the merged CPU+GPU register readback.
   We embed those two files VERBATIM (CeCILL-B, as in the rest of the tree) so a
   het harness directory is self-contained and does not depend on a libdir at
   emit time -- the repro command uses '-set-libdir herd/libdir', which ships
   the herd .cat models, not litmus7's C runtime.  Keep these byte-identical to
   litmus/libdir/_outs.{c,h}. *)

let outs_h = {ocaml|/****************************************************************************/
/*                           the diy toolsuite                              */
/*                                                                          */
/* Jade Alglave, University College London, UK.                             */
/* Luc Maranget, INRIA Paris-Rocquencourt, France.                          */
/*                                                                          */
/* Copyright 2015-present Institut National de Recherche en Informatique et */
/* en Automatique and the authors. All rights reserved.                     */
/*                                                                          */
/* This software is governed by the CeCILL-B license under French law and   */
/* abiding by the rules of distribution of free software. You can use,      */
/* modify and/ or redistribute the software under the terms of the CeCILL-B */
/* license as circulated by CEA, CNRS and INRIA at the following URL        */
/* "http://www.cecill.info". We also give a copy in LICENSE.txt.            */
/****************************************************************************/
#ifndef _OUTS_H
#define _OUTS_H 1

#include <stdio.h>

/************************/
/* Histogram structure  */
/************************/


/* 64bit counters, should be enough! */
#include <inttypes.h>
typedef uint64_t count_t;
#define PCTR PRIu64




typedef struct outs_t {
  struct outs_t *next,*down ;
  count_t c ;
  intmax_t k ;
  int show ;
} outs_t ;

void free_outs(outs_t *p) ;
outs_t *add_outcome_outs(outs_t *p, intmax_t *o, int sz, count_t v, int show) ;
int finals_outs(outs_t *p) ;
count_t sum_outs(outs_t *p) ;
typedef void dump_outcome(FILE *chan, intmax_t *o, count_t c, int show) ;
void dump_outs (FILE *chan, dump_outcome *dout,outs_t *p, intmax_t *buff, int sz) ;
outs_t *merge_outs(outs_t *p,outs_t *q, int sz) ;
int same_outs(outs_t *p,outs_t *q) ;
#endif
|ocaml}

let outs_c = {ocaml|/****************************************************************************/
/*                           the diy toolsuite                              */
/*                                                                          */
/* Jade Alglave, University College London, UK.                             */
/* Luc Maranget, INRIA Paris-Rocquencourt, France.                          */
/*                                                                          */
/* Copyright 2015-present Institut National de Recherche en Informatique et */
/* en Automatique and the authors. All rights reserved.                     */
/*                                                                          */
/* This software is governed by the CeCILL-B license under French law and   */
/* abiding by the rules of distribution of free software. You can use,      */
/* modify and/ or redistribute the software under the terms of the CeCILL-B */
/* license as circulated by CEA, CNRS and INRIA at the following URL        */
/* "http://www.cecill.info". We also give a copy in LICENSE.txt.            */
/****************************************************************************/
#include <stdlib.h>
#include <stdio.h>
#include "outs.h"

/**********************/
/* Lexicographic tree */
/**********************/

#if 0
static void debug(int *t, int i, int j) {
  for (int k=i ; k <= j ; k++)
    fprintf(stderr,"%i",t[k]) ;
  fprintf(stderr,"\n") ;
}
#endif


void *malloc_check(size_t sz) ;

static outs_t *alloc_outs(intmax_t k) {
  outs_t *r = malloc_check(sizeof(*r)) ;
  r->k = k ;
  r->c = 0 ;
  r->show = 0 ;
  r->next = r->down = NULL ;
  return r ;
}

void free_outs(outs_t *p) {
  if (p == NULL) return ;
  free_outs(p->next) ;
  free_outs(p->down) ;
  free(p) ;
}

/* Worth writing as a loop, since called many times */
static outs_t *loop_add_outcome_outs(outs_t *p, intmax_t *k, int i, count_t c, int show) {
  outs_t *r = p ;
  if (p == NULL || k[i] < p->k) {
    r = alloc_outs(k[i]) ;
    r->next = p ;
    p = r ;
  }
  for ( ; ; ) {
    outs_t **q ;
    if (k[i] > p->k) {
      q = &(p->next) ;
      p = p->next ;
    } else if (i <= 0) {
      p->c += c ;
      p->show = show || p->show ;
      return r ;
    } else {
      i-- ;
      q = &(p->down) ;
      p = p->down ;
    }
    if (p == NULL || k[i] < p->k) {
      outs_t *a = alloc_outs(k[i]) ;
      a->next = p ;
      p = a ;
      *q = a ;
    }
  }
}

outs_t *add_outcome_outs(outs_t *p, intmax_t *k, int sz, count_t c, int show) {
  return loop_add_outcome_outs(p,k,sz-1,c,show) ;
}

count_t sum_outs(outs_t *p) {
  count_t r = 0 ;
  for ( ; p ; p = p->next) {
    r += p->c ;
    r += sum_outs(p->down) ;
  }
  return r ;
}

int finals_outs(outs_t *p) {
  int r = 0 ;
  for ( ; p ; p = p->next) {
    if (p->c > 0) r++ ;
    r += finals_outs(p->down) ;
  }
  return r ;
}

void dump_outs (FILE *chan, dump_outcome *dout,outs_t *p, intmax_t *buff,int sz) {
  for ( ; p ; p = p->next) {
    buff[sz-1] = p->k ;
    if (p->c > 0) {
      dout(chan,buff,p->c,p->show) ;
    } else if (p->down) {
      dump_outs(chan,dout,p->down,buff,sz-1) ;
    }
  }
}

/* merge p and q into p */
static outs_t *do_merge_outs(outs_t *p, outs_t *q) {
  if (q == NULL) { // Nothing to add
    return p ;
  }
  if (p == NULL || q->k < p->k) { // Need a cell
    outs_t *r = alloc_outs(q->k) ;
    r->next = p ;
    p = r ;
  }
  if (p->k == q->k) {
    p->c += q->c ;
    p->show = p->show || q->show ;
    p->down = do_merge_outs(p->down,q->down) ;
    p->next = do_merge_outs(p->next,q->next) ;
  } else {
    p->next = do_merge_outs(p->next,q) ;
  }
  return p ;
}

outs_t *merge_outs(outs_t *p, outs_t *q, int sz) {
  return do_merge_outs(p,q) ;
}

int same_outs(outs_t *p,outs_t *q) {
  while (p && q) {
    if (p->k != q->k || p->c != q->c || p->show != q->show) return 0 ;
    if (!same_outs(p->down,q->down)) return 0 ;
    p = p->next ;
    q = q->next ;
  }
  return p == q ; /* == NULL */
}
|ocaml}

(* ---------------- B4: GPU memory-stress layer (het_stress.cuh) ---------------

   Emitted verbatim into every het harness directory and #include'd by BOTH the
   .cu and the .hip render.  It is a SHARED C header (like outs.h above), not a
   per-dialect render, so the "one template, two renders" invariant of the OCaml
   driver template is untouched: dump_gpu_file still emits only test-specific
   code through gpu_dialect FIELDS, and every line of reused cuda-litmus code --
   with its mandatory attributions -- stays in this one auditable place, which is
   what the reuse licence condition (citation) actually needs.

   Its ONE dialect divergence (the scoped atomics behind het_spin) is a
   preprocessor selection, because CUDA and HIP genuinely spell device-scope
   atomics differently and there is no dialect-neutral spelling.

   See env-research/Q5-gpu-stress.md sections 2 (knob catalog), 3.1 (do_stress /
   scratchpad / StressParams), 3.3 (the device-scope spin window-opener) and 3.4
   (host->device seeded RNG). *)

let het_stress_cuh = {ocaml|/* =========================================================================
 * het_stress.cuh -- HetLitmus GPU memory-stress layer.   DO NOT EDIT.
 * Emitted by litmus7 (HetArch.het_stress_cuh); included by <test>.cu/.hip.
 * =========================================================================
 * PORTED, WITH THE ADAPTATIONS NOTED BELOW, FROM cuda-litmus (Reese Levine),
 *   https://github.com/reeselevine/cuda-litmus
 *   -- functions.cu (do_stress, spin, permute_id, stripe_workgroup),
 *      litmus.cuh   (StressParams/KernelParams, PRE_STRESS, MEM_STRESS),
 *      runner.cu    (parseStressParamsFile, setScratchLocations, percentageCheck).
 * The repository carries NO licence file (all-rights-reserved by default);
 * reuse is cleared for this thesis ON CONDITION OF CITATION.  Each mechanism
 * below therefore carries BOTH its code source (cuda-litmus) AND the paper that
 * defines it:
 *
 *   scratchpad; critical patch size P; access sequence sigma; spread m;
 *   occupancy-scaled stressing-thread count
 *     -- Sorensen & Donaldson, "Exposing Errors Related to Weak Memory in GPU
 *        Applications", PLDI'16, sections 1/3.  (Their headline: 0/1000 weak
 *        observations without stress, 102/1000 with it.)
 *   the named, enumerable stress-parameter space + autotuning + the
 *   reproducibility bound
 *     -- Kirkham, Sorensen, Tureci, Martonosi, "Foundations of Empirical Memory
 *        Consistency Testing", OOPSLA'20, section 3.1.
 *   the four "incantations" (memory stress, thread synchronisation, thread
 *   randomisation, occupancy) and the busy-wait DEADLOCK GUARD
 *     -- Alglave et al., "GPU Concurrency: Weak Behaviours and Programming
 *        Assumptions", ASPLOS'15, section 4.3.  Table 6 shows sb/lb weak counts
 *        of ZERO in every no-incantation column: this layer is the reason the
 *        HetLitmus campaign is not vacuous.
 *   the co-prime permutation / Parallel Test Environment (permute_id,
 *   stripe_workgroup)
 *     -- Levine et al., "MC Mutants", ASPLOS'23, section 4.1 ("(vP) mod N ...
 *        P co-prime to N").
 *   the seeded Park-Miller RNG (so a run is replayable from its seed)
 *     -- Levine et al., "GPUHarbor", ISSTA'23, section 3.4.
 *
 * -------------------------------------------------------------------------
 * TWO OBJECT CLASSES, TWO ALLOCATORS.  Do not confuse them:
 *
 *   * the shared litmus VARIABLES and the cross-device rendezvous BARRIER are
 *     the property under test.  They go through gd_alloc_shared (system malloc
 *     + ATS on GH200; fine-grained hipMallocManaged on MI300A) so both sides
 *     touch the same cache line in place over the real interconnect.
 *
 *   * the stress SCRATCHPAD below is GPU-only and DISJOINT from every test
 *     location.  It goes in plain DEVICE memory (cudaMalloc / hipMalloc): the
 *     CPU never touches it and it can never alias a test location.  That
 *     disjointness is exactly what makes the stress sound -- it raises the
 *     coherence traffic without changing the tested program's behaviour set
 *     (S&D: "a completely disjoint region of memory ... called a scratchpad").
 *
 * WHAT THIS LAYER DOES *NOT* DO.  The scratchpad hammers the GPU's ON-DIE
 * L1/L2 coherence.  It does not, by itself, widen the CPU-GPU (NVLink-C2C)
 * window -- that needs interconnect-crossing traffic (CPU-side stress + remote
 * page placement), which is a separate build.  Do not claim otherwise.
 *
 * -------------------------------------------------------------------------
 * FIXED ON THE WAY IN: the cuda-litmus MEM_STRESS pattern-argument bug.
 *
 *   do_stress(scratchpad, locations, iterations, PATTERN)     [functions.cu:19]
 *
 * but cuda-litmus's MEM_STRESS() [litmus.cuh:346] passes `pre_stress_iterations'
 * in the PATTERN slot, where PRE_STRESS() [litmus.cuh:338] correctly passes
 * `pre_stress_pattern'.  do_stress's body is if(p==0)...else if(p==3) with NO
 * else, and the committed tuned config sets preStressIterations=57.  57 matches
 * no branch, so mem-stress spins memStressIterations=445 times doing NOTHING,
 * and memStressPattern is never read.
 *
 * The sting: the tuned preStressPattern=3 is `ld;ld' (pure loads), and pattern 0
 * (`st;st') is the only scratchpad WRITER -- the dead one.  So in the shipped
 * configuration NOTHING ever writes the scratchpad: the whole stress layer is
 * READ-ONLY, reading a region that is never written.  Store traffic -- which
 * invalidates lines and forces ownership transfer, the strong coherence
 * stressor -- never happens.
 *
 * This does NOT invalidate cuda-litmus's published results (their pre-stress did
 * real work).  It means the knobs LABELLED "mem-stress" were not doing what
 * their names say.  HetLitmus passes the pattern correctly, so scratchpad store
 * traffic appears here for the first time.  CONSEQUENCE: cuda-litmus's committed
 * params/stress_params.txt is NOT a valid tuning seed for us, and re-tuning on
 * the target hardware is MANDATORY, not optional.
 * ========================================================================= */
#ifndef HET_STRESS_CUH
#define HET_STRESS_CUH

#include <stdint.h>

#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
#include <hip/hip_runtime.h>
#else
#include <cuda/atomic>
#endif

/* -------------------------------------------------------------------------
 * Stress knobs.  THESE VALUES ARE A SEED, NOT A TUNED CONFIGURATION.
 *
 * They are cuda-litmus's committed params/stress_params.txt, which is (a) a
 * DEVICE-scope, GPU-only, Hopper-class autotuner output, and (b) was tuned with
 * the MEM_STRESS pattern bug live -- so its mem-stress knobs were inert and its
 * scratchpad was never written.  HetLitmus tests SYSTEM scope across a CPU-GPU
 * interconnect.  Kirkham OOPSLA'20 section 6.4: "parameters for one chip may not
 * be optimal on another chip, even from the same vendor."
 *
 * Every value below is therefore a STARTING POINT that must be re-tuned on the
 * target hardware.  All are -D-overridable so an autotuner can sweep them
 * without re-emitting the harness.
 * ------------------------------------------------------------------------- */
#ifndef HET_SCRATCH_SIZE
#define HET_SCRATCH_SIZE 4608          /* scratchpad size, in uint32 words     */
#endif
#ifndef HET_STRESS_LINE_SIZE
#define HET_STRESS_LINE_SIZE 16        /* S&D "critical patch size" P          */
#endif
#ifndef HET_STRESS_TARGETS
#define HET_STRESS_TARGETS 9           /* S&D "spread" m: lines hammered at once */
#endif
#ifndef HET_STRESS_ASSIGN
#define HET_STRESS_ASSIGN 1            /* 0 = round-robin, 1 = chunking        */
#endif
#ifndef HET_MEM_STRESS_PCT
#define HET_MEM_STRESS_PCT 20          /* % of rounds a stress lane hammers    */
#endif
#ifndef HET_MEM_STRESS_ITER
#define HET_MEM_STRESS_ITER 445
#endif
#ifndef HET_MEM_STRESS_PATTERN
#define HET_MEM_STRESS_PATTERN 0       /* 0 = st;st -- the ONLY writer pattern,
                                          and the one cuda-litmus's bug made
                                          unreachable.  See the header comment. */
#endif
#ifndef HET_PRE_STRESS_PCT
#define HET_PRE_STRESS_PCT 65          /* % of iterations a TEST lane self-stresses */
#endif
#ifndef HET_PRE_STRESS_ITER
#define HET_PRE_STRESS_ITER 57
#endif
#ifndef HET_PRE_STRESS_PATTERN
#define HET_PRE_STRESS_PATTERN 3       /* 3 = ld;ld                            */
#endif
#ifndef HET_BARRIER_PCT
#define HET_BARRIER_PCT 68             /* % of iterations the GPU test lanes
                                          hit the device-scope window-opener   */
#endif
#ifndef HET_SEED
#define HET_SEED 1                     /* fixed => a run is replayable (GPUHarbor) */
#endif
#ifndef HET_STRESS_BLOCKS
#define HET_STRESS_BLOCKS (-1)         /* -1 = auto: fill the co-resident grid */
#endif
#ifndef HET_STRESS_MAX_ROUNDS
#define HET_STRESS_MAX_ROUNDS 1000000000u  /* safety net only: a stress lane must
                                          never outlive a hung test lane for
                                          ever.  NOT a tuning knob -- it is far
                                          above any reachable round count.     */
#endif

/* -------------------------------------------------------------------------
 * Seeded Park-Miller (Lehmer minimal-standard) RNG.       [GPUHarbor ISSTA'23]
 *
 * ADAPTATION (Q5 3.4): cuda-litmus re-rolls its probabilistic toggles ON THE
 * HOST and cudaMemcpy's a fresh KernelParams before every relaunch.  The
 * HetLitmus kernel is PERPETUAL -- launched once, looping inside -- so there is
 * no per-iteration host round-trip and the toggles must be decided device-side.
 * Seeding per (lane, run) from a fixed seed keeps a run replayable, which is
 * exactly why GPUHarbor uses this generator.
 * ------------------------------------------------------------------------- */
typedef struct { uint32_t s; } het_rng_t;

__device__ __host__ static inline het_rng_t het_rng_init(uint32_t seed, uint32_t lane) {
  het_rng_t r;
  uint32_t s = (seed ^ (lane * 2654435761u)) % 2147483647u;
  if (s == 0u) s = 1u;             /* Park-Miller degenerates at 0 */
  r.s = s;
  return r;
}
__device__ __host__ static inline uint32_t het_rng_next(het_rng_t* r) {
  r->s = (uint32_t)(((uint64_t)r->s * 16807ull) % 2147483647ull);
  return r->s;
}
/* cuda-litmus's percentageCheck (runner.cu:106), moved device-side. */
__device__ __host__ static inline int het_rng_pct(het_rng_t* r, int pct) {
  return (int)(het_rng_next(r) % 100u) < pct;
}

/* -------------------------------------------------------------------------
 * Scaffolding counters.
 *
 * DELIBERATELY compiler BUILTINS (atomicAdd), not libcu++/HIP scoped atomics:
 * these are bookkeeping on a device-only scratch word, NOT memory-model ops of
 * the test.  A builtin atomicAdd lowers to a bare `atom.global.add.u32' that
 * carries no memory-order qualifier and sits OUTSIDE the PTX inline-asm markers,
 * so it stays out of the op stream that the L0 faithfulness gate
 * (hetlitmus/verify/ptxcheck.py) checks -- which is correct, because it is not a
 * tested op.  Reading through an RMW (add 0) rather than a plain load keeps the
 * value device-coherent (it resolves in L2) with no L1-caching question.
 * ------------------------------------------------------------------------- */
__device__ static inline uint32_t het_scratch_read(uint32_t* p) {
  return atomicAdd(p, 0u);
}
__device__ static inline void het_scratch_bump(uint32_t* p) {
  (void)atomicAdd(p, 1u);
}

/* -------------------------------------------------------------------------
 * do_stress -- cuda-litmus functions.cu:19-50, ported VERBATIM (only the types
 * and the name are ours).  Each stressing thread repeats a 2-instruction access
 * sequence on its workgroup's scratch line:
 *
 *     pattern 0 = st;st     1 = st;ld     2 = ld;st     3 = ld;ld
 *
 * (Kirkham's 2-instruction AccessPattern A0;A1; S&D's fuller sigma = (ld|st)+ up
 * to length 5 is not implemented upstream and is not reproduced here.)
 *
 * Pattern 0 is the only pure WRITER.  Store traffic invalidates lines and forces
 * ownership transfer, which is the strong coherence stressor -- and it is
 * precisely what cuda-litmus's shipped configuration never emitted (header).
 * ------------------------------------------------------------------------- */
__device__ static void het_do_stress(uint32_t* scratchpad,
                                     uint32_t* scratch_locations,
                                     uint32_t iterations,
                                     uint32_t pattern) {
  for (uint32_t i = 0; i < iterations; i++) {
    if (pattern == 0) {
      scratchpad[scratch_locations[blockIdx.x]] = i;
      scratchpad[scratch_locations[blockIdx.x]] = i + 1;
    } else if (pattern == 1) {
      scratchpad[scratch_locations[blockIdx.x]] = i;
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
    } else if (pattern == 2) {
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
      scratchpad[scratch_locations[blockIdx.x]] = i;
    } else if (pattern == 3) {
      uint32_t tmp1 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp1 > 100) { break; }
      uint32_t tmp2 = scratchpad[scratch_locations[blockIdx.x]];
      if (tmp2 > 100) { break; }
    }
  }
}

/* -------------------------------------------------------------------------
 * het_spin -- the DEVICE-SCOPE window-opener.  cuda-litmus functions.cu:10-17
 * (`spin'), Alglave ASPLOS'15 section 4.3.4 (the thread-synchronisation
 * incantation: "synchronise ... by atomically incrementing a counter and
 * busy-waiting ... take care to avoid deadlock"), Kirkham's Barrier+timeout.
 *
 * It aligns the GPU TEST LANES of an instance so their critical accesses race.
 * It is NOT the cross-device rendezvous: that is the system-scope gd_bar in the
 * driver, which fires ONCE, outside the perpetual loop.  A per-iteration
 * CROSS-DEVICE barrier would mask the tested order and stall (Srivastava
 * section 4.1), so the two must stay separate -- different scope, different
 * variable, different lifetime.  This one is device-scope, on a scratch word
 * that is not a test location, so it adds no ordering edge to the test.
 *
 * DEADLOCK GUARD (Alglave, verbatim from upstream): the wait is capped at 1024
 * spins.  GPUs give no forward-progress guarantee across workgroups, so a lane
 * that waits unboundedly for a lane that is not scheduled hangs the kernel --
 * and a silent hang is indistinguishable from a genuine non-observation.
 *
 * ADAPTATION (perpetual loop): upstream relaunches the kernel per test
 * iteration, so its barrier counter is fresh each time and it waits for
 * `blockDim.x * testing_workgroups'.  Our kernel loops INSIDE, so a counter that
 * only ever grows would be satisfied from iteration 1 onward and the barrier
 * would silently stop barriering.  The caller therefore passes an
 * ITERATION-INDEXED limit ((_n+1) * lanes): each of `lanes' lanes contributes
 * exactly one increment per iteration, so the counter reaches (_n+1)*lanes only
 * once every lane has entered iteration _n.  Monotonic counter, advancing
 * target -- lanes that run ahead wait, lanes that fall behind pass straight
 * through, and the 1024 cap still bounds the wait.
 * ------------------------------------------------------------------------- */
__device__ static void het_spin(uint32_t* barrier, uint32_t limit) {
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
  uint32_t val = __hip_atomic_fetch_add(barrier, 1u, __ATOMIC_RELAXED,
                                        __HIP_MEMORY_SCOPE_AGENT);
  int i = 0;
  while (i < 1024 && val < limit) {
    val = __hip_atomic_load(barrier, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT);
    i++;
  }
#else
  cuda::atomic_ref<uint32_t, cuda::thread_scope_device> _b(*barrier);
  uint32_t val = _b.fetch_add(1u, cuda::memory_order_relaxed);
  int i = 0;
  while (i < 1024 && val < limit) {
    val = _b.load(cuda::memory_order_relaxed);
    i++;
  }
#endif
}

/* -------------------------------------------------------------------------
 * The co-prime Parallel-Test-Environment primitives -- MC Mutants ASPLOS'23
 * section 4.1, cuda-litmus functions.cu:2-8.  (v*P) mod N with P co-prime to N
 * is a bijection, so it assigns each thread a partner / a location slot without
 * collisions while avoiding the ineffective n -> n+1 pattern.
 *
 * PORTED BUT NOT YET WIRED.  They belong to the GPU-only REPLICA population
 * (many independent instances of a gpu-only test per launch).  HetLitmus's
 * cross-device instance count is capped by CPU cores, not GPU threads, so the
 * het pair does not use them; they are here for the gpu-only companion
 * population, and left unreferenced deliberately.
 * ------------------------------------------------------------------------- */
[[maybe_unused]] __device__ static uint32_t het_permute_id(uint32_t id, uint32_t factor, uint32_t mask) {
  return (id * factor) % mask;
}
[[maybe_unused]] __device__ static uint32_t het_stripe_workgroup(uint32_t workgroup_id, uint32_t testing_workgroups) {
  return (workgroup_id + 1) % testing_workgroups;
}

/* -------------------------------------------------------------------------
 * het_set_scratch_locations -- cuda-litmus runner.cu:132-157
 * (`setScratchLocations'), HOST side.  Picks HET_STRESS_TARGETS distinct stress
 * lines at random out of (HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE) regions, one
 * random word within each, then maps workgroups onto those lines:
 *
 *   strategy 0 (round-robin): consecutive workgroups -> separate lines
 *   strategy 1 (chunking):    a run of consecutive workgroups -> the same line
 *
 * Distinct lines keep each stresser on a fresh cache line (S&D's critical patch);
 * the spread controls how many lines are contended at once.
 *
 * ADAPTATION: upstream dedups regions with std::set; with HET_STRESS_TARGETS <= 16
 * a linear scan over the chosen regions is the same algorithm without the
 * dependency.  Driven by rand(), which the driver seeds per run, so the layout
 * is replayable.
 * ------------------------------------------------------------------------- */
#if HET_STRESS_TARGETS < 1
#error "HET_STRESS_TARGETS must be >= 1 (it is S&D's spread m)"
#endif
__host__ static void het_set_scratch_locations(uint32_t* locations, int num_workgroups) {
  int num_regions = HET_SCRATCH_SIZE / HET_STRESS_LINE_SIZE;
  int used[HET_STRESS_TARGETS];
  int n_used = 0;
  /* Every entry must be a VALID index: a stress lane indexes the scratchpad by
     scratchpad[locations[blockIdx.x]], so an unwritten entry would be an
     out-of-bounds device write.  Zero first, then fill (both strategies below do
     cover [0,num_workgroups), but this makes that a property of the code rather
     than of an argument about it). */
  for (int j = 0; j < num_workgroups; j++) { locations[j] = 0u; }
  for (int i = 0; i < HET_STRESS_TARGETS; i++) {
    int region, dup;
    /* Upstream retries until it draws an unused region; with more targets than
       regions that never terminates.  Stop instead -- the targets we already
       have are still a valid (smaller) spread. */
    if (n_used >= num_regions) { break; }
    do {
      region = rand() % num_regions;
      dup = 0;
      for (int u = 0; u < n_used; u++) { if (used[u] == region) { dup = 1; break; } }
    } while (dup);
    used[n_used++] = region;
    int loc_in_region = rand() % HET_STRESS_LINE_SIZE;
    uint32_t target = (uint32_t)(region * HET_STRESS_LINE_SIZE + loc_in_region);
#if HET_STRESS_ASSIGN == 0
    for (int j = i; j < num_workgroups; j += HET_STRESS_TARGETS) {
      locations[j] = target;
    }
#else
    {
      int per = num_workgroups / HET_STRESS_TARGETS;
      for (int j = 0; j < per; j++) { locations[i * per + j] = target; }
      if (i == HET_STRESS_TARGETS - 1 && num_workgroups % HET_STRESS_TARGETS != 0) {
        for (int j = 0; j < num_workgroups % HET_STRESS_TARGETS; j++) {
          locations[num_workgroups - j - 1] = target;
        }
      }
    }
#endif
  }
}

#endif /* HET_STRESS_CUH */
|ocaml}
