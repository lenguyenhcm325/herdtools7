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

(* HetLitmus: the compound (CPU+GPU) harness emitter.

   One `Het' test becomes one self-contained harness directory: the CPU
   proc(s) as real ISA asm via ASMLang, the GPU procs as a CUDA and a HIP
   render of a single driver template, plus the runtime headers and a build
   script.  The seam back to Top's scope is three functor parameters ([O] an
   options slice, [SP] the splitter, [CpuKit] the compiled-CPU-code extractor
   closed at the dispatch site), so this file does not depend on
   top_litmus.ml.  Design: hetlitmus/docs/het-emission.md. *)

open Answer

(* The slice of top_litmus's Config this emitter needs: GenParser.Config for
   the het GenParser instance, plus the run-loop geometry (size = the
   free-running window N, runs = the outer instance loop; see
   hetlitmus/docs/00-environment-design.md sec 3.4).  top_litmus's full Config
   satisfies it structurally. *)
module type Config = sig
  include GenParser.Config
  val size : int
  val runs : int
end

  (* ===================== HetLitmus: GPU back-end dialect ===================
     The combined CPU+GPU harness is emitted for BOTH CUDA and HIP from ONE
     LISA parse.  CudaLang and HipLang share the layout / globals /
     result-register analysis byte-for-byte, so a `gpu_dialect' carries only the
     per-instruction lowering and the few differing host tokens, and one driver
     template is rendered twice (<t>.cu, <t>.hip).  Per-target behaviour is
     added as a FIELD here, never as a branch in the template. *)
  type gpu_dialect = {
      gd_ext : string ;             (* output extension: "cu" | "hip" *)
      gd_name : string ;            (* "CUDA" | "HIP" *)
      (* Toolchain facts, read by the emitted comp.sh / Makefile / README.  A
         vendor supplies values here instead of a hand-written arm in each of
         those files. *)
      gd_target : string ;        (* comp.sh/make target word: "cuda" | "hip" *)
      gd_vendor : string ;        (* "NVIDIA" | "AMD" *)
      gd_toolchain : string ;     (* named when its compiler is absent *)
      gd_compiler : string ;      (* "nvcc" | "hipcc" *)
      gd_compiler_var : string ;  (* build variable holding it: "NVCC" | "HIPCC" *)
      gd_arch_var : string ;      (* "CUDA_ARCH" | "HIP_ARCH" *)
      gd_arch_default : string ;  (* "sm_90" | "gfx942" *)
      gd_arch_device : string ;   (* the device that default names: "GH200" *)
      gd_arch_flag : string ;     (* "-arch=" | "--offload-arch=" *)
      gd_arch_flag_first : bool ; (* compile line: arch flag before -std=c++17 *)
      gd_obj_suffix : string ;    (* GPU object stem suffix: "" | "_hip" *)
      gd_readme_files : string ;  (* this render's entry in README's file list *)
      gd_runtime_include : string ; (* the differing GPU atomics/runtime header *)
      (* [~tag] selects the tagged/uint64 store path (Some (iter,k,mu)) over the
         standalone GPU-only path (None); a structural tuple, so this one field
         unifies across CudaLang and HipLang. *)
      gd_dump_instr :
        out_channel -> tag:(string * int * int) option -> string ->
        BellBase.instruction -> unit ;
      gd_device_sync : string ;     (* host-side device-sync statement *)
      gd_free : string -> string ;  (* var -> free statement *)
      gd_bar : string -> string -> string ; (* indent, ptr-expr -> arrive+spin *)
      (* Per-target allocator for the shared litmus vars + the rendezvous
         barrier; the banner in [gd_shared_mem_defs] states why the choice is
         correctness rather than tuning (env-research/Q8-allocation.md).
         [gd_shared_mem_defs] emits the file-scope gd_alloc_shared /
         gd_free_shared, so call sites stay dialect-agnostic C;
         [gd_shared_mem_note] is the harness-header banner comment.  __out is
         NOT routed through these. *)
      (* The page-placement lever HET_PLACE drives, by its API name -- a DIALECT
         fact, not a machine one: it is the vendor runtime call the render
         contains.  None where the render carries no placement code at all (the
         HIP lane refuses a non-zero HET_PLACE at compile time), and then
         het_verdict.h names the mechanism instead. *)
      gd_place_lever : string option ;
      gd_shared_mem_note : string ;  (* "shared vars" banner comment *)
      gd_shared_mem_defs : string ;  (* file-scope gd_alloc_shared / gd_free_shared defs *)
      (* The interconnect-stress allocator: a FOURTH object class -- large system
         buffers homed on the OTHER processing unit, so stream-reading them
         crosses the interconnect.  A field rather than a branch because the two
         targets differ in kind: GH200 places pages across an LPDDR/HBM split,
         MI300A has one HBM pool and gets its interconnect pressure from
         cross-chiplet contention instead
         (env-research/Q6-cpu-interconnect-stress.md sec 3.2/3.4). *)
      gd_noise_mem_defs : string ;   (* file-scope gd_alloc_noise / gd_free_noise *)
      (* Cooperative-launch API tokens, used only for the co-residency +
         weak-progress guarantee of the persistent kernel; the CPU<->GPU
         rendezvous stays [gd_bar] (a system-scope atomic), so no grid.sync and
         no cooperative_groups.h. *)
      gd_err_t : string ;         (* "cudaError_t"      | "hipError_t" *)
      gd_success : string ;       (* "cudaSuccess"      | "hipSuccess" *)
      gd_errstr : string ;        (* error-code -> message fn *)
      gd_dev_attr : string ;      (* device-attribute query fn *)
      gd_attr_coop : string ;     (* cooperative-launch support attribute enum *)
      gd_attr_smcount : string ;  (* multiprocessor-count attribute enum *)
      gd_occupancy : string ;     (* max-active-blocks-per-SM occupancy query fn *)
      gd_coop_launch : string ;   (* cooperative kernel-launch fn *)
      (* Read-buffer device-memory tokens.  The per-load read buffers live in
         DEVICE memory, off the coherent race path -- buffer writes must not add
         interconnect traffic that perturbs the tested race -- and are mirrored
         host-side after the terminal sync for the recovery scan. *)
      gd_dev_malloc : string -> string -> string ;   (* var, bytes -> device alloc *)
      gd_memcpy_d2h : string -> string -> string -> string ; (* dst, src, bytes *)
      gd_dev_memset0 : string -> string -> string ;  (* ptr, bytes -> zero device mem *)
      (* Host->device copy for the per-run stress scratch-location layout (chosen
         host-side by het_set_scratch_locations, consumed by every stressing
         lane).  The scratchpad is device memory -- GPU-only and disjoint from
         every test location -- so it never goes through gd_alloc_shared. *)
      gd_memcpy_h2d : string -> string -> string -> string ; (* dst, src, bytes *)
      (* A relaxed system-scope uint64 load of a shared var, used by the GPU
         observer lane to snoop a coherence (ws) location.  Analysis-only, never
         the tested order; given the global's C pointer name. *)
      gd_sys_load_u64 : string -> string ;           (* ptr -> load expression *)
    }

  let cuda_dialect = {
      gd_ext = "cu" ; gd_name = "CUDA" ;
      gd_target = "cuda" ; gd_vendor = "NVIDIA" ; gd_toolchain = "CUDA" ;
      gd_compiler = "nvcc" ; gd_compiler_var = "NVCC" ;
      gd_arch_var = "CUDA_ARCH" ; gd_arch_default = "sm_90" ;
      gd_arch_device = "GH200" ;
      gd_arch_flag = "-arch=" ; gd_arch_flag_first = false ;
      gd_obj_suffix = "" ;
      gd_readme_files =
        "GPU kernel + host driver, CUDA dialect (gd_alloc_shared:\n\
         \             system malloc on GH200 / cudaMallocManaged fallback for the shared vars +\n\
         \             barrier, cuda::atomic_ref system-scope barrier, pthread + kernel launch).\n" ;
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
      gd_place_lever = Some "cudaMemAdvise" ;
      gd_shared_mem_note =
        "// Shared vars + barrier use gd_alloc_shared: system malloc() on GH200 (ATS =>\n\
         // cache-line CHI coherence over NVLink-C2C, the real inter-device protocol);\n\
         // cudaMallocManaged only as the dev-box/CI fallback (managed = 2 MB page\n\
         // migration on GH200, which masks the race).\n" ;
      gd_shared_mem_defs = HetPayloads.het_alloc_cuda_inc ;
      gd_noise_mem_defs = HetPayloads.het_noise_cuda_inc ;
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
      gd_target = "hip" ; gd_vendor = "AMD" ; gd_toolchain = "HIP/ROCm" ;
      gd_compiler = "hipcc" ; gd_compiler_var = "HIPCC" ;
      gd_arch_var = "HIP_ARCH" ; gd_arch_default = "gfx942" ;
      gd_arch_device = "MI300A" ;
      gd_arch_flag = "--offload-arch=" ; gd_arch_flag_first = true ;
      gd_obj_suffix = "_hip" ;
      gd_readme_files =
        "same harness, HIP dialect (gd_alloc_shared: fine-grained\n\
         \             hipMallocManaged, __hip_atomic_*).\n" ;
      gd_runtime_include = "#include <hip/hip_runtime.h>" ;
      gd_dump_instr = HipLang.dump_instr ;
      (* no (void) cast: the driver binds this and checks its status *)
      gd_device_sync = "hipDeviceSynchronize();" ;
      gd_free = (fun v -> Printf.sprintf "(void)hipFree(%s);" v) ;
      gd_bar =
        (fun ind ptr ->
          Printf.sprintf
            "%s(void)__hip_atomic_fetch_add((%s), 1, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);\n\
             %swhile (__hip_atomic_load((%s), __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM) < NPART) { }\n"
            ind ptr ind ptr) ;
      (* No placement lever on this lane: MI300A has one HBM pool and nothing to
         place, and het_alloc_hip.inc turns a non-zero HET_PLACE into an #error. *)
      gd_place_lever = None ;
      gd_shared_mem_note =
        "// Shared vars + barrier use gd_alloc_shared: fine-grained hipMallocManaged on\n\
         // MI300A -- the only mode coherent for system-scope CPU<->GPU sync during a\n\
         // live kernel (coarse-grained is visible only at kernel boundary).\n" ;
      gd_shared_mem_defs = HetPayloads.het_alloc_hip_inc ;
      gd_noise_mem_defs = HetPayloads.het_noise_hip_inc ;
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

  (* THE DIALECT REGISTRY.  Every per-vendor site -- the renders themselves and
     every arm, header sentence and narrative of the emitted comp.sh / Makefile
     / README -- folds over this list, so a vendor is added by adding an entry.
     `-gpu-target' (hetTarget.ml) filters it: an emission sees ONE entry, and
     the folds below then name only that vendor.  List order is emission order;
     the head is what the build files default to. *)
  let dialects = [ cuda_dialect ; hip_dialect ]

  (* The `-gpu-target' vocabulary IS this list's target column; litmus7's option
     help reads it here rather than repeating the words. *)
  let target_doc = String.concat "|" (List.map (fun d -> d.gd_target) dialects)

  (* The GPU object this render compiles to, and the compile-line flags, given
     the arch reference as each build file spells it ("$CUDA_ARCH" in sh,
     "$(CUDA_ARCH)" in make). *)
  let gpu_obj d tname = Printf.sprintf "%s%s.o" tname d.gd_obj_suffix
  let gpu_cflags d aref =
    let a = d.gd_arch_flag ^ aref in
    if d.gd_arch_flag_first then a ^ " -std=c++17" else "-std=c++17 " ^ a

  (* ===================== HetLitmus: the compound emitter ===================
     A functor over the CPU module chain (Arch_litmus + Compile_litmus + a small
     column frontend), applied at AArch64 or X86_64 by the `Het' dispatch arm,
     which pre-scans the per-column device tag.  The GPU side is fixed
     (LISA/Bell -> CudaLang/HipLang).  Every CPU reference below goes through the
     [Cpu]/[CpuF] parameters, so the body is ISA-agnostic.
     See hetlitmus/docs/het-emission.md. *)
  module Make
      (Cfg : Config)
      (O : sig
         val verbose : int
         val nocatch : bool
         val is_out : bool
         val tarname : string
         val check_rename : string -> string option
       end)
      (SP : sig val split : string -> in_channel -> Splitter.result end)
      (Cpu : Arch_litmus.S)
      (CpuF : sig
         (* lex+parse ONE processor column's ';'-free instruction text with the
            matching ISA sub-parser (errors name the proc + ISA + column) *)
         val parse_column : int -> string -> Cpu.parsedPseudo list
         val isa_name : string         (* human label, e.g. "AArch64" *)
         (* the module that emits this ISA's tagged body, named in the emitted
            <t>_cpu.c banner so the artifact says which emitter produced it *)
         val body_module : string
         val host_macro : string       (* CPP macro true on the CPU host ISA *)
         (* (clang triple, -std) to cross-assemble the real CPU asm on a foreign
            dev host; None when the build host already IS this ISA (native gcc) *)
         val cross : (string * string) option
         (* NO PAIR FIELDS HERE.  [isa_name] is this module's whole contribution
            to the pair question: it is one coordinate of the (CPU ISA x GPU
            dialect) pair litmus/hetOracle.ml keys the control map and the machine
            prose on. *)
         (* The tagged-CPU-body hooks -- the ONLY CPU-ISA-specific pieces of the
            het emitter (the AArch64 arm wires HetCpuBody, the x86_64 arm its
            twin HetCpuBodyX86; both produce the same C shape and share
            [cpu_plan]).  [het_analyze] resolves one CPU
            proc's store/load structure (addresses via [reg_env]: addr-reg-name
            -> global C name), feeding the mu map, the read-buffer plan and the
            recovery map.  [het_emit_body] emits the tagged
            het_run_<prefix>P<proc>: store values rebound to K*(_n+1)+mu, loads
            recorded into per-iteration buffers, tested mnemonics and DMB SY
            verbatim.  [~prefix] is what keeps the co-running instances of a
            control harness apart -- without it T's P0 and mu(T)'s P0 are both
            `het_run_P0'. *)
         val het_analyze :
           reg_env:(string -> string) -> Cpu.pseudo list -> HetCpuBody.cpu_plan
         val het_emit_body :
           out_channel -> prefix:string -> proc:int -> k:int ->
           store_mu:(int -> int) -> load_buf:(int -> string) ->
           reg_env:(string -> string) ->
           iter:string -> addr_params:(string * string) list ->
           buf_params:(string * string) list -> Cpu.pseudo list -> unit
       end)
      (CpuKit : sig
         (* Tier-2 CPU backend seam: the REAL litmus7 compile pipeline for the
            CPU ISA (top_litmus.Make -> Compile.Make), reused so the CPU
            thread's inline asm comes from ASMLang (not a hand-rolled
            emitter).  Driven on a CPU-only projection of the het test;
            returns the compiled per-proc templates (Test_litmus [code]). *)
         val compile_code :
           Name.t ->
           (Cpu.location, Cpu.V.v, Cpu.pseudo, Cpu.FaultType.t) MiscParser.r3 ->
           (Proc.t * (Cpu.Out.t * ((Cpu.reg * CType.t) list * string list)))
             list
       end) =
    struct
      (* GPU side is fixed: LISA/Bell frontend + CudaLang/HipLang lowering. *)
      module GpuInstr = Instr.No(struct type instr = BellBase.instruction end)
      module GpuV = Int64Constant.Make(GpuInstr)
      module Gpu = LISAArch_litmus.Make(GpuV)
      module Arch' = HetArch.Make(Cpu)(Gpu)
      (* the debuglexer/check_rename slice of Top's LexConfig, rebuilt from
         the O seam so this file does not depend on top_litmus.ml *)
      module LexConfig = struct
        let debug = O.verbose > 2
        let check_rename = O.check_rename
      end
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

      module AllocArchCpu = struct
          include Cpu
          type v = Cpu.V.v
          let maybevToV = Cpu.maybevToV
          type global = Global_litmus.t
          let maybevToGlobal = Cpu.tr_global
        end
      module AllocCpu = SymbReg.Make(AllocArchCpu)

      let outs_h_content = HetPayloads.outs_h
      let outs_c_content = HetPayloads.outs_c
      (* the ported cuda-litmus GPU stress layer, emitted verbatim into every het
         harness dir and #include'd by both the .cu and the .hip render. *)
      let het_stress_content = HetPayloads.het_stress_cuh
      (* the CPU-side + interconnect stress layer.  A SEPARATE header from
         het_stress.cuh because it is the only place host-ISA asm may live: the
         .cu is nvcc's translation unit, and the preload primitives are AArch64
         (dc civac / prfm) or x86 (clflush / prefetcht0) inline asm.  Only
         <test>_cpu.c -- compiled by gcc, and cross-assembled by
         `clang --target=aarch64-linux-gnu' -- defines HET_CPU_STRESS_IMPL and so
         compiles the bodies; the .cu gets the knobs, the arg structs and the
         declarations, and NOT ONE LINE of host ISA. *)
      let het_cpu_stress_content = HetPayloads.het_cpu_stress_h
      (* het_obs_record + the null-credibility decision rule.  Shared with the
         verdictcheck gate, so the gate runs the rule that ships. *)
      let het_verdict_content = HetPayloads.het_verdict_h

      (* ======================= THE CO-RUN EMITTER ===========================
         A harness may carry more than one het instance in one translation unit:
         the test under study T, its minimal mutant mu(T) and the canary (see
         hetlitmus/docs/positive-control.md sec 5).  What that costs this emitter,
         and what each invariant prevents:

           - K (the store-tag modulus) is PER INSTANCE ([i_kmac]), never one
             TU-wide K_TAG: it is 3 for MP/SB/LB and 4 for R/S, and the canary is
             always an MP, so an R/S harness genuinely mixes both.  A tag decoded
             with the wrong K mis-attributes writer (tag % K) and iteration
             (tag / K) alike, making the recovered cycles fiction.
           - C identifiers are prefixed t_ / mu_ / can_, ALL THREE of them, so a
             missed prefix fails to compile instead of silently binding to T's
             object.  A single-instance harness keeps prefix "".
           - every participant count (NPART, blocks, lanes) is a SUM over the
             instances, never a constant: S and R carry observer lanes, so a
             hardcoded total would let the system-scope rendezvous release before
             their observers arrive -- a barrier that looks alive and is not.
           - each instance carries its own frame binding, detector, recovery scan
             and exhaustive_valid.

         The one thing NOT prefixed is the GPU lane's view of its own locations:
         CudaLang/HipLang name a global by its LISA name (`*x') and they are
         SHARED backends this file may not touch, so each lane opens with a local
         alias (`uint64_t* x = t_x;') that binds the emitted `*x' to this
         instance's object without changing the lowering. *)

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
          (* THE dialect list for this emission: `-gpu-target' filtered, so every
             per-vendor fold below renders and names one vendor.  Resolved before
             the parse -- an unregistered target must refuse having written
             nothing. *)
          let dialects = HetTarget.select ~key:(fun d -> d.gd_target) dialects in
          (* THE PAIR ROW for this emission, resolved in the same breath and for
             the same reason: an ABSENT (CPU ISA x GPU dialect) pair must refuse
             having written nothing.  One dialect survives the filter, so the pair
             is fixed here. *)
          let pair =
            HetOracle.resolve ~cpu_isa:CpuF.isa_name
              ~target:(List.hd dialects).gd_target in
          let parsed = P.parse in_chan splitted in
          close_in in_chan ;
          let tname = splitted.Splitter.name.Name.name in
          let doc = splitted.Splitter.name in
          let nprocs_total = List.length parsed.MiscParser.prog in
          (* D10 (memo 7.D10): is the CYCLE of the test under study CPU-ONLY?
             MEASURED from the per-column device tags, never from the name --
             a name-based rule would silently mis-classify anything renamed.
             A CPU-only test on the shared allocation is not a compound-model
             experiment at all: it tests x86-TSO on this silicon, so a sighting
             of a forbidden outcome indicts x86-TSO (or the memory type of the
             allocation, memo 8 P1) and NEVER the CMCM.  het_verdict.h owns that
             sentence; this flag is what lets it be written. *)
          let cpu_only =
            parsed.MiscParser.prog <> [] &&
            List.for_all
              (fun ((_,annot,_),_) ->
                match annot with Some ("cpu"::_) -> true | _ -> false)
              parsed.MiscParser.prog in
          (* The positive-control map: mu(T) and the canary to co-run
             (litmus/hetControlMap.ml).  A pair with no registered map reads NONE
             (D-MV5): mu(T) is a weakening on a PARTICULAR strength lattice, so a
             map borrowed from another pair names siblings that are not weakenings
             here.  Such a harness is single-instance and -- with no control built
             -- het_verdict() calls its nulls COLD-INVALID and says why.  The
             bootstrap map generator for a new pair is deliberately future work;
             until it exists, characterizing without one is the honest state. *)
          let src_dir = Filename.dirname src_name in
          let cmap =
            match pair with
            | HetOracle.Oracle p ->
               HetControlMap.load ~verbose:O.verbose ~dir:src_dir
                 ~csv:p.HetOracle.op_control_map_csv ~src_name
            | HetOracle.Characterize _ | HetOracle.Override ->
               HetControlMap.empty in
          let mu_name = HetControlMap.control_of cmap tname
          and canary_name = HetControlMap.canary_of cmap tname in
          (* WHICH MACHINE THIS HARNESS MAY NAME, for the emitted stderr WARNINGs
             -- the two halves of the interconnect noise and the link between
             them.  It comes from the PAIR ROW (litmus/hetOracle.ml), which is
             also what stamps the HET_LINK_NAME / HET_HOST_HALF / HET_DEV_HALF
             defines het_verdict.h prints from, so the driver's wording and the
             verdict's wording cannot disagree: one record feeds both. *)
          let mc =
            match HetOracle.machine_of pair with
            | Some m -> m
            | None -> HetOracle.generic_machine in
          let host_half = mc.HetOracle.mc_host_half
          and dev_half = mc.HetOracle.mc_dev_half
          and link_name = mc.HetOracle.mc_link_name in
          (* The (CPU ISA x GPU dialect) this harness was BUILT for, as the short
             name the verdict layer prints where it has to identify the target.
             A build fact, so every pair stamps it -- unlike [mc], which an
             unregistered pair leaves unstamped. *)
          let pair_label =
            HetOracle.pair_name ~cpu_isa:CpuF.isa_name
              ~target:(List.hd dialects).gd_target in
          (* WHETHER A POSITIVE-CONTROL MAP WAS READ AT ALL.  A pair with no
             registered map reads none, so nothing in such a harness marks any row
             the canary and its missing bound is deferred rather than structural --
             het_verdict.h has to be able to tell those two apart. *)
          let no_control_map =
            match pair with
            | HetOracle.Oracle _ -> false
            | HetOracle.Characterize _ | HetOracle.Override -> true in
          (* What goes in HET_CANARY_NAME / _rec.canary_name.  A name is NOT a
             co-run signal -- the map names a canary for every test, including the
             ones that are the canary.  HET_CANARY_COMPILED_IN, set from the
             instance population below, is the co-run signal. *)
          let canary_named =
            match canary_name with
            | Some _ as c -> c
            | None ->
               if HetControlMap.is_self_canary cmap tname then Some tname
               else None in

          (* ============ derive ONE instance from a parsed het test =============
             A function of (role, prefix, K-macro, name, parse), so one derivation
             produces T, its minimal mutant and the canary alike.  The decode
             function and the recovery scan are rendered HERE, because they are
             pure C over host buffers and need no dialect; that keeps the record
             small and both render passes readable. *)
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
            let cpu_code = CpuKit.compile_code doc cpu_allocated in
            (* the ASMLang address params of one CPU proc, in ASMLang's order *)
            let cpu_addrs_of out =
              let addrs,_ptes = Cpu.Out.get_addrs out in addrs in
            let params =
              List.map
                (fun (proc,(out,(_outregs,_envV))) -> (proc, out, cpu_addrs_of out))
                cpu_code in
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
            (* ============ the K*(_n+1)+mu store-tagging plan ================
               Every store carries a tag whose modulus decodes the writer and whose
               quotient decodes the iteration; that is what makes recovery
               clock-independent (docs/00-environment-design.md sec 3.4). *)
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
            (* ---- observers: the locations an [ell]=v atom is decided on ---- *)
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
            (* ---- condition -> C predicate over the read buffers ---- *)
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
            (* ======================= FRAME BINDING ========================== *)
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
            (* Every tag decode below spells K as THIS INSTANCE's macro [kmac],
               never a translation-unit-wide K_TAG; see the co-run banner above. *)
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
            (* HARD INVARIANT, checked here for EVERY instance: the emitted
               weak-behaviour detector may never be a CONSTANT.  A constant-true
               one reports the weak behaviour on every run; a constant-false one
               reports "Never" on every run, and a spurious "Never" on a
               should-be-forbidden test reads as confirmation of the memory model.
               On a control the same two failures read as "permanently cold" and
               "every null credible for free", and both look like a working
               control from outside.  Refusing to emit is structural, so it cannot
               regress (env-research/impl-briefs/SHARED-CHARGE.md). *)
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
               Only T feeds the outcome histogram -- a control is a separate
               instance and its outcomes must never pollute T's -- so only T needs
               a decoder, keyed on its own K. *)
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
                (* A coherence-final [ell] column is never MEASURED here: the
                   perpetual loop reads no location's final value, so `_o[n_reg+j]'
                   is the literal 0 at every call site, and an [ell]=v atom is
                   instead decided by the per-run observer ws witness reported
                   through HetObs / HetVerdict.  The columns therefore print `?';
                   printing the 0 would assert a state the test cannot end in, next
                   to the `*' witness marker that says the opposite.  `_labels' is
                   untouched -- the [ ] label still names the atom, and cram
                   pfix-cond.t pins it.  (env-research/impl-briefs/FA-FB-REPORT.md) *)
                s {ocaml|static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
  fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
|ocaml} ;
                if loc_slots = [] then begin
                  s (Printf.sprintf "  for (int i=0;i<%d;i++)" nslots) ;
                  s {ocaml| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
|ocaml}
                end else begin
                  if n_reg > 0 then begin
                    s (Printf.sprintf "  for (int i=0;i<%d;i++)" n_reg) ;
                    s {ocaml| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
|ocaml}
                  end else s "  (void)o;   /* every column is an unmeasured location */\n" ;
                  s (Printf.sprintf
                       "  for (int i=%d;i<%d;i++) fprintf(_ch, \"%%s=?; \", _labels[i]);\n"
                       n_reg nslots)
                end ;
                s {ocaml|  fprintf(_ch, "\n");
}

|ocaml} ;
                Buffer.contents b
              end in
            (* ================= the pre-rendered RECOVERY SCAN =================
               Pure C over host buffers, so it needs no dialect.  The instance's
               ROLE picks which channel of het_obs_record it feeds:
                 RTest   -> target_count_{exhaustive,heuristic}, interleavings,
                            frames_examined, skew/distinct, observer, the histogram
                 RMu     -> control_target_count / control_frames_examined
                 RCanary -> canary_target_count / canary_frames_examined
               It is the SAME scan for all three: a control is not special-cased,
               it is another instance whose target the identical scan tallies.  Each
               carries its own frame binding, detector and exhaustive_valid, because
               the shapes differ. *)
            let scan =
              let b = Buffer.create 4096 in
              let s = Buffer.add_string b in
              let is_test = role = RTest in
              let frames_field, exh_field = match role with
                | RTest -> "frames_examined", "exhaustive_valid"
                | RMu -> "control_frames_examined", "control_exhaustive_valid"
                | RCanary -> "canary_frames_examined", "canary_exhaustive_valid" in
              (* The control's count and its per-window sub-tally are bumped
                 together, on one line under one predicate: that is what makes
                 `sum(win[]) == total' an invariant het_stats_compute can check at
                 RUN time (HET_ST_WIN_DESYNC).  A tally checked only structurally
                 can be dead-code-eliminated and still pass every gate. *)
              let count_field = match role with
                | RTest -> None                     (* two channels; see below *)
                | RMu -> Some ("control_target_count", "control_win")
                | RCanary -> Some ("canary_target_count", "canary_win") in
              (* The control channel is the only windowed one: T's target is far
                 too rare to estimate a variance from -- which is why it needs a
                 bound at all -- while the control is a high-rate proxy on the same
                 fabric in the same run (env-research/Q3-stats.md sec 3.3). *)
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
              (* observer ws recovery -- a per-RUN witness, not a per-frame one. *)
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
                  (* This test HAS an observer decode, so the degeneracy guard may
                     read observer_unique_count.  For a store-only shape it is the
                     only channel there is: no reader means no synchrony decode, so
                     distinct_decoded_iters and skew_stddev are structurally 0 and a
                     guard reading those would call every such cell degenerate. *)
                  s "    _rec.obs_valid = 1;\n"
                end else
                  s "    (void)_obs_uniq;  /* the controls report only their target count */\n" ;
                s (Printf.sprintf "    int %s = %s;\n" locv loc_expr) ;
                (* WHICH OBSERVER RECOVERED THE `co' EDGE.  loc_expr is the
                   disjunction of the CPU-observer decode and the GPU-observer
                   decode, and on a CPU-ONLY test (D10) the difference decides
                   what the sighting is EVIDENCE OF: x86-TSO constrains the order
                   in which x86 agents see two x86 stores, and the GPU is not an
                   x86 agent, so a co edge seen only through the GPU observer is
                   NOT an x86-TSO statement at all.
                   MEASURED 2026-08-03 (i5-12500H + RTX 3060, HET_ALLOC=pinned):
                   2+2W-cpuonly-x86_64 reported a corroborated sighting, 10 of 10
                   runs, with ws_via_obs=1 -- and its detector is exactly this
                   disjunction.  Without recording the two arms separately, the
                   run log could not tell an Intel TSO violation from a GPU
                   observing two CPU stores out of order.  Recorded for the test
                   under study only; the controls report only their target count. *)
                if is_test then begin
                  let cprop = prop_of parsed.MiscParser.condition in
                  s (Printf.sprintf "    _rec.obs_ws_via_cpu = %s;\n" (c_loc "c" cprop)) ;
                  s (Printf.sprintf "    _rec.obs_ws_via_gpu = %s;\n" (c_loc "g" cprop))
                end
              end ;
              (* exhaustive_valid, PER INSTANCE and per shape.  T_L<=1: every frame
                 decodes exactly, so the O(N) scan is ground truth at any N.  T_L>=2:
                 valid only where the O(N^T_L) search actually ran.  Keying it off
                 (N <= HET_EXHAUSTIVE_MAX) for every test instead would make it 0 at
                 production N everywhere, and the verdict constantly COLD. *)
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
                match read_buffers with
                | [] ->
                   (* A store-only shape has no reader, so there is no interleaving
                      to detect: interleavings_detected stays memset-0 and the
                      observer channel (obs_valid) carries this test's liveness
                      instead, which is the channel het_verdict reads for it.
                      Emitting `int _hot = 0;' here would ship a constant-false
                      detector -- the same thing the _weak guard above refuses. *)
                   ()
                | _ ->
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
                      (* A control counts its WINDOWED detector, because that is the
                         count actually measured at production N.  Some mutants are
                         themselves T_L>=2 shapes whose exhaustive scan does not run
                         above HET_EXHAUSTIVE_MAX, so keying the control off the
                         exhaustive count would leave control_target_count zero by
                         construction and their nulls COLD forever -- a control that
                         cannot fire is not a control.  The window is a subset of the
                         full range under the SAME predicate, so it can miss cycles
                         but never invent them: under-counting errs toward COLD.
                         control_exhaustive_valid travels alongside so a reader can
                         see which kind of count it is
                         (hetlitmus/docs/positive-control.md sec 5). *)
                      s (bump_count f w))) ;
              (* liveness guard: the synchrony decode must actually VARY. *)
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
              (* Histogram: T only, and ONLY where an outcome is a per-FRAME fact.
                 A store-only shape (read_buffers = []) has no reader, so its `_weak'
                 is the bare run-level `_loc' -- the observer's ws witness over the
                 WHOLE run, computed before this loop and constant inside it.  Adding
                 it here would stamp one per-run observation into the histogram N
                 times, printing a total that exceeds the frames examined and is a
                 per-frame tally of nothing.  The per-RUN entry below is the sole
                 correct tally for those shapes
                 (env-research/impl-briefs/FA-FB-REPORT.md; gated by histcheck.py). *)
              if is_test && read_buffers <> [] then begin
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
                  (* This test HAS a synchrony decode, so the degeneracy guard may
                     read distinct_decoded_iters / skew_stddev.  The flag says the
                     fields are POPULATED, not that they are healthy: without it a
                     zero would be indistinguishable from "never measured". *)
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
                    (* The per-window stream must collapse WITH the count, or
                       sum(win[]) != total fires the WIN_DESYNC alarm on a harness
                       behaving exactly as designed.  No control in the shipped
                       corpus is a store-only shape, so this arm is unreached today;
                       it stays because that invariant is the only run-time evidence
                       the sub-tallies are alive, and one that can misfire is one
                       nobody will trust. *)
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
             A should-be-FORBIDDEN test -- the only kind for which control-map.csv
             names a mu -- becomes a THREE-instance harness: T + mu(T) + the canary,
             in the same launch, under the same stress, on the same C2C path, on
             disjoint cache-line-padded locations.

             Every other test co-runs the canary alone (T + canary).  Without it a
             non-firing test is as uninterpretable as a bare "Never": nothing tells
             "the harness was hot and this behaviour did not surface" -- an
             observability result -- from "the harness was dead".  A mutant is what
             the others cannot have: it presupposes a known-forbidden cycle to
             weaken (MC-Mutants sec 1.2).

             A test that IS the canary cannot co-run itself, so it stays
             single-instance with prefix "".
             (hetlitmus/docs/positive-control.md sec 5 and 11.) *)
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
          (* THE TWO FLAGS ARE NOT THE SAME CLAIM: collapsing them is how a null on
             a test with no mutant would start reading as vouched-for.  Both are
             computed from the emitted instance population, never from the map,
             which names a canary even for tests that co-run none. *)
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
          if O.verbose >= 0 then begin
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
                 HET_CONTROL_COMPILED_IN=%d HET_CANARY_COMPILED_IN=%d\n%!"
                npart test_blocks gpu_lanes spin_lanes
                (if has_mu then 1 else 0) (if has_canary then 1 else 0)
            end ;
            Printf.eprintf
              "  pair: %s%s\n%!" pair_label
              (if cpu_only then "  [D10 CPU-ONLY cycle]" else "") ;
            (* The `none' sentinel is a DERIVED absence, not a missing row, and
               the two must not read alike in a build log: this test co-runs the
               Layer-B canary alone because the corpus contains no weakening of
               it, so its null is canary-only by construction, forever. *)
            if HetControlMap.no_mutant_exists cmap tname then
              Printf.eprintf
                "  NOTE: the map's Mu column for %s is `none' -- no strictly weaker \
                 structural sibling EXISTS for it (control-map MuRule says why).  \
                 HET_CONTROL_COMPILED_IN=0 by derivation: canary only, so every \
                 null from this test is NOT-OBSERVED-CANARY-ONLY.\n%!"
                tname
          end ;
          let het_iter = "(_n + 1)" in
          let id = CudaLang.c_ident tname in
          (* ================= file emission ================= *)
          let base =
            if O.is_out && (try Sys.is_directory O.tarname with _ -> false)
            then O.tarname else Sys.getcwd () in
          let dir = Filename.concat base tname in
          if not (Sys.file_exists dir) then Sys.mkdir dir 0o755 ;
          let write fname f =
            Misc.output_protect f (Filename.concat dir fname) in
          (* het-CPU signature helpers, SHARED by _cpu.c (the body), the .cu extern
             decl, the cpu_args struct and the driver call, so all four stay
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
          (* WHICH TEST GLOBALS THE KERNEL NEEDS AS PARAMETERS.  Not
             [i_gpu_globals]: the GPU OBSERVER lane dereferences every location
             in [i_obs_locs], and on a test where no GPU proc happens to touch
             one of them that pointer would be undeclared.
             MEASURED 2026-08-03 on the D10 CPU-only set, where no GPU proc
             touches anything at all:
               2+2W-cpuonly-x86_64.cu(100): error: identifier "t_x" is undefined
               2+2W-cpuonly-x86_64.cu(101): error: identifier "t_y" is undefined
             -- 2 of the 6 D10 tests would not compile.  The committed het
             corpus never hit it (its 2+2W GPU proc writes BOTH locations, so
             both were already parameters), which is why it surfaced only when
             an all-CPU cycle was first emitted.  Order-preserving and
             append-only, so a test with no observer is byte-identical to
             before. *)
          let kernel_globals i =
            i.i_gpu_globals
            @ List.filter (fun l -> not (List.mem l i.i_gpu_globals))
                i.i_obs_locs in
          (* ---- <tname>_cpu.c : the CPU threads (real ISA asm) ---- *)
          let dump_cpu_file ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "/* HetLitmus: TAGGED CPU threads for %s (%s).\n   \
                  Bodies emitted by HetLitmus %s: the tested mnemonics\n   \
                  verbatim, store values rebound to the per-iteration tag\n   \
                  K*(_n+1)+mu, loads recorded into buffers.\n   \
                  DO NOT EDIT. */\n"
                 tname CpuF.isa_name CpuF.body_module) ;
            if co_run then
              s (Printf.sprintf
                   "/* CO-RUN: this file carries the CPU threads of every co-running\n   \
                    het instance, so each body is named het_run_<prefix>P<proc> and\n   \
                    keeps its OWN K:\n     \
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
            (* _GNU_SOURCE must precede EVERY libc header: het_cpu_stress.h needs
               cpu_set_t / sched_setaffinity for thread pinning, and glibc hides
               both behind it.  After <stdint.h> would already be too late. *)
            s "#define _GNU_SOURCE\n" ;
            s "#include <stdint.h>\n\n" ;
            (* THIS translation unit -- and only this one -- compiles the CPU stress
               bodies.  It is built by gcc for the host, and cross-assembled by clang
               for a foreign CPU ISA, so it is the one place the host-ISA cache
               primitives may live; nvcc compiles the .cu and must never see them. *)
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
          let buf_bytes = "sizeof(uint64_t)*SIZE_OF_TEST" in
          let gpu_bufs i =
            List.filter (fun (_,_,_,dev,_) -> dev = `Gpu) i.i_bufs in

          (* ---- the emitted main(): allocation, launch, the run loop,
                 the recovery scan and teardown ---- *)
          let dump_gpu_main dialect s =
            s "int main(void){\n" ;
            (* Shared litmus vars + barrier, always through gd_alloc_shared.  A
               co-run harness carves them out of ONE arena, one cache line apart:
               separate 8-byte allocations would land several instances' locations
               and the barrier on shared lines, and the cache-line rationale above
               applies.  One allocation, one free, and the free still matches the
               allocator. *)
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
            (* read buffers -- OFF the coherent race path. *)
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
            (* cooperative-launch prelude *)
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
            (* A co-run harness reserves several times the test blocks, so the
               stress population is the first thing the co-residency cap squeezes
               out.  An empty one is a run with no memory stress at all, and on
               NVIDIA silicon that is a run that observes nothing (Alglave
               ASPLOS'15 sec 4.3.1).  The tally would catch it afterwards; warn
               BEFORE the run. *)
            s "  if (HET_MEM_STRESS_PCT > 0 && _stressBlocks == 0)\n" ;
            (* Alglave's "zero without stress" is an NVIDIA measurement (B4), so
               it is cited only where it applies; elsewhere the gap is stated. *)
            s (Printf.sprintf
                 "    fprintf(stderr, \"HetLitmus WARNING: the mem-stress population is EMPTY (test=%%d + noise=%%d fills the co-resident cap %%d).  HET_MEM_STRESS_PCT=%%d asks for scratchpad stress and NO block will do any.  %s\\n\",\n\
               \            _testBlocks, _noiseBlocks, _maxGrid, (int)HET_MEM_STRESS_PCT);\n"
                 (if mc.HetOracle.mc_alglave_zero
                  then "On NVIDIA silicon an unstressed run observes nothing (Alglave ASPLOS'15 4.3.1)."
                  else "(Alglave ASPLOS'15 4.3.1's \\\"zero without stress\\\" was measured on NVIDIA parts and is not claimed for this target; no equivalent figure is published for it.)")) ;
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
            (* ------------------- the CPU stress population -------------------- *)
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
            (* The threshold is this PAIR's last level where a figure exists for
               it, and a disclosed fallback where none does -- naming another
               part's capacity as this one's is the claim this arm refuses. *)
            s "  if (HET_NOISE_MB < HET_LLC_MB)\n" ;
            s (match mc.HetOracle.mc_llc_mb with
               | Some _ ->
                  Printf.sprintf
                    "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%%d is BELOW the last-level cache (%%d MB) -- the noise buffers fit in cache, so the reads are served locally and generate NO interconnect traffic.  This run is NOT %s-stressed%s.\\n\",\n\
                   \            (int)HET_NOISE_MB, (int)HET_LLC_MB);\n"
                    link_name mc.HetOracle.mc_llc_note
               | None ->
                  Printf.sprintf
                    "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%%d is below the %%d MB threshold -- a FALLBACK figure, measured on another part, not a last-level-cache capacity for this target.  A noise buffer that fits in the last-level cache is served locally and crosses no %s, so this run may not be stressed at all%s.\\n\",\n\
                   \            (int)HET_NOISE_MB, (int)HET_LLC_MB);\n"
                    link_name mc.HetOracle.mc_llc_note) ;
            s "  if (_noiseBlocks > 0) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_ddr, (size_t)_noise_words*sizeof(uint64_t), 2);\n" ;
            s (Printf.sprintf
                 "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %%d MB DDR noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB); _noise_ddr = NULL; _noise_blocks = 0; }\n"
                 dev_half link_name) ;
            s (Printf.sprintf
                 "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the DDR noise buffer could not be homed on the CPU -- this device has no interconnect-stress lever (no ATS/coherent host-device link), so %s of the noise is exercising plumbing, not the %s.\\n\");\n"
                 dev_half link_name) ;
            s "  }\n" ;
            s "  if (HET_NOISE_CPU) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_hbm, (size_t)_noise_words*sizeof(uint64_t), 1);\n" ;
            s (Printf.sprintf
                 "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %%d MB HBM noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB); _noise_hbm = NULL; }\n"
                 host_half link_name) ;
            s (Printf.sprintf
                 "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the HBM noise buffer could not be homed on the GPU -- %s of the noise is exercising plumbing, not the %s.\\n\");\n"
                 host_half link_name) ;
            s "  }\n" ;
            s "  fprintf(stderr, \"HetLitmus cpu-stress: cores=%d test=%d enemies=%d spread=%u stride=%d seq=%d preload=%d%% aff=%d | noise: gpu_blocks=%u cpu=%d words=%llu (%d MB) place=%d\\n\",\n\
               \          _ncores, _nCpuTest, _nEnemy, _cpu_spread, (int)HET_CPU_STRIDE,\n\
               \          (int)HET_CPU_ENEMY_SEQ, (int)HET_CPU_PRELOAD_PCT, _aff,\n\
               \          _noise_blocks, (int)HET_NOISE_CPU,\n\
               \          (unsigned long long)_noise_words, (int)HET_NOISE_MB, (int)HET_PLACE);\n" ;
            s "  outs_t* hist = NULL;\n" ;
            (* The statistics are computed over the (instance,run) CELLS, so the
               records must OUTLIVE the run loop.  The replication unit is the cell
               and never the frame: the recovery scan validates N^{T_L} overlapping
               frames per N iterations, so a frame count fed into Kirkham's 1-e^{-n}
               returns ~1 vacuously.  Y = 1[target_count >= 1] per cell is the n the
               reproducibility and rule-of-three math takes
               (env-research/Q3-stats.md). *)
            s "  het_obs_record _recs[NUMBER_OF_RUN];\n" ;
            s "  memset(_recs, 0, sizeof _recs);\n" ;
            (* The campaign knobs are RUNTIME (getenv), never -D: the scheduler
               retunes them per invocation without a rebuild, and a compile-time
               knob threaded through an if-chain is what lets a whole mechanism be
               folded away.  Unset envs leave the compiled defaults.  HET_RUNS_MAX
               can only CURTAIL within one invocation, since the record array is
               compiled at NUMBER_OF_RUN; growing R is the outer scheduler's job,
               one fresh-HET_SEED invocation at a time -- replaying the same seeds
               adds no fresh phase draws, and pooling them would double-count the
               effective replication. *)
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
            (* ---- the CPU stress population, spawned BEFORE the test threads. *)
            s "    memset(&_ct, 0, sizeof _ct);\n" ;
            (* The CPU-preload liveness flag must be WRITTEN, not just read: on a
               host with no cache primitives het_cpu_preload issues zero hints, and
               a stress_requested that still claimed the preload would disqualify
               every null on that host as dead -- the false COLD the guard exists to
               prevent.  het_cpu_preload_live() is the accessor because
               HET_CPU_PRELOAD_LIVE is host-only, and this translation unit is the
               one nvcc parses. *)
            s "    _ct.preload_inert = !het_cpu_preload_live();\n" ;
            s "    het_cpu_shuffle(_cpu_idx, _cpu_nregions);   /* reshuffled per run, off the run seed */\n" ;
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
            (* args[] in KERNEL-PARAM order. *)
            let args_addrs =
              String.concat ", "
                (List.concat_map
                   (fun i ->
                     List.map (fun g -> "&" ^ gsym i g) (kernel_globals i)
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
            s "      if (_noise_blocks > 0 && _ng == 0)\n" ;
            s (Printf.sprintf
                 "        fprintf(stderr, \"HetLitmus WARNING: %%u device-side noise block(s) were launched but NONE completed a round -- %s of the %s noise did NOT run.  This run is not interconnect-stressed.\\n\", _noise_blocks);\n"
                 dev_half link_name) ;
            s "      if (_ct.aff_failures)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u sched_setaffinity call(s) FAILED -- those threads are wherever the scheduler put them.  The pinning is fiction and the stress topology is not the one being tuned.\\n\", _ct.aff_failures);\n" ;
            s "    }\n" ;
            (* mirror every instance's GPU device read + observer buffers. *)
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
            (* THE RECORD STAMP, written as the SYMBOL so a rename in
               het_verdict.h is a compile error here rather than a silent
               mis-read.  het_verdict() reads no field of an unstamped record:
               the record is memset(0) just above, so without this line every
               count and liveness tally it reports would be a memset zero
               indistinguishable from a run that saw nothing. *)
            s "    _rec.rec_magic = HET_REC_MAGIC;\n" ;
            s (Printf.sprintf
                 "    _rec.cpu_only = %d;  /* D10: 1 iff EVERY proc is a CPU proc */\n"
                 (if cpu_only then 1 else 0)) ;
            (* THE BUILD FACTS behind the "structurally absent stress" caveat,
               taken from the constants that actually guard the two loops rather
               than re-derived in het_verdict.h.  cpu_only is NOT a proxy for
               them: a CPU-only store-only shape still carries a GPU observer
               lane, so 2+2W-cpuonly-x86_64 and R-cpuonly-x86_64 emit
               HET_GPU_LANES=1 while the caveat used to assert 0 for all six. *)
            s "    _rec.gpu_lanes = HET_GPU_LANES;\n" ;
            s "    _rec.spin_lanes = HET_SPIN_LANES;\n" ;
            (match mu_name with
             | Some m -> s (Printf.sprintf "    _rec.control_name = \"%s\";\n" m)
             | None -> s "    _rec.control_name = NULL;  /* no mu(T): at the lattice floor */\n") ;
            (match canary_named with
             | Some c -> s (Printf.sprintf "    _rec.canary_name = \"%s\";\n" c)
             | None -> s "    _rec.canary_name = NULL;\n") ;
            s "    _rec.control_compiled_in = HET_CONTROL_COMPILED_IN;\n" ;
            s "    _rec.canary_compiled_in = HET_CANARY_COMPILED_IN;\n" ;
            (* THE TWO GPU MECHANISMS ARE ONLY REQUESTED WHERE THEY CAN RUN.
               het_do_stress's loop guard is `_gpu_done < HET_GPU_LANES' and the
               window-opener spins over HET_SPIN_LANES; on a CPU-only harness both
               constants are 0, so both loops exit before their body runs once.
               MEASURED 2026-08-03 on MP-cpuonly-x86_64 (RTX 3060, HET_ALLOC=pinned):
               spin=0/0 do_stress_rounds=0 with req=0xf, so het_dead() fired on both
               and ALL TEN runs came back COLD-INVALID -- a row whose null can
               never be a datum.  These are structurally absent mechanisms, not
               dead ones, which is exactly the distinction stress_requested exists to
               draw.  het_verdict() still raises HET_CV_NO_GPU_LANES so the null says
               out loud that only CPU-side stress opened its window.
               A het harness has HET_GPU_LANES >= 1, so the mask is unchanged there. *)
            s "    _rec.stress_requested =\n\
               \        ((HET_GPU_LANES > 0 && (HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0)) ? HET_REQ_GPU_STRESS : 0u)\n\
               \      | ((HET_SPIN_LANES > 0 && HET_BARRIER_PCT > 0) ? HET_REQ_SPIN : 0u)\n\
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
            (* The window resolution this run REALISED.  HET_NWIN is swept and the
               autocorrelation-time statistics are resolution-dependent, so a record
               scored at one nwin must never be silently pooled with another. *)
            s "    _rec.nwin = (uint32_t)HET_NWIN;\n" ;
            List.iter (fun i -> s i.i_scan) insts ;
            (* control_Prep is computed AFTER the control's scan, because it reads
               control_target_count, which is still memset-0 until that scan runs.
               Computing it earlier can only ever yield 1 - e^0 = 0. *)
            s "    _rec.control_Prep = 1.0 - exp(-(double)_rec.control_target_count);\n" ;
            s "    het_obs_record_print(stdout, &_rec);\n" ;
            (* THE REPORTING CONTRACT: never print a bare "Never".  Every null is
               printed paired with the control that vouches for it, by name and in
               absolute numbers, and a null no control vouches for is printed as
               discard-this rather than as a result.  It is the harness's own output,
               so the interpretation travels with the number
               (hetlitmus/docs/positive-control.md sec 6). *)
            s "    het_verdict_print(stdout, &_rec);\n" ;
            s "    _recs[_nrec++] = _rec;\n" ;
            (* The in-binary adaptive loop.  het_campaign_should_stop() is a pure
               function of the records accumulated so far, inheriting every
               statistic already computed, so consulting it after each run gives the
               campaign scheduler its per-test early stop with no new decision
               machinery.  With HET_ADAPTIVE unset the loop simply runs to
               _runs_budget. *)
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
            (* ========= the statistics post-pass over the aggregated cells ========
               het_verdict() is a PURE function of one record, so the aggregate reuses
               it instead of re-deriving liveness, inheriting every stress
               disqualifier.  This is what turns "not observed" into "not observed,
               under quantified effort, with a 95% bound on the run-level rate" --
               what makes a Never carry a bound at all (env-research/Q3-stats.md). *)
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

          (* ---- <tname>.{cu,hip} : GPU kernel + driver (per dialect) ---- *)
          let dump_gpu_file dialect ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "// HetLitmus GPU kernel + driver for %s (%s dialect).\n"
                 tname dialect.gd_name) ;
            s "// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
            s "// Stores carry the tag K*(_n+1)+mu; loads are recorded into\n" ;
            s "// per-iteration read buffers; a post-run scan decodes rf/init edges,\n" ;
            s "// and observer ws-edges, into a het_obs_record.\n" ;
            if co_run then begin
              s "//\n// THE POSITIVE CONTROL IS CO-RUNNING IN THIS HARNESS.\n" ;
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
                s "// mu(T) is a strictly weaker, structurally identical sibling of T,\n" ;
                s "// co-running on the same launch, stress and C2C path.  A null on T\n" ;
                s "// means \"not observed on a harness that demonstrably produced an\n" ;
                s "// interleaving of T's own shape\" -- and NOTHING AT ALL if the\n" ;
                s "// control did not fire (het_verdict.h).\n"
              end else begin
                (* At the lattice floor there is nothing left to weaken, so this
                   harness carries the canary only. *)
                s "// This test is at the lattice floor, so it has no strictly weaker\n" ;
                s "// structural sibling (Layer A) to co-run.  It carries the Layer-B\n" ;
                s "// canary ONLY, which is what makes a non-observation here mean \"not\n" ;
                s "// exposed on a demonstrably HOT harness\" instead of nothing at all.\n"
              end
            end ;
            s dialect.gd_shared_mem_note ;
            s "// a system-scope atomic barrier rendezvouses both sides.\n" ;
            s (Printf.sprintf
                 "// Compile-only by default (%s -c); comp.sh %s-link / make %s-bin\n"
                 dialect.gd_compiler dialect.gd_target dialect.gd_target) ;
            s "// link the runnable binary, guarded by uname -m.  DO NOT EDIT.\n" ;
            s (dialect.gd_runtime_include ^ "\n") ;
            s "#include <cstdio>\n#include <cstdint>\n#include <cstdlib>\n" ;
            s "#include <cstring>\n#include <cmath>\n" ;
            s "#include <pthread.h>\n#include <inttypes.h>\n" ;
            (* WHAT THE PAIR ROW STAMPS, ahead of the runtime headers that read
               it.  The machine words -- the two halves of the interconnect
               noise, the link between them, this part's last level -- are claims
               about silicon, so an unregistered pair stamps none of them and
               the headers' #ifndef defaults name the mechanism instead: a
               missing define can only weaken a claim.  The two build facts below
               are stamped by every pair, because they are true of the binary
               whatever the pair row says.  HET_PLACE_LEVER is separate again: the
               vendor API call this render actually contains is a dialect fact. *)
            (match HetOracle.machine_of pair with
             | Some m ->
                s (Printf.sprintf "#define HET_LINK_NAME %S\n"
                     m.HetOracle.mc_link_name) ;
                s (Printf.sprintf "#define HET_HOST_HALF %S\n"
                     m.HetOracle.mc_host_half) ;
                s (Printf.sprintf "#define HET_DEV_HALF %S\n"
                     m.HetOracle.mc_dev_half) ;
                (match m.HetOracle.mc_llc_mb with
                 | Some mb -> s (Printf.sprintf "#define HET_LLC_MB %d\n" mb)
                 | None -> ()) ;
                if m.HetOracle.mc_alglave_zero then
                  s "#define HET_ALGLAVE_ZERO_MEASURED 1\n"
             | None ->
                s "/* No machine defines: this harness's (CPU ISA x GPU dialect) pair\n" ;
                s "   is unregistered, so it names no silicon and het_verdict.h's\n" ;
                s "   generic host/device wording stands. */\n") ;
            s (Printf.sprintf "#define HET_PAIR_NAME %S\n" pair_label) ;
            if no_control_map then s "#define HET_NO_CONTROL_MAP 1\n" ;
            (match dialect.gd_place_lever with
             | Some lever -> s (Printf.sprintf "#define HET_PLACE_LEVER %S\n" lever)
             | None -> ()) ;
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
            (* ---- THE POSITIVE CONTROL: TWO LAYERS, TWO FLAGS.
               0 means the corresponding *_target_count is structurally zero and
               carries no information; 1 means that layer is genuinely co-running in
               this launch, under this stress, on this C2C path, so a count may be
               read against it.  Neither may ever be 1 without the co-run behind it,
               or a "Never" silently becomes a CREDIBLE "Never" -- an unfalsifiable
               null reading as confirmation of the model.  Both come from the
               instance population, so they cannot drift.

               They stay separate because "a canary is co-running" is a weaker claim
               than "the mutant OF THIS TEST is co-running", and only the second
               licenses a credible null; one bit cannot carry both without lying
               about one (hetlitmus/docs/positive-control.md sec 11). *)
            s (Printf.sprintf "#define HET_CONTROL_COMPILED_IN %d\n"
                 (if has_mu then 1 else 0)) ;
            s (Printf.sprintf "#define HET_CANARY_COMPILED_IN %d\n"
                 (if has_canary then 1 else 0)) ;
            (match mu_name with
             | Some m ->
                s (Printf.sprintf "#define HET_MU_NAME \"%s\"      /* Layer A: the minimal mutant */\n" m)
             | None -> s "#define HET_MU_NAME NULL\n") ;
            (* A test that IS the canary names itself, which is how het_verdict.h
               separates that designed case from a canary that went missing. *)
            (match canary_named with
             | Some c ->
                s (Printf.sprintf "#define HET_CANARY_NAME \"%s\"  /* Layer B: the universal het-MP floor */\n" c)
             | None -> s "#define HET_CANARY_NAME NULL\n") ;
            s (Printf.sprintf "#define SIZE_OF_TEST %d\n" Cfg.size) ;
            s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" Cfg.runs) ;
            (* One K macro per instance, never one per translation unit; the co-run
               banner above says what a shared K would decode wrongly. *)
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
              s "\n/* One cache line per shared location, so the co-running instances\n\
                 \   never share a coherence unit.  Disjoint ADDRESSES are not enough:\n\
                 \   two variables on one line are one coherence unit, and the control's\n\
                 \   traffic would then drag the tested line around -- perturbing the\n\
                 \   very test it exists to vouch for.  128 B covers both targets\n\
                 \   (64 B CPU-side, 128 B GPU-side cache lines). */\n" ;
              s "#ifndef HET_CACHE_LINE\n#define HET_CACHE_LINE 128\n#endif\n"
            end ;
            s "\n" ;
            s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
                 block_dim) ;
            (* Sums over the instances, because each one's count is shape-dependent
               (S and R carry an observer lane, MP/SB/LB do not). *)
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
                       (kernel_globals i)
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
                    (* Bind this instance's object to the LISA name the shared GPU
                       lowering emits; see the co-run banner.  A single-instance
                       harness has prefix "" and emits no alias. *)
                    if co_run then
                      List.iter
                        (fun g ->
                          s (Printf.sprintf
                               "    uint64_t* %s = %s;  /* this instance's %s */\n"
                               g (gsym i g) g))
                        i.i_gpu_globals ;
                    s (dialect.gd_bar "    " "barrier") ;
                    List.iter (fun n -> s (Printf.sprintf "    uint64_t r%d = 0;\n" n))
                      gp.gp_regs ;
                    s "    uint32_t _nb = 0;\n" ;
                    (* FAITHFULNESS, do not remove: SIZE_OF_TEST is a compile-time
                       constant, so without this pragma nvcc unrolls the loop and the
                       emitted PTX carries many copies of the tested instructions --
                       a different program microarchitecturally, and one the L0
                       faithfulness gate rejects.  The observer loop below needs the
                       same pragma for the same reason. *)
                    s "    #pragma unroll 1\n" ;
                    s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                    s "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n" ;
                    s "        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally);\n" ;
                    (* The barrier roll is drawn from a LANE-INDEPENDENT stream, keyed
                       by the iteration rather than the lane, so every test lane in
                       every co-running instance decides the same way for iteration
                       _n.  The barrier is then taken by all the spin lanes or none,
                       each contributing one increment, and the counter reaches
                       _nb*HET_SPIN_LANES exactly when the last lane arrives.  A
                       per-lane roll makes that limit unreachable after the first
                       skipped roll, and the spin degrades into a delay loop that
                       releases on its deadlock cap. *)
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
            (* =============== the pure stressing workgroups =================== *)
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
                  (* The OBSERVED shared locations are `volatile const' so that the
                     observer's per-iteration reads cannot be hoisted out of the
                     perpetual loop at -O2 -- the same treatment the noise buffers
                     get, and what the GPU-side atomic observer gets structurally.
                     A plain deref, never written on this thread, is hoisted to one
                     broadcast load: the observer would then record a single value N
                     times, pinning observer_unique_count at 1 and leaving a
                     store-only test's only recovery channel inert.  The
                     non-observed globals are not dereferenced here and stay plain. *)
                  List.iter
                    (fun l ->
                      let ty =
                        if List.mem l i.i_obs_locs
                        then "volatile const uint64_t*" else "uint64_t*" in
                      s (Printf.sprintf "  %s %s;\n" ty l))
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
            s "/* Placement refusals.  Incremented only where placement EXISTS (the\n\
               \   CUDA/GH200 render); stays 0 on the HIP/MI300A render, which has a\n\
               \   single HBM pool and therefore nothing to place. */\n" ;
            s "static int _het_place_failures = 0;\n\n" ;
            s dialect.gd_shared_mem_defs ;
            s "\n" ;
            s dialect.gd_noise_mem_defs ;
            s "\n" ;
            dump_gpu_main dialect s in
          (* ---- comp.sh / Makefile / README ---- *)
          (* `uname -m' of the CPU ISA this harness was rendered for.  The link
             targets below refuse on any other host, where <test>_cpu_host.o is the
             portable shim from dump_cpu_file's #else arm -- an executable built
             from it runs, prints a histogram and tests nothing.  An unknown
             host_macro maps to itself, which no `uname -m' can equal: fail
             closed. *)
          let host_uname = match CpuF.host_macro with
            | "__aarch64__" -> "aarch64"
            | "__x86_64__" -> "x86_64"
            | m -> m in
          (* The build files' per-vendor vocabulary, all of it folded over the
             (filtered) [dialects]; [d0] is the head, which they default to. *)
          let d0 = List.hd dialects in
          let targets = List.map (fun d -> d.gd_target) dialects in
          let comp_args =
            String.concat "|"
              (targets @ List.map (fun t -> t ^ "-link") targets) in
          (* Count-sensitive words for the prose below.  A harness carries ONE
             dialect (`-gpu-target'), so the sentences must read in the singular
             -- and still read at any registry size, which is why no count word
             is written out by hand. *)
          let n_d = List.length dialects in
          let plural sing plur = if n_d = 1 then sing else plur in
          let enum l = match List.rev l with
            | [] -> ""
            | [x] -> x
            | x :: rest -> String.concat ", " (List.rev rest) ^ " and " ^ x in
          let count_word = function
            | 1 -> "The one" | 2 -> "Both" | 3 -> "All three" | 4 -> "All four"
            | k -> Printf.sprintf "All %d" k in
          let vendors = enum (List.map (fun d -> d.gd_vendor) dialects) in
          let bin_targets =
            List.map (fun t -> Printf.sprintf "`make %s-bin'" t) targets in
          let dump_comp ch =
            let s = output_string ch in
            s "#!/bin/sh\n" ;
            s (Printf.sprintf
                 "# Compile-only check for HetLitmus harness '%s' (%s render).\n"
                 tname (enum (List.map (fun d -> d.gd_name) dialects))) ;
            s "# COMPILE-ONLY by default (-c, no link, no GPU run).\n" ;
            s (Printf.sprintf
                 "# Adding `-link' to a target (%s) LINKS ./%s as well, making\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`%s-link'" t) targets))
                 tname) ;
            s "# the harness runnable on real hardware.  Every link target is GUARDED by\n" ;
            s "# uname -m: on a foreign host the CPU object carries the portable shim, not\n" ;
            s "# the tested asm.\n" ;
            s (Printf.sprintf "# Usage: sh comp.sh [%s]   (default %s)\n"
                 comp_args d0.gd_target) ;
            s (Printf.sprintf
                 "# The link writes ./%s -- the path EVERY vendor's render links to, so\n"
                 tname) ;
            s "# run-one.sh / campaign.py stay vendor-agnostic (they exec ./<test> and read\n" ;
            s (Printf.sprintf
                 "# the HetStats line).  This harness carries the %s build arms only; the\n"
                 vendors) ;
            s (Printf.sprintf
                 "# link is unconditional and %s %s .PHONY, so a stale binary left by an\n"
                 (enum bin_targets) (plural "is" "are")) ;
            s "# earlier build is never mistaken for a fresh one.\n" ;
            s "set -e\n" ;
            s (Printf.sprintf "TARGET=\"${1:-%s}\"\n" d0.gd_target) ;
            (* one `compiler ; arch' line per dialect, their arch notes aligned *)
            let var_line d =
              Printf.sprintf "%s=\"${%s:-%s}\" ; %s=\"${%s:-%s}\""
                d.gd_compiler_var d.gd_compiler_var d.gd_compiler
                d.gd_arch_var d.gd_arch_var d.gd_arch_default in
            let var_w =
              List.fold_left
                (fun w d -> max w (String.length (var_line d))) 0 dialects in
            List.iter
              (fun d ->
                let v = var_line d in
                s (Printf.sprintf "%s%s # %s=%s\n"
                     v (String.make (var_w - String.length v) ' ')
                     d.gd_arch_device d.gd_arch_default))
              dialects ;
            s (Printf.sprintf
                 "HET_HOST_ISA=\"%s\"   # uname -m of this test's CPU ISA (%s)\n"
                 host_uname CpuF.isa_name) ;
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
            List.iter
              (fun d ->
                let cc = "$" ^ d.gd_compiler_var
                and arch = "$" ^ d.gd_arch_var
                and obj = gpu_obj d tname in
                s (Printf.sprintf "  %s|%s-link)\n" d.gd_target d.gd_target) ;
                s (Printf.sprintf
                     "    if [ \"$TARGET\" = %s-link ] && [ \"$(uname -m)\" != \"$HET_HOST_ISA\" ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"error: comp.sh %s-link refuses on $(uname -m): this harness's CPU thread is %s asm, so %s_cpu_host.o here is the PORTABLE SHIM and the binary would test nothing -- link on a $HET_HOST_ISA host\" >&2\n"
                     d.gd_target CpuF.isa_name tname) ;
                s "      exit 3\n" ;
                s "    fi\n" ;
                s (Printf.sprintf
                     "    command -v \"%s\" >/dev/null 2>&1 || { echo \"error: %s not found (%s toolchain absent)\" >&2 ; exit 1 ; }\n"
                     cc cc d.gd_toolchain) ;
                s (Printf.sprintf "    echo \"+ %s %s -c %s.%s\"\n"
                     cc (gpu_cflags d arch) tname d.gd_ext) ;
                s (Printf.sprintf "    %s %s -c %s.%s -o %s\n"
                     cc (gpu_cflags d arch) tname d.gd_ext obj) ;
                s (Printf.sprintf "    if [ \"$TARGET\" = %s-link ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"+ %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\"\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s (Printf.sprintf
                     "      %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s "    fi ;;\n")
              dialects ;
            (* An unmatched $TARGET means an argument was GIVEN (no argument
               takes d0 above), so the refusal quotes it back: one vendor per
               harness means the other vendor's target name is the likely
               mistake, and a bare usage line leaves the reader to spot that
               their own word is missing from it. *)
            s (Printf.sprintf
                 "  *) echo \"comp.sh: unknown target \\\"$TARGET\\\" -- this directory is %s-only (accepted: %s)\" >&2 ; exit 2 ;;\n"
                 (String.concat "/" targets) comp_args) ;
            s "esac\n" ;
            s (Printf.sprintf "if %s; then\n"
                 (String.concat " || "
                    (List.map
                       (fun t -> Printf.sprintf "[ \"$TARGET\" = %s-link ]" t)
                       targets))) ;
            s (Printf.sprintf "  echo \"HetLitmus: link OK -> ./%s\"\n" tname) ;
            s "else\n" ;
            s "  echo 'HetLitmus: compile OK'\n" ;
            s "fi\n" in
          let dump_makefile ch =
            let s = output_string ch in
            s (Printf.sprintf
                 "# HetLitmus harness '%s' -- objects by default (`make %s');\n"
                 tname d0.gd_target) ;
            s (Printf.sprintf
                 "# %s %s ./%s, guarded by uname -m.\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s-bin'" t)
                       targets))
                 (plural "links" "link") tname) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s ?= %s\n%s ?= %s\n"
                     d.gd_compiler_var d.gd_compiler
                     d.gd_arch_var d.gd_arch_default))
              dialects ;
            s "CC ?= gcc\n" ;
            (* The comment gets its OWN line: `VAR ?= val   # note' keeps the trailing
               blanks in the make variable, so the uname -m test below would compare
               "aarch64" against "aarch64   " and refuse on the very host it exists to
               admit -- a guard that is inert in the other direction. *)
            s (Printf.sprintf
                 "# uname -m of this test's CPU ISA (%s); the %s-bin guard compares it.\n"
                 CpuF.isa_name d0.gd_target) ;
            s (Printf.sprintf "HET_HOST_ISA ?= %s\n\n" host_uname) ;
            s (Printf.sprintf "all: %s\n\n" d0.gd_target) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname))
              dialects ;
            s "\n" ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s.%s\n\t$(%s) %s -c $< -o $@\n\n"
                     (gpu_obj d tname) tname d.gd_ext d.gd_compiler_var
                     (gpu_cflags d (Printf.sprintf "$(%s)" d.gd_arch_var))))
              dialects ;
            s "outs.o: outs.c\n\t$(CC) -c $< -o $@\n\n" ;
            s (Printf.sprintf "%s_cpu_host.o: %s_cpu.c\n\t$(CC) -c $< -o $@\n\n" tname tname) ;
            (* THE TWO LINK TARGETS ARE .PHONY RECIPES, NOT FILE RULES.  Both
               vendors write the same ./<test> -- deliberate, so run-one.sh and
               campaign.py stay vendor-agnostic (they exec ./<test>) -- and make
               cannot carry two file rules for one target.

               A file rule would also be SKIPPED whenever ./<test> is newer than
               its objects, which is exactly the state the other vendor's link
               leaves behind.  MEASURED on this tree before the fix, with
               `cuda-bin: <test>' + a `<test>: <test>.o ...' file rule: after
               `make hip-bin', `make cuda-bin' printed "Nothing to be done for
               'cuda-bin'", EXITED 0, and left the gfx942 binary in place -- a
               CUDA build that reports success and hands back the AMD harness.
               Inert while only one vendor could link; live from the moment
               hip-bin existed.  Both link unconditionally now: a link target
               that silently links nothing is this project's recurring failure
               mode.  Guarded for the same reason as comp.sh's *-link arms: on a
               foreign host $(TEST)_cpu_host.o is the portable shim. *)
            List.iter
              (fun d ->
                s (Printf.sprintf "%s-bin: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname) ;
                s (Printf.sprintf
                     "\t@ test \"$$(uname -m)\" = \"$(HET_HOST_ISA)\" || { echo \"error: %s-bin refuses on $$(uname -m): this harness's CPU thread is %s asm, so %s_cpu_host.o here is the PORTABLE SHIM and the binary would test nothing -- link on a $(HET_HOST_ISA) host\" >&2 ; exit 3 ; }\n"
                     d.gd_target CpuF.isa_name tname) ;
                s (Printf.sprintf "\t$(%s) %s$(%s) $^ -o %s -lpthread -lm\n\n"
                     d.gd_compiler_var d.gd_arch_flag d.gd_arch_var tname))
              dialects ;
            (* ...AND `make <test>' MUST NOT BUILD ANYTHING EITHER.  Making the two
               link targets phony removed the only rule that named ./<test>, so
               GNU make fell through to its BUILT-IN link rule `%: %.o' -- which
               links <test>.o with $(CC) and never consults the uname -m guard.
               MEASURED 2026-08-03 on an emitted x86 harness:

                 $ make MP-cg-sys-acqrel-2s-x86_64
                 cc   MP-cg-sys-acqrel-2s-x86_64.o   -o MP-cg-sys-acqrel-2s-x86_64
                 ... undefined reference to `cudaLaunchKernel'
                 make: *** [<builtin>: MP-cg-sys-acqrel-2s-x86_64] Error 1

               It failed only because these objects carry CUDA/C++ symbols the
               plain $(CC) link cannot resolve -- the ISA guard is NOT what
               stopped it, and `[<builtin>]' says so.  Before the link targets
               became phony the same command went through the guarded file rule.
               So: `.SUFFIXES:' kills the built-in fall-through for every target
               here (all four object rules are explicit, so nothing needs it),
               and ./<test> additionally gets a rule that SAYS which target to
               use.  It is .PHONY as well as explicit because a plain rule whose
               target already exists is "up to date": make would exit 0 printing
               nothing and hand back whichever vendor's binary was lying there --
               the same silent-success shape as the stale-link trap above. *)
            s ".SUFFIXES:\n\n" ;
            s (Printf.sprintf "%s:\n" tname) ;
            s (Printf.sprintf
                 "\t@ echo \"error: \\`make %s' is not a build target: it would bypass the uname -m guard (and, without this rule, make's built-in \\`%%: %%.o' rule links it with \\$$(CC) and no device code at all).  Link it with %s, %s uname -m first.\" >&2 ; exit 3\n\n"
                 tname
                 (String.concat " or "
                    (List.map
                       (fun d -> Printf.sprintf "\\`make %s-bin' (%s)"
                                   d.gd_target d.gd_vendor)
                       dialects))
                 (plural "which checks" "which all check")) ;
            s (Printf.sprintf
                 ".PHONY: all %s clean %s\nclean:\n\trm -f *.o %s\n"
                 (String.concat " "
                    (List.map (fun t -> Printf.sprintf "%s %s-bin" t t)
                       targets))
                 tname tname) in
          let dump_readme ch =
            let s = output_string ch in
            s (Printf.sprintf "# HetLitmus heterogeneous harness: %s\n\n" tname) ;
            s "Heterogeneous CPU+GPU litmus harness emitted by litmus7 (`Het` arch).\n\n" ;
            s (Printf.sprintf "CPU ISA: %s.  GPU dialect%s: %s.\n\n"
                 CpuF.isa_name (plural "" "s")
                 (String.concat " + "
                    (List.map
                       (fun d -> Printf.sprintf "%s (`.%s`)" d.gd_name d.gd_ext)
                       dialects))) ;
            if co_run then begin
              s "## The positive control is CO-RUNNING in this harness\n\n" ;
              s "A test's null result is evidence only if the harness would have seen a\n" ;
              s "weak behaviour had one occurred.  Every het instance below therefore\n" ;
              s "shares this launch, this stress config and this C2C path, on disjoint\n" ;
              s "cache-line-padded locations:\n\n" ;
              List.iter
                (fun i ->
                  s (Printf.sprintf "- `%s` (%s) -- prefix `%s`, K=%d\n"
                       i.i_name (role_note i.i_role) i.i_pre i.i_k))
                insts ;
              s "\nLayer A is a strictly weaker, structurally identical sibling of the test\n" ;
              s "under study; Layer B is the fixed het canary.  Neither carries a prediction:\n" ;
              s "their counts say how hot the harness was, and nothing about what the test\n" ;
              s "ought to have done.  See `het_verdict.h` for the rule that reads them.\n\n"
            end ;
            s "Files:\n" ;
            (* the renders first, their descriptions started at a common column *)
            let ext_w =
              List.fold_left
                (fun w d -> max w (String.length d.gd_ext)) 0 dialects + 4 in
            List.iter
              (fun d ->
                s (Printf.sprintf "- `%s.%s`%s%s" tname d.gd_ext
                     (String.make (ext_w - String.length d.gd_ext) ' ')
                     d.gd_readme_files))
              dialects ;
            s (Printf.sprintf "- `%s_cpu.c`  CPU thread(s): real %s inline asm (litmus7 ASMLang).\n" tname CpuF.isa_name) ;
            s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
            s (Printf.sprintf
                 "- `comp.sh` / `Makefile`  compile-only build, plus %s guarded link target%s.\n\n"
                 (plural "the" "the two") (plural "" "s")) ;
            s (Printf.sprintf
                 "Build (compile-only; no GPU needed): `sh comp.sh [%s]` (default %s),\n"
                 (String.concat "|" targets) d0.gd_target) ;
            s (Printf.sprintf "or %s.\n\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s`" t)
                       targets))) ;
            s "## Building the executable\n\n" ;
            List.iter
              (fun d ->
                s (Printf.sprintf
                     "%s: `sh comp.sh %s-link` or `make %s-bin` links `./%s` from `%s`\n"
                     d.gd_vendor d.gd_target d.gd_target tname (gpu_obj d tname)) ;
                s (Printf.sprintf "(`$%s %s$%s`, %s = %s).\n"
                     d.gd_compiler_var d.gd_arch_flag d.gd_arch_var
                     d.gd_arch_default d.gd_arch_device))
              dialects ;
            s "\n" ;
            s "The GPU compiler driver pulls in its own device runtime; `-lpthread -lm`\n" ;
            s "cover the CPU threads and the statistics layer.  ONE binary path per vendor\n" ;
            s "is deliberate: `run-one.sh` and `campaign.py` exec `./<test>` and stay\n" ;
            s "vendor-agnostic.  litmus7 renders ONE dialect per harness (`-gpu-target`),\n" ;
            s (Printf.sprintf
                 "so this directory carries the %s build arms and nothing else; %s\n"
                 vendors
                 (enum (List.map (fun t -> Printf.sprintf "`make %s-bin`" t) targets))) ;
            s (Printf.sprintf
                 "%s `.PHONY` and always relink%s, so a build can never report success\n"
                 (plural "is" "are") (plural "s" "")) ;
            s "while leaving a stale binary in place.\n\n" ;
            s (Printf.sprintf "%s %s\n"
                 (count_word (2 * n_d))
                 (enum
                    (List.concat
                       (List.map
                          (fun d ->
                            [ Printf.sprintf "`sh comp.sh %s-link`" d.gd_target ;
                              Printf.sprintf "`make %s-bin`" d.gd_target ])
                          dialects)))) ;
            s (Printf.sprintf
                 "REFUSE unless `uname -m` is `%s`: elsewhere `%s_cpu_host.o` is compiled\n"
                 host_uname tname) ;
            s (Printf.sprintf
                 "from the `#else` shim, not the %s asm, so the binary would run happily and\n"
                 CpuF.isa_name) ;
            s "test nothing.\n\n" ;
            List.iter
              (fun d ->
                s (Printf.sprintf
                     "Name the GPU arch explicitly, e.g. `%s=%s make %s-bin` (%s): a build\n"
                     d.gd_arch_var d.gd_arch_default d.gd_target d.gd_arch_device) ;
                s "for the wrong arch links and exits 0 just as happily.  Compile-time knobs\n" ;
                s (Printf.sprintf
                     "go through the compiler variable, e.g. `make %s-bin %s=\"%s -DHET_MEM_STRESS_PCT=0\"`.\n"
                     d.gd_target d.gd_compiler_var d.gd_compiler))
              dialects ;
            s "\n" ;
            s "`HET_PLACE` is the exception: page placement exists only on a render whose\n" ;
            s "runtime has a placement API, and a non-zero value REFUSES to compile on a\n" ;
            s "render that has none rather than be reported in the banner without placing\n" ;
            s "anything.\n\n" ;
            s (Printf.sprintf
                 "`make %s` is NOT one of these targets and refuses: it would bypass\n" tname) ;
            s "the `uname -m` guard, and without that refusal make silently falls back to its\n" ;
            s "built-in `%: %.o` rule and links the harness with `$(CC)` and no device code.\n" ;
            s (Printf.sprintf "Use %s.\n\n"
                 (enum (List.map (fun t -> Printf.sprintf "`make %s-bin`" t) targets))) ;
            s (Printf.sprintf "Target%s: %s.\n" (plural "" "s")
                 (enum
                    (List.map
                       (fun d ->
                         Printf.sprintf "%s %s (%s)"
                           d.gd_vendor d.gd_arch_device d.gd_name)
                       dialects))) in
          write "outs.h" (fun ch -> output_string ch outs_h_content) ;
          write "outs.c" (fun ch -> output_string ch outs_c_content) ;
          write "het_stress.cuh" (fun ch -> output_string ch het_stress_content) ;
          write "het_cpu_stress.h"
            (fun ch -> output_string ch het_cpu_stress_content) ;
          write "het_verdict.h"
            (fun ch -> output_string ch het_verdict_content) ;
          write (tname ^ "_cpu.c") dump_cpu_file ;
          let renders =
            List.map (fun d -> Printf.sprintf "%s.%s" tname d.gd_ext) dialects in
          List.iter
            (fun d -> write (Printf.sprintf "%s.%s" tname d.gd_ext)
                        (dump_gpu_file d))
            dialects ;
          write "comp.sh" dump_comp ;
          write "Makefile" dump_makefile ;
          write "README.md" dump_readme ;
          if O.verbose >= 0 then
            Printf.eprintf
              "HetLitmus: emitted harness directory %s (%s)\n%!"
              dir (String.concat " + " renders) ;
          Absent
        (* FAIL-CLOSED: the emitted harness directory is this function's ONLY
           deliverable, so a refusal must not be reported as success.  See
           HetArch.refused. *)
        with e ->
          if O.nocatch then raise e ;
          HetArch.refused "het" src_name e
    end
