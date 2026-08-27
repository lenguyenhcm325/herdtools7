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

(* HetLitmus: the emitted driver's main(), one phase function per part of it;
   contract in hetDriverMain.mli. *)

open HetDialect

open HetHarness

let dump_test_state_alloc dialect memory procs ch =
  let s = output_string ch in
  List.iter
    (fun o ->
      let n = o.mo_name and ty = o.mo_type and b = o.mo_bytes in
      match o.mo_where with
      | Shared ->
         s (Printf.sprintf "  %s *%s; gd_alloc_shared((void**)&%s, %s);\n"
              ty n n b)
      | Device ->
         s (Printf.sprintf "  %s *%s; %s\n" ty n (dialect.gd_dev_malloc n b)) ;
         s (Printf.sprintf "  %s *%s_h = (%s*)malloc_check(%s);\n" ty n ty b)
      | Host ->
         s (Printf.sprintf "  %s *%s = (%s*)malloc_check(%s);\n" ty n ty b))
    (memory_objects memory procs)

let dump_launch_geometry dialect identity ch =
  let s = output_string ch in
  let id = identity.id_ident in
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
  (* A quoted block's interior is the emitted text verbatim: its lines
     start at column 0, since an indent would be emitted too. *)
  s {|  int _maxGrid = _bpsm * _nsm;
  int _testBlocks = HET_TEST_BLOCKS;
  int _noiseBlocks = HET_NOISE_GPU_BLOCKS;
  if (_noiseBlocks < 0) _noiseBlocks = 0;
  int _stressBlocks = (HET_STRESS_BLOCKS >= 0) ? HET_STRESS_BLOCKS
                                              : (_maxGrid - _testBlocks - _noiseBlocks);
  if (_stressBlocks < 0) _stressBlocks = 0;
  int _grid = _testBlocks + _noiseBlocks + _stressBlocks;
  if (_grid > _maxGrid) { fprintf(stderr, "grid %d exceeds co-resident cap %d\n", _grid, _maxGrid); return 2; }
|} ;
  (* [Alglave15 sec 4.3.1 Tab. 6] *)
  s {|  if (HET_MEM_STRESS_PCT > 0 && _stressBlocks == 0)
    fprintf(stderr, "HetLitmus WARNING: the mem-stress population is EMPTY (test=%d + noise=%d fills the co-resident cap %d).  HET_MEM_STRESS_PCT=%d asks for scratchpad stress and NO block will do any.\n",
            _testBlocks, _noiseBlocks, _maxGrid, (int)HET_MEM_STRESS_PCT);
  uint32_t _pre_pat = (uint32_t)HET_PRE_STRESS_PATTERN;
  uint32_t _mem_pat = (uint32_t)HET_MEM_STRESS_PATTERN;
  fprintf(stderr, "HetLitmus: blockDim=%d grid=%d (test=%d stress=%d, co-resident cap=%d) pre_pat=%u mem_pat=%u\n",
          (int)HET_BLOCK_DIM, _grid, _testBlocks, _stressBlocks, _maxGrid,
          _pre_pat, _mem_pat);
|}

let dump_gpu_stress_alloc dialect ch =
  let s = output_string ch in
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
  s "  uint32_t *_scratch_loc_h = (uint32_t*)malloc_check(sizeof(uint32_t)*_grid);\n"

let dump_cpu_stress_setup procs ch =
  let s = output_string ch in
  (* The CPU stress population *)
  let n_cpu_threads = List.length procs.pr_cpus in
  s "  int _ncores = het_cpu_ncores();\n" ;
  s "  int _aff = HET_CPU_AFFINITY;\n" ;
  s (Printf.sprintf "  int _nCpuTest = %d;\n" n_cpu_threads) ;
  s {|  int _nEnemy = HET_CPU_ENEMIES;
  if (_nEnemy < 0) {
    _nEnemy = _ncores - _nCpuTest - (HET_NOISE_CPU ? 1 : 0) - HET_CPU_RESERVE_CORES;
    if (_nEnemy < 0) _nEnemy = 0;
  }
  het_cpu_tally _ct;
  int _stress_go = 0;
  uint64_t *_cpu_scratch =
    (uint64_t*)malloc_check(sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);
  memset(_cpu_scratch, 0, sizeof(uint64_t)*HET_CPU_SCRATCH_WORDS);
  uint32_t _cpu_nregions = (uint32_t)(HET_CPU_SCRATCH_WORDS / HET_CPU_STRIDE);
  if (_cpu_nregions < 1) _cpu_nregions = 1;
  uint32_t _cpu_spread = HET_CPU_SPREAD;
  if (_cpu_spread > _cpu_nregions) {
    fprintf(stderr, "HetLitmus WARNING: realised CPU stress spread is %u region(s), not HET_CPU_SPREAD=%d -- the enemy scratchpad (HET_CPU_SCRATCH_WORDS/HET_CPU_STRIDE) holds only %u.  The CPU stress is weaker than the configuration says.\n",
            _cpu_nregions, (int)HET_CPU_SPREAD, _cpu_nregions);
    _cpu_spread = _cpu_nregions;
  }
  uint32_t *_cpu_idx = (uint32_t*)malloc_check(sizeof(uint32_t)*_cpu_nregions);
  het_cpu_enemy_args *_ea = (het_cpu_enemy_args*)malloc_check(sizeof(het_cpu_enemy_args)*(_nEnemy>0?_nEnemy:1));
  pthread_t *_eth = (pthread_t*)malloc_check(sizeof(pthread_t)*(_nEnemy>0?_nEnemy:1));
|}

let dump_noise_setup ch =
  let s = output_string ch in
  s {|  uint64_t _noise_words = (uint64_t)HET_NOISE_MB * 1024ull * 1024ull / sizeof(uint64_t);
  uint32_t _noise_blocks = (uint32_t)_noiseBlocks;
  uint32_t _noise_chunk = (uint32_t)HET_NOISE_CHUNK;
  uint32_t _noise_stride = (uint32_t)HET_NOISE_STRIDE;
  uint64_t *_noise_ddr = NULL;   /* CPU-homed: the GPU streams it */
  uint64_t *_noise_hbm = NULL;   /* GPU-homed: the CPU streams it */
  het_cpu_noise_args _na; pthread_t _nth; int _noise_cpu_on = 0;
  if (HET_NOISE_MB < HET_LLC_MB) {
#if HET_LLC_MB_IS_FALLBACK
    fprintf(stderr, "HetLitmus WARNING: HET_NOISE_MB=%d is below the %d MB threshold -- a FALLBACK figure, measured on another part, not a last-level-cache capacity for this target (build with -DHET_LLC_MB=<MB> to supply it).  A noise buffer that fits in the last-level cache is served locally and crosses no %s, so this run may not be stressed at all.\n",
            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);
#else
    fprintf(stderr, "HetLitmus WARNING: HET_NOISE_MB=%d is BELOW the HET_LLC_MB supplied for this build (%d MB) -- the noise buffers fit in the last-level cache, so the reads are served locally and generate NO interconnect traffic.  This run is NOT %s-stressed.\n",
            (int)HET_NOISE_MB, (int)HET_LLC_MB, HET_LINK_NAME);
#endif
  }
  if (_noiseBlocks > 0) {
    int _rc = gd_alloc_noise((void**)&_noise_ddr, (size_t)_noise_words*sizeof(uint64_t), 2);
    if (_rc < 0) { fprintf(stderr, "HetLitmus WARNING: could not allocate the %d MB DDR noise buffer -- %s of the %s noise is DISABLED for this run.\n", (int)HET_NOISE_MB, HET_DEV_HALF, HET_LINK_NAME); _noise_ddr = NULL; _noise_blocks = 0; }
    else if (_rc > 0) fprintf(stderr, "HetLitmus WARNING: the DDR noise buffer could not be homed on the CPU -- this device has no interconnect-stress lever (no ATS/coherent host-device link), so %s of the noise is exercising plumbing, not the %s.\n", HET_DEV_HALF, HET_LINK_NAME);
  }
  if (HET_NOISE_CPU) {
    int _rc = gd_alloc_noise((void**)&_noise_hbm, (size_t)_noise_words*sizeof(uint64_t), 1);
    if (_rc < 0) { fprintf(stderr, "HetLitmus WARNING: could not allocate the %d MB HBM noise buffer -- %s of the %s noise is DISABLED for this run.\n", (int)HET_NOISE_MB, HET_HOST_HALF, HET_LINK_NAME); _noise_hbm = NULL; }
    else if (_rc > 0) fprintf(stderr, "HetLitmus WARNING: the HBM noise buffer could not be homed on the GPU -- %s of the noise is exercising plumbing, not the %s.\n", HET_HOST_HALF, HET_LINK_NAME);
  }
  fprintf(stderr, "HetLitmus cpu-stress: cores=%d test=%d enemies=%d spread=%u stride=%d seq=%d preload=%d%% aff=%d | noise: gpu_blocks=%u cpu=%d words=%llu (%d MB) place=%d\n",
          _ncores, _nCpuTest, _nEnemy, _cpu_spread, (int)HET_CPU_STRIDE,
          (int)HET_CPU_ENEMY_SEQ, (int)HET_CPU_PRELOAD_PCT, _aff,
          _noise_blocks, (int)HET_NOISE_CPU,
          (unsigned long long)_noise_words, (int)HET_NOISE_MB, (int)HET_PLACE);
|}

let dump_campaign_knobs ch =
  let s = output_string ch in
  s "  outs_t* hist = NULL;\n" ;

  (* One counter per run (hetlitmus/docs/harness-reporting.md sec 5). *)
  s "  het_obs_record _recs[NUMBER_OF_RUN];\n" ;
  s "  memset(_recs, 0, sizeof _recs);\n" ;
  (* Campaign knobs read through getenv, never -D: a retune needs
     no rebuild and no branch folds away.  See het_verdict.h. *)
  s {|  int _runs_budget = (int)het_env_long("HET_RUNS_MAX", NUMBER_OF_RUN);
  if (_runs_budget > NUMBER_OF_RUN) {
    fprintf(stderr, "HetLitmus WARNING: HET_RUNS_MAX=%d exceeds the compiled NUMBER_OF_RUN=%d -- clamped.  Grow R by re-invoking with a FRESH HET_SEED (hetlitmus/campaign.py), never by replaying the same seeds.\n", _runs_budget, (int)NUMBER_OF_RUN);
    _runs_budget = NUMBER_OF_RUN;
  }
  if (_runs_budget < 1) _runs_budget = 1;
  int _adaptive = (int)het_env_long("HET_ADAPTIVE", 0);
  int _rate_mode = (int)het_env_long("HET_RATE", 0);
  int _confirm_runs = (int)het_env_long("HET_CONFIRM_RUNS", 30);
  uint32_t _seed0 = (uint32_t)het_env_long("HET_SEED", (long)HET_SEED);
|} ;

  (* The rendezvous spin caps. *)
  s {|  long _cap_cpu = het_env_long("HET_CAP_CPU", (long)HET_CAP_CPU);
  long _cap_gpu_env = het_env_long("HET_CAP_GPU", (long)HET_CAP_GPU);
  if (_cap_cpu < 0) _cap_cpu = 0;
  if (_cap_gpu_env < 0) _cap_gpu_env = 0;
  unsigned long _cap_cpu_u = (unsigned long)_cap_cpu;
  unsigned long _cap_gpu_u = (unsigned long)_cap_gpu_env;
  if (_cap_cpu_u > 0xffffffffUL) {
    fprintf(stderr, "HetLitmus WARNING: HET_CAP_CPU=%lu exceeds the %lu polls the record can carry -- clamped.\n", _cap_cpu_u, 0xffffffffUL);
    _cap_cpu_u = 0xffffffffUL; _cap_cpu = (long)_cap_cpu_u;
  }
  if (_cap_gpu_u > 0xffffffffUL) {
    fprintf(stderr, "HetLitmus WARNING: HET_CAP_GPU=%lu exceeds the %lu polls a lane can carry -- clamped.\n", _cap_gpu_u, 0xffffffffUL);
    _cap_gpu_u = 0xffffffffUL;
  }
  uint32_t _cap_gpu = (uint32_t)_cap_gpu_u;
  int _nrec = 0;
|}

let host_reset o = match o.mo_reset with
  | Memset -> Printf.sprintf "memset(%s, 0, %s);" o.mo_name o.mo_bytes
  | Store_zero -> Printf.sprintf "*%s = 0;" o.mo_name

let dump_run_reset_race_surface memory ch =
  let s = output_string ch in
  List.iter
    (fun o -> s (Printf.sprintf "    %s\n" (host_reset o)))
    (race_surface memory) ;
  s {|    uint32_t _seed = _seed0 + (uint32_t)_run;
    srand((unsigned int)_seed);
    het_set_scratch_locations(_scratch_loc_h, _grid);
|}

let dump_run_spawn_stress ch =
  let s = output_string ch in
  (* The CPU stress population, spawned BEFORE the test threads. *)
  s "    memset(&_ct, 0, sizeof _ct);\n" ;

  (* A host with no cache primitives issues zero preload hints. *)
  s {|    _ct.preload_inert = !het_cpu_preload_live();
    het_cpu_shuffle(_cpu_idx, _cpu_nregions);   /* reshuffled per run, off the run seed */
    __atomic_store_n(&_stress_go, 1, __ATOMIC_RELAXED);
    int _ecore0 = HET_CPU_TEST_CORE0 + _nCpuTest + (HET_NOISE_CPU ? 1 : 0);
    if (_aff && _ecore0 + _nEnemy > _ncores)
      fprintf(stderr, "HetLitmus WARNING: %d enemy thread(s) from core %d exceed %d core(s) -- enemy pins WRAP onto the test threads' cores, so the test threads no longer have a core to themselves and the stress topology is not the one being tuned.\n",
              _nEnemy, _ecore0, _ncores);
    for (int _e = 0; _e < _nEnemy; ++_e) {
      uint32_t _off = (_cpu_nregions > _cpu_spread)
                    ? ((uint32_t)_e * _cpu_spread) % (_cpu_nregions - _cpu_spread + 1)
                    : 0u;
      _ea[_e].scratch = _cpu_scratch;
      _ea[_e].idx     = _cpu_idx + _off;
      _ea[_e].nidx    = _cpu_spread;
      _ea[_e].stride  = (uint32_t)HET_CPU_STRIDE;
      _ea[_e].seq     = (uint32_t)HET_CPU_ENEMY_SEQ;
      _ea[_e].core    = _aff ? ((_ecore0 + _e) % _ncores) : -1;
      _ea[_e].go      = &_stress_go;
      _ea[_e].tally   = &_ct;
      pthread_create(&_eth[_e], NULL, het_cpu_enemy, &_ea[_e]);
    }
    _noise_cpu_on = 0;
    if (HET_NOISE_CPU && _noise_hbm != NULL) {
      _na.buf    = (volatile const uint64_t*)_noise_hbm;
      _na.words  = _noise_words;
      _na.chunk  = _noise_chunk;
      _na.stride = _noise_stride;
      _na.core   = _aff ? ((HET_CPU_TEST_CORE0 + _nCpuTest) % _ncores) : -1;
      _na.go     = &_stress_go;
      _na.tally  = &_ct;
      pthread_create(&_nth, NULL, het_cpu_noise, &_na);
      _noise_cpu_on = 1;
    }
|}

let dump_run_reset_observation dialect memory procs ch =
  let s = output_string ch in
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
    (fun o ->
      match o.mo_where with
      | Device ->
         s (Printf.sprintf "    %s\n"
              (dialect.gd_dev_memset0 o.mo_name o.mo_bytes))
      | Shared | Host -> s (Printf.sprintf "    %s\n" (host_reset o)))
    (observation_record memory procs)

let dump_run_spawn_cpu_threads procs memory ch =
  let s = output_string ch in
  (* Cores go out in emission order, so no two test threads share one. *)
  let ti = ref 0 in
  List.iter
    (fun cp ->
      let proc = cp.cp_proc in
      let addr = cp.cp_addrs
      and bufs = cpu_read_buffers memory cp in
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
    procs.pr_cpus

let dump_run_launch_kernel dialect identity memory procs ch =
  let s = output_string ch in
  let id = identity.id_ident in
  (* args[] in kernel-parameter order. *)
  let args_addrs =
    String.concat ", "
      (List.map (fun g -> "&" ^ g) memory.me_gpu_globals
       @ List.map (fun rb -> "&" ^ rb.rb_name)
           (gpu_read_buffers memory)
       @ List.map (fun gp -> "&" ^ rdv_gpu_name gp.gp_proc) procs.pr_gpus
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
       dialect.gd_success dialect.gd_errstr)

let dump_run_join dialect procs ch =
  let s = output_string ch in
  List.iter
    (fun cp ->
      s (Printf.sprintf "    pthread_join(_th%d, NULL);\n" cp.cp_proc))
    procs.pr_cpus ;
  s (Printf.sprintf "    %s _s = %s\n" dialect.gd_err_t dialect.gd_device_sync) ;
  s (Printf.sprintf
       "    if (_s != %s) { fprintf(stderr, \"sync: %%s\\n\", %s(_s)); return 2; }\n"
       dialect.gd_success dialect.gd_errstr) ;
  s {|    __atomic_store_n(&_stress_go, 0, __ATOMIC_RELAXED);
    for (int _e = 0; _e < _nEnemy; ++_e) pthread_join(_eth[_e], NULL);
    if (_noise_cpu_on) pthread_join(_nth, NULL);
|}

let dump_run_stress_report dialect ch =
  let s = output_string ch in
  s (Printf.sprintf "    %s\n"
       (dialect.gd_memcpy_d2h "_stress_tally_h" "_stress_tally"
          "sizeof(uint32_t)*HET_TALLY_N")) ;
  s {|    {
      unsigned long long _er = _ct.enemy_rounds;
      unsigned long long _pl = _ct.preload_ops;
      unsigned long long _nc = _ct.noise_cpu_rounds;
      uint32_t _ng = _stress_tally_h[HET_TALLY_NOISE];
      fprintf(stderr, "HetLitmus cpu-stress: enemies=%u rounds=%llu accesses=%llu preload_hints=%llu | noise: cpu_rounds=%llu gpu_blocks=%u (max %u rounds) | aff_fail=%u place_fail=%d\n",
              _ct.enemies_realised, _er, (unsigned long long)_ct.enemy_accesses,
              _pl, _nc, _ng, _stress_tally_h[HET_TALLY_NOISE_ROUNDS],
              _ct.aff_failures, _het_place_failures);
      if (_nEnemy > 0 && _er == 0)
        fprintf(stderr, "HetLitmus WARNING: %d CPU enemy thread(s) were spawned but completed ZERO rounds -- the CPU-side stress did NOT run.  Its non-observations are not those of a CPU-stressed run.\n", _nEnemy);
      if (HET_CPU_PRELOAD_PCT > 0 && _pl == 0)
        fprintf(stderr, "HetLitmus WARNING: HET_CPU_PRELOAD_PCT=%d but ZERO preload hints were issued -- the cache preload is INERT (this host may have no cache primitives; see het_cpu_stress.h HET_CPU_PRELOAD_LIVE).\n", (int)HET_CPU_PRELOAD_PCT);
      if (_noise_blocks > 0 && _ng == 0)
        fprintf(stderr, "HetLitmus WARNING: %u device-side noise block(s) were launched but NONE completed a round -- %s of the %s noise did NOT run.  This run is not interconnect-stressed.\n", _noise_blocks, HET_DEV_HALF, HET_LINK_NAME);
      if (_ct.aff_failures)
        fprintf(stderr, "HetLitmus WARNING: %u sched_setaffinity call(s) FAILED -- those threads are wherever the scheduler put them.  The pinning is fiction and the stress topology is not the one being tuned.\n", _ct.aff_failures);
    }
|}

let dump_run_readback dialect memory procs ch =
  let s = output_string ch in
  List.iter
    (fun o ->
      match o.mo_where with
      | Device ->
         s (Printf.sprintf "    %s\n"
              (dialect.gd_memcpy_d2h (o.mo_name^"_h") o.mo_name o.mo_bytes))
      | Shared | Host -> ())
    (observation_record memory procs)

let dump_run_record_stamp identity ch =
  let s = output_string ch in
  let tname = identity.id_name in
  let cpu_only = identity.id_cpu_only in
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
  s {|    _rec.stress_requested =
        ((HET_GPU_LANES > 0 && (HET_PRE_STRESS_PCT > 0 || HET_MEM_STRESS_PCT > 0)) ? HET_REQ_GPU_STRESS : 0u)
      | ((_nEnemy > 0) ? HET_REQ_CPU_ENEMY : 0u)
      | ((HET_CPU_PRELOAD_PCT > 0 && !_ct.preload_inert) ? HET_REQ_CPU_PRELOAD : 0u)
      | ((HET_NOISE_CPU && _noise_cpu_on) ? HET_REQ_NOISE_CPU : 0u)
      | ((_noise_blocks > 0) ? HET_REQ_NOISE_GPU : 0u);
    _rec.stress_truncated = _stress_tally_h[HET_TALLY_TRUNC];
    _rec.gpu_stress_rounds = _stress_tally_h[HET_TALLY_STRESS_ROUNDS];
    _rec.cpu_enemies = _ct.enemies_realised;
    _rec.cpu_enemy_rounds = _ct.enemy_rounds;
    _rec.cpu_enemy_accesses = _ct.enemy_accesses;
    _rec.cpu_preload_ops = _ct.preload_ops;
    _rec.noise_cpu_rounds = _ct.noise_cpu_rounds;
    _rec.noise_cpu_words = _ct.noise_cpu_words;
    _rec.noise_gpu_blocks = _stress_tally_h[HET_TALLY_NOISE];
    _rec.noise_gpu_rounds = _stress_tally_h[HET_TALLY_NOISE_ROUNDS];
    _rec.cpu_aff_failures = _ct.aff_failures;
    _rec.place_failures = (uint32_t)_het_place_failures;
    _rec.noise_ws_mb = (uint32_t)HET_NOISE_MB;
    _rec.place_mode = (uint32_t)HET_PLACE;
    _rec.cap_cpu = (uint32_t)_cap_cpu;
    _rec.cap_gpu = _cap_gpu;
    _rec.cap_calibrated = HET_CAP_CALIBRATED;
|}

(* Iteration n's vector comes from slot n, and the arrival flags are ANDed
   first, so an iteration ONLY one side started is discarded unread. *)
let dump_run_readout procs outcome ch =
  let s = output_string ch in
  let nslots = n_columns outcome in
  let n_reg = List.length outcome.oc_reg_columns in
  let nsl = max 1 nslots in
  s (Printf.sprintf "    intmax_t _first[%d]; int _seen_first = 0;\n" nsl) ;
  s "    for (int _n=0; _n<SIZE_OF_TEST; ++_n) {\n" ;
  s "      int _ok = 1;\n" ;
  List.iter
    (fun (p,dev) ->
      match dev with
      | `Gpu ->
         s (Printf.sprintf
              "      if (!%s_h[_n]) { _ok = 0; _rec.rdv_cap_gpu++; }\n"
              (rdv_gpu_name p))
      | `Cpu ->
         s (Printf.sprintf
              "      if (!%s[_n]) { _ok = 0; _rec.rdv_cap_cpu++; }\n"
              (rdv_cpu_name p)))
    procs.pr_participants ;
  s "      if (!_ok) { _rec.iters_discarded++; continue; }\n" ;
  s "      _rec.iters_scored++;\n" ;
  s (Printf.sprintf "      intmax_t _o[%d];\n" nsl) ;
  List.iteri
    (fun i (_,buf) ->
      s (Printf.sprintf "      _o[%d] = (intmax_t)%s[_n];\n" i buf))
    outcome.oc_reg_columns ;
  List.iteri
    (fun j g ->
      s (Printf.sprintf
           "      _o[%d] = (intmax_t)%s[(size_t)_n*HET_SLOT_STRIDE_WORDS];\n"
           (n_reg+j) g))
    outcome.oc_loc_columns ;
  if nslots = 0 then s "      _o[0] = 0;\n" ;
  s (Printf.sprintf "      int _weak = %s;\n" outcome.oc_weak_expr) ;
  s "      if (_weak) _rec.target_count++;\n" ;
  s (Printf.sprintf
       "      hist = add_outcome_outs(hist, _o, %d, 1, _weak);\n" nslots) ;

  (* outcomes_vary = 0 iff every scored iteration read the same vector. *)
  s {|      if (!_seen_first) { memcpy(_first, _o, sizeof _o); _seen_first = 1; }
      else if (memcmp(_first, _o, sizeof _o) != 0) _rec.outcomes_vary = 1;
    }
|} ;
  (* Marks the readout as having run
     (hetlitmus/docs/00-environment-design.md sec 4). *)
  s "    _rec.rdv_valid = 1;\n"

let dump_run_report ch =
  let s = output_string ch in
  s {|    fprintf(stderr, "HetLitmus rendezvous: scored=%llu discarded=%llu (cap_cpu=%llu cap_gpu=%llu) caps=%lu/%u jitter=%d discard_max=%d%% %s\n",
            (unsigned long long)_rec.iters_scored,
            (unsigned long long)_rec.iters_discarded,
            (unsigned long long)_rec.rdv_cap_cpu,
            (unsigned long long)_rec.rdv_cap_gpu,
            (unsigned long)_cap_cpu, _cap_gpu, (int)HET_RELEASE_JITTER,
            (int)HET_RDV_MAX_DISCARD_PCT,
            HET_CAP_CALIBRATED ? "caps calibrated" : "caps UNCALIBRATED");
    het_obs_record_print(stdout, &_rec);
    het_verdict_print(stdout, &_rec);
    _recs[_nrec++] = _rec;
|}

let dump_run_early_stop identity ch =
  let s = output_string ch in
  let tname = identity.id_name in
  (* Early stop after each run, decided from the records so far
     (het_verdict.h); with HET_ADAPTIVE unset the loop runs to budget. *)
  s {|    if (_adaptive) {
      het_campaign_stop_t _stop = het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs);
      if (_stop != HET_CAMPAIGN_CONTINUE) {
|} ;
  s (Printf.sprintf
       "        printf(\"HetCampaign %s stop=%%s runs=%%d budget=%%d\\n\",\n\
        \               het_campaign_stop_name(_stop), _nrec, _runs_budget);\n"
       tname) ;
  s {|        { const char *_why = het_campaign_stop_why(_stop);
          if (*_why) printf("  %s.\n", _why); }
        break;
      }
    }
|}

let dump_aggregate identity outcome ch =
  let s = output_string ch in
  let tname = identity.id_name in
  (* The aggregate reuses het_verdict() per record, so it inherits
     every disqualifier (hetlitmus/docs/harness-reporting.md sec 5). *)
  s {|  {
    het_stats_t _st;
    het_stats_compute(_recs, _nrec, &_st);
    het_stats_print(stdout, &_st);
  }
|} ;
  s (Printf.sprintf "  intmax_t _buff[%d];\n"
       (max 1 (n_columns outcome))) ;
  s (Printf.sprintf "  printf(\"Test %s\\n\");\n" tname) ;
  s (Printf.sprintf "  dump_outs(stdout, _dump_one, hist, _buff, %d);\n"
       (n_columns outcome)) ;
  s "  free_outs(hist);\n"

let dump_free dialect memory procs ch =
  let s = output_string ch in
  List.iter
    (fun o ->
      let n = o.mo_name in
      match o.mo_where with
      | Shared -> s (Printf.sprintf "  gd_free_shared(%s);\n" n)
      | Device -> s (Printf.sprintf "  %s free(%s_h);\n" (dialect.gd_free n) n)
      | Host -> s (Printf.sprintf "  free(%s);\n" n))
    (memory_objects memory procs) ;
  s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch")) ;
  s (Printf.sprintf "  %s\n" (dialect.gd_free "_scratch_loc")) ;
  s (Printf.sprintf "  %s\n" (dialect.gd_free "_gpu_done")) ;
  s (Printf.sprintf "  %s\n" (dialect.gd_free "_stress_tally")) ;
  s {|  free(_scratch_loc_h);
  free(_cpu_scratch);
  free(_cpu_idx);
  free(_ea);
  free(_eth);
  gd_free_noise(_noise_ddr);
  gd_free_noise(_noise_hbm);
|}

let dump h dialect ch =
  let s = output_string ch in
  let identity = h.h_identity in
  let procs = h.h_procs and memory = h.h_memory in
  let outcome = h.h_outcome in
  s "int main(void){\n" ;
  dump_test_state_alloc dialect memory procs ch ;
  dump_launch_geometry dialect identity ch ;
  dump_gpu_stress_alloc dialect ch ;
  dump_cpu_stress_setup procs ch ;
  dump_noise_setup ch ;
  dump_campaign_knobs ch ;
  s "  for (int _run=0; _run<_runs_budget; ++_run) {\n" ;
  dump_run_reset_race_surface memory ch ;
  dump_run_spawn_stress ch ;
  dump_run_reset_observation dialect memory procs ch ;
  dump_run_spawn_cpu_threads procs memory ch ;
  dump_run_launch_kernel dialect identity memory procs ch ;
  dump_run_join dialect procs ch ;
  dump_run_stress_report dialect ch ;
  dump_run_readback dialect memory procs ch ;
  dump_run_record_stamp identity ch ;
  dump_run_readout procs outcome ch ;
  dump_run_report ch ;
  dump_run_early_stop identity ch ;
  s "  }\n" ;
  dump_aggregate identity outcome ch ;
  dump_free dialect memory procs ch ;
  s "  return 0;\n}\n"
