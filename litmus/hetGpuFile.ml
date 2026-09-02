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

(* HetLitmus: the .cu/.hip render, one phase function per part of the file;
   contract in hetGpuFile.mli. *)

open HetDialect

open HetHarness

(* The file prelude: the banner every render carries, the runtime and
   payload includes, the pair stamp and the harness geometry defines. *)
let dump_prelude dialect identity geometry procs ch =
  let s = output_string ch in
  let tname = identity.id_name in
  let pair_label = identity.id_pair_label in
  s (Printf.sprintf
       "// HetLitmus GPU kernel + driver for %s (%s dialect).\n"
       tname dialect.gd_name) ;
  s {|// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).
// Iteration _n of both sides touches slot _n of every location and
// records its loads at index _n; the post-run readout reads the
// outcome of iteration _n out of slot _n into a het_obs_record.
|} ;
  s dialect.gd_shared_mem_note ;
  s "// every iteration begins at a relaxed system-scope counter rendezvous.\n" ;
  s (Printf.sprintf
       "// Compile-only by default (%s -c); comp.sh %s-link / make %s-bin\n"
       dialect.gd_compiler dialect.gd_target dialect.gd_target) ;
  s "// link the runnable binary.  DO NOT EDIT.\n" ;
  s (dialect.gd_runtime_include ^ "\n") ;
  s {|#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <inttypes.h>
|} ;

  s (dialect.gd_fence_floor_guard
       (List.concat_map (fun gp -> gp.gp_instrs) procs.pr_gpus)) ;
  s (Printf.sprintf "#define HET_PAIR_NAME %S\n" pair_label) ;
  (match dialect.gd_place_lever with
   | Some lever -> s (Printf.sprintf "#define HET_PLACE_LEVER %S\n" lever)
   | None -> ()) ;
  s {|#include "het_stress.h"
#include "het_cpu_stress.h"
#include "het_verdict.h"
#include "het_rdv.h"
extern "C" {
#include "outs.h"
|} ;
  List.iter
    (fun cp ->
      s (Printf.sprintf "  void het_run_P%d(%s);\n"
           cp.cp_proc (cpu_signature cp)))
    procs.pr_cpus ;
  s "}\n" ;
  s {|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|} ;
  s (Printf.sprintf "\n#define NPART %d\n" geometry.ge_npart) ;
  s (Printf.sprintf "#define SIZE_OF_TEST %d\n" geometry.ge_size) ;
  s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" geometry.ge_runs) ;
  s "\n" ;
  let lanes = max 1 geometry.ge_bdim in
  (* The floor is the block width het_stress.h's knobs were tuned jointly with
     [CudaLitmus params/stress_params.txt]. *)
  s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
       (max 128 lanes)) ;
  (* #error expands no macro, so the scope tree's width is baked in as text. *)
  s (Printf.sprintf
       "#if HET_BLOCK_DIM < %d\n\
        #error \"HET_BLOCK_DIM is below the %d lane(s) this test's scope tree \
        places in one block; the missing lane would never run and every \
        iteration would be discarded at the rendezvous\"\n\
        #endif\n"
       lanes lanes) ;
  s (Printf.sprintf "#define HET_TEST_BLOCKS %d\n\n" geometry.ge_blocks)

(* The kernel signature: the shared globals, then the GPU read buffers and
   arrival flags, then the stress and noise arguments every lane shares. *)
let kernel_parameters memory procs =
  String.concat ", "
    (List.map (fun g -> Printf.sprintf "int* %s" g)
       memory.me_gpu_globals
     @ List.map
         (fun rb -> Printf.sprintf "%s* %s" rb.rb_type rb.rb_name)
         (gpu_read_buffers memory)
     @ List.map
         (fun gp -> Printf.sprintf "uint8_t* %s" (rdv_gpu_name gp.gp_proc))
         procs.pr_gpus
     @ ["uint64_t* barrier" ; "uint32_t _cap_gpu"]
     @ ["uint32_t* _scratch" ; "uint32_t* _scratch_loc" ;
        "uint32_t* _gpu_iter" ;
        "uint32_t* _stress_tally" ;
        "uint32_t _seed" ; "uint32_t _pre_pat" ; "uint32_t _mem_pat" ;
        "uint64_t* _noise_ddr" ; "uint64_t _noise_words" ;
        "uint32_t _noise_blocks" ; "uint32_t _noise_chunk" ;
        "uint32_t _noise_stride"])

(* One GPU proc, guarded to its (block, lane) and looping over the
   iterations; it takes the channel because gd_dump_instr writes to it. *)
let dump_test_lane dialect gp ch =
  let s = output_string ch in
  s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n"
       gp.gp_blk gp.gp_lane) ;
  List.iter (fun n -> s (Printf.sprintf "    int r%d = 0;\n" n))
    gp.gp_regs ;
  (* #pragma unroll 1 -- hetlitmus/docs/amd-faithfulness.md,
     "The mapping". *)
  s {|    #pragma unroll 1
    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {
      if ((int)(het_draw(_seed, _who, 2u*(uint64_t)_n) % 100u) < HET_PRE_STRESS_PCT)
        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally);
|} ;

  (* Rendezvous, jitter, then the tested ops; nothing is placed
     between two tested accesses
     (hetlitmus/docs/00-environment-design.md sec 3.6). *)
  s (Printf.sprintf
       "      %s[_n] = het_rdv_device(barrier, (uint64_t)NPART*(uint64_t)(_n+1), _cap_gpu);\n"
       (rdv_gpu_name gp.gp_proc)) ;
  s "      het_rdv_jitter(het_draw(_seed, _who, 2u*(uint64_t)_n + 1u), HET_RELEASE_JITTER);\n" ;
  List.iter
    (fun instr -> dialect.gd_dump_instr ch ~het:(Some "_n") "      " instr)
    gp.gp_instrs ;
  List.iteri
    (fun li n ->
      s (Printf.sprintf "      %s[_n] = r%d;\n"
           (buf_name_of gp.gp_proc li) n))
    gp.gp_regs ;
  (* The iteration clock the stress blocks poll: ONE lane publishes it, so the
     mem-stress percentage is decided per iteration and grid-wide. *)
  if gp.gp_blk = 0 && gp.gp_lane = 0 then
    s "      het_scratch_bump(_gpu_iter);\n" ;
  s {|    }
  }
|}

(* The blocks past the test lanes: interconnect noise readers first, then
   the scratchpad stressers, both spinning on the iteration clock. *)
let dump_stress_workgroups ch =
  let s = output_string ch in
  s {|  if (blockIdx.x >= HET_TEST_BLOCKS) {
    /* Lane 0 reads the iteration clock for the whole block and broadcasts it:
       one device-scope RMW per block per round, whatever HET_BLOCK_DIM is.  The
       two branches below are block-uniform, so a __syncthreads is reached by
       every lane of its block and by NO test block. */
    __shared__ uint32_t _clk;
    if (_noise_ddr != NULL && blockIdx.x < HET_TEST_BLOCKS + _noise_blocks) {
      volatile const uint64_t* _nb = (volatile const uint64_t*)_noise_ddr;
      uint64_t _t = (uint64_t)(blockIdx.x - HET_TEST_BLOCKS) * blockDim.x + threadIdx.x;
      uint64_t _step = (uint64_t)_noise_blocks * blockDim.x * _noise_stride;
      uint64_t _i = (_noise_words > 0) ? (_t % _noise_words) : 0;
      /* The reads are volatile, so the stream is issued with no value escaping;
         the tally below counts blocks whose thread 0 completed a round. */
      uint32_t _r = 0;
      for (;;) {
        if (threadIdx.x == 0) _clk = het_scratch_read(_gpu_iter);
        __syncthreads();
        uint32_t _v = _clk;
        /* Every lane has taken its copy, so lane 0 may overwrite _clk. */
        __syncthreads();
        if (_v >= (uint32_t)SIZE_OF_TEST || _r >= HET_STRESS_MAX_ROUNDS) break;
        for (uint32_t _c = 0; _c < _noise_chunk; ++_c) {
          (void)_nb[_i];
          _i += _step;
          if (_i >= _noise_words) _i = (_noise_words > 0) ? (_i % _noise_words) : 0;
        }
        ++_r;
      }
      if (_r > 0 && threadIdx.x == 0) het_scratch_bump(&_stress_tally[HET_TALLY_NOISE]);
      if (threadIdx.x == 0) het_scratch_max(&_stress_tally[HET_TALLY_NOISE_ROUNDS], _r);
    } else {
      uint32_t _polls = 0;
      for (;;) {
        if (threadIdx.x == 0) _clk = het_scratch_read(_gpu_iter);
        __syncthreads();
        uint32_t _v = _clk;
        __syncthreads();
        if (_v >= (uint32_t)SIZE_OF_TEST || _polls >= HET_STRESS_MAX_ROUNDS) break;
        /* _v is the same in every lane, so the draw is one decision the block
           recomputes rather than one roll per lane. */
        if ((int)(het_draw(_seed, HET_WHO_GRID, _v) % 100u) < HET_MEM_STRESS_PCT)
          het_do_stress(_scratch, _scratch_loc, HET_MEM_STRESS_ITER, _mem_pat, _stress_tally);
        else
          het_idle();
        ++_polls;
      }
      if (_polls >= HET_STRESS_MAX_ROUNDS && threadIdx.x == 0)
        het_scratch_bump(&_stress_tally[HET_TALLY_TRUNC]);
    }
  }
|}

let dump_kernel dialect identity memory procs ch =
  let s = output_string ch in
  s (Printf.sprintf "__global__ void litmus_%s(%s) {\n"
       identity.id_ident (kernel_parameters memory procs)) ;
  s "  const uint32_t _who = blockIdx.x * blockDim.x + threadIdx.x;\n" ;
  List.iter (fun gp -> dump_test_lane dialect gp ch) procs.pr_gpus ;
  dump_stress_workgroups ch ;
  s "}\n\n"

(* One pthread wrapper per CPU proc: its argument struct, the participant id
   its draws are made under, and the loop calling het_run_P<p> on iteration n. *)
let dump_cpu_thread_wrappers dialect procs memory ch =
  let s = output_string ch in
  s dialect.gd_poke_def ;
  let cpu_ord = ref 0 in
  List.iter
    (fun cp ->
      let proc = cp.cp_proc in
      let addr = cp.cp_addrs
      and bufs = cpu_read_buffers memory cp in
      s (Printf.sprintf "struct cpu_args_P%d {\n" proc) ;
      List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr ;
      s "  uint64_t* barrier;\n" ;
      List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) bufs ;
      s {|  uint8_t* _rdv; long _cap;
  int _core; uint32_t _seed; het_cpu_tally* _tally;
};
|} ;
      s (Printf.sprintf "static void* cpu_thread_P%d(void* _a) {\n" proc) ;
      s (Printf.sprintf "  cpu_args_P%d* a = (cpu_args_P%d*)_a;\n" proc proc) ;
      s "  het_cpu_affinity(a->_core, a->_tally);\n" ;
      let npl = List.length addr in
      if npl > 0 then s "  uint64_t _plops = 0;\n" ;
      (* Its own draws: a GPU lane's delays would shift both sides
         together, leaving the relative phase unchanged. *)
      s (Printf.sprintf "  const uint32_t _who = HET_WHO_CPU(%du);\n" !cpu_ord) ;
      incr cpu_ord ;
      let call_args =
        String.concat ","
          (List.map (fun (_,a) -> Printf.sprintf "a->%s + _slot" a) addr
           @ List.map (fun (_,b) -> Printf.sprintf "a->%s + _n" b) bufs) in
      s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
      s "    size_t _slot = (size_t)_n * HET_SLOT_STRIDE_WORDS;\n" ;
      s (Printf.sprintf "    const uint64_t _kn = (uint64_t)_n * %du;\n"
           (1 + 2 * npl)) ;

      if npl > 0 then begin
        (* The hint must name the line this iteration touches, so
           the array is rebuilt per iteration. *)
        s (Printf.sprintf "    void* const _pl[%d] = { %s };\n" npl
             (String.concat ", "
                (List.map
                   (fun (_,n) -> Printf.sprintf "(void*)(a->%s + _slot)" n)
                   addr))) ;
        s (Printf.sprintf
             "    _plops += het_cpu_preload(_pl, %d, a->_seed, _who, _kn + 1u, HET_CPU_PRELOAD_PCT);\n"
             npl)
      end ;
      s (Printf.sprintf
           "    a->_rdv[_n] = het_rdv_host(a->barrier, (uint64_t)NPART*(uint64_t)(_n+1), a->_cap, %s);\n"
           dialect.gd_poke_arg) ;
      s "    het_rdv_jitter(het_draw(a->_seed, _who, _kn), HET_RELEASE_JITTER);\n" ;
      s (Printf.sprintf "    het_run_P%d(%s);\n" proc call_args) ;
      s "  }\n" ;
      if npl > 0 then
        s "  __atomic_fetch_add(&a->_tally->preload_ops, _plops, __ATOMIC_RELAXED);\n" ;
      s {|  return NULL;
}

|})
    procs.pr_cpus

(* The outcome vector's column labels, and the histogram printer that walks
   them: `_labels[i]' names column i of every `_o[]' the readout builds. *)
let dump_outcome_labels outcome ch =
  let s = output_string ch in
  let nslots = n_columns outcome in
  let labelstr =
    String.concat ", "
      (List.map (fun ((p,r),_) -> Printf.sprintf "\"%d:%s\"" p r)
         outcome.oc_reg_columns
       @ List.map (Printf.sprintf "\"[%s]\"") outcome.oc_loc_columns) in
  s (Printf.sprintf "static const char* _labels[%d] = { %s };\n"
       (max 1 nslots) labelstr) ;
  s {|static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
  fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
|} ;
  if nslots = 0 then s "  (void)o;\n"
  else begin
    s (Printf.sprintf "  for (int i=0;i<%d;i++)" nslots) ;
    s {| fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
|}
  end ;
  s {|  fprintf(_ch, "\n");
}

|}

(* The file-scope definitions the driver below closes over. *)
let dump_file_scope_defs dialect ch =
  let s = output_string ch in
  s {|/* Placement refusals.  Raised where a placement was requested but not
   achieved (CUDA render only); stays 0 on the HIP render, which
   carries no placement code. */
static int _het_place_failures = 0;

|} ;
  s dialect.gd_shared_mem_defs ;
  s "\n" ;
  s dialect.gd_noise_mem_defs ;
  s "\n"

let dump h dialect ch =
  let identity = h.h_identity and geometry = h.h_geometry in
  let procs = h.h_procs and memory = h.h_memory in
  dump_prelude dialect identity geometry procs ch ;
  dump_kernel dialect identity memory procs ch ;
  dump_cpu_thread_wrappers dialect procs memory ch ;
  dump_outcome_labels h.h_outcome ch ;
  dump_file_scope_defs dialect ch ;
  HetDriverMain.dump h dialect ch
