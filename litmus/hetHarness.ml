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

(* HetLitmus: the compound harness shape as data -- what one parsed het test
   derives to, and the naming its file emitters share.  Design:
   hetlitmus/docs/het-emission.md. *)

type dev = [ `Cpu | `Gpu ]

(* Plain strings and a printer: no arch-polymorphic type in the record. *)
type cpu_proc = {
    cp_proc : int ;
    cp_addrs : (string * string) list ;  (* address params, ASMLang order *)
    cp_outs : (string * string) list ;   (* one pointer per final register *)
    cp_dump : out_channel -> unit ;
  }

(* [gp_blk] is the proc's block index in the launched grid. *)
type gpu_proc = {
    gp_proc : int ;
    gp_blk : int ; gp_lane : int ;
    gp_instrs : BellBase.instruction list ;
    gp_regs : int list ;
  }

(* One observable column's read buffer, SIZE_OF_TEST wide and off the race
   path; [rb_index] is the column's position among its proc's. *)
type read_buffer = {
    rb_proc : int ;
    rb_index : int ;
    rb_name : string ;
    rb_dev : dev ;
    rb_type : string ;             (* C element type *)
  }

(* The sub-records below are grouped by what reads them: a phase function
   takes only the ones it needs. *)

(* What every rendered file stamps to say which test, and which pair, it is. *)
type identity = {
    id_name : string ;
    id_ident : string ;            (* CudaLang.c_ident of it, for C symbols *)
    id_pair_label : string ;
    id_cpu_only : bool ;
  }

(* The counts the render turns into #defines and the launch is sized by. *)
type geometry = {
    ge_size : int ;                (* SIZE_OF_TEST *)
    ge_runs : int ;                (* NUMBER_OF_RUN *)
    ge_bdim : int ;
    ge_npart : int ;               (* cpu procs + gpu procs *)
    ge_blocks : int ;              (* GPU test blocks *)
    ge_lanes : int ;               (* GPU test lanes *)
  }

(* [pr_participants] is every proc in proc order, which is the order the
   readout ANDs the arrival flags in -- NOT the CPUs followed by the GPUs. *)
type procs = {
    pr_cpus : cpu_proc list ;
    pr_gpus : gpu_proc list ;
    pr_participants : (int * dev) list ;
  }

(* The objects main() allocates, resets per run, reads back and frees. *)
type memory = {
    me_gpu_globals : string list ;
    me_all_globals : string list ;
    me_bufs : read_buffer list ;
  }

(* The outcome vector as columns: what the labels name, what the readout
   reads into `_o[]', and the condition compiled against those indices. *)
type outcome = {
    oc_reg_columns : ((int * string) * string) list ;
                                   (* ((proc, reg as the condition spells it),
                                      host array holding the column) *)
    oc_loc_columns : string list ; (* shared locations read at slot _n *)
    oc_weak_expr : string ;        (* the condition as C over _o[] *)
  }

(* Naming helpers, shared by derive and the emitters *)
let buf_name_of p li = Printf.sprintf "bufP%d_%d" p li
(* 1 iff that participant's rendezvous reached its target on iteration n. *)
let rdv_gpu_name p = Printf.sprintf "_rdvG_P%d" p
let rdv_cpu_name p = Printf.sprintf "_rdvC_P%d" p

(* het_run_P<p> wraps code<p>: its declaration, args struct, call
   and read buffers all come from cp_addrs @ cp_outs, in that order. *)
let cpu_read_buffers memory cp =
  List.filter_map
    (fun rb ->
      if rb.rb_proc = cp.cp_proc && rb.rb_dev = `Cpu
      then Some (Printf.sprintf "%s *%s" rb.rb_type rb.rb_name, rb.rb_name)
      else None)
    memory.me_bufs
let cpu_signature cp =
  String.concat "," (List.map fst (cp.cp_addrs @ cp.cp_outs))
let gpu_read_buffers memory =
  List.filter (fun rb -> rb.rb_dev = `Gpu) memory.me_bufs
let n_columns outcome =
  List.length outcome.oc_reg_columns + List.length outcome.oc_loc_columns

(* One emission's harness: the shape above, the identity every rendered file
   stamps, and the toolchain and dialect facts the build files fold over. *)
type t = {
    h_identity : identity ;
    h_geometry : geometry ;
    h_procs : procs ;
    h_memory : memory ;
    h_outcome : outcome ;
    h_toolchain : HetCpuFront.toolchain ;
    h_dialects : HetDialect.gpu_dialect list ;
  }
