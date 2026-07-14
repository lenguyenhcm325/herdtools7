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
      (* B5 (Q6 3.2/3.4): the interconnect-stress allocator.  A FOURTH object class
         -- large system buffers HOMED ON THE OTHER processing unit, so that
         stream-reading them crosses the interconnect (Fusco's noise kernels).  It
         is a per-dialect FIELD, not a branch, because the two targets differ in
         KIND: GH200 places (LPDDR/HBM split + cudaMemAdvise), MI300A cannot (one
         HBM pool) and gets its interconnect pressure from cross-chiplet CONTENTION
         instead.  Same threads, same buffers, different physics. *)
      gd_noise_mem_defs : string ;   (* file-scope gd_alloc_noise / gd_free_noise *)
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
/* B5 HALF 2a -- PLACEMENT, the first of the two interconnect-stress levers (Q6 3.2
   steps 1-2).  Pin the shared pages away from the participant that will read them,
   so the tested accesses actually cross NVLink-C2C instead of hitting a local copy.

   WHY IT IS NOT ENOUGH ON ITS OWN, stated here because the temptation to ship (a)
   and call the interconnect stressed is exactly the mistake Fusco's data forbids:
   "Hopper L2 cache can cache data that is physically allocated on HBM, both local
   and peer.  L2 resident peer HBM accesses are faster than local DDR accesses."
   A remote-pinned line that stays L2-resident crosses NOTHING.  Sustained C2C
   traffic comes from the noise pair (Half 2b), and from the test's own coherence
   race; placement tunes the home/PoC and the first-touch latency.  Ship BOTH.

   ACCESS-COUNTER MIGRATION.  SetPreferredLocation alone can be undone by the
   driver's access counters (threshold 256), which migrate a hot page local and
   silence the very traffic we are trying to create; SetAccessedBy on both
   participants is the documented way to hold the mapping.  Whether that SUFFICES on
   a given driver is a HARDWARE question (Q8 open item 5) -- if it does not, the
   fallback is an open-gpu-kernel-module parameter, which needs root at the eval
   site.  Do not assume the pin held; the failure counter below is why.

   DEFAULT IS 0 = FIRST-TOUCH, DELIBERATELY.  That is Bagchi's baseline (plain
   malloc, placement uncontrolled) and it is the honest default, because Q6 3.3
   finds the net effect CONFOUNDED: pinning widens the window but slows the loop, so
   sightings = yield x rate could move either way, and nobody has measured it.  B8
   sweeps HET_PLACE.  Do not promote a non-zero default without hardware evidence.

   A REFUSED cudaMemAdvise is counted, never swallowed: a placement knob that says
   "remote" while the pages sat where first touch left them is an inert mechanism
   reporting itself as live, which is this project's signature bug.  The counter
   itself (_het_place_failures) is declared by the SHARED driver template, not here:
   "how many placement calls were refused" is a dialect-agnostic fact that the
   HetObs record reports on both renders, and only the MECHANISM that increments it
   is CUDA-specific.  Declaring it in this string is what broke the .hip build. */
static void _het_place(void* _p, size_t _bytes, int _where){
  if (_where == 0) return;                  /* first-touch: nothing to advise */
  int _dev = 0;
  int _home = (_where == 1) ? _dev : cudaCpuDeviceId;   /* 1 = HBM, 2 = DDR */
  cudaError_t _e1 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetPreferredLocation, _home);
  cudaError_t _e2 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetAccessedBy, _dev);
  cudaError_t _e3 = cudaMemAdvise(_p, _bytes, cudaMemAdviseSetAccessedBy, cudaCpuDeviceId);
  if (_e1 != cudaSuccess || _e2 != cudaSuccess || _e3 != cudaSuccess) {
    _het_place_failures++;
    fprintf(stderr,
            "HetLitmus WARNING: cudaMemAdvise REFUSED (%s / %s / %s) -- HET_PLACE=%d "
            "did NOT place these pages; they are wherever first touch put them, so "
            "the tested accesses may never cross C2C.  This run is NOT "
            "placement-stressed.\n",
            cudaGetErrorString(_e1), cudaGetErrorString(_e2), cudaGetErrorString(_e3),
            _where);
  }
}
static void gd_alloc_shared(void** _pp, size_t _bytes){
  if (_shared_pageable()) {
    *_pp = malloc(_bytes);   /* GH200: ATS, in-place cache-line CHI coherence */
    _het_place(*_pp, _bytes, HET_PLACE);   /* B5 Half 2a -- see above */
  } else {
    cudaMallocManaged(_pp, _bytes);   /* dev-box / CI fallback only */
    /* No placement here BY DESIGN: without pageable-memory access there is no ATS,
       no C2C and no placement lever at all -- managed memory just page-migrates over
       PCIe.  Advising it would be a no-op that looked like a knob. */
  }
}
static void gd_free_shared(void* _p){
  if (_shared_pageable()) { free(_p); } else { cudaFree(_p); }
}
|ocaml} ;
      gd_noise_mem_defs =
        {ocaml|/* B5 HALF 2b -- the NOISE BUFFERS.  A FOURTH object class, and the four must not
   be confused (each existed as a bug once):

     shared test vars + barrier -> gd_alloc_shared  (coherent; the property under test)
     GPU stress scratchpad      -> cudaMalloc       (device-only, disjoint)
     CPU enemy scratchpad       -> host malloc      (CPU-only, disjoint)
     noise buffers              -> HERE             (system memory homed on the OTHER
                                                     PU, so streaming it crosses C2C)

   Fusco's construction, verbatim: "we develop a Grace and a Hopper noise kernel that
   continuously reads from a large buffer of 8 GB.  To stress the C2C interconnect,
   the Grace noise kernel reads HBM system allocated memory and the Hopper noise
   kernel reads DDR allocated memory."  So BOTH buffers are system-allocated; they
   differ only in where their pages are homed -- which is what `_where' selects.
   Measured effect: "Writes to HBM are the most impacted, with a Grace bandwidth of
   17% and a Hopper bandwidth of 65% of the theoretical maximum."

   Returns 0 = placed, 1 = allocated but NOT interconnect-capable (degraded), -1 =
   failed.  The caller must say which -- a noise buffer that could not be homed
   remotely generates no cross-device traffic, and a run whose interconnect stressor
   is inert must never be reported as an interconnect-stressed run. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  if (!_shared_pageable()) {
    /* Dev box: no ATS, no C2C, no placement lever (Q8 3).  Allocate so the plumbing
       is exercised, but this is NOT interconnect stress and the driver says so. */
    *_pp = NULL;
    if (cudaMallocManaged(_pp, _bytes) != cudaSuccess || *_pp == NULL) return -1;
    het_cpu_first_touch(*_pp, _bytes);   /* managed memory is lazily populated too */
    return 1;
  }
  *_pp = malloc(_bytes);
  if (*_pp == NULL) return -1;
  int _before = _het_place_failures;
  /* ADVISE FIRST, then FAULT THE PAGES IN.  Order matters both ways:

     - the advice must precede the touch, because on GH200 FIRST TOUCH IS WHAT
       PLACES THE PAGE -- advising afterwards would be advising about pages that
       already have a home.

     - and the touch is not optional.  An untouched malloc'd buffer is not backed by
       physical memory at all: Linux maps every untouched anonymous page to ONE
       shared zero page, so reading 8 GB of it would hit a single cache line, be
       served from L1, and generate NO memory traffic and NO C2C traffic whatsoever.
       The noise kernel would run, report healthy round counts, and stress nothing.
       (Measured: reading 1 GiB of untouched malloc'd memory grows RSS by 388 KB;
       first-touching it grows RSS to 1,050,392 KB.)  See het_cpu_first_touch. */
  _het_place(*_pp, _bytes, _where);
  het_cpu_first_touch(*_pp, _bytes);
  /* The CPU did the touching, so the pages are now homed on DDR.  For the buffer
     that is supposed to live on HBM (the one the Grace noise thread streams, so that
     each of its reads CROSSES C2C) the advice alone will not move them -- it is a
     hint, and the pages are already resident.  Prefetch them across, and say so if
     the driver refuses: a "HBM" noise buffer that is really on DDR generates local
     traffic, not interconnect traffic, and the run is not C2C-stressed. */
  if (_where == 1) {
    cudaError_t _e = cudaMemPrefetchAsync(*_pp, _bytes, 0, 0);
    if (_e == cudaSuccess) _e = cudaDeviceSynchronize();
    if (_e != cudaSuccess) {
      _het_place_failures++;
      fprintf(stderr,
              "HetLitmus WARNING: cudaMemPrefetchAsync of the HBM noise buffer FAILED "
              "(%s) -- its pages are still homed where the CPU first touched them "
              "(DDR), so the Grace noise thread is streaming LOCAL memory and crosses "
              "no interconnect.  This run is not C2C-stressed on the Grace side.\n",
              cudaGetErrorString(_e));
    }
  }
  return (_het_place_failures > _before) ? 1 : 0;
}
static void gd_free_noise(void* _p){
  if (_p == NULL) return;
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
  /* B5 Half 2a DOES NOT TRANSFER HERE, and that is a finding, not an omission.
     MI300A has ONE HBM pool shared by the CCD (CPU) and XCD (GPU) chiplets: no
     LPDDR/HBM split, no first-touch home to choose, no cudaMemAdvise-style remote
     pin.  There is nothing to place (Q6 3.4).  The MI300A analogue of the
     interconnect lever is the OTHER half -- CONTENTION -- and that is exactly what
     the Half 2b noise pair does when both sides stream the same coherent pool; see
     gd_alloc_noise below. */
}
static void gd_free_shared(void* _p){
  (void)hipFree(_p);
}
|ocaml} ;
      gd_noise_mem_defs =
        {ocaml|/* B5 HALF 2b -- the NOISE BUFFERS on MI300A.  Same threads, same streaming, same
   disjointness; a DIFFERENT mechanism, because the hardware is different.

   On GH200 the noise crosses the interconnect because each buffer is HOMED on the
   other processing unit (Fusco).  MI300A has a single HBM pool, so there is no
   "other" memory to home it in -- placement does not transfer.  What transfers is
   CROSS-CHIPLET COHERENCE CONTENTION: both sides hammering the same fine-grained-
   coherent region, with a working set that defeats L2 / Infinity-Cache residency,
   keeps the coherence protocol bouncing lines between the CCDs and the XCDs.

   Contention is NECESSARY on MI300A precisely because caching is ALLOWED there.
   Schieffer et al. (arXiv:2410.00801) on the predecessor MI250X: GPU-side caching
   of coherent memory is disabled, so "each access to data located in remote
   coherent memory generates traffic over the CPU-GPU interconnect" -- fabric traffic
   came for free.  But "on more recent systems, such as AMD MI300A, the no-caching
   restriction can be lifted", so per-access traffic is NOT automatic and the lines
   must be kept moving by contention.  Corroborated by arXiv:2508.12743, where
   co-running CPU and GPU atomics on a contended shared array drops CPU throughput
   to 11-25% of baseline.

   hipMallocManaged is fine-grained by default on MI300A, which is the coherence mode
   this needs.  `_where' is accepted and ignored: there is no home to select.
   Returns 0 (no placement step can fail, because there is none) or -1. */
static int gd_alloc_noise(void** _pp, size_t _bytes, int _where){
  (void)_where;
  *_pp = NULL;
  if (hipMallocManaged(_pp, _bytes) != hipSuccess || *_pp == NULL) return -1;
  /* FAULT THE PAGES IN.  Managed memory is lazily populated, and an untouched
     buffer is backed by a single shared zero page -- so streaming 8 GB of it would
     hit ONE cache line, be served from L1, and generate no coherence traffic at all.
     The contention analogue this render depends on needs the lines to EXIST before
     the two chiplets can bounce them.  See het_cpu_first_touch. */
  het_cpu_first_touch(*_pp, _bytes);
  return 0;
}
static void gd_free_noise(void* _p){
  if (_p != NULL) (void)hipFree(_p);
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
            [het_emit_body] emits the tagged het_run_<prefix>P<proc> (K*(_n+1)+mu
            store values from register operands, loads recorded into per-iteration
            buffers, tested mnemonics + DMB SY verbatim).  B6b: [~prefix] is what
            keeps the three co-running instances of a control harness apart --
            without it T's P0 and mu(T)'s P0 are both `het_run_P0'. *)
         val het_analyze :
           reg_env:(string -> string) -> Cpu.pseudo list -> HetCpuBody.cpu_plan
         val het_emit_body :
           out_channel -> prefix:string -> proc:int -> k:int ->
           store_mu:(int -> int) -> load_buf:(int -> string) ->
           reg_env:(string -> string) ->
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
      (* B6: het_obs_record + the null-credibility decision rule.  Shared with the
         verdictcheck unit test so the gate runs the rule that ships. *)
      let het_verdict_content = HetArch.het_verdict_h

      (* ==================== B6b: THE CO-RUN EMITTER =========================
         Q4 2.4 calls the positive control "just another het instance ... No new
         machinery" and 2.3 "essentially free".  Against this emitter that was
         FALSE: it was a SINGLE-INSTANCE emitter, and four things collided the
         moment a second test entered the same translation unit.

           1. K_TAG was one #define per TU -- and it is 3 for MP/SB/LB but 4 for
              R/S (three stores, not two).  The canary is always an MP, so EVERY
              R/S harness mixes K=4 and K=3.  A single K_TAG cannot serve, and a
              tag decoded with the wrong K silently mis-attributes writers and
              iterations: the "recovered" cycles become fiction and no gate would
              say so.  K is therefore PER INSTANCE ([i_kmac]), and every decode
              site spells that instance's macro.
           2. het_run_P<proc> was named from the proc number ALONE, so T's P0 and
              mu(T)'s P0 were both `het_run_P0' -- a duplicate symbol at best, and
              at worst a driver calling the WRONG TEST'S BODY.  Hence ~prefix
              (HetCpuBody), threaded through the extern decl, the arg struct, the
              thread wrapper and the call.
           3. NPART is NOT "2 -> 6".  S and R carry observer lanes, so their NPART
              is 4, not 2, and their co-run harnesses are NPART 10.  Every
              participant count is a SUM over the instances -- a hardcoded 6 lets
              the system-scope rendezvous release before the S/R observers arrive,
              which is a barrier that looks alive and is not.
           4. Three instances = three frame bindings, three detectors, three
              recovery scans, three exhaustive_valid.

         The instance's C identifiers are PREFIXED (t_ / mu_ / can_), and the
         prefix is "" on the single-instance path -- so the 322 non-Disallowed
         harnesses stay byte-for-byte what they were.  Prefixing ALL THREE (rather
         than leaving T bare) is deliberate: a missed prefix then fails to COMPILE
         instead of silently binding to T's object.

         The one thing NOT prefixed is the GPU lane's view of its own locations:
         CudaLang/HipLang name a global by its LISA name (`*x'), and those are
         SHARED backends we may not touch.  So each lane opens with a local alias
         (`uint64_t* x = t_x;'), which binds the emitted `*x' to this instance's
         object with no change to the shared lowering at all. *)

      type dev = [ `Cpu | `Gpu ]
      type mode = [ `Exh | `Heur ]
      type role = RTest | RMu | RCanary

      (* One CPU proc of one instance, pre-digested so the record carries no
         arch-polymorphic type. *)
      type cpu_proc = {
          cp_proc : int ;
          cp_addrs : string list ;       (* ASMLang address params, in ASMLang order *)
          cp_code : Cpu.pseudo list ;
          cp_reg_env : string -> string ;
          cp_nloads : int ;              (* read buffers this proc needs *)
        }

      (* One GPU proc of one instance.  [gp_blk] is the block index WITHIN the
         instance; the composed grid adds the instance's base. *)
      type gpu_proc = {
          gp_proc : int ;
          gp_blk : int ; gp_lane : int ;
          gp_instrs : BellBase.instruction list ;
          gp_regs : int list ;
        }

      type inst = {
          i_role : role ;
          i_pre : string ;               (* C identifier prefix: "" | "t_" | ... *)
          i_kmac : string ;              (* this instance's K macro *)
          i_name : string ;
          i_k : int ;
          i_cpus : cpu_proc list ;
          i_gpus : gpu_proc list ;
          i_store_mu : int -> int -> int ;   (* proc -> store index -> mu *)
          i_gpu_globals : string list ;  (* raw (unprefixed) names *)
          i_all_globals : string list ;  (* raw (unprefixed) names *)
          i_obs_locs : string list ;     (* raw (unprefixed) names *)
          i_obs : bool ;
          i_bdim : int ;
          i_nblocks : int ;              (* GPU test blocks (observer NOT counted) *)
          i_npart : int ;                (* cpu procs + gpu procs + observers *)
          i_blocks : int ;               (* i_nblocks + the observer block *)
          i_lanes : int ;                (* gpu procs + the observer lane *)
          i_spin : int ;                 (* gpu TEST lanes (observer excluded) *)
          (* read buffers: (proc, load idx, PREFIXED name, device, global) *)
          i_bufs : (int * int * string * dev * string) list ;
          i_decode : string ;            (* the _<pre>decode_value fn ("" unless T) *)
          i_scan : string ;              (* the whole pre-rendered recovery scan *)
          i_labels : string ;            (* _labels + _dump_one ("" unless T) *)
          i_nslots : int ;
          i_mech : HetCond.mechanism_class ;
          i_report : HetCond.mechanism_class ;
        }

      (* ---- naming helpers, shared by derive and the emitters ---------------- *)
      (* an identifier that already starts with '_': keep the underscore leading.
         (C++ reserves every identifier CONTAINING a double underscore, so
         "t_" ^ "_decode_value" is not an option.) *)
      let usym pre s =
        if pre = "" then s
        else "_" ^ pre ^ String.sub s 1 (String.length s - 1)
      let buf_name_of pre p li = Printf.sprintf "%sbufP%d_%d" pre p li
      let obsG_of pre l = Printf.sprintf "%sobsG_%s" pre l
      let obsC_of pre l = Printf.sprintf "%sobsC_%s" pre l
      let role_note = function
        | RTest -> "the test under study"
        | RMu -> "Layer A: the minimal mutant mu(T)"
        | RCanary -> "Layer B: the universal het-MP canary"

      let run _hash_env src_name in_chan _out_chan splitted =
        try
          let parsed = P.parse in_chan splitted in
          close_in in_chan ;
          let tname = splitted.Splitter.name.Name.name in
          let doc = splitted.Splitter.name in
          let nprocs_total = List.length parsed.MiscParser.prog in
          (* ================= B6: the positive-control map =====================
             (Q4 2.3/2.4.)  For a should-be-FORBIDDEN test T we co-run mu(T), its
             nearest ALLOWED grid neighbour, so that `target_count = 0' means "not
             observed on a demonstrably hot harness" instead of nothing at all.

             mu(T) is looked up in tests/het/control-map.csv, which sits next to
             the input .litmus and is DERIVED from the corpus sources + the oracle
             by hetlitmus/verify/controlmap.py (gated by `make
             hetlitmus-controlmap').  It is NOT computed here by rewriting T's
             name: the one-sided grid variants are named for the op THE GPU
             performs, and the GPU's role flips with the device cut, so
             MP-gc-sys-acquire / S-gc-sys-acquire / R-gc-sys-acquire DO NOT EXIST
             and a naive `acqrel-2s -> acquire' rewrite would name a nonexistent
             test for 2 of the 16.  A silently-missing control is the worst
             failure available here: the null still prints, still looks green, and
             is now unfalsifiably wrong.

             Absent map => no names, and control_compiled_in stays 0, which makes
             het_verdict() return COLD and SAY SO.  It never quietly proceeds. *)
          let src_dir = Filename.dirname src_name in
          let control_of, canary_of, oracle_of, canary_self_of =
            let tbl = Hashtbl.create 512 in
            let f = Filename.concat src_dir "control-map.csv" in
            (try
               let ch = open_in f in
               (try
                  while true do
                    let line = input_line ch in
                    if String.length line > 0 && line.[0] <> '#' then
                      match String.split_on_char ',' line with
                      (* B6c: `exp' -- field 2, the ORACLE VERDICT -- was bound as
                         `_exp' and DISCARDED.  With it thrown away het_verdict()
                         could not tell a should-be-forbidden test from an
                         oracle-ALLOWED one, so it framed all 338 as forbidden and
                         stood ready to print "the should-be-FORBIDDEN outcome was
                         OBSERVED ... a single sighting REFUTES the model" on the 322
                         where the weak outcome is EXPECTED or the model is SILENT.
                         The oracle was in this file the whole time. *)
                      | t :: exp :: mu :: _muexp :: _rule :: _alt :: _rlx :: can :: _
                           when t <> "Test" ->
                         Hashtbl.replace tbl t (exp, mu, can)
                      | _ -> ()
                  done
                with End_of_file -> ()) ;
               close_in ch
             with Sys_error _ ->
               (* Say it out loud.  Without the map no control is NAMED, and a
                  control nobody can name is a control nobody will notice is
                  missing.  The harness still fails closed (control_compiled_in
                  stays 0 => het_verdict returns COLD), but silence here is how a
                  null quietly becomes unfalsifiable. *)
               if OT.verbose >= 0 then
                 Printf.eprintf
                   "HetLitmus WARNING: no control-map.csv next to %s -- this \
                    harness names NO positive control, so every null it produces \
                    is uninterpretable (het_verdict will return COLD-INVALID).  \
                    Regenerate with hetlitmus/verify/controlmap.py --emit.\n%!"
                   src_name) ;
            (fun t -> match Hashtbl.find_opt tbl t with
                      | Some (_,mu,_) when mu <> "-" -> Some mu
                      | _ -> None),
            (* `self' is NOT a canary to co-run: MP-{cg,gc}-sys-relaxed ARE the
               Layer-B canary and cannot co-run themselves.  They are named below
               (the map's answer to "what vouches for you?" is "I do"), but no
               canary INSTANCE is built for them -- so HET_CANARY_COMPILED_IN is 0
               and het_verdict() correctly refuses to call their nulls anything but
               COLD.  That is not a gap: a canary that did not fire IS a cold
               harness. *)
            (fun t -> match Hashtbl.find_opt tbl t with
                      | Some (_,_,can) when can <> "-" && can <> "self" -> Some can
                      | _ -> None),
            (* B6c: the oracle class -> the C enum in het_verdict.h.  A test absent
               from the map (or a map that would not open) yields ORACLE_UNSET, which
               het_verdict() fails CLOSED on: it prints "this is a BUILD BUG, not a
               result" and claims nothing.  It must never silently default to a
               class, because whichever class it defaulted to would be a lie about
               the other two. *)
            (fun t -> match Hashtbl.find_opt tbl t with
                      | Some ("Disallowed",_,_) -> "ORACLE_DISALLOWED"
                      | Some ("Allowed",_,_)    -> "ORACLE_ALLOWED"
                      | Some ("NO-ORACLE",_,_)  -> "ORACLE_NONE"
                      | _                       -> "ORACLE_UNSET"),
            (* The `self' rows name THEMSELVES.  het_verdict.h tells the DESIGNED
               case (this test IS the canary, so nothing can vouch for it) from the
               BUG case (the canary silently went missing) by comparing canary_name
               with test_name -- so the NAME must be honest even where no canary
               INSTANCE is built. *)
            (fun t -> match Hashtbl.find_opt tbl t with
                      | Some (_,_,"self") -> true
                      | _ -> false) in
          let mu_name = control_of tname
          and canary_name = canary_of tname
          and oracle = oracle_of tname in
          (* What goes in HET_CANARY_NAME / _rec.canary_name.  NOT a co-run signal:
             the map names a canary for all 338, but only 320 co-run one.  The co-run
             is HET_CANARY_COMPILED_IN, set from the instance population. *)
          let canary_named =
            match canary_name with
            | Some _ as c -> c
            | None -> if canary_self_of tname then Some tname else None in

          (* ============ derive ONE instance from a parsed het test =============
             Everything here was `run's body before B6b.  It is now a function of
             (role, prefix, K-macro, name, parse), so the same derivation produces
             T, its minimal mutant and the canary.  The decode function and the
             recovery scan are RENDERED HERE -- they are pure C over host buffers,
             so they need no dialect -- which keeps the record small and the two
             render passes readable. *)
          let derive ~role ~pre ~kmac ~tname ~parsed ~doc =
            (* ---- classify processors by device tag ---- *)
            let dev_of_proc p =
              let rec find = function
                | ((q,annot,_),_)::_ when q=p ->
                   (match annot with Some (d::_) -> d | _ -> "?")
                | _::rest -> find rest
                | [] -> "?" in
              find parsed.MiscParser.prog in
            let is_cpu p = dev_of_proc p = "cpu" in
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
            (* the ASMLang address params of one CPU proc, in ASMLang's order *)
            let cpu_addrs_of out =
              let addrs,_ptes = Cpu.Out.get_addrs out in addrs in
            let params =
              List.map
                (fun (proc,(out,(_outregs,_envV))) -> (proc, out, cpu_addrs_of out))
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
                  List.map (fun n -> (p, Printf.sprintf "r%d" n))
                    (CudaLang.result_regs code))
                gpu_prog in
            let cpu_slots =
              List.concat_map
                (fun (proc,out,_) ->
                  List.map (fun reg -> (proc, Cpu.pp_reg reg)) out.Cpu.Out.final)
                params in
            let slots = cpu_slots @ gpu_slots in
            let n_reg = List.length slots in
            (* ---- shared globals (allocated once, coherent to both) ---- *)
            let cpu_addrs = List.concat_map (fun (_,_,ap) -> ap) params in
            let all_globals =
              let seen = Hashtbl.create 8 in
              List.filter
                (fun g -> if Hashtbl.mem seen g then false
                          else (Hashtbl.add seen g () ; true))
                (cpu_addrs @ gpu_globals) in
            (* ================= B3: K*(_n+1)+mu store-tagging plan ============= *)
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
            let store_mu_tbl = Hashtbl.create 16 in
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
            let value_mu = Hashtbl.create 16 and mu_value = Hashtbl.create 16 in
            let mu_proc = Hashtbl.create 16 in
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
            let proc_store_mu proc g =
              match List.find_opt (fun (p,_,_,_) -> p=proc) proc_infos with
              | Some (_,_,stores,_) ->
                 let rec f i = function
                   | (sg,_)::rest -> if sg=g then Some (store_mu proc i) else f (i+1) rest
                   | [] -> None in
                 f 0 stores
              | None -> None in
            (* Read buffers: one per (load-performing proc, load index), size N. *)
            let read_buffers =
              List.concat_map
                (fun (p,dev,_stores,loads) ->
                  List.mapi
                    (fun li (g,_r) -> (p, li, buf_name_of pre p li, dev, g))
                    loads)
                proc_infos in
            let loads_of p =
              match List.find_opt (fun (q,_,_,_) -> q=p) proc_infos with
              | Some (_,_,_,loads) -> loads | None -> [] in
            let read_of p r =
              let rec f li = function
                | (_,rr)::rest -> if rr = r then Some li else f (li+1) rest
                | [] -> None in
              f 0 (loads_of p) in
            let buf_name p li = buf_name_of pre p li in
            let scan_buf p li =
              let rec f = function
                | (q,l,name,dev,_)::_ when q=p && l=li ->
                   (match dev with `Gpu -> name ^ "_h" | `Cpu -> name)
                | _::rest -> f rest
                | [] -> buf_name p li in
              f read_buffers in
            (* ---- B3 observers (Decision 4/5) ---- *)
            let obs_locs =
              List.filter_map
                (fun g ->
                  let name = MiscParser.dump_value g in
                  if List.mem name all_globals then Some name else None)
                (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
            let has_observers = obs_locs <> [] in
            let writers_of l =
              List.concat_map
                (fun (p,_dev,stores,_loads) ->
                  List.concat
                    (List.mapi
                       (fun si (g,_v) -> if g=l then [store_mu p si] else [])
                       stores))
                proc_infos in
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
            let loc_slots =
              List.filter_map
                (fun g ->
                  let name = MiscParser.dump_value g in
                  if List.mem name all_globals then Some name else None)
                (HetCond.condition_locations (prop_of parsed.MiscParser.condition)) in
            let nslots = n_reg + List.length loc_slots in
            (* ---- condition -> C predicate over the read buffers (B3) ---- *)
            let cval v = ParsedConstant.pp_v v in
            let cint v = int_of_string_opt (ParsedConstant.pp_v v) in
            let read_global pr li =
              let rec f = function
                | (p,l,_,_,g)::_ when p=pr && l=li -> Some g
                | _::rest -> f rest
                | [] -> None in
              f read_buffers in
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
            (* ================== B3c: FRAME BINDING ========================== *)
            let read_atoms =
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
            let frame_kind = Hashtbl.create 8 in
            let pin_src = Hashtbl.create 8 in
            let win_src = Hashtbl.create 8 in
            let bound_by = Hashtbl.create 8 in
            let win_order = ref [] in
            let is_bound p = Hashtbl.mem frame_kind p in
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
            let rf_atom =
              List.find_opt
                (fun (_,_,g,v) -> v <> 0 && Hashtbl.mem value_mu (g,v))
                read_atoms in
            let has_rf_anchor = rf_atom <> None in
            let anchor_atom =
              match rf_atom with
              | Some a -> Some a
              | None -> (match read_atoms with a::_ -> Some a | [] -> None) in
            (match anchor_atom with
             | None -> ()
             | Some (b,_,_,_) ->
                Hashtbl.replace frame_kind b `Base ;
                propagate () ;
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
            let mvar (m:mode) p =
              Printf.sprintf "%s%d" (match m with `Exh -> "_em" | `Heur -> "_m") p in
            let tvar (m:mode) p =
              Printf.sprintf "%s%d" (match m with `Exh -> "_et" | `Heur -> "_t") p in
            let idx_of m p =
              match Hashtbl.find_opt frame_kind p with
              | Some `Base -> "_f"
              | Some `Pin -> Printf.sprintf "(%s - 1)" (mvar m p)
              | Some `Win -> tvar m p
              | None -> "_f" in
            let it_of m p =
              match Hashtbl.find_opt frame_kind p with
              | Some `Base -> "(_f + 1)"
              | Some `Pin -> mvar m p
              | Some `Win -> Printf.sprintf "(%s + 1)" (tvar m p)
              | None -> "0" in
            let buf_at m p li =
              Printf.sprintf "%s[%s]" (scan_buf p li) (idx_of m p) in
            let pin_guards m =
              List.filter_map
                (fun (p,_) ->
                  match Hashtbl.find_opt frame_kind p with
                  | Some `Pin when is_reader p ->
                     let v = mvar m p in
                     Some (Printf.sprintf
                             "(%s >= 1 && %s <= (uint64_t)SIZE_OF_TEST)" v v)
                  | _ -> None)
                (List.map (fun (p,_,_,_) -> (p,())) read_atoms
                 |> List.sort_uniq compare) in
            (* Every tag decode below spells K as THIS INSTANCE's macro [kmac], not
               a TU-wide K_TAG.  With an MP canary (K=3) co-running beside an S test
               (K=4) in one file, a shared K would decode one instance's tags with
               the other's modulus: writer and iteration both come out wrong, the
               "recovered" cycles are fiction, and no structural gate would see it. *)
            let rec c_tag_of_prop m p =
              let open ConstrGen in
              match p with
              | Atom (LV (Loc (MiscParser.Location_reg (pr,r)),v)) ->
                 let li = match read_of pr r with
                   | Some li -> li
                   | None -> assert false in
                 let g = match read_global pr li with
                   | Some g -> g | None -> assert false in
                 let buf = buf_at m pr li in
                 (match cint v with
                  | Some 0 ->
                     (match fr_target pr g with
                      | Some (w,mu) when is_bound w ->
                         Printf.sprintf "(%s < (uint64_t)%s*%s + %d)"
                           buf kmac (it_of m w) mu
                      | _ -> Printf.sprintf "(%s == 0)" buf)
                  | Some n ->
                     (match Hashtbl.find_opt value_mu (g,n) with
                      | Some mu ->
                         let same_iter =
                           match Hashtbl.find_opt mu_proc mu with
                           | Some w when is_bound w
                                         && Hashtbl.find_opt bound_by (pr,li) <> Some w ->
                              Printf.sprintf " && %s / %s == (uint64_t)%s"
                                buf kmac (it_of m w)
                           | _ -> "" in
                         Printf.sprintf "(%s != 0 && %s %% %s == %d%s)"
                           buf buf kmac mu same_iter
                      | None ->
                         Warn.fatal
                           "hetlitmus: condition wants %d:%s=%d but no store writes \
                            %d to %s" pr r n n g)
                  | None -> assert false)
              | Atom (LV (Loc (MiscParser.Location_global g),v)) ->
                 let name = MiscParser.dump_value g in
                 if List.mem name obs_locs then
                   Printf.sprintf "1 /* [%s] via observer _loc */" name
                 else
                   Warn.fatal
                     "hetlitmus: condition observes [%s]=%s but no global backs it \
                      (no observer buffer can be allocated)" name (cval v)
              | Atom _ ->
                 Warn.fatal "hetlitmus: unsupported condition atom (not loc=v)"
              | Not q -> Printf.sprintf "(!%s)" (c_tag_of_prop m q)
              | And ps -> mk_and (List.map (c_tag_of_prop m) ps)
              | Or ps -> mk_or (List.map (c_tag_of_prop m) ps)
              | Implies (a,b) ->
                 Printf.sprintf "(!(%s) || %s)"
                   (c_tag_of_prop m a) (c_tag_of_prop m b) in
            let cond_at m =
              mk_and
                (pin_guards m
                 @ [c_tag_of_prop m (prop_of parsed.MiscParser.condition)]) in
            let cond_expr = cond_at `Heur in
            let ws_var l d = Printf.sprintf "%s_ws_%s_%s" pre l d in
            let rec c_loc d p =
              let open ConstrGen in
              match p with
              | Atom (LV (Loc (MiscParser.Location_reg _),_)) -> "1"
              | Atom (LV (Loc (MiscParser.Location_global g),_)) ->
                 let name = MiscParser.dump_value g in
                 if List.mem name obs_locs then ws_var name d
                 else "0 /* unobservable location */"
              | Atom _ -> "0"
              | Not q -> Printf.sprintf "(!%s)" (c_loc d q)
              | And ps -> mk_and (List.map (c_loc d) ps)
              | Or ps -> mk_or (List.map (c_loc d) ps)
              | Implies (a,b) ->
                 Printf.sprintf "(!(%s) || %s)" (c_loc d a) (c_loc d b) in
            let loc_expr =
              if has_observers then
                mk_or [ c_loc "c" (prop_of parsed.MiscParser.condition) ;
                        c_loc "g" (prop_of parsed.MiscParser.condition) ]
              else "1" in
            let locv = usym pre "_loc" in
            (* B3c HARD INVARIANT (SHARED-CHARGE, "incompleteness is NOT a
               placeholder").  The emitted detector may never be a CONSTANT.  A
               constant-true _weak reports the weak behaviour on every run; a
               constant-false one reports "Never" on every run -- and a spurious
               "Never" on a should-be-forbidden test reads as CONFIRMATION of the
               memory model.  Both silently falsify the science, so refuse to emit
               rather than ship one (this is what B3's HET_PENDING=0 did to 266 of
               the 338 het tests).  Structural, not a test: it cannot regress.

               B6b: it now fires PER INSTANCE, and a constant detector on the
               CONTROL is the same catastrophe wearing a different hat.  A
               constant-FALSE mu(T) is permanently cold, so every null it gates is
               discarded forever; a constant-TRUE one makes every null credible for
               free.  Both look exactly like a working control from outside. *)
            let weak_expr =
              if has_observers then mk_and [cond_expr ; locv] else cond_expr in
            if is_true weak_expr || is_false weak_expr then
              Warn.fatal
                "hetlitmus: %s (%s) would emit a CONSTANT weak-behaviour detector \
                 (_weak = %s) -- refusing to emit (SHARED-CHARGE.md)"
                tname (role_note role) weak_expr ;
            let sync_src =
              List.find_opt
                (fun (p,_,g,_) ->
                  Hashtbl.find_opt frame_kind p = Some `Base && writers_of g <> [])
                read_atoms in
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
            let n_observers = if has_observers then 2 else 0 in
            let mech_class =
              HetCond.perpetual_class (prop_of parsed.MiscParser.condition) in
            let report_class = HetCond.reporting_class ~has_rf_anchor mech_class in
            (* ---------------- the pre-rendered _decode_value ------------------
               Only T feeds the outcome histogram (Q4 3.2: "the control is a
               separate instance, so its outcomes never pollute T's histogram"), so
               only T needs a decoder -- and each decoder is keyed on ITS OWN K. *)
            let decode_fn =
              if role <> RTest then ""
              else begin
                let b = Buffer.create 256 in
                let s = Buffer.add_string b in
                s (Printf.sprintf
                     "[[maybe_unused]] static uint64_t %s(uint64_t _tag){\n"
                     (usym pre "_decode_value")) ;
                s "  if (_tag == 0) return 0;\n" ;
                s (Printf.sprintf "  switch (_tag %% %s) {\n" kmac) ;
                Hashtbl.iter
                  (fun mu v -> s (Printf.sprintf "    case %d: return %d;\n" mu v))
                  mu_value ;
                s "    default: return 0;\n  }\n}\n\n" ;
                Buffer.contents b
              end in
            (* ---------------- the pre-rendered _labels / _dump_one ------------ *)
            let labels =
              if role <> RTest then ""
              else begin
                let b = Buffer.create 256 in
                let s = Buffer.add_string b in
                let labelstr =
                  String.concat ", "
                    (List.map (fun (p,r) -> Printf.sprintf "\"%d:%s\"" p r) slots
                     @ List.map (Printf.sprintf "\"[%s]\"") loc_slots) in
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
                Buffer.contents b
              end in
            (* ================= the pre-rendered RECOVERY SCAN =================
               Pure C over host buffers, so it needs no dialect.  The instance's
               ROLE decides which channel of het_obs_record it feeds:
                 RTest   -> target_count_{exhaustive,heuristic}, interleavings,
                            frames_examined, skew/distinct, observer, the histogram
                 RMu     -> control_target_count / control_frames_examined
                 RCanary -> canary_target_count / canary_frames_examined
               All three are the SAME scan -- "the control is not special-cased, it
               is another instance whose target is tallied by the identical scan"
               (Q4 3.2).  Each carries its own frame binding, its own detector and
               its own exhaustive_valid, because the shapes differ. *)
            let scan =
              let b = Buffer.create 4096 in
              let s = Buffer.add_string b in
              let is_test = role = RTest in
              let frames_field, exh_field = match role with
                | RTest -> "frames_examined", "exhaustive_valid"
                | RMu -> "control_frames_examined", "control_exhaustive_valid"
                | RCanary -> "canary_frames_examined", "canary_exhaustive_valid" in
              (* B7: the control's count and its PER-WINDOW sub-tally are bumped
                 together, on one line, under one predicate -- which is what makes
                 `sum(win[]) == total' an invariant het_stats_compute can check at
                 run time (HET_ST_WIN_DESYNC).  A tally that is only ever checked
                 structurally is a tally that can be dead-code-eliminated and stay
                 green, which is precisely how B4 shipped an inert stress layer. *)
              let count_field = match role with
                | RTest -> None                     (* two channels; see below *)
                | RMu -> Some ("control_target_count", "control_win")
                | RCanary -> Some ("canary_target_count", "canary_win") in
              (* The control channel is the ONLY one windowed: the target is far too
                 rare to estimate a variance from (that is why it needs a bound at
                 all), while the control is the high-rate proxy on the same fabric in
                 the same run (Q3 3.3 job 3). *)
              let bump_count f w =
                Printf.sprintf
                  "      if (_weak) { _rec.%s++; _rec.%s[het_win_of(_f, SIZE_OF_TEST)]++; }\n"
                  f w in
              if pre <> "" then
                s (Printf.sprintf "    /* ---- recovery scan: %s -- %s (K=%d) ---- */\n"
                     tname (role_note role) k_tag) ;
              (* Every scan-local name lives in its own block, so only the BUFFERS
                 (which are main-scope) carry the instance prefix. *)
              if pre <> "" then s "    {\n" ;
              (match sync_src with
               | Some _ when is_test ->
                  s "    long _skew_sum = 0; double _skew_sq = 0.0; uint64_t _skew_n = 0;\n" ;
                  s "    int32_t _skew_lo = INT32_MAX, _skew_hi = INT32_MIN;\n" ;
                  s "    uint64_t _prev_m = 0; int _have_prev = 0;\n"
               | _ -> ()) ;
              (* B3 observer ws recovery (per run). *)
              if has_observers then begin
                s "    uint64_t _obs_uniq = UINT64_MAX;\n" ;
                List.iter
                  (fun l ->
                    List.iter
                      (fun (d, bufexpr) ->
                        let wsv = ws_var l d in
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
                            s (Printf.sprintf
                                 "        if (_t != 0) {\n          uint64_t _mu = _t %% %s;\n"
                                 kmac) ;
                            s (Printf.sprintf "          if (%s) _seen = 1;\n" seen) ;
                            s (Printf.sprintf
                                 "          if (_mu == %d && _seen) { %s = 1; break; }\n" mf wsv) ;
                            s "        }\n      }\n    }\n"
                         | _ ->
                            s (Printf.sprintf
                                 "    /* %s: no competing writer, ws unobservable */\n" wsv)) ;
                        s "    {\n      uint64_t _u = 0, _pm = 0; int _hp = 0;\n" ;
                        s "      for (int _w=0; _w<SIZE_OF_TEST; ++_w) {\n" ;
                        s (Printf.sprintf "        uint64_t _t = %s[_w];\n" bufexpr) ;
                        s (Printf.sprintf
                             "        if (_t != 0) { uint64_t _mi = _t / %s;\n" kmac) ;
                        s "          if (!_hp || _mi != _pm) { _u++; _pm = _mi; _hp = 1; } }\n" ;
                        s "      }\n      if (_u < _obs_uniq) _obs_uniq = _u;\n    }\n")
                      [("c", obsC_of pre l); ("g", obsG_of pre l ^ "_h")])
                  obs_locs ;
                if is_test then begin
                  s "    _rec.observer_unique_count = (_obs_uniq == UINT64_MAX) ? 0 : _obs_uniq;\n" ;
                  (* B7 TRAP 3: this test HAS an observer decode, so the degeneracy
                     guard may read observer_unique_count.  For the 22 store-only
                     (2+2W) shapes this is the ONLY channel there is -- they have no
                     reader, so no synchrony decode, so distinct_decoded_iters and
                     skew_stddev are structurally 0 and a guard that read those would
                     call every one of their cells degenerate forever. *)
                  s "    _rec.obs_valid = 1;\n"
                end else
                  s "    (void)_obs_uniq;  /* the controls report only their target count */\n" ;
                s (Printf.sprintf "    int %s = %s;\n" locv loc_expr)
              end ;
              (* exhaustive_valid -- PER INSTANCE.  T_L<=1: every frame is decoded
                 exactly, so the O(N) scan IS the ground truth at any N.  T_L>=2:
                 only when the O(N^T_L) search actually ran.  (B6a: setting it to
                 (N <= HET_EXHAUSTIVE_MAX) for every test made it 0 on all 338 at
                 the default N, so the rule would have been constant-COLD forever.) *)
              let exhv = usym pre "_exh" in
              let windowed = !win_order <> [] in
              (match windowed with
               | false ->
                  s (Printf.sprintf
                       "    _rec.%s = 1;  /* T_L<=1: the O(N) scan is exact at any N */\n"
                       exh_field)
               | true ->
                  s (Printf.sprintf
                       "    const int %s = (SIZE_OF_TEST <= HET_EXHAUSTIVE_MAX);\n" exhv) ;
                  s (Printf.sprintf
                       "    _rec.%s = %s;  /* T_L>=2: only if the O(N^T_L) search ran */\n"
                       exh_field exhv)) ;
              s "    for (int _f=0; _f<SIZE_OF_TEST; ++_f) {\n" ;
              s (Printf.sprintf "      _rec.%s++;\n" frames_field) ;
              let pins_at m lvl =
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
                       Printf.sprintf "%s = %s / %s;"
                         (mvar m w) (buf_at m q li) kmac) in
              let decl_pins m ind lvl =
                List.iter
                  (fun a -> s (Printf.sprintf "%suint64_t %s\n" ind a))
                  (pins_at m lvl) in
              let assign_pins m ind lvl =
                List.iter (fun a -> s (Printf.sprintf "%s%s\n" ind a)) (pins_at m lvl) in
              let win_centre m p =
                match Hashtbl.find_opt win_src p with
                | Some (q,li) ->
                   Printf.sprintf "(long)(%s / %s) - 1" (buf_at m q li) kmac
                | None -> "(long)_f" in
              let win_guard m p =
                match Hashtbl.find_opt win_src p with
                | Some (q,li) ->
                   Some (Printf.sprintf "%s != 0" (buf_at m q li))
                | None -> None in
              decl_pins `Heur "      " 0 ;
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
              if is_test then begin
                s (Printf.sprintf "      int _hot = %s;\n" hot_expr) ;
                s "      if (_hot) _rec.interleavings_detected++;\n"
              end ;
              (* ---- the weak-behaviour detector ---- *)
              (match windowed with
               | false ->
                  s (Printf.sprintf "      int _weak = %s;\n" weak_expr) ;
                  (match count_field with
                   | None ->
                      s "      if (_weak) { _rec.target_count_exhaustive++; _rec.target_count_heuristic++; }\n"
                   | Some (f,w) -> s (bump_count f w))
               | true ->
                  let emit_search m weakv exhaustive =
                    let ind = ref "      " in
                    let bump () = ind := !ind ^ "  " in
                    List.iteri
                      (fun i p ->
                        let lvl = i+1 in
                        let t = tvar m p in
                        let c = Printf.sprintf "_c%d%s" p
                                  (match m with `Exh -> "e" | `Heur -> "") in
                        (match win_guard m p with
                         | Some g ->
                            s (Printf.sprintf "%sif (%s) {\n" !ind g) ; bump ()
                         | None -> s (Printf.sprintf "%s{\n" !ind) ; bump ()) ;
                        if exhaustive then begin
                          s (Printf.sprintf "%slong %s_lo = 0, %s_hi = SIZE_OF_TEST-1;\n"
                               !ind c c)
                        end else begin
                          s (Printf.sprintf "%slong %s = %s;\n" !ind c (win_centre m p)) ;
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
                        assign_pins m !ind lvl)
                      !win_order ;
                    s (Printf.sprintf "%sif (%s) %s = 1;\n" !ind (cond_at m) weakv) ;
                    List.iter
                      (fun _ ->
                        ind := String.sub !ind 0 (String.length !ind - 2) ;
                        s (Printf.sprintf "%s}\n" !ind) ;
                        ind := String.sub !ind 0 (String.length !ind - 2) ;
                        s (Printf.sprintf "%s}\n" !ind))
                      !win_order in
                  s "      int _rwin = 0;\n" ;
                  emit_search `Heur "_rwin" false ;
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
                       (if has_observers then mk_and ["_rwin"; locv] else "_rwin")) ;
                  (match count_field with
                   | None ->
                      s "      if (_weak) _rec.target_count_heuristic++;\n" ;
                      s "      int _rex = 0;\n" ;
                      s (Printf.sprintf "      if (%s) {\n" exhv) ;
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
                           (if has_observers then mk_and ["_rex"; locv] else "_rex")) ;
                      s "      if (_weak_ex) _rec.target_count_exhaustive++;\n"
                   | Some (f,w) ->
                      (* THE CONTROL'S COUNT MUST BE THE ONE THAT IS ACTUALLY
                         MEASURED AT PRODUCTION N.  mu(SB-*-sys-fence-2s) is
                         SB-*-sys-acqrel-2s -- itself a T_L>=2 shape -- so its
                         exhaustive scan does NOT run at N=100000 (> the
                         HET_EXHAUSTIVE_MAX cap) and its exhaustive count is 0 BY
                         CONSTRUCTION.  Keying the control off that count would make
                         control_target_count structurally zero on 2 of the 16
                         control harnesses, so those nulls would be COLD-INVALID
                         forever: a positive control that CANNOT FIRE is not a
                         control, it is the dead mechanism this task exists to stop.

                         The windowed count is sound for this: the window is a subset
                         of the full range under the SAME predicate, so a windowed hit
                         is a genuine recovered cycle (it can MISS cycles, it cannot
                         invent them).  Under-counting the control errs toward COLD --
                         the safe direction.  control_exhaustive_valid travels with it
                         so a reader can see which kind of count it is. *)
                      s (bump_count f w))) ;
              (* guard 1 (4.4): the synchrony decode must actually VARY. *)
              (match sync_src with
               | Some (p,li,_,_) when is_test ->
                  let sb = Printf.sprintf "%s[_f]" (scan_buf p li) in
                  s (Printf.sprintf "      if (%s != 0) {\n" sb) ;
                  s (Printf.sprintf "        uint64_t _ms = %s / %s;\n" sb kmac) ;
                  s "        int32_t _sk = (int32_t)((long)_ms - (long)(_f+1));\n" ;
                  s "        _skew_sum += _sk; _skew_sq += (double)_sk*(double)_sk; _skew_n++;\n" ;
                  s "        if (_sk < _skew_lo) _skew_lo = _sk; if (_sk > _skew_hi) _skew_hi = _sk;\n" ;
                  s "        if (!_have_prev || _ms != _prev_m) { _rec.distinct_decoded_iters++; _prev_m = _ms; _have_prev = 1; }\n" ;
                  s "      }\n"
               | _ -> ()) ;
              (* Histogram: T only. *)
              if is_test then begin
                s "      if (_hot || _weak) {\n" ;
                s (Printf.sprintf "        intmax_t _o[%d];\n" (max 1 nslots)) ;
                List.iteri
                  (fun i (p,r) ->
                    match read_of p r with
                    | Some li ->
                       let e =
                         Printf.sprintf "%s(%s)" (usym pre "_decode_value")
                           (buf_at `Heur p li) in
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
                s "      }\n"
              end ;
              s "    }\n" ;                                (* end for (_f) *)
              (match sync_src with
               | Some _ when is_test ->
                  (* B7 TRAP 3: this test HAS a synchrony decode, so the degeneracy
                     guard may read distinct_decoded_iters / skew_stddev.  The flag
                     says the fields are POPULATED -- it does not say they are
                     healthy.  Without it a zero could not be told apart from "never
                     measured", which is the exhaustive_valid bug in a new field. *)
                  s "    _rec.sync_valid = 1;\n" ;
                  s "    if (_skew_n > 0) {\n" ;
                  s "      _rec.skew_min = _skew_lo; _rec.skew_max = _skew_hi;\n" ;
                  s "      _rec.skew_mean = (double)_skew_sum / (double)_skew_n;\n" ;
                  s "      double _var = (_skew_sq / (double)_skew_n) - _rec.skew_mean*_rec.skew_mean;\n" ;
                  s "      _rec.skew_stddev = _var > 0.0 ? sqrt(_var) : 0.0;\n" ;
                  s "    }\n"
               | _ -> ()) ;
              (* A pure-location (store-only) test's weak result is per-RUN. *)
              if has_observers && read_buffers = [] then begin
                (match count_field with
                 | None ->
                    s "    _rec.target_count_exhaustive = _rec.target_count_exhaustive ? 1 : 0;\n" ;
                    s "    _rec.target_count_heuristic  = _rec.target_count_heuristic  ? 1 : 0;\n"
                 | Some (f,w) ->
                    (* B7: the per-window stream must collapse WITH the count, or
                       sum(win[]) != total would fire the WIN_DESYNC alarm on a
                       harness that is behaving exactly as designed.  UNREACHABLE in
                       the shipped corpus -- no control is a store-only shape (the
                       canary is always an MP, and none of the 16 mu(T) is a 2+2W) --
                       but an invariant that can misfire is an invariant nobody will
                       trust, and this one is the only run-time evidence that the
                       sub-tallies are alive at all. *)
                    s (Printf.sprintf
                         "    { int _cw, _cf = -1;   /* store-only: the weak result is per-RUN */\n\
                          \      for (_cw = 0; _cw < HET_NWIN; ++_cw)\n\
                          \        if (_rec.%s[_cw]) { _cf = _cw; break; }\n\
                          \      memset(_rec.%s, 0, sizeof _rec.%s);\n\
                          \      if (_cf >= 0) _rec.%s[_cf] = 1; }\n" w w w w) ;
                    s (Printf.sprintf "    _rec.%s = _rec.%s ? 1 : 0;\n" f f)) ;
                if is_test then begin
                  s (Printf.sprintf "    { intmax_t _o[%d];\n" (max 1 nslots)) ;
                  List.iteri (fun i _ -> s (Printf.sprintf "      _o[%d] = 0;\n" i)) slots ;
                  List.iteri (fun j _ -> s (Printf.sprintf "      _o[%d] = 0;\n" (n_reg+j)))
                    loc_slots ;
                  s (Printf.sprintf
                       "      hist = add_outcome_outs(hist, _o, %d, 1, %s); }\n" nslots locv)
                end
              end ;
              if has_observers && is_test then
                s "    _rec.ws_edges_via_observer = _rec.target_count_exhaustive;\n" ;
              if pre <> "" then s "    }\n" ;
              Buffer.contents b in
            let cpus =
              List.map
                (fun (proc,_out,addrs) ->
                  { cp_proc = proc ;
                    cp_addrs = addrs ;
                    cp_code =
                      (match List.find_opt (fun ((p,_,_),_) -> p=proc) cpu_prog with
                       | Some (_,code) -> code | None -> []) ;
                    cp_reg_env = reg_env_of proc ;
                    cp_nloads = List.length (loads_of proc) })
                params in
            let gpus =
              List.map
                (fun ((p,_,_),code) ->
                  let blk,lane = layout p in
                  { gp_proc = p ; gp_blk = blk ; gp_lane = lane ;
                    gp_instrs = CudaLang.instrs_of_code code ;
                    gp_regs = CudaLang.result_regs code })
                gpu_prog in
            { i_role = role ; i_pre = pre ; i_kmac = kmac ; i_name = tname ;
              i_k = k_tag ;
              i_cpus = cpus ; i_gpus = gpus ; i_store_mu = store_mu ;
              i_gpu_globals = gpu_globals ; i_all_globals = all_globals ;
              i_obs_locs = obs_locs ; i_obs = has_observers ;
              i_bdim = block_dim ; i_nblocks = n_blocks ;
              i_npart = List.length params + List.length gpu_prog + n_observers ;
              i_blocks = n_blocks + (if has_observers then 1 else 0) ;
              i_lanes = List.length gpu_prog + (if has_observers then 1 else 0) ;
              i_spin = List.length gpu_prog ;
              i_bufs = read_buffers ;
              i_decode = decode_fn ; i_scan = scan ; i_labels = labels ;
              i_nslots = nslots ;
              i_mech = mech_class ; i_report = report_class ; } in

          (* ---- parse a sibling corpus test (mu(T) / the canary) -------------- *)
          let parse_sibling name =
            let f = Filename.concat src_dir (name ^ ".litmus") in
            if not (Sys.file_exists f) then
              Warn.fatal
                "hetlitmus: %s names the control %s, but %s does not exist.  A \
                 control that cannot be BUILT cannot vouch for anything, and a \
                 harness that silently drops it turns its null into an \
                 unfalsifiable claim -- regenerate control-map.csv \
                 (hetlitmus/verify/controlmap.py --emit)."
                tname name f ;
            let ch = open_in f in
            let sp = SP.split f ch in
            let p = P.parse ch sp in
            close_in ch ;
            (p, sp.Splitter.name) in

          (* ================= the instance population ==========================
             A should-be-FORBIDDEN test (the only kind for which control-map.csv
             names a mu) becomes a THREE-instance harness: T + mu(T) + the canary,
             in the SAME launch, under the SAME stress, on the SAME C2C path, on
             disjoint cache-line-padded locations.

             B6c: EVERY OTHER TEST NOW CO-RUNS THE CANARY TOO (T + canary), which is
             Q4 R5 and the incompleteness B6b reported.  Without it a non-firing test
             is exactly as uninterpretable as a bare "Never": there is no way to tell
             "the harness was hot and this behaviour did not surface" (an
             OBSERVABILITY result -- Iorga's taxonomy, Alglave's GTX-280 honesty)
             from "the harness was dead" (no result at all).  The 36 NO-ORACLE rows
             need it to be reportable AS ANYTHING (Q4 R5: characterization against a
             demonstrably-hot harness); the 286 Allowed rows need it to distinguish
             ALLOWED-UNOBSERVED from COLD-INVALID.

             Only Layer A is absent from them, and necessarily so: a mutant
             presupposes a known-forbidden cycle to weaken (MC-Mutants 1.2), which is
             exactly what a non-Disallowed row does not have.

             The two `self' rows (MP-{cg,gc}-sys-relaxed) ARE the canary and cannot
             co-run themselves; they stay single-instance, prefix "", byte-for-byte
             what they were. *)
          let insts =
            match mu_name, canary_name with
            | Some m, Some c ->
               let (mp,mdoc) = parse_sibling m
               and (cp,cdoc) = parse_sibling c in
               [ derive ~role:RTest ~pre:"t_" ~kmac:"T_K_TAG" ~tname ~parsed ~doc ;
                 derive ~role:RMu ~pre:"mu_" ~kmac:"MU_K_TAG"
                   ~tname:m ~parsed:mp ~doc:mdoc ;
                 derive ~role:RCanary ~pre:"can_" ~kmac:"CAN_K_TAG"
                   ~tname:c ~parsed:cp ~doc:cdoc ]
            | None, Some c ->
               let (cp,cdoc) = parse_sibling c in
               [ derive ~role:RTest ~pre:"t_" ~kmac:"T_K_TAG" ~tname ~parsed ~doc ;
                 derive ~role:RCanary ~pre:"can_" ~kmac:"CAN_K_TAG"
                   ~tname:c ~parsed:cp ~doc:cdoc ]
            | _ -> [ derive ~role:RTest ~pre:"" ~kmac:"K_TAG" ~tname ~parsed ~doc ] in
          let co_run = List.length insts > 1 in
          (* THE TWO FLAGS ARE NOT THE SAME CLAIM, and collapsing them is how a null
             on a test with no mutant would start reading as vouched-for.  They are
             computed from the emitted instance POPULATION -- never from the map,
             which NAMES a canary for all 338 while only 320 co-run one. *)
          let has_mu = List.exists (fun i -> i.i_role = RMu) insts
          and has_canary = List.exists (fun i -> i.i_role = RCanary) insts in
          let it = List.hd insts in            (* the test under study *)
          (* Composed geometry -- every participant count is a SUM over instances. *)
          let npart = List.fold_left (fun a i -> a + i.i_npart) 0 insts in
          let test_blocks = List.fold_left (fun a i -> a + i.i_blocks) 0 insts in
          let gpu_lanes = List.fold_left (fun a i -> a + i.i_lanes) 0 insts in
          let spin_lanes = List.fold_left (fun a i -> a + i.i_spin) 0 insts in
          let block_dim = List.fold_left (fun a i -> max a i.i_bdim) 1 insts in
          (* each instance's block base in the composed grid *)
          let bases =
            let _,acc =
              List.fold_left
                (fun (b,acc) i -> (b + i.i_blocks, (i.i_pre, b) :: acc))
                (0,[]) insts in
            List.rev acc in
          let base_of i = List.assoc i.i_pre bases in
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
              parsed.MiscParser.prog ;
            if co_run then begin
              List.iter
                (fun i ->
                  if i.i_role <> RTest then
                    Printf.eprintf
                      "  co-run %-6s %-22s K=%d  +%d part  +%d blk  +%d lane\n%!"
                      (match i.i_role with
                       | RMu -> "mu(T)" | RCanary -> "canary" | RTest -> "")
                      i.i_name i.i_k i.i_npart i.i_blocks i.i_lanes)
                insts ;
              Printf.eprintf
                "  => NPART=%d HET_TEST_BLOCKS=%d HET_GPU_LANES=%d HET_SPIN_LANES=%d, \
                 HET_CONTROL_COMPILED_IN=%d HET_CANARY_COMPILED_IN=%d (oracle: %s)\n%!"
                npart test_blocks gpu_lanes spin_lanes
                (if has_mu then 1 else 0) (if has_canary then 1 else 0) oracle
            end
          end ;
          let het_iter = "(_n + 1)" in
          let id = CudaLang.c_ident tname in
          (* ================= file emission ================= *)
          let base =
            if OT.is_out && (try Sys.is_directory OT.tarname with _ -> false)
            then OT.tarname else Sys.getcwd () in
          let dir = Filename.concat base tname in
          if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
          let write fname f =
            Misc.output_protect f (Filename.concat dir fname) in
          (* B3 het-CPU signature helpers, SHARED by _cpu.c (the body), the .cu
             extern decl, the cpu_args struct and the driver call, so all four stay
             consistent (addresses widened to uint64_t*; one buffer pointer per CPU
             load; trailing int _n). *)
          let cpu_addr_u64 cp =
            List.map (fun n -> (Printf.sprintf "uint64_t *%s" n, n)) cp.cp_addrs in
          let cpu_bufs i cp =
            List.init cp.cp_nloads
              (fun li ->
                let b = buf_name_of i.i_pre cp.cp_proc li in
                (Printf.sprintf "uint64_t *%s" b, b)) in
          let cpu_sig i cp =
            String.concat ","
              (List.map fst (cpu_addr_u64 cp @ cpu_bufs i cp) @ ["int _n"]) in
          let gsym i g = i.i_pre ^ g in     (* this instance's copy of global [g] *)
          (* ---- <tname>_cpu.c : the CPU threads (real ISA asm) ---- *)
          let dump_cpu_file ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "/* HetLitmus Tier-2: TAGGED CPU threads for %s (%s).\n   \
                  Bodies emitted by HetLitmus hetCpuBody (B3 Decision 1): the\n   \
                  tested mnemonics verbatim, store values rebound to the per-\n   \
                  iteration tag K*(_n+1)+mu, loads recorded into buffers.\n   \
                  DO NOT EDIT. */\n"
                 tname CpuF.isa_name) ;
            if co_run then
              s (Printf.sprintf
                   "/* B6b CO-RUN: this file carries the CPU threads of THREE het\n   \
                    instances, so every body is named het_run_<prefix>P<proc> and\n   \
                    each keeps its OWN K:\n     \
                    %s\n   \
                    A shared K would decode one instance's tags with another's\n   \
                    modulus -- wrong writer, wrong iteration, fictional cycles. */\n"
                   (String.concat "\n     "
                      (List.map
                         (fun i ->
                           Printf.sprintf "%-6s %-22s K=%d"
                             (match i.i_role with
                              | RTest -> "T" | RMu -> "mu(T)" | RCanary -> "canary")
                             i.i_name i.i_k)
                         insts))) ;
            (* B5: _GNU_SOURCE must precede EVERY libc header -- het_cpu_stress.h
               needs cpu_set_t / sched_setaffinity (M6 affinity), which glibc hides
               behind it.  Defining it after <stdint.h> would be too late. *)
            s "#define _GNU_SOURCE\n" ;
            s "#include <stdint.h>\n\n" ;
            (* B5: THIS translation unit -- and only this one -- compiles the CPU
               stress bodies.  It is built by gcc for the host and by
               `clang --target=aarch64-linux-gnu' for the real AArch64 asm, so it is
               the one place the host-ISA cache primitives can live; nvcc compiles
               the .cu and must never see them. *)
            s "#define HET_CPU_STRESS_IMPL\n" ;
            s "#include \"het_cpu_stress.h\"\n\n" ;
            s (Printf.sprintf "#if defined(%s)\n" CpuF.host_macro) ;
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    CpuF.het_emit_body ch ~prefix:i.i_pre ~proc:cp.cp_proc ~k:i.i_k
                      ~store_mu:(i.i_store_mu cp.cp_proc)
                      ~load_buf:(fun li -> buf_name_of i.i_pre cp.cp_proc li)
                      ~reg_env:cp.cp_reg_env
                      ~iter:het_iter
                      ~addr_params:(cpu_addr_u64 cp)
                      ~buf_params:(cpu_bufs i cp)
                      cp.cp_code)
                  i.i_cpus)
              insts ;
            s "#else\n" ;
            s (Printf.sprintf
                 "/* Portable shim so the harness also compiles on a host whose\n   \
                  ISA is not %s.  NOT the tested path -- the %s tagged asm above\n   \
                  is the real CPU thread; build on %s (or cross-assemble). */\n"
                 CpuF.isa_name CpuF.isa_name CpuF.isa_name) ;
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    let addr = cpu_addr_u64 cp and bufs = cpu_bufs i cp in
                    s (Printf.sprintf "void het_run_%sP%d(%s) {\n"
                         i.i_pre cp.cp_proc (cpu_sig i cp)) ;
                    s "  (void)_n;\n" ;
                    List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n)) addr ;
                    List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n)) bufs ;
                    s "}\n")
                  i.i_cpus)
              insts ;
            s "#endif\n" in
          (* ---- <tname>.{cu,hip} : GPU kernel + driver (per dialect) ---- *)
          let dump_gpu_file dialect ch =
            let s = output_string ch in
            let buf_bytes = "sizeof(uint64_t)*SIZE_OF_TEST" in
            let gpu_bufs i =
              List.filter (fun (_,_,_,dev,_) -> dev = `Gpu) i.i_bufs in
            s (Printf.sprintf
                 "// HetLitmus Tier-2 GPU kernel + driver for %s (%s dialect).\n"
                 tname dialect.gd_name) ;
            s "// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
            s "// B3: stores carry the tag K*(_n+1)+mu; loads are recorded into\n" ;
            s "// per-iteration read buffers; a post-run scan decodes rf/init edges\n" ;
            s "// into a het_obs_record (observer ws-edges land in the B3 observer commit).\n" ;
            if co_run then begin
              s "//\n// B6b/B6c THE POSITIVE CONTROL IS CO-RUNNING IN THIS HARNESS.\n" ;
              s (Printf.sprintf
                   "// %d het instances share this launch, this stress config and this\n"
                   (List.length insts)) ;
              s "// C2C path, on disjoint cache-line-padded locations:\n" ;
              List.iter
                (fun i ->
                  s (Printf.sprintf "//   %-6s %-22s prefix %-5s K=%d  %s\n"
                       (match i.i_role with
                        | RTest -> "T" | RMu -> "mu(T)" | RCanary -> "canary")
                       i.i_name i.i_pre i.i_k (role_note i.i_role)))
                insts ;
              if has_mu then begin
                s "// A null on T means \"not observed on a harness that demonstrably\n" ;
                s "// produced the very interleaving T's ordering is claimed to prevent\"\n" ;
                s "// -- and NOTHING AT ALL if the control did not fire (het_verdict.h).\n"
              end else begin
                (* B6c.  This test has no forbidden cycle, so it has no mutant, so it
                   gets Layer B only (Q4 R5).  The canary is what separates "permitted
                   but not exposed here" -- an OBSERVABILITY result -- from "the
                   harness was dead", which is no result at all. *)
                s "// This test is NOT should-be-forbidden, so it has no minimal mutant\n" ;
                s "// (Layer A) -- a mutant presupposes a forbidden cycle to weaken.  It\n" ;
                s "// co-runs the Layer-B canary ONLY, which is what makes a\n" ;
                s "// non-observation here mean \"permitted, but we could not expose it\n" ;
                s "// on a demonstrably HOT harness\" instead of nothing at all.\n"
              end
            end ;
            s dialect.gd_shared_mem_note ;
            s "// a system-scope atomic barrier rendezvouses both sides.\n" ;
            s (Printf.sprintf
                 "// COMPILE-ONLY (%s -c); GPU execution is Task 9.  DO NOT EDIT.\n"
                 (if dialect.gd_ext = "cu" then "nvcc" else "hipcc")) ;
            s (dialect.gd_runtime_include ^ "\n") ;
            s "#include <cstdio>\n#include <cstdint>\n#include <cstdlib>\n" ;
            s "#include <cstring>\n#include <cmath>\n" ;
            s "#include <pthread.h>\n#include <inttypes.h>\n" ;
            s "#include \"het_stress.cuh\"\n" ;
            s "#include \"het_cpu_stress.h\"\n" ;
            s "#include \"het_verdict.h\"\n" ;
            s "extern \"C\" {\n" ;
            s "#include \"outs.h\"\n" ;
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    s (Printf.sprintf "  void het_run_%sP%d(%s);\n"
                         i.i_pre cp.cp_proc (cpu_sig i cp)))
                  i.i_cpus)
              insts ;
            s "}\n" ;
            s {ocaml|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|ocaml} ;
            s (Printf.sprintf "\n#define NPART %d\n" npart) ;
            (* ---- B6/B6b/B6c THE POSITIVE CONTROL.  TWO LAYERS, TWO FLAGS.
               These are the highest-stakes values in this file.  0 means the
               corresponding *_target_count is STRUCTURALLY zero and carries no
               information whatsoever; 1 means that layer is genuinely CO-RUNNING
               here, in this launch, under this stress, on this C2C path, and a
               count may be read against it.

               Neither may EVER be 1 without the co-run behind it: every "Never"
               would silently become a *credible* "Never" -- an unfalsifiable null
               that reads as confirmation of the CMCM.  Both are set from the
               instance population, not by hand, so they cannot drift.

               HET_CONTROL_COMPILED_IN (Layer A, mu(T)) IS STILL 1 ON EXACTLY THE 16
               DISALLOWED TESTS.  B6c did not widen it -- it added a SECOND flag.
               Only a should-be-forbidden test has a minimal mutant (a mutant
               presupposes a known-forbidden cycle to weaken), so the other 322 have
               no Layer A and never will; what they gained is a Layer-B canary, and
               "the canary is co-running" is a different, weaker claim than "the
               mutant of THIS test is co-running".  One bit cannot carry both without
               lying about one of them. *)
            s (Printf.sprintf "#define HET_CONTROL_COMPILED_IN %d\n"
                 (if has_mu then 1 else 0)) ;
            s (Printf.sprintf "#define HET_CANARY_COMPILED_IN %d\n"
                 (if has_canary then 1 else 0)) ;
            (match mu_name with
             | Some m ->
                s (Printf.sprintf "#define HET_MU_NAME \"%s\"      /* Layer A: the minimal mutant */\n" m)
             | None -> s "#define HET_MU_NAME NULL\n") ;
            (* NAMED for all 338; CO-RUN on 320.  The name is not the co-run --
               HET_CANARY_COMPILED_IN above is.  The two `self' rows name themselves,
               which is how het_verdict.h tells "this test IS the canary" from "the
               canary went missing". *)
            (match canary_named with
             | Some c ->
                s (Printf.sprintf "#define HET_CANARY_NAME \"%s\"  /* Layer B: the universal het-MP floor */\n" c)
             | None -> s "#define HET_CANARY_NAME NULL\n") ;
            s (Printf.sprintf "#define SIZE_OF_TEST %d\n" Cfg.size) ;
            s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" Cfg.runs) ;
            (* K IS PER INSTANCE.  It is 3 for MP/SB/LB but 4 for R/S (three stores,
               not two), and the canary is always an MP -- so every R/S control
               harness genuinely mixes K=4 and K=3 in one translation unit.  A tag
               decoded with the wrong K mis-attributes both the writer (tag % K) and
               the iteration (tag / K), and the "recovered" cycles become fiction
               that no structural gate can see. *)
            List.iter
              (fun i ->
                if co_run then
                  s (Printf.sprintf "#define %-9s %d   /* %s (%s) */\n"
                       i.i_kmac i.i_k i.i_name
                       (match i.i_role with
                        | RTest -> "T" | RMu -> "mu(T)" | RCanary -> "canary"))
                else s (Printf.sprintf "#define %s %d\n" i.i_kmac i.i_k))
              insts ;
            s "#ifndef HET_WINDOW\n#define HET_WINDOW 8\n#endif\n" ;
            s "#ifndef HET_EXHAUSTIVE_MAX\n#define HET_EXHAUSTIVE_MAX 4096\n#endif\n" ;
            if co_run then begin
              (* Q4 3.1 / 8.4: the three instances must not share a coherence unit.
                 Disjoint ADDRESSES are not enough -- two variables on one cache line
                 are one coherence unit, so mu(T)'s traffic would drag T's line
                 around and the control would be perturbing the very test it exists
                 to vouch for.  128 B covers both targets (Grace/Neoverse-V2 = 64 B,
                 Hopper L2 sector = 128 B). *)
              s "\n/* B6b: one cache line per shared location, so the three co-running\n\
                 \   instances never share a coherence unit (Q4 3.1: \"disjoint\n\
                 \   cache-line-padded locations\").  128 B covers Grace (64 B lines) and\n\
                 \   Hopper's 128 B L2 sector. */\n" ;
              s "#ifndef HET_CACHE_LINE\n#define HET_CACHE_LINE 128\n#endif\n"
            end ;
            s "\n" ;
            s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
                 block_dim) ;
            (* HET_TEST_BLOCKS / HET_GPU_LANES / HET_SPIN_LANES are SUMS over the
               instances.  Each instance's own count is shape-dependent (S and R
               carry an observer lane, MP/SB/LB do not), so a hardcoded number is
               wrong for exactly the harnesses that need it most: the sys-scope
               rendezvous would release before the S/R observers arrived, and the
               stressers would stop while lanes were still looping. *)
            s (Printf.sprintf "#define HET_TEST_BLOCKS %d\n" test_blocks) ;
            s (Printf.sprintf "#define HET_GPU_LANES %d\n" gpu_lanes) ;
            s (Printf.sprintf "#define HET_SPIN_LANES %d\n\n" spin_lanes) ;
            (* _decode_value (T only): a store tag -> the ORIGINAL value that write
               carried.  Keyed on T's OWN K. *)
            List.iter (fun i -> s i.i_decode) insts ;
            (* ---------------------------- the kernel ------------------------- *)
            let kparams =
              String.concat ", "
                (List.concat_map
                   (fun i ->
                     List.map (fun g -> Printf.sprintf "uint64_t* %s" (gsym i g))
                       i.i_gpu_globals
                     @ List.map (fun (_,_,name,_,_) -> Printf.sprintf "uint64_t* %s" name)
                         (gpu_bufs i)
                     @ List.map
                         (fun l -> Printf.sprintf "uint64_t* %s" (obsG_of i.i_pre l))
                         i.i_obs_locs)
                   insts
                 @ ["int* barrier"]
                 @ ["uint32_t* _scratch" ; "uint32_t* _scratch_loc" ;
                    "uint32_t* _spin_bar" ; "uint32_t* _gpu_done" ;
                    "uint32_t* _stress_tally" ;
                    "uint32_t _seed" ; "uint32_t _pre_pat" ; "uint32_t _mem_pat" ;
                    "uint64_t* _noise_ddr" ; "uint64_t _noise_words" ;
                    "uint32_t _noise_blocks" ; "uint32_t _noise_chunk" ;
                    "uint32_t _noise_stride"]) in
            s (Printf.sprintf "__global__ void litmus_%s(%s) {\n" id kparams) ;
            s "  het_rng_t _rng = het_rng_init(_seed, blockIdx.x * blockDim.x + threadIdx.x);\n" ;
            List.iter
              (fun i ->
                let bb = base_of i in
                (* the GPU TEST lanes of this instance *)
                List.iter
                  (fun gp ->
                    s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n"
                         (bb + gp.gp_blk) gp.gp_lane) ;
                    (* B6b: CudaLang/HipLang name a location by its LISA name (`*x'),
                       and they are SHARED backends we may not touch.  So bind this
                       instance's object to that name locally: the emitted `*x' then
                       refers to t_x / mu_x / can_x with no change to the lowering at
                       all.  (Single-instance harnesses keep prefix "" and emit no
                       alias, so they are byte-for-byte unchanged.) *)
                    if co_run then
                      List.iter
                        (fun g ->
                          s (Printf.sprintf
                               "    uint64_t* %s = %s;  /* B6b: this instance's %s */\n"
                               g (gsym i g) g))
                        i.i_gpu_globals ;
                    s (dialect.gd_bar "    " "barrier") ;
                    List.iter (fun n -> s (Printf.sprintf "    uint64_t r%d = 0;\n" n))
                      gp.gp_regs ;
                    s "    uint32_t _nb = 0;\n" ;
                    (* FAITHFULNESS: SIZE_OF_TEST is a compile-time constant, so nvcc
                       unrolls this loop ~16x and the emitted PTX carries 16x the
                       tested instructions -- the whole het corpus failed the L0
                       faithfulness gate.  An unrolled body is also a DIFFERENT
                       program microarchitecturally, which perturbs the very timing
                       window the test probes.  Do NOT remove. *)
                    s "    #pragma unroll 1\n" ;
                    s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                    s "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n" ;
                    s "        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally);\n" ;
                    (* B4-fix: the roll is drawn from a LANE-INDEPENDENT stream (keyed
                       by the iteration, not the lane), so every test lane -- across
                       ALL co-running instances -- reaches the same verdict for
                       iteration _n.  A barrier is therefore taken by ALL the spin
                       lanes or by NONE, each contributes exactly one increment, and
                       the counter hits _nb*HET_SPIN_LANES EXACTLY when the last lane
                       arrives.  Roll it per-lane instead and the limit becomes
                       unreachable after the first skipped roll (B4's 99.6% cap). *)
                    s "      het_rng_t _brng = het_rng_init(_seed ^ 0x9e3779b9u, (uint32_t)_n);\n" ;
                    s "      if (het_rng_pct(&_brng, HET_BARRIER_PCT)) {\n" ;
                    s "        _nb++;\n" ;
                    s "        het_spin(_spin_bar, _nb * HET_SPIN_LANES, _stress_tally);\n" ;
                    s "      }\n" ;
                    let st_ctr = ref 0 in
                    List.iter
                      (fun instr ->
                        let tag = match instr with
                          | BellBase.Pst _ ->
                             let si = !st_ctr in incr st_ctr ;
                             Some (het_iter, i.i_k, i.i_store_mu gp.gp_proc si)
                          | _ -> Some (het_iter, i.i_k, 0) in
                        dialect.gd_dump_instr ch ~tag "      " instr)
                      gp.gp_instrs ;
                    List.iteri
                      (fun li n ->
                        s (Printf.sprintf "      %s[_n] = (uint64_t)r%d;\n"
                             (buf_name_of i.i_pre gp.gp_proc li) n))
                      gp.gp_regs ;
                    s "    }\n" ;
                    s "    het_scratch_bump(_gpu_done);\n" ;
                    s "  }\n")
                  i.i_gpus ;
                (* this instance's observer lane (block bb + i_nblocks) *)
                if i.i_obs then begin
                  s (Printf.sprintf
                       "  if (blockIdx.x == %d && threadIdx.x == 0) {\n"
                       (bb + i.i_nblocks)) ;
                  s (dialect.gd_bar "    " "barrier") ;
                  s "    #pragma unroll 1\n" ;
                  s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                  List.iter
                    (fun l ->
                      s (Printf.sprintf "      %s[_n] = %s;\n"
                           (obsG_of i.i_pre l) (dialect.gd_sys_load_u64 (gsym i l))))
                    i.i_obs_locs ;
                  s "    }\n" ;
                  s "    het_scratch_bump(_gpu_done);\n" ;
                  s "  }\n"
                end)
              insts ;
            (* ================= B4: pure stressing workgroups ================= *)
            s "  if (blockIdx.x >= HET_TEST_BLOCKS) {\n" ;
            s "    if (_noise_ddr != NULL && blockIdx.x < HET_TEST_BLOCKS + _noise_blocks) {\n" ;
            s "      volatile const uint64_t* _nb = (volatile const uint64_t*)_noise_ddr;\n" ;
            s "      uint64_t _t = (uint64_t)(blockIdx.x - HET_TEST_BLOCKS) * blockDim.x + threadIdx.x;\n" ;
            s "      uint64_t _step = (uint64_t)_noise_blocks * blockDim.x * _noise_stride;\n" ;
            s "      uint64_t _i = (_noise_words > 0) ? (_t % _noise_words) : 0;\n" ;
            s "      uint64_t _acc = 0;\n" ;
            s "      uint32_t _r = 0;\n" ;
            s "      for (;\n\
               \           _r < HET_STRESS_MAX_ROUNDS && het_scratch_read(_gpu_done) < HET_GPU_LANES;\n\
               \           ++_r) {\n" ;
            s "        for (uint32_t _c = 0; _c < _noise_chunk; ++_c) {\n" ;
            s "          _acc += _nb[_i];\n" ;
            s "          _i += _step;\n" ;
            s "          if (_i >= _noise_words) _i = (_noise_words > 0) ? (_i % _noise_words) : 0;\n" ;
            s "        }\n" ;
            s "      }\n" ;
            s "      if (_r > 0) het_scratch_bump(&_stress_tally[HET_TALLY_NOISE]);\n" ;
            s "      het_scratch_max(&_stress_tally[HET_TALLY_NOISE_ROUNDS], _r);\n" ;
            s "      if (_acc == 0xFFFFFFFFFFFFFFFFull)\n" ;
            s "        het_scratch_bump(&_stress_tally[HET_TALLY_NOISE]);  /* sink: force _acc to escape */\n" ;
            s "    } else {\n" ;
            s "    uint32_t _s = 0;\n" ;
            s "    for (;\n\
               \         _s < HET_STRESS_MAX_ROUNDS && het_scratch_read(_gpu_done) < HET_GPU_LANES;\n\
               \         ++_s) {\n" ;
            s "      if (het_rng_pct(&_rng, HET_MEM_STRESS_PCT))\n" ;
            s "        het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally);\n" ;
            s "    }\n" ;
            s "    if (_s >= HET_STRESS_MAX_ROUNDS)\n" ;
            s "      het_scratch_bump(&_stress_tally[HET_TALLY_TRUNC]);\n" ;
            s "    }\n" ;
            s "  }\n" ;
            s "}\n\n" ;
            (* ---------------- CPU pthread wrappers, per instance -------------- *)
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    let proc = cp.cp_proc in
                    let addr = cpu_addr_u64 cp and bufs = cpu_bufs i cp in
                    s (Printf.sprintf "struct cpu_args_%sP%d {\n" i.i_pre proc) ;
                    List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr ;
                    s "  int* barrier;\n" ;
                    List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) bufs ;
                    s "  int _core; uint32_t _seed; het_cpu_tally* _tally;\n" ;
                    s "};\n" ;
                    s (Printf.sprintf "static void* cpu_thread_%sP%d(void* _a) {\n"
                         i.i_pre proc) ;
                    s (Printf.sprintf "  cpu_args_%sP%d* a = (cpu_args_%sP%d*)_a;\n"
                         i.i_pre proc i.i_pre proc) ;
                    s "  het_cpu_affinity(a->_core, a->_tally);\n" ;
                    let npl = List.length addr in
                    if npl > 0 then begin
                      s (Printf.sprintf "  void* const _pl[%d] = { %s };\n" npl
                           (String.concat ", "
                              (List.map (fun (_,n) -> Printf.sprintf "(void*)a->%s" n)
                                 addr))) ;
                      s (Printf.sprintf
                           "  uint32_t _plrng = het_cpu_rng_init(a->_seed, %du);\n" proc) ;
                      s "  uint64_t _plops = 0;\n"
                    end ;
                    s (dialect.gd_bar "  " "a->barrier") ;
                    let call_args =
                      String.concat ","
                        (List.map (fun (_,a) -> "a->"^a) (addr @ bufs) @ ["_n"]) in
                    s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                    if npl > 0 then
                      s (Printf.sprintf
                           "    _plops += het_cpu_preload(_pl, %d, &_plrng, HET_CPU_PRELOAD_PCT);\n"
                           npl) ;
                    s (Printf.sprintf "    het_run_%sP%d(%s);\n" i.i_pre proc call_args) ;
                    s "  }\n" ;
                    if npl > 0 then
                      s "  __atomic_fetch_add(&a->_tally->preload_ops, _plops, __ATOMIC_RELAXED);\n" ;
                    s "  return NULL;\n}\n\n")
                  i.i_cpus ;
                (* this instance's CPU observer pthread *)
                if i.i_obs then begin
                  s (Printf.sprintf "struct %scpu_obs_args {\n" i.i_pre) ;
                  List.iter (fun l -> s (Printf.sprintf "  uint64_t* %s;\n" l))
                    i.i_all_globals ;
                  s "  int* barrier;\n" ;
                  List.iter
                    (fun l -> s (Printf.sprintf "  uint64_t* %s;\n" (obsC_of "" l)))
                    i.i_obs_locs ;
                  s "  int _core; het_cpu_tally* _tally;\n" ;
                  s "};\n" ;
                  s (Printf.sprintf "static void* %scpu_obs_thread(void* _a) {\n" i.i_pre) ;
                  s (Printf.sprintf "  %scpu_obs_args* a = (%scpu_obs_args*)_a;\n"
                       i.i_pre i.i_pre) ;
                  s "  het_cpu_affinity(a->_core, a->_tally);\n" ;
                  s (dialect.gd_bar "  " "a->barrier") ;
                  s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                  List.iter
                    (fun l ->
                      s (Printf.sprintf "    a->%s[_n] = *a->%s;\n" (obsC_of "" l) l))
                    i.i_obs_locs ;
                  s "  }\n  return NULL;\n}\n\n"
                end)
              insts ;
            (* outcome labels + decoded-outcome dump callback (T only) *)
            List.iter (fun i -> s i.i_labels) insts ;
            s "/* B5: placement refusals.  Incremented only where placement EXISTS\n\
               \   (the CUDA/GH200 render); stays 0 on the HIP/MI300A render, which has a\n\
               \   single HBM pool and therefore nothing to place. */\n" ;
            s "static int _het_place_failures = 0;\n\n" ;
            s dialect.gd_shared_mem_defs ;
            s "\n" ;
            s dialect.gd_noise_mem_defs ;
            s "\n" ;
            (* ------------------------------ driver --------------------------- *)
            s "int main(void){\n" ;
            (* B1: shared litmus vars + barrier through gd_alloc_shared.
               B6b: in a co-run harness they are carved out of ONE gd_alloc_shared
               arena, ONE CACHE LINE APART.  Separate 8-byte mallocs would land the
               three instances' locations (and the barrier) on shared lines, and two
               variables on one line are ONE coherence unit -- mu(T)'s traffic would
               then drag T's line around and the control would perturb the very test
               it exists to vouch for.  One allocation, one free, and the free still
               matches the allocator (Q8: malloc/ATS on GH200, managed fallback). *)
            let shared_slots =
              List.concat_map
                (fun i -> List.map (fun g -> (i,g)) i.i_all_globals) insts in
            if co_run then begin
              let nslot = List.length shared_slots + 1 in    (* +1 for the barrier *)
              s (Printf.sprintf
                   "  /* %d cache-line-padded shared slots: %s + barrier */\n" nslot
                   (String.concat " " (List.map (fun (i,g) -> gsym i g) shared_slots))) ;
              s "  unsigned char *_shared_arena;\n" ;
              s (Printf.sprintf
                   "  gd_alloc_shared((void**)&_shared_arena, (size_t)HET_CACHE_LINE*%d);\n"
                   (nslot + 1)) ;
              s "  uintptr_t _sa = ((uintptr_t)_shared_arena + (HET_CACHE_LINE-1))\n\
                 \                  & ~(uintptr_t)(HET_CACHE_LINE-1);\n" ;
              List.iteri
                (fun k (i,g) ->
                  s (Printf.sprintf
                       "  uint64_t *%s = (uint64_t*)(_sa + (size_t)HET_CACHE_LINE*%d);\n"
                       (gsym i g) k))
                shared_slots ;
              s (Printf.sprintf
                   "  int *barrier = (int*)(_sa + (size_t)HET_CACHE_LINE*%d);\n"
                   (List.length shared_slots))
            end else begin
              List.iter
                (fun (i,g) ->
                  s (Printf.sprintf
                       "  uint64_t *%s; gd_alloc_shared((void**)&%s, sizeof(uint64_t));\n"
                       (gsym i g) (gsym i g)))
                shared_slots ;
              s "  int *barrier; gd_alloc_shared((void**)&barrier, sizeof(int));\n"
            end ;
            (* B3: read buffers -- OFF the coherent race path. *)
            List.iter
              (fun i ->
                List.iter
                  (fun (_,_,name,dev,_) ->
                    match dev with
                    | `Gpu ->
                       s (Printf.sprintf "  uint64_t *%s; %s\n" name
                            (dialect.gd_dev_malloc name buf_bytes)) ;
                       s (Printf.sprintf
                            "  uint64_t *%s_h = (uint64_t*)malloc_check(%s);\n"
                            name buf_bytes)
                    | `Cpu ->
                       s (Printf.sprintf
                            "  uint64_t *%s = (uint64_t*)malloc_check(%s);\n"
                            name buf_bytes))
                  i.i_bufs ;
                List.iter
                  (fun l ->
                    let og = obsG_of i.i_pre l and oc = obsC_of i.i_pre l in
                    s (Printf.sprintf "  uint64_t *%s; %s\n" og
                         (dialect.gd_dev_malloc og buf_bytes)) ;
                    s (Printf.sprintf "  uint64_t *%s_h = (uint64_t*)malloc_check(%s);\n"
                         og buf_bytes) ;
                    s (Printf.sprintf "  uint64_t *%s = (uint64_t*)malloc_check(%s);\n"
                         oc buf_bytes))
                  i.i_obs_locs)
              insts ;
            (* B2: cooperative-launch prelude *)
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
            s "  int _testBlocks = HET_TEST_BLOCKS;\n" ;
            s "  int _noiseBlocks = HET_NOISE_GPU_BLOCKS;\n" ;
            s "  if (_noiseBlocks < 0) _noiseBlocks = 0;\n" ;
            s "  int _stressBlocks = (HET_STRESS_BLOCKS >= 0) ? HET_STRESS_BLOCKS\n\
               \                                              : (_maxGrid - _testBlocks - _noiseBlocks);\n" ;
            s "  if (_stressBlocks < 0) _stressBlocks = 0;\n" ;
            s "  int _grid = _testBlocks + _noiseBlocks + _stressBlocks;\n" ;
            s "  if (_grid > _maxGrid) { fprintf(stderr, \"grid %d exceeds co-resident cap %d\\n\", _grid, _maxGrid); return 2; }\n" ;
            (* B6b: a co-run harness reserves 3x-5x the test blocks, so the stress
               population is the first thing the co-residency cap squeezes out.  An
               empty stress population is a run with NO memory stress at all -- and
               on NVIDIA silicon that is a run that observes nothing (Alglave 4.3.1).
               The GPU-stress tally would catch it after the fact; say it BEFORE. *)
            s "  if (HET_MEM_STRESS_PCT > 0 && _stressBlocks == 0)\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: the mem-stress population is EMPTY (test=%d + noise=%d fills the co-resident cap %d).  HET_MEM_STRESS_PCT=%d asks for scratchpad stress and NO block will do any.  On NVIDIA silicon an unstressed run observes nothing (Alglave ASPLOS'15 4.3.1).\\n\",\n\
               \            _testBlocks, _noiseBlocks, _maxGrid, (int)HET_MEM_STRESS_PCT);\n" ;
            s "  uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;\n" ;
            s "  uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;\n" ;
            s "  fprintf(stderr, \"HetLitmus: blockDim=%d grid=%d (test=%d stress=%d, co-resident cap=%d) pre_pat=%u mem_pat=%u\\n\",\n\
               \          (int)HET_BLOCK_DIM, _grid, _testBlocks, _stressBlocks, _maxGrid,\n\
               \          _pre_pat, _mem_pat);\n" ;
            s (Printf.sprintf "  uint32_t *_scratch; %s\n"
                 (dialect.gd_dev_malloc "_scratch" "sizeof(uint32_t)*HET_SCRATCH_SIZE")) ;
            s (Printf.sprintf "  uint32_t *_scratch_loc; %s\n"
                 (dialect.gd_dev_malloc "_scratch_loc" "sizeof(uint32_t)*_grid")) ;
            s (Printf.sprintf "  uint32_t *_spin_bar; %s\n"
                 (dialect.gd_dev_malloc "_spin_bar" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "  uint32_t *_gpu_done; %s\n"
                 (dialect.gd_dev_malloc "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "  uint32_t *_stress_tally; %s\n"
                 (dialect.gd_dev_malloc "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "  uint32_t _stress_tally_h[HET_TALLY_N];\n" ;
            s "  uint32_t *_scratch_loc_h = (uint32_t*)malloc_check(sizeof(uint32_t)*_grid);\n" ;
            (* ---------------- B5 Half 1: the CPU stress population ------------ *)
            let n_cpu_threads =
              List.fold_left
                (fun a i -> a + List.length i.i_cpus + (if i.i_obs then 1 else 0))
                0 insts in
            s "  int _ncores = het_cpu_ncores();\n" ;
            s "  int _aff = HET_CPU_AFFINITY;\n" ;
            s (Printf.sprintf "  int _nCpuTest = %d;\n" n_cpu_threads) ;
            s "  int _nEnemy = HET_CPU_ENEMIES;\n" ;
            s "  if (_nEnemy < 0) {\n" ;
            s "    _nEnemy = _ncores - _nCpuTest - (HET_NOISE_CPU ? 1 : 0) - HET_CPU_RESERVE_CORES;\n" ;
            s "    if (_nEnemy < 0) _nEnemy = 0;\n" ;
            s "  }\n" ;
            s "  het_cpu_tally _ct;\n" ;
            s "  int _stress_go = 0;\n" ;
            s "  uint64_t *_cpu_scratch =\n\
               \    (uint64_t*)malloc_check(sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);\n" ;
            s "  memset(_cpu_scratch, 0, sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);\n" ;
            s "  uint32_t _cpu_nregions = (uint32_t)(HET_CPU_SCRATCH_WORDS / HET_CPU_STRIDE);\n" ;
            s "  if (_cpu_nregions < 1) _cpu_nregions = 1;\n" ;
            s "  uint32_t _cpu_spread = HET_CPU_SPREAD;\n" ;
            s "  if (_cpu_spread > _cpu_nregions) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: realised CPU stress spread is %u region(s), not HET_CPU_SPREAD=%d -- the enemy scratchpad (HET_CPU_SCRATCH_WORDS/HET_CPU_STRIDE) holds only %u.  The CPU stress is weaker than the configuration says.\\n\",\n\
               \            _cpu_nregions, (int)HET_CPU_SPREAD, _cpu_nregions);\n" ;
            s "    _cpu_spread = _cpu_nregions;\n" ;
            s "  }\n" ;
            s "  uint32_t *_cpu_idx = (uint32_t*)malloc_check(sizeof(uint32_t)*_cpu_nregions);\n" ;
            s "  het_cpu_enemy_args *_ea = (het_cpu_enemy_args*)malloc_check(sizeof(het_cpu_enemy_args)*(_nEnemy>0?_nEnemy:1));\n" ;
            s "  pthread_t *_eth = (pthread_t*)malloc_check(sizeof(pthread_t)*(_nEnemy>0?_nEnemy:1));\n" ;
            s "  uint64_t _noise_words = (uint64_t)HET_NOISE_MB * 1024ull * 1024ull / sizeof(uint64_t);\n" ;
            s "  uint32_t _noise_blocks = (uint32_t)_noiseBlocks;\n" ;
            s "  uint32_t _noise_chunk = (uint32_t)HET_NOISE_CHUNK;\n" ;
            s "  uint32_t _noise_stride = (uint32_t)HET_NOISE_STRIDE;\n" ;
            s "  uint64_t *_noise_ddr = NULL;   /* CPU-homed: the GPU streams it */\n" ;
            s "  uint64_t *_noise_hbm = NULL;   /* GPU-homed: the CPU streams it */\n" ;
            s "  het_cpu_noise_args _na; pthread_t _nth; int _noise_cpu_on = 0;\n" ;
            s "  if (HET_NOISE_MB < HET_LLC_MB)\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%d is BELOW the last-level cache (%d MB) -- the noise buffers fit in cache, so the reads are served locally and generate NO interconnect traffic.  This run is NOT C2C-stressed (Fusco: Hopper L2 caches HBM, local and peer).\\n\",\n\
               \            (int)HET_NOISE_MB, (int)HET_LLC_MB);\n" ;
            s "  if (_noiseBlocks > 0) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_ddr, (size_t)_noise_words*sizeof(uint64_t), 2);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB DDR noise buffer -- the Hopper half of the C2C noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB); _noise_ddr = NULL; _noise_blocks = 0; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the DDR noise buffer could not be homed on the CPU -- this device has no interconnect-stress lever (no ATS/C2C), so the Hopper noise is exercising plumbing, not C2C.\\n\");\n" ;
            s "  }\n" ;
            s "  if (HET_NOISE_CPU) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_hbm, (size_t)_noise_words*sizeof(uint64_t), 1);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB HBM noise buffer -- the Grace half of the C2C noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB); _noise_hbm = NULL; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the HBM noise buffer could not be homed on the GPU -- the Grace noise is exercising plumbing, not C2C.\\n\");\n" ;
            s "  }\n" ;
            s "  fprintf(stderr, \"HetLitmus cpu-stress: cores=%d test=%d enemies=%d spread=%u stride=%d seq=%d preload=%d%% aff=%d | noise: gpu_blocks=%u cpu=%d words=%llu (%d MB) place=%d\\n\",\n\
               \          _ncores, _nCpuTest, _nEnemy, _cpu_spread, (int)HET_CPU_STRIDE,\n\
               \          (int)HET_CPU_ENEMY_SEQ, (int)HET_CPU_PRELOAD_PCT, _aff,\n\
               \          _noise_blocks, (int)HET_NOISE_CPU,\n\
               \          (unsigned long long)_noise_words, (int)HET_NOISE_MB, (int)HET_PLACE);\n" ;
            s "  outs_t* hist = NULL;\n" ;
            (* B7: the statistics are computed over the (instance,run) CELLS, so the
               records have to OUTLIVE the run loop.  R1 -- the load-bearing
               correction -- is that the replication unit is the cell, never the
               frame: the recovery scan validates N^{T_L} overlapping frames per N
               iterations (PerpLE VI-B.1), so a frame count fed into Kirkham's
               1-e^{-n} returns ~1 vacuously.  Y = 1[target_count >= 1] per cell is
               the n that goes into the reproducibility and rule-of-three math. *)
            s "  het_obs_record _recs[NUMBER_OF_RUN];\n" ;
            s "  memset(_recs, 0, sizeof _recs);\n" ;
            (* B7b: the campaign knobs are RUNTIME (getenv), never -D -- a
               compile-time knob threaded through an if-chain is how B4's stress
               layer got folded away, and the scheduler retunes these per
               invocation without a rebuild.  Unset envs leave the compiled
               defaults, so a bare ./run behaves exactly as B7 did.  HET_RUNS_MAX
               can only CURTAIL within one invocation (the record array is
               compiled at NUMBER_OF_RUN); growing R is the outer scheduler's
               job, one fresh-HET_SEED invocation at a time -- re-running the
               same seeds adds no fresh phase draws and pooling them would
               double-count R_eff. *)
            s "  int _runs_budget = (int)het_env_long(\"HET_RUNS_MAX\", NUMBER_OF_RUN);\n" ;
            s "  if (_runs_budget > NUMBER_OF_RUN) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_RUNS_MAX=%d exceeds the compiled NUMBER_OF_RUN=%d -- clamped.  Grow R by re-invoking with a FRESH HET_SEED (hetlitmus/campaign.py), never by replaying the same seeds.\\n\", _runs_budget, (int)NUMBER_OF_RUN);\n" ;
            s "    _runs_budget = NUMBER_OF_RUN;\n" ;
            s "  }\n" ;
            s "  if (_runs_budget < 1) _runs_budget = 1;\n" ;
            s "  int _adaptive = (int)het_env_long(\"HET_ADAPTIVE\", 0);\n" ;
            s "  double _p_goal = het_env_double(\"HET_P_GOAL\", -1.0);\n" ;
            s "  uint32_t _seed0 = (uint32_t)het_env_long(\"HET_SEED\", (long)HET_SEED);\n" ;
            s "  int _nrec = 0;\n" ;
            s "  for (int _run=0; _run<_runs_budget; ++_run) {\n" ;
            List.iter
              (fun (i,g) -> s (Printf.sprintf "    *%s = 0;\n" (gsym i g)))
              shared_slots ;
            s "    *barrier = 0;\n" ;
            s "    uint32_t _seed = _seed0 + (uint32_t)_run;\n" ;
            s "    srand((unsigned int)_seed);\n" ;
            s "    het_set_scratch_locations(_scratch_loc_h, _grid);\n" ;
            (* ---- B5: the CPU stress population, spawned BEFORE the test threads. *)
            s "    memset(&_ct, 0, sizeof _ct);\n" ;
            s "    het_cpu_shuffle(_cpu_idx, _cpu_nregions);   /* M2: reshuffled per run, off the run seed */\n" ;
            s "    __atomic_store_n(&_stress_go, 1, __ATOMIC_RELAXED);\n" ;
            s "    int _ecore0 = HET_CPU_TEST_CORE0 + _nCpuTest + (HET_NOISE_CPU ? 1 : 0);\n" ;
            s "    if (_aff && _ecore0 + _nEnemy > _ncores)\n" ;
            s "      fprintf(stderr, \"HetLitmus WARNING: %d enemy thread(s) from core %d exceed %d core(s) -- enemy pins WRAP onto the test threads' cores, so the test threads no longer have a core to themselves and the stress topology is not the one being tuned.\\n\",\n\
               \              _nEnemy, _ecore0, _ncores);\n" ;
            s "    for (int _e = 0; _e < _nEnemy; ++_e) {\n" ;
            s "      uint32_t _off = (_cpu_nregions > _cpu_spread)\n\
               \                    ? ((uint32_t)_e * _cpu_spread) % (_cpu_nregions - _cpu_spread + 1)\n\
               \                    : 0u;\n" ;
            s "      _ea[_e].scratch = _cpu_scratch;\n" ;
            s "      _ea[_e].idx     = _cpu_idx + _off;\n" ;
            s "      _ea[_e].nidx    = _cpu_spread;\n" ;
            s "      _ea[_e].stride  = (uint32_t)HET_CPU_STRIDE;\n" ;
            s "      _ea[_e].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;\n" ;
            s "      _ea[_e].core    = _aff ? ((_ecore0 + _e) % _ncores) : -1;\n" ;
            s "      _ea[_e].go      = &_stress_go;\n" ;
            s "      _ea[_e].tally   = &_ct;\n" ;
            s "      pthread_create(&_eth[_e], NULL, het_cpu_enemy, &_ea[_e]);\n" ;
            s "    }\n" ;
            s "    _noise_cpu_on = 0;\n" ;
            s "    if (HET_NOISE_CPU && _noise_hbm != NULL) {\n" ;
            s "      _na.buf    = (volatile const uint64_t*)_noise_hbm;\n" ;
            s "      _na.words  = _noise_words;\n" ;
            s "      _na.chunk  = _noise_chunk;\n" ;
            s "      _na.stride = _noise_stride;\n" ;
            s "      _na.core   = _aff ? ((HET_CPU_TEST_CORE0 + _nCpuTest) % _ncores) : -1;\n" ;
            s "      _na.go     = &_stress_go;\n" ;
            s "      _na.tally  = &_ct;\n" ;
            s "      pthread_create(&_nth, NULL, het_cpu_noise, &_na);\n" ;
            s "      _noise_cpu_on = 1;\n" ;
            s "    }\n" ;
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
            List.iter
              (fun i ->
                List.iter
                  (fun (_,_,name,dev,_) ->
                    match dev with
                    | `Gpu ->
                       s (Printf.sprintf "    %s\n"
                            (dialect.gd_dev_memset0 name buf_bytes))
                    | `Cpu ->
                       s (Printf.sprintf "    memset(%s, 0, %s);\n" name buf_bytes))
                  i.i_bufs ;
                List.iter
                  (fun l ->
                    s (Printf.sprintf "    %s\n"
                         (dialect.gd_dev_memset0 (obsG_of i.i_pre l) buf_bytes)) ;
                    s (Printf.sprintf "    memset(%s, 0, %s);\n"
                         (obsC_of i.i_pre l) buf_bytes))
                  i.i_obs_locs)
              insts ;
            (* spawn the CPU test threads of every instance; cores are handed out in
               emission order so the instances never share one. *)
            let ti = ref 0 in
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    let proc = cp.cp_proc in
                    let addr = cpu_addr_u64 cp and bufs = cpu_bufs i cp in
                    let core =
                      Printf.sprintf
                        "(_aff ? ((HET_CPU_TEST_CORE0 + %d) %% _ncores) : -1)" !ti in
                    incr ti ;
                    let fields =
                      String.concat ", "
                        (List.map (fun (_,n) -> gsym i n) addr
                         @ ["barrier"] @ List.map snd bufs
                         @ [core ; "_seed" ; "&_ct"]) in
                    s (Printf.sprintf "    cpu_args_%sP%d %s = { %s };\n"
                         i.i_pre proc (usym i.i_pre (Printf.sprintf "_ca%d" proc))
                         fields) ;
                    s (Printf.sprintf
                         "    pthread_t %s; pthread_create(&%s, NULL, cpu_thread_%sP%d, &%s);\n"
                         (usym i.i_pre (Printf.sprintf "_th%d" proc))
                         (usym i.i_pre (Printf.sprintf "_th%d" proc))
                         i.i_pre proc
                         (usym i.i_pre (Printf.sprintf "_ca%d" proc))))
                  i.i_cpus ;
                if i.i_obs then begin
                  let core =
                    Printf.sprintf
                      "(_aff ? ((HET_CPU_TEST_CORE0 + %d) %% _ncores) : -1)" !ti in
                  incr ti ;
                  let fields =
                    String.concat ", "
                      (List.map (gsym i) i.i_all_globals @ ["barrier"]
                       @ List.map (obsC_of i.i_pre) i.i_obs_locs
                       @ [core ; "&_ct"]) in
                  s (Printf.sprintf "    %scpu_obs_args %s = { %s };\n"
                       i.i_pre (usym i.i_pre "_cao") fields) ;
                  s (Printf.sprintf
                       "    pthread_t %s; pthread_create(&%s, NULL, %scpu_obs_thread, &%s);\n"
                       (usym i.i_pre "_tho") (usym i.i_pre "_tho") i.i_pre
                       (usym i.i_pre "_cao"))
                end)
              insts ;
            (* B2: args[] in KERNEL-PARAM order. *)
            let args_addrs =
              String.concat ", "
                (List.concat_map
                   (fun i ->
                     List.map (fun g -> "&" ^ gsym i g) i.i_gpu_globals
                     @ List.map (fun (_,_,name,_,_) -> "&"^name) (gpu_bufs i)
                     @ List.map (fun l -> "&" ^ obsG_of i.i_pre l) i.i_obs_locs)
                   insts
                 @ ["&barrier"]
                 @ ["&_scratch" ; "&_scratch_loc" ; "&_spin_bar" ; "&_gpu_done" ;
                    "&_stress_tally" ; "&_seed" ; "&_pre_pat" ; "&_mem_pat" ;
                    "&_noise_ddr" ; "&_noise_words" ; "&_noise_blocks" ;
                    "&_noise_chunk" ; "&_noise_stride"]) in
            s (Printf.sprintf "    void* _args[] = { %s };\n" args_addrs) ;
            s (Printf.sprintf
                 "    %s _e = %s((void*)litmus_%s, dim3(_grid), dim3(HET_BLOCK_DIM), _args, 0, 0);\n"
                 dialect.gd_err_t dialect.gd_coop_launch id) ;
            s (Printf.sprintf
                 "    if (_e != %s) { fprintf(stderr, \"coop launch: %%s\\n\", %s(_e)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            List.iter
              (fun i ->
                List.iter
                  (fun cp ->
                    s (Printf.sprintf "    pthread_join(%s, NULL);\n"
                         (usym i.i_pre (Printf.sprintf "_th%d" cp.cp_proc))))
                  i.i_cpus ;
                if i.i_obs then
                  s (Printf.sprintf "    pthread_join(%s, NULL);\n"
                       (usym i.i_pre "_tho")))
              insts ;
            s (Printf.sprintf "    %s _s = %s\n" dialect.gd_err_t dialect.gd_device_sync) ;
            s (Printf.sprintf
                 "    if (_s != %s) { fprintf(stderr, \"sync: %%s\\n\", %s(_s)); return 2; }\n"
                 dialect.gd_success dialect.gd_errstr) ;
            s "    __atomic_store_n(&_stress_go, 0, __ATOMIC_RELAXED);\n" ;
            s "    for (int _e = 0; _e < _nEnemy; ++_e) pthread_join(_eth[_e], NULL);\n" ;
            s "    if (_noise_cpu_on) pthread_join(_nth, NULL);\n" ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_memcpy_d2h "_stress_tally_h" "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "    {\n" ;
            s "      unsigned long long _rdv = _stress_tally_h[HET_TALLY_RDV];\n" ;
            s "      unsigned long long _cap = _stress_tally_h[HET_TALLY_CAP];\n" ;
            s "      unsigned long long _spins = _rdv + _cap;\n" ;
            s "      fprintf(stderr, \"HetLitmus stress: spins=%llu rendezvous=%llu cap=%llu (%.1f%% rendezvous) do_stress_rounds=%u\\n\",\n\
               \              _spins, _rdv, _cap, _spins ? 100.0*(double)_rdv/(double)_spins : 0.0,\n\
               \              _stress_tally_h[HET_TALLY_STRESS_ROUNDS]);\n" ;
            s "      if (_spins && _rdv * 2 < _spins)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: the device-scope window-opener released on the 1024-spin DEADLOCK CAP in %.1f%% of spins -- it is aligning the GPU test lanes weakly or not at all (expect ~0%% cap on a healthy run; see het_stress.cuh het_spin)\\n\",\n\
               \                100.0*(double)_cap/(double)_spins);\n" ;
            s "      if (_stress_tally_h[HET_TALLY_TRUNC])\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u stress lane(s) hit HET_STRESS_MAX_ROUNDS -- stress STOPPED while tested lanes were still running.  This run is NOT a stressed run and its non-observations are not comparable with one.\\n\",\n\
               \                _stress_tally_h[HET_TALLY_TRUNC]);\n" ;
            (* B6b fix 2: het_do_stress now has a runtime tally, so a GPU scratchpad
               layer that never EXECUTED is finally visible.  stresscheck.py proves
               (structurally) that its accesses survive into the PTX; this proves they
               ran.  Neither alone is enough -- that division of labour is the whole
               lesson of B4, which shipped a stress layer that was in the source, gone
               from the PTX, and green on every gate. *)
            s "      if ((HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0)\n\
               \          && _stress_tally_h[HET_TALLY_STRESS_ROUNDS] == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: the GPU scratchpad stress was REQUESTED (pre=%d%% mem=%d%%) but het_do_stress completed ZERO rounds -- the layer did NOT run.  Its non-observations are not those of a stressed run.\\n\",\n\
               \                (int)HET_PRE_STRESS_PCT, (int)HET_MEM_STRESS_PCT);\n" ;
            s "    }\n" ;
            s "    {\n" ;
            s "      unsigned long long _er = _ct.enemy_rounds;\n" ;
            s "      unsigned long long _pl = _ct.preload_ops;\n" ;
            s "      unsigned long long _nc = _ct.noise_cpu_rounds;\n" ;
            s "      uint32_t _ng = _stress_tally_h[HET_TALLY_NOISE];\n" ;
            s "      fprintf(stderr, \"HetLitmus cpu-stress: enemies=%u rounds=%llu accesses=%llu preload_hints=%llu | noise: cpu_rounds=%llu gpu_blocks=%u (max %u rounds) | aff_fail=%u place_fail=%d\\n\",\n\
               \              _ct.enemies_realised, _er, (unsigned long long)_ct.enemy_accesses,\n\
               \              _pl, _nc, _ng, _stress_tally_h[HET_TALLY_NOISE_ROUNDS],\n\
               \              _ct.aff_failures, _het_place_failures);\n" ;
            s "      if (_nEnemy > 0 && _er == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds -- the CPU-side stress did NOT run.  Its non-observations are not those of a CPU-stressed run.\\n\", _nEnemy);\n" ;
            s "      if (HET_CPU_PRELOAD_PCT > 0 && _pl == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: HET_CPU_PRELOAD_PCT=%d but ZERO preload hints were issued -- the M3 incantation is INERT (this host may have no cache primitives; see het_cpu_stress.h HET_CPU_PRELOAD_LIVE).\\n\", (int)HET_CPU_PRELOAD_PCT);\n" ;
            s "      if (HET_NOISE_CPU && _noise_cpu_on && _nc == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: the Grace noise thread completed ZERO rounds -- the CPU half of the C2C noise did NOT run.\\n\");\n" ;
            s "      if (_noise_blocks > 0 && _ng == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u Hopper noise block(s) were launched but NONE completed a round -- the GPU half of the C2C noise did NOT run.  This run is not interconnect-stressed.\\n\", _noise_blocks);\n" ;
            s "      if (_ct.aff_failures)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u sched_setaffinity call(s) FAILED -- those threads are wherever the scheduler put them.  The pinning is fiction and the stress topology is not the one being tuned.\\n\", _ct.aff_failures);\n" ;
            s "    }\n" ;
            (* B3: mirror every instance's GPU device read + observer buffers. *)
            List.iter
              (fun i ->
                List.iter
                  (fun (_,_,name,_,_) ->
                    s (Printf.sprintf "    %s\n"
                         (dialect.gd_memcpy_d2h (name^"_h") name buf_bytes)))
                  (gpu_bufs i) ;
                List.iter
                  (fun l ->
                    let og = obsG_of i.i_pre l in
                    s (Printf.sprintf "    %s\n"
                         (dialect.gd_memcpy_d2h (og^"_h") og buf_bytes)))
                  i.i_obs_locs)
              insts ;
            (* ======== the recovery scans: one per instance ==================== *)
            s "    het_obs_record _rec; memset(&_rec, 0, sizeof _rec);\n" ;
            s (Printf.sprintf
                 "    _rec.test_name = \"%s\"; _rec.instance_id = 0; _rec.run_id = _run;\n"
                 tname) ;
            s (Printf.sprintf "    _rec.confidence = %s;\n"
                 (HetCond.confidence_c_name it.i_mech)) ;
            s (Printf.sprintf "    _rec.reporting = %s;\n"
                 (HetCond.confidence_c_name it.i_report)) ;
            s "    _rec.N = SIZE_OF_TEST;\n" ;
            (* B6c: WHAT THE MODEL PREDICTS FOR THIS TEST.  Read from field 2 of
               control-map.csv (the grounded oracle).  Without it het_verdict()
               framed every test as should-be-forbidden and 322 of the 338 harnesses
               stood ready to print a false REFUTATION of the compound model on a
               weak outcome the model EXPECTS.  ORACLE_UNSET (a test missing from the
               map) fails closed: the harness prints "BUILD BUG, not a result". *)
            s (Printf.sprintf "    _rec.het_oracle = %s;\n" oracle) ;
            (match mu_name with
             | Some m -> s (Printf.sprintf "    _rec.control_name = \"%s\";\n" m)
             | None -> s "    _rec.control_name = NULL;  /* no mu(T): not a Disallowed test */\n") ;
            (match canary_named with
             | Some c -> s (Printf.sprintf "    _rec.canary_name = \"%s\";\n" c)
             | None -> s "    _rec.canary_name = NULL;\n") ;
            s "    _rec.control_compiled_in = HET_CONTROL_COMPILED_IN;\n" ;
            s "    _rec.canary_compiled_in = HET_CANARY_COMPILED_IN;\n" ;
            s "    _rec.stress_requested =\n\
               \        ((HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0) ? HET_REQ_GPU_STRESS : 0u)\n\
               \      | ((HET_BARRIER_PCT > 0) ? HET_REQ_SPIN : 0u)\n\
               \      | ((_nEnemy > 0) ? HET_REQ_CPU_ENEMY : 0u)\n\
               \      | ((HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) ? HET_REQ_CPU_PRELOAD : 0u)\n\
               \      | ((HET_NOISE_CPU && _noise_cpu_on) ? HET_REQ_NOISE_CPU : 0u)\n\
               \      | ((_noise_blocks > 0) ? HET_REQ_NOISE_GPU : 0u);\n" ;
            s "    _rec.spin_rendezvous = _stress_tally_h[HET_TALLY_RDV];\n" ;
            s "    _rec.spin_cap = _stress_tally_h[HET_TALLY_CAP];\n" ;
            s "    _rec.stress_truncated = _stress_tally_h[HET_TALLY_TRUNC];\n" ;
            s "    _rec.gpu_stress_rounds = _stress_tally_h[HET_TALLY_STRESS_ROUNDS];\n" ;
            s "    _rec.cpu_enemies = _ct.enemies_realised;\n" ;
            s "    _rec.cpu_enemy_rounds = _ct.enemy_rounds;\n" ;
            s "    _rec.cpu_enemy_accesses = _ct.enemy_accesses;\n" ;
            s "    _rec.cpu_preload_ops = _ct.preload_ops;\n" ;
            s "    _rec.noise_cpu_rounds = _ct.noise_cpu_rounds;\n" ;
            s "    _rec.noise_cpu_words = _ct.noise_cpu_words;\n" ;
            s "    _rec.noise_gpu_blocks = _stress_tally_h[HET_TALLY_NOISE];\n" ;
            s "    _rec.noise_gpu_rounds = _stress_tally_h[HET_TALLY_NOISE_ROUNDS];\n" ;
            s "    _rec.cpu_aff_failures = _ct.aff_failures;\n" ;
            s "    _rec.place_failures = (uint32_t)_het_place_failures;\n" ;
            s "    _rec.noise_ws_mb = (uint32_t)HET_NOISE_MB;\n" ;
            s "    _rec.place_mode = (uint32_t)HET_PLACE;\n" ;
            (* B7b: the window resolution this run REALISED.  HET_NWIN is swept,
               and tau_w/F_win/N_eff are resolution-dependent -- a record scored
               at one nwin must never be silently pooled with another. *)
            s "    _rec.nwin = (uint32_t)HET_NWIN;\n" ;
            List.iter (fun i -> s i.i_scan) insts ;
            (* control_Prep is computed AFTER the control's scan -- it reads
               control_target_count, which is still 0 (memset) until the mu(T) scan
               above has run.  (B6a computed it up front, where it could only ever be
               1 - e^0 = 0; harmless while no control was compiled in, a silent lie
               the moment one was.) *)
            s "    _rec.control_Prep = 1.0 - exp(-(double)_rec.control_target_count);\n" ;
            s "    het_obs_record_print(stdout, &_rec);\n" ;
            (* B6 THE REPORTING CONTRACT (Q4 5): never print a bare "Never".  Every
               null is printed PAIRED with the control that vouches for it, by name
               and with absolute numbers, and a null the controls do not vouch for is
               printed as DISCARD-THIS, not as a result.  This is the harness's own
               output, so the interpretation travels with the number instead of
               living in a note in the thesis. *)
            s "    het_verdict_print(stdout, &_rec);\n" ;
            s "    _recs[_nrec++] = _rec;\n" ;
            (* B7b: the in-binary adaptive loop.  het_campaign_should_stop() is a
               pure function of the records accumulated so far (it inherits every
               B6c oracle frame and B7 statistic for free), so consulting it after
               each run gives the per-test early stop the campaign scheduler needs
               WITHOUT any new decision machinery.  Off (HET_ADAPTIVE unset) the
               loop runs to _runs_budget exactly as B7 did. *)
            s "    if (_adaptive) {\n" ;
            s "      het_campaign_stop_t _stop = het_campaign_should_stop(_recs, _nrec, _runs_budget, _p_goal);\n" ;
            s "      if (_stop != HET_CAMPAIGN_CONTINUE) {\n" ;
            s (Printf.sprintf
                 "        printf(\"HetCampaign %s stop=%%s runs=%%d budget=%%d p_goal=%%g\\n\",\n\
                  \               het_campaign_stop_name(_stop), _nrec, _runs_budget, _p_goal);\n"
                 tname) ;
            s "        break;\n" ;
            s "      }\n" ;
            s "    }\n" ;
            s "  }\n" ;
            (* ======== B7: the statistics post-pass over the aggregated cells =====
               het_verdict() is a PURE function of one record, so the aggregate reuses
               it rather than re-deriving liveness -- inheriting every B4/B5
               disqualifier and all of B6c's oracle-awareness for free.  This is what
               turns "not observed" into "not observed, under quantified effort, with
               the 95% bound on its run-level rate being p < X" -- and it is what
               makes a Never carry a bound at all. *)
            s "  {\n" ;
            s "    het_stats_t _st;\n" ;
            s "    het_stats_compute(_recs, _nrec, &_st);\n" ;
            s "    het_stats_print(stdout, &_st);\n" ;
            s "  }\n" ;
            s (Printf.sprintf "  intmax_t _buff[%d];\n" (max 1 it.i_nslots)) ;
            s (Printf.sprintf "  printf(\"Test %s\\n\");\n" tname) ;
            s (Printf.sprintf "  dump_outs(stdout, _dump_one, hist, _buff, %d);\n"
                 it.i_nslots) ;
            s "  free_outs(hist);\n" ;
            if co_run then
              s "  gd_free_shared(_shared_arena);   /* the one padded arena */\n"
            else begin
              List.iter
                (fun (i,g) -> s (Printf.sprintf "  gd_free_shared(%s);\n" (gsym i g)))
                shared_slots ;
              s "  gd_free_shared(barrier);\n"
            end ;
            List.iter
              (fun i ->
                List.iter
                  (fun (_,_,name,dev,_) ->
                    match dev with
                    | `Gpu ->
                       s (Printf.sprintf "  %s free(%s_h);\n"
                            (dialect.gd_free name) name)
                    | `Cpu -> s (Printf.sprintf "  free(%s);\n" name))
                  i.i_bufs ;
                List.iter
                  (fun l ->
                    let og = obsG_of i.i_pre l and oc = obsC_of i.i_pre l in
                    s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free og) og) ;
                    s (Printf.sprintf "  free(%s);\n" oc))
                  i.i_obs_locs)
              insts ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch_loc")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_spin_bar")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_gpu_done")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_stress_tally")) ;
            s "  free(_scratch_loc_h);\n" ;
            s "  free(_cpu_scratch);\n" ;
            s "  free(_cpu_idx);\n" ;
            s "  free(_ea);\n" ;
            s "  free(_eth);\n" ;
            s "  gd_free_noise(_noise_ddr);\n" ;
            s "  gd_free_noise(_noise_hbm);\n" ;
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
            if co_run then begin
              s "## The positive control is CO-RUNNING in this harness\n\n" ;
              s "This is a should-be-FORBIDDEN test, so its result is a NULL -- and a null\n" ;
              s "is evidence only if the harness would have seen a weak behaviour had one\n" ;
              s "been permitted.  Three het instances therefore share this launch, this\n" ;
              s "stress config and this C2C path, on disjoint cache-line-padded locations:\n\n" ;
              List.iter
                (fun i ->
                  s (Printf.sprintf "- `%s` (%s) -- prefix `%s`, K=%d\n"
                       i.i_name (role_note i.i_role) i.i_pre i.i_k))
                insts ;
              s "\nSee `het_verdict.h` for the rule that turns their counts into a verdict.\n\n"
            end ;
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
          write "het_verdict.h"
            (fun ch -> output_string ch het_verdict_content) ;
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
                          let het_emit_body ch ~prefix ~proc ~k ~store_mu ~load_buf
                                ~reg_env ~iter ~addr_params ~buf_params pseudos =
                            HetCpuBody.emit_body ch ~prefix ~proc ~k ~store_mu
                              ~load_buf ~reg_env ~iter ~addr_params ~buf_params
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
                          let het_emit_body ch ~prefix ~proc ~k:_ ~store_mu:_
                                ~load_buf:_ ~reg_env:_ ~iter:_ ~addr_params
                                ~buf_params _pseudos =
                            HetCpuBody.emit_stub ch ~prefix ~proc ~addr_params
                              ~buf_params
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
