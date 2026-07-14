(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2010-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(***********************************************)
(* Parse a source file for the needs of litmus *)
(* (And then compile test)                     *)
(***********************************************)

open Answer

module type CommonConfig = sig
  val verbose : int
  val limit : bool
  val timeloop : int
  val stride : Stride.t
  val avail : int option
  val runs : int
  val size : int
  val noccs : int
  val timelimit : float option
  val isync : bool
  val speedcheck : Speedcheck.t
  val safer : Safer.t
  val cautious : bool
  val preload : Preload.t
  val memory : Memory.t
  val alloc : Alloc.t
  val doublealloc : bool
  val threadstyle : ThreadStyle.t
  val launch : Launch.t
  val barrier : Barrier.t
  val linkopt : string
  val logicalprocs : int list option
  val affinity : Affinity.t
  val targetos : TargetOS.t
  val is_out : bool
  val exit_cond : bool
  val sleep : int
  val driver : Driver.t
  val crossrun : Crossrun.t
  val adbdir : string
  val makevar : string list
  val gcc : string
  val c11 : bool
  val ascall : bool
  val fault_handling : Fault.Handling.t
  val mte_precision : Precision.t
  val variant : Variant_litmus.t -> bool
  val nocatch : bool
  val stdio : bool
  val xy : bool
  val morearch : MoreArch.t
  val carch : Archs.System.t
  val syncconst : int
  val numeric_labels : bool
  val kind : bool
  val force_affinity : bool
  val smtmode : Smt.t
  val smt : int
  val nsockets : int
  val contiguous : bool
  val noalign : Align.t option
  val syncmacro : int option
  val collect : Collect.t
  val hexa : bool
  val verbose_barrier : bool
  val verbose_prelude : bool
  val check_kind : string -> ConstrGen.kind option
  val check_cond : string -> string option
  val check_nstates : string -> int option
  val cross : bool
  val tarname : string
  val hint : string option
  val no : string option
  val index : string option
  val outnames : string option
end

module type TopConfig = sig
  include CommonConfig
  val platform : string
  val check_name : string -> bool
  val check_rename : string -> string option
  (* Arch dependent options *)
  val mkopt : Option.opt -> Option.opt
  (* Mode *)
  val mode : Mode.t
  (* usearch *)
  val usearch : UseArch.t
  (* Hum *)
  val asmcomment : string option
  val asmcommentaslabel : bool
end

module type Config = sig
  include GenParser.Config
  include Compile.Config
  val asmcommentaslabel : bool
  val sysarch : Archs.System.t
  (* Additions for Presi *)
  val line : int
  val noccs : int
  val timelimit : float option
  val check_nstates : string -> int option
  val fault_handling : Fault.Handling.t
  (* End of additions *)
  include Skel.Config
  include Run_litmus.Config
  val limit : bool
  val word : Word.t
  val noinline : bool
end

module Top (OT:TopConfig) (Tar:Tar.S) : sig
  val from_files : string list -> unit
end = struct

  (************************************************************)
  (* Some configuration dependent stuff, to be performed once *)
  (************************************************************)

  (* Avoid cycles *)
  let read_no fname =
    Misc.input_protect
      (fun chan -> MySys.read_list chan (fun s -> Some s))
      fname

  let avoid_cycle =
    let xs = match OT.no with
      | None -> []
      | Some fname -> read_no fname in
    let set = StringSet.of_list xs in
    fun cy -> StringSet.mem cy set

  (* hints *)
  let hint = match OT.hint with
    | None -> Hint.empty
    | Some fname -> Hint.read fname

  module W = Warn.Make(OT)


  module Utils (O:Config) (A':Arch_litmus.Base)
           (Lang:Language.S with type t = A'.Out.t)
           (Pseudo:PseudoAbstract.S with type ins = A'.instruction) =
    struct

      module T = Test_litmus.Make(O)(A')(Pseudo)
      module R = Run_litmus.Make(O)(Tar)(T.D)
      module H = LitmusUtils.Hash(O)

      let get_cycle t =
        let info = t.MiscParser.info in
        List.assoc "Cycle" info

      let cycle_ok avoid t =
        try
          let cy = get_cycle t in
          not (avoid cy)
        with Not_found -> true


      let change_hint hint name t =
        try
          let more_info = Hint.get hint name in
          let info =
            more_info @
              List.filter
                (fun (k,_) ->
                  try
                    let _ = List.assoc k more_info in
                    false
                  with Not_found -> true)
                t.MiscParser.info in
          { t with MiscParser.info = info; }
        with Not_found -> t

      let dump source doc compiled =
        let outname = Tar.outname source in
        try
          Misc.output_protect
            (fun chan ->
              let module Out =
                Indent.Make(struct let hexa = O.hexa let out = chan end) in
              let dump =
                match OT.mode with
                | Mode.Std ->
                    let module S = Skel.Make(O)(Pseudo)(A')(T)(Out)(Lang) in
                    S.dump
                | Mode.PreSi|Mode.Kvm ->
                    let module O =
                      struct
                        include O
                        let is_kvm = match OT.mode with
                        | Mode.Kvm -> true
                        | Mode.PreSi -> false
                        | Mode.Std -> assert false
                        let is_tb = match OT.barrier with
                        | Barrier.TimeBase  -> true
                        | _ -> false
                      end  in
                    let module S = PreSi.Make(O)(Pseudo)(A')(T)(Out)(Lang) in
                    S.dump in
              dump doc compiled)
            outname
        with e ->
          begin try Sys.remove outname with _ -> () end ;
          raise e

      let check_variant v a =
        if O.variant v && not (Variant_litmus.ok v a) then
          Warn.user_error
            "variant %s does not apply to arch %s"
            (Variant_litmus.pp v)
            (Archs.pp a) ;
        let v = Variant_litmus.Vmsa in
        if O.variant v && O.mode != Mode.Kvm then
          Warn.user_error
            "(optional) variant %s not compatible with mode %s"
            (Variant_litmus.pp v)
            (Mode.pp O.mode)

      let limit_ok nprocs = match O.avail with
        | None|Some 0 -> true
        | Some navail -> not O.limit || nprocs <= navail

      let warn_limit name nprocs = match O.avail with
        | None|Some 0 -> ()
        | Some navail ->
           if nprocs > navail then
             Warn.warn_always
               "%stest with more threads (%i) than available (%i) is compiled"
               (Pos.str_pos0 name.Name.file) nprocs navail

      let compile
            parse count_procs compile allocate
            hash_env
            name in_chan out_chan splitted =
        try begin
            check_variant Variant_litmus.Self splitted.Splitter.arch ;
            let parsed = parse in_chan splitted in
            let doc = splitted.Splitter.name in
            let tname = doc.Name.name in
            close_in in_chan ;
            let nprocs = count_procs parsed.MiscParser.prog in
            let hash =  H.mk_hash_info name parsed.MiscParser.info in
            let cycle_ok = cycle_ok avoid_cycle parsed
            and hash_ok = H.hash_ok hash_env tname hash
            and limit_ok = limit_ok nprocs in
            if
              cycle_ok && hash_ok && limit_ok
            then begin
                warn_limit doc nprocs ;
                let parsed = change_hint hint doc.Name.name parsed in
                let allocated = allocate parsed in
                let compiled = compile doc allocated in
                let src = MyName.outname name ".c" in
                let flags =
                  { Flags.pac = O.variant (Variant_litmus.PacVersion `PAuth1) ||
                                O.variant (Variant_litmus.PacVersion `PAuth2);
                    Flags.self = O.variant Variant_litmus.Self;
                    Flags.memtag = O.variant Variant_litmus.MemTag;
                    Flags.exs = O.variant Variant_litmus.ExS;
                    Flags.ets = O.variant Variant_litmus.ETS2 } in
                dump src doc compiled;
                if not OT.is_out then begin
                    let _utils =
                      let module OO = struct
                        include OT
                        let arch = A'.arch
                        let sysarch = Archs.get_sysarch A'.arch OT.carch
                        let cached =
                          match threadstyle with
                          | ThreadStyle.Cached -> true
                          | _ -> false
                      end in
                      let module Obj = ObjUtil.Make(OO)(Tar) in
                      Obj.dump flags in
                    ()
                  end ;
                R.run name out_chan doc allocated src ;
                Completed
                  { arch = A'.arch; doc; src; fullhash = hash ;
                    nprocs; flags; }
              end else begin
                let cause = if limit_ok then "" else " (too many threads)" in
                Warn.warn_always "%s test not compiled%s"
                  (Pos.str_pos0 doc.Name.file) cause ;
                Absent
              end
          end with e -> if OT.nocatch then raise e ; Interrupted e
    end


  module Make
           (O:Config)
           (A:Arch_litmus.S)
           (L:GenParser.LexParse with type instruction = A.parsedPseudo)
           (XXXComp : XXXCompile_litmus.S with module A = A) =
    struct
      module Pseudo = LitmusUtils.Pseudo(A)
      module ALang = struct
        include A.I
        module RegSet = A.Out.RegSet
        module RegMap = A.Out.RegMap
      end
      module Lang = ASMLang.Make(O)(ALang)(A.Out)(A)
      module Utils = Utils(O)(A)(Lang)(Pseudo)
      module P = GenParser.Make(O)(A) (L)
      module Comp = Compile.Make (O)(A)(Utils.T)(XXXComp)

      module AllocArch = struct
        include A
        type v = A.V.v
        let maybevToV = A.maybevToV
        type global = Global_litmus.t
        let maybevToGlobal = A.tr_global
      end

      let compile =
        let allocate parsed =
          let module Alloc = SymbReg.Make(AllocArch) in
          Alloc.allocate_regs parsed in
        Utils.compile P.parse MiscParser.count_procs Comp.compile allocate
    end


  module Make'
           (O:Config)
           (A:sig val comment : string end) =
    struct
      module L = struct
        type token = CParser.token
        module CL = CLexer.Make(struct let debug = false end)
        let lexer = CL.token false
        let parser lexer buf = fst (CParser.shallow_main lexer buf)
      end

      module A' = CArch_litmus.Make(O)

      module Pseudo =
        struct
          type ins = A'.instruction
          include DumpCAst
          let code_exists _ _ = assert false
          let exported_labels_code _ = Label.Full.Set.empty
          let from_labels _ _ = []
          let all_labels _ = []
        end

      module Lang =
        CLang.Make
          (struct
            let comment = A.comment
            let memory = O.memory
            let mode = O.mode
            let asmcommentaslabel = O.asmcommentaslabel
          end)
          (struct
            let verbose = O.verbose
            let noinline = true
            let simple = false
          end)
      module Utils = Utils(O)(A')(Lang)(Pseudo)
      module P = CGenParser_litmus.Make(O)(Pseudo)(A')(L)
      module Comp =
        CCompile_litmus.Make
          (struct include O let kernel = false let rcu = false end)(Utils.T)

      let compile =
        let allocate parsed =
          let module Alloc = CSymbReg.Make(A') in
          Alloc.allocate_regs parsed in
        Utils.compile P.parse A'.count_procs Comp.compile allocate
    end

  let debuglexer =  OT.verbose > 2

  module LexConfig =
    struct
      let debug = debuglexer
      let check_rename = OT.check_rename
    end


  module SP = Splitter.Make(LexConfig)

  (* ===================== HetLitmus: GPU back-end dialect ===================
     Phase B: the combined CPU+GPU harness is emitted for BOTH CUDA and HIP from
     ONE LISA parse.  CudaLang and HipLang share the layout / globals /
     result-register analysis byte-for-byte; only the per-instruction lowering
     (dump_instr) and a few host tokens differ, so a `gpu_dialect' captures just
     that delta and the same driver template is rendered twice (<t>.cu, <t>.hip). *)
  type gpu_dialect = {
      gd_ext : string ;             (* output extension: "cu" | "hip" *)
      gd_name : string ;            (* "CUDA" | "HIP" *)
      gd_runtime_include : string ; (* the differing GPU atomics/runtime header *)
      (* B3: [~tag] gates the tagged/uint64 store path (Some (iter,k,mu)) vs the
         standalone GPU-only path (None).  Structural tuple so CudaLang and
         HipLang share the type and this one field unifies across both. *)
      gd_dump_instr :
        out_channel -> tag:(string * int * int) option -> string ->
        BellBase.instruction -> unit ;
      gd_device_sync : string ;     (* host-side device-sync statement *)
      gd_free : string -> string ;  (* var -> free statement *)
      gd_bar : string -> string -> string ; (* indent, ptr-expr -> arrive+spin *)
      (* B1 (Q8 R1/R2/R4): per-target allocator for the shared litmus vars + the
         rendezvous barrier.  The allocator SELECTS THE PROPERTY UNDER TEST, so
         this is correctness, not tuning (system malloc/ATS on GH200; fine-grained
         hipMallocManaged on MI300A; cudaMallocManaged only as the dev-box/CI
         fallback).  [gd_shared_mem_defs] emits the file-scope gd_alloc_shared /
         gd_free_shared helpers (call sites are dialect-agnostic C); [gd_shared_mem_note]
         is the corrected banner comment.  __out is NOT routed through these. *)
      gd_shared_mem_note : string ;  (* corrected "shared vars" banner comment *)
      gd_shared_mem_defs : string ;  (* file-scope gd_alloc_shared / gd_free_shared defs *)
      (* B2: cooperative-launch API tokens.  Used PURELY for the co-residency +
         weak-progress guarantee of the persistent kernel; the CPU<->GPU rendezvous
         stays [gd_bar] (system-scope atomic), so NO grid.sync / cooperative_groups.h. *)
      gd_err_t : string ;         (* "cudaError_t"      | "hipError_t" *)
      gd_success : string ;       (* "cudaSuccess"      | "hipSuccess" *)
      gd_errstr : string ;        (* error-code -> message fn *)
      gd_dev_attr : string ;      (* device-attribute query fn *)
      gd_attr_coop : string ;     (* cooperative-launch support attribute enum *)
      gd_attr_smcount : string ;  (* multiprocessor-count attribute enum *)
      gd_occupancy : string ;     (* max-active-blocks-per-SM occupancy query fn *)
      gd_coop_launch : string ;   (* cooperative kernel-launch fn *)
      (* B3: read-buffer device-memory tokens.  The per-load read buffers live in
         DEVICE memory (off the coherent race path -- buffer writes must not add
         C2C traffic that perturbs the tested race), then are mirrored host-side
         after the terminal sync for the recovery scan.  Per-dialect FIELDS (not
         branches) keep the "one template, two renders" invariant. *)
      gd_dev_malloc : string -> string -> string ;   (* var, bytes -> device alloc *)
      gd_memcpy_d2h : string -> string -> string -> string ; (* dst, src, bytes *)
      gd_dev_memset0 : string -> string -> string ;  (* ptr, bytes -> zero device mem *)
      (* B4: host->device copy, for the per-run stress scratch-location layout
         (chosen host-side by het_set_scratch_locations, consumed by every
         stressing lane).  The scratchpad itself is DEVICE memory -- GPU-only and
         disjoint from every test location -- so it never goes through
         gd_alloc_shared.  Two object classes, two allocators (Q5 F4). *)
      gd_memcpy_h2d : string -> string -> string -> string ; (* dst, src, bytes *)
      (* B3 observer: a relaxed system-scope uint64 load of a shared var, used by
         the GPU observer lane to snoop a coherence (ws) location.  Analysis-only
         (never the tested order); given the global's C pointer name. *)
      gd_sys_load_u64 : string -> string ;           (* ptr -> load expression *)
    }

  let cuda_dialect = {
      gd_ext = "cu" ; gd_name = "CUDA" ;
      gd_runtime_include = "#include <cuda/atomic>" ;
      gd_dump_instr = CudaLang.dump_instr ;
      gd_device_sync = "cudaDeviceSynchronize();" ;
      gd_free = (fun v -> Printf.sprintf "cudaFree(%s);" v) ;
      gd_bar =
        (fun ind ptr ->
          Printf.sprintf
            "%scuda::atomic_ref<int, cuda::thread_scope_system> _bar(*(%s));\n\
             %s_bar.fetch_add(1, cuda::memory_order_seq_cst);\n\
             %swhile (_bar.load(cuda::memory_order_seq_cst) < NPART) { }\n"
            ind ptr ind ind) ;
      gd_shared_mem_note =
        "// Shared vars + barrier use gd_alloc_shared: system malloc() on GH200 (ATS =>\n\
         // cache-line CHI coherence over NVLink-C2C, the real inter-device protocol);\n\
         // cudaMallocManaged only as the dev-box/CI fallback (managed = 2 MB page\n\
         // migration on GH200, which masks the race -- Q8 R1).\n" ;
      gd_shared_mem_defs =
        {ocaml|/* B1 (Q8 R1/R4): per-target allocator for the shared litmus vars + rendezvous
   barrier.  The allocator SELECTS THE PROPERTY UNDER TEST -- not a perf detail.
   Runtime dispatch (mirrors B2's cooperative support-check): on a pageable-
   memory-access device (GH200: ATS gives CPU+GPU one page table) the shared
   objects go through system malloc(), so both sides touch the SAME cache line in
   place over NVLink-C2C via the real CHI/SWMR hardware coherence -- exactly what
   Bagchi et al. (ISMM'26) used.  cudaMallocManaged is the dev-box/CI FALLBACK
   only: on GH200 it 2 MB-page-migrates under the concurrent race and MASKS the
   weak behaviour.  The free MUST match the allocator (malloc=>free, managed=>
   cudaFree); a mismatched free is UB that may not fault on the managed dev-box
   path and only surfaces on GH200.  The B3 read buffers are NOT routed here --
   they are device memory (cudaMalloc), off the coherent race path.
   Dev box: guard cudaDevAttrConcurrentManagedAccess before treating any local run
   as a result -- the CI path is compile-only, so it never reaches this at run time. */
static int _shared_pageable(void){
  int _p = 0;
  (void)cudaDeviceGetAttribute(&_p, cudaDevAttrPageableMemoryAccess, 0);
  return _p;
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  if (_shared_pageable()) {
    *_pp = malloc(_bytes);   /* GH200: ATS, in-place cache-line CHI coherence */
    /* B5 SEAM: cudaMemAdvise(*_pp,_bytes,cudaMemAdviseSetPreferredLocation,dev)
       + cudaMemAdvise(...,cudaMemAdviseSetAccessedBy,...) pins the page remote to
       its consumer, forcing every access across C2C -- the interconnect-stress
       lever.  Attaches HERE (GH200 malloc branch only); leave unbuilt for B5. */
  } else {
    cudaMallocManaged(_pp, _bytes);   /* dev-box / CI fallback only */
  }
}
static void gd_free_shared(void* _p){
  if (_shared_pageable()) { free(_p); } else { cudaFree(_p); }
}
|ocaml} ;
      gd_err_t = "cudaError_t" ;
      gd_success = "cudaSuccess" ;
      gd_errstr = "cudaGetErrorString" ;
      gd_dev_attr = "cudaDeviceGetAttribute" ;
      gd_attr_coop = "cudaDevAttrCooperativeLaunch" ;
      gd_attr_smcount = "cudaDevAttrMultiProcessorCount" ;
      gd_occupancy = "cudaOccupancyMaxActiveBlocksPerMultiprocessor" ;
      gd_coop_launch = "cudaLaunchCooperativeKernel" ;
      gd_dev_malloc =
        (fun v bytes -> Printf.sprintf "cudaMalloc(&%s, %s);" v bytes) ;
      gd_memcpy_d2h =
        (fun dst src bytes ->
          Printf.sprintf "cudaMemcpy(%s, %s, %s, cudaMemcpyDeviceToHost);"
            dst src bytes) ;
      gd_memcpy_h2d =
        (fun dst src bytes ->
          Printf.sprintf "cudaMemcpy(%s, %s, %s, cudaMemcpyHostToDevice);"
            dst src bytes) ;
      gd_dev_memset0 =
        (fun p bytes -> Printf.sprintf "cudaMemset(%s, 0, %s);" p bytes) ;
      gd_sys_load_u64 =
        (fun ptr ->
          Printf.sprintf
            "cuda::atomic_ref<uint64_t, cuda::thread_scope_system>(*%s).load(cuda::memory_order_relaxed)"
            ptr) ;
    }

  let hip_dialect = {
      gd_ext = "hip" ; gd_name = "HIP" ;
      gd_runtime_include = "#include <hip/hip_runtime.h>" ;
      gd_dump_instr = HipLang.dump_instr ;
      gd_device_sync = "hipDeviceSynchronize();" ; (* B2: no (void) cast -- the terminal sync's return is now error-checked *)
      gd_free = (fun v -> Printf.sprintf "(void)hipFree(%s);" v) ;
      gd_bar =
        (fun ind ptr ->
          Printf.sprintf
            "%s(void)__hip_atomic_fetch_add((%s), 1, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);\n\
             %swhile (__hip_atomic_load((%s), __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM) < NPART) { }\n"
            ind ptr ind ptr) ;
      gd_shared_mem_note =
        "// Shared vars + barrier use gd_alloc_shared: fine-grained hipMallocManaged on\n\
         // MI300A -- the only mode coherent for system-scope CPU<->GPU sync during a\n\
         // live kernel (coarse-grained is visible only at kernel boundary; Q8 R2).\n" ;
      gd_shared_mem_defs =
        {ocaml|/* B1 (Q8 R2/R4): shared litmus vars + barrier use fine-grained coherent memory.
   hipMallocManaged is fine-grained BY DEFAULT on MI300A -- the only coherence mode
   usable for system-scope CPU<->GPU synchronisation *while the kernel is live*
   (coarse-grained memory is visible only at a kernel-boundary sync, which would
   void every heterogeneous test).  MI300A's unified HBM pool needs no page
   migration, so no malloc/ATS dispatch is required for correctness; the free
   matches (hipFree).  A malloc+HSA_XNACK=1 variant is a runtime-env choice, not a
   codegen one.  The B3 read buffers are NOT routed here -- device memory
   (hipMalloc), off the coherent race path. */
static void gd_alloc_shared(void** _pp, size_t _bytes){
  (void)hipMallocManaged(_pp, _bytes);   /* fine-grained by default */
  /* B5 SEAM: MI300A has a single HBM pool -- no LPDDR/HBM placement knob; the
     interconnect-stress placement attaches on the GH200 CUDA twin, not here. */
}
static void gd_free_shared(void* _p){
  (void)hipFree(_p);
}
|ocaml} ;
      gd_err_t = "hipError_t" ;
      gd_success = "hipSuccess" ;
      gd_errstr = "hipGetErrorString" ;
      gd_dev_attr = "hipDeviceGetAttribute" ;
      gd_attr_coop = "hipDeviceAttributeCooperativeLaunch" ;
      gd_attr_smcount = "hipDeviceAttributeMultiprocessorCount" ;
      gd_occupancy = "hipOccupancyMaxActiveBlocksPerMultiprocessor" ;
      gd_coop_launch = "hipLaunchCooperativeKernel" ;
      gd_dev_malloc =
        (fun v bytes -> Printf.sprintf "(void)hipMalloc(&%s, %s);" v bytes) ;
      gd_memcpy_d2h =
        (fun dst src bytes ->
          Printf.sprintf "(void)hipMemcpy(%s, %s, %s, hipMemcpyDeviceToHost);"
            dst src bytes) ;
      gd_memcpy_h2d =
        (fun dst src bytes ->
          Printf.sprintf "(void)hipMemcpy(%s, %s, %s, hipMemcpyHostToDevice);"
            dst src bytes) ;
      gd_dev_memset0 =
        (fun p bytes -> Printf.sprintf "(void)hipMemset(%s, 0, %s);" p bytes) ;
      gd_sys_load_u64 =
        (fun ptr ->
          Printf.sprintf
            "__hip_atomic_load(%s, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM)" ptr) ;
    }

  (* ===================== HetLitmus: the compound emitter ===================
     Phase A: the AArch64-specific Tier-2 body is now a functor over the CPU
     module chain (Arch_litmus + Compile_litmus + a small column frontend); the
     `Het' dispatch arm pre-scans the device tag and applies it at AArch64 or
     X86_64.  The GPU side is fixed (LISA/Bell -> CudaLang/HipLang).  Every CPU
     reference below goes through the [Cpu]/[CpuF] parameters, so the body is
     ISA-agnostic.  See hetlitmus/docs/het-emission.md. *)
  module HetEmit
      (Cfg : Config)
      (Cpu : Arch_litmus.S)
      (CpuComp : XXXCompile_litmus.S with module A = Cpu)
      (CpuLP : GenParser.LexParse with type instruction = Cpu.parsedPseudo)
      (CpuF : sig
         (* lex+parse ONE processor column's ';'-free instruction text with the
            matching ISA sub-parser (errors name the proc + ISA + column) *)
         val parse_column : int -> string -> Cpu.parsedPseudo list
         val isa_name : string         (* human label, e.g. "AArch64" *)
         val host_macro : string       (* CPP macro true on the CPU host ISA *)
         (* (clang triple, -std) to cross-assemble the real CPU asm on a foreign
            dev host; None when the build host already IS this ISA (native gcc) *)
         val cross : (string * string) option
         (* B3 (Decision 1): the tagged-CPU-body hooks.  These are the ONLY
            CPU-ISA-specific pieces of the het emitter; the AArch64 arm wires the
            real HetCpuBody matcher, the x86_64 arm a compile-only stub.
            [het_analyze] resolves one CPU proc's store/load structure (addresses
            resolved via [reg_env]: addr-reg-name -> global C name); the generic
            emitter uses it for the mu map + read-buffer plan + recovery map.
            [het_emit_body] emits the tagged het_run_P<proc> (K*(_n+1)+mu store
            values from register operands, loads recorded into per-iteration
            buffers, tested mnemonics + DMB SY verbatim). *)
         val het_analyze :
           reg_env:(string -> string) -> Cpu.pseudo list -> HetCpuBody.cpu_plan
         val het_emit_body :
           out_channel -> proc:int -> k:int -> store_mu:(int -> int) ->
           load_buf:(int -> string) -> reg_env:(string -> string) ->
           iter:string -> addr_params:(string * string) list ->
           buf_params:(string * string) list -> Cpu.pseudo list -> unit
       end) =
    struct
      (* GPU side is fixed: LISA/Bell frontend + CudaLang/HipLang lowering. *)
      module GpuInstr = Instr.No(struct type instr = BellBase.instruction end)
      module GpuV = Int64Constant.Make(GpuInstr)
      module Gpu = LISAArch_litmus.Make(GpuV)
      module Arch' = HetArch.Make(Cpu)(Gpu)
      module GpuLexer = BellLexer.Make(LexConfig)

      let parse_cpu p txt = List.map Arch'.of_cpu_parsed (CpuF.parse_column p txt)
      let parse_gpu p txt =
        let lexbuf = Lexing.from_string txt in
        (try
           List.map Arch'.of_gpu_parsed
             (LISAParser.instr_option_seq GpuLexer.token lexbuf)
         with
         | Parsing.Parse_error ->
            Warn.user_error
              "HetLitmus: P%d (gpu, LISA/Bell) parse error near offset %d \
               of its instruction column %S"
              p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
         | LexMisc.Error (msg,_) ->
            Warn.user_error
              "HetLitmus: P%d (gpu, LISA/Bell) lexing error: %s (in column %S)"
              p msg txt)

      module LexParse = struct
          type instruction = Arch'.parsedPseudo
          type token = unit
          let lexer = fun _ -> ()
          let parser = Arch'.het_parser ~cpu:parse_cpu ~gpu:parse_gpu
        end
      module P = GenParser.Make(Cfg)(Arch')(LexParse)

      (* Tier-2 CPU backend: the REAL litmus7 compile pipeline for this ISA,
         reused so the CPU thread's inline asm comes from ASMLang (not a
         hand-rolled emitter).  Driven on a CPU-only projection of the het test. *)
      module CpuX = Make(Cfg)(Cpu)(CpuLP)(CpuComp)
      module AllocArchCpu = struct
          include Cpu
          type v = Cpu.V.v
          let maybevToV = Cpu.maybevToV
          type global = Global_litmus.t
          let maybevToGlobal = Cpu.tr_global
        end
      module AllocCpu = SymbReg.Make(AllocArchCpu)

      let outs_h_content = HetArch.outs_h
      let outs_c_content = HetArch.outs_c
      (* B4: the ported cuda-litmus GPU stress layer, emitted verbatim into every
         het harness dir and #include'd by both the .cu and the .hip render. *)
      let het_stress_content = HetArch.het_stress_cuh
      (* B5: the CPU-side + interconnect stress layer.  A SEPARATE header from
         het_stress.cuh because it is the only place host-ISA asm may live: the
         .cu is nvcc's translation unit, and the M3 preload primitives are AArch64
         (dc civac / prfm) or x86 (clflush / prefetcht0) inline asm.  Only
         <test>_cpu.c -- compiled by gcc, and cross-assembled by
         `clang --target=aarch64-linux-gnu' -- defines HET_CPU_STRESS_IMPL and so
         compiles the bodies; the .cu gets the knobs, the arg structs and the
         declarations, and NOT ONE LINE of host ISA. *)
      let het_cpu_stress_content = HetArch.het_cpu_stress_h

      let run _hash_env _name in_chan _out_chan splitted =
        try
          let parsed = P.parse in_chan splitted in
          close_in in_chan ;
          let tname = splitted.Splitter.name.Name.name in
          let doc = splitted.Splitter.name in
          let nprocs_total = List.length parsed.MiscParser.prog in
          (* ---- classify processors by device tag ---- *)
          let dev_of_proc p =
            let rec find = function
              | ((q,annot,_),_)::_ when q=p ->
                 (match annot with Some (d::_) -> d | _ -> "?")
              | _::rest -> find rest
              | [] -> "?" in
            find parsed.MiscParser.prog in
          let is_cpu p = dev_of_proc p = "cpu" in
          if OT.verbose >= 0 then begin
            Printf.eprintf
              "HetLitmus: emitting Tier-2 harness for %s (%d procs, CPU=%s)\n%!"
              tname nprocs_total CpuF.isa_name ;
            List.iter
              (fun ((p,annot,_),_code) ->
                let dev = match annot with Some (d::_) -> d | _ -> "?" in
                Printf.eprintf "  P%d device=%s -> %s\n%!" p dev
                  (match dev with
                   | "cpu" ->
                      Printf.sprintf "CPU pthread (%s asm via ASMLang)" CpuF.isa_name
                   | "gpu" -> "GPU kernel (LISA/PTX via CudaLang/HipLang)"
                   | _ -> "unknown"))
              parsed.MiscParser.prog
          end ;
          (* ---- CPU-only projection -> compile -> templates ---- *)
          let cpu_prog =
            List.filter_map
              (fun ((p,annot,f),code) -> match annot with
                | Some ("cpu"::_) ->
                   Some ((p,annot,f),List.map Arch'.to_cpu_pseudo code)
                | _ -> None)
              parsed.MiscParser.prog in
          let cpu_init =
            List.filter
              (fun (loc,_) -> match loc with
                | MiscParser.Location_reg (p,_) -> is_cpu p
                | _ -> true)
              parsed.MiscParser.init in
          let prop_of = function
            | ConstrGen.ForallStates p | ConstrGen.ExistsState p
            | ConstrGen.NotExistsState p -> p in
          let rec filt_cpu p =
            let open ConstrGen in
            match p with
            | Atom (LV (Loc (MiscParser.Location_reg (pr,_)),_)) ->
               if is_cpu pr then Some p else None
            | Atom _ -> None
            | Not q -> (match filt_cpu q with Some q' -> Some (Not q') | None -> None)
            | And ps -> Some (And (List.filter_map filt_cpu ps))
            | Or ps ->
               (match List.filter_map filt_cpu ps with [] -> None | xs -> Some (Or xs))
            | Implies (a,b) ->
               (match filt_cpu a, filt_cpu b with
                | Some a',Some b' -> Some (Implies (a',b')) | _ -> None) in
          let cpu_prop =
            match filt_cpu (prop_of parsed.MiscParser.condition) with
            | Some p -> p | None -> ConstrGen.And [] in
          let cpu_parsed =
            { MiscParser.info = parsed.MiscParser.info ;
              init = cpu_init ;
              prog = cpu_prog ;
              filter = None ;
              condition = ConstrGen.ExistsState cpu_prop ;
              locations = [] ;
              extra_data = MiscParser.empty_extra ; } in
          let cpu_allocated = AllocCpu.allocate_regs cpu_parsed in
          let cpu_compiled = CpuX.Comp.compile doc cpu_allocated in
          let global_env =
            List.map
              (fun (loc,t) ->
                let t = match t with CType.Array (b,_) -> CType.Base b | _ -> t in
                loc,t)
              cpu_compiled.CpuX.Utils.T.globals in
          (* per-CPU-proc inline-asm function signature (mirrors exactly what
             ASMLang.dump_fun emits: addresses then output regs). *)
          let cpu_param_types out proc =
            let addrs,_ptes = Cpu.Out.get_addrs out in
            let addr_params =
              List.map
                (fun a ->
                  let ty = try List.assoc a global_env with Not_found -> Compile.base in
                  (Printf.sprintf "%s *%s" (SkelUtil.dump_global_type a ty) a), a)
                addrs in
            let out_params =
              List.map
                (fun reg ->
                  let ty =
                    let t = Cpu.Out.RegMap.find reg out.Cpu.Out.ty_env in
                    if CType.is_tag_ptr t then CType.pointer_type t else t in
                  (Printf.sprintf "%s *%s" (CType.dump ty) (Cpu.Out.dump_out_reg proc reg)),
                  (Cpu.Out.dump_out_reg proc reg))
                out.Cpu.Out.final in
            addr_params, out_params in
          let params =
            List.map
              (fun (proc,(out,(_outregs,envV))) ->
                (proc,out,envV,cpu_param_types out proc))
              cpu_compiled.CpuX.Utils.T.code in
          (* ---- GPU-only projection (reuse CudaLang translation) ---- *)
          let gpu_prog =
            List.filter_map
              (fun ((p,annot,f),code) -> match annot with
                | Some ("gpu"::_) ->
                   Some ((p,annot,f),List.map Arch'.to_gpu_pseudo code)
                | _ -> None)
              parsed.MiscParser.prog in
          let gpu_globals = CudaLang.collect_globals gpu_prog in
          let gpu_procs = List.map (fun ((p,_,_),_) -> p) gpu_prog in
          let layout,n_blocks,block_dim =
            CudaLang.layout_of_scopes None gpu_procs in
          let gpu_slots =
            List.concat_map
              (fun ((p,_,_),code) ->
                List.map
                  (fun n ->
                    (p, Printf.sprintf "r%d" n,
                     Printf.sprintf "__out[%d*%d+%d]" p CudaLang.nregs_layout n))
                  (CudaLang.result_regs code))
              gpu_prog in
          let cpu_slots =
            List.concat_map
              (fun (proc,out,_,_) ->
                List.mapi
                  (fun i reg ->
                    (proc, Cpu.pp_reg reg,
                     Printf.sprintf "cpu_outs_P%d[%d]" proc i))
                  out.Cpu.Out.final)
              params in
          let slots = cpu_slots @ gpu_slots in
          let n_reg = List.length slots in
          (* ---- shared globals (allocated once, coherent to both) ----
             Moved above the condition compiler (Task P 7a): the location-atom
             arm reads a global's quiescent post-join value, so it needs the
             allocated set. *)
          let cpu_addrs =
            List.concat_map (fun (_,_,_,(ap,_)) -> List.map snd ap) params in
          let all_globals =
            let seen = Hashtbl.create 8 in
            List.filter
              (fun g -> if Hashtbl.mem seen g then false
                        else (Hashtbl.add seen g () ; true))
              (cpu_addrs @ gpu_globals) in
          (* ================= B3: K*(_n+1)+mu store-tagging plan =================
             (env-research/decisions/B3-decision.md, Decisions 2+3).  Every store
             node (CPU + GPU) gets a distinct mu in [1,#stores]; K = 1 + #stores;
             a store writes the per-iteration tag (uint64_t)K*(_n+1)+mu, so a read
             that observes it decodes (tag mod K)=writer mu and (tag div K)=writer
             iteration (>=1; 0 = init/stale, unambiguous).  The SAME map feeds the
             CPU body (HetCpuBody) and the GPU dump_instr tag ctx. *)
          let het_iter = "(_n + 1)" in   (* tag iteration starts at 1 (reserve 0) *)
          (* reg_env for a CPU proc: init "P:reg=global" -> (regname -> global). *)
          let reg_env_of proc =
            let tbl = Hashtbl.create 8 in
            List.iter
              (fun (loc,(_,v)) -> match loc with
                | MiscParser.Location_reg (p,r) when p = proc ->
                   let g = MiscParser.dump_value v in
                   if List.mem g all_globals then Hashtbl.replace tbl r g
                | _ -> ())
              parsed.MiscParser.init ;
            fun r -> match Hashtbl.find_opt tbl r with Some g -> g | None -> r in
          (* Per proc (canonical proc order): device, ordered stores
             [(global,value opt)], ordered loads [global].  CPU via HetCpuBody
             (CpuF.het_analyze); GPU via BellBase Pst/Pld. *)
          let proc_infos =
            List.map
              (fun ((p,annot,_),code) -> match annot with
                | Some ("cpu"::_) ->
                   let plan =
                     CpuF.het_analyze ~reg_env:(reg_env_of p)
                       (List.map Arch'.to_cpu_pseudo code) in
                   (p, `Cpu, plan.HetCpuBody.stores, plan.HetCpuBody.loads)
                | Some ("gpu"::_) ->
                   let instrs =
                     CudaLang.instrs_of_code (List.map Arch'.to_gpu_pseudo code) in
                   let stores =
                     List.filter_map
                       (function
                        | BellBase.Pst (ao,roi,_) ->
                           let g = match CudaLang.abs_of_addr_op ao with
                             | Some s -> s | None -> "?" in
                           let v = match roi with
                             | BellBase.Imm i -> Some i | _ -> None in
                           Some (g,v)
                        | _ -> None)
                       instrs in
                   (* (global, dest reg) -- the reg is spelled as the condition
                      spells it ("r0"), so the B3c scan binds a GPU atom exactly
                      like a CPU one.  Program order == read-buffer index. *)
                   let loads =
                     List.filter_map
                       (function
                        | BellBase.Pld (BellBase.GPRreg n,ao,_) ->
                           let g = match CudaLang.abs_of_addr_op ao with
                             | Some s -> s | None -> "?" in
                           Some (g, Printf.sprintf "r%d" n)
                        | _ -> None)
                       instrs in
                   (p, `Gpu, stores, loads)
                | _ -> (p, `Gpu, [], []))
              (List.sort
                 (fun ((a,_,_),_) ((b,_,_),_) -> compare a b)
                 parsed.MiscParser.prog) in
          (* mu = 1,2,3,... in (proc order, program order); K = 1 + #stores. *)
          let store_mu_tbl = Hashtbl.create 16 in  (* (proc,store_idx) -> mu *)
          let mu_counter = ref 0 in
          List.iter
            (fun (p,_dev,stores,_loads) ->
              List.iteri
                (fun si _ -> incr mu_counter ;
                             Hashtbl.replace store_mu_tbl (p,si) !mu_counter)
                stores)
            proc_infos ;
          let n_stores_total = !mu_counter in
          let k_tag = 1 + n_stores_total in
          let store_mu p si =
            try Hashtbl.find store_mu_tbl (p,si) with Not_found -> 0 in
          (* (global, orig value) -> mu : decode a read's tag to a writer;
             mu -> orig value : decode a tag to the value that write carried. *)
          let value_mu = Hashtbl.create 16 and mu_value = Hashtbl.create 16 in
          let mu_proc = Hashtbl.create 16 in  (* mu -> writer proc *)
          List.iter
            (fun (p,_dev,stores,_loads) ->
              List.iteri
                (fun si (g,vopt) ->
                  let mu = store_mu p si in
                  Hashtbl.replace mu_proc mu p ;
                  match vopt with
                  | Some v ->
                     Hashtbl.replace value_mu (g,v) mu ;
                     Hashtbl.replace mu_value mu v
                  | None -> ())
                stores)
            proc_infos ;
          (* mu of proc's store to global g (the fr edge's target write). *)
          let proc_store_mu proc g =
            match List.find_opt (fun (p,_,_,_) -> p=proc) proc_infos with
            | Some (_,_,stores,_) ->
               let rec f i = function
                 | (sg,_)::rest -> if sg=g then Some (store_mu proc i) else f (i+1) rest
                 | [] -> None in
               f 0 stores
            | None -> None in
          (* Read buffers: one per (load-performing proc, load index), size N.
             GPU buffers -> cudaMalloc device mem (+ D2H copy for the host scan);
             CPU buffers -> host malloc.  OFF the coherent race path. *)
          let read_buffers =  (* (proc, load_idx, name, dev, global) *)
            List.concat_map
              (fun (p,dev,_stores,loads) ->
                List.mapi
                  (fun li (g,_r) -> (p, li, Printf.sprintf "bufP%d_%d" p li, dev, g))
                  loads)
              proc_infos in
          (* B3c: bind a condition's register atom to a read buffer by LOAD NODE,
             not by device (B3-decision 4.1).  A CPU read buffer and a GPU read
             buffer are the same uint64_t[N] object (the GPU's is host-mirrored
             D2H), so the scan must not care which side performed the load --
             that is what makes MP-gc fall out as literally the same logic as
             MP-cg.  [read_of p r] = the load index of proc p's load into
             register r (program order == read-buffer index), for BOTH devices;
             the reg is spelled as the condition spells it ("r0" / "X0"). *)
          let loads_of p =
            match List.find_opt (fun (q,_,_,_) -> q=p) proc_infos with
            | Some (_,_,_,loads) -> loads | None -> [] in
          let read_of p r =
            let rec f li = function
              | (_,rr)::rest -> if rr = r then Some li else f (li+1) rest
              | [] -> None in
            f 0 (loads_of p) in
          let buf_name p li = Printf.sprintf "bufP%d_%d" p li in
          (* Buffer name the HOST recovery scan reads: GPU buffers live in device
             memory (cudaMalloc) and are mirrored to a host copy "<buf>_h" after
             the terminal sync; CPU buffers are host malloc'd and read in place. *)
          let scan_buf p li =
            let rec f = function
              | (q,l,name,dev,_)::_ when q=p && l=li ->
                 (match dev with `Gpu -> name ^ "_h" | `Cpu -> name)
              | _::rest -> f rest
              | [] -> buf_name p li in
            f read_buffers in
          (* ---- B3 observers (Decision 4/5): the 72 tests whose condition has a
             coherence-final [ell]=v atom need a ws-edge witness.  Per B3-decision
             5, ONE GPU observer lane + ONE CPU observer pthread snoop every such
             location ell into obsG_<ell> (device, mirrored) / obsC_<ell> (host),
             each covering ALL observed locations so a two-ws (2+2W) cycle is
             recovered within a SINGLE observer thread (Eq 3.12).  Observer loads
             are analysis-only (relaxed sys), never the tested order. *)
          let obs_locs =
            List.filter_map
              (fun g ->
                let name = MiscParser.dump_value g in
                if List.mem name all_globals then Some name else None)
              (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
          let has_observers = obs_locs <> [] in
          (* the mu of every store to a given location (its coherence writers). *)
          let writers_of l =
            List.concat_map
              (fun (p,_dev,stores,_loads) ->
                List.concat
                  (List.mapi
                     (fun si (g,_v) -> if g=l then [store_mu p si] else [])
                     stores))
              proc_infos in
          (* the value each observed location is tested against ([l]=v -> v). *)
          let loc_value l =
            let r = ref None in
            let rec scan p = let open ConstrGen in match p with
              | Atom (LV (Loc (MiscParser.Location_global g),v)) ->
                 if !r = None && MiscParser.dump_value g = l then
                   r := int_of_string_opt (ParsedConstant.pp_v v)
              | Not q -> scan q
              | And ps | Or ps -> List.iter scan ps
              | Implies (a,b) -> scan a ; scan b
              | Atom _ -> () in
            scan (prop_of parsed.MiscParser.condition) ; !r in
          (* ---- location slots (Task P 7a): one outcome-vector cell per
             Location_global atom in the condition (e.g. [x]=2), read ONCE after
             pthread_join / device-sync from the quiescent managed global.  In
             this single-instance emitter every condition location is backed by
             an allocated global, so it becomes a real final-memory read; a
             location with no backing global (perpetual mode, B6) is left out of
             loc_slots and c_of_prop emits a compile-visible HET_UNCONVERTIBLE
             marker instead of silently collapsing to constant-true. *)
          let loc_slots =
            List.filter_map
              (fun g ->
                let name = MiscParser.dump_value g in
                if List.mem name all_globals
                then Some (name, Printf.sprintf "(*%s)" name)
                else None)
              (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
          let nslots = n_reg + List.length loc_slots in
          (* ---- condition -> C predicate over the read buffers (B3) ---- *)
          let cval v = ParsedConstant.pp_v v in
          let cint v = int_of_string_opt (ParsedConstant.pp_v v) in
          (* Global that a given (proc,load-index) buffer reads. *)
          let read_global pr li =
            let rec f = function
              | (p,l,_,_,g)::_ when p=pr && l=li -> Some g
              | _::rest -> f rest
              | [] -> None in
            f read_buffers in
          (* Boolean constant-folding for the emitted C: drop the constant-true
             operands "1" / "1 /*..*/" from an AND (else clang's
             -Wconstant-logical-operand fires on `1 && x'), the constant-false
             "0" / "0 /*..*/" from an OR.  HET_PENDING (a macro, not a literal) is
             left as-is -- clang does not flag macro operands. *)
          let is_true s =
            s = "1" || (String.length s >= 2 && s.[0]='1' && s.[1]=' ') in
          let is_false s =
            s = "0" || (String.length s >= 2 && s.[0]='0' && s.[1]=' ') in
          let mk_and parts =
            if List.exists is_false parts then "0"
            else match List.filter (fun p -> not (is_true p)) parts with
            | [] -> "1"
            | [p] -> p
            | ps -> "(" ^ String.concat " && " ps ^ ")" in
          let mk_or parts =
            if List.exists is_true parts then "1"
            else match List.filter (fun p -> not (is_false p)) parts with
              | [] -> "0"
              | [p] -> p
              | ps -> "(" ^ String.concat " || " ps ^ ")" in
          (* ================== B3c: FRAME BINDING ==========================
             (env-research/decisions/B3-decision.md 4.1-4.2, Srivastava Eqs
             3.8-3.14.)  Each proc runs its OWN perpetual loop, so each has its
             own iteration space; a read buffer entry is indexed by the iteration
             of the proc that PERFORMED the load.  Recovering a cycle therefore
             means choosing one frame per participating proc.  We do that by
             DECODING, not searching, wherever the tags allow it (Eq 3.14):

               Base    : the proc carrying the anchor read.  Frame = the scan's
                         loop var _f.
               Pinned  : a proc W whose store was read by an rf atom on an
                         already-bound proc.  The tag DECODES W's iteration
                         exactly -- _mW = tag / K (Eq 3.13).  No search.
               Windowed: a reader whose frame no rf atom decodes (SB/LB's second
                         reader, the 3-hop shapes' third proc).  Searched over
                         [c-W, c+W] where the centre c is itself decoded from a
                         bound proc's read of a location THIS proc writes -- a
                         stale-but-real rf edge.  This is the T_L>=2 window.

             Every cycle edge is then one predicate over those frames:
               rf  (Eq 3.13): tag % K == mu_writer  [+ tag / K == it(W) when W's
                              frame is already bound by another atom]
               fr  (Fig 3.7 = rf+ws): tag < K*it(W) + mu_target -- the read took
                              a write coherence-BEFORE the cycle's target write.
                              Subsumes literal init (tag 0) and stale writes.
             MP (T_L=1) needs no window at all and stays the exact O(N) scan. *)
          let read_atoms =    (* (proc, load idx, global, value) in source order *)
            let acc = ref [] in
            let rec scan p = let open ConstrGen in match p with
              | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
                 (match read_of pr r, cint v with
                  | Some li, Some n ->
                     (match read_global pr li with
                      | Some g -> acc := (pr,li,g,n) :: !acc
                      | None ->
                         Warn.fatal
                           "hetlitmus: condition reads %d:%s, whose load has no \
                            resolvable location" pr r)
                  | None, _ ->
                     (* Loud by construction: a condition register we cannot bind
                        to a load node would silently become a constant-false
                        detector (the B3 HET_PENDING bug).  Refuse to emit. *)
                     Warn.fatal
                       "hetlitmus: condition names %d:%s but proc %d has no load \
                        into that register (cannot bind a read buffer)" pr r pr
                  | _, None ->
                     Warn.fatal
                       "hetlitmus: condition value for %d:%s is not an integer" pr r)
              | Atom _ -> ()
              | Not q -> scan q
              | And ps | Or ps -> List.iter scan ps
              | Implies (a,b) -> scan a ; scan b in
            scan (prop_of parsed.MiscParser.condition) ;
            List.rev !acc in
          let is_reader p = List.exists (fun (q,_,_,_) -> q=p) read_atoms in
          (* The write an fr read falsifies against: the store to [g] by a proc
             OTHER than the reader (the cycle's target write).  Returns its proc
             and mu. *)
          let fr_target pr g =
            let rec f = function
              | (p,_,stores,_)::rest when p <> pr ->
                 let rec h i = function
                   | (sg,_)::t -> if sg=g then Some (p, store_mu p i) else h (i+1) t
                   | [] -> None in
                 (match h 0 stores with Some x -> Some x | None -> f rest)
              | _::rest -> f rest
              | [] -> None in
            f proc_infos in
          (* --- the binding itself ------------------------------------------ *)
          let frame_kind = Hashtbl.create 8 in   (* proc -> `Base|`Pin|`Win     *)
          let pin_src = Hashtbl.create 8 in      (* pinned  -> (reader,li) decoding it *)
          let win_src = Hashtbl.create 8 in      (* windowed-> (reader,li) centring it *)
          let bound_by = Hashtbl.create 8 in     (* (reader,li) -> proc it bound *)
          let win_order = ref [] in              (* windowed procs, nesting order *)
          let is_bound p = Hashtbl.mem frame_kind p in
          (* Bind every writer that a bound proc's rf atom decodes (fixpoint).
             An fr atom (v=0) must NOT bind its own target: the decode would be
             self-referential (tag < K*(tag/K)+mu degenerates), so R's synchrony
             stays observer-pinned exactly as B3-decision 4.2 requires. *)
          let propagate () =
            let changed = ref true in
            while !changed do
              changed := false ;
              List.iter
                (fun (pr,li,g,v) ->
                  if is_bound pr && v <> 0 then
                    match Hashtbl.find_opt value_mu (g,v) with
                    | Some mu ->
                       (match Hashtbl.find_opt mu_proc mu with
                        | Some w when w <> pr && not (is_bound w) ->
                           Hashtbl.replace frame_kind w `Pin ;
                           Hashtbl.replace pin_src w (pr,li) ;
                           Hashtbl.replace bound_by (pr,li) w ;
                           changed := true
                        | _ -> ())
                    | None -> ())
                read_atoms
            done in
          (* Anchor = the first rf atom (its tag decodes a writer); failing that
             (SB: both reads are fr) the first read atom.  Its proc is the base. *)
          let anchor_atom =
            let rf =
              List.find_opt
                (fun (_,_,g,v) ->
                  v <> 0 && Hashtbl.mem value_mu (g,v))
                read_atoms in
            match rf with Some a -> Some a | None -> (match read_atoms with
                                                      | a::_ -> Some a | [] -> None) in
          (match anchor_atom with
           | None -> ()            (* 2+2W: no reads at all; observer-only cycle *)
           | Some (b,_,_,_) ->
              Hashtbl.replace frame_kind b `Base ;
              propagate () ;
              (* Readers still unbound get a searched window, outermost first. *)
              let rec add_windows () =
                let unbound =
                  List.sort_uniq compare
                    (List.filter_map
                       (fun (p,_,_,_) -> if is_bound p then None else Some p)
                       read_atoms) in
                match unbound with
                | [] -> ()
                | p::_ ->
                   Hashtbl.replace frame_kind p `Win ;
                   (* Centre: a BOUND proc's read of a location p writes -- its
                      tag decodes one of p's iterations (Eq 3.14), stale or not. *)
                   (match
                      List.find_opt
                        (fun (q,_,g,_) ->
                          is_bound q && proc_store_mu p g <> None)
                        read_atoms
                    with
                    | Some (q,li,_,_) -> Hashtbl.replace win_src p (q,li)
                    | None -> ()) ;
                   win_order := !win_order @ [p] ;
                   propagate () ;
                   add_windows () in
              add_windows ()) ;
          (* --- frame expressions (mode = the heuristic scan or the exhaustive
                 ground-truth scan; they differ only in the search RANGE, so they
                 need disjoint variable names) ------------------------------- *)
          let mvar mode p =
            Printf.sprintf "%s%d" (match mode with `Exh -> "_em" | `Heur -> "_m") p in
          let tvar mode p =
            Printf.sprintf "%s%d" (match mode with `Exh -> "_et" | `Heur -> "_t") p in
          let idx_of mode p =        (* 0-based read-buffer index for proc p *)
            match Hashtbl.find_opt frame_kind p with
            | Some `Base -> "_f"
            | Some `Pin -> Printf.sprintf "(%s - 1)" (mvar mode p)
            | Some `Win -> tvar mode p
            | None -> "_f" in
          let it_of mode p =         (* 1-based iteration, for tag arithmetic *)
            match Hashtbl.find_opt frame_kind p with
            | Some `Base -> "(_f + 1)"
            | Some `Pin -> mvar mode p
            | Some `Win -> Printf.sprintf "(%s + 1)" (tvar mode p)
            | None -> "0" in
          let buf_at mode p li =
            Printf.sprintf "%s[%s]" (scan_buf p li) (idx_of mode p) in
          (* A pinned proc's index comes from a decoded tag, so it is only a legal
             buffer index when the tag was a real write (>=1) and in range. *)
          let pin_guards mode =
            List.filter_map
              (fun (p,_) ->
                match Hashtbl.find_opt frame_kind p with
                | Some `Pin when is_reader p ->
                   let v = mvar mode p in
                   Some (Printf.sprintf
                           "(%s >= 1 && %s <= (uint64_t)SIZE_OF_TEST)" v v)
                | _ -> None)
              (List.map (fun (p,_,_,_) -> (p,())) read_atoms
               |> List.sort_uniq compare) in
          (* ---- condition -> C boolean over the bound frames ---- *)
          let rec c_tag_of_prop mode p =
            let open ConstrGen in
            match p with
            | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
               let li = match read_of pr r with
                 | Some li -> li
                 | None -> assert false (* read_atoms already Warn.fatal'd *) in
               let g = match read_global pr li with
                 | Some g -> g | None -> assert false in
               let buf = buf_at mode pr li in
               (match cint v with
                | Some 0 ->
                   (* fr (Fig 3.7): the read took a write coherence-before the
                      cycle's target write.  When the target's frame is bound we
                      can say exactly which write that is; when it is not (R: the
                      only read is this fr, so nothing decodes the writer -- 4.2)
                      we fall back to literal init, which is sound but blind to
                      stale writes.  R's full cycle rests on the observer ws. *)
                   (match fr_target pr g with
                    | Some (w,mu) when is_bound w ->
                       Printf.sprintf "(%s < (uint64_t)%d*%s + %d)"
                         buf k_tag (it_of mode w) mu
                    | _ -> Printf.sprintf "(%s == 0)" buf)
                | Some n ->
                   (match Hashtbl.find_opt value_mu (g,n) with
                    | Some mu ->
                       let same_iter =
                         (* If the writer's frame is already bound by ANOTHER atom,
                            this rf must land on that exact iteration; if THIS atom
                            is what bound it, the equality is a tautology. *)
                         match Hashtbl.find_opt mu_proc mu with
                         | Some w when is_bound w
                                       && Hashtbl.find_opt bound_by (pr,li) <> Some w ->
                            Printf.sprintf " && %s / %d == (uint64_t)%s"
                              buf k_tag (it_of mode w)
                         | _ -> "" in
                       Printf.sprintf "(%s != 0 && %s %% %d == %d%s)"
                         buf buf k_tag mu same_iter
                    | None ->
                       (* No store writes that value: the outcome is unreachable
                          by construction, not un-implemented.  Loud rather than
                          a silent 0. *)
                       Warn.fatal
                         "hetlitmus: condition wants %d:%s=%d but no store writes \
                          %d to %s" pr r n n g)
                | None -> assert false)
            | Atom (LV (Loc (MiscParser.Location_global g),v)) ->
               (* A coherence-final [ell]=v atom is carried by the per-run observer
                  ws cycle (_loc), so it does not constrain the per-frame register
                  part.  An unbacked location would be unobservable -- refuse to
                  emit rather than fold it to a silent constant. *)
               let name = MiscParser.dump_value g in
               if List.mem name obs_locs then
                 Printf.sprintf "1 /* [%s] via observer _loc */" name
               else
                 Warn.fatal
                   "hetlitmus: condition observes [%s]=%s but no global backs it \
                    (no observer buffer can be allocated)" name (cval v)
            | Atom _ ->
               Warn.fatal "hetlitmus: unsupported condition atom (not loc=v)"
            | Not q -> Printf.sprintf "(!%s)" (c_tag_of_prop mode q)
            | And ps -> mk_and (List.map (c_tag_of_prop mode) ps)
            | Or ps -> mk_or (List.map (c_tag_of_prop mode) ps)
            | Implies (a,b) ->
               Printf.sprintf "(!(%s) || %s)"
                 (c_tag_of_prop mode a) (c_tag_of_prop mode b) in
          (* The register half of the cycle, at the bound frames. *)
          let cond_at mode =
            mk_and
              (pin_guards mode
               @ [c_tag_of_prop mode (prop_of parsed.MiscParser.condition)]) in
          let cond_expr = cond_at `Heur in
          (* per-run observer ws name: _ws_<location>_<c|g> (CPU/GPU observer). *)
          let ws_var l dev = Printf.sprintf "_ws_%s_%s" l dev in
          (* location pass (per observer device): register atoms are unconstrained
             (-> 1); a coherence-final [ell]=v atom -> that device's ws witness.
             _loc = (cpu observer sees all its ws) || (gpu observer sees all its
             ws) -- the SAME-observer-thread constraint of Eq 3.12 (B3-decision
             4.3): a two-ws (2+2W) cycle must be recovered within one thread. *)
          let rec c_loc dev p =
            let open ConstrGen in
            match p with
            | Atom (LV (Loc (MiscParser.Location_reg _),_)) -> "1"
            | Atom (LV (Loc (MiscParser.Location_global g),_)) ->
               let name = MiscParser.dump_value g in
               if List.mem name obs_locs then ws_var name dev
               else "0 /* unobservable location */"
            | Atom _ -> "0"
            | Not q -> Printf.sprintf "(!%s)" (c_loc dev q)
            | And ps -> mk_and (List.map (c_loc dev) ps)
            | Or ps -> mk_or (List.map (c_loc dev) ps)
            | Implies (a,b) ->
               Printf.sprintf "(!(%s) || %s)" (c_loc dev a) (c_loc dev b) in
          let loc_expr =
            if has_observers then
              mk_or [ c_loc "c" (prop_of parsed.MiscParser.condition) ;
                      c_loc "g" (prop_of parsed.MiscParser.condition) ]
            else "1" in
          (* B3c HARD INVARIANT (SHARED-CHARGE, "incompleteness is NOT a
             placeholder").  The emitted detector may never be a CONSTANT.  A
             constant-true _weak reports the weak behaviour on every run; a
             constant-false one reports "Never" on every run -- and a spurious
             "Never" on a should-be-forbidden test reads as CONFIRMATION of the
             memory model.  Both silently falsify the science, so refuse to emit
             rather than ship one (this is what B3's HET_PENDING=0 did to 266 of
             the 338 het tests).  Structural, not a test: it cannot regress. *)
          let weak_expr =
            if has_observers then mk_and [cond_expr ; "_loc"] else cond_expr in
          if is_true weak_expr || is_false weak_expr then
            Warn.fatal
              "hetlitmus: %s would emit a CONSTANT weak-behaviour detector \
               (_weak = %s) -- refusing to emit (SHARED-CHARGE.md)"
              tname weak_expr ;
          (* Synchrony source for the guards (Eq 3.14): the base proc's first read
             of a location somebody writes -- its tag decodes a partner iteration.
             This is the rf anchor for MP/S, the window centre's decoder for SB.
             2+2W (no reads) has none, so it carries no skew/distinct stats. *)
          let sync_src =
            List.find_opt
              (fun (p,_,g,_) ->
                Hashtbl.find_opt frame_kind p = Some `Base && writers_of g <> [])
              read_atoms in
          (* "harness was hot at _f": any read observed a real (non-init) writer.
             Feeds het_obs_record.interleavings_detected. *)
          let hot_expr =
            match read_buffers with
            | [] -> "0"
            | _ ->
               "(" ^
               String.concat " || "
                 (List.map
                    (fun (p,li,_,_,_) -> Printf.sprintf "%s[_f] != 0" (scan_buf p li))
                    read_buffers)
               ^ ")" in
          (* B3: the 72 add ONE GPU observer lane + ONE CPU observer pthread, both
             joining the start barrier (Srivastava Alg 2 SYNCHRONIZE), so NPART
             grows by 2 for them. *)
          let n_observers = if has_observers then 2 else 0 in
          let npart = List.length params + List.length gpu_prog + n_observers in
          let id = CudaLang.c_ident tname in
          (* ================= file emission ================= *)
          let base =
            if OT.is_out && (try Sys.is_directory OT.tarname with _ -> false)
            then OT.tarname else Sys.getcwd () in
          let dir = Filename.concat base tname in
          if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
          let write fname f =
            Misc.output_protect f (Filename.concat dir fname) in
          (* ---- <tname>_cpu.c : the CPU threads (real ISA asm) ---- *)
          (* B3 het-CPU signature helpers, SHARED by _cpu.c (the body), the .cu
             extern decl, the cpu_args struct and the driver call so all four
             stay consistent (addresses widened to uint64_t*; one buffer pointer
             per CPU load; trailing int _n). *)
          let cpu_addr_u64 addr_params =
            List.map
              (fun (_,name) -> (Printf.sprintf "uint64_t *%s" name, name))
              addr_params in
          let loads_of_proc proc =
            match List.find_opt (fun (p,_,_,_) -> p=proc) proc_infos with
            | Some (_,_,_,loads) -> loads | None -> [] in
          let cpu_bufs proc =
            List.mapi
              (fun li _ ->
                let b = buf_name proc li in (Printf.sprintf "uint64_t *%s" b, b))
              (loads_of_proc proc) in
          let cpu_code_of proc =
            match List.find_opt (fun ((p,_,_),_) -> p=proc) cpu_prog with
            | Some (_,code) -> code | None -> [] in
          let dump_cpu_file ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "/* HetLitmus Tier-2: TAGGED CPU threads for %s (%s).\n   \
                  Bodies emitted by HetLitmus hetCpuBody (B3 Decision 1): the\n   \
                  tested mnemonics verbatim, store values rebound to the per-\n   \
                  iteration tag K*(_n+1)+mu, loads recorded into buffers.\n   \
                  DO NOT EDIT. */\n"
                 tname CpuF.isa_name) ;
            (* B5: _GNU_SOURCE must precede EVERY libc header -- het_cpu_stress.h
               needs cpu_set_t / sched_setaffinity (M6 affinity), which glibc hides
               behind it.  Defining it after <stdint.h> would be too late. *)
            s "#define _GNU_SOURCE\n" ;
            s "#include <stdint.h>\n\n" ;
            (* B5: THIS translation unit -- and only this one -- compiles the CPU
               stress bodies.  It is built by gcc for the host and by
               `clang --target=aarch64-linux-gnu' for the real AArch64 asm, so it
               is the one place the host-ISA cache primitives can live; nvcc
               compiles the .cu and must never see them. *)
            s "#define HET_CPU_STRESS_IMPL\n" ;
            s "#include \"het_cpu_stress.h\"\n\n" ;
            s (Printf.sprintf "#if defined(%s)\n" CpuF.host_macro) ;
            List.iter
              (fun (proc,_out,_envV,(addr_params,_out_params)) ->
                CpuF.het_emit_body ch ~proc ~k:k_tag
                  ~store_mu:(store_mu proc)
                  ~load_buf:(fun li -> buf_name proc li)
                  ~reg_env:(reg_env_of proc)
                  ~iter:het_iter
                  ~addr_params:(cpu_addr_u64 addr_params)
                  ~buf_params:(cpu_bufs proc)
                  (cpu_code_of proc))
              params ;
            s "#else\n" ;
            s (Printf.sprintf
                 "/* Portable shim so the harness also compiles on a host whose\n   \
                  ISA is not %s.  NOT the tested path -- the %s tagged asm above\n   \
                  is the real CPU thread; build on %s (or cross-assemble). */\n"
                 CpuF.isa_name CpuF.isa_name CpuF.isa_name) ;
            List.iter
              (fun (proc,_out,_envV,(addr_params,_out_params)) ->
                let addr = cpu_addr_u64 addr_params and bufs = cpu_bufs proc in
                let ps =
                  String.concat ","
                    (List.map fst (addr @ bufs) @ ["int _n"]) in
                s (Printf.sprintf "void het_run_P%d(%s) {\n" proc ps) ;
                s "  (void)_n;\n" ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n)) addr ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n)) bufs ;
                s "}\n")
              params ;
            s "#endif\n" in
          (* ---- <tname>.{cu,hip} : GPU kernel + driver (per dialect) ---- *)
          let dump_gpu_file dialect ch =
            let s = output_string ch in
            let mech_class =
              HetCond.perpetual_class (prop_of parsed.MiscParser.condition) in
            let gpu_read_buffers =
              List.filter (fun (_,_,_,dev,_) -> dev = `Gpu) read_buffers in
            let buf_bytes = "sizeof(uint64_t)*SIZE_OF_TEST" in
            s (Printf.sprintf
                 "// HetLitmus Tier-2 GPU kernel + driver for %s (%s dialect).\n"
                 tname dialect.gd_name) ;
            s "// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
            s "// B3: stores carry the tag K*(_n+1)+mu; loads are recorded into\n" ;
            s "// per-iteration read buffers; a post-run scan decodes rf/init edges\n" ;
            s "// into a het_obs_record (observer ws-edges land in the B3 observer commit).\n" ;
            s dialect.gd_shared_mem_note ;
            s "// a system-scope atomic barrier rendezvouses both sides.\n" ;
            s (Printf.sprintf
                 "// COMPILE-ONLY (%s -c); GPU execution is Task 9.  DO NOT EDIT.\n"
                 (if dialect.gd_ext = "cu" then "nvcc" else "hipcc")) ;
            s (dialect.gd_runtime_include ^ "\n") ;
            s "#include <cstdio>\n#include <cstdint>\n#include <cstdlib>\n" ;
            s "#include <cstring>\n#include <cmath>\n" ;
            s "#include <pthread.h>\n#include <inttypes.h>\n" ;
            (* B4: the ported cuda-litmus stress layer (do_stress / het_spin /
               seeded Park-Miller RNG / scratch-location layout) + every stress
               knob.  A SHARED header, included by both renders, so all reused
               code and its mandatory citations live in one auditable file. *)
            s "#include \"het_stress.cuh\"\n" ;
            (* B5: the CPU + interconnect stress layer.  This side of the header
               is asm-free BY CONSTRUCTION (the bodies are behind
               HET_CPU_STRESS_IMPL, which only <test>_cpu.c defines), so nvcc sees
               only the knobs, the argument structs and the declarations.  It
               self-guards with extern "C", hence outside the block below. *)
            s "#include \"het_cpu_stress.h\"\n" ;
            s "extern \"C\" {\n" ;
            s "#include \"outs.h\"\n" ;
            List.iter
              (fun (proc,_out,_envV,(addr_params,_out_params)) ->
                let ps =
                  String.concat ","
                    (List.map fst
                       (cpu_addr_u64 addr_params @ cpu_bufs proc) @ ["int _n"]) in
                s (Printf.sprintf "  void het_run_P%d(%s);\n" proc ps))
              params ;
            s "}\n" ;
            s {ocaml|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|ocaml} ;
            s (Printf.sprintf "\n#define NPART %d\n" npart) ;
            (* B2/B0: perpetual-loop bounds, Cfg-driven (was the literal 100000).
               SIZE_OF_TEST = free-running inner window; NUMBER_OF_RUN = outer runs. *)
            s (Printf.sprintf "#define SIZE_OF_TEST %d\n" Cfg.size) ;
            s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" Cfg.runs) ;
            s (Printf.sprintf "#define K_TAG %d\n" k_tag) ;
            (* B3c knobs.  HET_WINDOW = the T_L>=2 search radius W: how far the
               partner proc's iteration may drift from the synchrony point decoded
               out of the tag (B3-decision 4.1).  Its VALUE is hardware-tuned (it
               tracks the measured CPU/GPU iteration-rate mismatch, Q2 3.3) and is
               owned by Q7/B8 -- 8 is a placeholder, not a measurement.
               HET_EXHAUSTIVE_MAX caps the O(N^T_L) ground-truth scan so it cannot
               blow up at N=1e6; above it only the windowed heuristic runs, and
               het_obs_record.exhaustive_valid says so.  Both -D-overridable. *)
            s "#ifndef HET_WINDOW\n#define HET_WINDOW 8\n#endif\n" ;
            s "#ifndef HET_EXHAUSTIVE_MAX\n#define HET_EXHAUSTIVE_MAX 4096\n#endif\n\n" ;
            (* ---- B4 stress geometry (per-test; the stress KNOBS themselves are
               in het_stress.cuh).  A het test's GPU side is a handful of lanes:
               HET_TEST_BLOCKS blocks hold the GPU test lane(s) plus (for the 72
               observer tests) the observer lane; every block ABOVE that is a pure
               stressing workgroup.  HET_GPU_LANES counts the lanes that run the
               perpetual loop and therefore signal completion -- the stressers run
               until all of them are done, so stress covers exactly the tested
               window (upstream gets this for free by relaunching per iteration).

               HET_BLOCK_DIM is the launch block size.  The het scope-tree layout
               (CudaLang.layout_of_scopes) gives each GPU proc its OWN block with
               a single lane, so it is 1: a stressing workgroup is ONE thread, and
               the stress population is bounded by the block count alone.  That is
               a real cap on stress intensity (upstream runs 128-thread
               workgroups).  Raising it is an OCCUPANCY-GEOMETRY decision, which
               is hardware-tuned and owned by the tuning task -- the seam is here
               and needs no re-emission: the test lanes are guarded on
               threadIdx.x, so with a larger block dim the extra threads of a
               STRESS block all stress, while test blocks simply idle theirs. *)
            s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
                 block_dim) ;
            s (Printf.sprintf "#define HET_TEST_BLOCKS %d\n"
                 (n_blocks + (if has_observers then 1 else 0))) ;
            s (Printf.sprintf "#define HET_GPU_LANES %d\n"
                 (List.length gpu_prog + (if has_observers then 1 else 0))) ;
            (* HET_SPIN_LANES = the GPU TEST lanes the device-scope window-opener
               aligns.  The observer is excluded on purpose: it runs at its own
               rate and gating the test lanes on it would couple the two.

               Be honest about what this buys per test: most het shapes put a
               SINGLE proc on the GPU, and a barrier over one lane aligns nothing
               -- there it is a self-barrier whose only effect is scratch-word
               traffic (still stress, but not alignment).  It aligns real partners
               only where the shape puts two procs on the GPU.  The CPU-GPU
               alignment is never bought here: it is bought with volume + stress,
               because a per-iteration cross-device barrier would mask the very
               order under test. *)
            s (Printf.sprintf "#define HET_SPIN_LANES %d\n\n"
                 (List.length gpu_prog)) ;
            s (HetCond.het_confidence_enum_c ^ "\n") ;
            (* B3 het_obs_record (B3-decision Decision 5): one per (test,instance,run).
               COMMIT-1 fills N/frames/target/interleavings/distinct/skew from the
               read-buffer scan; observer fields (ws_edges_via_observer,
               observer_unique_count) and control_target_count stay 0 pending the
               observer commit / B6. *)
            s {ocaml|typedef struct het_obs_record {
  const char *test_name; int instance_id; int run_id;
  het_confidence confidence;
  uint64_t N, frames_examined;
  uint64_t target_count_exhaustive, target_count_heuristic;
  /* 0 = the O(N^T_L) exhaustive scan did NOT run at this N (capped by
     HET_EXHAUSTIVE_MAX), so target_count_exhaustive is NOT a count of zero
     observations -- it is "not measured".  B7 must not read it as data. */
  int exhaustive_valid;
  uint64_t interleavings_detected;
  uint64_t distinct_decoded_iters;
  uint64_t ws_edges_via_observer;
  uint64_t observer_unique_count;
  int32_t skew_min, skew_max; double skew_mean, skew_stddev;
  uint64_t control_target_count;
  /* B4-fix STRESS LIVENESS.  The stress layer is invisible to the L0
     faithfulness gate by design, so its health has to be MEASURED at run time or
     it is not known at all (it was inert for two commits and every gate stayed
     green).  spin_rendezvous/spin_cap: how the window-opener's spins ended -- a
     mostly-cap-released spin is a delay loop, not a rendezvous, and B8 tunes
     HET_BARRIER_PCT against this ratio.  stress_truncated: stress lanes that hit
     HET_STRESS_MAX_ROUNDS, i.e. stopped stressing while the test was still
     running -- such a run's non-observations are NOT comparable with a stressed
     run's, so B7 must treat a nonzero value as disqualifying, not cosmetic. */
  uint64_t spin_rendezvous, spin_cap, stress_truncated;
} het_obs_record;
static void het_obs_record_print(FILE* _ch, const het_obs_record* _r){
  fprintf(_ch,
    "HetObs %s inst=%d run=%d conf=%d N=%llu frames=%llu target=%s%llu/%llu "
    "interleavings=%llu distinct_iters=%llu ws_via_obs=%llu obs_unique=%llu "
    "skew=[%d,%d] mean=%.3f sd=%.3f ctrl=%llu "
    "spin=%llu/%llu stress_trunc=%llu\n",
    _r->test_name,_r->instance_id,_r->run_id,(int)_r->confidence,
    (unsigned long long)_r->N,(unsigned long long)_r->frames_examined,
    _r->exhaustive_valid ? "" : "NA:",
    (unsigned long long)_r->target_count_exhaustive,
    (unsigned long long)_r->target_count_heuristic,
    (unsigned long long)_r->interleavings_detected,
    (unsigned long long)_r->distinct_decoded_iters,
    (unsigned long long)_r->ws_edges_via_observer,
    (unsigned long long)_r->observer_unique_count,
    _r->skew_min,_r->skew_max,_r->skew_mean,_r->skew_stddev,
    (unsigned long long)_r->control_target_count,
    (unsigned long long)_r->spin_rendezvous,
    (unsigned long long)_r->spin_cap,
    (unsigned long long)_r->stress_truncated);
}
|ocaml} ;
            (* _decode_value: a store tag -> the ORIGINAL value that write carried
               (0 = init/stale).  Used only to fill the decoded outcome vector for
               the human-readable histogram; the weak-behaviour test itself uses the
               tag arithmetic (mu = tag % K_TAG) directly. *)
            (* [[maybe_unused]]: a store-only test (e.g. 2+2W) has no register
               reads to decode, so this is unreferenced there. *)
            s "[[maybe_unused]] static uint64_t _decode_value(uint64_t _tag){\n" ;
            s "  if (_tag == 0) return 0;\n" ;
            s "  switch (_tag % K_TAG) {\n" ;
            Hashtbl.iter
              (fun mu v -> s (Printf.sprintf "    case %d: return %d;\n" mu v))
              mu_value ;
            s "    default: return 0;\n  }\n}\n\n" ;
            (* kernel: uint64_t globals + GPU read buffers + barrier. *)
            let obsG l = Printf.sprintf "obsG_%s" l in  (* GPU observer buffer (device) *)
            let kparams =
              String.concat ", "
                (List.map (fun g -> Printf.sprintf "uint64_t* %s" g) gpu_globals
                 @ List.map (fun (_,_,name,_,_) -> Printf.sprintf "uint64_t* %s" name)
                     gpu_read_buffers
                 @ List.map (fun l -> Printf.sprintf "uint64_t* %s" (obsG l)) obs_locs
                 @ ["int* barrier"]
                 (* B4: the stress layer's device-only objects.  DISJOINT from
                    every test location by construction, so they perturb the
                    memory system without changing the tested behaviour set.
                    B4-fix: the two access PATTERNS are kernel ARGUMENTS, not
                    -D constants baked into the device code.  Hand het_do_stress
                    a compile-time pattern and nvcc folds its if-chain to the one
                    live branch -- and the tuned default (3 = ld;ld, whose loads
                    only feed a `break') is then provably side-effect-free, so the
                    whole stress loop is DELETED (measured: 0 scratchpad ops in
                    the emitted PTX).  Upstream is immune only because its pattern
                    arrives through a runtime kernel_params pointer.  The -D knobs
                    still drive them -- host-side, below. *)
                 @ ["uint32_t* _scratch" ; "uint32_t* _scratch_loc" ;
                    "uint32_t* _spin_bar" ; "uint32_t* _gpu_done" ;
                    "uint32_t* _stress_tally" ;
                    "uint32_t _seed" ; "uint32_t _pre_pat" ; "uint32_t _mem_pat"]) in
            s (Printf.sprintf "__global__ void litmus_%s(%s) {\n" id kparams) ;
            (* B4: each lane draws from its OWN seeded Park-Miller stream, so the
               probabilistic stress toggles are decided device-side (the perpetual
               kernel has no per-iteration host round-trip to re-roll them) and a
               run replays exactly from its seed (GPUHarbor ISSTA'23). *)
            s "  het_rng_t _rng = het_rng_init(_seed, blockIdx.x * blockDim.x + threadIdx.x);\n" ;
            List.iter
              (fun ((proc,_,_),code) ->
                let blk,lane = layout proc in
                let instrs = CudaLang.instrs_of_code code in
                let regs = CudaLang.result_regs code in
                s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n" blk lane) ;
                (* B2: gd_bar fires ONCE (start rendezvous, outside the loop). *)
                s (dialect.gd_bar "    " "barrier") ;
                List.iter (fun n -> s (Printf.sprintf "    uint64_t r%d = 0;\n" n)) regs ;
                (* FAITHFULNESS: SIZE_OF_TEST is a compile-time constant, so nvcc
                   unrolls this loop ~16x and the emitted PTX carries 16x the tested
                   instructions (33 ld.acquire where the test declares 2) -- the whole
                   het corpus failed the L0 faithfulness gate.  An unrolled body is
                   also a DIFFERENT program microarchitecturally (ILP/scheduling),
                   which perturbs the very timing window the test probes.  Pin the
                   trip count to 1 so the PTX contains exactly the tested sequence per
                   iteration.  Do NOT remove (l0_tokens.sh het lane depends on it). *)
                (* B4-fix: barriers TAKEN by this lane.  It indexes the spin's
                   limit; see the window-opener block below. *)
                s "    uint32_t _nb = 0;\n" ;
                s "    #pragma unroll 1\n" ;
                s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                (* B4 PRE-STRESS (cuda-litmus PRE_STRESS, litmus.cuh:336).  The
                   TESTING thread stresses its OWN L1/pipeline before the litmus
                   body: the disjoint stressing workgroups never touch the testing
                   thread's private hardware, so without this "these testing thread
                   hardware components may not be stressed" (Kirkham OOPSLA'20).
                   Probabilistic per iteration, off the lane's own RNG stream (this
                   toggle MAY stay per-lane: it feeds no shared counter, unlike the
                   barrier below).  Runs INSIDE the loop because one perpetual
                   iteration is what one upstream kernel launch was.  Its scratchpad
                   accesses are plain (non-atomic, unordered) loads/stores on a
                   device-only region, so they add no ordering edge to the test and
                   do not appear in the PTX model-op stream the L0 faithfulness gate
                   checks -- which is why they get their OWN gate
                   (hetlitmus/verify/stresscheck.py): the pattern reaches
                   het_do_stress as a RUNTIME argument (_pre_pat), because a
                   compile-time one is dead-code-eliminated to nothing. *)
                s (Printf.sprintf
                     "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n\
                      \        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat);\n") ;
                (* B4 WINDOW-OPENER (cuda-litmus's `spin', Alglave's
                   thread-synchronisation incantation).  DEVICE scope, on a scratch
                   word that is not a test location: it aligns the GPU test lanes so
                   their critical accesses race, and adds no ordering edge to the
                   test.  It is NOT the cross-device rendezvous -- that is the
                   system-scope gd_bar above, fired ONCE outside this loop.  The two
                   must never merge: a per-iteration CROSS-DEVICE barrier masks the
                   tested order and stalls (Srivastava 4.1).  ptxcheck pins the scope
                   to `gpu' so that regression cannot land silently.

                   ALL-OR-NONE, AND THE LIMIT COUNTS TAKEN BARRIERS (B4-fix).  The
                   loop is perpetual, so the counter cannot be fresh per iteration
                   (upstream relaunches, and so gets that for free); it grows, and
                   the limit must grow with it.  The invariant that makes ANY such
                   limit attainable is Alglave 4.3.4's: wait for "the number of
                   threads PARTICIPATING in the test".  So the roll is drawn from a
                   LANE-INDEPENDENT stream (keyed by the iteration, not the lane):
                   every lane reaches the same verdict for iteration _n, so a barrier
                   is taken by ALL the test lanes or by NONE, each contributes exactly
                   one increment to it, and the counter hits _nb*HET_SPIN_LANES
                   EXACTLY when the last lane arrives.

                   Do NOT roll this from the lane's own stream with an
                   iteration-indexed limit ((_n+1)*lanes): a lane then increments on
                   only HET_BARRIER_PCT% of iterations while the limit rises every
                   iteration, so the counter falls permanently behind, the limit is
                   unreachable after the first skipped roll, and every spin burns the
                   full 1024-spin cap instead of rendezvousing.  That was the shipped
                   behaviour and it aligned nothing (99% cap-released in simulation).
                   The het_spin tally + the HetObs `spin=' field exist so that this
                   cannot silently return: they report rendezvous vs cap exits. *)
                s "      het_rng_t _brng = het_rng_init(_seed ^ 0x9e3779b9u, (uint32_t)_n);\n" ;
                s "      if (het_rng_pct(&_brng, HET_BARRIER_PCT)) {\n" ;
                s "        _nb++;\n" ;
                s "        het_spin(_spin_bar, _nb * HET_SPIN_LANES, _stress_tally);\n" ;
                s "      }\n" ;
                (* B3: tagged stores (mu per store node); loads unchanged, recorded
                   below.  Some(...) also widens the atomic_ref to uint64_t. *)
                let st_ctr = ref 0 in
                List.iter
                  (fun i ->
                    let tag = match i with
                      | BellBase.Pst _ ->
                         let si = !st_ctr in incr st_ctr ;
                         Some (het_iter, k_tag, store_mu proc si)
                      | _ -> Some (het_iter, k_tag, 0) in
                    dialect.gd_dump_instr ch ~tag "      " i)
                  instrs ;
                (* B3: record each load into its per-iteration device buffer
                   (li-th load's dest reg = result_regs[li]). *)
                List.iteri
                  (fun li n ->
                    s (Printf.sprintf "      %s[_n] = (uint64_t)r%d;\n"
                         (buf_name proc li) n))
                  regs ;
                s "    }\n" ;
                (* B4: signal completion so the stressing workgroups stop.  A
                   builtin atomic on a device-only word: scaffolding, not a model
                   op, and it runs AFTER the tested loop. *)
                s "    het_scratch_bump(_gpu_done);\n" ;
                s "  }\n")
              gpu_prog ;
            (* B3 observer: one extra co-resident lane (block n_blocks, thread 0)
               snoops every observed location into its device buffer; joins the
               start barrier.  Analysis-only relaxed sys loads, never the tested
               order.  Its ws stream is scanned host-side for coherence edges. *)
            if has_observers then begin
              s (Printf.sprintf
                   "  if (blockIdx.x == %d && threadIdx.x == 0) {\n" n_blocks) ;
              s (dialect.gd_bar "    " "barrier") ;
              (* FAITHFULNESS: pin the observer's trip count too, so the kernel PTX
                 carries exactly ONE relaxed/sys load per observed location (not
                 nvcc's ~16x unroll).  l0_tokens.sh models the observer lane as a
                 fixed [ld.relaxed.sys] x |obs_locs| segment; an unrolled observer
                 would make that count nondeterministic.  Do NOT remove. *)
              s "    #pragma unroll 1\n" ;
              s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
              List.iter
                (fun l ->
                  s (Printf.sprintf "      %s[_n] = %s;\n"
                       (obsG l) (dialect.gd_sys_load_u64 l)))
                obs_locs ;
              s "    }\n" ;
              (* B4: the observer is a perpetual lane too -- the stressers must
                 not stop while it is still snooping.  No pre-stress here: its job
                 is to SAMPLE the shared locations as densely as it can, and
                 self-stress would only thin the sampling. *)
              s "    het_scratch_bump(_gpu_done);\n" ;
              s "  }\n"
            end ;
            (* ================= B4: pure stressing workgroups =================
               Every block above the test/observer blocks is a stresser: it does
               nothing but hammer the scratchpad for as long as ANY tested lane is
               still looping.  This is cuda-litmus's testing-vs-stressing workgroup
               split (MC Mutants ASPLOS'23 section 4.1) and S&D's occupancy-scaled
               stressing-thread count, and on NVIDIA silicon -- our GH200 target --
               it is the whole reason the campaign can observe anything: "we did not
               observe sb and lb on Titan without this incantation" (Alglave
               ASPLOS'15 4.3.1), Table 6 showing sb/lb at 0 in every column without
               memory stress; S&D went 0/1000 -> 102/1000 on a Tesla K20 by adding
               it.  On AMD the same paper found weak behaviours WITHOUT stress (lb:
               10959/100k with no incantations), so for the .hip render this layer
               is a rate amplifier, not an on/off switch.  See het_stress.cuh's
               VENDOR SPLIT note -- the unqualified claim is a Nvidia-only result.

               The termination condition is the adaptation the perpetual frame
               forces.  Upstream relaunches the kernel per test iteration, so its
               stressers simply end with the launch.  Ours must cover the whole
               free-running window and no longer: they spin on the completion
               counter that each tested lane bumps on its way out.  The round cap
               is only a safety net so a stresser can never outlive a hung lane
               for ever (a silent hang is indistinguishable from a genuine
               non-observation) -- and if it EVER fires it means stress stopped
               while the test was still running, which is not comparable with a
               stressed run, so it is tallied and the host says so.  A stress
               window that silently stopped stressing is exactly the failure this
               commit exists to end.

               Its ops are plain, unordered accesses on a device-only scratchpad
               that is disjoint from every test location: no ordering edge, and
               nothing in the PTX model-op stream (hence stresscheck.py). *)
            s "  if (blockIdx.x >= HET_TEST_BLOCKS) {\n" ;
            s "    uint32_t _s = 0;\n" ;
            s "    for (;\n\
               \         _s < HET_STRESS_MAX_ROUNDS && het_scratch_read(_gpu_done) < HET_GPU_LANES;\n\
               \         ++_s) {\n" ;
            s "      if (het_rng_pct(&_rng, HET_MEM_STRESS_PCT))\n" ;
            s "        het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat);\n" ;
            s "    }\n" ;
            s "    if (_s >= HET_STRESS_MAX_ROUNDS)\n" ;
            s "      het_scratch_bump(&_stress_tally[HET_TALLY_TRUNC]);\n" ;
            s "  }\n" ;
            s "}\n\n" ;
            (* CPU pthread wrappers (arrive at barrier, then run the tagged body).
               Struct carries the uint64_t* globals, the barrier and this proc's
               read-buffer pointers; the loop threads _n into het_run_P. *)
            List.iter
              (fun (proc,_out,_envV,(addr_params,_out_params)) ->
                let addr = cpu_addr_u64 addr_params and bufs = cpu_bufs proc in
                s (Printf.sprintf "struct cpu_args_P%d {\n" proc) ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr ;
                s "  int* barrier;\n" ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) bufs ;
                s "};\n" ;
                s (Printf.sprintf "static void* cpu_thread_P%d(void* _a) {\n" proc) ;
                s (Printf.sprintf "  cpu_args_P%d* a = (cpu_args_P%d*)_a;\n" proc proc) ;
                s (dialect.gd_bar "  " "a->barrier") ;
                let call_args =
                  String.concat ","
                    (List.map (fun (_,a) -> "a->"^a) (addr @ bufs) @ ["_n"]) in
                s (Printf.sprintf
                     "  for (int _n=0; _n<SIZE_OF_TEST; ++_n)\n    het_run_P%d(%s);\n  return NULL;\n}\n\n"
                     proc call_args))
              params ;
            (* B3 observer: one CPU pthread snooping every observed location into
               its host buffer; joins the start barrier.  Plain 64-bit loads
               (analysis-only, not the tested order). *)
            let obsC l = Printf.sprintf "obsC_%s" l in  (* CPU observer buffer (host) *)
            if has_observers then begin
              s "struct cpu_obs_args {\n" ;
              List.iter (fun l -> s (Printf.sprintf "  uint64_t* %s;\n" l)) all_globals ;
              s "  int* barrier;\n" ;
              List.iter (fun l -> s (Printf.sprintf "  uint64_t* %s;\n" (obsC l))) obs_locs ;
              s "};\n" ;
              s "static void* cpu_obs_thread(void* _a) {\n" ;
              s "  cpu_obs_args* a = (cpu_obs_args*)_a;\n" ;
              s (dialect.gd_bar "  " "a->barrier") ;
              s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
              List.iter
                (fun l -> s (Printf.sprintf "    a->%s[_n] = *a->%s;\n" (obsC l) l))
                obs_locs ;
              s "  }\n  return NULL;\n}\n\n"
            end ;
            (* outcome labels + decoded-outcome dump callback (histogram of the
               decoded read values over "hot" frames). *)
            let labelstr =
              String.concat ", "
                (List.map (fun (p,r,_) -> Printf.sprintf "\"%d:%s\"" p r) slots
                 @ List.map (fun (name,_) -> Printf.sprintf "\"[%s]\"" name) loc_slots) in
            s (Printf.sprintf "static const char* _labels[%d] = { %s };\n"
                 (max 1 nslots) labelstr) ;
            s {ocaml|static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
  fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
|ocaml} ;
            s (Printf.sprintf "  for (int i=0;i<%d;i++)" nslots) ;
            s {ocaml| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
  fprintf(_ch, "\n");
}

|ocaml} ;
            s dialect.gd_shared_mem_defs ;
            s "\n" ;
            (* driver *)
            s "int main(void){\n" ;
            (* B1: shared litmus vars (now uint64_t) + barrier via gd_alloc_shared. *)
            List.iter
              (fun g ->
                s (Printf.sprintf
                     "  uint64_t *%s; gd_alloc_shared((void**)&%s, sizeof(uint64_t));\n" g g))
              all_globals ;
            s (Printf.sprintf
                 "  int *barrier; gd_alloc_shared((void**)&barrier, sizeof(int));\n") ;
            (* B3: read buffers -- OFF the coherent race path.  GPU buffers in device
               memory (gd_dev_malloc) + a host mirror "<buf>_h" for the scan; CPU
               buffers host-malloc'd and read in place. *)
            List.iter
              (fun (p,li,name,dev,_g) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  uint64_t *%s; %s\n" name
                        (dialect.gd_dev_malloc name buf_bytes)) ;
                   s (Printf.sprintf
                        "  uint64_t *%s_h = (uint64_t*)malloc_check(%s);\n" name buf_bytes)
                | `Cpu ->
                   ignore p ; ignore li ;
                   s (Printf.sprintf
                        "  uint64_t *%s = (uint64_t*)malloc_check(%s);\n" name buf_bytes))
              read_buffers ;
            (* B3 observer buffers: obsG_<l> device (+ host mirror) / obsC_<l> host. *)
            let obsG l = Printf.sprintf "obsG_%s" l in
            let obsC l = Printf.sprintf "obsC_%s" l in
            List.iter
              (fun l ->
                s (Printf.sprintf "  uint64_t *%s; %s\n" (obsG l)
                     (dialect.gd_dev_malloc (obsG l) buf_bytes)) ;
                s (Printf.sprintf "  uint64_t *%s_h = (uint64_t*)malloc_check(%s);\n"
                     (obsG l) buf_bytes) ;
                s (Printf.sprintf "  uint64_t *%s = (uint64_t*)malloc_check(%s);\n"
                     (obsC l) buf_bytes))
              obs_locs ;
            (* B2: cooperative-launch prelude -- compute the co-resident grid ONCE. *)
            s "  int _coop = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_coop, %s, 0);\n"
                 dialect.gd_dev_attr dialect.gd_attr_coop) ;
            s "  if (!_coop) { fprintf(stderr, \"cooperative launch unsupported on this device\\n\"); return 2; }\n" ;
            s "  int _nsm = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_nsm, %s, 0);\n"
                 dialect.gd_dev_attr dialect.gd_attr_smcount) ;
            s "  int _bpsm = 0;\n" ;
            s (Printf.sprintf "  (void)%s(&_bpsm, litmus_%s, HET_BLOCK_DIM, 0);\n"
                 dialect.gd_occupancy id) ;
            s "  int _maxGrid = _bpsm * _nsm;\n" ;
            (* B2/B3/B4: HET_TEST_BLOCKS holds the GPU test lane(s) + (for the 72)
               the observer lane; the rest of the co-resident grid is filled with
               pure stressing workgroups.  The <= _maxGrid guard is LOAD-BEARING
               and stays: the kernel is persistent and cooperatively launched, so
               an over-large grid must be REJECTED at launch
               (cudaErrorCooperativeLaunchTooLarge) rather than silently deadlock
               on a block that is never scheduled -- and a silent hang is
               indistinguishable from a genuine non-observation.
               HET_STRESS_BLOCKS = -1 (default) means "fill to the cap", which
               lands exactly ON it; an explicit -DHET_STRESS_BLOCKS=n keeps the
               guard live (an over-large n is caught here). *)
            s "  int _testBlocks = HET_TEST_BLOCKS;\n" ;
            s "  int _stressBlocks = (HET_STRESS_BLOCKS >= 0) ? HET_STRESS_BLOCKS\n\
               \                                              : (_maxGrid - _testBlocks);\n" ;
            s "  if (_stressBlocks < 0) _stressBlocks = 0;\n" ;
            s "  int _grid = _testBlocks + _stressBlocks;\n" ;
            s "  if (_grid > _maxGrid) { fprintf(stderr, \"grid %d exceeds co-resident cap %d\\n\", _grid, _maxGrid); return 2; }\n" ;
            (* B4-fix: the access patterns are LAUNCH ARGUMENTS (a compile-time
               pattern is folded away and the stress loop dead-code-eliminated --
               see the kernel-parameter note).  The -D knobs still choose them;
               het_stress.cuh #errors on a value outside 0..3, which is how
               upstream's silent "pattern 57 matches no branch" no-op is refused
               here.  Printed with the geometry so a tuning log records what the
               run actually stressed with. *)
            s "  uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;\n" ;
            s "  uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;\n" ;
            (* Report the realised stress population: the tuning task needs the
               per-test stress-lane count to tune against, and it is a runtime
               property of the device (SM count x resident blocks/SM). *)
            s "  fprintf(stderr, \"HetLitmus: blockDim=%d grid=%d (test=%d stress=%d, co-resident cap=%d) pre_pat=%u mem_pat=%u\\n\",\n\
               \          (int)HET_BLOCK_DIM, _grid, _testBlocks, _stressBlocks, _maxGrid,\n\
               \          _pre_pat, _mem_pat);\n" ;
            (* B4 stress objects: DEVICE memory (gd_dev_malloc), never
               gd_alloc_shared -- they are GPU-only and disjoint from every test
               location, which is exactly what makes the stress sound.  The
               scratch-location layout is chosen host-side per run and copied in. *)
            s (Printf.sprintf "  uint32_t *_scratch; %s\n"
                 (dialect.gd_dev_malloc "_scratch" "sizeof(uint32_t)*HET_SCRATCH_SIZE")) ;
            s (Printf.sprintf "  uint32_t *_scratch_loc; %s\n"
                 (dialect.gd_dev_malloc "_scratch_loc" "sizeof(uint32_t)*_grid")) ;
            s (Printf.sprintf "  uint32_t *_spin_bar; %s\n"
                 (dialect.gd_dev_malloc "_spin_bar" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "  uint32_t *_gpu_done; %s\n"
                 (dialect.gd_dev_malloc "_gpu_done" "sizeof(uint32_t)")) ;
            (* B4-fix: the stress-liveness tally (rendezvous / cap / truncation).
               Device memory like the rest of the scaffolding. *)
            s (Printf.sprintf "  uint32_t *_stress_tally; %s\n"
                 (dialect.gd_dev_malloc "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "  uint32_t _stress_tally_h[HET_TALLY_N];\n" ;
            s "  uint32_t *_scratch_loc_h = (uint32_t*)malloc_check(sizeof(uint32_t)*_grid);\n" ;
            s "  outs_t* hist = NULL;\n" ;
            s "  for (int _run=0; _run<NUMBER_OF_RUN; ++_run) {\n" ;
            List.iter (fun g -> s (Printf.sprintf "    *%s = 0;\n" g)) all_globals ;
            s "    *barrier = 0;\n" ;
            (* B4 per-run stress setup.  Re-rolling the scratch-line layout each
               run keeps the stress non-stationary; seeding both the host rand()
               and the device RNG from (HET_SEED + run) keeps the whole run
               replayable (GPUHarbor's reproducibility discipline). *)
            s "    uint32_t _seed = (uint32_t)(HET_SEED + _run);\n" ;
            s "    srand((unsigned int)_seed);\n" ;
            s "    het_set_scratch_locations(_scratch_loc_h, _grid);\n" ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_memcpy_h2d "_scratch_loc" "_scratch_loc_h"
                    "sizeof(uint32_t)*_grid")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_scratch" "sizeof(uint32_t)*HET_SCRATCH_SIZE")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_spin_bar" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            (* reset read buffers (all N entries are overwritten by the loop, but
               reset keeps unreached tail entries at the init marker 0). *)
            List.iter
              (fun (_,_,name,dev,_) ->
                match dev with
                | `Gpu -> s (Printf.sprintf "    %s\n" (dialect.gd_dev_memset0 name buf_bytes))
                | `Cpu -> s (Printf.sprintf "    memset(%s, 0, %s);\n" name buf_bytes))
              read_buffers ;
            List.iter
              (fun l ->
                s (Printf.sprintf "    %s\n" (dialect.gd_dev_memset0 (obsG l) buf_bytes)) ;
                s (Printf.sprintf "    memset(%s, 0, %s);\n" (obsC l) buf_bytes))
              obs_locs ;
            List.iter
              (fun (proc,_out,_envV,(addr_params,_out_params)) ->
                let addr = cpu_addr_u64 addr_params and bufs = cpu_bufs proc in
                let fields =
                  String.concat ", "
                    (List.map snd addr @ ["barrier"] @ List.map snd bufs) in
                s (Printf.sprintf "    cpu_args_P%d _ca%d = { %s };\n" proc proc fields) ;
                s (Printf.sprintf
                     "    pthread_t _th%d; pthread_create(&_th%d, NULL, cpu_thread_P%d, &_ca%d);\n"
                     proc proc proc proc))
              params ;
            (* B3: launch the CPU observer pthread (fields: all shared globals,
               barrier, then this run's obsC buffers -- matches cpu_obs_args). *)
            if has_observers then begin
              let fields =
                String.concat ", "
                  (all_globals @ ["barrier"] @ List.map obsC obs_locs) in
              s (Printf.sprintf "    cpu_obs_args _cao = { %s };\n" fields) ;
              s "    pthread_t _tho; pthread_create(&_tho, NULL, cpu_obs_thread, &_cao);\n"
            end ;
            (* B2: args[] in KERNEL-PARAM order (gpu_globals @ gpu read buffers @
               [barrier]); each entry is the address of the pointer variable. *)
            let args_addrs =
              String.concat ", "
                (List.map (fun g -> "&"^g) gpu_globals
                 @ List.map (fun (_,_,name,_,_) -> "&"^name) gpu_read_buffers
                 @ List.map (fun l -> "&"^obsG l) obs_locs
                 @ ["&barrier"]
                 @ ["&_scratch" ; "&_scratch_loc" ; "&_spin_bar" ; "&_gpu_done" ;
                    "&_stress_tally" ; "&_seed" ; "&_pre_pat" ; "&_mem_pat"]) in
            s (Printf.sprintf "    void* _args[] = { %s };\n" args_addrs) ;
            s (Printf.sprintf
                 "    %s _e = %s((void*)litmus_%s, dim3(_grid), dim3(HET_BLOCK_DIM), _args, 0, 0);\n"
                 dialect.gd_err_t dialect.gd_coop_launch id) ;
            s (Printf.sprintf
                 "    if (_e != %s) { fprintf(stderr, \"coop launch: %%s\\n\", %s(_e)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            List.iter
              (fun (proc,_,_,_) -> s (Printf.sprintf "    pthread_join(_th%d, NULL);\n" proc))
              params ;
            if has_observers then s "    pthread_join(_tho, NULL);\n" ;
            (* B2: SINGLE terminal sync per run, error-checked. *)
            s (Printf.sprintf "    %s _s = %s\n" dialect.gd_err_t dialect.gd_device_sync) ;
            s (Printf.sprintf
                 "    if (_s != %s) { fprintf(stderr, \"sync: %%s\\n\", %s(_s)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            (* B4-fix: read back the stress-liveness tally and SAY what it says.
               Everything in the stress layer is invisible to the L0 faithfulness
               gate (it is scaffolding, not tested ops), so a stress layer that
               has stopped working looks exactly like one that is working -- which
               is what happened: two mechanisms shipped inert through five green
               gates.  These counters are the only thing that can tell the
               difference at run time.  Printed to stderr AND recorded in the
               HetObs line, because B7 must be able to disqualify a run and B8
               must be able to tune against it. *)
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_memcpy_d2h "_stress_tally_h" "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "    {\n" ;
            s "      unsigned long long _rdv = _stress_tally_h[HET_TALLY_RDV];\n" ;
            s "      unsigned long long _cap = _stress_tally_h[HET_TALLY_CAP];\n" ;
            s "      unsigned long long _spins = _rdv + _cap;\n" ;
            s "      fprintf(stderr, \"HetLitmus stress: spins=%llu rendezvous=%llu cap=%llu (%.1f%% rendezvous)\\n\",\n\
               \              _spins, _rdv, _cap, _spins ? 100.0*(double)_rdv/(double)_spins : 0.0);\n" ;
            (* The window-opener's PURPOSE is the rendezvous; the 1024-spin cap is
               a deadlock guard.  A spin population dominated by cap exits is a
               fixed-length delay loop that aligns nothing -- say so rather than
               let a tuned-looking HET_BARRIER_PCT hide it. *)
            s "      if (_spins && _rdv * 2 < _spins)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: the device-scope window-opener released on the 1024-spin DEADLOCK CAP in %.1f%% of spins -- it is aligning the GPU test lanes weakly or not at all (expect ~0%% cap on a healthy run; see het_stress.cuh het_spin)\\n\",\n\
               \                100.0*(double)_cap/(double)_spins);\n" ;
            s "      if (_stress_tally_h[HET_TALLY_TRUNC])\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u stress lane(s) hit HET_STRESS_MAX_ROUNDS -- stress STOPPED while tested lanes were still running.  This run is NOT a stressed run and its non-observations are not comparable with one.\\n\",\n\
               \                _stress_tally_h[HET_TALLY_TRUNC]);\n" ;
            s "    }\n" ;
            (* B3: mirror GPU device read + observer buffers to the host scan. *)
            List.iter
              (fun (_,_,name,_,_) ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (name^"_h") name buf_bytes)))
              gpu_read_buffers ;
            List.iter
              (fun l ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (obsG l^"_h") (obsG l) buf_bytes)))
              obs_locs ;
            (* ======== B3 recovery scan: read + observer buffers -> het_obs_record.
               Register atoms: rf/fr read-buffer decode.  Reads bind by LOAD NODE,
               not by device, so a CPU read buffer scans exactly like a GPU one
               (B3c).  Each proc gets its own frame, decoded where tags allow: base /
               rf-pinned (_m = tag/K, no search) / windowed (HET_WINDOW) only for a
               reader no rf atom decodes.  Coherence-final [l]=v atoms: the per-run
               observer ws witness _loc (below).  A frame with no decodable synchrony
               point is REFUSED (else a cold run reports 100% weak).  NOTHING is
               HET_PENDING any more -- the emitter Warn.fatals rather than ship a
               constant detector.  See c_tag_of_prop / c_loc. ==== *)
            s "    het_obs_record _rec; memset(&_rec, 0, sizeof _rec);\n" ;
            s (Printf.sprintf
                 "    _rec.test_name = \"%s\"; _rec.instance_id = 0; _rec.run_id = _run;\n"
                 tname) ;
            s (Printf.sprintf "    _rec.confidence = %s;\n"
                 (HetCond.confidence_c_name mech_class)) ;
            s "    _rec.N = SIZE_OF_TEST;\n" ;
            (* B4-fix: the stress layer's own vital signs travel WITH the result --
               a target count from a run whose stress was inert is not the same
               datum as one from a stressed run, and nothing else in this record
               would say so. *)
            s "    _rec.spin_rendezvous = _stress_tally_h[HET_TALLY_RDV];\n" ;
            s "    _rec.spin_cap = _stress_tally_h[HET_TALLY_CAP];\n" ;
            s "    _rec.stress_truncated = _stress_tally_h[HET_TALLY_TRUNC];\n" ;
            (* skew/distinct accumulators only exist when a read buffer decodes a
               synchrony iteration at all (a store-only test -- 2+2W -- has none). *)
            (match sync_src with
             | Some _ ->
                s "    long _skew_sum = 0; double _skew_sq = 0.0; uint64_t _skew_n = 0;\n" ;
                s "    int32_t _skew_lo = INT32_MAX, _skew_hi = INT32_MIN;\n" ;
                s "    uint64_t _prev_m = 0; int _have_prev = 0;\n"
             | None -> ()) ;
            (* B3 observer ws recovery (per run): for each observed location scan
               EACH observer thread's buffer for a ws witness -- an OTHER writer's
               tag appears coherence-before the [l]=v writer's tag (Eq 3.12,
               single O(N) pass).  Kept per device ("_c"/"_g") so _loc's OR honours
               the same-thread constraint (4.3).  guard-2 observer_unique_count =
               min distinct decoded iterations across observer buffers. *)
            if has_observers then begin
              s "    uint64_t _obs_uniq = UINT64_MAX;\n" ;
              List.iter
                (fun l ->
                  List.iter
                    (fun (dev, bufexpr) ->
                      let wsv = ws_var l dev in
                      let muf = match loc_value l with
                        | Some v -> Hashtbl.find_opt value_mu (l,v) | None -> None in
                      let others = match muf with
                        | Some mf -> List.filter (fun m -> m <> mf) (writers_of l)
                        | None -> [] in
                      s (Printf.sprintf "    int %s = 0;\n" wsv) ;
                      (match muf, others with
                       | Some mf, (_::_ as os) ->
                          let seen =
                            String.concat " || "
                              (List.map (Printf.sprintf "_mu == %d") os) in
                          s "    {\n      int _seen = 0;\n" ;
                          s "      for (int _w=0; _w<SIZE_OF_TEST; ++_w) {\n" ;
                          s (Printf.sprintf "        uint64_t _t = %s[_w];\n" bufexpr) ;
                          s "        if (_t != 0) {\n          uint64_t _mu = _t % K_TAG;\n" ;
                          s (Printf.sprintf "          if (%s) _seen = 1;\n" seen) ;
                          s (Printf.sprintf
                               "          if (_mu == %d && _seen) { %s = 1; break; }\n" mf wsv) ;
                          s "        }\n      }\n    }\n"
                       | _ ->
                          s (Printf.sprintf
                               "    /* %s: no competing writer, ws unobservable */\n" wsv)) ;
                      (* guard-2: distinct decoded iterations in this observer buffer *)
                      s "    {\n      uint64_t _u = 0, _pm = 0; int _hp = 0;\n" ;
                      s "      for (int _w=0; _w<SIZE_OF_TEST; ++_w) {\n" ;
                      s (Printf.sprintf "        uint64_t _t = %s[_w];\n" bufexpr) ;
                      s "        if (_t != 0) { uint64_t _mi = _t / K_TAG;\n" ;
                      s "          if (!_hp || _mi != _pm) { _u++; _pm = _mi; _hp = 1; } }\n" ;
                      s "      }\n      if (_u < _obs_uniq) _obs_uniq = _u;\n    }\n")
                    [("c", obsC l); ("g", obsG l ^ "_h")])
                obs_locs ;
              s "    _rec.observer_unique_count = (_obs_uniq == UINT64_MAX) ? 0 : _obs_uniq;\n" ;
              s (Printf.sprintf "    int _loc = %s;\n" loc_expr)
            end ;
            (* B3c: the exhaustive ground-truth scan is O(N^T_L); only run it at a
               small N (HET_EXHAUSTIVE_MAX).  Recorded, so a capped-out run cannot
               be misread as "exhaustively counted zero". *)
            s "    const int _exh = (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX);\n" ;
            s "    _rec.exhaustive_valid = _exh;\n" ;
            s "    for (int _f=0; _f<SIZE_OF_TEST; ++_f) {\n" ;
            s "      _rec.frames_examined++;\n" ;
            (* ---- B3c frame binding, emitted (see the FRAME BINDING block).
               Level-0 pins decode straight off the base proc's buffers; each
               windowed proc then adds a search loop, inside which the pins it in
               turn decodes are (re)assigned. ------------------------------- *)
            let pins_at mode lvl =   (* pinned procs whose decoder sits at level lvl *)
              Hashtbl.fold
                (fun w (q,li) acc ->
                  let qlvl =
                    match Hashtbl.find_opt frame_kind q with
                    | Some `Base -> 0
                    | Some `Win ->
                       1 + (let rec ix i = function
                              | [] -> 0
                              | p::t -> if p=q then i else ix (i+1) t in
                            ix 0 !win_order)
                    | _ -> 0 in
                  if qlvl = lvl then (w,q,li) :: acc else acc)
                pin_src []
              |> List.sort compare
              |> List.map
                   (fun (w,q,li) ->
                     Printf.sprintf "%s = %s / K_TAG;"
                       (mvar mode w) (buf_at mode q li)) in
            let decl_pins mode ind lvl =
              List.iter
                (fun a -> s (Printf.sprintf "%suint64_t %s\n" ind a))
                (pins_at mode lvl) in
            let assign_pins mode ind lvl =
              List.iter (fun a -> s (Printf.sprintf "%s%s\n" ind a)) (pins_at mode lvl) in
            (* window bounds for proc p at nesting level lvl (1-based) *)
            let win_centre mode p =
              match Hashtbl.find_opt win_src p with
              | Some (q,li) ->
                 Printf.sprintf "(long)(%s / K_TAG) - 1" (buf_at mode q li)
              | None -> "(long)_f" in
            let win_guard mode p =
              match Hashtbl.find_opt win_src p with
              | Some (q,li) ->
                 (* No decoded tag = no synchrony point (Eq 3.14) = this frame is
                    not a valid virtual test instance.  Skipping it is what stops
                    an all-init (cold) run from reporting 100% weak behaviours --
                    Srivastava's constant-read degeneracy, 4.4 guard 1. *)
                 Some (Printf.sprintf "%s != 0" (buf_at mode q li))
              | None -> None in
            decl_pins `Heur "      " 0 ;
            (* windowed frame vars live at FRAME scope (the histogram below reads
               them after the search): default = the synchrony centre, overwritten
               by a hit. *)
            List.iteri
              (fun i p ->
                let lvl = i+1 in
                s (Printf.sprintf "      long %s = %s;\n"
                     (tvar `Heur p) (win_centre `Heur p)) ;
                s (Printf.sprintf "      if (%s < 0) %s = 0;\n"
                     (tvar `Heur p) (tvar `Heur p)) ;
                s (Printf.sprintf
                     "      if (%s >= SIZE_OF_TEST) %s = SIZE_OF_TEST-1;\n"
                     (tvar `Heur p) (tvar `Heur p)) ;
                decl_pins `Heur "      " lvl)
              !win_order ;
            s (Printf.sprintf "      int _hot = %s;\n" hot_expr) ;
            s "      if (_hot) _rec.interleavings_detected++;\n" ;
            (* ---- the weak-behaviour detector ---- *)
            (match !win_order with
             | [] ->
                (* T_L<=1 (MP/S/R/2+2W): every frame is decoded exactly; the
                   exhaustive count IS the heuristic count. *)
                s (Printf.sprintf "      int _weak = %s;\n" weak_expr) ;
                s "      if (_weak) { _rec.target_count_exhaustive++; _rec.target_count_heuristic++; }\n"
             | _ ->
                (* T_L>=2: search each unbound reader's window around its decoded
                   synchrony centre (COUNTH), and -- at small N -- the whole range
                   (COUNT, ground truth for calibrating W). *)
                let emit_search mode weakv exhaustive =
                  let ind = ref "      " in
                  let bump () = ind := !ind ^ "  " in
                  List.iteri
                    (fun i p ->
                      let lvl = i+1 in
                      let t = tvar mode p in
                      let c = Printf.sprintf "_c%d%s" p
                                (match mode with `Exh -> "e" | `Heur -> "") in
                      (match win_guard mode p with
                       | Some g ->
                          s (Printf.sprintf "%sif (%s) {\n" !ind g) ; bump ()
                       | None -> s (Printf.sprintf "%s{\n" !ind) ; bump ()) ;
                      if exhaustive then begin
                        s (Printf.sprintf "%slong %s_lo = 0, %s_hi = SIZE_OF_TEST-1;\n"
                             !ind c c)
                      end else begin
                        s (Printf.sprintf "%slong %s = %s;\n" !ind c (win_centre mode p)) ;
                        s (Printf.sprintf
                             "%slong %s_lo = %s - HET_WINDOW, %s_hi = %s + HET_WINDOW;\n"
                             !ind c c c c) ;
                        s (Printf.sprintf "%sif (%s_lo < 0) %s_lo = 0;\n" !ind c c) ;
                        s (Printf.sprintf
                             "%sif (%s_hi > SIZE_OF_TEST-1) %s_hi = SIZE_OF_TEST-1;\n"
                             !ind c c)
                      end ;
                      s (Printf.sprintf
                           "%sfor (%s = %s_lo; %s <= %s_hi && !%s; ++%s) {\n"
                           !ind t c t c weakv t) ;
                      bump () ;
                      assign_pins mode !ind lvl)
                    !win_order ;
                  s (Printf.sprintf "%sif (%s) %s = 1;\n" !ind (cond_at mode) weakv) ;
                  List.iter
                    (fun _ ->
                      ind := String.sub !ind 0 (String.length !ind - 2) ;
                      s (Printf.sprintf "%s}\n" !ind) ;
                      ind := String.sub !ind 0 (String.length !ind - 2) ;
                      s (Printf.sprintf "%s}\n" !ind))
                    !win_order in
                (* the register half, searched *)
                s "      int _rwin = 0;\n" ;
                emit_search `Heur "_rwin" false ;
                (* no hit: leave the frame vars at the synchrony centre so the
                   histogram below reports the decoded partner frame, not the last
                   window step. *)
                List.iteri
                  (fun i p ->
                    let lvl = i+1 in
                    s (Printf.sprintf "      if (!_rwin) {\n        %s = %s;\n"
                         (tvar `Heur p) (win_centre `Heur p)) ;
                    s (Printf.sprintf "        if (%s < 0) %s = 0;\n"
                         (tvar `Heur p) (tvar `Heur p)) ;
                    s (Printf.sprintf
                         "        if (%s >= SIZE_OF_TEST) %s = SIZE_OF_TEST-1;\n"
                         (tvar `Heur p) (tvar `Heur p)) ;
                    assign_pins `Heur "        " lvl ;
                    s "      }\n")
                  !win_order ;
                s (Printf.sprintf "      int _weak = %s;\n"
                     (if has_observers then mk_and ["_rwin"; "_loc"] else "_rwin")) ;
                s "      if (_weak) _rec.target_count_heuristic++;\n" ;
                (* COUNT: the same predicate over the FULL range (ground truth). *)
                s "      int _rex = 0;\n" ;
                s "      if (_exh) {\n" ;
                List.iter
                  (fun p ->
                    s (Printf.sprintf "        long %s = 0;\n" (tvar `Exh p)))
                  !win_order ;
                List.iter
                  (fun a -> s (Printf.sprintf "        uint64_t %s\n" a))
                  (List.concat_map (fun l -> pins_at `Exh l)
                     (List.init (List.length !win_order + 1) (fun i -> i))) ;
                emit_search `Exh "_rex" true ;
                s "      }\n" ;
                s (Printf.sprintf "      int _weak_ex = %s;\n"
                     (if has_observers then mk_and ["_rex"; "_loc"] else "_rex")) ;
                s "      if (_weak_ex) _rec.target_count_exhaustive++;\n") ;
            (* guard 1 (4.4): the synchrony decode must actually VARY.  A read
               buffer that decodes to a constant iteration means the two sides
               never interleaved, and every "weak" frame it produced is spurious
               (Srivastava 4.1: "recorded 100% weak behaviors").  B6/B7 gate on
               distinct_decoded_iters + the skew spread. *)
            (match sync_src with
             | Some (p,li,_,_) ->
                let sb = Printf.sprintf "%s[_f]" (scan_buf p li) in
                s (Printf.sprintf "      if (%s != 0) {\n" sb) ;
                s (Printf.sprintf "        uint64_t _ms = %s / K_TAG;\n" sb) ;
                s "        int32_t _sk = (int32_t)((long)_ms - (long)(_f+1));\n" ;
                s "        _skew_sum += _sk; _skew_sq += (double)_sk*(double)_sk; _skew_n++;\n" ;
                s "        if (_sk < _skew_lo) _skew_lo = _sk; if (_sk > _skew_hi) _skew_hi = _sk;\n" ;
                s "        if (!_have_prev || _ms != _prev_m) { _rec.distinct_decoded_iters++; _prev_m = _ms; _have_prev = 1; }\n" ;
                s "      }\n"
             | None -> ()) ;
            (* Histogram: every frame that is hot OR validated.  "|| _weak" is load
               bearing -- an fr-against-init cycle (R) is weak precisely when its
               read is COLD, so gating on _hot alone would drop exactly the frames
               the test exists to count, and oracle-compare.sh would read the empty
               histogram as "Never" (a spurious confirmation of the model). *)
            s "      if (_hot || _weak) {\n" ;
            s (Printf.sprintf "        intmax_t _o[%d];\n" (max 1 nslots)) ;
            (* Decoded outcome vector, read at each proc's OWN bound frame (B3c) --
               a CPU reader's buffer is decoded exactly like a GPU reader's.
               A PINNED proc's index is (_mP - 1) with _mP a decoded uint64 tag,
               so a cold read (_mP = 0) would underflow it to UINT64_MAX and index
               out of bounds.  The predicate short-circuits on pin_guards; this
               path does not (it runs whenever the frame is _hot), so it needs the
               same range check.  Windowed/base indices are already clamped. *)
            List.iteri
              (fun i (p,r,_) ->
                match read_of p r with
                | Some li ->
                   let e = Printf.sprintf "_decode_value(%s)" (buf_at `Heur p li) in
                   let e =
                     match Hashtbl.find_opt frame_kind p with
                     | Some `Pin ->
                        let v = mvar `Heur p in
                        Printf.sprintf
                          "(%s >= 1 && %s <= (uint64_t)SIZE_OF_TEST) ? %s : 0" v v e
                     | _ -> e in
                   s (Printf.sprintf "        _o[%d] = (intmax_t)(%s);\n" i e)
                | None -> s (Printf.sprintf "        _o[%d] = 0;\n" i))
              slots ;
            List.iteri
              (fun j _ -> s (Printf.sprintf "        _o[%d] = 0;\n" (n_reg+j)))
              loc_slots ;
            s (Printf.sprintf
                 "        hist = add_outcome_outs(hist, _o, %d, 1, _weak);\n" nslots) ;
            s "      }\n" ;
            s "    }\n" ;
            (match sync_src with
             | Some _ ->
                s "    if (_skew_n > 0) {\n" ;
                s "      _rec.skew_min = _skew_lo; _rec.skew_max = _skew_hi;\n" ;
                s "      _rec.skew_mean = (double)_skew_sum / (double)_skew_n;\n" ;
                s "      double _var = (_skew_sq / (double)_skew_n) - _rec.skew_mean*_rec.skew_mean;\n" ;
                s "      _rec.skew_stddev = _var > 0.0 ? sqrt(_var) : 0.0;\n" ;
                s "    }\n"
             | None -> ()) ;
            (* B3: a pure-location (store-only) test's weak result is per-RUN (the
               observer ws witness), not per-frame -- collapse the frame-summed
               target to a 0/1 per-run count, and record one outcome so the
               histogram / oracle-compare parse is non-empty. *)
            if has_observers && read_buffers = [] then begin
              s "    _rec.target_count_exhaustive = _rec.target_count_exhaustive ? 1 : 0;\n" ;
              s "    _rec.target_count_heuristic  = _rec.target_count_heuristic  ? 1 : 0;\n" ;
              s (Printf.sprintf "    { intmax_t _o[%d];\n" (max 1 nslots)) ;
              List.iteri (fun i _ -> s (Printf.sprintf "      _o[%d] = 0;\n" i)) slots ;
              List.iteri (fun j _ -> s (Printf.sprintf "      _o[%d] = 0;\n" (n_reg+j))) loc_slots ;
              s (Printf.sprintf
                   "      hist = add_outcome_outs(hist, _o, %d, 1, _loc); }\n" nslots)
            end ;
            (* ws_edges_via_observer: the weak frames whose ws half was confirmed
               only via an observer buffer (all of them, when observers are used). *)
            if has_observers then
              s "    _rec.ws_edges_via_observer = _rec.target_count_exhaustive;\n" ;
            s "    het_obs_record_print(stdout, &_rec);\n" ;
            s "  }\n" ;
            s (Printf.sprintf "  intmax_t _buff[%d];\n" (max 1 nslots)) ;
            s (Printf.sprintf "  printf(\"Test %s\\n\");\n" tname) ;
            s (Printf.sprintf "  dump_outs(stdout, _dump_one, hist, _buff, %d);\n" nslots) ;
            s "  free_outs(hist);\n" ;
            (* B1: shared vars + barrier free through gd_free_shared (allocator-aware).
               B3: read buffers free through gd_free (device) / free (host mirror + CPU). *)
            List.iter (fun g -> s (Printf.sprintf "  gd_free_shared(%s);\n" g)) all_globals ;
            s "  gd_free_shared(barrier);\n" ;
            List.iter
              (fun (_,_,name,dev,_) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free name) name)
                | `Cpu -> s (Printf.sprintf "  free(%s);\n" name))
              read_buffers ;
            (* B3: observer buffers -- GPU device + host mirror, CPU host. *)
            List.iter
              (fun l ->
                s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free (obsG l)) (obsG l)) ;
                s (Printf.sprintf "  free(%s);\n" (obsC l)))
              obs_locs ;
            (* B4: the stress objects are device memory -> the device free. *)
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch_loc")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_spin_bar")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_gpu_done")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_stress_tally")) ;
            s "  free(_scratch_loc_h);\n" ;
            s "  return 0;\n}\n" in
          (* ---- comp.sh / Makefile / README ---- *)
          let dump_comp ch =
            let s = output_string ch in
            s "#!/bin/sh\n" ;
            s (Printf.sprintf
                 "# Compile-only check for HetLitmus Tier-2 harness '%s'.\n" tname) ;
            s "# COMPILE-ONLY (-c, no link, no GPU run -- execution is Task 9).\n" ;
            s "# Usage: sh comp.sh [cuda|hip]   (default cuda)\n" ;
            s "set -e\n" ;
            s "TARGET=\"${1:-cuda}\"\n" ;
            s "NVCC=\"${NVCC:-nvcc}\" ; CUDA_ARCH=\"${CUDA_ARCH:-sm_90}\"   # GH200=sm_90\n" ;
            s "HIPCC=\"${HIPCC:-hipcc}\" ; HIP_ARCH=\"${HIP_ARCH:-gfx942}\" # MI300A=gfx942\n" ;
            (* shared CPU compile steps *)
            s "echo \"+ gcc -c outs.c\"\ngcc -c outs.c -o outs.o\n" ;
            s (Printf.sprintf
                 "echo \"+ gcc -c %s_cpu.c  (host build; %s asm under #if defined(%s))\"\n"
                 tname CpuF.isa_name CpuF.host_macro) ;
            s (Printf.sprintf "gcc -c %s_cpu.c -o %s_cpu_host.o\n" tname tname) ;
            (match CpuF.cross with
             | Some (triple,std) ->
                s "if command -v clang >/dev/null 2>&1; then\n" ;
                s (Printf.sprintf
                     "  echo \"+ clang --target=%s -c %s_cpu.c  (real %s asm)\"\n"
                     triple tname CpuF.isa_name) ;
                s (Printf.sprintf
                     "  clang --target=%s -std=%s -c %s_cpu.c -o %s_cpu.o\n"
                     triple std tname tname) ;
                s (Printf.sprintf
                     "else\n  echo \"(no clang: skipped %s cross-assembly of %s_cpu.c)\"\nfi\n"
                     CpuF.isa_name tname)
             | None ->
                s (Printf.sprintf
                     "# (%s host == build host: the gcc -c above already assembled the real %s asm)\n"
                     CpuF.isa_name CpuF.isa_name)) ;
            (* GPU step branches by target; hard-fail if the toolchain is absent *)
            s "case \"$TARGET\" in\n" ;
            s "  cuda)\n" ;
            s "    command -v \"$NVCC\" >/dev/null 2>&1 || { echo \"error: $NVCC not found (CUDA toolchain absent)\" >&2 ; exit 1 ; }\n" ;
            s (Printf.sprintf "    echo \"+ $NVCC -std=c++17 -arch=$CUDA_ARCH -c %s.cu\"\n" tname) ;
            s (Printf.sprintf "    $NVCC -std=c++17 -arch=$CUDA_ARCH -c %s.cu -o %s.o ;;\n" tname tname) ;
            s "  hip)\n" ;
            s "    command -v \"$HIPCC\" >/dev/null 2>&1 || { echo \"error: $HIPCC not found (HIP/ROCm toolchain absent)\" >&2 ; exit 1 ; }\n" ;
            s (Printf.sprintf "    echo \"+ $HIPCC --offload-arch=$HIP_ARCH -std=c++17 -c %s.hip\"\n" tname) ;
            s (Printf.sprintf "    $HIPCC --offload-arch=$HIP_ARCH -std=c++17 -c %s.hip -o %s_hip.o ;;\n" tname tname) ;
            s "  *) echo \"usage: sh comp.sh [cuda|hip]\" >&2 ; exit 2 ;;\n" ;
            s "esac\n" ;
            s "echo 'HetLitmus: compile OK'\n" in
          let dump_makefile ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "# HetLitmus Tier-2 harness '%s' -- compile-only (objects; no link/run).\n" tname) ;
            s "NVCC ?= nvcc\nCUDA_ARCH ?= sm_90\nHIPCC ?= hipcc\nHIP_ARCH ?= gfx942\nCC ?= gcc\n\n" ;
            s "all: cuda\n\n" ;
            s (Printf.sprintf "cuda: %s.o outs.o %s_cpu_host.o\n" tname tname) ;
            s (Printf.sprintf "hip: %s_hip.o outs.o %s_cpu_host.o\n\n" tname tname) ;
            s (Printf.sprintf "%s.o: %s.cu\n\t$(NVCC) -std=c++17 -arch=$(CUDA_ARCH) -c $< -o $@\n\n" tname tname) ;
            s (Printf.sprintf "%s_hip.o: %s.hip\n\t$(HIPCC) --offload-arch=$(HIP_ARCH) -std=c++17 -c $< -o $@\n\n" tname tname) ;
            s "outs.o: outs.c\n\t$(CC) -c $< -o $@\n\n" ;
            s (Printf.sprintf "%s_cpu_host.o: %s_cpu.c\n\t$(CC) -c $< -o $@\n\n" tname tname) ;
            s ".PHONY: all cuda hip clean\nclean:\n\trm -f *.o\n" in
          let dump_readme ch =
            let s = output_string ch in
            s (Printf.sprintf "# HetLitmus Tier-2 harness: %s\n\n" tname) ;
            s "Heterogeneous CPU+GPU litmus harness emitted by litmus7 (`Het` arch).\n\n" ;
            s (Printf.sprintf "CPU ISA: %s.  GPU dialects: CUDA (`.cu`) + HIP (`.hip`).\n\n" CpuF.isa_name) ;
            s "Files:\n" ;
            s (Printf.sprintf "- `%s.cu`     GPU kernel + host driver, CUDA dialect (gd_alloc_shared:\n" tname) ;
            s "             system malloc on GH200 / cudaMallocManaged fallback for the shared vars +\n" ;
            s "             barrier, cuda::atomic_ref system-scope barrier, pthread + kernel launch).\n" ;
            s (Printf.sprintf "- `%s.hip`    same harness, HIP dialect (gd_alloc_shared: fine-grained\n" tname) ;
            s "             hipMallocManaged, __hip_atomic_*).\n" ;
            s (Printf.sprintf "- `%s_cpu.c`  CPU thread(s): real %s inline asm (litmus7 ASMLang).\n" tname CpuF.isa_name) ;
            s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
            s "- `comp.sh` / `Makefile`  compile-only build.\n\n" ;
            s "Build (compile-only; no GPU needed): `sh comp.sh [cuda|hip]` (default cuda),\n" ;
            s "or `make cuda` / `make hip`.\n" ;
            s "Targets: NVIDIA GH200 Grace-Hopper (CUDA) and AMD MI300A (HIP).\n" in
          write "outs.h" (fun ch -> output_string ch outs_h_content) ;
          write "outs.c" (fun ch -> output_string ch outs_c_content) ;
          write "het_stress.cuh" (fun ch -> output_string ch het_stress_content) ;
          write "het_cpu_stress.h"
            (fun ch -> output_string ch het_cpu_stress_content) ;
          write (tname ^ "_cpu.c") dump_cpu_file ;
          write (tname ^ ".cu") (dump_gpu_file cuda_dialect) ;
          write (tname ^ ".hip") (dump_gpu_file hip_dialect) ;
          write "comp.sh" dump_comp ;
          write "Makefile" dump_makefile ;
          write "README.md" dump_readme ;
          if OT.verbose >= 0 then
            Printf.eprintf
              "HetLitmus: emitted harness directory %s (%s.cu + %s.hip)\n%!"
              dir tname tname ;
          Absent
        with e -> if OT.nocatch then raise e ; Interrupted e
    end

  let from_chan hash_env name in_chan out_chan =
    (* First split the input file in sections *)
    let { Splitter.arch=arch ; _ } as splitted =
      SP.split name in_chan in
    let tname = splitted.Splitter.name.Name.name in
    if OT.check_name tname then begin
        (* Read variant field in test *)
        let module TestConf =
          TestVariant.Make
            (struct
              module Opt = Variant_litmus
              let info = splitted.Splitter.info
              let variant = OT.variant
              let mte_precision = OT.mte_precision
              let mte_store_only = false
              let fault_handling = OT.fault_handling
              let sve_vector_length = 0
              let sme_vector_length = 0
            end) in
        (* Then call appropriate compiler, depending upon arch *)
        let opt = OT.mkopt (Option.get_default arch) in
        let word = Option.get_word opt in
        let module ODep = struct
            let word = word
            let line = Option.get_line opt
            let delay = Option.get_delay opt
            let gccopts = Option.get_gccopts opt
          end in
        (* Compile configuration, must also be used to configure arch modules *)
        let module OC = struct
          let verbose = OT.verbose
          let word = word
          let syncmacro =OT.syncmacro
          let syncconst = OT.syncconst
          let memory = OT.memory
          let morearch = OT.morearch
          let cautious = OT.cautious
          let asmcomment = OT.asmcomment
          let hexa = OT.hexa
          let mode = OT.mode
          let precision = TestConf.fault_handling
        end in
        let module Cfg = struct
          include GenParser.DefaultConfig
          include OT
          let hash = HashInfo.Std
          let precision = TestConf.fault_handling
          let tagcheck = TestConf.mte_precision
          let variant = TestConf.variant
          include ODep
          let debuglexer = debuglexer
          let sysarch =
            match arch,Archs.get_sysarch arch  OT.carch with
            | `C,`Unknown->
                if not OT.c11 then
                Warn.user_error "Test %s in C not performed, because no option -carch <arch> or -c11 true is present" tname ;
                `Unknown
            | _,a -> a
          let noinline = true
          end in
        let aux = function
          | `PPC ->
             begin match OT.usearch with
             | UseArch.Trad ->
                let module V = Int64Constant.Make(PPCInstr) in
                let module Arch' = PPCArch_litmus.Make(OC)(V) in
                let module LexParse = struct
                    type instruction = Arch'.parsedPseudo
                    type token = PPCParser.token
                    module Lexer = PPCLexer.Make(LexConfig)
                    let lexer = Lexer.token
                    let parser = MiscParser.mach2generic PPCParser.main
                  end in
                let module Compile = PPCCompile_litmus.Make(V)(OC) in
                let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
                X.compile
             | UseArch.Gen ->
                assert false
             (*
  let module Arch' = PPCGenArch.Make(OC)(V) in
  let module LexParse = struct
  type instruction = Arch'.pseudo
  type token = PPCGenParser.token
  module Lexer = PPCGenLexer.Make(LexConfig)
  let lexer = Lexer.token
  let parser = PPCGenParser.main
  end in
  let module Compile = PPCGenCompile.Make(V)(OC) in
  let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
  X.compile
              *)
             end
          | `X86 ->
             let module V = Int32Constant.Make(X86Base.Instr) in
             let module Arch' = X86Arch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = X86Parser.token
                 module Lexer = X86Lexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic X86Parser.main
               end in
             let module Compile = X86Compile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `X86_64 ->
             let module V = Int64Constant.Make(X86_64Base.Instr) in
             let module Arch' = X86_64Arch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = X86_64Parser.token
                 module Lexer = X86_64Lexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic X86_64Parser.main
               end in
             let module X86_64Config = struct
                 let sse =
                   match OT.mode with
                   | Mode.Kvm -> false
                   | Mode.PreSi|Mode.Std -> true
                 let reason = "-mode kvm"
               end in
             let module Compile =
               X86_64Compile_litmus.Make(X86_64Config)(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `ARM ->
             let module V = Int32Constant.Make(ARMInstr) in
             let module Arch' = ARMArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = ARMParser.token
                 module Lexer = ARMLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic ARMParser.main
               end in
             let module Compile = ARMCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `AArch64 ->
             begin match OT.usearch with
             | UseArch.Trad ->
                let module V =
                  SymbConstant.Make
                    (Int64Scalar)(AArch64PteVal)(AArch64AddrReg)
                    (AArch64Instr.Std) in
                let module Arch' = AArch64Arch_litmus.Make(OC)(V) in
                let module LexParse = struct
                  type instruction = Arch'.parsedPseudo
                  type token = AArch64Parser.token
                  module Lexer =
                    AArch64Lexer.Make
                      (struct include LexConfig let is_morello = false end)
                  let lexer = Lexer.token
                  let parser = (*MiscParser.mach2generic*) AArch64Parser.main
                end in
                let module Compile = AArch64Compile_litmus.Make(V)(OC) in
                let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
                X.compile
             | UseArch.Gen ->
                assert false
             end
          | `MIPS ->
             let module V = Int64Constant.Make(MIPSBase.Instr) in
             let module Arch' = MIPSArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.pseudo
                 type token = MIPSParser.token
                 module Lexer = MIPSLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic MIPSParser.main
               end in
             let module Compile = MIPSCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `RISCV ->
             let module V = Int64Constant.Make(RISCVBase.Instr) in
             let module Arch' = RISCVArch_litmus.Make(OC)(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = RISCVParser.token
                 module Lexer = RISCVLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = MiscParser.mach2generic RISCVParser.main
               end in
             let module Compile = RISCVCompile_litmus.Make(V)(OC) in
             let module X = Make(Cfg)(Arch')(LexParse)(Compile) in
             X.compile
          | `C ->
             let module Arch' = struct
                 let comment =  match OT.asmcomment with
                   | Some c -> c
                   | None ->
                      begin match Cfg.sysarch with
                      | `PPC -> PPCArch_litmus.comment
                      | `X86 -> X86Arch_litmus.comment
                      | `X86_64 -> X86_64Arch_litmus.comment
                      | `ARM -> ARMArch_litmus.comment
                      | `AArch64 -> AArch64Arch_litmus.comment
                      | `MIPS -> MIPSArch_litmus.comment
                      | `RISCV -> RISCVArch_litmus.comment
                      | `BPF
                      | `Unknown -> "#"
                      end
               end in
             let module X = Make'(Cfg)(Arch') in
             X.compile
          | `LISA ->
             (* HetLitmus Route B: parse the scoped LISA/Bell test and emit a
                CUDA (.cu) litmus kernel via CudaLang.  litmus7 had no LISA
                path (this branch was `assert false'); GPU codegen reuses the
                Bell scoped IR rather than a native PTX arch.  See memory
                hetlitmus-route-b-frontend. *)
             let module LISAInstr =
               Instr.No(struct type instr = BellBase.instruction end) in
             let module V = Int64Constant.Make(LISAInstr) in
             let module Arch' = LISAArch_litmus.Make(V) in
             let module LexParse = struct
                 type instruction = Arch'.parsedPseudo
                 type token = LISAParser.token
                 module Lexer = BellLexer.Make(LexConfig)
                 let lexer = Lexer.token
                 let parser = LISAParser.main
               end in
             let module P = GenParser.Make(Cfg)(Arch')(LexParse) in
             (fun _hash_env name in_chan _out_chan splitted ->
               try
                 let parsed = P.parse in_chan splitted in
                 close_in in_chan ;
                 let tname = splitted.Splitter.name.Name.name in
                 let outname = Tar.outname (MyName.outname name ".cu") in
                 Misc.output_protect
                   (fun chan -> CudaLang.dump chan tname parsed)
                   outname ;
                 if OT.verbose >= 0 then
                   Printf.eprintf "HetLitmus: emitted CUDA %s\n%!" outname ;
                 (* AMD sibling: emit a HIP (.hip) kernel from the same parsed
                    scoped test (HipLang).  Emit-only -- the hipcc compile is
                    the HIP analog of Task 8, deferred (no ROCm here). *)
                 let hipname = Tar.outname (MyName.outname name ".hip") in
                 Misc.output_protect
                   (fun chan -> HipLang.dump chan tname parsed)
                   hipname ;
                 if OT.verbose >= 0 then
                   Printf.eprintf "HetLitmus: emitted HIP %s\n%!" hipname ;
                 Absent
               with e -> if OT.nocatch then raise e ; Interrupted e)
          | `Het ->
             (* HetLitmus Phase A: the per-column device tag NAMES the CPU ISA.
                Pre-scan the program-section header to pick the ONE CPU ISA the
                test's CPU columns share, instantiate the matching CPU module
                chain (lexer + parser + Arch_litmus + Compile_litmus), and drive
                the shared HetEmit functor.  The GPU side stays LISA/Bell ->
                CudaLang/HipLang; HetEmit dual-emits <t>.cu and <t>.hip from the
                one parse.  All het logic lives here + in litmus/HetArch.ml; see
                hetlitmus/docs/het-emission.md. *)
             (fun hash_env name in_chan out_chan splitted ->
               try
                 let (_,prog_loc,_,_) = splitted.Splitter.locs in
                 let prog_text =
                   let (p1,p2) = prog_loc in
                   let a = p1.Lexing.pos_cnum and b = p2.Lexing.pos_cnum in
                   let ic = open_in_bin name in
                   let len = max 0 (b - a) in
                   seek_in ic a ;
                   let txt = really_input_string ic len in
                   close_in ic ; txt in
                 let run =
                   match HetArch.scan_cpu_isa prog_text with
                   | HetArch.IsaAArch64 ->
                      let module CpuV =
                        SymbConstant.Make
                          (Int64Scalar)(AArch64PteVal)(AArch64AddrReg)
                          (AArch64Instr.Std) in
                      let module Cpu = AArch64Arch_litmus.Make(OC)(CpuV) in
                      let module CpuComp = AArch64Compile_litmus.Make(CpuV)(OC) in
                      let module CpuLexer =
                        AArch64Lexer.Make
                          (struct include LexConfig let is_morello = false end) in
                      let module CpuLP = struct
                          type instruction = Cpu.parsedPseudo
                          type token = AArch64Parser.token
                          let lexer = CpuLexer.token
                          let parser = AArch64Parser.main
                        end in
                      let module CpuF = struct
                          let isa_name = "AArch64"
                          let host_macro = "__aarch64__"
                          let cross = Some ("aarch64-linux-gnu","gnu11")
                          let parse_column p txt =
                            let lexbuf = Lexing.from_string txt in
                            (try AArch64Parser.instr_option_seq CpuLexer.token lexbuf
                             with
                             | Parsing.Parse_error ->
                                Warn.user_error
                                  "HetLitmus: P%d (cpu, AArch64) parse error near offset %d \
                                   of its instruction column %S"
                                  p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
                             | LexMisc.Error (msg,_) ->
                                Warn.user_error
                                  "HetLitmus: P%d (cpu, AArch64) lexing error: %s (in column %S)"
                                  p msg txt)
                          (* B3: real tagged AArch64 body.  Cpu.pseudo =
                             AArch64Base.pseudo here, so HetCpuBody matches
                             directly after peeling. *)
                          let het_analyze ~reg_env pseudos =
                            HetCpuBody.analyze ~reg_env
                              (HetCpuBody.instrs_of_code pseudos)
                          let het_emit_body ch ~proc ~k ~store_mu ~load_buf
                                ~reg_env ~iter ~addr_params ~buf_params pseudos =
                            HetCpuBody.emit_body ch ~proc ~k ~store_mu ~load_buf
                              ~reg_env ~iter ~addr_params ~buf_params
                              (HetCpuBody.instrs_of_code pseudos)
                        end in
                      let module H = HetEmit(Cfg)(Cpu)(CpuComp)(CpuLP)(CpuF) in
                      H.run
                   | HetArch.IsaX86_64 ->
                      let module CpuV = Int64Constant.Make(X86_64Base.Instr) in
                      let module Cpu = X86_64Arch_litmus.Make(OC)(CpuV) in
                      let module X86_64Config = struct
                          let sse =
                            match OT.mode with
                            | Mode.Kvm -> false
                            | Mode.PreSi|Mode.Std -> true
                          let reason = "-mode kvm"
                        end in
                      let module CpuComp =
                        X86_64Compile_litmus.Make(X86_64Config)(CpuV)(OC) in
                      let module CpuLexer = X86_64Lexer.Make(LexConfig) in
                      let module CpuLP = struct
                          type instruction = Cpu.parsedPseudo
                          type token = X86_64Parser.token
                          let lexer = CpuLexer.token
                          let parser = MiscParser.mach2generic X86_64Parser.main
                        end in
                      let module CpuF = struct
                          let isa_name = "X86_64"
                          let host_macro = "__x86_64__"
                          let cross = None
                          let parse_column p txt =
                            let lexbuf = Lexing.from_string txt in
                            (try X86_64Parser.instr_option_seq CpuLexer.token lexbuf
                             with
                             | Parsing.Parse_error ->
                                Warn.user_error
                                  "HetLitmus: P%d (cpu, X86_64) parse error near offset %d \
                                   of its instruction column %S"
                                  p lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum txt
                             | LexMisc.Error (msg,_) ->
                                Warn.user_error
                                  "HetLitmus: P%d (cpu, X86_64) lexing error: %s (in column %S)"
                                  p msg txt)
                          (* B3: x86_64 het body is a compile-only stub (MI300A
                             de-prioritised).  het_analyze reports no tagged
                             stores/loads; het_emit_body emits a no-op body with
                             the matching signature. *)
                          let het_analyze ~reg_env:_ _pseudos = HetCpuBody.empty_plan
                          let het_emit_body ch ~proc ~k:_ ~store_mu:_ ~load_buf:_
                                ~reg_env:_ ~iter:_ ~addr_params ~buf_params _pseudos =
                            HetCpuBody.emit_stub ch ~proc ~addr_params ~buf_params
                        end in
                      let module H = HetEmit(Cfg)(Cpu)(CpuComp)(CpuLP)(CpuF) in
                      H.run in
                 run hash_env name in_chan out_chan splitted
               with e -> if OT.nocatch then raise e ; Interrupted e)
          | `CPP | `JAVA | `ASL | `BPF -> assert false
        in
        aux arch hash_env name in_chan out_chan splitted
      end else begin (* Excluded explicitely, (check_tname), do not warn *)
        Absent
      end

  let from_file hash_env name out_chan =
    Misc.input_protect
      (fun in_chan -> from_chan hash_env name in_chan out_chan)
      name

  (* Call generic tar builder/runner *)
  module DF = DumpRun.Make (OT)(Tar) (struct let from_file = from_file end)

  let from_files = DF.from_files
end
