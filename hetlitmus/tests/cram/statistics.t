Statistics-layer guard (hetlitmus/docs/00-environment-design.md sec 3.7; where
that design and litmus/het-runtime/het_verdict.h disagree, the header is what
ships).  A "Never" is readable only against the effort that produced it, so the
harness has to carry every input the estimator reads out of a run: the record
array that outlives the run loop, the campaign knobs read at run time, the
adaptive stop, and the decode channel each shape actually has.

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
unit-tested from synthetic records.  The record also reports the window
resolution the run realised: HET_NWIN is swept, and a record scored at one nwin
must never be pooled with another.

  $ grep -c 'het_campaign_should_stop(_recs, _nrec, _runs_budget, _rate_mode, _confirm_runs)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'HetCampaign MP-cg-sys-fence-2s stop=%s' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_campaign_stop_why(_stop)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.nwin = (uint32_t)HET_NWIN;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE TARGET COUNT IS BUMPED ON ONE LINE, UNDER ONE PREDICATE, on both channels
at once: the exhaustive count and the heuristic one are the same sighting read
two ways, and a bump that drifted onto its own line under its own condition
would let the two disagree about a frame while every structural gate stayed
green.

  $ grep -c 'target_count_exhaustive++; _rec.target_count_heuristic++' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE DEGENERACY GUARD MUST NOT GO CONSTANT ON THE STORE-ONLY SHAPES.
distinct_decoded_iters and skew_stddev are both written from the same
synchrony-decode block, so a test with no synchrony read leaves both at their
memset zero.  Every 2+2W -- store-only, with no reader at all -- sits in exactly
that position, and a guard reading `skew_stddev == 0' as "the decoder is
degenerate" would condemn every one of their cells forever, making k_eff constant
0 and P_rep a constant 1 - e^0 = 0 on them.  0 means NOT MEASURED,
never "measured zero", so the emitter tags which channel each test actually has
and the guard switches channel rather than firing blind.

MP has a reader -> the synchrony channel:

  $ grep -c '_rec.sync_valid = 1;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.obs_valid = 1;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  0
  [1]

2+2W is store-only -> the OBSERVER channel, and no synchrony channel at all:

  $ grep -c '_rec.obs_valid = 1;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c '_rec.sync_valid = 1;' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  0
  [1]

THE INSTRUMENTS THEMSELVES ARE IN THE EMITTED HEADER, NOT IN A SCRIPT.  A reader
who cannot recompute an outcome from the artefact has not been given a result.

  $ grep -c 'static int het_ks2' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static int het_cell_degenerate' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static het_campaign_stop_t het_campaign_should_stop' MP-cg-sys-fence-2s/het_verdict.h
  1

THE KS GATE FAILS CLOSED ON AN EMPTY STREAM, and this is the conjunct that makes
it: the gate is refused when the pooled control stream is absent, all-zero or
desynced.  Run anyway, D is 0 against 0, the gate "passes" and P_rep is unlocked
for a harness in which nothing ever fired -- the one way this layer can claim
more than it measured.

  $ grep -c 'ks = (st->flags & HET_ST_CTRL_STREAM_EMPTY)' MP-cg-sys-fence-2s/het_verdict.h
  1

NO RATE AND NO PROBABILITY IS ATTACHED TO A NULL.  What a non-observation reports
is the effort spent and the control that vouched for it, so the harness carries
the sentence that says so rather than leaving a reader to infer it.

  $ grep -c 'NO RATE AND NO PROBABILITY' MP-cg-sys-fence-2s/het_verdict.h
  1
