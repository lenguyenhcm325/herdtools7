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

(* HetLitmus: the .cu/.hip render -- the file prelude, the GPU kernel (test
   lanes and stressing workgroups), the CPU pthread wrappers and the outcome
   labels, in one dialect; HetDriverMain writes the main() that closes it.
   Design: hetlitmus/docs/het-emission.md. *)

open HetDialect

open HetHarness

let dump h dialect ch =
  let s = output_string ch in
  let tname = h.h_name and it = h.h_shape in
  let id = h.h_ident and pair_label = h.h_pair_label in
  let kernel_globals = it.i_gpu_globals in
  let cpu_bufs cp = cpu_bufs it cp and gpu_bufs = gpu_bufs it in
            s (Printf.sprintf
                 "// HetLitmus GPU kernel + driver for %s (%s dialect).\n"
                 tname dialect.gd_name) ;
            s "// P(gpu) run as a GPU kernel; P(cpu) as a pthread (see _cpu.c).\n" ;
            s "// Iteration _n of both sides touches slot _n of every location and\n" ;
            s "// records its loads at index _n; the post-run readout reads the\n" ;
            s "// outcome of iteration _n out of slot _n into a het_obs_record.\n" ;
            s dialect.gd_shared_mem_note ;
            s "// every iteration begins at a relaxed system-scope counter rendezvous.\n" ;
            s (Printf.sprintf
                 "// Compile-only by default (%s -c); comp.sh %s-link / make %s-bin\n"
                 dialect.gd_compiler dialect.gd_target dialect.gd_target) ;
            s "// link the runnable binary, guarded by uname -m.  DO NOT EDIT.\n" ;
            s (dialect.gd_runtime_include ^ "\n") ;
            s "#include <cstdio>\n#include <cstdint>\n#include <cstdlib>\n" ;
            s "#include <cstring>\n#include <cmath>\n" ;
            s "#include <pthread.h>\n#include <inttypes.h>\n" ;

            s (Printf.sprintf "#define HET_PAIR_NAME %S\n" pair_label) ;
            (match dialect.gd_place_lever with
             | Some lever -> s (Printf.sprintf "#define HET_PLACE_LEVER %S\n" lever)
             | None -> ()) ;
            s "#include \"het_stress.h\"\n" ;
            s "#include \"het_cpu_stress.h\"\n" ;
            s "#include \"het_verdict.h\"\n" ;
            s "#include \"het_rdv.h\"\n" ;
            s "extern \"C\" {\n" ;
            s "#include \"outs.h\"\n" ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  void het_run_P%d(%s);\n"
                     cp.cp_proc (cpu_sig cp)))
              it.i_cpus ;
            s "}\n" ;
            s {ocaml|extern "C" void *malloc_check(size_t sz){
  void *p = malloc(sz);
  if (p == NULL) { fprintf(stderr,"out of memory\n"); exit(2); }
  return p;
}
|ocaml} ;
            s (Printf.sprintf "\n#define NPART %d\n" it.i_npart) ;
            s (Printf.sprintf "#define SIZE_OF_TEST %d\n" h.h_size) ;
            s (Printf.sprintf "#define NUMBER_OF_RUN %d\n" h.h_runs) ;
            s "\n" ;
            s (Printf.sprintf "#ifndef HET_BLOCK_DIM\n#define HET_BLOCK_DIM %d\n#endif\n"
                 (max 1 it.i_bdim)) ;
            s (Printf.sprintf "#define HET_TEST_BLOCKS %d\n" it.i_blocks) ;
            s (Printf.sprintf "#define HET_GPU_LANES %d\n\n" it.i_lanes) ;
            (* The kernel *)
            let kparams =
              String.concat ", "
                (List.map (fun g -> Printf.sprintf "int* %s" g) kernel_globals
                 @ List.map
                     (fun (_,_,name,_,ty) -> Printf.sprintf "%s* %s" ty name)
                     gpu_bufs
                 @ List.map
                     (fun gp -> Printf.sprintf "uint8_t* %s" (rdv_gpu_name gp.gp_proc))
                     it.i_gpus
                 @ ["uint64_t* barrier" ; "uint32_t _cap_gpu"]
                 @ ["uint32_t* _scratch" ; "uint32_t* _scratch_loc" ;
                    "uint32_t* _gpu_done" ;
                    "uint32_t* _stress_tally" ;
                    "uint32_t _seed" ; "uint32_t _pre_pat" ; "uint32_t _mem_pat" ;
                    "uint64_t* _noise_ddr" ; "uint64_t _noise_words" ;
                    "uint32_t _noise_blocks" ; "uint32_t _noise_chunk" ;
                    "uint32_t _noise_stride"]) in
            s (Printf.sprintf "__global__ void litmus_%s(%s) {\n" id kparams) ;
            s "  het_rng_t _rng = het_rng_init(_seed, blockIdx.x * blockDim.x + threadIdx.x);\n" ;

            (* the GPU test lanes *)
            List.iter
              (fun gp ->
                s (Printf.sprintf "  if (blockIdx.x == %d && threadIdx.x == %d) {\n"
                     gp.gp_blk gp.gp_lane) ;
                List.iter (fun n -> s (Printf.sprintf "    int r%d = 0;\n" n))
                  gp.gp_regs ;
                (* #pragma unroll 1 -- hetlitmus/docs/amd-faithfulness.md,
                   "The mapping". *)
                s "    #pragma unroll 1\n" ;
                s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                s "      if (het_rng_pct(&_rng, HET_PRE_STRESS_PCT))\n" ;
                s "        het_do_stress(_scratch, _scratch_loc, HET_PRE_STRESS_ITER, _pre_pat, _stress_tally);\n" ;

                (* Rendezvous, jitter, then the tested ops; nothing is placed
                   between two tested accesses
                   (hetlitmus/docs/00-environment-design.md sec 3.6). *)
                s (Printf.sprintf
                     "      %s[_n] = het_rdv_device(barrier, (uint64_t)NPART*(uint64_t)(_n+1), _cap_gpu);\n"
                     (rdv_gpu_name gp.gp_proc)) ;
                s "      het_rdv_jitter(&_rng, HET_RELEASE_JITTER);\n" ;
                List.iter
                  (fun instr -> dialect.gd_dump_instr ch ~het:(Some "_n") "      " instr)
                  gp.gp_instrs ;
                List.iteri
                  (fun li n ->
                    s (Printf.sprintf "      %s[_n] = r%d;\n"
                         (buf_name_of gp.gp_proc li) n))
                  gp.gp_regs ;
                s "    }\n" ;
                s "    het_scratch_bump(_gpu_done);\n" ;
                s "  }\n")
              it.i_gpus ;

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

            (* The CPU pthread wrappers *)
            s dialect.gd_poke_def ;
            let cpu_ord = ref 0 in
            List.iter
              (fun cp ->
                let proc = cp.cp_proc in
                let addr = cp.cp_addrs and bufs = cpu_bufs cp in
                s (Printf.sprintf "struct cpu_args_P%d {\n" proc) ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) addr ;
                s "  uint64_t* barrier;\n" ;
                List.iter (fun (decl,_) -> s (Printf.sprintf "  %s;\n" decl)) bufs ;
                s "  uint8_t* _rdv; long _cap;\n" ;
                s "  int _core; uint32_t _seed; het_cpu_tally* _tally;\n" ;
                s "};\n" ;
                s (Printf.sprintf "static void* cpu_thread_P%d(void* _a) {\n" proc) ;
                s (Printf.sprintf "  cpu_args_P%d* a = (cpu_args_P%d*)_a;\n" proc proc) ;
                s "  het_cpu_affinity(a->_core, a->_tally);\n" ;
                let npl = List.length addr in
                if npl > 0 then begin
                  s (Printf.sprintf
                       "  uint32_t _plrng = het_cpu_rng_init(a->_seed, %du);\n" proc) ;
                  s "  uint64_t _plops = 0;\n"
                end ;
                (* Its own jitter stream: a GPU lane's delays would shift both
                   sides together, leaving the relative phase unchanged.  Lanes
                   past HET_TEST_BLOCKS*HET_BLOCK_DIM are no test lane's. *)
                s (Printf.sprintf
                     "  het_rng_t _jrng = het_rng_init(a->_seed, (uint32_t)(HET_TEST_BLOCKS*HET_BLOCK_DIM + %d));\n"
                     !cpu_ord) ;
                incr cpu_ord ;
                let call_args =
                  String.concat ","
                    (List.map (fun (_,a) -> Printf.sprintf "a->%s + _slot" a) addr
                     @ List.map (fun (_,b) -> Printf.sprintf "a->%s + _n" b) bufs) in
                s "  for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
                s "    size_t _slot = (size_t)_n * HET_SLOT_STRIDE_WORDS;\n" ;

                if npl > 0 then begin
                  (* The hint must name the line this iteration touches, so
                     the array is rebuilt per iteration. *)
                  s (Printf.sprintf "    void* const _pl[%d] = { %s };\n" npl
                       (String.concat ", "
                          (List.map
                             (fun (_,n) -> Printf.sprintf "(void*)(a->%s + _slot)" n)
                             addr))) ;
                  s (Printf.sprintf
                       "    _plops += het_cpu_preload(_pl, %d, &_plrng, HET_CPU_PRELOAD_PCT);\n"
                       npl)
                end ;
                s (Printf.sprintf
                     "    a->_rdv[_n] = het_rdv_host(a->barrier, (uint64_t)NPART*(uint64_t)(_n+1), a->_cap, %s);\n"
                     dialect.gd_poke_arg) ;
                s "    het_rdv_jitter(&_jrng, HET_RELEASE_JITTER);\n" ;
                s (Printf.sprintf "    het_run_P%d(%s);\n" proc call_args) ;
                s "  }\n" ;
                if npl > 0 then
                  s "  __atomic_fetch_add(&a->_tally->preload_ops, _plops, __ATOMIC_RELAXED);\n" ;
                s "  return NULL;\n}\n\n")
              it.i_cpus ;
            s it.i_labels ;
            s "/* Placement refusals.  Incremented only where placement EXISTS (the\n\
               \   CUDA render's cudaMemAdvise); stays 0 on the HIP render, which\n\
               \   carries no placement code. */\n" ;
            s "static int _het_place_failures = 0;\n\n" ;
            s dialect.gd_shared_mem_defs ;
            s "\n" ;
            s dialect.gd_noise_mem_defs ;
            s "\n" ;
            HetDriverMain.dump h dialect ch
