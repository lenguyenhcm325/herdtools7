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
   path. *)
type read_buffer = {
    rb_proc : int ;
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

(* Every shared global is SIZE_OF_TEST slots wide, one per iteration. *)
let global_bytes = "sizeof(int)*SIZE_OF_TEST*HET_SLOT_STRIDE_WORDS"
let buf_bytes ty = Printf.sprintf "sizeof(%s)*SIZE_OF_TEST" ty
let rdv_bytes = "sizeof(uint8_t)*SIZE_OF_TEST"

(* One object main() manages.  Residence decides its allocation, readback and
   free text; the reset kind separates the barrier counter from the arrays. *)
type residence = Shared | Device | Host
type reset = Memset | Store_zero
type mem_object = {
    mo_name : string ;
    mo_type : string ;             (* C element type *)
    mo_bytes : string ;            (* C byte count *)
    mo_where : residence ;
    mo_reset : reset ;
  }

(* The two families main() allocates, resets, reads back and frees, in that
   lifecycle order: the race surface -- every shared global, then the barrier
   counter -- reset BEFORE the stress spawn; then the observation record --
   the read buffers in column order, then one arrival flag per proc on the
   side that writes it -- reset after it. *)
let race_surface memory =
  List.map
    (fun g ->
      { mo_name = g ; mo_type = "int" ; mo_bytes = global_bytes ;
        mo_where = Shared ; mo_reset = Memset })
    memory.me_all_globals
  @ [ { mo_name = "barrier" ; mo_type = "uint64_t" ;
        mo_bytes = "sizeof(int)*HET_SLOT_STRIDE_WORDS" ;
        mo_where = Shared ; mo_reset = Store_zero } ]

let observation_record memory procs =
  List.map
    (fun rb ->
      { mo_name = rb.rb_name ; mo_type = rb.rb_type ;
        mo_bytes = buf_bytes rb.rb_type ;
        mo_where = (match rb.rb_dev with `Gpu -> Device | `Cpu -> Host) ;
        mo_reset = Memset })
    memory.me_bufs
  @ List.map
      (fun gp ->
        { mo_name = rdv_gpu_name gp.gp_proc ; mo_type = "uint8_t" ;
          mo_bytes = rdv_bytes ; mo_where = Device ; mo_reset = Memset })
      procs.pr_gpus
  @ List.map
      (fun cp ->
        { mo_name = rdv_cpu_name cp.cp_proc ; mo_type = "uint8_t" ;
          mo_bytes = rdv_bytes ; mo_where = Host ; mo_reset = Memset })
      procs.pr_cpus

let memory_objects memory procs =
  race_surface memory @ observation_record memory procs

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
