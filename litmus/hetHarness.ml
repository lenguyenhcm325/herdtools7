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

type dev = [ `Cpu | `Gpu ]

type cpu_proc = {
    cp_proc : int ;
    cp_addrs : (string * string) list ;
    cp_outs : (string * string) list ;
    cp_dump : out_channel -> unit ;
  }

type gpu_proc = {
    gp_proc : int ;
    gp_blk : int ; gp_lane : int ;
    gp_instrs : BellBase.instruction list ;
    gp_regs : int list ;
  }

type read_buffer = {
    rb_proc : int ;
    rb_name : string ;
    rb_dev : dev ;
    rb_type : string ;
  }

type identity = {
    id_name : string ;
    id_ident : string ;
    id_pair_label : string ;
  }

type geometry = {
    ge_size : int ;
    ge_runs : int ;
    ge_bdim : int ;
    ge_npart : int ;
    ge_blocks : int ;
  }

(* In proc order, the order the readout ANDs the arrival flags in. *)
type procs = {
    pr_cpus : cpu_proc list ;
    pr_gpus : gpu_proc list ;
    pr_participants : (int * dev) list ;
  }

type memory = {
    me_gpu_globals : string list ;
    me_all_globals : string list ;
    me_bufs : read_buffer list ;
  }

type outcome = {
    oc_reg_columns : ((int * string) * string) list ;
    oc_loc_columns : string list ;
    oc_weak_expr : string ;
  }

let buf_name_of p li = Printf.sprintf "bufP%d_%d" p li
let rdv_gpu_name p = Printf.sprintf "_rdvG_P%d" p
let rdv_cpu_name p = Printf.sprintf "_rdvC_P%d" p

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

let global_elts = "SIZE_OF_TEST*HET_SLOT_STRIDE_WORDS"
let iteration_elts = "SIZE_OF_TEST"

type residence = Shared | Device | Host
type reset = Memset | Store_zero
type mem_object = {
    mo_name : string ;
    mo_type : string ;
    mo_bytes : string ;
    mo_where : residence ;
    mo_reset : reset ;
  }

let mem_object ~name ~ty ~elts ~where ~reset =
  { mo_name = name ; mo_type = ty ;
    mo_bytes = Printf.sprintf "sizeof(%s)*%s" ty elts ;
    mo_where = where ; mo_reset = reset }

let race_surface memory =
  List.map
    (fun g ->
      mem_object ~name:g ~ty:"int" ~elts:global_elts
        ~where:Shared ~reset:Memset)
    memory.me_all_globals
  @ [ mem_object ~name:"barrier" ~ty:"uint64_t"
        ~elts:"HET_SLOT_STRIDE_WORDS" ~where:Shared ~reset:Store_zero ]

let observation_record memory procs =
  List.map
    (fun rb ->
      mem_object ~name:rb.rb_name ~ty:rb.rb_type ~elts:iteration_elts
        ~where:(match rb.rb_dev with `Gpu -> Device | `Cpu -> Host)
        ~reset:Memset)
    memory.me_bufs
  @ List.map
      (fun gp ->
        mem_object ~name:(rdv_gpu_name gp.gp_proc) ~ty:"uint8_t"
          ~elts:iteration_elts ~where:Device ~reset:Memset)
      procs.pr_gpus
  @ List.map
      (fun cp ->
        mem_object ~name:(rdv_cpu_name cp.cp_proc) ~ty:"uint8_t"
          ~elts:iteration_elts ~where:Host ~reset:Memset)
      procs.pr_cpus

let memory_objects memory procs =
  race_surface memory @ observation_record memory procs

type t = {
    h_identity : identity ;
    h_geometry : geometry ;
    h_procs : procs ;
    h_memory : memory ;
    h_outcome : outcome ;
    h_toolchain : HetCpuFront.toolchain ;
    h_dialect : HetDialect.gpu_dialect ;
  }
