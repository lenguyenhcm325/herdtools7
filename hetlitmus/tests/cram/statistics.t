Statistics-layer inputs: hetlitmus/docs/harness-reporting.md sec 5.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1

The records outlive the run loop, and the post-pass scores the cells actually run
(_nrec) rather than the compiled constant.

  $ grep -c 'het_obs_record _recs\[NUMBER_OF_RUN\];' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_recs\[_nrec++\] = _rec;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_stats_compute(_recs, _nrec, &_st);' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

The campaign knobs are runtime reads (getenv), NEVER a -D, and the per-run seed
derives from the seed base.

  $ grep -c 'het_env_long("HET_RUNS_MAX", NUMBER_OF_RUN)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_ADAPTIVE", 0)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_SEED", (long)HET_SEED)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_RATE", 0)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_CONFIRM_RUNS", 30)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'uint32_t _seed = _seed0 + (uint32_t)_run;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

The adaptive stop is the header's rule, consulted after every run and passed the
two policy knobs it decides on.

  $ grep -c 'het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'HetCampaign MP-cg-sys-fence-2s stop=%s' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_campaign_stop_why(_stop)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

The target count is bumped once per scored iteration, under the detector itself,
beside the iters_scored the effort disclosure is summed from.

  $ grep -c 'if (_weak) _rec.target_count++;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.iters_scored++;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

The degeneracy guard reads evidence the emitter writes, and every shape writes it
-- the store-only ones included.

  $ grep -c '_rec.outcomes_vary = 1;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.outcomes_vary = 1;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c '_rec.iters_scored++;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
