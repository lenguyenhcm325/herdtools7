Statistics-layer inputs: hetlitmus/docs/00-environment-design.md "Aggregate".

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-sy.fsc.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-plain.fsc.litmus >/dev/null 2>&1

The records outlive the run loop, and the post-pass scores the runs actually banked
(_nrec) rather than the compiled constant.

  $ grep -c 'het_obs_record _recs\[NUMBER_OF_RUN\];' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c '_recs\[_nrec++\] = _rec;' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'het_stats_compute(_recs, _nrec, &_st);' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1

The campaign knobs are runtime reads (getenv), NEVER a -D, and the per-run seed
derives from the seed base.

  $ grep -c 'het_env_long("HET_RUNS_MAX", NUMBER_OF_RUN)' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'het_env_long("HET_STOP_AT_SIGHTING", 0)' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'het_env_long("HET_SEED", (long)HET_SEED)' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'uint32_t _seed = _seed0 + (uint32_t)_run;' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1

An unset, empty or unparseable HET_SEED pins nothing, so the base is drawn from
entropy, and the run prints the base it used either way.

  $ grep -c '_seed_env = getenv("HET_SEED")' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -cF "_seed_env != NULL && *_seed_env != '\0'" MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c '_seed_end != NULL && _seed_end != _seed_env' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'het_seed_entropy(&_seed0) == 0' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'HetLitmus: seed0=%u source=%s' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1

The run loop ends at the first clean sighting only when asked, and says so.

  $ grep -c 'if (_stop_at_sighting && _rec.target_count > 0 && !het_run_degenerate(&_rec)) {' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c 'HetLitmus: run loop ended after run %d of %d on a clean sighting' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1

The target count is bumped once per scored iteration, under the detector itself.

  $ grep -c 'if (_weak) _rec.target_count++;' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1

The degeneracy guard reads evidence the emitter writes, and every shape writes it
-- the store-only ones included.

  $ grep -c '_rec.outcomes_vary = 1;' MP-cg-sys-sy.fsc/MP-cg-sys-sy.fsc.cu
  1
  $ grep -c '_rec.outcomes_vary = 1;' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  1
