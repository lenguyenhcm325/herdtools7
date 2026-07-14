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
 *        Applications", PLDI'16, sections 1/3.  (Their headline: "no erroneous
 *        behaviour is observed when conducting 1000 executions ... on a Tesla
 *        K20" -> "errors ... appear in 102 out of 1000 executions" once stressed,
 *        p.101.  Nvidia silicon -- see the VENDOR SPLIT below.)
 *   the named, enumerable stress-parameter space + autotuning + the
 *   reproducibility bound
 *     -- Kirkham, Sorensen, Tureci, Martonosi, "Foundations of Empirical Memory
 *        Consistency Testing", OOPSLA'20, section 3.1.
 *   the four "incantations" (memory stress, thread synchronisation, thread
 *   randomisation, occupancy) and the busy-wait DEADLOCK GUARD
 *     -- Alglave et al., "GPU Concurrency: Weak Behaviours and Programming
 *        Assumptions", ASPLOS'15, section 4.3.
 *
 * VENDOR SPLIT -- why this layer exists, stated honestly, because this header is
 * included by the .hip (AMD MI300A) render as well as the .cu (Nvidia GH200) one:
 *
 *   * NVIDIA (GTX Titan, and by lineage our GH200 target): the stress layer is
 *     the difference between observing something and observing nothing.
 *     "we did not observe sb and lb on Titan without this incantation"
 *     (Alglave 4.3.1, p.585).  Table 6 (p.584): sb and lb are 0 in EVERY column
 *     without memory stress (cols 1-8), and become non-zero only once it is
 *     enabled (cols 9-16).  Without stress the campaign is vacuous.
 *
 *   * AMD (Radeon HD 7970, the MI300A render's ancestor): NOT so, and the
 *     unqualified claim would be false.  "For AMD HD7970 we did not need memory
 *     stress to observe weak behaviour, although we observe mp consistently more
 *     when this incantation is enabled" (Alglave 4.3.1, p.585).  Table 6:
 *     lb is 10959/100k in column 1 -- no incantations at all -- while sb stays
 *     ~0 in every column.
 *
 *   * The paper's own summary (4.3, p.585): "The setup of Sec. 4.2 only witnessed
 *     weak behaviours in combination with incantations ON NVIDIA CHIPS; these
 *     incantations also influenced the incidence of weak behaviours on AMD chips."
 *
 *   So: on Nvidia this layer is load-bearing for observing anything; on AMD it is
 *   a rate and coverage amplifier, not an on/off switch.  Do not repeat the
 *   unqualified "zero without stress" line -- it is a Nvidia result.
 *
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
 * DIVERGENCES FROM UPSTREAM.  Three, all deliberate.  We cite Levine, so a
 * reviewer must be able to tell which lines are theirs and which are not.
 *
 * (1) UPSTREAM BUG, FIXED: the MEM_STRESS pattern-argument slot.
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
 *
 * (2) UPSTREAM BUG, DIVERGED: setScratchLocations' region dedup is DEAD CODE.
 *     Upstream declares `std::set<int> usedRegions' [runner.cu:131] and queries
 *     it -- `while (usedRegions.count(region)) region = rand() % numRegions;'
 *     [runner.cu:135] -- but NEVER INSERTS INTO IT (`grep -n "\.insert"
 *     runner.cu' finds nothing).  count() is therefore always 0: the loop never
 *     spins, upstream never dedups, and the SAME region can be drawn for several
 *     of its stressTargetLines.  Its realised spread is <= m, not m.
 *     het_set_scratch_locations below implements the dedup upstream INTENDED
 *     (a linear scan; no std::set dependency), so HetLitmus really does hammer m
 *     DISTINCT stress lines -- closer to S&D's "spread" than upstream is.  This
 *     is a behavioural divergence, not a faithful port: their tuned m and ours
 *     do not mean the same thing, which is a second reason re-tuning is
 *     mandatory.
 *
 * (3) OUR OWN BUG, FIXED (B4-fix): the ACCESS PATTERN MUST BE A RUNTIME VALUE.
 *     The first port passed the pattern as a compile-time -D constant.  nvcc then
 *     constant-folds do_stress's if(p==0)...else if(p==3) chain down to the one
 *     live branch -- and the tuned default, pattern 3, is `ld;ld' whose loaded
 *     values only feed a `break'.  That is provably side-effect-free, so nvcc
 *     DELETED THE WHOLE LOOP: measured on the emitted PTX (sm_90), the test lane
 *     carried 0 scratchpad ops, and -DHET_MEM_STRESS_PATTERN=3 emptied the entire
 *     kernel (0 ops).  The stress layer compiled, satisfied every gate, and did
 *     nothing.  Upstream is immune by accident of design: its pattern arrives
 *     through kernel_params (a runtime pointer), so the storing branches always
 *     survive.
 *     FIX: the patterns are passed to the kernel as ARGUMENTS (_pre_pat/_mem_pat
 *     in top_litmus.ml), sourced from the -D knobs HOST-side.  The knobs keep
 *     working; the device code cannot fold them.  DO NOT "simplify" them back
 *     into #defines here -- hetlitmus/verify/stresscheck.py fails the build if
 *     anyone does (it asserts the PTX scratchpad-op count is INVARIANT under
 *     -DHET_*_PATTERN, which is exactly the property a compile-time pattern
 *     destroys).
 * ========================================================================= */
#ifndef HET_STRESS_CUH
#define HET_STRESS_CUH

#include <stdint.h>
#include <stdio.h>      /* het_report_spread: a degraded stress layer must SAY so */

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

/* het_do_stress's if-chain has NO else, so a pattern outside 0..3 makes the
   stress loop spin doing NOTHING -- silently.  That is exactly how upstream's
   MEM_STRESS bug hid (it passed 57).  A silent no-op stress layer is a silent
   falsification of every non-observation, so refuse to compile instead.
   (B8 note: if you ever source a pattern from a config file at RUN time rather
   than from these -D knobs, re-validate it there -- this guard cannot see it.) */
#if (HET_PRE_STRESS_PATTERN) < 0 || (HET_PRE_STRESS_PATTERN) > 3
#error "HET_PRE_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_MEM_STRESS_PATTERN) < 0 || (HET_MEM_STRESS_PATTERN) > 3
#error "HET_MEM_STRESS_PATTERN must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
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
                                          ever.  NOT a tuning knob.            */
#endif

/* -------------------------------------------------------------------------
 * LIVENESS TALLY (B4-fix).  Three device counters the host reads back and
 * prints, because every mechanism in this file is INVISIBLE to the L0
 * faithfulness gate by design (stress is scaffolding, not a tested op) -- and a
 * scaffolding layer that silently stops scaffolding produces a clean-looking
 * "Never" that is worth nothing.  Two of the three exist because that is
 * precisely what happened here (see divergence (3) above).
 *
 *   RDV   / CAP : how each het_spin ended.  The window-opener is meant to
 *                 RENDEZVOUS the GPU test lanes; the 1024-spin deadlock cap is
 *                 only a safety net (Alglave 4.3.4).  A spin that mostly exits
 *                 on the CAP is not a window-opener, it is a fixed-length delay
 *                 loop -- and only a runtime counter can tell the two apart.
 *                 This ratio is also the datum the tuning task (B8) tunes
 *                 HET_BARRIER_PCT against.
 *   TRUNC       : stress lanes that hit HET_STRESS_MAX_ROUNDS, i.e. STOPPED
 *                 STRESSING while tested lanes were still running.  Its result
 *                 is not comparable with a fully stressed one, so it must never
 *                 be silent.
 *   NOISE /     : B5, the Hopper half of the Fusco C2C noise pair.  NOISE counts
 *   NOISE_ROUNDS  the noise BLOCKS that completed at least one streaming round
 *                 (bounded by the grid, so it cannot overflow); NOISE_ROUNDS is
 *                 the MAX rounds any one block completed (atomicMax, likewise
 *                 overflow-safe -- a summed uint32 round count would wrap on a
 *                 long run and a wrapped-to-zero tally reads exactly like a dead
 *                 mechanism, which is the failure this whole tally exists to
 *                 prevent).  Zero NOISE with the noise enabled = the interconnect
 *                 stressor is not running, and the run is not C2C-stressed.
 * ------------------------------------------------------------------------- */
#define HET_TALLY_RDV          0
#define HET_TALLY_CAP          1
#define HET_TALLY_TRUNC        2
#define HET_TALLY_NOISE        3
#define HET_TALLY_NOISE_ROUNDS 4
#define HET_TALLY_N            5

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
/* B5: a saturating-by-construction volume counter.  atomicMax, not atomicAdd:
   a SUMMED uint32 round count wraps on a long streaming run, and a tally that
   wrapped to zero is indistinguishable from a mechanism that never ran. */
__device__ static inline void het_scratch_max(uint32_t* p, uint32_t v) {
  (void)atomicMax(p, v);
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
 *
 * CALLER CONTRACT (load-bearing -- header divergence (3)): `pattern' MUST reach
 * this function as a RUNTIME value (a kernel argument).  Hand it a compile-time
 * constant and nvcc folds the if-chain to one branch; if that branch is 3
 * (`ld;ld', the tuned default) the body becomes provably side-effect-free and
 * THE ENTIRE LOOP IS DELETED.  The accesses below are deliberately plain and
 * non-volatile -- exactly upstream's -- so that the stress traffic is ordinary
 * cacheable traffic that thrashes the testing thread's own L1 (Kirkham 3.1's
 * whole point) and adds no ordering edge to the test.  Keeping them plain is
 * what makes the runtime pattern load-bearing rather than a style choice.
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
 * `blockDim.x * testing_workgroups' -- Alglave 4.3.4: "busy-waiting until the
 * counter reaches THE NUMBER OF THREADS PARTICIPATING IN THE TEST".  Our kernel
 * loops INSIDE, so a counter that only ever grows would be satisfied from
 * iteration 1 onward and the barrier would silently stop barriering.  The caller
 * therefore passes a limit indexed by the number of barriers TAKEN SO FAR
 * (_nb * lanes), and takes them ALL-OR-NONE: the caller's roll is drawn from a
 * LANE-INDEPENDENT stream (seeded by the iteration, not by the lane), so every
 * lane takes the same barriers, contributes exactly one increment to each, and
 * the counter reaches _nb*lanes EXACTLY when the last lane arrives.  Monotonic
 * counter, exactly-attainable target.
 *
 * B4-fix -- WHY THAT SENTENCE IS THE WHOLE MECHANISM.  The first version rolled
 * the toggle from the LANE'S OWN stream and indexed the limit by the ITERATION
 * ((_n+1)*lanes).  A lane then incremented on only ~68% of iterations while the
 * limit rose by `lanes' every iteration, so the counter fell permanently behind:
 * after the first skipped roll the limit was UNREACHABLE FOREVER, every spin ran
 * out the full 1024-iteration deadlock cap, and the "window-opener" was a
 * fixed-length delay loop that aligned nothing (simulated over the emitted
 * protocol: 99% of spins cap-released, final counter deficit 625; with the fix,
 * 100% rendezvous-released, deficit 0).  Upstream never hit this because its
 * toggle is ONE host-set boolean, uniform across the launch [litmus.cuh:340] --
 * all testing threads spin, or none do.  The uniformity is the invariant; the
 * per-lane draw broke it.  KEEP THE DRAW LANE-INDEPENDENT.
 *
 * DEADLOCK GUARD + LIVENESS TALLY: the wait is capped at 1024 spins (Alglave,
 * verbatim from upstream) -- GPUs give no forward-progress guarantee across
 * workgroups, and a silent hang is indistinguishable from a genuine
 * non-observation.  But a cap that fires is a barrier that did NOT rendezvous,
 * so each exit is tallied by its reason and the host prints the ratio: that is
 * the only way this mechanism can be seen to be alive (the L0 gate cannot see
 * it, and did not).
 * ------------------------------------------------------------------------- */
__device__ static void het_spin(uint32_t* barrier, uint32_t limit,
                                uint32_t* tally) {
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
  /* Released by the rendezvous, or by the deadlock cap?  (val >= limit) is the
     loop's success exit; anything else means i hit 1024 with the counter still
     short.  A builtin atomicAdd on a device-only word: scaffolding, invisible to
     the model-op stream, which is why ptxcheck's stray-sys check exists. */
  het_scratch_bump(&tally[(val >= limit) ? HET_TALLY_RDV : HET_TALLY_CAP]);
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
 * DIVERGENCE (header (2)) -- WE DEDUP, UPSTREAM ONLY LOOKS LIKE IT DOES.  Upstream
 * declares `std::set<int> usedRegions' [runner.cu:131] and guards its draw with
 * `while (usedRegions.count(region)) region = rand() % numRegions;' [runner.cu:135]
 * -- but it never inserts into the set (`grep -n "\.insert" runner.cu' finds
 * nothing), so count() is always 0, the guard never spins, and two of its
 * stressTargetLines can land on the SAME region.  Upstream's realised spread is
 * therefore <= m, not m.
 *
 * The linear scan below is the dedup upstream INTENDED, and it is real: the m
 * lines are distinct, which is what S&D's "spread" means.  Consequences to keep
 * in mind: (a) upstream's tuned m is not our m -- another reason re-tuning is
 * mandatory; (b) OUR loop would spin forever if it ever ran out of regions
 * (m > num_regions), which upstream's dead code could not -- hence the explicit
 * break below.  Driven by rand(), which the driver seeds per run, so the layout
 * is replayable.
 * ------------------------------------------------------------------------- */
#if HET_STRESS_TARGETS < 1
#error "HET_STRESS_TARGETS must be >= 1 (it is S&D's spread m)"
#endif
/* The REALISED spread can be smaller than the knob, silently.  Chunking divides
   num_workgroups by HET_STRESS_TARGETS, so a grid SMALLER than the target count
   gives workgroupsPerLocation = 0 and the tail case then dumps EVERY workgroup on
   the LAST line -- realised spread 1, while the knob still says m (verified on
   device: 6 workgroups, m=9 -> all 6 on one line; 64 workgroups, m=9 -> 9 distinct
   lines, as intended).  Round-robin degrades more gently but still leaves targets
   unused.  Either way the stress is weaker than the configuration claims, and B8
   sweeps exactly these knobs (HET_STRESS_BLOCKS x HET_STRESS_TARGETS), so it must
   never score a spread-1 config as if it were spread-m.  Count what was actually
   assigned and say so. */
__host__ static void het_report_spread(const uint32_t* locations, int num_workgroups) {
  int distinct = 0;
  for (int i = 0; i < num_workgroups; i++) {
    int seen = 0;
    for (int j = 0; j < i; j++) { if (locations[j] == locations[i]) { seen = 1; break; } }
    if (!seen) distinct++;
  }
  if (distinct < HET_STRESS_TARGETS) {
    fprintf(stderr,
            "HetLitmus WARNING: realised stress spread is %d line(s), not "
            "HET_STRESS_TARGETS=%d -- %d stressing workgroup(s) cannot cover %d "
            "lines (S&D's spread m).  The stress is weaker than the configuration "
            "says; raise the grid or lower HET_STRESS_TARGETS.\n",
            distinct, (int)HET_STRESS_TARGETS, num_workgroups,
            (int)HET_STRESS_TARGETS);
  }
}
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
    /* Our dedup is REAL (upstream's is dead code, see above), so it can exhaust
       the region pool and spin forever.  Stop instead -- the targets we already
       have are still a valid, smaller spread. */
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
  het_report_spread(locations, num_workgroups);
}

#endif /* HET_STRESS_CUH */
|ocaml}

(* ------------- B5: CPU-side + interconnect stress (het_cpu_stress.h) ---------

   The sibling of het_stress_cuh above, and it exists for a reason that is worth
   stating once, at the top: B4's GPU scratchpad stress widens the INTRA-DEVICE
   window.  The heterogeneous weak behaviour does not live there.  It lives in
   the CROSS-DEVICE window -- a store in flight across NVLink-C2C but not yet
   globally visible -- and nothing in the harness loaded that path deliberately
   until this file.  Q6 (env-research/Q6-cpu-interconnect-stress.md) is the spec.

   WHY IT IS A SEPARATE HEADER FROM het_stress.cuh, AND NOT PART OF THE .cu.
   This is not tidiness; it is forced, and getting it wrong breaks a gate:

     * the emitted CPU thread wrapper (cpu_thread_P<n>) and the driver main()
       both live in the .cu -- i.e. in the NVCC translation unit.  The M3 preload
       primitives are HOST-ISA inline asm (dc civac / prfm on AArch64, clflush /
       prefetcht0 on x86_64).  Put them in the .cu and nvcc must swallow AArch64
       asm on an x86 build host.  So the asm lives HERE, in a header that only
       <test>_cpu.c (the gcc / clang --target=aarch64-linux-gnu TU) compiles,
       behind HET_CPU_STRESS_IMPL; the .cu sees the declarations and the argument
       structs, and NOT ONE LINE of host ISA.

     * NO <pthread.h> IN THIS FILE.  VERIFIED, not assumed: <sched.h>, <stdio.h>,
       <stdlib.h>, <string.h> and <unistd.h> all survive
       `clang --target=aarch64-linux-gnu -c', but <pthread.h> does NOT -- it
       reaches x86 glibc's bits/pthreadtypes-arch.h, whose __cleanup_fct_attribute
       is __attribute__((__regparm__(1))), and regparm "is not valid on this
       platform" for AArch64.  That cross-assembly step is comp.sh's, and
       hetlitmus/verify/smoke.sh gates on it, so a stray #include <pthread.h> here
       fails the smoke gate on every het test in the corpus.  The thread bodies
       below need only the pthread entry-point signature (a void-pointer function
       of one void pointer), never a pthread primitive; pthread_create is called
       from the .cu, which is compiled for the native host and already includes
       <pthread.h>.  Keep it that way.

   THE -2s INVARIANTS (Q6 2.4).  For a two-sided test the CPU issues the ordering
   instructions UNDER TEST (STLR / LDAPR / DMB.SY).  They are the hypothesis.  So
   the stress layer holds two invariants, and both hold BY CONSTRUCTION here:

     (i)  enemy and noise traffic touches ONLY a disjoint scratchpad / noise
          buffer -- never X, Y or the barrier.  An enemy that WRITES a test
          variable injects co/rf edges and the run stops being a test of the
          CPU-GPU order.  S&D PLDI'16, verbatim: "Because the stressing threads
          and memory are disjoint from application threads and data, the set of
          possible behaviours a program can exhibit remains the same."
     (ii) nothing is ever injected INSIDE het_run_P<n>.  A fence or atomic
          between the two tested accesses adds ordering the test does not have.
          The tested order is an opaque compiled unit in <test>_cpu.c; the
          emitter only injects AROUND it (preload before the call, enemies beside
          it).  A cache HINT changes residency, not program order, so preloading
          the test variables before the body is -2s-safe.

   See also: hetlitmus/docs/00-environment-design.md 3.6. *)

let het_cpu_stress_h = {ocaml|/* =========================================================================
 * het_cpu_stress.h -- HetLitmus CPU-side + interconnect (C2C) stress.  DO NOT EDIT.
 * Emitted by litmus7 (HetArch.het_cpu_stress_h); #include'd by <test>_cpu.c (with
 * HET_CPU_STRESS_IMPL, which compiles the bodies) and by <test>.cu / .hip (which
 * get only the knobs, the argument structs and the declarations).
 * =========================================================================
 * WHAT THIS LAYER IS FOR, AND WHY B4 WAS NOT ENOUGH
 *
 * het_stress.cuh hammers the GPU's own L1/L2 with a device-only scratchpad.  That
 * widens the INTRA-device window.  The heterogeneous weak behaviour does not live
 * there: it lives in the CROSS-device window -- the interval in which a store is
 * in flight across the CPU-GPU interconnect but not yet globally visible.  Per-
 * device stress on either side never loads that path.  This file adds the two
 * levers that do:
 *
 *   HALF 1 -- CPU-side stress.  The litmus7 "incantation" vocabulary, ported as
 *             RECIPES (never via Skel.ml): preload (M3), disjoint-scratchpad enemy
 *             threads (M1 in S&D's form), indirect access (M2), stride/spread (M4),
 *             affinity (M6).
 *   HALF 2 -- INTERCONNECT stress.  (a) placement: pin the shared pages remote to
 *             their consumer so the tested accesses cross C2C (this half lives in
 *             the .cu, next to gd_alloc_shared -- it is CUDA API, not host asm).
 *             (b) noise: each processing unit continuously stream-reads the OTHER
 *             one's memory, over a working set far larger than any cache.
 *
 * Half 2 is the thesis's methodological addition beyond Bagchi et al. (ISMM'26),
 * who stressed each device independently -- "Each was executed millions of times
 * with memory stressing [21] on both devices" (4.2) -- with NO link-directed
 * component anywhere in the paper (no placement, no cudaMemAdvise, no C2C noise).
 * Their interconnect is loaded only implicitly, by the test's own coherence race.
 *
 * -------------------------------------------------------------------------
 * HONESTY ABOUT WHAT HALF 2 BUYS.  This is an INFERENCE, not a measurement, and
 * it must be written that way in the thesis too.
 *
 *   * Fusco et al. measured BANDWIDTH degradation under noise (below).  Nobody
 *     has ever measured whether C2C saturation raises heterogeneous litmus YIELD.
 *   * It is also CONFOUNDED: remote placement and noise slow the whole loop, so
 *     there are fewer CPU/GPU rendezvous per second.  Sightings = yield x rate,
 *     and the net sign of that product is genuinely unknown.
 *
 * The defensible claim is therefore: interconnect stress is ADDITIVE AND
 * COMPOSABLE with per-device stress, and it is the lever most SPECIFIC to the
 * cross-device window.  It is NOT "more effective than per-device stress".  Do
 * not upgrade that sentence without hardware evidence.
 *
 * -------------------------------------------------------------------------
 * SOURCES.  Cited because we reuse them, and (for cuda-litmus, which carries no
 * licence file) because citation is the condition of reuse.
 *
 *   Alglave, Maranget, Sarkar, Sewell.  "Litmus: Running Tests against Hardware."
 *   TACAS'11, section 3 -- the CPU incantation vocabulary this half ports:
 *     NEXE     "To benefit from parallelism and stress the memory subsystem, given
 *               a test consisting of t threads P0,...,Pt-1, we run n = max(1, a/t)
 *               identical test instances concurrently on a machine with a cores."
 *     indirect "In direct mode the array cell is accessed directly as x[i]; hence
 *               cells are accessed sequentially and false sharing effects are
 *               likely.  In indirect mode (the default) the array cell is accessed
 *               by a shuffled array of pointers, giving a much greater variability
 *               of outcomes."
 *     preload  "If the (default) preload mode is enabled, a preliminary loop of
 *               size s reads a random subset of the memory locations accessed by
 *               Pk, also leading to a greater outcome variability."
 *   Its cache primitives are litmus7's own (litmus/libdir/_aarch64/_cache.h and
 *   _x86_64/_cache.h, CeCILL-B, reused verbatim below).
 *
 *   Sorensen & Donaldson.  "Exposing Errors Related to Weak Memory in GPU
 *   Applications."  PLDI'16 -- the disjoint-scratchpad invariant that makes ALL of
 *   this sound, and the named knobs (patch P, sequence sigma, spread m, distance):
 *     "The key part of our testing environment is a memory stressing strategy that
 *      targets a completely disjoint region of memory from the application data
 *      (called a scratchpad) using extra GPU threads disjoint from the threads that
 *      execute the application... Because the stressing threads and memory are
 *      disjoint from application threads and data, the set of possible behaviours a
 *      program can exhibit remains the same."
 *
 *   Alglave et al.  "GPU Concurrency: Weak Behaviours and Programming Assumptions."
 *   ASPLOS'15, section 4.3.1 -- the window-widening rationale this whole layer
 *   rests on, verbatim:
 *     "Stressing caching protocols might trigger weak behaviours.  For example, a
 *      bus may be more likely to transfer data out of order when it is under heavy
 *      stress than when it is only servicing a few requests."
 *   VENDOR SPLIT (see het_stress.cuh at length): "we did not observe sb and lb on
 *   Titan without this incantation", but "For AMD HD7970 we did not need memory
 *   stress to observe weak behaviour, although we observe mp consistently more when
 *   this incantation is enabled."  On Nvidia the stress layer is the difference
 *   between observing something and observing nothing; on AMD it amplifies a rate.
 *
 *   Fusco, Khalilov, Chrapek, Chukkapalli, Schulthess, Hoefler.  "Understanding
 *   Data Movement in Tightly Coupled Heterogeneous Systems: A Case Study with the
 *   Grace Hopper Superchip."  arXiv:2408.11556 -- the noise-kernel construction,
 *   verbatim:
 *     "we develop a Grace and a Hopper noise kernel that continuously reads from a
 *      large buffer of 8 GB.  To stress the C2C interconnect, the Grace noise kernel
 *      reads HBM system allocated memory and the Hopper noise kernel reads DDR
 *      allocated memory.  We start the noise kernel for one PU and run the read and
 *      write tests for the other PU."
 *   Effect: "Writes to HBM are the most impacted, with a Grace bandwidth of 17% and
 *   a Hopper bandwidth of 65% of the theoretical maximum."
 *   And the caveat that makes the WORKING SET load-bearing rather than decorative:
 *     "Hopper L2 cache can cache data that is physically allocated on HBM, both
 *      local and peer.  L2 resident peer HBM accesses are faster than local DDR
 *      accesses."
 *   -- i.e. a remote-pinned line that stays L2-resident crosses NOTHING.  Placement
 *   alone does not guarantee C2C traffic.  That is precisely why the noise exists,
 *   and why its buffer must exceed the last-level cache (see HET_NOISE_MB).
 *
 *   MI300A analogue (the AMD render): there is NO placement lever -- one HBM pool,
 *   no LPDDR/HBM split, no cudaMemAdvise equivalent.  The analogue is cross-chiplet
 *   coherence CONTENTION: co-hammer a shared fine-grained-coherent region whose
 *   working set defeats L2/Infinity-Cache residency.  Grounded in arXiv:2508.12743
 *   (co-running CPU+GPU atomics drops CPU throughput to 11-25%) and Schieffer et
 *   al., arXiv:2410.00801 ("each access to data located in remote coherent memory
 *   generates traffic over the CPU-GPU interconnect... on more recent systems, such
 *   as AMD MI300A, the no-caching restriction can be lifted").  Since caching is
 *   allowed on MI300A, per-access fabric traffic is NOT automatic and contention is
 *   what keeps the lines bouncing -- which is exactly what the noise pair below
 *   does when both sides stream the same coherent pool.  So the SAME noise code is
 *   the GH200 lever (by placement) and the MI300A lever (by contention); only the
 *   placement half is Nvidia-only.
 *
 * -------------------------------------------------------------------------
 * DIVERGENCES / DELIBERATE CHOICES.  Stated because a reviewer must be able to
 * tell what is ported from what is ours.
 *
 * (1) THE ACCESS SEQUENCE IS A RUNTIME VALUE, NOT A -D CONSTANT.  This is B4's
 *     scar tissue.  The GPU port first passed the access pattern as a compile-time
 *     -D; nvcc folded do_stress's if-chain to the one live branch, that branch
 *     (ld;ld) was provably side-effect-free, and THE ENTIRE STRESS LOOP WAS
 *     DELETED -- while every gate stayed green.  The CPU enemy has the identical
 *     shape (a sigma selector over an if/switch chain), so it gets the identical
 *     defence: `seq' arrives in het_cpu_enemy_args as a RUNTIME field, sourced
 *     from the -D knob host-side in main().  It is ALSO belt-and-braces here,
 *     because the enemy's accesses are `volatile' and so cannot be elided at all
 *     -- but the invariant that a knob cannot silently switch a stressor off is
 *     worth more than the one it costs, and hetlitmus/verify/cpustresscheck.py
 *     gates on it (the compiled op count must be INVARIANT under
 *     -DHET_CPU_ENEMY_SEQ).  Do not "simplify" it back into a #define.
 *
 * (2) M1 IS PORTED AS S&D-STYLE ENEMY THREADS, NOT AS litmus7's NEXE.  NEXE runs
 *     n = max(1, a/t) copies of the WHOLE TEST concurrently.  That does not
 *     compose with a persistent GPU kernel (the het instance count is capped by
 *     CPU cores, not by test replicas), so what is ported is the IDEA -- concurrent
 *     memory-subsystem contention -- in the disjoint-scratchpad form, which is
 *     automatically -2s-safe.  Q6 2.1 M1.
 *
 * (3) M5 (launch randomisation), M7 (per-cell barrier) and M8 (timebase release)
 *     are NOT ported.  M7 as a CPU<->GPU per-trial barrier is anti-correct: it
 *     masks the tested order and stalls (Srivastava 4.1).  M8 needs one shared
 *     counter, and Grace's cntvct_el0 and Hopper's %globaltimer have different
 *     epochs -- there is no shared clock to release on.  Q6 2.3.
 *
 * (4) EVERY numeric below is a SEED, not a tuning.  Alglave TACAS'11 4: stress is
 *     per-testbed.  Kirkham OOPSLA'20 6.4: "parameters for one chip may not be
 *     optimal on another chip, even from the same vendor."  Re-tune on GH200 and
 *     again on MI300A -- they do not even share the interconnect lever.  All knobs
 *     are -D-overridable so B8 can sweep them without re-emitting the harness, and
 *     main() prints the REALISED value of each (a knob that says 9 while the
 *     hardware realised 1 silently mis-tunes the autotuner -- het_report_spread in
 *     het_stress.cuh learned that the hard way).
 * ========================================================================= */
#ifndef HET_CPU_STRESS_H
#define HET_CPU_STRESS_H

/* NO <pthread.h> -- it does not survive `clang --target=aarch64-linux-gnu -c'
   (x86 glibc's __cleanup_fct_attribute is __attribute__((__regparm__(1))), which
   is invalid on AArch64), and that cross-assembly is a gated build step.  The
   thread bodies below need only the void*(void*) signature; pthread_create is
   called from the .cu, which is built for the native host.  These four DO cross-
   compile cleanly (verified). */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * HALF 1 KNOBS -- CPU-side stress.  Seeds, not a tuning (divergence (4)).
 * ------------------------------------------------------------------------- */
#ifndef HET_CPU_ENEMIES
#define HET_CPU_ENEMIES (-1)      /* -1 = auto: every spare core (see main())    */
#endif
#ifndef HET_CPU_SCRATCH_WORDS
#define HET_CPU_SCRATCH_WORDS 262144   /* 2 MiB of uint64: the enemy scratchpad.
                                          A THIRD object class -- plain host
                                          malloc.  It is CPU-only and disjoint
                                          from every test location, so it needs
                                          neither GPU coherence (gd_alloc_shared)
                                          nor device memory (gd_dev_malloc).  Do
                                          not conflate the three.               */
#endif
#ifndef HET_CPU_SPREAD
#define HET_CPU_SPREAD 8          /* S&D "spread" m: distinct lines hammered     */
#endif
#ifndef HET_CPU_STRIDE
#define HET_CPU_STRIDE 8          /* M4 STRIDE: word gap between regions.  8 x 8B
                                     = 64B = one cache line, so consecutive
                                     regions land on distinct lines.             */
#endif
#ifndef HET_CPU_ENEMY_SEQ
#define HET_CPU_ENEMY_SEQ 0       /* sigma: 0=st;st 1=st;ld 2=ld;st 3=ld;ld.
                                     0 is the only pure WRITER: store traffic
                                     invalidates lines and forces ownership
                                     transfer, which is the strong coherence
                                     stressor.  Reaches the enemy as a RUNTIME
                                     field -- divergence (1).                    */
#endif
#ifndef HET_CPU_PRELOAD_PCT
#define HET_CPU_PRELOAD_PCT 50    /* M3: % of iterations a TEST thread preloads
                                     its own test variables (litmus7's default
                                     preload mode is RandomPL).                  */
#endif
#ifndef HET_CPU_AFFINITY
#define HET_CPU_AFFINITY 1        /* M6: pin threads to cores (sched_setaffinity)*/
#endif
#ifndef HET_CPU_TEST_CORE0
#define HET_CPU_TEST_CORE0 0      /* first core the CPU test threads are pinned to*/
#endif
#ifndef HET_CPU_RESERVE_CORES
#define HET_CPU_RESERVE_CORES 2   /* cores left unpinned for the OS, the driver and
                                     the GPU-launch thread.  Grace has 72 cores and
                                     NO SMT (1 hw thread/core), so litmus7's SMT /
                                     hyperthread knobs are INERT there and affinity
                                     reduces to which core + L2/L3 locality; on the
                                     x86 MI300A host (24c/48t/3 CCD) they are live.
                                     Q6 2.5.                                     */
#endif

/* -------------------------------------------------------------------------
 * HALF 2 KNOBS -- interconnect (C2C).  HET_PLACE is consumed in the .cu (it is
 * CUDA API, not host asm); the noise knobs are consumed on both sides.
 * ------------------------------------------------------------------------- */
#ifndef HET_PLACE
#define HET_PLACE 0               /* shared-var placement:
                                     0 = first-touch (DEFAULT).  This is Bagchi's
                                         baseline -- they used plain malloc() and
                                         let first-touch decide -- and it is the
                                         honest default because Q6 3.3 finds the
                                         net effect of pinning CONFOUNDED (it
                                         widens the window but slows the loop) and
                                         nobody has measured which way it goes.
                                     1 = prefer HBM  (pages home on the GPU)
                                     2 = prefer DDR  (pages home on the CPU)
                                     B8 sweeps this.  Do NOT promote a non-zero
                                     default without hardware evidence.          */
#endif
#ifndef HET_NOISE_MB
#define HET_NOISE_MB 8192         /* per noise buffer.  Fusco's is 8 GB, and the
                                     size is NOT arbitrary: the buffer must exceed
                                     the last-level cache on the path or the reads
                                     hit cache and cross nothing (Grace L3 = 114 MB,
                                     Hopper L2 = 51 MB, Bagchi Tab. 1).  Checked at
                                     RUN time, loudly -- see HET_LLC_MB.          */
#endif
#ifndef HET_NOISE_CPU
#define HET_NOISE_CPU 1           /* the Grace half: a CPU thread stream-reading a
                                     HBM-homed buffer                             */
#endif
#ifndef HET_NOISE_GPU_BLOCKS
#define HET_NOISE_GPU_BLOCKS 8    /* the Hopper half: blocks of the PERSISTENT grid
                                     stream-reading a DDR-homed buffer.  They are
                                     extra blocks of the existing kernel, never a
                                     second __global__ -- a separate kernel would
                                     drop its ops into the middle of the flat PTX
                                     op stream that the L0 faithfulness gate slices
                                     per lane.                                    */
#endif
#ifndef HET_NOISE_CHUNK
#define HET_NOISE_CHUNK 4096      /* words streamed per round before re-testing the
                                     stop flag.  Bounds how long the noise can
                                     outlive the test.                            */
#endif
#ifndef HET_NOISE_STRIDE
#define HET_NOISE_STRIDE 1        /* words between consecutive noise reads         */
#endif

/* The last-level cache the noise buffer must EXCEED to generate any interconnect
   traffic at all: max(Grace L3 114 MB, Hopper L2 51 MB).  Fusco: for buffers
   larger than Grace L2, Hopper's DDR accesses "are never cached" -- but Hopper's
   L2 DOES cache HBM, "both local and peer", so a small buffer is served entirely
   from cache and the noise crosses nothing.  A sub-LLC noise buffer is a stressor
   that stresses nothing, so the driver WARNS at run time rather than let a green
   compile imply a live mechanism. */
#define HET_LLC_MB 114

#if (HET_CPU_ENEMY_SEQ) < 0 || (HET_CPU_ENEMY_SEQ) > 3
#error "HET_CPU_ENEMY_SEQ must be 0..3 (0=st;st 1=st;ld 2=ld;st 3=ld;ld)"
#endif
#if (HET_PLACE) < 0 || (HET_PLACE) > 2
#error "HET_PLACE must be 0 (first-touch), 1 (prefer HBM) or 2 (prefer DDR)"
#endif
#if (HET_CPU_SPREAD) < 1
#error "HET_CPU_SPREAD must be >= 1 (it is S&D's spread m)"
#endif
#if (HET_CPU_STRIDE) < 1
#error "HET_CPU_STRIDE must be >= 1"
#endif
/* A zero stride or a zero chunk turns the noise stream into a no-op WITHOUT any
   other symptom: with stride 0 the index never advances, so the thread re-reads ONE
   location for ever (served from L1 -- no DRAM traffic, no C2C traffic); with chunk
   0 the inner loop never executes and the outer loop spins on the stop flag doing
   nothing.  Both would report healthy round counts.  This is the same shape as the
   upstream cuda-litmus MEM_STRESS bug -- a knob whose out-of-range value silently
   disables the mechanism it configures -- so, as there, refuse to compile. */
#if (HET_NOISE_STRIDE) < 1
#error "HET_NOISE_STRIDE must be >= 1 (0 re-reads ONE location for ever: no traffic)"
#endif
#if (HET_NOISE_CHUNK) < 1
#error "HET_NOISE_CHUNK must be >= 1 (0 streams nothing)"
#endif
#if (HET_NOISE_MB) < 1
#error "HET_NOISE_MB must be >= 1"
#endif

/* -------------------------------------------------------------------------
 * LIVENESS TALLY.  The CPU twin of het_stress.cuh's.  Same reason, restated
 * because it is the reason this project keeps shipping dead code: NOTHING in
 * this layer is visible to a structural gate.  The enemy threads touch a private
 * scratchpad; the preload emits cache hints; the noise streams a disjoint buffer.
 * None of it enters the tested op stream -- correctly, it is scaffolding -- and so
 * a layer that has silently stopped working looks EXACTLY like one that is
 * working.  These counters are the only thing that can tell the difference at run
 * time, and every one of them is here because the corresponding mechanism has a
 * plausible way to die:
 *
 *   enemy_rounds     0 => the enemies never ran (a stress_go set after they exited,
 *                    or a loop the optimiser proved side-effect-free and deleted).
 *   preload_ops      0 => the preload incantation is inert (a host ISA with no
 *                    cache primitives, or a 0% roll).
 *   noise_cpu_rounds 0 => the Grace half of the C2C noise never ran.
 *   aff_failures    >0 => sched_setaffinity FAILED and nobody would otherwise
 *                    know: every thread then lands on whatever core the scheduler
 *                    picks, the pinning is a fiction, and the stress topology is
 *                    not the one the tuning assumed.  litmus7 errexit()s here; we
 *                    must not die mid-campaign, but we must not be silent either.
 *   place_failures  >0 => cudaMemAdvise was REFUSED and the pages are wherever
 *                    first touch put them -- i.e. HET_PLACE did nothing while
 *                    claiming to place.  (Filled in the .cu, carried here so one
 *                    struct is the whole vital-signs record.)
 * ------------------------------------------------------------------------- */
typedef struct het_cpu_tally {
  uint64_t enemy_rounds;      /* enemy loop iterations, summed over enemies      */
  uint64_t enemy_accesses;    /* scratchpad accesses issued by the enemies       */
  uint64_t preload_ops;       /* M3 cache hints actually issued                  */
  uint64_t noise_cpu_rounds;  /* Grace noise thread: streaming rounds            */
  uint64_t noise_cpu_words;   /* Grace noise thread: words read                  */
  uint64_t noise_sink;        /* the streamed values, forced to ESCAPE (below)   */
  uint32_t enemies_realised;  /* enemy threads that actually entered their loop  */
  uint32_t aff_failures;      /* sched_setaffinity failures -- never silent      */
  uint32_t place_failures;    /* cudaMemAdvise failures (filled by the .cu)      */
  uint32_t preload_inert;     /* 1 => this host has NO cache primitives at all   */
} het_cpu_tally;

/* -------------------------------------------------------------------------
 * Enemy arguments.  EVERY behavioural field is a RUNTIME value (divergence (1)).
 * ------------------------------------------------------------------------- */
typedef struct het_cpu_enemy_args {
  volatile uint64_t *scratch; /* DISJOINT host scratchpad.  NEVER a test var.    */
  const uint32_t *idx;        /* M2: SHUFFLED region indices (indirection)       */
  uint32_t nidx;              /* M4: spread m -- how many regions per round      */
  uint32_t stride;            /* M4: word gap between regions                    */
  uint32_t seq;               /* sigma, 0..3.  RUNTIME -- see divergence (1).    */
  int core;                   /* M6: core to pin to, or -1 for unpinned          */
  int *go;                    /* the stop flag; set BEFORE the enemies are spawned*/
  het_cpu_tally *tally;
} het_cpu_enemy_args;

/* Grace-side noise arguments (Half 2b).  `buf' is the OTHER PU's memory. */
typedef struct het_cpu_noise_args {
  volatile const uint64_t *buf;  /* HBM-homed buffer -- every read crosses C2C   */
  uint64_t words;
  uint32_t chunk;             /* words per round before the stop flag is re-tested*/
  uint32_t stride;
  int core;
  int *go;
  het_cpu_tally *tally;
} het_cpu_noise_args;

/* -------------------------------------------------------------------------
 * API.  Bodies are compiled ONLY into <test>_cpu.c (HET_CPU_STRESS_IMPL).
 * ------------------------------------------------------------------------- */
int      het_cpu_affinity(int core, het_cpu_tally *t);  /* 0 = pinned, -1 = failed */
int      het_cpu_ncores(void);
uint32_t het_cpu_rng_init(uint32_t seed, uint32_t lane);
/* M3.  Returns the number of hints issued, so the caller can accumulate LOCALLY
   and flush once -- an atomic bump per hint would put scaffolding contention in
   the middle of the tested loop, which is the one place it must not be. */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct);
void    *het_cpu_enemy(void *a);   /* pthread body; NOT a pthread dependency       */
void    *het_cpu_noise(void *a);   /* pthread body; the Grace half of the C2C noise*/
/* -------------------------------------------------------------------------
 * FIRST-TOUCH -- and this one is not a detail, it is the difference between a
 * noise buffer that stresses the interconnect and one that stresses NOTHING.
 *
 * A malloc'd buffer that has never been WRITTEN is not backed by physical memory.
 * Linux maps every untouched anonymous page to a single shared, read-only ZERO
 * PAGE.  So READING such a buffer -- which is exactly what a noise kernel does --
 * touches ONE physical cache line no matter how large the buffer is: every read
 * hits L1, and it generates no memory traffic, no DRAM traffic, and NO INTERCONNECT
 * TRAFFIC AT ALL.  An 8 GB noise buffer would be 4 KB of physical memory.
 *
 * Measured on the dev box, to make sure this is real and not folklore: reading 1 GiB
 * of untouched malloc'd memory grew RSS by 388 KB; first-touching the same buffer
 * grew RSS to 1,050,392 KB -- the actual gigabyte.
 *
 * A noise layer without this compiles, links, runs, reports healthy round counts,
 * and stresses nothing.  That is this project's signature failure, and it would have
 * been its fourth instance.
 *
 * It also decides the page's NUMA HOME on GH200 (first touch places it), which is
 * why the caller advises the preferred location BEFORE calling this, and prefetches
 * afterwards if the pages must end up on the far side.  One write per page suffices.
 * ------------------------------------------------------------------------- */
void     het_cpu_first_touch(void *p, size_t bytes);
/* Host-side, seeded from srand() by the driver, so a run replays from its seed
   (GPUHarbor ISSTA'23 3.4's reproducibility discipline). */
void     het_cpu_shuffle(uint32_t *idx, uint32_t n);

#ifdef HET_CPU_STRESS_IMPL
/* ========================= IMPLEMENTATION =================================
 * Compiled ONLY in the <test>_cpu.c translation unit (gcc for the build host,
 * and clang --target=aarch64-linux-gnu for the real AArch64 asm).  nvcc never
 * sees a line of it.
 * ========================================================================= */
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <unistd.h>

/* ---- M3 cache primitives -------------------------------------------------
 * litmus7's own, reused VERBATIM from litmus/libdir/_aarch64/_cache.h and
 * litmus/libdir/_x86_64/_cache.h (CeCILL-B, as the rest of the tree).
 *
 * On AArch64 `dc civac' cleans+invalidates to the POINT OF COHERENCE -- which on
 * GH200 is the coherence point shared with the GPU over C2C.  So the preload
 * plausibly touches the cross-device path and not merely the CPU's own cache.
 * That is an INFERENCE (Q6 2.1 M3), unmeasured, and hardware-only: it may equally
 * be redundant with the coherence traffic the test's own race already generates.
 * Do not claim it in the thesis without measuring it.
 * ------------------------------------------------------------------------- */
#if defined(__aarch64__)
#define HET_CPU_ISA "aarch64"
#define HET_CPU_PRELOAD_LIVE 1
static inline void het_cache_flush(void *p) {
  asm __volatile__ ("dc civac,%[p]" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch(void *p) {
  asm __volatile__ ("prfm pldl1keep,[%[p]]" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch_store(void *p) {
  asm __volatile__ ("prfm pstl1keep,[%[p]]" :: [p] "r" (p) : "memory");
}
#elif defined(__x86_64__)
#define HET_CPU_ISA "x86_64"
#define HET_CPU_PRELOAD_LIVE 1
static inline void het_cache_flush(void *p) {
  asm __volatile__ ("clflush 0(%[p])" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch(void *p) {
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
static inline void het_cache_touch_store(void *p) {
  /* litmus7's comment, kept: "Did not find how to announce intention to store
     for x86" -- so this is prefetcht0 as well, not a store-intent hint. */
  asm __volatile__ ("prefetcht0 0(%[p])" :: [p] "r" (p) : "memory");
}
#else
#define HET_CPU_ISA "portable"
#define HET_CPU_PRELOAD_LIVE 0
/* No cache primitives on this host.  The preload incantation is INERT here, and
   het_cpu_preload SAYS SO (once) rather than returning a healthy-looking count of
   hints it never issued.  An incantation that quietly does nothing is how a
   meaningless "Never" gets mistaken for a memory-model result. */
static inline void het_cache_flush(void *p) { (void)p; }
static inline void het_cache_touch(void *p) { (void)p; }
static inline void het_cache_touch_store(void *p) { (void)p; }
#endif

/* ---- seeded Park-Miller (host twin of het_stress.cuh's) ------------------ */
static inline uint32_t het_cpu_rng_next(uint32_t *s) {
  *s = (uint32_t)(((uint64_t)*s * 16807ull) % 2147483647ull);
  return *s;
}
static inline int het_cpu_rng_pct(uint32_t *s, int pct) {
  return (int)(het_cpu_rng_next(s) % 100u) < pct;
}
uint32_t het_cpu_rng_init(uint32_t seed, uint32_t lane) {
  uint32_t s = (seed ^ (lane * 2654435761u)) % 2147483647u;
  if (s == 0u) s = 1u;              /* Park-Miller degenerates at 0 */
  return s;
}

int het_cpu_ncores(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return (n < 1) ? 1 : (int)n;
}

/* ---- M6 affinity ---------------------------------------------------------
 * The reuse path is litmus7's write_one_affinity (libdir/_linux_affinity.c:117):
 * it bottoms out in sched_setaffinity with a one-CPU mask.  We reuse the RECIPE,
 * not the file (Q9: no route through Skel.ml).
 *
 * ONE DELIBERATE DIFFERENCE: litmus7 errexit()s on failure.  We must not kill a
 * campaign mid-run -- but we must not swallow it either.  A silently-failed pin
 * puts every thread wherever the scheduler likes, which changes the stress
 * topology completely while looking identical from the outside.  So: count it,
 * and let main() report it.
 * ------------------------------------------------------------------------- */
int het_cpu_affinity(int core, het_cpu_tally *t) {
  if (core < 0) return 0;                    /* unpinned by request */
  cpu_set_t m;
  CPU_ZERO(&m);
  CPU_SET(core, &m);
  if (sched_setaffinity(0, sizeof(m), &m) != 0) {
    if (t) __atomic_fetch_add(&t->aff_failures, 1u, __ATOMIC_RELAXED);
    return -1;
  }
  return 0;
}

/* ---- M3 preload ----------------------------------------------------------
 * Called from cpu_thread_P<n>, per iteration, BEFORE het_run_P<n> -- never
 * inside it (invariant (ii)).  It targets the TEST VARIABLES on purpose: that is
 * what M3 is.  It is -2s-safe anyway, because a cache hint changes RESIDENCY, not
 * program order, and because it cannot migrate into the tested sequence: the
 * tested body is an opaque call into another translation unit and every primitive
 * above is asm volatile with a "memory" clobber.
 * ------------------------------------------------------------------------- */
uint32_t het_cpu_preload(void *const *vars, int nvars, uint32_t *rng, int pct) {
#if HET_CPU_PRELOAD_LIVE == 0
  (void)vars; (void)nvars; (void)rng; (void)pct;
  return 0u;                        /* inert -- the driver reports it, see above */
#else
  uint32_t n = 0u;
  for (int i = 0; i < nvars; i++) {
    if (!het_cpu_rng_pct(rng, pct)) continue;
    /* litmus7's RandomPL: flush / touch / touch-for-store, chosen per variable
       per iteration off the thread's own stream. */
    switch (het_cpu_rng_next(rng) % 3u) {
    case 0:  het_cache_flush(vars[i]);       break;
    case 1:  het_cache_touch(vars[i]);       break;
    default: het_cache_touch_store(vars[i]); break;
    }
    n++;
  }
  return n;
#endif
}

/* ---- M1 (S&D form) + M2 + M4: the disjoint-scratchpad enemy ---------------
 * The litmus7 NEXE recipe -- concurrent memory-subsystem contention -- realised in
 * S&D's disjoint-scratchpad form, which is what composes with a persistent GPU
 * kernel and is -2s-safe by construction (invariant (i)).
 *
 * THE ACCESSES ARE `volatile'.  This is load-bearing, and it is where the CPU
 * enemy DIVERGES from het_stress.cuh's GPU stresser, which is deliberately NON-
 * volatile (upstream's, so that its traffic is ordinary cacheable traffic that
 * thrashes the testing thread's own L1).  Here the loop's only observable effect
 * IS the memory traffic, so a non-volatile version is provably side-effect-free
 * and -O2 deletes it outright -- which is exactly how B4's stress layer died.
 * `volatile' forbids the compiler to elide or reorder the accesses while leaving
 * them ordinary cacheable traffic to the hardware, which is what we want.
 * hetlitmus/verify/cpustresscheck.py reads the COMPILED asm to prove the loop
 * survived, because reading the source proves nothing.
 * ------------------------------------------------------------------------- */
void *het_cpu_enemy(void *_a) {
  het_cpu_enemy_args *a = (het_cpu_enemy_args *)_a;
  het_cpu_affinity(a->core, a->tally);
  __atomic_fetch_add(&a->tally->enemies_realised, 1u, __ATOMIC_RELAXED);

  uint64_t rounds = 0, accesses = 0;
  uint32_t i = 0;
  /* The stop flag is read atomically every round: a plain load could be hoisted
     out of the loop, and an enemy that never re-reads its flag never stops. */
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t r = 0; r < a->nidx; r++) {
      /* M2 (indirect): the region is reached through a SHUFFLED index array, not
         by walking r -- "a shuffled array of pointers, giving a much greater
         variability of outcomes" (Alglave TACAS'11 3).  Indirection is applied to
         the SCRATCHPAD ONLY; the coherent single-word test variables stay direct.
         M4 (stride): consecutive regions are `stride' words apart, so they land on
         distinct cache lines -- the CPU-side analogue of S&D's spread/distance. */
      volatile uint64_t *l = a->scratch + (size_t)a->idx[r] * (size_t)a->stride;
      switch (a->seq) {              /* sigma -- RUNTIME, divergence (1) */
      case 0:  *l = i; *l = i + 1;        break;   /* st;st -- the pure WRITER */
      case 1:  *l = i; (void)*l;          break;   /* st;ld */
      case 2:  (void)*l; *l = i;          break;   /* ld;st */
      default: (void)*l; (void)*l;        break;   /* ld;ld */
      }
      accesses += 2;
    }
    i++;
    rounds++;
  }
  /* One flush at the end.  An atomic bump per round would make the tally itself a
     contended location and change the stress it is supposed to be measuring. */
  __atomic_fetch_add(&a->tally->enemy_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->enemy_accesses, accesses, __ATOMIC_RELAXED);
  return NULL;
}

/* ---- Half 2b: the GRACE noise thread -------------------------------------
 * Fusco's Grace noise kernel: continuously stream-read a buffer homed on the
 * OTHER processing unit's memory (HBM), so every read that misses cache crosses
 * the C2C interconnect.  The Hopper twin is emitted into the .cu as extra blocks
 * of the persistent grid (never a second kernel -- see the header of that file).
 *
 * The buffer is DISJOINT from every test location, so this is -2s-safe by the same
 * S&D invariant as the enemies.
 *
 * `buf' is volatile: the accumulator would otherwise be dead and -O2 would delete
 * the entire stream.  The accumulator is ALSO forced to escape into the tally --
 * belt and braces, because a noise thread that compiled to nothing would be the
 * fourth instance of this project's signature bug.
 * ------------------------------------------------------------------------- */
void *het_cpu_noise(void *_a) {
  het_cpu_noise_args *a = (het_cpu_noise_args *)_a;
  het_cpu_affinity(a->core, a->tally);

  uint64_t rounds = 0, words = 0, acc = 0, i = 0;
  while (__atomic_load_n(a->go, __ATOMIC_RELAXED)) {
    for (uint32_t c = 0; c < a->chunk; c++) {
      acc += a->buf[i];
      i += a->stride;
      if (i >= a->words) i = 0;    /* wrap: keep the whole working set streaming */
    }
    words += a->chunk;
    rounds++;
  }
  __atomic_fetch_add(&a->tally->noise_cpu_rounds, rounds, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->noise_cpu_words, words, __ATOMIC_RELAXED);
  __atomic_fetch_add(&a->tally->noise_sink, acc, __ATOMIC_RELAXED);
  return NULL;
}

/* ---- first-touch (see the declaration above for why this is load-bearing) --
 * One write per page.  `volatile' so it cannot be optimised away -- a first-touch
 * loop the compiler deletes leaves the buffer on the zero page, which is precisely
 * the failure it exists to prevent.
 * ------------------------------------------------------------------------- */
void het_cpu_first_touch(void *p, size_t bytes) {
  long ps = sysconf(_SC_PAGESIZE);
  if (ps < 1) ps = 4096;
  volatile unsigned char *b = (volatile unsigned char *)p;
  for (size_t i = 0; i < bytes; i += (size_t)ps) b[i] = 1u;
  if (bytes > 0) b[bytes - 1] = 1u;      /* the tail page, if bytes is not a multiple */
}

/* ---- M2: the shuffle behind the indirection ------------------------------
 * Fisher-Yates over rand(), which the driver seeds per run from (HET_SEED + run),
 * so the layout is replayable.  This is the CPU twin of het_set_scratch_locations'
 * random line choice in het_stress.cuh.
 * ------------------------------------------------------------------------- */
void het_cpu_shuffle(uint32_t *idx, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) idx[i] = i;
  for (uint32_t i = n; i > 1; i--) {
    uint32_t j = (uint32_t)(rand() % (int)i);
    uint32_t t = idx[i - 1]; idx[i - 1] = idx[j]; idx[j] = t;
  }
}

#endif /* HET_CPU_STRESS_IMPL */

#ifdef __cplusplus
}
#endif
#endif /* HET_CPU_STRESS_H */
|ocaml}
