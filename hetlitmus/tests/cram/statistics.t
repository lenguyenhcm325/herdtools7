Statistics-layer guard (hetlitmus/docs/harness-reporting.md sec 5; where a
design document and litmus/het-runtime/het_verdict.h disagree, the header is
what ships).  A "Never" is readable only against the effort that produced it,
so the harness carries every input the estimator reads out of a run: the record
array that outlives the run loop, the campaign knobs read at run time, the
adaptive stop, and the readout counts and degeneracy evidence every shape writes.

The layer's own behaviour is gated by hetlitmus/verify/statscheck.py, which
compiles the real het_verdict.h and drives it with synthetic record streams.
What this file pins is the EMITTER's half: that the harness produces the inputs
the layer consumes, since a perfect estimator fed by a tally that never moves is
indistinguishable from one that works.

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1

THE RECORDS MUST OUTLIVE THE RUN LOOP.  The statistics are computed over the
per-run records, so a single reused _rec would leave nothing to aggregate.
The loop may stop early (HET_ADAPTIVE), so the records land at _nrec and the
post-pass scores _nrec -- the cells actually run, never the compiled constant.

  $ grep -c 'het_obs_record _recs\[NUMBER_OF_RUN\];' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_recs\[_nrec++\] = _rec;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_stats_compute(_recs, _nrec, &_st);' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE CAMPAIGN KNOBS ARE RUNTIME (getenv), NEVER -D.  A compile-time knob threaded
through an if-chain is how the stress layer got folded away by nvcc (stress.t
(e)), and the campaign scheduler retunes budget/seed per invocation without a
rebuild.  The seed base is env-overridable for exactly one reason: growing R
happens by re-invoking with a fresh HET_SEED, and replaying the same seeds would
count one draw twice.

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

THE ADAPTIVE STOP IS THE HEADER'S RULE, consulted after every run -- the same
pure function the campaign scheduler applies across invocations, so there is
exactly one stopping policy.  The rule stays PURE, so the driver reads its two
policy knobs and PASSES them; a rule that read its own environment could not be
unit-tested from synthetic records.

  $ grep -c 'het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'HetCampaign MP-cg-sys-fence-2s stop=%s' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_campaign_stop_why(_stop)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE TARGET COUNT IS BUMPED ONCE PER SCORED ITERATION, UNDER THE DETECTOR ITSELF,
beside the iters_scored the effort disclosure is summed from.  A bump that
drifted onto its own condition would let the count and the effort disagree about
an iteration while every structural gate stayed green.

  $ grep -c 'if (_weak) _rec.target_count++;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.iters_scored++;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE DEGENERACY GUARD READS EVIDENCE THE EMITTER WRITES.  het_cell_degenerate
asks whether this cell scored anything and whether its outcome vector ever
varied; both are memset zero unless the readout writes them, and a guard reading
an unwritten field would call every cell degenerate.  Every shape writes them,
the store-only ones included -- a location column is read out of its slot like a
register's, so 2+2W has an outcome vector like any other test.

  $ grep -c '_rec.outcomes_vary = 1;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.outcomes_vary = 1;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c '_rec.iters_scored++;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

THE INSTRUMENTS THEMSELVES ARE IN THE EMITTED HEADER, NOT IN A SCRIPT.  A reader
who cannot recompute an outcome from the artefact has not been given a result.

  $ grep -c 'static void het_stats_compute' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static int het_cell_degenerate' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static het_campaign_stop_t het_campaign_should_stop' MP-cg-sys-fence-2s/het_verdict.h
  1

THE DENOMINATOR IS R, THE RUNS EXECUTED, and this is the line that makes it:
nothing co-runs, so a cell is usable partly BECAUSE it fired, and scoring over
the usable cells would report Always for a row that fired in some of its runs --
the one way this layer can claim more than it measured.

  $ grep -c '{ int denom = st->R;' MP-cg-sys-fence-2s/het_verdict.h
  1

NO RATE AND NO PROBABILITY IS ATTACHED TO A NULL.  What a non-observation reports
is the effort spent and the liveness the run measured on its own counters, so
both printers carry the sentence that says so rather than leaving a reader to
infer it: the per-run verdict block and the campaign-level one.

  $ grep -c 'NO RATE AND NO PROBABILITY' MP-cg-sys-fence-2s/het_verdict.h
  2
