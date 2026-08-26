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

(* HetLitmus: the emitted driver's main() -- allocation, launch, the run loop,
   the slot readout and teardown -- written in one GPU dialect.
   Design: hetlitmus/docs/het-emission.md. *)

open HetDialect

open HetHarness

(* Every shared global is SIZE_OF_TEST slots wide, one per iteration. *)
let global_bytes = "sizeof(int)*SIZE_OF_TEST*HET_SLOT_STRIDE_WORDS"
let buf_bytes ty = Printf.sprintf "sizeof(%s)*SIZE_OF_TEST" ty
let rdv_bytes = "sizeof(uint8_t)*SIZE_OF_TEST"

let dump h dialect ch =
  let s = output_string ch in
  let tname = h.h_name and it = h.h_shape in
  let id = h.h_ident and cpu_only = h.h_cpu_only in
  let kernel_globals = it.i_gpu_globals in
  let cpu_bufs cp = cpu_bufs it cp and gpu_bufs = gpu_bufs it in
            s "int main(void){\n" ;
            (* One gd_alloc_shared per location, so the free matches it. *)
            List.iter
              (fun g ->
                s (Printf.sprintf
                     "  int *%s; gd_alloc_shared((void**)&%s, %s);\n"
                     g g global_bytes))
              it.i_all_globals ;

            (* The rendezvous counter gets a slot of its own *)
            s "  uint64_t *barrier; gd_alloc_shared((void**)&barrier, sizeof(int)*HET_SLOT_STRIDE_WORDS);\n" ;
            (* read buffers -- OFF the coherent race path. *)
            List.iter
              (fun (_,_,name,dev,ty) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  %s *%s; %s\n" ty name
                        (dialect.gd_dev_malloc name (buf_bytes ty))) ;
                   s (Printf.sprintf
                        "  %s *%s_h = (%s*)malloc_check(%s);\n"
                        ty name ty (buf_bytes ty))
                | `Cpu ->
                   s (Printf.sprintf
                        "  %s *%s = (%s*)malloc_check(%s);\n"
                        ty name ty (buf_bytes ty)))
              it.i_bufs ;
            (* rendezvous flags, each on the side that writes it. *)
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "  uint8_t *%s; %s\n" g
                     (dialect.gd_dev_malloc g rdv_bytes)) ;
                s (Printf.sprintf "  uint8_t *%s_h = (uint8_t*)malloc_check(%s);\n"
                     g rdv_bytes))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  uint8_t *%s = (uint8_t*)malloc_check(%s);\n"
                     (rdv_cpu_name cp.cp_proc) rdv_bytes))
              it.i_cpus ;

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
            (* [Alglave15 sec 4.3.1 Tab. 6] *)
            s "  if (HET_MEM_STRESS_PCT > 0 && _stressBlocks == 0)\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: the mem-stress population is EMPTY (test=%d + noise=%d fills the co-resident cap %d).  HET_MEM_STRESS_PCT=%d asks for scratchpad stress and NO block will do any.\\n\",\n\
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
            s (Printf.sprintf "  uint32_t *_gpu_done; %s\n"
                 (dialect.gd_dev_malloc "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "  uint32_t *_stress_tally; %s\n"
                 (dialect.gd_dev_malloc "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            s "  uint32_t _stress_tally_h[HET_TALLY_N];\n" ;
            s "  uint32_t *_scratch_loc_h = (uint32_t*)malloc_check(sizeof(uint32_t)*_grid);\n" ;
            (* The CPU stress population *)
            let n_cpu_threads = List.length it.i_cpus in
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

            s "  if (HET_NOISE_MB < HET_LLC_MB) {\n" ;
            s "#if HET_LLC_MB_IS_FALLBACK\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%d is below the %d MB threshold -- a FALLBACK figure, measured on another part, not a last-level-cache capacity for this target (build with -DHET_LLC_MB=<MB> to supply it).  A noise buffer that fits in the last-level cache is served locally and crosses no %s, so this run may not be stressed at all.\\n\",\n\
               \            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);\n" ;
            s "#else\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_NOISE_MB=%d is BELOW the HET_LLC_MB supplied for this build (%d MB) -- the noise buffers fit in the last-level cache, so the reads are served locally and generate NO interconnect traffic.  This run is NOT %s-stressed.\\n\",\n\
               \            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);\n" ;
            s "#endif\n" ;
            s "  }\n" ;
            s "  if (_noiseBlocks > 0) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_ddr, (size_t)_noise_words*sizeof(uint64_t), 2);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB DDR noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB, HET_DEV_HALF, HET_LINK_NAME); _noise_ddr = NULL; _noise_blocks = 0; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the DDR noise buffer could not be homed on the CPU -- this device has no interconnect-stress lever (no ATS/coherent host-device link), so %s of the noise is exercising plumbing, not the %s.\\n\", HET_DEV_HALF, HET_LINK_NAME);\n" ;
            s "  }\n" ;
            s "  if (HET_NOISE_CPU) {\n" ;
            s "    int _rc = gd_alloc_noise((void**)&_noise_hbm, (size_t)_noise_words*sizeof(uint64_t), 1);\n" ;
            s "    if (_rc < 0) { fprintf(stderr, \"HetLitmus WARNING: could not allocate the %d MB HBM noise buffer -- %s of the %s noise is DISABLED for this run.\\n\", (int)HET_NOISE_MB, HET_HOST_HALF, HET_LINK_NAME); _noise_hbm = NULL; }\n" ;
            s "    else if (_rc > 0) fprintf(stderr, \"HetLitmus WARNING: the HBM noise buffer could not be homed on the GPU -- %s of the noise is exercising plumbing, not the %s.\\n\", HET_HOST_HALF, HET_LINK_NAME);\n" ;
            s "  }\n" ;
            s "  fprintf(stderr, \"HetLitmus cpu-stress: cores=%d test=%d enemies=%d spread=%u stride=%d seq=%d preload=%d%% aff=%d | noise: gpu_blocks=%u cpu=%d words=%llu (%d MB) place=%d\\n\",\n\
               \          _ncores, _nCpuTest, _nEnemy, _cpu_spread, (int)HET_CPU_STRIDE,\n\
               \          (int)HET_CPU_ENEMY_SEQ, (int)HET_CPU_PRELOAD_PCT, _aff,\n\
               \          _noise_blocks, (int)HET_NOISE_CPU,\n\
               \          (unsigned long long)_noise_words, (int)HET_NOISE_MB, (int)HET_PLACE);\n" ;
            s "  outs_t* hist = NULL;\n" ;

            (* One counter per run (hetlitmus/docs/harness-reporting.md sec 5). *)
            s "  het_obs_record _recs[NUMBER_OF_RUN];\n" ;
            s "  memset(_recs, 0, sizeof _recs);\n" ;
            (* Campaign knobs read through getenv, never -D: a retune needs
               no rebuild and no branch folds away.  See het_verdict.h. *)
            s "  int _runs_budget = (int)het_env_long(\"HET_RUNS_MAX\", NUMBER_OF_RUN);\n" ;
            s "  if (_runs_budget > NUMBER_OF_RUN) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_RUNS_MAX=%d exceeds the compiled NUMBER_OF_RUN=%d -- clamped.  Grow R by re-invoking with a FRESH HET_SEED (hetlitmus/campaign.py), never by replaying the same seeds.\\n\", _runs_budget, (int)NUMBER_OF_RUN);\n" ;
            s "    _runs_budget = NUMBER_OF_RUN;\n" ;
            s "  }\n" ;
            s "  if (_runs_budget < 1) _runs_budget = 1;\n" ;
            s "  int _adaptive = (int)het_env_long(\"HET_ADAPTIVE\", 0);\n" ;
            s "  int _rate_mode = (int)het_env_long(\"HET_RATE\", 0);\n" ;
            s "  int _confirm_runs = (int)het_env_long(\"HET_CONFIRM_RUNS\", 30);\n" ;
            s "  uint32_t _seed0 = (uint32_t)het_env_long(\"HET_SEED\", (long)HET_SEED);\n" ;

            (* The rendezvous spin caps. *)
            s "  long _cap_cpu = het_env_long(\"HET_CAP_CPU\", (long)HET_CAP_CPU);\n" ;
            s "  long _cap_gpu_env = het_env_long(\"HET_CAP_GPU\", (long)HET_CAP_GPU);\n" ;
            s "  if (_cap_cpu < 0) _cap_cpu = 0;\n" ;
            s "  if (_cap_gpu_env < 0) _cap_gpu_env = 0;\n" ;
            s "  unsigned long _cap_cpu_u = (unsigned long)_cap_cpu;\n" ;
            s "  unsigned long _cap_gpu_u = (unsigned long)_cap_gpu_env;\n" ;
            s "  if (_cap_cpu_u > 0xffffffffUL) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_CAP_CPU=%lu exceeds the %lu polls the record can carry -- clamped.\\n\", _cap_cpu_u, 0xffffffffUL);\n" ;
            s "    _cap_cpu_u = 0xffffffffUL; _cap_cpu = (long)_cap_cpu_u;\n" ;
            s "  }\n" ;
            s "  if (_cap_gpu_u > 0xffffffffUL) {\n" ;
            s "    fprintf(stderr, \"HetLitmus WARNING: HET_CAP_GPU=%lu exceeds the %lu polls a lane can carry -- clamped.\\n\", _cap_gpu_u, 0xffffffffUL);\n" ;
            s "    _cap_gpu_u = 0xffffffffUL;\n" ;
            s "  }\n" ;
            s "  uint32_t _cap_gpu = (uint32_t)_cap_gpu_u;\n" ;
            s "  int _nrec = 0;\n" ;
            s "  for (int _run=0; _run<_runs_budget; ++_run) {\n" ;

            (* Every shared location is zeroed over all its slots, once per run. *)
            List.iter
              (fun g ->
                s (Printf.sprintf "    memset(%s, 0, %s);\n" g global_bytes))
              it.i_all_globals ;
            s "    *barrier = 0;\n" ;
            s "    uint32_t _seed = _seed0 + (uint32_t)_run;\n" ;
            s "    srand((unsigned int)_seed);\n" ;
            s "    het_set_scratch_locations(_scratch_loc_h, _grid);\n" ;

            (* The CPU stress population, spawned BEFORE the test threads. *)
            s "    memset(&_ct, 0, sizeof _ct);\n" ;

            (* A host with no cache primitives issues zero preload hints. *)
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
                 (dialect.gd_dev_memset0 "_gpu_done" "sizeof(uint32_t)")) ;
            s (Printf.sprintf "    %s\n"
                 (dialect.gd_dev_memset0 "_stress_tally"
                    "sizeof(uint32_t)*HET_TALLY_N")) ;
            List.iter
              (fun (_,_,name,dev,ty) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "    %s\n"
                        (dialect.gd_dev_memset0 name (buf_bytes ty)))
                | `Cpu ->
                   s (Printf.sprintf "    memset(%s, 0, %s);\n"
                        name (buf_bytes ty)))
              it.i_bufs ;
            List.iter
              (fun gp ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_dev_memset0 (rdv_gpu_name gp.gp_proc) rdv_bytes)))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "    memset(%s, 0, %s);\n"
                     (rdv_cpu_name cp.cp_proc) rdv_bytes))
              it.i_cpus ;
            (* Cores go out in emission order, so no two test threads share one. *)
            let ti = ref 0 in
            List.iter
              (fun cp ->
                let proc = cp.cp_proc in
                let addr = cp.cp_addrs and bufs = cpu_bufs cp in
                let core =
                  Printf.sprintf
                    "(_aff ? ((HET_CPU_TEST_CORE0 + %d) %% _ncores) : -1)" !ti in
                incr ti ;
                let fields =
                  String.concat ", "
                    (List.map snd addr
                     @ ["barrier"] @ List.map snd bufs
                     @ [rdv_cpu_name proc ; "_cap_cpu"]
                     @ [core ; "_seed" ; "&_ct"]) in
                s (Printf.sprintf "    cpu_args_P%d _ca%d = { %s };\n"
                     proc proc fields) ;
                s (Printf.sprintf
                     "    pthread_t _th%d; pthread_create(&_th%d, NULL, cpu_thread_P%d, &_ca%d);\n"
                     proc proc proc proc))
              it.i_cpus ;

            (* args[] in kernel-parameter order. *)
            let args_addrs =
              String.concat ", "
                (List.map (fun g -> "&" ^ g) kernel_globals
                 @ List.map (fun (_,_,name,_,_) -> "&"^name) gpu_bufs
                 @ List.map (fun gp -> "&" ^ rdv_gpu_name gp.gp_proc) it.i_gpus
                 @ ["&barrier" ; "&_cap_gpu"]
                 @ ["&_scratch" ; "&_scratch_loc" ; "&_gpu_done" ;
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
              (fun cp ->
                s (Printf.sprintf "    pthread_join(_th%d, NULL);\n" cp.cp_proc))
              it.i_cpus ;
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
            s "        fprintf(stderr, \"HetLitmus WARNING: HET_CPU_PRELOAD_PCT=%d but ZERO preload hints were issued -- the cache preload is INERT (this host may have no cache primitives; see het_cpu_stress.h HET_CPU_PRELOAD_LIVE).\\n\", (int)HET_CPU_PRELOAD_PCT);\n" ;
            s "      if (_noise_blocks > 0 && _ng == 0)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u device-side noise block(s) were launched but NONE completed a round -- %s of the %s noise did NOT run.  This run is not interconnect-stressed.\\n\", _noise_blocks, HET_DEV_HALF, HET_LINK_NAME);\n" ;
            s "      if (_ct.aff_failures)\n" ;
            s "        fprintf(stderr, \"HetLitmus WARNING: %u sched_setaffinity call(s) FAILED -- those threads are wherever the scheduler put them.  The pinning is fiction and the stress topology is not the one being tuned.\\n\", _ct.aff_failures);\n" ;
            s "    }\n" ;

            List.iter
              (fun (_,_,name,_,ty) ->
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (name^"_h") name (buf_bytes ty))))
              gpu_bufs ;
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "    %s\n"
                     (dialect.gd_memcpy_d2h (g^"_h") g rdv_bytes)))
              it.i_gpus ;
            (* ======== the slot readout ======================================== *)
            s "    het_obs_record _rec; memset(&_rec, 0, sizeof _rec);\n" ;
            s (Printf.sprintf
                 "    _rec.test_name = \"%s\"; _rec.instance_id = 0; _rec.run_id = _run;\n"
                 tname) ;
            s "    _rec.N = SIZE_OF_TEST;\n" ;
            (* het_verdict() refuses an unstamped record
               (hetlitmus/docs/harness-reporting.md sec 2). *)
            s "    _rec.rec_magic = HET_REC_MAGIC;\n" ;
            s (Printf.sprintf
                 "    _rec.cpu_only = %d;  /* 1 iff EVERY proc is a CPU proc */\n"
                 (if cpu_only then 1 else 0)) ;

            (* gpu_lanes is a build fact, NOT cpu_only's cycle fact; het_verdict
               keys the absent-GPU-stress caveat on it. *)
            s "    _rec.gpu_lanes = HET_GPU_LANES;\n" ;

            (* A mechanism is requested ONLY where it can run: a standing
               request that nothing performs reads as dead
               (hetlitmus/docs/harness-reporting.md sec 3). *)
            s "    _rec.stress_requested =\n\
               \        ((HET_GPU_LANES > 0 && (HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0)) ? HET_REQ_GPU_STRESS : 0u)\n\
               \      | ((_nEnemy > 0) ? HET_REQ_CPU_ENEMY : 0u)\n\
               \      | ((HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) ? HET_REQ_CPU_PRELOAD : 0u)\n\
               \      | ((HET_NOISE_CPU && _noise_cpu_on) ? HET_REQ_NOISE_CPU : 0u)\n\
               \      | ((_noise_blocks > 0) ? HET_REQ_NOISE_GPU : 0u);\n" ;
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

            s "    _rec.cap_cpu = (uint32_t)_cap_cpu;\n" ;
            s "    _rec.cap_gpu = _cap_gpu;\n" ;
            s "    _rec.cap_calibrated = HET_CAP_CALIBRATED;\n" ;
            s it.i_readout ;

            s "    fprintf(stderr, \"HetLitmus rendezvous: scored=%llu discarded=%llu (cap_cpu=%llu cap_gpu=%llu) caps=%lu/%u jitter=%d discard_max=%d%% %s\\n\",\n\
               \            (unsigned long long)_rec.iters_scored,\n\
               \            (unsigned long long)_rec.iters_discarded,\n\
               \            (unsigned long long)_rec.rdv_cap_cpu,\n\
               \            (unsigned long long)_rec.rdv_cap_gpu,\n\
               \            (unsigned long)_cap_cpu, _cap_gpu, (int)HET_RELEASE_JITTER,\n\
               \            (int)HET_RDV_MAX_DISCARD_PCT,\n\
               \            HET_CAP_CALIBRATED ? \"caps calibrated\" : \"caps UNCALIBRATED\");\n" ;
            s "    het_obs_record_print(stdout, &_rec);\n" ;

            s "    het_verdict_print(stdout, &_rec);\n" ;
            s "    _recs[_nrec++] = _rec;\n" ;

            (* Early stop after each run, decided from the records so far
               (het_verdict.h); with HET_ADAPTIVE unset the loop runs to budget. *)
            s "    if (_adaptive) {\n" ;
            s "      het_campaign_stop_t _stop = het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs);\n" ;
            s "      if (_stop != HET_CAMPAIGN_CONTINUE) {\n" ;
            s (Printf.sprintf
                 "        printf(\"HetCampaign %s stop=%%s runs=%%d budget=%%d\\n\",\n\
                  \               het_campaign_stop_name(_stop), _nrec, _runs_budget);\n"
                 tname) ;
            s "        { const char *_why = het_campaign_stop_why(_stop);\n" ;
            s "          if (*_why) printf(\"  %s.\\n\", _why); }\n" ;
            s "        break;\n" ;
            s "      }\n" ;
            s "    }\n" ;
            s "  }\n" ;

            (* The aggregate reuses het_verdict() per record, so it inherits
               every disqualifier (hetlitmus/docs/harness-reporting.md sec 5). *)
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
            List.iter
              (fun g -> s (Printf.sprintf "  gd_free_shared(%s);\n" g))
              it.i_all_globals ;
            s "  gd_free_shared(barrier);\n" ;
            List.iter
              (fun (_,_,name,dev,_) ->
                match dev with
                | `Gpu ->
                   s (Printf.sprintf "  %s free(%s_h);\n"
                        (dialect.gd_free name) name)
                | `Cpu -> s (Printf.sprintf "  free(%s);\n" name))
              it.i_bufs ;
            List.iter
              (fun gp ->
                let g = rdv_gpu_name gp.gp_proc in
                s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free g) g))
              it.i_gpus ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "  free(%s);\n" (rdv_cpu_name cp.cp_proc)))
              it.i_cpus ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch_loc")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_gpu_done")) ;
            s (Printf.sprintf "  %s\n" (dialect.gd_free "_stress_tally")) ;
            s "  free(_scratch_loc_h);\n" ;
            s "  free(_cpu_scratch);\n" ;
            s "  free(_cpu_idx);\n" ;
            s "  free(_ea);\n" ;
            s "  free(_eth);\n" ;
            s "  gd_free_noise(_noise_ddr);\n" ;
            s "  gd_free_noise(_noise_hbm);\n" ;
            s "  return 0;\n}\n"
